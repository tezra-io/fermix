defmodule FermixCore.Introspection.Overview do
  @moduledoc """
  Aggregated runtime snapshot shared by CLI and future dashboard views.
  """

  alias FermixCore.Health
  alias FermixCore.Introspection.Agents
  alias FermixCore.Introspection.Capabilities
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.ConfigStore

  @spec snapshot(keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(opts \\ []) when is_list(opts) do
    health = Keyword.get_lazy(opts, :health_report, fn -> Health.report() end)

    with {:ok, agents} <- agent_snapshot(opts),
         {:ok, capabilities} <- capability_snapshot(opts) do
      {:ok,
       %{
         generated_at: Keyword.get(opts, :generated_at, DateTime.utc_now()),
         readiness: readiness(health),
         daemon: Keyword.get(opts, :daemon, unknown_daemon()),
         provider: provider_summary(),
         channels: Map.get(health, :channels, []),
         memory: memory_summary(health),
         jobs: jobs_summary(opts),
         agents: agent_summary(agents),
         realtime: realtime_summary(health),
         capabilities: Map.get(capabilities, :counts, empty_capability_counts()),
         paths: path_summary(health)
       }}
    end
  end

  defp agent_snapshot(opts) do
    case Keyword.fetch(opts, :main_agent_status) do
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, main} ->
        workers = Keyword.get(opts, :skill_workers, [])
        {:ok, %{main: main, skill_workers: workers, counts: worker_counts(workers)}}

      :error ->
        Agents.snapshot(opts)
    end
  end

  defp capability_snapshot(opts) do
    case Keyword.fetch(opts, :capabilities_snapshot) do
      {:ok, {:ok, snapshot}} -> {:ok, snapshot}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, snapshot} -> {:ok, snapshot}
      :error -> Capabilities.snapshot(opts)
    end
  end

  defp jobs_summary(opts) do
    jobs_result = read_injected_or(opts, :jobs, fn -> read_jobs(opts) end)

    running_result =
      read_injected_or(opts, :running_job_runs, fn -> read_runs("running", opts) end)

    failed_result = read_injected_or(opts, :failed_job_runs, fn -> read_runs("error", opts) end)

    jobs = list_or_empty(jobs_result)
    running_runs = list_or_empty(running_result)
    failed_runs = list_or_empty(failed_result)

    %{
      scheduled: count_jobs(jobs, "scheduled"),
      running: length(running_runs),
      paused: count_jobs(jobs, "paused"),
      failed_recent: length(failed_runs),
      next: next_job(jobs),
      status: jobs_status([jobs_result, running_result, failed_result]),
      error: jobs_error([jobs_result, running_result, failed_result])
    }
  end

  defp read_jobs(opts) do
    opts
    |> Keyword.get(:job_registry, JobsRegistry)
    |> apply(:list_jobs, [[repo: Keyword.get(opts, :repo, Repo)]])
  catch
    :exit, reason -> {:error, {:job_registry_unavailable, reason}}
  end

  defp read_runs(status, opts) do
    %{status: status}
    |> Repo.list_job_runs(server: Keyword.get(opts, :repo, Repo), limit: 20)
  catch
    :exit, reason -> {:error, {:job_runs_unavailable, status, reason}}
  end

  defp read_injected_or(opts, key, reader) when is_function(reader, 0) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, {:ok, value}} when is_list(value) -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      :error -> reader.()
    end
  end

  defp list_or_empty({:ok, value}) when is_list(value), do: value
  defp list_or_empty({:error, _reason}), do: []

  defp jobs_status(results) do
    if Enum.all?(results, &match?({:ok, _value}, &1)), do: :ready, else: :unavailable
  end

  defp jobs_error(results) do
    Enum.find_value(results, fn
      {:error, reason} -> inspect(reason)
      {:ok, _value} -> nil
    end)
  end

  defp count_jobs(jobs, state) do
    Enum.count(jobs, &(Map.get(&1, :state) == state))
  end

  defp next_job(jobs) when is_list(jobs) do
    jobs
    |> Enum.filter(&(Map.get(&1, :state) == "scheduled" and Map.get(&1, :next_run_at) != nil))
    |> Enum.sort_by(&(Map.get(&1, :next_run_at) |> DateTime.to_unix(:microsecond)))
    |> List.first()
    |> summarize_job()
  end

  defp next_job(_jobs), do: nil

  defp summarize_job(nil), do: nil

  defp summarize_job(job) when is_map(job) do
    %{
      id: Map.get(job, :id),
      name: Map.get(job, :name) || Map.get(job, :title) || Map.get(job, :description),
      next_run_at: Map.get(job, :next_run_at),
      state: Map.get(job, :state)
    }
  end

  defp agent_summary(%{main: main, counts: counts}) do
    activity = Map.get(main, :activity, Map.get(main, :status, :unknown))

    %{
      main: %{
        health: Map.get(main, :health, :online),
        activity: activity,
        status: Map.get(main, :status, activity),
        active_conversations: Map.get(main, :active_conversations, 0),
        pending_conversations: Map.get(main, :pending_conversations, 0)
      },
      skill_workers: Map.get(counts, :skill_workers, 0),
      running_skill_workers: Map.get(counts, :running_skill_workers, 0)
    }
  end

  defp worker_counts(workers) when is_list(workers) do
    %{
      skill_workers: length(workers),
      running_skill_workers: Enum.count(workers, &(Map.get(&1, :status) == :running))
    }
  end

  defp readiness(health) do
    %{status: Map.get(health, :status, :unknown), failures: Map.get(health, :failures, [])}
  end

  defp memory_summary(health) do
    paths = ConfigStore.workspace_paths()
    memory = Map.get(health, :memory, %{})

    %{
      database_path: Path.join(ConfigStore.fermix_home(), "memory.db"),
      repo: Map.get(memory, :repo, :unknown),
      conversation_store: Map.get(memory, :conversation_store, :unknown),
      store: Map.get(memory, :store, :unknown),
      paths: %{journals: paths.journals, bootstrap: paths.bootstrap, skills: paths.skills}
    }
  end

  defp path_summary(health) do
    paths = ConfigStore.workspace_paths()

    %{
      home: ConfigStore.fermix_home(),
      config: get_in(health, [:config, :path]) || ConfigStore.path(),
      logs: paths.logs,
      traces: paths.traces
    }
  end

  # Active provider tracks the primary flag (legacy agent.provider only as
  # migration input) so the overview can't drift after a primary switch.
  defp provider_summary do
    providers = Application.get_env(:fermix_core, :providers, [])

    case PrimaryConfig.primary() do
      {:ok, active} ->
        provider_config = Keyword.get(providers, active, [])

        %{
          active: active,
          model: Keyword.get(provider_config, :default_model),
          auth_mode: Keyword.get(provider_config, :auth_mode),
          reasoning_effort: Keyword.get(provider_config, :reasoning_effort)
        }

      {:error, :multiple_primary} ->
        %{active: :invalid_config, model: nil, auth_mode: nil, reasoning_effort: nil}
    end
  end

  defp empty_capability_counts, do: %{builtin: 0, skill: 0, mcp: 0, total: 0}
  defp unknown_daemon, do: %{status: :unknown, pid: nil, uptime_ms: nil}

  # Health.report/1 always returns a fully-shaped `:realtime` map; this is
  # a defensive fallback for the rare case where someone injects a partial
  # health report in tests.
  defp realtime_summary(health) do
    Map.get(health, :realtime, %{
      enabled: false,
      status: :unknown,
      provider: nil,
      model: nil,
      socket_path: nil,
      socket_alive: nil,
      active_sessions: 0,
      active_clients: 0,
      companion_connected?: false
    })
  end
end
