defmodule FermixCore.Management.Telemetry do
  @moduledoc """
  Telemetry emitters for the management run kinds: the `doctor` session and the
  `management_job` family (M34 §2, §5, native setup §7.3).

  A management operation that is a *run* is minted with its own `session_id`
  before any work executes, has a monotonic whole-run budget, and can be
  cancelled — so it needs lifecycle bookends to be readable at all. Two families
  qualify: a Doctor session (`doctor:<rand>`) and a management job
  (`job:<rand>`), and a provider call made inside a job carries the job's id as
  its `session_id` so the metered call nests under the run that issued it.
  Lifecycle leases, log queries, and diagnostics builds are single bounded
  request/response operations with no run identity; they deliberately mint no
  session and emit no telemetry.

  Modeled on `FermixCore.SkillCuration.Telemetry`. Counts only — a check summary
  can carry operator paths, so no summary or evidence text rides telemetry.
  """

  @session_start_event [:fermix, :doctor, :session_start]
  @session_complete_event [:fermix, :doctor, :session_complete]
  @session_error_event [:fermix, :doctor, :session_error]
  @job_start_event [:fermix, :management_job, :start]
  @job_complete_event [:fermix, :management_job, :complete]

  @trace_event_definitions [
    %{
      event: @session_start_event,
      trace_event: "doctor_session_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @session_complete_event,
      trace_event: "doctor_session_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @session_error_event,
      trace_event: "doctor_session_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @job_start_event,
      trace_event: "management_job_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @job_complete_event,
      trace_event: "management_job_complete",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc "The run identity threaded through one Doctor session."
  @type run_meta :: %{
          required(:session_id) => String.t(),
          required(:scope) => :local | :network,
          required(:budget_ms) => pos_integer(),
          optional(:parent_session) => String.t() | nil
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec session_start(run_meta(), non_neg_integer()) :: :ok
  def session_start(meta, check_count) when is_map(meta) and is_integer(check_count) do
    execute(@session_start_event, %{checks: check_count}, base_metadata(meta))
  end

  @doc """
  Close a session that reached a terminal state. `status` is the run's terminal
  word (`completed`, `cancelled`, `timed_out`) — the diagnosis, never a bare
  "ok" — and `counts` carries per-status check tallies only.
  """
  @spec session_complete(run_meta(), String.t(), non_neg_integer(), map()) :: :ok
  def session_complete(meta, status, duration_ms, counts)
      when is_map(meta) and is_binary(status) and is_integer(duration_ms) and duration_ms >= 0 and
             is_map(counts) do
    metadata =
      meta
      |> base_metadata()
      |> Map.put(:status, status)
      |> Map.merge(counts)

    execute(@session_complete_event, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  @spec session_error(run_meta(), atom(), term()) :: :ok
  def session_error(meta, reason_kind, reason) when is_map(meta) and is_atom(reason_kind) do
    metadata =
      meta
      |> base_metadata()
      |> Map.put(:status, "error")
      |> Map.put(:reason_kind, reason_kind)
      |> Map.put(:error, format_error(reason))

    execute(@session_error_event, %{count: 1}, metadata)
  end

  @typedoc "The run identity threaded through one management job."
  @type job_meta :: %{
          required(:job_id) => String.t(),
          required(:kind) => atom(),
          required(:budget_ms) => pos_integer()
        }

  @doc "Open one management job's run, before its body executes."
  @spec job_start(job_meta()) :: :ok
  def job_start(meta) when is_map(meta) do
    execute(@job_start_event, %{count: 1}, job_metadata(meta))
  end

  @doc """
  Close a management job that reached a terminal state. `status` is the run's
  terminal word (`completed`, `failed`, `cancelled`, `timed_out`) — never a
  generic "ok" — and `failure` is the public failure record or `nil`. The
  sentence is the daemon's own operator-facing copy, so it rides the bookend;
  no operation result ever does.
  """
  @spec job_complete(job_meta(), String.t(), non_neg_integer(), map() | nil) :: :ok
  def job_complete(meta, status, duration_ms, failure)
      when is_map(meta) and is_binary(status) and is_integer(duration_ms) and duration_ms >= 0 do
    metadata =
      meta
      |> job_metadata()
      |> Map.put(:status, status)
      |> Map.put(:failure_code, failure && Map.get(failure, "code"))
      |> Map.put(:error, failure && Map.get(failure, "sentence"))

    execute(@job_complete_event, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  defp job_metadata(meta) do
    %{
      agent: "management_job",
      session_id: Map.fetch!(meta, :job_id),
      kind: Map.fetch!(meta, :kind),
      budget_ms: Map.fetch!(meta, :budget_ms)
    }
  end

  defp base_metadata(meta) do
    %{
      agent: "doctor",
      session_id: Map.fetch!(meta, :session_id),
      parent_session: Map.get(meta, :parent_session),
      scope: Map.fetch!(meta, :scope),
      budget_ms: Map.fetch!(meta, :budget_ms)
    }
  end

  # An exit reason can embed a check's captured detail through inspect — never
  # let it ride telemetry whole.
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
