defmodule FermixCore.Tools.ListJobRuns do
  @moduledoc """
  List the recorded execution history of a scheduled job.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @default_limit 20
  @max_limit 100

  @impl true
  def name, do: "list_job_runs"

  @impl true
  def description do
    "List the execution history of a scheduled job: each run's status, trigger, " <>
      "timing, final response, and any error. Use this to see whether a job has " <>
      "been firing and what its runs produced."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["job_id"],
      properties: %{
        job_id: %{type: "string", description: "Scheduled job id whose runs to list."},
        status: %{
          type: "string",
          enum: ["queued", "running", "ok", "error"],
          description: "Optional status filter; omit to list runs of every status."
        },
        limit: %{
          type: "integer",
          minimum: 1,
          maximum: @max_limit,
          description: "Maximum runs to return, newest first (default 20)."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Inspect a scheduled job's run history — confirm it is firing, or read past outcomes and errors."
  end

  @impl true
  def examples do
    [%{args: %{"job_id" => "weather_abc", "status" => "error"}, note: "see failed runs of a job"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_job_id", description: "job_id is absent or blank"},
      %{tag: "registry_failed", description: "job run query failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, job_id} <- Support.required_string(args, "job_id") do
      selector = build_selector(job_id, args)

      case Repo.list_job_runs(selector, server: Support.repo(context), limit: limit(args)) do
        {:ok, runs} -> Support.success_json(%{runs: Enum.map(runs, &Support.job_run_summary/1)})
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  defp build_selector(job_id, args) do
    case Support.optional_string(args, "status") do
      nil -> %{job_id: job_id}
      status -> %{job_id: job_id, status: status}
    end
  end

  defp limit(args) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, @max_limit)
      _other -> @default_limit
    end
  end
end
