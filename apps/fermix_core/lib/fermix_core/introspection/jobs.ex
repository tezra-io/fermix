defmodule FermixCore.Introspection.Jobs do
  @moduledoc """
  Read-only projection of scheduled jobs for operator surfaces.
  """

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  @type snapshot :: %{
          status: :ready | :unavailable,
          error: String.t() | nil,
          counts: map(),
          jobs: [map()]
        }

  @spec snapshot(keyword()) :: {:ok, snapshot()}
  def snapshot(opts \\ []) when is_list(opts) do
    jobs_result = read_injected_or(opts, :jobs, fn -> read_jobs(opts) end)
    jobs = list_or_empty(jobs_result)

    {:ok,
     %{
       status: jobs_status(jobs_result),
       error: jobs_error(jobs_result),
       counts: counts(jobs),
       jobs: Enum.map(jobs, &job_row/1)
     }}
  end

  defp read_jobs(opts) do
    opts
    |> Keyword.get(:job_registry, Registry)
    |> apply(:list_jobs, [[repo: Keyword.get(opts, :repo, Repo)]])
  catch
    :exit, reason -> {:error, {:job_registry_unavailable, reason}}
  end

  defp read_injected_or(opts, key, reader) when is_function(reader, 0) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, {:ok, value}} when is_list(value) -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      :error -> reader.()
    end
  end

  defp list_or_empty({:ok, jobs}) when is_list(jobs), do: jobs
  defp list_or_empty({:error, _reason}), do: []

  defp jobs_status({:ok, _jobs}), do: :ready
  defp jobs_status({:error, _reason}), do: :unavailable

  defp jobs_error({:ok, _jobs}), do: nil
  defp jobs_error({:error, reason}), do: inspect(reason)

  defp counts(jobs) when is_list(jobs) do
    %{
      total: length(jobs),
      scheduled: count_state(jobs, "scheduled"),
      running: count_state(jobs, "running"),
      paused: count_state(jobs, "paused"),
      disabled: Enum.count(jobs, &(Map.get(&1, :enabled?) == false))
    }
  end

  defp count_state(jobs, state) do
    Enum.count(jobs, &(Map.get(&1, :state) == state))
  end

  defp job_row(job) when is_map(job) do
    %{
      id: Map.get(job, :id),
      name: Map.get(job, :name),
      description: Map.get(job, :description),
      state: Map.get(job, :state),
      enabled?: Map.get(job, :enabled?, false),
      schedule_kind: Map.get(job, :schedule_kind),
      schedule_expr: Map.get(job, :schedule_expr),
      timezone: Map.get(job, :timezone),
      next_run_at: Map.get(job, :next_run_at),
      last_run_at: Map.get(job, :last_run_at),
      last_status: Map.get(job, :last_status),
      last_error: Map.get(job, :last_error),
      delivery_mode: Map.get(job, :delivery_mode),
      memory_source_id: Map.get(job, :memory_source_id),
      created_by_agent_id: Map.get(job, :created_by_agent_id)
    }
  end
end
