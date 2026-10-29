defmodule FermixCore.OpenLoops.Telemetry do
  @moduledoc """
  The single owner of the open-loop telemetry family (M78 §09).

  A check-in calls `AgentLoop.run/1` in its own context, so it is a run kind
  under `docs/TELEMETRY_CONTRACT.md` and owes what that carries: a unique
  `session_id` (`open_loop_<id>_<touch>`), lifecycle bookends, and errors traced
  before the run ends. Its provider and tool spans need no mapping of their own:
  they ride the shared `[:fermix, :provider, :call]` / `[:fermix, :tool, :exec]`
  events and nest under the session these bookends carry.

      [:fermix, :open_loop, :checkin, :start]
      [:fermix, :open_loop, :checkin, :complete]
      [:fermix, :open_loop, :checkin, :error]

  Four point events have no run behind them, so they carry no session of their
  own:

      [:fermix, :open_loop, :skipped]   # the scheduler declined to start a run
      [:fermix, :open_loop, :settled]   # a loop's state moved
      [:fermix, :open_loop, :fault]     # a scheduler step failed
      [:fermix, :open_loop, :reaction]  # a follow-up's outcome was recorded

  A skip never reached a model, which is the reminder rail's split: has a
  session or not. A settlement carries the settling turn's `session_id` only
  when the caller has one (the attended turn that recorded an answer); a
  scheduler expiry has none. A fault is the open-loop counterpart of the
  reminder rail's `scheduler_error` phase: it names the step that failed and a
  class derived from the reason, never the reason itself. A reaction (M83 §07)
  is the owner's reply to a follow-up, or its absence a day on: the loop, the
  rung and `replied | no_reply`, the delay in `reply_after_ms`, never a word of
  either side's text, and the observing turn's `session_id` only when the
  caller has one.

  There is no `parent_session`: the scheduler spawned the run, not another run,
  and the turn that captured the loop closed days before (the follow-up and
  harness precedents).

  Every word is checked against its closed set at the boundary, so no caller can
  emit an outcome, status, reason or settler a consumer has never heard of. The
  one owner-facing string a run produces, the message it sent, rides only behind
  `FermixCore.Telemetry.capture_content?/0`. Destinations are never emitted:
  no function here accepts one.

  Never hand-roll these events elsewhere.
  """

  alias FermixCore.Telemetry

  @start_event [:fermix, :open_loop, :checkin, :start]
  @complete_event [:fermix, :open_loop, :checkin, :complete]
  @error_event [:fermix, :open_loop, :checkin, :error]
  @skipped_event [:fermix, :open_loop, :skipped]
  @settled_event [:fermix, :open_loop, :settled]
  @fault_event [:fermix, :open_loop, :fault]
  @reaction_event [:fermix, :open_loop, :reaction]

  @checkin_component "open_loop_checkin"
  @scheduler_component "open_loop_scheduler"
  @settle_component "open_loops"

  @rungs [1, 2]
  @horizon_classes ["long", "medium", "short", "imminent", "after"]
  @outcomes ["spoke", "silent", "later", "closed", "empty", "delivery_failed"]
  @statuses ["timeout", "error"]
  @skip_reasons [
    "disabled",
    "budget",
    "active_hours",
    "no_target",
    "max_children",
    "closed_meanwhile"
  ]
  @live_states ["open", "due", "asked"]
  @states @live_states ++ ["closed", "expired"]
  @answers ["done", "plan", "not_yet", "stop", "drop", "asked", "moved", "reach"]
  @settlers ["main_agent", "checkin", "scheduler"]
  @fault_stages ["scan", "claim", "release", "timer", "start_checkin", "sweep"]
  @reaction_outcomes ["replied", "no_reply"]

  @active_hours_label ~r/\A\d{2}:\d{2}-\d{2}:\d{2}\z/

  @trace_event_definitions [
    %{
      event: @start_event,
      trace_event: "open_loop_checkin_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @complete_event,
      trace_event: "open_loop_checkin_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @error_event,
      trace_event: "open_loop_checkin_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @skipped_event,
      trace_event: "open_loop_skipped",
      trace_type: :agent_event,
      agent_field: :component
    },
    %{
      event: @settled_event,
      trace_event: "open_loop_settled",
      trace_type: :agent_event,
      agent_field: :component
    },
    %{
      event: @fault_event,
      trace_event: "open_loop_fault",
      trace_type: :agent_event,
      agent_field: :component
    },
    %{
      event: @reaction_event,
      trace_event: "open_loop_reaction",
      trace_type: :agent_event,
      agent_field: :component
    }
  ]

  @typedoc "One check-in run's identity, from `correlation/2`."
  @type run :: %{
          session_id: String.t(),
          agent: String.t(),
          open_loop_id: String.t(),
          touch: pos_integer()
        }

  defguardp is_loop_id(id)
            when is_binary(id) and byte_size(id) > 5 and binary_part(id, 0, 5) == "loop_"

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  The identity of one check-in run: the loop it serves and the touch it would
  make (the row's `touches + 1`).

  One derivation, two consumers: the loop context takes its `session_id` and
  `agent_name` from here, so the run's provider and tool spans correlate with
  these bookends by construction rather than by two call sites agreeing.
  """
  @spec correlation(String.t(), pos_integer()) :: run()
  def correlation(loop_id, touch) when is_loop_id(loop_id) and is_integer(touch) and touch > 0 do
    %{
      session_id: "open_loop_" <> loop_id <> "_" <> Integer.to_string(touch),
      agent: "open_loop:" <> loop_id,
      open_loop_id: loop_id,
      touch: touch
    }
  end

  @doc """
  Opens the run's trace, before the first provider call.

  `active_hours_label` is `OpenLoops.ActiveHours.label/1` of the hours the run
  was admitted under, snapshotted so the trace says why it ran when it did.
  `max_duration_ms` is the run's watchdog, carried so the exporter sweeps by the
  run's own ceiling rather than its idle TTL.
  """
  @spec run_start(run(), 1 | 2, String.t(), String.t(), pos_integer()) :: :ok
  def run_start(run, rung, horizon_class, active_hours_label, max_duration_ms)
      when is_map(run) and rung in @rungs and horizon_class in @horizon_classes and
             is_binary(active_hours_label) and is_integer(max_duration_ms) and
             max_duration_ms > 0 do
    metadata =
      run
      |> base_metadata()
      |> Map.merge(%{
        rung: rung,
        horizon_class: horizon_class,
        active_hours: active_hours!(active_hours_label),
        max_duration_ms: max_duration_ms
      })

    execute(@start_event, %{count: 1}, metadata)
  end

  @doc """
  Closes a run that reached a decision: `spoke`, `silent`, `later`, `closed`,
  `empty` or `delivery_failed`. Each is a run that finished, recorded as itself.
  `sent_text` is the message a `spoke` run sent; it rides as `output` only when
  content capture is on.
  """
  @spec run_complete(run(), String.t(), non_neg_integer(), String.t() | nil) :: :ok
  def run_complete(run, outcome, duration_ms, sent_text \\ nil)
      when is_map(run) and outcome in @outcomes and is_integer(duration_ms) and
             duration_ms >= 0 and (is_nil(sent_text) or is_binary(sent_text)) do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:outcome, outcome)
      |> maybe_put_output(sent_text)

    execute(@complete_event, %{duration_ms: duration_ms}, metadata)
  end

  @doc """
  Closes a run that never reached a decision: the watchdog (`timeout`) or a
  loop crash or provider failure (`error`).
  """
  @spec run_error(run(), String.t(), non_neg_integer(), term()) :: :ok
  def run_error(run, status, duration_ms, error)
      when is_map(run) and status in @statuses and is_integer(duration_ms) and
             duration_ms >= 0 do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:status, status)
      |> Map.put(:error, format_error(error))

    execute(@error_event, %{duration_ms: duration_ms}, metadata)
  end

  @doc """
  The scheduler declined to start a check-in. A sessionless point event: no run
  began, so there is nothing to correlate but the loop. `open_loop_id` is nil
  only when the skip concerns no single loop.
  """
  @spec skipped(String.t(), String.t() | nil) :: :ok
  def skipped(reason, open_loop_id)
      when reason in @skip_reasons and (is_nil(open_loop_id) or is_loop_id(open_loop_id)) do
    metadata = %{
      open_loop_id: open_loop_id,
      reason: reason,
      component: @scheduler_component
    }

    execute(@skipped_event, %{count: 1}, metadata)
  end

  @doc """
  A loop's state moved: an owner's answer (`by: "main_agent"`), a check-in's
  own write (`"checkin"`), or an expiry (`"scheduler"`). `from` is the live
  state the write left; `answer` is nil when no answer caused it; `session_id`
  is the settling turn's, nil when there is none.
  """
  @spec settled(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil
        ) ::
          :ok
  def settled(open_loop_id, from, to, answer, by, session_id)
      when is_loop_id(open_loop_id) and from in @live_states and to in @states and
             (is_nil(answer) or answer in @answers) and by in @settlers and
             (is_nil(session_id) or is_binary(session_id)) do
    metadata = %{
      open_loop_id: open_loop_id,
      from: from,
      to: to,
      answer: answer,
      by: by,
      component: @settle_component,
      session_id: session_id
    }

    execute(@settled_event, %{count: 1}, metadata)
  end

  @doc """
  A scheduler step failed: the boot `sweep`, a due `scan` (or a read it needed
  to weigh a due loop), a `claim`, a claim `release`, the `timer` read, or a
  check-in that could not `start_checkin`. A sessionless point event: no run
  began. `open_loop_id` is nil when the fault concerns no single loop.

  `error_class` is derived from `reason`, never passed through: an atom, or a
  tagged tuple's atom head, names the class, and anything else is
  `"unclassified"`. A reason's body can embed a destination or a vendor's words,
  so those stay in the scheduler's log line.
  """
  @spec fault(String.t(), String.t() | nil, term()) :: :ok
  def fault(stage, open_loop_id, reason)
      when stage in @fault_stages and (is_nil(open_loop_id) or is_loop_id(open_loop_id)) do
    metadata = %{
      stage: stage,
      open_loop_id: open_loop_id,
      component: @scheduler_component,
      error_class: error_class(reason)
    }

    execute(@fault_event, %{count: 1}, metadata)
  end

  @doc """
  A follow-up's outcome was recorded (M83 §07): the owner `replied` in the
  follow-up's conversation within the day, after `reply_after_ms`, or the day
  passed with `no_reply` (which carries no delay). `rung` is the follow-up's:
  1 raised in conversation, 2 sent by message. `session_id` is the observing
  turn's, nil when the caller has none. No text of the follow-up or the reply
  rides the event.
  """
  @spec reaction(String.t(), 1 | 2, String.t(), non_neg_integer() | nil, String.t() | nil) :: :ok
  def reaction(open_loop_id, rung, outcome, reply_after_ms, session_id)
      when is_loop_id(open_loop_id) and rung in @rungs and outcome in @reaction_outcomes and
             (is_nil(session_id) or is_binary(session_id)) do
    metadata = %{
      open_loop_id: open_loop_id,
      rung: rung,
      outcome: outcome,
      component: @settle_component,
      session_id: session_id
    }

    execute(@reaction_event, reaction_measurements(outcome, reply_after_ms), metadata)
  end

  defp reaction_measurements("replied", ms) when is_integer(ms) and ms >= 0,
    do: %{count: 1, reply_after_ms: ms}

  defp reaction_measurements("no_reply", nil), do: %{count: 1}

  defp base_metadata(run) do
    %{
      agent: Map.fetch!(run, :agent),
      session_id: Map.fetch!(run, :session_id),
      open_loop_id: Map.fetch!(run, :open_loop_id),
      touch: Map.fetch!(run, :touch),
      component: @checkin_component
    }
  end

  defp active_hours!(label) do
    if Regex.match?(@active_hours_label, label) do
      label
    else
      raise ArgumentError,
            "open-loop telemetry active hours must be an HH:MM-HH:MM label, got: " <>
              inspect(label)
    end
  end

  defp maybe_put_output(metadata, nil), do: metadata

  defp maybe_put_output(metadata, text) do
    if Telemetry.capture_content?() do
      Map.put(metadata, :output, Telemetry.preview(text))
    else
      metadata
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  # `Temporal.Telemetry`'s derivation: the class groups failures, and nothing
  # of the reason's body survives.
  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      head when is_atom(head) -> Atom.to_string(head)
      _other -> "unclassified"
    end
  end

  defp error_class(_reason), do: "unclassified"

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, compact(metadata))
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
