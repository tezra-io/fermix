defmodule FermixCore.Agents.AgentSupervisor do
  @moduledoc """
  Dynamic supervisor for delegated skill workers.
  """

  use DynamicSupervisor

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentServer
  alias FermixCore.Agents.LifecycleTelemetry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @spec spawn_agent(Supervisor.supervisor(), AgentDefinition.t(), keyword()) ::
          {:ok, pid(), String.t()} | {:error, term()}
  def spawn_agent(supervisor \\ __MODULE__, %AgentDefinition{} = definition, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    child_opts = [
      definition: definition,
      session_id: session_id,
      restart: restart_strategy(definition),
      parent: Keyword.get(opts, :parent),
      parent_name: Keyword.get(opts, :parent_name),
      parent_session: Keyword.get(opts, :parent_session),
      provider: Keyword.get(opts, :provider, FermixCore.Providers.OpenAI),
      registry: Keyword.get(opts, :registry, FermixCore.Tools.Registry),
      capability_registry:
        Keyword.get(opts, :capability_registry, FermixCore.Capabilities.Registry),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    ]

    case DynamicSupervisor.start_child(supervisor, {AgentServer, child_opts}) do
      {:ok, pid} ->
        LifecycleTelemetry.supervisor_spawn(
          definition.name,
          definition.persistent,
          Keyword.get(opts, :parent_name, "unknown")
        )

        {:ok, pid, session_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec stop_agent(Supervisor.supervisor(), pid() | String.t(), term()) ::
          :ok | {:error, term()}
  def stop_agent(supervisor \\ __MODULE__, name_or_pid, reason \\ :normal)

  def stop_agent(_supervisor, pid, reason) when is_pid(pid) do
    if Process.alive?(pid) do
      AgentServer.stop(pid, reason)
      :ok
    else
      {:error, :not_found}
    end
  end

  def stop_agent(supervisor, name, reason) when is_binary(name) do
    case find_agent(supervisor, name) do
      nil -> {:error, :not_found}
      pid -> stop_agent(supervisor, pid, reason)
    end
  end

  @spec list_agents(Supervisor.supervisor()) :: [map()]
  def list_agents(supervisor \\ __MODULE__) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
      case safe_status(pid) do
        {:ok, status} -> [Map.put(status, :pid, pid)]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&{&1.name, &1.session_id})
  end

  @spec find_agent(Supervisor.supervisor(), String.t()) :: pid() | nil
  def find_agent(supervisor \\ __MODULE__, name) when is_binary(name) do
    Enum.find_value(list_agents(supervisor), fn
      %{name: ^name, pid: pid} -> pid
      _other -> nil
    end)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp safe_status(pid) do
    {:ok, AgentServer.get_status(pid)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp restart_strategy(%AgentDefinition{persistent: true}), do: :permanent
  defp restart_strategy(_definition), do: :temporary

  defp generate_session_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
