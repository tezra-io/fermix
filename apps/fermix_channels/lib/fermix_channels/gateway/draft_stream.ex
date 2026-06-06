defmodule FermixChannels.Gateway.DraftStream do
  @moduledoc """
  Channel-agnostic live-draft engine for streamed replies
  (docs/design/CHANNEL_STREAMING.md §5.5).

  One `spawn_link`ed process per *streaming* turn, owned by the turn task —
  the same shape as `FermixChannels.Gateway.Typing`. Provider deltas arrive
  in-process (the SSE `into:` callback runs in the turn task) and are pushed
  here only to decouple the fast token rate from the slow channel edit
  budget: the engine coalesces cumulative snapshots (newest wins) and writes
  them through a throttled, single-flight loop.

  The engine never sees a channel module. It drives the four closures in
  `DraftStream.Spec`, built by the gateway where the channel module and
  inbound message both exist. A test greps this file to keep platform-isms
  out.

  Lifecycle: `push/2` feeds `FermixCore.AgentLoop.stream_event()`s;
  `seal/2` performs the final reliable write from the authoritative turn
  response; `discard/1` deletes the draft. The engine traps exits so a
  killed turn task (`/stop` sends `:shutdown` through the link) still
  triggers a best-effort discard — no orphaned drafts on cancellation.
  """

  require Logger

  alias FermixCore.AgentLoop

  defmodule Spec do
    @moduledoc """
    Channel-bound closures the engine drives, plus the channel name for
    telemetry. Built by the gateway (which holds the channel module and the
    inbound message); the engine itself stays channel-blind.

    Two modes (`docs/design/CHANNEL_STREAMING.md` §5.4/§7):
    - `:draft` — one message edited in place; requires `open`/`edit`/`seal`/
      `discard` closures over a draft-capable channel.
    - `:block` — completed chunks sent as separate ordinary messages; requires
      only `send` (any channel can do it).
    """

    @enforce_keys [:channel]
    defstruct [:channel, :open, :edit, :seal, :discard, :send, mode: :draft]

    @type t :: %__MODULE__{
            channel: String.t(),
            mode: :draft | :block,
            open: (String.t() -> {:ok, term()} | {:error, term()}) | nil,
            edit: (term(), String.t() -> :ok | {:error, term()}) | nil,
            seal: (term(), String.t() -> {:ok, String.t() | nil} | {:error, term()}) | nil,
            discard: (term() -> :ok | {:error, term()}) | nil,
            send: (String.t() -> :ok | {:error, term()}) | nil
          }
  end

  # Throttle policy (design §5.5). Constants, not operator config — the only
  # operator knob is the per-channel `streaming` mode switch. The keyword
  # overrides on start_link/2 exist for tests.
  @edit_interval_ms 1_000
  @min_draft_chars 30
  @max_edits 300
  @max_consecutive_failures 2
  @seal_timeout_ms 15_000

  # Block-mode chunking (OpenClaw-proven defaults): paragraph-aligned chunks of
  # 800–1200 chars; a 1 s idle lull flushes smaller fence-balanced text (this is
  # what lets pre-tool commentary land as its own message).
  @block_min_chars 800
  @block_max_chars 1_200
  @idle_flush_ms 1_000

  @type seal_result :: {:ok, String.t() | nil | :no_draft} | {:error, term()}

  @doc """
  Build the closure spec for a draft-capable channel + inbound message. Called
  by the gateway — the one layer that holds the channel module — so the engine
  (and the queue) stay channel-blind.
  """
  @spec build_spec(module(), struct()) :: Spec.t()
  def build_spec(channel, %{channel: channel_name} = message) when is_atom(channel) do
    %Spec{
      channel: channel_name,
      mode: :draft,
      open: fn text -> channel.open_draft(message, text) end,
      edit: fn handle, text -> channel.edit_draft(message, handle, text) end,
      seal: fn handle, text -> channel.seal_draft(message, handle, text) end,
      discard: fn handle -> channel.discard_draft(message, handle) end
    }
  end

  @doc """
  Build a block-mode spec: completed chunks go out as ordinary sends through
  the supplied closure (typically the gateway's reply closure). No draft
  callbacks needed, so any channel qualifies.
  """
  @spec build_block_spec(String.t(), (String.t() -> :ok | {:error, term()})) :: Spec.t()
  def build_block_spec(channel_name, send_fn)
      when is_binary(channel_name) and is_function(send_fn, 1) do
    %Spec{channel: channel_name, mode: :block, send: send_fn}
  end

  @doc """
  Spawn the engine linked to the calling turn task. Returns the engine pid.

  `opts` (test-only overrides): `:edit_interval_ms`, `:min_draft_chars`,
  `:max_edits`, `:block_min_chars`, `:block_max_chars`, `:idle_flush_ms`.
  """
  @spec start_link(Spec.t(), keyword()) :: pid()
  def start_link(%Spec{} = spec, opts \\ []) when is_list(opts) do
    assert_spec!(spec)
    spawn_link(fn -> init(spec, opts) end)
  end

  # Fail loud in the caller (not the spawned process) when a spec is missing
  # the closures its mode drives.
  defp assert_spec!(%Spec{mode: :draft} = spec) do
    valid? =
      is_function(spec.open, 1) and is_function(spec.edit, 2) and
        is_function(spec.seal, 2) and is_function(spec.discard, 1)

    valid? || raise ArgumentError, "draft-mode spec requires open/edit/seal/discard closures"
    :ok
  end

  defp assert_spec!(%Spec{mode: :block} = spec) do
    is_function(spec.send, 1) || raise ArgumentError, "block-mode spec requires a send closure"
    :ok
  end

  @doc "Feed a stream event (async). Newest cumulative snapshot wins."
  @spec push(pid(), AgentLoop.stream_event()) :: :ok
  def push(pid, event) when is_pid(pid) do
    send(pid, {:push, event})
    :ok
  end

  @doc """
  Final reliable write: seal the draft with the authoritative turn response.

  Returns `{:ok, :no_draft}` when no draft was ever opened (short reply or
  non-streaming provider), `{:ok, nil}` on a sealed draft, `{:ok, overflow}`
  when the channel sealed a prefix and returned the remainder for normal
  delivery, `{:error, reason}` when the seal write failed (the draft was
  discarded; deliver the response as a fresh message). A wedged engine is
  killed after `timeout` and reported as `{:error, :draft_stream_timeout}`.
  """
  @spec seal(pid(), String.t(), pos_integer()) :: seal_result()
  def seal(pid, final_text, timeout \\ @seal_timeout_ms)
      when is_pid(pid) and is_binary(final_text) and is_integer(timeout) and timeout > 0 do
    sync(pid, {:seal, final_text}, timeout)
  end

  @doc "Delete the draft (stopped/superseded/errored turn). Best-effort."
  @spec discard(pid(), pos_integer()) :: :ok | {:error, term()}
  def discard(pid, timeout \\ @seal_timeout_ms) when is_pid(pid) do
    case sync(pid, :discard, timeout) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Engine process --

  defp init(spec, opts) do
    Process.flag(:trap_exit, true)
    now = monotonic_ms()
    interval = positive_integer(Keyword.get(opts, :edit_interval_ms), @edit_interval_ms)

    loop(%{
      spec: spec,
      phase: :idle,
      handle: nil,
      buffer: "",
      dirty?: false,
      last_sent: nil,
      # Backdated so the first flushable snapshot writes immediately.
      last_write_at: now - interval,
      started_at: now,
      write_count: 0,
      dropped: 0,
      failures: 0,
      session_id: nil,
      timer_ref: nil,
      idle_ref: nil,
      # Block mode: byte offset into the current iteration's cumulative text
      # already emitted as block messages.
      sent_upto: 0,
      # Block mode: a completed message item is pending full flush (the
      # semantic boundary — flush regardless of the chunk minimum).
      pending_done?: false,
      # Block mode: out-of-band messages (reasoning summaries) awaiting send.
      side_queue: [],
      interval_ms: interval,
      min_chars: positive_integer(Keyword.get(opts, :min_draft_chars), @min_draft_chars),
      max_edits: positive_integer(Keyword.get(opts, :max_edits), @max_edits),
      block_min: positive_integer(Keyword.get(opts, :block_min_chars), @block_min_chars),
      block_max: positive_integer(Keyword.get(opts, :block_max_chars), @block_max_chars),
      idle_ms: positive_integer(Keyword.get(opts, :idle_flush_ms), @idle_flush_ms)
    })
  end

  defp loop(state) do
    receive do
      {:push, event} ->
        state |> apply_event(event) |> maybe_flush() |> loop()

      :flush_tick ->
        %{state | timer_ref: nil} |> maybe_flush() |> loop()

      :idle_flush ->
        %{state | idle_ref: nil} |> idle_flush() |> loop()

      {{:seal, final_text}, from, ref} ->
        handle_seal(state, final_text, from, ref)

      {:discard, from, ref} ->
        handle_discard(state, from, ref)

      {:EXIT, _pid, reason} ->
        handle_parent_exit(state, reason)
    end
  end

  # -- Event application --

  defp apply_event(state, {:text_delta, cumulative}) when is_binary(cumulative) do
    dropped = if state.dirty?, do: state.dropped + 1, else: state.dropped
    %{state | buffer: cumulative, dirty?: true, dropped: dropped}
  end

  # Per-iteration reset (design §5.3): clear the buffer; the live draft keeps
  # its last text until the new iteration's first non-empty snapshot replaces
  # it. In block mode, already-sent blocks stand as commentary; unsent text is
  # discarded (a completed item already flushed via :text_done) and the
  # emitted-offset restarts with the new iteration.
  defp apply_event(state, {:iteration_started, _n}) do
    %{state | buffer: "", dirty?: false, sent_upto: 0, pending_done?: false}
  end

  # A message output item completed — the semantic block boundary. Block mode
  # flushes everything unsent regardless of the chunk minimum (each model
  # "thought" becomes its own message); draft mode treats it as a snapshot.
  defp apply_event(state, {:text_done, cumulative}) when is_binary(cumulative) do
    state = apply_event(state, {:text_delta, cumulative})

    case state.spec.mode do
      :block -> %{state | pending_done?: true}
      _draft -> state
    end
  end

  # The model's decision-making summary. Block mode sends it as its own 💭
  # message (the OpenClaw-on-Signal behavior) — headings only, the full body
  # is too noisy for chat; draft mode drops it — a single evolving draft has
  # no place for out-of-band notes.
  defp apply_event(%{spec: %Spec{mode: :block}} = state, {:reasoning_done, text})
       when is_binary(text) do
    queue_side_block(state, text |> String.trim() |> reasoning_heading())
  end

  defp apply_event(state, {:reasoning_done, _text}), do: state

  defp apply_event(state, {:session_started, session_id}) do
    %{state | session_id: session_id}
  end

  # Typed out of the answer path by design — never enters the buffer.
  defp apply_event(state, {:reasoning_delta, _text}), do: state

  defp apply_event(state, event) do
    Logger.warning("DraftStream ignoring unknown stream event: #{inspect(event)}")
    state
  end

  # -- Flushing --

  defp maybe_flush(%{spec: %Spec{mode: :block}} = state) do
    state = reset_idle_timer(state)

    cond do
      frozen?(state) -> state
      elapsed_ms(state) < state.interval_ms -> ensure_timer(state)
      state.side_queue != [] -> send_side_block(state)
      true -> emit_ready_block(state, state.block_min)
    end
  end

  defp maybe_flush(state) do
    cond do
      not flushable?(state) -> state
      elapsed_ms(state) >= state.interval_ms -> do_flush(state)
      true -> ensure_timer(state)
    end
  end

  defp frozen?(state) do
    state.failures >= @max_consecutive_failures or state.write_count >= state.max_edits
  end

  defp flushable?(state) do
    state.buffer != "" and state.buffer != state.last_sent and
      state.failures < @max_consecutive_failures and
      state.write_count < state.max_edits and
      (state.phase == :live or String.length(state.buffer) >= state.min_chars)
  end

  defp do_flush(%{phase: :idle} = state) do
    case state.spec.open.(state.buffer) do
      {:ok, handle} ->
        emit(state, :open, %{ttfd_ms: monotonic_ms() - state.started_at}, :ok)
        mark_written(%{state | phase: :live, handle: handle})

      {:error, reason} ->
        note_failure(state, :open, reason)
    end
  end

  defp do_flush(%{phase: :live} = state) do
    {result, duration_us} = timed_us(fn -> state.spec.edit.(state.handle, state.buffer) end)

    case result do
      :ok ->
        emit(state, :edit, %{duration_us: duration_us, edit_index: state.write_count + 1}, :ok)
        mark_written(state)

      {:error, reason} ->
        note_failure(state, :edit, reason)
    end
  end

  defp mark_written(state) do
    %{
      state
      | last_sent: state.buffer,
        dirty?: false,
        last_write_at: monotonic_ms(),
        write_count: state.write_count + 1,
        failures: 0
    }
  end

  # Interim writes are best-effort by contract: log, count, never retry. At
  # @max_consecutive_failures the preview freezes; seal (the reliable write)
  # still runs at turn end.
  defp note_failure(state, op, reason) do
    Logger.warning("DraftStream #{op} failed (#{state.spec.channel}): #{inspect(reason)}")
    %{state | failures: state.failures + 1, last_write_at: monotonic_ms()}
  end

  # -- Block-mode emission --

  # Emit at most one ready chunk per call; the paced timer picks up the next.
  # A pending completed item (:text_done) flushes whatever is unsent — the
  # semantic boundary beats the chunk minimum.
  defp emit_ready_block(%{pending_done?: true} = state, _min_chars) do
    window = state |> unsent() |> String.slice(0, state.block_max)

    case String.trim(window) do
      "" -> %{state | pending_done?: false}
      text -> send_block(state, text, byte_size(window))
    end
  end

  defp emit_ready_block(state, min_chars) do
    case next_block(unsent(state), min_chars, state.block_max) do
      :wait -> state
      {:block, text, consumed} -> send_block(state, text, consumed)
    end
  end

  defp send_block(state, text, consumed) do
    {result, duration_us} = timed_us(fn -> state.spec.send.(text) end)

    case result do
      :ok ->
        emit_block_telemetry(state, duration_us)
        state = %{mark_written(state) | sent_upto: state.sent_upto + consumed}
        state = clear_drained_done(state)
        ensure_timer(state)

      {:error, reason} ->
        note_failure(state, :block, reason)
    end
  end

  defp clear_drained_done(%{pending_done?: true} = state) do
    if String.trim(unsent(state)) == "", do: %{state | pending_done?: false}, else: state
  end

  defp clear_drained_done(state), do: state

  # Reasoning summaries arrive as "**Heading**\n\nbody…" parts (the format
  # Codex CLI renders as headers). Chat only gets the headings; a summary the
  # model didn't structure falls back to one truncated line.
  @reasoning_heading_max 80

  defp reasoning_heading(""), do: ""

  defp reasoning_heading(text) do
    case text |> String.split("\n\n", trim: true) |> Enum.flat_map(&bold_heading/1) do
      [] -> text |> first_line() |> truncate(@reasoning_heading_max)
      headings -> Enum.join(headings, " · ")
    end
  end

  defp bold_heading(segment) do
    case Regex.run(~r/\A\*\*(.+)\*\*\z/U, first_line(segment)) do
      [_, heading] -> [String.trim(heading)]
      nil -> []
    end
  end

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  defp truncate(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  # Out-of-band reasoning messages. Bounded: the loop iteration cap keeps this
  # to a few dozen per turn at most; the cap below is a loud backstop.
  @max_side_blocks 32

  defp queue_side_block(state, ""), do: state

  defp queue_side_block(state, text) when length(state.side_queue) >= @max_side_blocks do
    Logger.warning("DraftStream dropping side block beyond cap: #{String.slice(text, 0, 60)}")
    state
  end

  defp queue_side_block(state, text) do
    %{state | side_queue: state.side_queue ++ ["💭 " <> text]}
  end

  defp send_side_block(%{side_queue: [text | rest]} = state) do
    {result, duration_us} = timed_us(fn -> state.spec.send.(text) end)

    case result do
      :ok ->
        emit_block_telemetry(state, duration_us)
        ensure_timer(%{mark_written(state) | side_queue: rest})

      {:error, reason} ->
        # A failed side block is dropped (logged) — it's commentary, not the
        # answer; the answer path has its own failure handling.
        note_failure(%{state | side_queue: rest}, :block, reason)
    end
  end

  defp emit_block_telemetry(%{write_count: 0} = state, _duration_us) do
    emit(state, :open, %{ttfd_ms: monotonic_ms() - state.started_at}, :ok)
  end

  defp emit_block_telemetry(state, duration_us) do
    emit(state, :block, %{duration_us: duration_us, block_index: state.write_count + 1}, :ok)
  end

  # An idle lull (no deltas for idle_ms) flushes the fence-balanced unsent text
  # even below the chunk minimum — this is how pre-tool commentary becomes its
  # own message instead of waiting for the turn to end.
  defp idle_flush(%{spec: %Spec{mode: :block}, side_queue: [_ | _]} = state) do
    if frozen?(state), do: state, else: send_side_block(state)
  end

  defp idle_flush(%{spec: %Spec{mode: :block}} = state) do
    window = state |> unsent() |> String.slice(0, state.block_max)

    if frozen?(state) or String.trim(window) == "" or not fence_balanced?(window) do
      state
    else
      send_block(state, String.trim(window), byte_size(window))
    end
  end

  defp idle_flush(state), do: state

  # A mid-stream provider retry restarts the SSE cumulative from empty
  # (HttpClient retries a dropped connection with a fresh parser), so the
  # buffer can be SHORTER than the consumed offset — clamp, never crash.
  # Emission resumes once the retried stream regrows past the offset; the
  # seal prefix-check guarantees the final reply is correct either way.
  defp unsent(state) do
    start = min(state.sent_upto, byte_size(state.buffer))
    binary_part(state.buffer, start, byte_size(state.buffer) - start)
  end

  # Next emit-ready chunk of the unsent region: prefer the last paragraph
  # boundary past min_chars within the window; force-cut overlong text at a
  # newline; never split inside a code fence (an unsplittable fence waits for
  # the turn-end tail). Returns {:block, trimmed_text, consumed_bytes} | :wait.
  defp next_block("", _min_chars, _max_chars), do: :wait

  defp next_block(text, min_chars, max_chars) do
    window = String.slice(text, 0, max_chars)

    case paragraph_cut(window, min_chars) do
      {:ok, prefix, consumed} -> {:block, String.trim(prefix), consumed}
      :none -> forced_cut(text, window, min_chars)
    end
  end

  # Last "\n\n" in the window at/after min_chars whose prefix is fence-balanced.
  # Byte offsets from :binary.matches are valid boundaries ("\n" is ASCII).
  defp paragraph_cut(window, min_chars) do
    window
    |> :binary.matches("\n\n")
    |> Enum.reverse()
    |> Enum.find_value(:none, fn {pos, _len} ->
      prefix = binary_part(window, 0, pos)
      if pos >= min_chars and fence_balanced?(prefix), do: {:ok, prefix, pos + 2}
    end)
  end

  defp forced_cut(text, window, min_chars) do
    cond do
      String.length(text) <= String.length(window) ->
        :wait

      not fence_balanced?(window) ->
        :wait

      true ->
        {:block, String.trim(cut_at_newline(window, min_chars)),
         forced_consumed(window, min_chars)}
    end
  end

  defp cut_at_newline(window, min_chars) do
    case last_newline_at(window, min_chars) do
      nil -> window
      pos -> binary_part(window, 0, pos)
    end
  end

  defp forced_consumed(window, min_chars) do
    case last_newline_at(window, min_chars) do
      nil -> byte_size(window)
      pos -> pos + 1
    end
  end

  defp last_newline_at(window, min_chars) do
    window
    |> :binary.matches("\n")
    |> Enum.reverse()
    |> Enum.find_value(fn {pos, _len} -> if pos >= min_chars, do: pos end)
  end

  defp fence_balanced?(text) do
    text |> :binary.matches("```") |> length() |> rem(2) == 0
  end

  defp reset_idle_timer(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle_flush, state.idle_ms)}
  end

  # -- Timers --

  defp ensure_timer(%{timer_ref: nil} = state) do
    delay = max(state.interval_ms - elapsed_ms(state), 0)
    %{state | timer_ref: Process.send_after(self(), :flush_tick, delay)}
  end

  defp ensure_timer(state), do: state

  defp cancel_timers(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | timer_ref: nil, idle_ref: nil}
  end

  defp elapsed_ms(state), do: monotonic_ms() - state.last_write_at

  # -- Terminal transitions (each ends the process) --

  defp handle_seal(state, final_text, from, ref) do
    state = cancel_timers(state)
    {reply, status} = do_seal(state, final_text)
    emit(state, :seal, stop_measurements(state), status)
    send(from, {ref, reply})
    :ok
  end

  # Block-mode seal: nothing to edit — return the un-streamed tail for normal
  # delivery. Sent blocks must be a prefix of the final response (they were cut
  # from the same cumulative text); if they aren't, deliver the response in
  # full rather than risk a corrupt tail.
  defp do_seal(%{spec: %Spec{mode: :block}, sent_upto: 0}, _final_text),
    do: {{:ok, :no_draft}, :ok}

  defp do_seal(%{spec: %Spec{mode: :block}} = state, final_text) do
    consumed = min(state.sent_upto, byte_size(state.buffer))
    prefix = binary_part(state.buffer, 0, consumed)

    if String.starts_with?(final_text, prefix) do
      tail =
        final_text
        |> binary_part(byte_size(prefix), byte_size(final_text) - byte_size(prefix))
        |> String.trim()

      {{:ok, if(tail == "", do: nil, else: tail)}, :ok}
    else
      Logger.warning(
        "DraftStream block seal (#{state.spec.channel}): streamed blocks are not a prefix " <>
          "of the final response; delivering it in full"
      )

      {{:ok, :no_draft}, :ok}
    end
  end

  defp do_seal(%{phase: :idle}, _final_text), do: {{:ok, :no_draft}, :ok}

  # No-op seal (design §5.7): the last successful write already holds exactly
  # the final text — calling the channel again would be an idempotent no-op
  # the platform may reject ("message is not modified").
  defp do_seal(%{last_sent: text}, text), do: {{:ok, nil}, :ok}

  defp do_seal(%{phase: :live} = state, final_text) do
    case state.spec.seal.(state.handle, final_text) do
      {:ok, overflow} ->
        {{:ok, overflow}, :ok}

      {:error, reason} ->
        Logger.error("DraftStream seal failed (#{state.spec.channel}): #{inspect(reason)}")
        best_effort_discard(state)
        {{:error, reason}, :error}
    end
  end

  defp handle_discard(state, from, ref) do
    state = cancel_timers(state)
    best_effort_discard(state)
    emit(state, :discard, stop_measurements(state), :ok)
    send(from, {ref, :ok})
    :ok
  end

  # The turn task died (`/stop` sends :shutdown through the link; crashes
  # propagate too). Trap-exit is what makes draft cleanup reachable at all —
  # a killed task never runs its own `after` blocks.
  defp handle_parent_exit(state, reason) do
    state = cancel_timers(state)
    best_effort_discard(state)
    emit(state, :discard, stop_measurements(state), :ok)
    exit(reason)
  end

  defp best_effort_discard(%{phase: :live} = state) do
    case state.spec.discard.(state.handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("DraftStream discard failed (#{state.spec.channel}): #{inspect(reason)}")
        :ok
    end
  end

  defp best_effort_discard(_state), do: :ok

  # -- Telemetry + trace --

  defp emit(state, phase, measurements, status) do
    :telemetry.execute(
      [:fermix, :channel, :stream],
      measurements,
      %{
        channel: state.spec.channel,
        session_id: state.session_id,
        phase: phase,
        status: status
      }
    )

    trace_stream_phase(state, phase, measurements)
  end

  # JSONL trace bookends for the draft lifecycle (interim edits are telemetry-only).
  defp trace_stream_phase(state, :open, measurements) do
    FermixCore.Trace.record(:agent_event, "main", %{
      event: :stream_started,
      channel: state.spec.channel,
      session_id: state.session_id,
      ttfd_ms: measurements.ttfd_ms
    })
  end

  defp trace_stream_phase(state, phase, measurements) when phase in [:seal, :discard] do
    FermixCore.Trace.record(:agent_event, "main", %{
      event: :stream_finalized,
      outcome: phase,
      channel: state.spec.channel,
      session_id: state.session_id,
      total_edits: measurements.total_edits,
      dropped_snapshots: measurements.dropped_snapshots
    })
  end

  defp trace_stream_phase(_state, _phase, _measurements), do: :ok

  defp stop_measurements(state) do
    %{total_edits: state.write_count, dropped_snapshots: state.dropped}
  end

  # -- Sync call plumbing (monitor/ack, mirroring Typing.stop_typing_loop) --

  defp sync(pid, message, timeout) do
    ref = Process.monitor(pid)
    send(pid, {message, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:draft_stream_down, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        kill_wedged(pid)
        {:error, :draft_stream_timeout}
    end
  end

  # A wedged engine (stuck in a channel call) is unlinked before the kill so
  # the untrappable exit can't ricochet into the calling turn task.
  defp kill_wedged(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp timed_us(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - start}
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
