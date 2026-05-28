defmodule FermixCore.Memory.Scheduler do
  @moduledoc """
  Debounced event-driven prompt-memory rebuild scheduling.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.PromptFiles

  @type rebuild_reason :: :event | :periodic

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec request_rebuild(String.t(), String.t(), rebuild_reason(), keyword()) :: :ok
  def request_rebuild(agent_id, owner_id, reason, opts \\ [])
      when is_binary(agent_id) and is_binary(owner_id) and reason in [:event, :periodic] do
    server = Keyword.get(opts, :server, __MODULE__)

    GenServer.cast(
      server,
      {:request_rebuild, agent_id, owner_id, reason, provenance(reason, opts)}
    )
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Config.scheduler_enabled?(opts),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      rebuild_module: Keyword.get(opts, :rebuild_module, PromptFiles),
      rebuild_opts: Keyword.get(opts, :rebuild_opts, []),
      jobs: %{},
      task_refs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:request_rebuild, agent_id, owner_id, reason, provenance}, state) do
    {:noreply, enqueue_rebuild(state, agent_id, owner_id, reason, provenance)}
  end

  @impl true
  def handle_info({:rebuild_result, agent_id, reason, {:error, rebuild_reason}}, state) do
    Logger.error("memory rebuild failed for #{agent_id} (#{reason}): #{inspect(rebuild_reason)}")

    {:noreply, state}
  end

  def handle_info({:rebuild_result, _agent_id, _reason, {:ok, _result}}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _task_refs} ->
        {:noreply, state}

      {agent_id, task_refs} ->
        {:noreply, complete_job(%{state | task_refs: task_refs}, agent_id)}
    end
  end

  defp enqueue_rebuild(%{enabled: false} = state, _agent_id, _owner_id, _reason, _provenance),
    do: state

  defp enqueue_rebuild(state, agent_id, owner_id, reason, provenance) do
    case Map.get(state.jobs, agent_id, empty_job(owner_id)) do
      %{active: nil} ->
        start_job(state, agent_id, owner_id, reason, provenance)

      job ->
        put_in(state.jobs[agent_id], %{
          job
          | pending: merge_pending(job.pending, owner_id, reason, provenance)
        })
    end
  end

  defp start_job(state, agent_id, owner_id, rebuild_reason, provenance) do
    parent = self()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           result =
             state.rebuild_module.rebuild(
               agent_id,
               owner_id,
               rebuild_reason,
               Keyword.put(state.rebuild_opts, :provenance, provenance)
             )

           send(parent, {:rebuild_result, agent_id, rebuild_reason, result})
         end) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        state
        |> put_in(
          [:jobs, agent_id],
          %{
            active: %{
              owner_id: owner_id,
              reason: rebuild_reason,
              provenance: provenance,
              monitor_ref: monitor_ref
            },
            pending: nil
          }
        )
        |> update_in([:task_refs], &Map.put(&1, monitor_ref, agent_id))

      {:error, start_reason} ->
        Logger.error("failed to start memory rebuild for #{agent_id}: #{inspect(start_reason)}")
        state
    end
  end

  defp complete_job(state, agent_id) do
    case Map.get(state.jobs, agent_id) do
      %{pending: %{owner_id: owner_id, reason: reason, provenance: provenance}} ->
        start_job(
          put_in(state.jobs[agent_id], %{active: nil, pending: nil}),
          agent_id,
          owner_id,
          reason,
          provenance
        )

      %{pending: nil} ->
        update_in(state.jobs, &Map.delete(&1, agent_id))

      nil ->
        state
    end
  end

  defp merge_reason(nil, reason), do: reason
  defp merge_reason(:event, _reason), do: :event
  defp merge_reason(:periodic, :event), do: :event
  defp merge_reason(:periodic, :periodic), do: :periodic

  defp merge_pending(nil, owner_id, reason, provenance) do
    %{owner_id: owner_id, reason: reason, provenance: provenance}
  end

  defp merge_pending(pending, owner_id, reason, provenance) do
    existing_reason = pending.reason
    merged_reason = merge_reason(existing_reason, reason)

    %{
      owner_id: owner_id || pending.owner_id,
      reason: merged_reason,
      provenance: merge_provenance(pending.provenance, provenance, merged_reason, reason)
    }
  end

  defp merge_provenance(_existing, provenance, reason, reason), do: provenance
  defp merge_provenance(existing, _provenance, _merged_reason, _new_reason), do: existing

  defp provenance(:periodic, opts), do: Keyword.get(opts, :provenance, scheduler_provenance())
  defp provenance(:event, opts), do: Keyword.get(opts, :provenance)

  defp scheduler_provenance do
    %{
      trigger: "scheduler_rebuild",
      rebuild_reason: "periodic",
      description: "Periodic prompt file rebuild under current policy"
    }
  end

  defp empty_job(_owner_id), do: %{active: nil, pending: nil}
end
