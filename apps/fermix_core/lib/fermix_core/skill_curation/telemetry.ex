defmodule FermixCore.SkillCuration.Telemetry do
  @moduledoc """
  Telemetry emitters for the `skill_curation` run kind
  (MILESTONE_26_SKILL_CURATION §9, modeled on `FermixCore.Jobs.Telemetry`).

  Cycle sessions are minted before any turn exists (`skill_curation:<rand>`;
  creation tasks `skill_curation:create:<token>`), so the run bookends carry
  the `session_id` that nests the bounded provider calls. `proposal_actioned`
  is a point event: owner actions land days after the cycle trace has shipped,
  so the exporter gives it a self-closing trace instead of a child span.
  """

  @run_start_event [:fermix, :skill_curation, :run_start]
  @run_complete_event [:fermix, :skill_curation, :run_complete]
  @run_error_event [:fermix, :skill_curation, :run_error]
  @proposal_actioned_event [:fermix, :skill_curation, :proposal_actioned]

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "skill_curation_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "skill_curation_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "skill_curation_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @proposal_actioned_event,
      trace_event: "skill_curation_proposal_actioned",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc "The run identity threaded through a cycle or creation task."
  @type run_meta :: %{
          required(:session_id) => String.t(),
          required(:stage) => :cycle | :create,
          required(:trigger) => :scheduled | :manual | :approval,
          optional(:parent_session) => String.t() | nil
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec run_start(run_meta()) :: :ok
  def run_start(meta) when is_map(meta) do
    execute(@run_start_event, %{}, base_metadata(meta))
  end

  @doc """
  Close a successful run. `counts` carries the §9 count fields
  (messages_scanned, candidates, dropped_*, deferred, proposals_*,
  delivery_status, …) — counts only, never content.
  """
  @spec run_complete(run_meta(), map()) :: :ok
  def run_complete(meta, counts) when is_map(meta) and is_map(counts) do
    metadata =
      meta
      |> base_metadata()
      |> Map.put(:status, "ok")
      |> Map.merge(counts)

    execute(@run_complete_event, %{count: 1}, metadata)
  end

  @spec run_error(run_meta(), atom(), term()) :: :ok
  def run_error(meta, reason_kind, reason) when is_map(meta) and is_atom(reason_kind) do
    metadata =
      meta
      |> base_metadata()
      |> Map.put(:status, "error")
      |> Map.put(:reason_kind, reason_kind)
      |> Map.put(:error, format_error(reason))

    execute(@run_error_event, %{count: 1}, metadata)
  end

  @spec proposal_actioned(String.t(), String.t(), non_neg_integer()) :: :ok
  def proposal_actioned(action, kind, age_ms)
      when action in ["approve", "deny", "unpark", "expire"] and is_binary(kind) and
             is_integer(age_ms) and age_ms >= 0 do
    execute(@proposal_actioned_event, %{count: 1, age_ms: age_ms}, %{
      agent: "skill_curation",
      action: action,
      kind: kind
    })
  end

  defp base_metadata(meta) do
    %{
      agent: "skill_curation",
      session_id: Map.fetch!(meta, :session_id),
      parent_session: Map.get(meta, :parent_session),
      stage: Map.fetch!(meta, :stage),
      trigger: Map.fetch!(meta, :trigger)
    }
  end

  # Bounded: an error term can embed request/window content via inspect —
  # never let it ride telemetry whole.
  defp format_error(error) when is_binary(error), do: String.slice(error, 0, 500)
  defp format_error(error), do: error |> inspect() |> String.slice(0, 500)

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, compact_map(metadata))
  end

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
