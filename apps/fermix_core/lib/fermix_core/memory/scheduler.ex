defmodule FermixCore.Memory.Scheduler do
  @moduledoc """
  Debounced event-driven and periodic prompt-memory rebuild scheduling.
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
    GenServer.cast(server, {:request_rebuild, agent_id, owner_id, reason})
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Config.scheduler_enabled?(opts),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      rebuild_module: Keyword.get(opts, :rebuild_module, PromptFiles),
      rebuild_opts: Keyword.get(opts, :rebuild_opts, []),
      periodic_interval_ms: Config.prompt_files_rebuild_interval_ms(opts),
      periodic_agent_ids: Keyword.get(opts, :periodic_agent_ids, [Config.agent_id(opts)]),
      periodic_owner_id: Keyword.get(opts, :periodic_owner_id, Config.owner_id(opts)),
      jobs: %{},
      task_refs: %{}
    }

    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:request_rebuild, agent_id, owner_id, reason}, state) do
    {:noreply, enqueue_rebuild(state, agent_id, owner_id, reason)}
  end

  @impl true
  def handle_info(:tick, state) do
    next_state =
      Enum.reduce(state.periodic_agent_ids, state, fn agent_id, acc ->
        enqueue_rebuild(acc, agent_id, state.periodic_owner_id, :periodic)
      end)

    schedule_tick(next_state)
    {:noreply, next_state}
  end

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

  defp schedule_tick(%{enabled: false}), do: :ok

  defp schedule_tick(%{periodic_interval_ms: interval_ms}),
    do: Process.send_after(self(), :tick, interval_ms)

  defp enqueue_rebuild(%{enabled: false} = state, _agent_id, _owner_id, _reason), do: state

  defp enqueue_rebuild(state, agent_id, owner_id, reason) do
    case Map.get(state.jobs, agent_id, empty_job(owner_id)) do
      %{active: nil} ->
        start_job(state, agent_id, owner_id, reason)

      job ->
        put_in(state.jobs[agent_id], %{
          job
          | pending: merge_pending(job.pending, owner_id, reason)
        })
    end
  end

  defp start_job(state, agent_id, owner_id, rebuild_reason) do
    parent = self()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           result =
             state.rebuild_module.rebuild(
               agent_id,
               owner_id,
               rebuild_reason,
               state.rebuild_opts
             )

           send(parent, {:rebuild_result, agent_id, rebuild_reason, result})
         end) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        state
        |> put_in(
          [:jobs, agent_id],
          %{
            active: %{owner_id: owner_id, reason: rebuild_reason, monitor_ref: monitor_ref},
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
      %{pending: %{owner_id: owner_id, reason: reason}} ->
        start_job(
          put_in(state.jobs[agent_id], %{active: nil, pending: nil}),
          agent_id,
          owner_id,
          reason
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

  defp merge_pending(nil, owner_id, reason), do: %{owner_id: owner_id, reason: reason}

  defp merge_pending(%{owner_id: existing_owner_id, reason: existing_reason}, owner_id, reason) do
    %{
      owner_id: owner_id || existing_owner_id,
      reason: merge_reason(existing_reason, reason)
    }
  end

  defp empty_job(_owner_id), do: %{active: nil, pending: nil}
end
