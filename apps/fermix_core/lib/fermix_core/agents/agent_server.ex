defmodule FermixCore.Agents.AgentServer do
  @moduledoc """
  Dynamic skill worker that runs one delegated task at a time.
  """

  use GenServer

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Tools.Registry

  @type run_context :: %{
          optional(:task_context) => String.t() | nil,
          optional(:tool_context) => map()
        }

  @type status :: %{
          name: String.t(),
          role: AgentDefinition.role(),
          session_id: String.t(),
          status: :idle | :running,
          parent: String.t() | nil
        }

  @type pending_task :: %{
          from: GenServer.from(),
          ref: reference(),
          pid: pid(),
          started_monotonic_ms: integer(),
          task_summary: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      registered_name -> GenServer.start_link(__MODULE__, opts, name: registered_name)
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :temporary),
      shutdown: 30_000,
      type: :worker
    }
  end

  @spec run_task(GenServer.server(), String.t(), run_context(), keyword()) ::
          {:ok, AgentLoop.loop_result()} | {:error, term()}
  def run_task(server, task, context \\ %{}, opts \\ [])
      when is_binary(task) and is_map(context) do
    GenServer.call(server, {:run_task, task, context}, Keyword.get(opts, :timeout, :infinity))
  end

  @spec get_status(GenServer.server()) :: status()
  def get_status(server) do
    GenServer.call(server, :get_status)
  end

  @spec stop(GenServer.server(), term()) :: :ok
  def stop(server, reason \\ :normal) do
    GenServer.stop(server, {:shutdown, reason})
  end

  @impl true
  def init(opts) do
    definition = Keyword.fetch!(opts, :definition)
    parent_pid = Keyword.get(opts, :parent)
    parent_ref = if is_pid(parent_pid), do: Process.monitor(parent_pid)
    started_at = DateTime.utc_now()

    state = %{
      definition: definition,
      session_id: Keyword.fetch!(opts, :session_id),
      status: :idle,
      parent_pid: parent_pid,
      parent_name: Keyword.get(opts, :parent_name),
      parent_session: Keyword.get(opts, :parent_session),
      parent_ref: parent_ref,
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      provider: Keyword.get(opts, :provider, FermixCore.Providers.OpenAI),
      registry: Keyword.get(opts, :registry, Registry),
      pending_task: nil,
      started_at: started_at,
      started_monotonic_ms: System.monotonic_time(:millisecond)
    }

    LifecycleTelemetry.agent_start(definition.name, definition.role, state.session_id,
      parent: state.parent_name,
      parent_session: state.parent_session
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply,
     %{
       name: state.definition.name,
       role: state.definition.role,
       session_id: state.session_id,
       status: state.status,
       parent: state.parent_name
     }, state}
  end

  def handle_call({:run_task, _task, _context}, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:run_task, task, context}, from, state) do
    task_summary = summarize_task(task)

    LifecycleTelemetry.agent_task_start(
      state.definition.name,
      state.definition.role,
      state.session_id,
      task_summary,
      parent: state.parent_name,
      parent_session: state.parent_session
    )

    async_task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        execute_task(
          state.definition,
          state.session_id,
          state.provider,
          state.registry,
          task,
          context
        )
      end)

    pending_task = %{
      from: from,
      ref: async_task.ref,
      pid: async_task.pid,
      started_monotonic_ms: System.monotonic_time(:millisecond),
      task_summary: task_summary
    }

    {:noreply, %{state | status: :running, pending_task: pending_task}}
  end

  @impl true
  def handle_info({ref, result}, %{pending_task: %{ref: ref} = pending_task} = state) do
    Process.demonitor(ref, [:flush])

    duration_ms = System.monotonic_time(:millisecond) - pending_task.started_monotonic_ms
    {reply, success, iterations} = normalize_task_result(result)

    LifecycleTelemetry.agent_task_complete(
      state.definition.name,
      state.definition.role,
      state.session_id,
      success,
      duration_ms,
      iterations,
      parent: state.parent_name,
      parent_session: state.parent_session
    )

    GenServer.reply(pending_task.from, reply)

    {:noreply, %{state | status: :idle, pending_task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{parent_ref: ref} = state) do
    state = stop_pending_task(state)
    {:stop, {:parent_down, reason}, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{pending_task: %{ref: ref} = pending_task} = state
      ) do
    duration_ms = System.monotonic_time(:millisecond) - pending_task.started_monotonic_ms

    LifecycleTelemetry.agent_task_complete(
      state.definition.name,
      state.definition.role,
      state.session_id,
      false,
      duration_ms,
      0,
      parent: state.parent_name,
      parent_session: state.parent_session
    )

    GenServer.reply(pending_task.from, {:error, {:task_crashed, reason}})

    {:noreply, %{state | status: :idle, pending_task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    stop_pending_task(state)

    duration_ms = System.monotonic_time(:millisecond) - state.started_monotonic_ms
    terminal_reason = normalize_stop_reason(reason)

    LifecycleTelemetry.agent_stop(
      state.definition.name,
      state.definition.role,
      state.session_id,
      terminal_reason,
      duration_ms,
      parent: state.parent_name,
      parent_session: state.parent_session
    )

    LifecycleTelemetry.supervisor_exit(
      state.definition.name,
      terminal_reason,
      not is_nil(state.parent_pid)
    )

    :ok
  end

  defp execute_task(definition, session_id, provider, registry, task, context) do
    messages = [
      %{role: "system", content: definition.system_prompt},
      %{role: "user", content: build_task_prompt(task, Map.get(context, :task_context))}
    ]

    tool_context =
      context
      |> Map.get(:tool_context, %{})
      |> Map.merge(%{agent_name: definition.name, session_id: session_id})

    loop_opts =
      [
        messages: messages,
        tools: Registry.all_tools_for_llm(registry, definition.allowed_tools),
        allowed_tools: definition.allowed_tools,
        provider: provider,
        max_iterations: definition.max_iterations,
        context: tool_context,
        registry: registry
      ]
      |> maybe_put(:model, definition.model)
      |> maybe_put(:temperature, definition.temperature)

    AgentLoop.run(loop_opts)
  end

  defp build_task_prompt(task, nil), do: "Task:\n#{task}"
  defp build_task_prompt(task, ""), do: "Task:\n#{task}"

  defp build_task_prompt(task, task_context) do
    """
    Task:
    #{task}

    Additional context:
    #{task_context}
    """
    |> String.trim()
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_task_result({:ok, %{iterations: iterations} = result}),
    do: {{:ok, result}, true, iterations}

  defp normalize_task_result({:error, reason}), do: {{:error, reason}, false, 0}
  defp normalize_task_result(result), do: {{:error, {:unexpected_result, result}}, false, 0}

  defp stop_pending_task(%{pending_task: nil} = state), do: state

  defp stop_pending_task(%{task_supervisor: task_supervisor, pending_task: %{pid: pid}} = state) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} -> Process.exit(pid, :kill)
    end

    %{state | pending_task: nil}
  end

  defp summarize_task(task) do
    task
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp normalize_stop_reason({:shutdown, reason}), do: normalize_stop_reason(reason)
  defp normalize_stop_reason({:parent_down, reason}), do: "parent_down: #{inspect(reason)}"
  defp normalize_stop_reason(reason), do: reason
end
