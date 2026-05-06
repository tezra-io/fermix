defmodule FermixCore.Introspection.Agents do
  @moduledoc """
  Read-only projection of the main agent and delegated skill workers.
  """

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.MainAgent

  @type snapshot :: %{
          main: map(),
          skill_workers: [map()],
          counts: %{
            skill_workers: non_neg_integer(),
            running_skill_workers: non_neg_integer()
          }
        }

  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(opts \\ []) when is_list(opts) do
    main_agent = Keyword.get(opts, :main_agent, MainAgent)
    supervisor = Keyword.get(opts, :agent_supervisor, AgentSupervisor)

    with {:ok, main} <- main_status(main_agent),
         {:ok, workers} <- worker_statuses(supervisor) do
      {:ok,
       %{
         main: main,
         skill_workers: workers,
         counts: counts(workers)
       }}
    end
  end

  defp main_status(server) do
    status =
      server
      |> MainAgent.status()
      |> normalize_main_status()

    {:ok, status}
  catch
    :exit, reason -> {:error, {:main_agent_unavailable, reason}}
  end

  defp worker_statuses(supervisor) do
    workers =
      supervisor
      |> AgentSupervisor.list_agents()
      |> Enum.map(&normalize_worker_status/1)

    {:ok, workers}
  catch
    :exit, reason -> {:error, {:agent_supervisor_unavailable, reason}}
  end

  defp counts(workers) when is_list(workers) do
    %{
      skill_workers: length(workers),
      running_skill_workers: Enum.count(workers, &(&1.status == :running))
    }
  end

  defp normalize_main_status(status) when is_map(status) do
    activity = Map.get(status, :activity, Map.get(status, :status, :unknown))

    %{
      name: Map.get(status, :name),
      health: Map.get(status, :health, :online),
      activity: activity,
      status: Map.get(status, :status, activity),
      pid: Map.get(status, :pid),
      active_conversations: Map.get(status, :active_conversations, 0),
      pending_conversations: Map.get(status, :pending_conversations, 0),
      active_requests: Map.get(status, :active_requests, 0),
      pending_requests: Map.get(status, :pending_requests, 0),
      available_skills: Map.get(status, :available_skills, []),
      provider: Map.get(status, :provider),
      model: Map.get(status, :model),
      memory: Map.get(status, :memory)
    }
  end

  defp normalize_worker_status(status) when is_map(status) do
    %{
      name: Map.get(status, :name),
      role: Map.get(status, :role),
      session_id: Map.get(status, :session_id),
      status: Map.get(status, :status),
      parent: Map.get(status, :parent),
      pid: Map.get(status, :pid)
    }
  end
end
