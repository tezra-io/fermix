defmodule FermixOpik.Aggregation do
  @moduledoc """
  Reassembles Fermix telemetry into Opik traces — the pure core, with no I/O.

  One Opik **trace** is one top-level run: a main agent turn, or one scheduled
  job run. Within it, every run (the turn itself, each subagent, each scheduled
  job) becomes a `general` wrapper span; every LLM call becomes an `llm` span and
  every tool call a `tool` span, parented to its run's wrapper. Runs are linked
  by Fermix's `session_id`/`parent_session`, so a subagent's work nests under the
  delegating turn.

  `apply_event/4` folds one event into the state and returns any traces that just
  closed (root run finished). `sweep/2` force-closes traces whose root never
  signalled completion, so nothing leaks. This module is deliberately pure: the
  `Aggregator` GenServer wraps it for live use, and `Mix.Tasks.Opik.Replay`
  drives the same logic over JSONL files.
  """

  alias FermixOpik.Mapper

  # Grace added to a scheduled run's max duration before the sweep force-closes
  # it: the run's watchdog fires `run_error`/timeout at the cap and closes the
  # trace through the normal path, so the duration-based sweep only acts as a
  # backstop for a run that died without signalling (e.g. daemon restart).
  @sweep_grace_ms 60_000

  @enforce_keys [:project, :ttl_ms]
  defstruct project: nil, ttl_ms: 120_000, traces: %{}, sessions: %{}

  @type closed :: %{trace: map(), spans: [map()]}
  @type at :: %{at: DateTime.t(), mono: integer()}

  @spec new(keyword()) :: %__MODULE__{}
  def new(opts) do
    %__MODULE__{
      project: Keyword.fetch!(opts, :project),
      ttl_ms: Keyword.get(opts, :ttl_ms, 120_000)
    }
  end

  @doc """
  Fold one telemetry event into the state.

  Returns `{state, closed}` where `closed` is a (possibly empty) list of traces
  whose root run just finished and are ready to ship.
  """
  @spec apply_event(%__MODULE__{}, [atom()], map(), map(), at()) :: {%__MODULE__{}, [closed()]}
  def apply_event(state, event, measurements, metadata, at)

  def apply_event(state, [:fermix, :provider, :call], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.llm_span(meta, meas, &1))
  end

  # Provider failover ([:fermix, :provider, :failover]): one point span per
  # transition, child of the turn's trace via the shared session_id.
  def apply_event(state, [:fermix, :provider, :failover], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.failover_span(meta, meas, &1))
  end

  def apply_event(state, [:fermix, :tool, :exec], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.tool_span(meta, meas, &1))
  end

  # One durable memory write by the background reviewer — child of the
  # reviewer's run via the shared session_id, so a reviewer-driven persist is
  # an observable span. The event carries channel/chat_id, so place_under sets
  # the reviewer trace's thread_id to the conversation (the reviewer runs after
  # the turn closed and cannot nest into it; thread_id is how it correlates).
  def apply_event(state, [:fermix, :memory, :write], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.memory_write_span(meta, meas, &1))
  end

  # The reviewer's run closer. It carries the run session_id (shared with the
  # review's provider.call/memory.write spans) plus its op-count summary, so the
  # reviewer's root trace ships here with an output/status instead of only via the
  # exporter's TTL sweep. session_id is nil on a pre-call failure → close_root
  # no-ops (no root was ever opened). The run was tagged :memory_review when its
  # first span created the session (see infer_kind).
  def apply_event(state, [:fermix, :memory, :review], meas, meta, at) do
    close_root(state, meta, at, %{
      output:
        compact(%{
          status: stringify(Map.get(meta, :status)),
          added: Map.get(meas, :ops_added),
          replaced: Map.get(meas, :ops_replaced),
          archived: Map.get(meas, :ops_archived),
          skipped: Map.get(meas, :ops_skipped),
          input_messages: Map.get(meas, :input_messages)
        }),
      status: stringify(Map.get(meta, :status)),
      thread_id: thread_id(meta),
      metadata:
        compact(%{
          conversation_key: Map.get(meta, :conversation_key),
          channel: stringify(Map.get(meta, :channel)),
          chat_id: Map.get(meta, :chat_id),
          input_tokens: Map.get(meas, :input_tokens),
          duration_us: Map.get(meas, :duration_us)
        })
    })
  end

  def apply_event(state, [:fermix, :skill, :invoke], meas, meta, at) do
    # A skill invocation is a point event; model it as a tool-like span under the
    # invoking run (parent_session), named for the skill.
    meta = Map.put(meta, :tool, "skill:#{Map.get(meta, :skill, "skill")}")
    parent = Map.get(meta, :parent_session)
    place_under(state, parent, meta, at, &Mapper.tool_span(meta, meas, &1))
  end

  # Channel-stream lifecycle ([:fermix, :channel, :stream]): open/block/seal/
  # discard become child spans of the turn's trace via the shared session_id —
  # never a root run (the stream has no parent_session of its own). Interim
  # draft :edit phases are deliberately not exported: at ~1 edit/s they would
  # flood the trace; the seal span carries total_edits/dropped_snapshots
  # instead. :block phases (one per sent chunk, a handful per turn) export too,
  # but only while the run's session is still open (see below).
  def apply_event(state, [:fermix, :channel, :stream], meas, meta, at) do
    case Map.get(meta, :phase) do
      :open ->
        # :open fires on the first edit/block, always during the agent loop, so
        # the run's session is guaranteed open — safe to create the child span.
        add_child_span(state, meta, at, &Mapper.stream_span(meta, meas, &1))

      phase when phase in [:block, :seal, :discard] ->
        # These phases can arrive AFTER the turn's `agent.message` already closed
        # and shipped the trace: :seal/:discard fire just as the turn completes,
        # and in block streaming a paced :block edit (~1s throttle / idle flush)
        # can land after completion too. Creating a span here via `place_under`
        # would lazily resurrect a phantom empty trace — no input/output, no
        # thread (stream telemetry carries no chat_id) — that the sweep later
        # flushes to Opik. So attach only while the run's session is still open;
        # otherwise drop (the seal span already carries the aggregate counts).
        attach_if_open(state, meta, at, &Mapper.stream_span(meta, meas, &1))

      _other ->
        {state, []}
    end
  end

  def apply_event(state, [:fermix, :agent, start], _meas, meta, at)
      when start in [:start, :task_start] do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: Map.get(meta, :parent_session),
          kind: kind_from_role(Map.get(meta, :role)),
          name: Map.get(meta, :name),
          input: Map.get(meta, :task_summary),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  def apply_event(state, [:fermix, :agent, done], meas, meta, at)
      when done in [:stop, :task_complete] do
    finish_wrapper(state, Map.get(meta, :session_id), at, %{
      iterations: Map.get(meas, :iterations),
      success: Map.get(meta, :success)
    })
  end

  def apply_event(state, [:fermix, :agent, :message], meas, meta, at) do
    close_root(state, meta, at, %{
      input: Map.get(meta, :input),
      output: Map.get(meta, :output),
      status: "ok",
      thread_id: thread_id(meta),
      metadata:
        compact(%{
          channel: stringify(Map.get(meta, :channel)),
          chat_id: Map.get(meta, :chat_id),
          sender: Map.get(meta, :sender),
          iterations: Map.get(meas, :iterations),
          total_tokens: Map.get(meas, :total_tokens)
        })
    })
  end

  def apply_event(state, [:fermix, :agent, :message_error], _meas, meta, at) do
    close_root(state, meta, at, %{
      output: stringify(Map.get(meta, :reason)),
      status: "error",
      thread_id: thread_id(meta),
      metadata:
        compact(%{channel: stringify(Map.get(meta, :channel)), chat_id: Map.get(meta, :chat_id)})
    })
  end

  def apply_event(state, [:fermix, :job, :run_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: :scheduled,
          name: Map.get(meta, :name) || Map.get(meta, :agent),
          input: Map.get(meta, :input),
          thread_id: Map.get(meta, :job_id),
          max_duration_ms: Map.get(meta, :max_duration_ms),
          trace_metadata:
            compact(%{
              job_id: Map.get(meta, :job_id),
              run_id: Map.get(meta, :run_id),
              schedule_kind: Map.get(meta, :schedule_kind),
              schedule_expr: Map.get(meta, :schedule_expr),
              trigger: Map.get(meta, :trigger)
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  def apply_event(state, [:fermix, :job, run], _meas, meta, at)
      when run in [:run_complete, :run_error] do
    status = if run == :run_error, do: "error", else: Map.get(meta, :status, "ok")

    close_root(state, meta, at, %{
      output: Map.get(meta, :output) || Map.get(meta, :error),
      status: status,
      metadata: compact(%{job_id: Map.get(meta, :job_id), run_id: Map.get(meta, :run_id)})
    })
  end

  # A `/soul review` draft is a single bounded provider call minted with its own
  # `session_id` before any turn exists (see `SoulCuration.Telemetry`). run_start
  # opens its root trace; the provider.call span nests via the shared session_id;
  # run_complete/run_error close it. `parent_session` (the originating command)
  # is present when the draft was dispatched from a channel command.
  def apply_event(state, [:fermix, :soul_curation, :run_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: Map.get(meta, :parent_session),
          kind: :soul_curation,
          name: stringify(Map.get(meta, :mode)),
          input: Map.get(meta, :input),
          trace_metadata:
            compact(%{
              mode: stringify(Map.get(meta, :mode)),
              with_context: Map.get(meta, :with_context)
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  def apply_event(state, [:fermix, :soul_curation, run], _meas, meta, at)
      when run in [:run_complete, :run_error] do
    status = if run == :run_error, do: "error", else: Map.get(meta, :status, "ok")

    close_root(state, meta, at, %{
      output: Map.get(meta, :output) || Map.get(meta, :error),
      status: status,
      metadata:
        compact(%{
          mode: stringify(Map.get(meta, :mode)),
          route: Map.get(meta, :route),
          byte_delta: Map.get(meta, :byte_delta),
          line_delta: Map.get(meta, :line_delta),
          suspect: Map.get(meta, :suspect)
        })
    })
  end

  # Realtime voice runs on its own WebSocket session. call_start opens the root
  # trace (carrying model/voice/device); the model turn and tool calls reuse the
  # provider/tool spans and nest via the shared session_id; call_stop closes it.
  def apply_event(state, [:fermix, :realtime, :call_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: :realtime,
          name: nil,
          input: nil,
          trace_metadata:
            compact(%{
              device_id: Map.get(meta, :device_id),
              model: Map.get(meta, :model),
              voice: Map.get(meta, :voice),
              session_scope: Map.get(meta, :session_scope)
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  def apply_event(state, [:fermix, :realtime, phase], meas, meta, at)
      when phase in [:session_created, :session_updated, :provider_error, :reconnect] do
    add_child_span(
      state,
      meta,
      at,
      &Mapper.realtime_span(meta, meas, Keyword.put(&1, :phase, phase))
    )
  end

  # The call's accumulated audio usage rides as `call_stop` measurements; fold it
  # into the trace metadata so the realtime session's footprint survives at the
  # trace level (per-turn LLM spans still carry their own token usage).
  def apply_event(state, [:fermix, :realtime, :call_stop], meas, meta, at) do
    close_root(state, meta, at, %{
      status: "ok",
      metadata:
        compact(%{
          device_id: Map.get(meta, :device_id),
          model: Map.get(meta, :model),
          voice: Map.get(meta, :voice),
          input_audio_ms: Map.get(meas, :input_audio_ms),
          input_audio_tokens: Map.get(meas, :input_audio_tokens),
          estimated_cost_cents: Map.get(meas, :estimated_cost_cents),
          reported_cost_cents: Map.get(meas, :reported_cost_cents)
        })
    })
  end

  # Plugin distribution ops ([:fermix, :plugin, :dist]): install/uninstall/gc
  # run in the installer or a CLI VM with no agent session, so each
  # op is a point event that becomes its own self-closing trace — emitted
  # immediately, never tracked in state.
  def apply_event(state, [:fermix, :plugin, :dist], meas, meta, at) do
    duration_ms = Map.get(meas, :duration_ms, 0)
    started = Mapper.start_of(at.at, duration_ms)

    trace =
      Mapper.drop_nil(%{
        id: Mapper.new_id(started),
        project_name: state.project,
        name: "dist:#{stringify(Map.get(meta, :op))}",
        start_time: Mapper.iso(started),
        end_time: Mapper.iso(at.at),
        metadata:
          compact(%{
            plugin: Map.get(meta, :plugin),
            version: Map.get(meta, :version),
            result: stringify(Map.get(meta, :result)),
            reason: stringify(Map.get(meta, :reason)),
            duration_ms: duration_ms
          }),
        tags: ["dist"]
      })

    {state, [%{trace: trace, spans: []}]}
  end

  # A fired failure-deadline timeout ([:fermix, :timeout, :expired]): a point
  # span under the run's trace via the shared session_id, flagged errored so a
  # deadline that fired mid-run is visible rather than only inferable from a
  # missing child span. session_id nil → place_under no-ops (nothing to nest).
  def apply_event(state, [:fermix, :timeout, :expired], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.timeout_span(meta, meas, &1))
  end

  def apply_event(state, _event, _meas, _meta, _at), do: {state, []}

  @doc """
  Force-close abandoned traces. A scheduled run with a duration floor is closed
  only once past that absolute deadline (its max wall-clock duration + grace);
  every other trace uses the idle TTL (no event within `ttl_ms`).
  """
  @spec sweep(%__MODULE__{}, integer()) :: {%__MODULE__{}, [closed()]}
  def sweep(state, now_mono) do
    stale =
      for {trace_id, acc} <- state.traces,
          stale?(acc, now_mono, state.ttl_ms),
          do: trace_id

    Enum.reduce(stale, {state, []}, fn trace_id, {st, closed} ->
      {st, one} = emit_trace(st, trace_id)
      {st, closed ++ List.wrap(one)}
    end)
  end

  defp stale?(%{sweep_floor_mono: floor}, now_mono, _ttl_ms) when is_integer(floor),
    do: now_mono > floor

  defp stale?(acc, now_mono, ttl_ms),
    do: now_mono - acc.last_seen_mono > ttl_ms * 1000

  @doc "All currently-open traces flushed immediately (used at shutdown / replay end)."
  @spec drain(%__MODULE__{}) :: {%__MODULE__{}, [closed()]}
  def drain(state) do
    Enum.reduce(Map.keys(state.traces), {state, []}, fn trace_id, {st, closed} ->
      {st, one} = emit_trace(st, trace_id)
      {st, closed ++ List.wrap(one)}
    end)
  end

  # --- internals ---

  defp add_child_span(state, meta, at, span_fun) do
    place_under(state, Map.get(meta, :session_id), meta, at, span_fun)
  end

  # Attach a span only if its run's session is still open; never create a trace.
  # Used for terminal stream phases so a late event can't resurrect a closed run
  # into a phantom trace. (Distinct from `memory.write`, which is *meant* to open
  # its own post-turn trace.)
  defp attach_if_open(state, meta, at, span_fun) do
    session_id = Map.get(meta, :session_id)

    if session_id && Map.has_key?(state.sessions, session_id) do
      place_under(state, session_id, meta, at, span_fun)
    else
      {state, []}
    end
  end

  # Attach a child span under `session_id`'s wrapper (creating the run lazily).
  defp place_under(state, nil, _meta, _at, _span_fun), do: {state, []}

  defp place_under(state, session_id, meta, at, span_fun) do
    ctx = %{
      parent_session: Map.get(meta, :parent_session),
      kind: nil,
      name: Map.get(meta, :agent),
      input: nil,
      at: at.at,
      mono: at.mono
    }

    {state, ref} = ensure_session(state, session_id, ctx)
    state = maybe_set_thread(state, ref.trace_id, thread_id(meta))

    span =
      span_fun.(
        trace_id: ref.trace_id,
        parent_span_id: ref.span_id,
        project_name: state.project,
        ended: at.at
      )

    {touch(state, ref.trace_id, at.mono, fn acc -> %{acc | spans: [span | acc.spans]} end), []}
  end

  # Backfill a trace's thread_id from a child event that carries channel/chat_id
  # (only if not already set). Lets a background run whose root trace opened
  # without a thread (e.g. the memory reviewer, first seen via a provider/memory
  # event) still group into the conversation thread. Main turns are unaffected:
  # their child events carry no chat_id, so thread_id stays set at close_root.
  defp maybe_set_thread(state, _trace_id, nil), do: state

  defp maybe_set_thread(state, trace_id, thread) do
    update_trace(state, trace_id, fn acc ->
      if acc.thread_id, do: acc, else: %{acc | thread_id: thread}
    end)
  end

  defp ensure_session(state, session_id, ctx) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, ref} -> {maybe_set_input(state, ref, ctx), ref}
      :error -> create_session(state, session_id, ctx)
    end
  end

  defp create_session(state, session_id, ctx) do
    kind = ctx.kind || infer_kind(session_id)
    parent = ctx.parent_session

    {trace_id, parent_span_id, state} = resolve_trace(state, session_id, kind, parent, ctx)

    span_id = Mapper.new_id(ctx.at)

    wrapper =
      %{
        id: span_id,
        trace_id: trace_id,
        parent_span_id: parent_span_id,
        project_name: state.project,
        name: wrapper_name(kind, ctx.name, session_id),
        type: "general",
        start_time: Mapper.iso(ctx.at)
      }
      |> maybe_put_input(ctx)

    ref = %{trace_id: trace_id, span_id: span_id, parent_session: parent, kind: kind}

    state =
      state
      |> put_in([Access.key(:sessions), session_id], ref)
      |> touch(trace_id, ctx.mono, fn acc -> %{acc | spans: [wrapper | acc.spans]} end)

    {state, ref}
  end

  defp resolve_trace(state, session_id, kind, parent, ctx) do
    case parent && Map.get(state.sessions, parent) do
      # Non-root: same trace as parent, nested under the parent's wrapper.
      %{trace_id: trace_id, span_id: span_id} -> {trace_id, span_id, state}
      # Root (no parent, or parent not seen yet): open a new trace.
      _missing -> new_root_trace(state, session_id, kind, ctx)
    end
  end

  defp new_root_trace(state, session_id, kind, ctx) do
    trace_id = Mapper.new_id(ctx.at)

    acc = %{
      trace_id: trace_id,
      root_session: session_id,
      name: wrapper_name(kind, ctx.name, session_id),
      thread_id: Map.get(ctx, :thread_id),
      start_time: ctx.at,
      end_time: nil,
      input: nil,
      output: nil,
      status: nil,
      metadata: Map.get(ctx, :trace_metadata, %{}),
      tags: [Atom.to_string(kind)],
      spans: [],
      last_seen_mono: ctx.mono,
      sweep_floor_mono: sweep_floor(ctx),
      open?: true
    }

    {trace_id, nil, put_in(state, [Access.key(:traces), trace_id], acc)}
  end

  # A scheduled run is bounded by its own wall-clock timeout, not the idle TTL:
  # a long job can sit silent past the idle window yet still be running, so we
  # only force-close once it is past the point where it could still be alive
  # (its max duration + grace). Roots without a max duration (main turns,
  # subagents, realtime) get `nil` and fall back to the idle TTL.
  defp sweep_floor(ctx) do
    case Map.get(ctx, :max_duration_ms) do
      ms when is_integer(ms) and ms > 0 -> ctx.mono + (ms + @sweep_grace_ms) * 1000
      _absent -> nil
    end
  end

  defp finish_wrapper(state, nil, _at, _fields), do: {state, []}

  defp finish_wrapper(state, session_id, at, fields) do
    case Map.fetch(state.sessions, session_id) do
      :error ->
        {state, []}

      {:ok, ref} ->
        state =
          touch(state, ref.trace_id, at.mono, fn acc ->
            %{acc | spans: close_wrapper_span(acc.spans, ref.span_id, at.at, fields)}
          end)

        {state, []}
    end
  end

  defp close_root(state, meta, at, fields) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: nil,
          name: Map.get(meta, :agent),
          input: nil,
          at: at.at,
          mono: at.mono
        }

        {state, ref} = ensure_session(state, session_id, ctx)

        state =
          state
          |> update_trace(ref.trace_id, fn acc ->
            acc
            |> Map.put(:end_time, at.at)
            |> Map.put(:input, fields[:input] || acc.input)
            |> Map.put(:output, fields[:output] || acc.output)
            |> Map.put(:status, fields[:status] || acc.status)
            # main turns learn their thread (channel:chat_id) only at close; a
            # thread_id set at creation (scheduled jobs → job_id) wins.
            |> Map.put(:thread_id, acc.thread_id || fields[:thread_id])
            |> Map.update!(:metadata, &Map.merge(&1, Map.get(fields, :metadata, %{})))
            |> Map.update!(:spans, &close_wrapper_span(&1, ref.span_id, at.at, %{}))
          end)

        {state, one} = emit_trace(state, ref.trace_id)
        {state, List.wrap(one)}
    end
  end

  defp emit_trace(state, trace_id) do
    case Map.fetch(state.traces, trace_id) do
      :error ->
        {state, nil}

      {:ok, acc} ->
        end_time = acc.end_time || acc.start_time

        spans =
          acc.spans
          |> Enum.reverse()
          |> Enum.map(&(&1 |> backfill_end(end_time) |> Mapper.drop_nil()))

        trace =
          Mapper.drop_nil(%{
            id: trace_id,
            project_name: state.project,
            name: acc.name,
            thread_id: acc.thread_id,
            start_time: Mapper.iso(acc.start_time),
            end_time: Mapper.iso(end_time),
            input: io(acc.input),
            output: io(acc.output),
            metadata: compact(acc.metadata),
            tags: acc.tags
          })

        sessions =
          for {sid, ref} <- state.sessions, ref.trace_id != trace_id, into: %{}, do: {sid, ref}

        state = %{state | traces: Map.delete(state.traces, trace_id), sessions: sessions}
        {state, %{trace: trace, spans: spans}}
    end
  end

  defp close_wrapper_span(spans, span_id, ended, fields) do
    Enum.map(spans, fn
      %{id: ^span_id} = span ->
        span
        |> Map.put_new(:end_time, Mapper.iso(ended))
        |> merge_wrapper_metadata(fields)

      span ->
        span
    end)
  end

  defp merge_wrapper_metadata(span, fields) do
    extra = compact(%{iterations: fields[:iterations], success: fields[:success]})
    if extra == %{}, do: span, else: Map.update(span, :metadata, extra, &Map.merge(&1, extra))
  end

  defp backfill_end(span, end_time) do
    Map.put_new(span, :end_time, Mapper.iso(end_time))
  end

  defp maybe_set_input(state, ref, %{input: input}) when is_binary(input) do
    update_trace(state, ref.trace_id, &set_span_input(&1, ref.span_id, input))
  end

  defp maybe_set_input(state, _ref, _ctx), do: state

  defp set_span_input(acc, span_id, input) do
    Map.update!(acc, :spans, fn spans ->
      Enum.map(spans, &put_span_input(&1, span_id, input))
    end)
  end

  defp put_span_input(%{id: id} = span, id, input), do: Map.put_new(span, :input, io(input))
  defp put_span_input(span, _span_id, _input), do: span

  defp maybe_put_input(span, %{input: input}) when is_binary(input),
    do: Map.put(span, :input, io(input))

  defp maybe_put_input(span, _ctx), do: span

  defp touch(state, trace_id, mono, fun) do
    update_trace(state, trace_id, fn acc -> %{fun.(acc) | last_seen_mono: mono} end)
  end

  defp update_trace(state, trace_id, fun) do
    case Map.fetch(state.traces, trace_id) do
      {:ok, acc} -> put_in(state, [Access.key(:traces), trace_id], fun.(acc))
      :error -> state
    end
  end

  defp io(nil), do: nil
  defp io(value) when is_binary(value), do: %{text: value}
  defp io(value), do: %{value: value}

  defp infer_kind("main-" <> _), do: :main
  defp infer_kind("cron_" <> _), do: :scheduled
  defp infer_kind("session:" <> _), do: :realtime
  defp infer_kind("soul_curation:" <> _), do: :soul_curation
  defp infer_kind("memory_review:" <> _), do: :memory_review
  defp infer_kind(_other), do: :subagent

  defp kind_from_role(role) when role in [:skill, "skill"], do: :skill
  defp kind_from_role(_role), do: :subagent

  defp wrapper_name(:main, _name, _session), do: "agent:main"
  defp wrapper_name(:scheduled, name, session), do: "scheduled:#{name || session}"
  defp wrapper_name(kind, nil, session), do: "#{kind}:#{session}"
  defp wrapper_name(kind, name, _session), do: "#{kind}:#{name}"

  defp compact(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end

  # Group a channel conversation into one Opik thread. Fermix's conversation
  # boundary is {channel, chat_id, sender}; channel:chat_id is the stable,
  # human-meaningful grain (all messages in a Telegram chat → one thread).
  defp thread_id(meta) do
    case Map.get(meta, :chat_id) do
      nil -> nil
      chat_id -> "#{stringify(Map.get(meta, :channel))}:#{chat_id}"
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value)
end
