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

  The engine never sees a channel module. It drives the closures in
  `DraftStream.Spec` — including the channel's own length measurer, which is how
  rotation stays channel-blind — built by the gateway where the channel module
  and inbound message both exist. A test greps this file to keep platform-isms
  out.

  Lifecycle: `push/2` feeds `FermixCore.AgentLoop.stream_event()`s;
  `seal/2` performs the final reliable write from the authoritative turn
  response; `discard/1` deletes the draft. The engine traps exits so a
  killed turn task (`/stop` sends `:shutdown` through the link) still
  triggers a best-effort discard — no orphaned drafts on cancellation.
  """

  require Logger

  alias FermixChannels.Outbound.Splitter
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

    `measure`/`rotate_at` are the draft-rotation pair
    (CHANNEL_LONGFORM_PRESENTATION §6): the channel's rendered-length measurer
    and the card size at which the live bubble is sealed and a fresh one opened,
    so a long answer lands as section-shaped cards instead of freezing at the
    platform limit. Both or neither — a threshold with no way to measure against
    it (or the reverse) is a half-wired spec, so it is refused where the spec is
    built. Unset, the draft freezes at the channel's own limit (pre-S2 behavior).

    `ephemeral_send`/`delete` are the optional thought-sweep pair
    (CHANNEL_LONGFORM_PRESENTATION §5, decision §9.1): a silent send that
    answers with the platform ids of the messages it created, and a delete for
    those ids. `ephemeral_send` requires `delete` — a channel that can post
    thoughts but not remove them would leave permanent residue, so a half-wired
    spec is refused. This is the **delete-only channel tier** (design §6): a
    channel that can delete but cannot edit in place. A draft-capable channel
    never uses it — it gets the rolling status bubble instead.
    """

    @enforce_keys [:channel]
    defstruct [
      :channel,
      :open,
      :edit,
      :seal,
      :discard,
      :send,
      :ephemeral_send,
      :delete,
      :measure,
      :rotate_at,
      mode: :draft
    ]

    @type t :: %__MODULE__{
            channel: String.t(),
            mode: :draft | :block,
            open: (String.t() -> {:ok, term()} | {:error, term()}) | nil,
            edit: (term(), String.t() -> :ok | {:error, term()}) | nil,
            seal: (term(), String.t() -> {:ok, String.t() | nil} | {:error, term()}) | nil,
            discard: (term() -> :ok | {:error, term()}) | nil,
            send: (String.t() -> :ok | {:error, term()}) | nil,
            ephemeral_send: (String.t() -> {:ok, [term()]} | {:error, term()}) | nil,
            delete: (term() -> :ok | {:error, term()}) | nil,
            measure: (String.t() -> non_neg_integer()) | nil,
            rotate_at: pos_integer() | nil
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

  `opts` carries the rotation pair the gateway resolved from the channel:
  `:measure` (rendered-length measurer) and `:rotate_at` (card size). Omitted,
  the draft freezes at the channel's own limit instead of rotating.
  """
  @spec build_spec(module(), struct(), keyword()) :: Spec.t()
  def build_spec(channel, %{channel: channel_name} = message, opts \\ [])
      when is_atom(channel) and is_list(opts) do
    %Spec{
      channel: channel_name,
      mode: :draft,
      open: fn text -> channel.open_draft(message, text) end,
      edit: fn handle, text -> channel.edit_draft(message, handle, text) end,
      seal: fn handle, text -> channel.seal_draft(message, handle, text) end,
      discard: fn handle -> channel.discard_draft(message, handle) end,
      measure: Keyword.get(opts, :measure),
      rotate_at: Keyword.get(opts, :rotate_at)
    }
  end

  @doc """
  Build a block-mode spec: completed chunks go out as ordinary sends through
  the supplied closure (typically the gateway's reply closure). No draft
  callbacks needed, so any channel qualifies.

  `opts` carries the optional thought-sweep pair — `:ephemeral_send` and
  `:delete` — which the gateway supplies only for a channel that can both send
  silently and delete. Omitted (or nil), the engine drops thought blocks
  entirely rather than posting undeletable ones.
  """
  @spec build_block_spec(String.t(), (String.t() -> :ok | {:error, term()}), keyword()) ::
          Spec.t()
  def build_block_spec(channel_name, send_fn, opts \\ [])
      when is_binary(channel_name) and is_function(send_fn, 1) and is_list(opts) do
    spec = %Spec{
      channel: channel_name,
      mode: :block,
      send: send_fn,
      ephemeral_send: Keyword.get(opts, :ephemeral_send),
      delete: Keyword.get(opts, :delete)
    }

    assert_thought_sweep!(spec)
    spec
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
    assert_rotation!(spec)
  end

  defp assert_spec!(%Spec{mode: :block} = spec) do
    is_function(spec.send, 1) || raise ArgumentError, "block-mode spec requires a send closure"
    assert_rotation!(spec)
    assert_thought_sweep!(spec)
  end

  # Rotation is all-or-none: a threshold with no measurer (or a measurer with no
  # threshold) is a spec that silently never rotates, which is exactly the class
  # of half-wired failure this engine refuses at build time.
  defp assert_rotation!(%Spec{measure: nil, rotate_at: nil}), do: :ok

  defp assert_rotation!(%Spec{measure: measure, rotate_at: rotate_at})
       when is_function(measure, 1) and is_integer(rotate_at) and rotate_at > 0,
       do: :ok

  defp assert_rotation!(_spec) do
    raise ArgumentError,
          "draft rotation requires both a measure closure and a positive rotate_at"
  end

  # Thoughts are ephemeral or absent (decision §9.1): a spec that can post them
  # but not remove them would leave permanent residue in the chat, so a
  # half-wired pair fails loud where the spec is built, not mid-turn.
  defp assert_thought_sweep!(%Spec{ephemeral_send: nil}), do: :ok

  defp assert_thought_sweep!(%Spec{ephemeral_send: send_fn, delete: delete_fn})
       when is_function(send_fn, 1) and is_function(delete_fn, 1),
       do: :ok

  defp assert_thought_sweep!(_spec) do
    raise ArgumentError, "thought sweep requires both ephemeral_send and delete closures"
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
      # Draft mode: byte offset into the buffer already sealed into finished
      # bubbles by rotation. Every open/edit renders the buffer from here on.
      sealed_upto: 0,
      # Refused rotation seals this turn; at the cap the engine stops rotating.
      rotate_failures: 0,
      # Draft mode: the rolling 💭 status bubble (its own draft) and the rolling
      # window of reasoning headings it shows.
      status_handle: nil,
      status_text: nil,
      status_headings: [],
      # Block mode: a completed message item is pending full flush (the
      # semantic boundary — flush regardless of the chunk minimum).
      pending_done?: false,
      # Block mode: out-of-band messages (reasoning summaries) awaiting send.
      side_queue: [],
      # Block mode: platform ids of every ephemeral thought message sent this
      # turn, swept at seal/discard.
      thought_ids: [],
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
    state
    |> seal_live_on_reset()
    |> Map.merge(%{buffer: "", dirty?: false, sent_upto: 0, pending_done?: false})
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

  # The model's decision-making summary — headings only, the full body is too
  # noisy for chat. Block mode sends each drain as its own 💭 message (the
  # OpenClaw-on-Signal behavior, swept at the end of the turn); draft mode edits
  # them into ONE rolling 💭 status bubble that is deleted when the answer lands
  # (CHANNEL_LONGFORM_PRESENTATION §6). Either way the heading only gets queued
  # here — the write happens on a tick no answer content claimed.
  defp apply_event(state, {:reasoning_done, text}) when is_binary(text) do
    queue_side_block(state, text |> String.trim() |> reasoning_heading())
  end

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
      true -> flush_block_tick(state)
    end
  end

  # Draft-mode tick priority (design §6): answer content first, then rotation
  # (inside do_flush, on the write it just made), then the 💭 status bubble —
  # which therefore only ever writes on a tick the answer had nothing to say.
  defp maybe_flush(state) do
    cond do
      frozen?(state) -> state
      flushable?(state) -> paced(state, &do_flush/1)
      status_pending?(state) -> paced(state, &flush_status/1)
      true -> state
    end
  end

  defp paced(state, write_fun) when is_function(write_fun, 1) do
    if elapsed_ms(state) >= state.interval_ms do
      write_fun.(state)
    else
      ensure_timer(state)
    end
  end

  # A SUCCESSFUL write can leave work behind — the remainder a rotation just
  # detached, or a thought the answer outranked this tick — and nothing else
  # would wake the engine until the next delta, which may never arrive. Only
  # `mark_written` calls this, so a failed interim write is still never retried
  # (best-effort by contract); block mode keeps its own timer discipline.
  # Converges: each scheduled tick either writes (clearing the condition), is
  # throttled (the timer already exists), or freezes.
  defp ensure_pending_timer(%{spec: %Spec{mode: :block}} = state), do: state

  defp ensure_pending_timer(state) do
    if not frozen?(state) and (flushable?(state) or status_pending?(state)) do
      ensure_timer(state)
    else
      state
    end
  end

  defp frozen?(state) do
    state.failures >= @max_consecutive_failures or state.write_count >= state.max_edits
  end

  # Measured on the LIVE slice (everything after the last rotation seal), never
  # on the whole buffer: sealed bubbles are finished messages the engine must
  # not re-render.
  defp flushable?(state) do
    live = live_text(state)

    live != "" and live != state.last_sent and
      (state.phase == :live or String.length(live) >= state.min_chars)
  end

  defp do_flush(%{phase: :idle} = state) do
    live = live_text(state)
    {result, duration_us} = timed_us(fn -> state.spec.open.(live) end)

    case result do
      {:ok, handle} ->
        emit_write(state, :edit, %{duration_us: duration_us, edit_index: state.write_count + 1})

        %{state | phase: :live, handle: handle, last_sent: live}
        |> mark_written()
        |> maybe_rotate()

      {:error, reason} ->
        note_failure(state, :open, reason)
    end
  end

  defp do_flush(%{phase: :live} = state) do
    live = live_text(state)
    {result, duration_us} = timed_us(fn -> state.spec.edit.(state.handle, live) end)

    case result do
      :ok ->
        emit_write(state, :edit, %{duration_us: duration_us, edit_index: state.write_count + 1})
        %{state | last_sent: live} |> mark_written() |> maybe_rotate()

      {:error, reason} ->
        note_failure(state, :edit, reason)
    end
  end

  defp mark_written(state) do
    ensure_pending_timer(%{
      state
      | dirty?: false,
        last_write_at: monotonic_ms(),
        write_count: state.write_count + 1,
        failures: 0
    })
  end

  # Interim writes are best-effort by contract: log, count, never retry. At
  # @max_consecutive_failures the preview freezes; seal (the reliable write)
  # still runs at turn end.
  defp note_failure(state, op, reason) do
    Logger.warning("DraftStream #{op} failed (#{state.spec.channel}): #{inspect(reason)}")
    %{state | failures: state.failures + 1, last_write_at: monotonic_ms()}
  end

  # -- Draft rotation (CHANNEL_LONGFORM_PRESENTATION §6) --

  # After each successful write: if the live slice has grown past one card AND
  # the boundary falls strictly inside it (more content is still streaming),
  # seal the live bubble at that boundary and detach — the next flush opens a
  # fresh bubble with the remainder. A spec without the rotation pair never
  # rotates and the draft freezes at the channel's own limit instead.
  defp maybe_rotate(%{spec: %Spec{rotate_at: nil}} = state), do: state

  # Defined cap behavior: after @max_consecutive_failures refused rotation seals
  # in a turn, stop asking. The draft degrades to the freeze-at-limit shape and
  # the turn-end seal still lands — better than re-hitting a refusing API on
  # every tick for the rest of the turn.
  defp maybe_rotate(%{rotate_failures: failures} = state)
       when failures >= @max_consecutive_failures,
       do: state

  # The rotation seal is itself a write: once the budget is spent, rotating
  # would overrun max_edits by one. Freeze instead — same bound frozen?
  # enforces at tick entry.
  defp maybe_rotate(%{write_count: writes, max_edits: cap} = state) when writes >= cap,
    do: state

  defp maybe_rotate(state) do
    live = live_text(state)

    case Splitter.first_chunk(live, limit: state.spec.rotate_at, measure: state.spec.measure) do
      {:chunk, chunk, consumed} -> rotate_if_inside(state, live, chunk, consumed)
      :fits -> state
    end
  end

  defp rotate_if_inside(state, live, chunk, consumed) do
    if chunk != "" and consumed < byte_size(live) do
      seal_rotation(state, chunk, consumed)
    else
      state
    end
  end

  # The rotation seal is an interim write by the same contract as an edit: a
  # failure is logged and counted (two in a row freeze the preview), never
  # retried. The turn-end seal remains the one reliable write.
  defp seal_rotation(state, chunk, consumed) do
    {result, duration_us} = timed_us(fn -> rotation_seal_call(state, chunk) end)

    case result do
      {:ok, _overflow} ->
        emit(state, :rotate, %{duration_us: duration_us, edit_index: state.write_count + 1}, :ok)
        mark_written(detach_bubble(state, consumed))

      {:error, reason} ->
        state = note_failure(state, :rotate, reason)
        %{state | rotate_failures: state.rotate_failures + 1}
    end
  end

  # The bubble already shows exactly this text (the write that triggered the
  # rotation landed on a chunk boundary), so re-sending it would be an
  # idempotent no-op the platform may reject.
  defp rotation_seal_call(%{last_sent: chunk} = _state, chunk), do: {:ok, nil}
  defp rotation_seal_call(state, chunk), do: state.spec.seal.(state.handle, chunk)

  defp detach_bubble(state, consumed) do
    %{
      state
      | phase: :idle,
        handle: nil,
        last_sent: nil,
        sealed_upto: state.sealed_upto + consumed
    }
  end

  # Per-iteration reset with rotation wired: the live bubble stands as
  # commentary (mirroring block mode's "sent blocks stand") — seal it as-is,
  # then the new iteration starts its own bubble from offset zero.
  defp seal_live_on_reset(%{spec: %Spec{rotate_at: nil}} = state), do: state
  defp seal_live_on_reset(%{phase: :idle} = state), do: %{state | sealed_upto: 0}

  defp seal_live_on_reset(state) do
    case live_text(state) do
      # A mid-stream provider retry can shrink the buffer below the sealed
      # offset: there is nothing to seal, so the bubble stands with the text it
      # already shows and the new iteration starts fresh.
      "" -> state |> detach_bubble(0) |> reset_sealed()
      live -> commit_reset_seal(state, live)
    end
  end

  # The iteration seal is a real channel write — phase-visible like every
  # other write (:edit / :rotate / :seal), so no write is invisible to the
  # stream trace. :rotate fits: a seal-as-commentary is a rotation-shaped
  # non-terminal write.
  defp commit_reset_seal(state, live) do
    {result, duration_us} = timed_us(fn -> rotation_seal_call(state, live) end)

    case result do
      {:ok, _overflow} ->
        emit(state, :rotate, %{duration_us: duration_us, edit_index: state.write_count + 1}, :ok)
        state |> detach_bubble(0) |> reset_sealed() |> mark_written()

      {:error, reason} ->
        state |> detach_bubble(0) |> reset_sealed() |> reset_failure(reason)
    end
  end

  defp reset_sealed(state), do: %{state | sealed_upto: 0}

  defp reset_failure(state, reason) do
    Logger.warning(
      "DraftStream iteration seal failed (#{state.spec.channel}): #{inspect(reason)}"
    )

    %{state | failures: state.failures + 1}
  end

  # -- Block-mode emission --

  # One tick emits at most one chunk; the paced timer picks up the next. Answer
  # text wins the tick (design §5): the thought queue drains only when no
  # answer block is ready, so a side message can never land between an
  # already-streamed paragraph and its continuation.
  defp flush_block_tick(state) do
    case take_block(state) do
      {:block, text, consumed, state} -> send_block(state, text, consumed)
      {:none, state} -> drain_side_queue(state)
    end
  end

  # A pending completed item (:text_done) is the semantic boundary: it beats the
  # chunk minimum. The remainder goes out whole when it fits one message;
  # otherwise the cut follows `next_block`'s boundary preference (paragraph,
  # then newline) rather than a blind max-length slice.
  defp take_block(%{pending_done?: true} = state) do
    remainder = state |> unsent() |> String.trim()

    cond do
      remainder == "" ->
        {:none, %{state | pending_done?: false}}

      String.length(remainder) <= state.block_max ->
        {:block, remainder, unsent_size(state), state}

      true ->
        done_tail_block(state, remainder)
    end
  end

  defp take_block(state) do
    case next_block(unsent(state), state.block_min, state.block_max) do
      {:block, text, consumed} -> {:block, text, consumed, state}
      :wait -> {:none, state}
    end
  end

  # Over-max remainder at a completed item. `next_block` returns `:wait` here
  # only for a fence-unbalanced window, and a completed item must never wedge
  # until seal — so the whole trimmed remainder goes as ONE send. The channel
  # adapter ladder-splits oversized text safely (S0), so this cannot exceed a
  # platform limit.
  defp done_tail_block(state, remainder) do
    case next_block(unsent(state), state.block_min, state.block_max) do
      {:block, text, consumed} -> {:block, text, consumed, state}
      :wait -> {:block, remainder, unsent_size(state), state}
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

  # Every thought message must stay deletable, so the turn's whole thought
  # stream is capped too: past this many sent messages the stream stops rather
  # than growing a sweep list without an end.
  @max_thought_ids 64

  # -- Rolling 💭 status bubble (draft mode, CHANNEL_LONGFORM_PRESENTATION §6) --

  # The status bubble is a rolling window of the LATEST headings, so its text
  # must stay one short bubble: the oldest headings are dropped (a leading "…"
  # marks the trim) until the join fits one card. The newest heading is kept
  # even if it alone exceeds that — `reasoning_heading/1` caps a heading at
  # @reasoning_heading_max graphemes, so the floor is unreachable in practice,
  # and a status bubble is disposable meta that is deleted at turn end anyway.
  @status_limit_units 1_000
  @max_status_headings 16

  defp status_pending?(%{spec: %Spec{mode: :draft}} = state), do: state.side_queue != []
  defp status_pending?(_state), do: false

  defp flush_status(state) do
    headings = Enum.take(state.status_headings ++ state.side_queue, -@max_status_headings)
    text = status_bubble_text(state, headings)
    state = %{state | status_headings: headings, side_queue: []}

    if text == state.status_text, do: state, else: write_status(state, text)
  end

  defp write_status(%{status_handle: nil} = state, text) do
    {result, duration_us} = timed_us(fn -> state.spec.open.(text) end)

    case result do
      {:ok, handle} ->
        emit_write(state, :edit, %{duration_us: duration_us, edit_index: state.write_count + 1})
        mark_written(%{state | status_handle: handle, status_text: text})

      {:error, reason} ->
        note_failure(state, :status_open, reason)
    end
  end

  defp write_status(state, text) do
    {result, duration_us} = timed_us(fn -> state.spec.edit.(state.status_handle, text) end)

    case result do
      :ok ->
        emit_write(state, :edit, %{duration_us: duration_us, edit_index: state.write_count + 1})
        mark_written(%{state | status_text: text})

      {:error, reason} ->
        note_failure(state, :status_edit, reason)
    end
  end

  # Candidates from the widest (every heading) to the narrowest (only the
  # newest); the first that fits the card wins, the last one is the floor.
  defp status_bubble_text(state, headings) do
    limit = state.spec.rotate_at || @status_limit_units
    measure = state.spec.measure || (&String.length/1)
    candidates = Enum.map(0..(length(headings) - 1), &status_candidate(headings, &1))

    Enum.find(candidates, List.last(candidates), fn text -> measure.(text) <= limit end)
  end

  defp status_candidate(headings, 0), do: "💭 " <> Enum.join(headings, "\n")

  defp status_candidate(headings, drop) do
    "💭 …\n" <> (headings |> Enum.drop(drop) |> Enum.join("\n"))
  end

  # The status bubble is a draft, not a sent message: `discard` deletes it.
  # Best-effort like every other sweep write — a leftover bubble is cosmetic and
  # must never touch the seal/discard result.
  defp discard_status(%{status_handle: nil}), do: :ok

  defp discard_status(state) do
    case state.spec.discard.(state.status_handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "DraftStream status sweep failed (#{state.spec.channel}): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp queue_side_block(state, ""), do: state

  defp queue_side_block(state, text) when length(state.side_queue) >= @max_side_blocks do
    Logger.warning("DraftStream dropping side block beyond cap: #{String.slice(text, 0, 60)}")
    state
  end

  defp queue_side_block(state, text) do
    %{state | side_queue: state.side_queue ++ [text]}
  end

  defp drain_side_queue(%{side_queue: []} = state), do: state
  defp drain_side_queue(state), do: send_side_block(state)

  # Decision §9.2: a channel that cannot delete gets no thought stream at all.
  # Deliberately NOT a fallback to the ordinary send — an undeletable 💭 message
  # is exactly the residue the design removes.
  defp send_side_block(%{spec: %Spec{ephemeral_send: nil}} = state) do
    %{state | side_queue: []}
  end

  defp send_side_block(state) when length(state.thought_ids) >= @max_thought_ids do
    Logger.warning(
      "DraftStream thought stream capped at #{@max_thought_ids} messages; dropping the rest"
    )

    %{state | side_queue: []}
  end

  # The whole queue drains as ONE silent message: one 💭 prefix, one line per
  # queued heading. Truncated (never split) at the chunk ceiling — thoughts are
  # disposable meta, so an overlong join loses its tail rather than costing a
  # second message the sweep would have to track.
  defp send_side_block(state) do
    text = truncate("💭 " <> Enum.join(state.side_queue, "\n"), state.block_max)
    {result, duration_us} = timed_us(fn -> state.spec.ephemeral_send.(text) end)

    case result do
      {:ok, ids} when is_list(ids) ->
        emit_block_telemetry(state, duration_us)
        state = %{mark_written(state) | side_queue: [], thought_ids: state.thought_ids ++ ids}
        ensure_timer(state)

      {:error, reason} ->
        # A failed side block is dropped (logged) — it's commentary, not the
        # answer; the answer path has its own failure handling.
        note_failure(%{state | side_queue: []}, :block, reason)
    end
  end

  # Best-effort sweep of everything ephemeral this turn produced: the rolling
  # status bubble (draft mode) and every 💭 message id (block mode). Failures are
  # logged and never retried — leftovers are cosmetic and must not touch the
  # seal/discard result.
  defp sweep_ephemera(state) do
    discard_status(state)
    sweep_thoughts(state)
  end

  defp sweep_thoughts(%{thought_ids: []}), do: :ok

  defp sweep_thoughts(state) do
    Enum.each(state.thought_ids, fn id -> delete_thought(state, id) end)
  end

  defp delete_thought(state, id) do
    case state.spec.delete.(id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "DraftStream thought sweep failed (#{state.spec.channel}) for #{inspect(id)}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp emit_block_telemetry(state, duration_us) do
    emit_write(state, :block, %{duration_us: duration_us, block_index: state.write_count + 1})
  end

  # The stream's first successful write is its `:open` bookend (it carries
  # ttfd_ms); every later write reports its own phase. A rotation's fresh bubble
  # is therefore an interim write, not a second stream open.
  defp emit_write(%{write_count: 0} = state, _phase, _measurements) do
    emit(state, :open, %{ttfd_ms: monotonic_ms() - state.started_at}, :ok)
  end

  defp emit_write(state, phase, measurements), do: emit(state, phase, measurements, :ok)

  # An idle lull (no deltas for idle_ms) flushes the fence-balanced unsent text
  # even below the chunk minimum — this is how pre-tool commentary becomes its
  # own message instead of waiting for the turn to end.
  # Same priority as a paced tick: answer text first, thoughts only when there
  # is no flushable answer text.
  defp idle_flush(%{spec: %Spec{mode: :block}} = state) do
    if frozen?(state), do: state, else: idle_emit(state)
  end

  defp idle_flush(state), do: state

  defp idle_emit(state) do
    window = state |> unsent() |> String.slice(0, state.block_max)
    text = String.trim(window)

    if text == "" or not fence_balanced?(window) do
      drain_side_queue(state)
    else
      send_block(state, text, byte_size(window))
    end
  end

  # A mid-stream provider retry restarts the SSE cumulative from empty
  # (HttpClient retries a dropped connection with a fresh parser), so the
  # buffer can be SHORTER than the consumed offset — clamp, never crash.
  # Emission resumes once the retried stream regrows past the offset; the
  # seal prefix-check guarantees the final reply is correct either way.
  defp unsent(state), do: slice_from(state.buffer, state.sent_upto)

  defp unsent_size(state), do: byte_size(unsent(state))

  # Draft mode's live slice: everything after the last rotation seal. Same clamp
  # and same reason as `unsent/1`.
  defp live_text(state), do: slice_from(state.buffer, state.sealed_upto)

  defp slice_from(buffer, offset) do
    start = min(offset, byte_size(buffer))
    binary_part(buffer, start, byte_size(buffer) - start)
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
    # After the reply, deliberately: the sweep is N synchronous deletes, and
    # run before the send it can outlast the caller's seal sync window —
    # converting a successful seal into :draft_stream_timeout and a duplicate
    # full-reply delivery. Post-reply, a slow delete only delays process exit.
    sweep_ephemera(state)
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
      {{:ok, blank_to_nil(tail_after(final_text, prefix))}, :ok}
    else
      Logger.warning(
        "DraftStream block seal (#{state.spec.channel}): streamed blocks are not a prefix " <>
          "of the final response; delivering it in full"
      )

      {{:ok, :no_draft}, :ok}
    end
  end

  # Draft mode after at least one rotation: the sealed bubbles already carry the
  # answer's prefix, so only the tail may still be written. Same prefix check
  # (and the same clamp for a mid-stream provider retry) as the block path.
  defp do_seal(%{sealed_upto: sealed} = state, final_text) when sealed > 0 do
    consumed = min(state.sealed_upto, byte_size(state.buffer))
    prefix = binary_part(state.buffer, 0, consumed)

    if String.starts_with?(final_text, prefix) do
      seal_tail(state, tail_after(final_text, prefix))
    else
      seal_prefix_mismatch(state)
    end
  end

  defp do_seal(%{phase: :idle}, _final_text), do: {{:ok, :no_draft}, :ok}

  # No-op seal (design §5.7): the last successful write already holds exactly
  # the final text — calling the channel again would be an idempotent no-op
  # the platform may reject ("message is not modified").
  defp do_seal(%{last_sent: text}, text), do: {{:ok, nil}, :ok}

  defp do_seal(%{phase: :live} = state, final_text), do: seal_live(state, final_text)

  # No live bubble (the last rotation detached it): everything after the sealed
  # prefix goes out through the queue's normal chunked delivery.
  defp seal_tail(%{phase: :idle}, tail), do: {{:ok, blank_to_nil(tail)}, :ok}

  # The final response stops at the sealed prefix, so whatever the live bubble
  # holds is not part of the answer — remove it rather than leave stale text.
  defp seal_tail(state, "") do
    best_effort_discard(state)
    {{:ok, nil}, :ok}
  end

  # The tail seals into the live bubble whole when the channel can hold it; a
  # tail too big for one message comes back as the channel's overflow remainder
  # for normal delivery. This is what absorbs a tiny post-completion remainder
  # into the last card instead of ringing a second message for it.
  defp seal_tail(state, tail), do: seal_live(state, tail)

  defp seal_live(state, text) do
    case state.spec.seal.(state.handle, text) do
      {:ok, overflow} ->
        {{:ok, overflow}, :ok}

      {:error, reason} ->
        Logger.error("DraftStream seal failed (#{state.spec.channel}): #{inspect(reason)}")
        best_effort_discard(state)
        {{:error, reason}, :error}
    end
  end

  # Same posture as the block path: the streamed text is not a prefix of the
  # authoritative response (a mid-stream provider retry rewrote it), so deliver
  # the response in full. The unsealed live bubble holds text the answer never
  # confirmed and is discarded; sealed bubbles stand, exactly as sent blocks do.
  defp seal_prefix_mismatch(state) do
    Logger.warning(
      "DraftStream rotated seal (#{state.spec.channel}): sealed bubbles are not a prefix " <>
        "of the final response; delivering it in full"
    )

    best_effort_discard(state)
    {{:ok, :no_draft}, :ok}
  end

  defp tail_after(final_text, prefix) do
    final_text
    |> binary_part(byte_size(prefix), byte_size(final_text) - byte_size(prefix))
    |> String.trim()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp handle_discard(state, from, ref) do
    state = cancel_timers(state)
    best_effort_discard(state)
    emit(state, :discard, stop_measurements(state), :ok)
    send(from, {ref, :ok})
    # Post-reply for the same reason as handle_seal: deletes must not delay
    # the caller past its sync window.
    sweep_ephemera(state)
    :ok
  end

  # The turn task died (`/stop` sends :shutdown through the link; crashes
  # propagate too). Trap-exit is what makes draft cleanup reachable at all —
  # a killed task never runs its own `after` blocks.
  defp handle_parent_exit(state, reason) do
    state = cancel_timers(state)
    best_effort_discard(state)
    sweep_ephemera(state)
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
