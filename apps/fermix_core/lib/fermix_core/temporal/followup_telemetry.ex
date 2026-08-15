defmodule FermixCore.Temporal.FollowupTelemetry do
  @moduledoc """
  Bookend telemetry for one post-delivery follow-up run (M30 §22.7).

  A follow-up calls `AgentLoop.run/1` in its own context, so it is a run kind
  under `docs/TELEMETRY_CONTRACT.md` and owes the full obligations that carries:
  a unique `session_id`, lifecycle bookends, and errors traced before the run
  ends. Its provider and tool spans need no mapping of their own — they ride the
  shared `[:fermix, :provider, :call]` / `[:fermix, :tool, :exec]` events and
  nest under the same `session_id` these bookends carry.

      [:fermix, :reminder, :followup_start]
      [:fermix, :reminder, :followup_complete]
      [:fermix, :reminder, :followup_error]

  This is deliberately NOT `Temporal.Telemetry`: that emitter belongs to the
  delivery rail, which calls no model and accepts no session (§6.4). The split
  is exactly the line §22.7 draws — has a session or not. Pre-run skips, which
  never reach a model, stay on the lifecycle event as the `:followup_skipped`
  phase.

  There is no `parent_session`: the turn that stored the event closed hours or
  days before delivery, so the run is a root trace rather than a resurrection of
  a closed one (the memory-reviewer and harness precedents).

  The one owner-facing string the run can produce — the message it actually
  sent — rides only behind `FermixCore.Telemetry.capture_content?/0`.
  """

  alias FermixCore.Telemetry

  @start_event [:fermix, :reminder, :followup_start]
  @complete_event [:fermix, :reminder, :followup_complete]
  @error_event [:fermix, :reminder, :followup_error]

  @component "temporal_followup"

  @trace_event_definitions [
    %{
      event: @start_event,
      trace_event: "reminder_followup_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @complete_event,
      trace_event: "reminder_followup_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @error_event,
      trace_event: "reminder_followup_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  The identity of one follow-up run, derived from the reminder row it trails.

  One derivation, two consumers: the loop context takes its `session_id` and
  `agent_name` from here, so the run's provider and tool spans correlate with
  these bookends by construction rather than by two call sites agreeing.
  """
  @spec correlation(map()) :: map()
  def correlation(row) when is_map(row) do
    %{
      session_id: "followup_" <> row.id,
      agent: "followup:" <> row.event_id,
      event_id: row.event_id,
      reminder_id: row.id,
      occurrence_key: Map.get(row, :occurrence_key)
    }
  end

  @doc """
  Opens the run's trace, before the first provider call.

  `max_duration_ms` is the run's wall-clock watchdog, carried so the exporter
  sweeps by the run's own ceiling rather than its idle TTL — the two are the
  same 120s by default, and an idle-swept root would tombstone the closer of a
  run whose first provider call was merely slow (the jobs precedent).
  """
  @spec run_start(map(), pos_integer()) :: :ok
  def run_start(run, max_duration_ms)
      when is_map(run) and is_integer(max_duration_ms) and max_duration_ms > 0 do
    metadata = Map.put(base_metadata(run), :max_duration_ms, max_duration_ms)
    execute(@start_event, %{count: 1}, metadata)
  end

  @doc """
  Closes a run that reached a decision — `sent`, `declined`, `empty`, or
  `delivery_failed` (§22.8). Declining is a success, recorded as itself.
  """
  @spec run_complete(map(), String.t(), non_neg_integer(), String.t() | nil) :: :ok
  def run_complete(run, outcome, duration_ms, sent_text \\ nil)
      when is_map(run) and is_binary(outcome) and is_integer(duration_ms) and duration_ms >= 0 do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:outcome, outcome)
      |> maybe_put_output(sent_text)

    execute(@complete_event, %{duration_ms: duration_ms}, metadata)
  end

  @doc """
  Closes a run that never reached one — a loop crash, a provider failure, or the
  wall-clock watchdog. `status` is the §22.8 outcome word (`error`/`timeout`).
  """
  @spec run_error(map(), String.t(), non_neg_integer(), term()) :: :ok
  def run_error(run, status, duration_ms, error)
      when is_map(run) and is_binary(status) and is_integer(duration_ms) and duration_ms >= 0 do
    metadata =
      run
      |> base_metadata()
      |> Map.put(:status, status)
      |> Map.put(:error, format_error(error))

    execute(@error_event, %{duration_ms: duration_ms}, metadata)
  end

  defp base_metadata(run) do
    %{
      agent: Map.fetch!(run, :agent),
      session_id: Map.fetch!(run, :session_id),
      event_id: Map.fetch!(run, :event_id),
      reminder_id: Map.fetch!(run, :reminder_id),
      occurrence_key: Map.get(run, :occurrence_key),
      component: @component
    }
  end

  defp maybe_put_output(metadata, nil), do: metadata

  defp maybe_put_output(metadata, text) when is_binary(text) do
    if Telemetry.capture_content?() do
      Map.put(metadata, :output, Telemetry.preview(text))
    else
      metadata
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, compact(metadata))
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
