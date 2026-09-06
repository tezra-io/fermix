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

  # How long a closed session stays tombstoned (see `closed_sessions`). Long
  # enough to cover an async emitter that lost the race with its own turn's close
  # (channel draft-stream seals do, on a fast turn), short enough that the map
  # cannot grow without bound — the sweep prunes past this age.
  @closed_session_ttl_ms 600_000

  # The outbound-MCP lifecycle phases that can happen inside an agent turn. Every
  # other phase is boot/teardown work with no turn to nest under (see the
  # [:fermix, :mcp_client, :lifecycle] clause).
  @mcp_client_turn_phases [:security_block, :drift, :reconnect]

  @enforce_keys [:project, :ttl_ms]
  defstruct project: nil,
            ttl_ms: 120_000,
            traces: %{},
            sessions: %{},
            # session_id => monotonic close time. A span arriving for a session
            # whose trace already SHIPPED cannot be added to it, and creating a
            # session for it would mint an empty second root for a turn that is
            # already complete (observed live: a fast turn whose `stream:open` /
            # `stream:seal` landed a second after `agent.message` closed the
            # trace, producing an input/output-less `agent:main` phantom). Such
            # spans are dropped and counted instead.
            closed_sessions: %{},
            dropped_after_close: 0

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

  # Channel-stream lifecycle ([:fermix, :channel, :stream]): open/block/rotate/
  # seal/discard become child spans of the turn's trace via the shared
  # session_id — never a root run (the stream has no parent_session of its own).
  # Interim draft :edit phases are deliberately not exported: at ~1 edit/s they
  # would flood the trace; the seal span carries total_edits/dropped_snapshots
  # instead. :block (one per sent chunk) and :rotate (one per sealed draft card,
  # a handful per turn) export too, but only while the run's session is still
  # open (see below).
  def apply_event(state, [:fermix, :channel, :stream], meas, meta, at) do
    case Map.get(meta, :phase) do
      :open ->
        # :open may be a turn's FIRST exported event, so it must be allowed to
        # create the session — `attach_if_open` (below) would drop it and lose the
        # ttfd_ms. Its old claim that the session is therefore "guaranteed open"
        # was wrong: the draft stream is its own process, and on a fast turn both
        # :open and :seal can land after `agent.message` already shipped the trace
        # (observed live). What makes that safe is the `closed_sessions` tombstone
        # in `place_under`, which drops a span for an already-shipped session
        # instead of resurrecting it as an empty root.
        add_child_span(state, meta, at, &Mapper.stream_span(meta, meas, &1))

      phase when phase in [:block, :rotate, :seal, :discard] ->
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

  # A failed turn is the trace a reader most needs, so it carries everything its
  # successful sibling carries — the prompt above all (the emitter attaches it
  # under the same `capture_content` gate). `error_info` is what makes it
  # filterable in Opik instead of findable only by reading the output text.
  def apply_event(state, [:fermix, :agent, :message_error], _meas, meta, at) do
    reason = stringify(Map.get(meta, :reason))

    close_root(state, meta, at, %{
      input: Map.get(meta, :input),
      output: reason,
      status: "error",
      error_info: error_info("TurnError", reason),
      thread_id: thread_id(meta),
      metadata:
        compact(%{
          channel: stringify(Map.get(meta, :channel)),
          chat_id: Map.get(meta, :chat_id),
          sender: Map.get(meta, :sender)
        })
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

  # A coding-harness run (codex/claude, local/cloud) is its OWN root trace: the
  # spawning turn/cron rides as `origin_session_id` correlation metadata, NEVER a
  # parent_session (hard-coded nil below). A detached run finishing after its
  # origin turn already closed would otherwise nest into — or resurrect — the
  # origin's trace and mint a broken second root (H7 fix; see the fermix repo
  # docs/design/CODING_HARNESS_ORCHESTRATION.md §11). run_start opens the root;
  # the run's provider/tool spans nest via the shared `harness_<run_id>` session;
  # run_complete/run_error close it. Bounded by the run's own max_duration
  # (sweep floor), not the idle TTL.
  def apply_event(state, [:fermix, :harness, :run_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: :harness,
          name: Map.get(meta, :vendor) || Map.get(meta, :agent),
          input: Map.get(meta, :input),
          max_duration_ms: Map.get(meta, :max_duration_ms),
          trace_metadata:
            compact(%{
              run_id: Map.get(meta, :run_id),
              vendor: stringify(Map.get(meta, :vendor)),
              rail: stringify(Map.get(meta, :rail)),
              origin_kind: stringify(Map.get(meta, :origin_kind)),
              origin_session_id: Map.get(meta, :origin_session_id)
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  def apply_event(state, [:fermix, :harness, run], _meas, meta, at)
      when run in [:run_complete, :run_error] do
    status = if run == :run_error, do: "error", else: Map.get(meta, :status, "ok")

    close_root(state, meta, at, %{
      output: Map.get(meta, :output) || Map.get(meta, :error),
      status: status,
      metadata:
        compact(%{
          run_id: Map.get(meta, :run_id),
          vendor: stringify(Map.get(meta, :vendor)),
          reason: Map.get(meta, :reason),
          exit_code: Map.get(meta, :exit_code),
          usage: Map.get(meta, :usage),
          origin_session_id: Map.get(meta, :origin_session_id)
        })
    })
  end

  # A harness liveness/progress point: a child span under the run's trace via the
  # shared harness session_id (never a root). It only fires while the run's own
  # root trace is open, so nesting is the whole point.
  def apply_event(state, [:fermix, :harness, :progress], meas, meta, at) do
    add_child_span(state, meta, at, &harness_progress_span(meta, meas, &1))
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

  # A skill-curation cycle (MILESTONE_26_SKILL_CURATION §9) is a bounded
  # background run minted with its own session_id before any turn exists —
  # scheduled cycles are roots (no parent_session emitted), a manual
  # `/skills review` and a creation task pass the originating command session
  # through (the soul_curation shape).
  def apply_event(state, [:fermix, :skill_curation, :run_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: Map.get(meta, :parent_session),
          kind: :skill_curation,
          name: stringify(Map.get(meta, :stage)),
          input: nil,
          trace_metadata:
            compact(%{
              stage: stringify(Map.get(meta, :stage)),
              trigger: stringify(Map.get(meta, :trigger))
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  # Counts only — this compact map is the metadata allowlist for the run
  # bookends; a count field not named here never exports.
  def apply_event(state, [:fermix, :skill_curation, run], _meas, meta, at)
      when run in [:run_complete, :run_error] do
    status = if run == :run_error, do: "error", else: Map.get(meta, :status, "ok")

    close_root(state, meta, at, %{
      output: Map.get(meta, :error),
      status: status,
      metadata:
        compact(%{
          stage: stringify(Map.get(meta, :stage)),
          trigger: stringify(Map.get(meta, :trigger)),
          reason_kind: stringify(Map.get(meta, :reason_kind)),
          messages_scanned: Map.get(meta, :messages_scanned),
          checkpoints_included: Map.get(meta, :checkpoints_included),
          messages_dropped_caps: Map.get(meta, :messages_dropped_caps),
          dropped_unattributed: Map.get(meta, :dropped_unattributed),
          candidates: Map.get(meta, :candidates),
          dropped_disposition: Map.get(meta, :dropped_disposition),
          dropped_grounding: Map.get(meta, :dropped_grounding),
          dropped_invalid_name: Map.get(meta, :dropped_invalid_name),
          dropped_overflow: Map.get(meta, :dropped_overflow),
          deferred: Map.get(meta, :deferred),
          delivered_deferred: Map.get(meta, :delivered_deferred),
          proposals_new: Map.get(meta, :proposals_new),
          proposals_update: Map.get(meta, :proposals_update),
          proposals_archive: Map.get(meta, :proposals_archive),
          archive_overflow: Map.get(meta, :archive_overflow),
          expired_pending: Map.get(meta, :expired_pending),
          expired_deferred: Map.get(meta, :expired_deferred),
          window_truncated: Map.get(meta, :window_truncated),
          delivery_status: stringify(Map.get(meta, :delivery_status)),
          skill: Map.get(meta, :skill)
        })
    })
  end

  # Owner proposal actions land days after the cycle trace shipped (the
  # tombstone would drop a child span), so each action is a point event that
  # becomes its own self-closing trace — the plugin-dist shape.
  def apply_event(state, [:fermix, :skill_curation, :proposal_actioned], meas, meta, at) do
    trace =
      Mapper.drop_nil(%{
        id: Mapper.new_id(at.at),
        project_name: state.project,
        name: "skillcur:#{stringify(Map.get(meta, :action))}",
        start_time: Mapper.iso(at.at),
        end_time: Mapper.iso(at.at),
        metadata:
          compact(%{
            action: stringify(Map.get(meta, :action)),
            kind: stringify(Map.get(meta, :kind)),
            age_ms: Map.get(meas, :age_ms)
          }),
        tags: ["skill_curation"]
      })

    {state, [%{trace: trace, spans: []}]}
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

  # `screen_feed_start`/`_stop` are bookends, not per-frame events: the individual
  # `frame_sent` events stay out of Opik on purpose (up to 20/minute would bury a
  # call's real spans), and the stop event's typed `reason` is what a reader needs.
  def apply_event(state, [:fermix, :realtime, phase], meas, meta, at)
      when phase in [
             :session_created,
             :session_updated,
             :provider_error,
             :reconnect,
             :screen_feed_start,
             :screen_feed_stop
           ] do
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
          # WHY the call ended (call_stop / cost_limit / max_session_duration /
          # provider_disconnected). Without it a teardown was indistinguishable
          # from a normal hang-up in the trace, which is what let a cost-ceiling
          # kill masquerade as the operator ending the call.
          reason: Map.get(meta, :reason),
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

  # Outbound MCP client lifecycle ([:fermix, :mcp_client, :lifecycle]). Routing
  # is decided by ONE classifier — "did this phase happen inside an agent turn?"
  # — not by a fallback: the two shapes are two distinct situations, not two
  # attempts at the same one.
  #
  # `initialize`/`discover`/`ready`/`teardown`/`owner_down` fire at client boot
  # and teardown, where no turn exists. Routing them through `add_child_span`
  # would drop them outright (nil session_id) or, given a non-turn id, mint a
  # phantom root whose `infer_kind/1` falls through to `:subagent` — the
  # orphan-span bug M27 §11.1 warns about. So they build a self-closing trace
  # inline, exactly like `[:fermix, :plugin, :dist]`, and are never tracked in
  # state.
  #
  # `security_block`/`drift`/`reconnect` CAN occur mid-turn (a call proxy
  # rejection, a contract drift noticed on invoke), so they nest under the turn
  # when it supplied its session_id, and self-close when it did not.
  def apply_event(state, [:fermix, :mcp_client, :lifecycle], meas, meta, at) do
    session_id = Map.get(meta, :session_id)

    if Map.get(meta, :phase) in @mcp_client_turn_phases and is_binary(session_id) do
      add_child_span(state, meta, at, &Mapper.mcp_client_span(meta, meas, &1))
    else
      {state, [%{trace: mcp_client_trace(state, meas, meta, at), spans: []}]}
    end
  end

  # A fired failure-deadline timeout ([:fermix, :timeout, :expired]): a point
  # span under the run's trace via the shared session_id, flagged errored so a
  # deadline that fired mid-run is visible rather than only inferable from a
  # missing child span. session_id nil → place_under no-ops (nothing to nest).
  def apply_event(state, [:fermix, :timeout, :expired], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.timeout_span(meta, meas, &1))
  end

  # Proactive reminder lifecycle ([:fermix, :reminder, :lifecycle]). A reminder
  # delivery is not an agent run — no provider call, no turn, and by design no
  # session_id (M30 §6.4) — so every phase is a point event that becomes its own
  # self-closing trace, built inline exactly like [:fermix, :plugin, :dist] and
  # never tracked in state. Correlation is by event/reminder ids; nesting one
  # under a session would mint the phantom root M27 §11.1 warns about.
  def apply_event(state, [:fermix, :reminder, :lifecycle], meas, meta, at) do
    {state, [%{trace: reminder_trace(state, meas, meta, at), spans: []}]}
  end

  # A post-delivery follow-up (M30 §22.7) is the one part of the reminder rail
  # that IS an agent run: it drives the loop in its own context, so unlike every
  # phase above it owns a session and gets a real root trace with the run's
  # provider/tool spans nested under it.
  #
  # `parent_session` is hard-coded nil for the harness reason: the turn that
  # stored the event closed hours or days before delivery, so there is no live
  # turn to nest into and naming one would resurrect a shipped trace. There is
  # deliberately no `thread_id` either — the temporal family never carries the
  # delivery destination, so the run is an unthreaded root, found by its session
  # prefix and its event/reminder ids.
  def apply_event(state, [:fermix, :reminder, :followup_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: :reminder_followup,
          name: Map.get(meta, :agent),
          input: nil,
          max_duration_ms: Map.get(meta, :max_duration_ms),
          trace_metadata: followup_metadata(meta),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  # `followup_complete` closes a run that reached a decision — `sent`,
  # `declined`, `empty`, `delivery_failed` — and every one of those is a
  # successful run, so the status is "ok" and the `outcome` is what says which.
  # Only a run that never reached one (`followup_error`) carries its own status
  # word (`error`/`timeout`). The owner-facing text rides `output` and exists
  # only when the operator turned content capture on.
  def apply_event(state, [:fermix, :reminder, run], _meas, meta, at)
      when run in [:followup_complete, :followup_error] do
    status = if run == :followup_error, do: Map.get(meta, :status, "error"), else: "ok"

    close_root(state, meta, at, %{
      output: Map.get(meta, :output) || Map.get(meta, :error),
      status: status,
      metadata: followup_metadata(meta)
    })
  end

  # A meeting run (M21 §11.1) is a detached run that outlives the turn which
  # asked for it: the Session joins the call, streams transcript for an hour,
  # then summarizes and delivers. So it is its OWN root trace and
  # `parent_session` rides as correlation metadata only, never as a parent (the
  # harness reason: the originating turn ships long first, so nesting would drop
  # every later span into the tombstone and mint a broken second root when the
  # closer finally arrives). run_start opens the root; the phase spans and the
  # run's provider/tool spans nest via the shared `meeting_<id>_<ts>` session;
  # run_complete/run_error close it. `url`/`title` reach this module only when
  # the operator turned content capture on (a meeting URL can embed a passcode).
  def apply_event(state, [:fermix, :meeting, :run_start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: :meeting,
          name: Map.get(meta, :agent),
          input: Map.get(meta, :url),
          # A quiet meeting emits nothing between phase transitions, which can
          # outlast the idle TTL — the run's own cap is the honest sweep floor.
          max_duration_ms: Map.get(meta, :max_duration_ms),
          trace_metadata: meeting_metadata(meta),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  # `run_complete` carries the delivered run's counters; `run_error` carries the
  # TERMINAL STATE word (`failed`, `refused`, …), which is the diagnosis — the
  # generic "error" would erase which wall the meeting hit — plus `error_info`
  # so the failure is filterable in Opik rather than only readable.
  def apply_event(state, [:fermix, :meeting, run], meas, meta, at)
      when run in [:run_complete, :run_error] do
    status =
      if run == :run_error,
        do: Map.get(meta, :status, "error"),
        else: Map.get(meta, :status, "ok")

    close_root(state, meta, at, %{
      output: Map.get(meta, :error),
      status: status,
      error_info: meeting_error_info(run, meta),
      metadata: compact(Map.merge(meeting_metadata(meta), meeting_counters(meas)))
    })
  end

  # One Session state transition: a point span under the run's trace via the
  # shared session_id. `reason` is a typed end_reason/detail atom, never free
  # text, so a phase span carries no meeting content.
  def apply_event(state, [:fermix, :meeting, :phase], meas, meta, at) do
    add_child_span(state, meta, at, &Mapper.meeting_phase_span(meta, meas, &1))
  end

  # A management Doctor run (M34 §5) is a bounded background run minted with its
  # own `doctor:<rand>` session before any check executes. It is always a root:
  # the app asks the daemon directly, so there is no originating turn to nest
  # under.
  def apply_event(state, [:fermix, :doctor, :session_start], meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: Map.get(meta, :parent_session),
          kind: :doctor,
          name: stringify(Map.get(meta, :scope)),
          input: nil,
          trace_metadata:
            compact(%{
              scope: stringify(Map.get(meta, :scope)),
              budget_ms: Map.get(meta, :budget_ms),
              checks: Map.get(meas, :checks)
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  # Counts only — this compact map is the metadata allowlist for the run
  # bookends, and `status` carries the run's TERMINAL word (`completed`,
  # `cancelled`, `timed_out`) rather than a generic "ok" that would erase which
  # bound the run hit.
  def apply_event(state, [:fermix, :doctor, run], _meas, meta, at)
      when run in [:session_complete, :session_error] do
    status = if run == :session_error, do: "error", else: Map.get(meta, :status, "completed")

    close_root(state, meta, at, %{
      output: Map.get(meta, :error),
      status: status,
      metadata:
        compact(%{
          scope: stringify(Map.get(meta, :scope)),
          budget_ms: Map.get(meta, :budget_ms),
          reason_kind: stringify(Map.get(meta, :reason_kind)),
          checks_total: Map.get(meta, :checks_total),
          passed: Map.get(meta, :passed),
          warning: Map.get(meta, :warning),
          failed: Map.get(meta, :failed),
          unavailable: Map.get(meta, :unavailable),
          skipped: Map.get(meta, :skipped),
          cancelled: Map.get(meta, :cancelled),
          timed_out: Map.get(meta, :timed_out)
        })
    })
  end

  # A management job (M34 native setup §7.3) is a bounded background run minted
  # with its own `job:<rand>` session before its body executes. Like a Doctor
  # run it is always a root: the app asks the daemon directly, so there is no
  # originating turn to nest under. A provider call made inside the run carries
  # the same session id and lands as its child.
  def apply_event(state, [:fermix, :management_job, :start], _meas, meta, at) do
    case Map.get(meta, :session_id) do
      nil ->
        {state, []}

      session_id ->
        ctx = %{
          parent_session: nil,
          kind: :management_job,
          name: stringify(Map.get(meta, :kind)),
          input: nil,
          trace_metadata:
            compact(%{
              kind: stringify(Map.get(meta, :kind)),
              budget_ms: Map.get(meta, :budget_ms)
            }),
          at: at.at,
          mono: at.mono
        }

        {state, _ref} = ensure_session(state, session_id, ctx)
        {state, []}
    end
  end

  # `status` carries the run's TERMINAL word (`completed`, `failed`,
  # `cancelled`, `timed_out`) rather than a generic "ok", and the failure
  # sentence is the daemon's own operator copy — never an operation result.
  def apply_event(state, [:fermix, :management_job, :complete], _meas, meta, at) do
    close_root(state, meta, at, %{
      output: Map.get(meta, :error),
      status: Map.get(meta, :status, "completed"),
      metadata:
        compact(%{
          kind: stringify(Map.get(meta, :kind)),
          budget_ms: Map.get(meta, :budget_ms),
          failure_code: Map.get(meta, :failure_code)
        })
    })
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

    {state, closed} =
      Enum.reduce(stale, {state, []}, fn trace_id, {st, closed} ->
        {st, one} = emit_trace(st, trace_id)
        {st, closed ++ List.wrap(one)}
      end)

    {prune_closed_sessions(state, now_mono), closed}
  end

  # Tombstones are bounded by age: past the TTL a late span can no longer belong
  # to that turn, so the entry is dropped and the session id behaves as new again.
  defp prune_closed_sessions(state, now_mono) do
    ttl_us = @closed_session_ttl_ms * 1_000

    kept =
      for {sid, closed_at} <- state.closed_sessions,
          now_mono - closed_at < ttl_us,
          into: %{},
          do: {sid, closed_at}

    %{state | closed_sessions: kept}
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

  # A span for a session whose trace already shipped: adding it is impossible and
  # creating a session would mint an empty second root, so drop and count it. Only
  # ever reached by an emitter that lost the race with its own turn's close.
  defp place_under(state, session_id, _meta, _at, _span_fun)
       when is_map_key(state.closed_sessions, session_id) do
    {%{state | dropped_after_close: state.dropped_after_close + 1}, []}
  end

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
      error_info: nil,
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
            |> Map.put(:error_info, fields[:error_info] || acc.error_info)
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
            metadata: compact(put_status(acc.metadata, acc.status)),
            error_info: acc.error_info,
            tags: acc.tags
          })

        {closing, sessions} =
          Map.split_with(state.sessions, fn {_sid, ref} -> ref.trace_id == trace_id end)

        # Tombstone the sessions whose trace just shipped, so a late span is
        # dropped rather than resurrected into a fresh (empty) root. Stamped with
        # the trace's last activity, which is what the sweep prunes against.
        closed_at = acc.last_seen_mono

        closed_sessions =
          Enum.reduce(closing, state.closed_sessions, fn {sid, _ref}, tombstones ->
            Map.put(tombstones, sid, closed_at)
          end)

        state = %{
          state
          | traces: Map.delete(state.traces, trace_id),
            sessions: sessions,
            closed_sessions: closed_sessions
        }

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
  defp infer_kind("harness_" <> _), do: :harness
  defp infer_kind("session:" <> _), do: :realtime
  defp infer_kind("skill_curation:" <> _), do: :skill_curation
  defp infer_kind("soul_curation:" <> _), do: :soul_curation
  defp infer_kind("memory_review:" <> _), do: :memory_review
  defp infer_kind("followup_" <> _), do: :reminder_followup
  defp infer_kind("meeting_" <> _), do: :meeting
  # The computer-history summarizer (§22.4) is a headless single-call run with
  # no bookend events: its provider span creates the session, so the kind must
  # come from the id prefix or the root would read as a :subagent of nothing.
  defp infer_kind("computer_history_summarize:" <> _), do: :computer_history_summary
  defp infer_kind("doctor:" <> _), do: :doctor
  defp infer_kind("job:" <> _), do: :management_job
  defp infer_kind(_other), do: :subagent

  defp kind_from_role(role) when role in [:skill, "skill"], do: :skill
  defp kind_from_role(_role), do: :subagent

  defp wrapper_name(:main, _name, _session), do: "agent:main"
  defp wrapper_name(:scheduled, name, session), do: "scheduled:#{name || session}"
  defp wrapper_name(:harness, name, session), do: "harness:#{name || session}"
  # The run's agent name ("followup:<event_id>") already reads as a label, and
  # its session id ("followup_<reminder_id>") is its own fallback — the generic
  # "<kind>:<name>" shape would only say "followup" twice.
  defp wrapper_name(:reminder_followup, name, session), do: name || session
  # Same shape: the run's agent name is already "meeting:<id>", and its session
  # id ("meeting_<id>_<ts>") is its own fallback — the generic "<kind>:<name>"
  # would only say "meeting" twice.
  defp wrapper_name(:meeting, name, session), do: name || session
  # Same shape again: the agent name is "computer_history_summarizer" and the
  # session id starts "computer_history_summarize:" — prefixing the kind would
  # say "computer history" twice.
  defp wrapper_name(:computer_history_summary, name, session), do: name || session
  defp wrapper_name(kind, nil, session), do: "#{kind}:#{session}"
  defp wrapper_name(kind, name, _session), do: "#{kind}:#{name}"

  # A point span marking a harness run's liveness/progress. Built inline (like
  # the plugin-dist trace) rather than in the Mapper because it is harness-local
  # accounting: the run's phase plus its event/framing counters.
  defp harness_progress_span(metadata, measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    started = Mapper.start_of(ended, 0)

    %{
      id: Mapper.new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: "harness:progress",
      type: "general",
      start_time: Mapper.iso(started),
      end_time: Mapper.iso(ended),
      metadata:
        compact(%{
          phase: stringify(Map.get(metadata, :phase)),
          events: Map.get(measurements, :events),
          framing_errors: Map.get(measurements, :framing_errors)
        })
    }
    |> Mapper.drop_nil()
  end

  # A self-closing trace for one outbound-MCP lifecycle phase that had no turn to
  # nest under. Built inline (like the plugin-dist trace) because it is a point
  # event that ships immediately and is never tracked in state.
  defp mcp_client_trace(state, measurements, metadata, at) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    started = Mapper.start_of(at.at, duration_ms)

    Mapper.drop_nil(%{
      id: Mapper.new_id(started),
      project_name: state.project,
      name: "mcp_client:#{stringify(Map.get(metadata, :phase))}",
      start_time: Mapper.iso(started),
      end_time: Mapper.iso(at.at),
      metadata:
        compact(%{
          source_id: Map.get(metadata, :source_id),
          plugin: Map.get(metadata, :plugin),
          phase: stringify(Map.get(metadata, :phase)),
          result: stringify(Map.get(metadata, :result)),
          error_class: stringify(Map.get(metadata, :error_class)),
          attempt: Map.get(metadata, :attempt),
          duration_ms: duration_ms
        }),
      tags: ["mcp_client"]
    })
  end

  # A self-closing trace for one reminder lifecycle phase. Built inline (like the
  # plugin-dist trace) because it is a point event that ships immediately. The
  # metadata is exactly the emitter's fixed allowlist — `content` only exists at
  # all when the operator turned the shared content gate on.
  defp reminder_trace(state, measurements, metadata, at) do
    duration_ms = Map.get(measurements, :duration_ms, 0)
    started = Mapper.start_of(at.at, duration_ms)

    Mapper.drop_nil(%{
      id: Mapper.new_id(started),
      project_name: state.project,
      name: "reminder:#{stringify(Map.get(metadata, :phase))}",
      start_time: Mapper.iso(started),
      end_time: Mapper.iso(at.at),
      metadata: compact(reminder_metadata(metadata, duration_ms)),
      tags: ["reminder"]
    })
  end

  # The follow-up bookends' correlation allowlist, shared by the opener and the
  # closer so a run whose opener never arrived still carries the ids. `outcome`
  # exists only on the closer; `compact` drops it everywhere else.
  defp followup_metadata(metadata) do
    compact(%{
      component: Map.get(metadata, :component),
      event_id: Map.get(metadata, :event_id),
      reminder_id: Map.get(metadata, :reminder_id),
      occurrence_key: Map.get(metadata, :occurrence_key),
      outcome: Map.get(metadata, :outcome)
    })
  end

  # The meeting bookends' correlation allowlist, shared by the opener and the
  # closer so a run whose opener never arrived still carries the ids. `title` is
  # content-gated at the emitter and simply absent when capture is off; the URL
  # rides as the trace input under that same gate.
  defp meeting_metadata(metadata) do
    compact(%{
      meeting_id: Map.get(metadata, :meeting_id),
      platform: stringify(Map.get(metadata, :platform)),
      origin: stringify(Map.get(metadata, :origin)),
      parent_session: Map.get(metadata, :parent_session),
      title: Map.get(metadata, :title)
    })
  end

  # The closer's measurements: what the run actually captured. Absent on
  # `run_error` (no counters to report), where `compact` drops them.
  defp meeting_counters(measurements) do
    %{
      duration_ms: Map.get(measurements, :duration_ms),
      segments: Map.get(measurements, :segments),
      words: Map.get(measurements, :words),
      participants_peak: Map.get(measurements, :participants_peak)
    }
  end

  defp meeting_error_info(:run_error, metadata),
    do: error_info("MeetingError", stringify(Map.get(metadata, :error)))

  defp meeting_error_info(_run, _metadata), do: nil

  defp reminder_metadata(metadata, duration_ms) do
    %{
      component: Map.get(metadata, :component),
      phase: stringify(Map.get(metadata, :phase)),
      event_id: Map.get(metadata, :event_id),
      reminder_id: Map.get(metadata, :reminder_id),
      occurrence_key: Map.get(metadata, :occurrence_key),
      rule_id: Map.get(metadata, :rule_id),
      platform: Map.get(metadata, :platform),
      attempt: Map.get(metadata, :attempt),
      result: stringify(Map.get(metadata, :result)),
      error_class: stringify(Map.get(metadata, :error_class)),
      content: Map.get(metadata, :content),
      duration_ms: duration_ms
    }
  end

  defp compact(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end

  # Opik's structured failure surface: a trace carrying `error_info` is
  # filterable as failed. Never fabricated — a run that named no reason gets
  # none, and `Mapper.drop_nil` leaves the field off entirely.
  defp error_info(_type, nil), do: nil
  defp error_info(type, message), do: %{exception_type: type, message: message}

  # Surface the run status the accumulator already tracks (it was dropped at
  # emit until now). "ok" is the absence of a status: exporting it would rewrite
  # every successful trace's payload to say what the missing error_info says.
  defp put_status(metadata, status) when status in [nil, "ok"], do: metadata
  defp put_status(metadata, status), do: Map.put(metadata, :status, status)

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
