defmodule FermixCore.Realtime.SessionGuard do
  @moduledoc """
  A voice session never outlives the transport adapter that owns it, whatever
  the transport.

  An adapter (the Unix socket's connection handler today, a serial or
  WebSocket link and the phone's call channel later) has its session started
  HERE, from its own process (`start_session/4`). The guard monitors the
  adapter first and only then runs the start, so no session ever exists that
  the guard does not answer for: when the adapter exits for any reason (a
  clean stop, a crash, a kill), its bound session is torn down, and a session
  whose adapter is gone by the time its start returns is torn down the moment
  it arrives. A session that outlived its adapter would keep a billed provider
  socket open with no one listening, and hold the home's one call
  (`CallLease`), refusing every later call. An adapter that ends its call
  itself (`call_stop`) tears the session down and then releases it, so the
  guard forgets it.

  Nothing a session does runs on the guard's own loop, so a slow or failing
  engine can never hold up another adapter's teardown: a start runs in a task
  on the task supervisor and reports back, a crashed start is a typed failure,
  and a teardown runs in a task too. The adapter waits for its start at most
  `@start_timeout_ms`: past it the adapter is refused
  `session_start_timeout`, and a session the start still makes is torn down
  when it arrives.

  The guard answers for its sessions only while it runs, so it never
  restarts on its own: it is the FIRST child of a `:rest_for_one` tree with
  the task supervisor and the session supervisor after it
  (`Realtime.Supervisor`). A guard restart therefore ends every session it
  guarded and every start still running, instead of forgetting them, and the
  guard never raises on what it is sent: an unknown call is refused, an
  unknown cast or message logged.

  A session ends itself on `call_stop`, as every engine does (`{:stop,
  {:shutdown, :call_stop}, :ok, state}`), so `call_stop` is the whole
  teardown.
  """

  use GenServer

  require Logger

  # How long an adapter waits for its session to start. A start is an engine's
  # `init/1` (config, the call lease, its prompt) and opens no provider socket,
  # so a start that takes this long is stuck, not slow.
  @start_timeout_ms 15_000

  @typedoc """
  Starts the adapter's session: the engine start, or a test's double. It must
  not fail once its session exists: a session it made and did not return is
  one nothing guards.
  """
  @type starter :: (keyword() -> {:ok, pid()} | {:error, term()})

  @typedoc "An adapter's session, or the start still making it (`session: nil`)."
  @type binding :: %{
          ref: reference(),
          session: pid() | nil,
          session_module: module(),
          start: reference() | nil
        }

  @typedoc "A start in flight. `owner: nil` once its adapter is gone or refused."
  @type start :: %{
          owner: pid() | nil,
          from: GenServer.from() | nil,
          session_module: module(),
          timer: reference()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts the calling adapter's session with `starter.(opts)` and binds it to
  the adapter, which the guard monitors before the start runs. One session per
  adapter at a time. The starter's own refusal comes back as it was given; a
  start that crashes is `{:session_start_failed, reason}`, one past the bound
  `:session_start_timeout`, and a guard that is not running
  `:session_guard_unavailable`, in which case no session was started.

  The call waits with no timeout of its own: the guard answers every start
  within `@start_timeout_ms`, and a guard that exits ends the wait.
  """
  @spec start_session(GenServer.server(), starter(), keyword(), module()) ::
          {:ok, pid()} | {:error, term()}
  def start_session(guard, starter, opts, session_module)
      when is_function(starter, 1) and is_list(opts) and is_atom(session_module) do
    GenServer.call(guard, {:start, self(), starter, opts, session_module}, :infinity)
  catch
    :exit, reason -> unavailable(:start, reason)
  end

  @doc """
  Forgets the calling adapter's session, which the adapter has torn down
  itself. No timeout of its own: the guard answers every call from its own
  loop, which never waits on a session.
  """
  @spec release(GenServer.server()) :: :ok | {:error, :session_guard_unavailable}
  def release(guard) do
    GenServer.call(guard, {:release, self()}, :infinity)
  catch
    :exit, reason -> unavailable(:release, reason)
  end

  @doc """
  Ends a session's call, which ends the session: the one teardown, shared by
  the guard and by an adapter tearing down its own session. It may race a
  session already dying on its own, so an exit from the call is logged, not
  raised.
  """
  @spec teardown(pid(), module()) :: :ok
  def teardown(session, session_module) when is_pid(session) and is_atom(session_module) do
    if Process.alive?(session), do: session_module.call_stop(session)
    :ok
  catch
    :exit, reason ->
      Logger.debug("Realtime session teardown exited: #{inspect(reason)}")
      :ok
  end

  @impl true
  def init(opts) do
    {:ok, %{task_supervisor: Keyword.fetch!(opts, :task_supervisor), bindings: %{}, starts: %{}}}
  end

  @impl true
  def handle_call({:start, owner, starter, opts, session_module}, from, state) do
    case Map.fetch(state.bindings, owner) do
      {:ok, %{session: bound}} ->
        {:reply, {:error, {:already_bound, bound}}, state}

      :error ->
        start = %{owner: owner, from: from, session_module: session_module}
        begin_start(start, starter, opts, state)
    end
  end

  def handle_call({:release, owner}, _from, state) do
    {:reply, :ok, forget_owner(state, owner)}
  end

  def handle_call(request, _from, state) do
    Logger.warning("Realtime session guard refused an unknown call: #{inspect(request)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_cast(request, state) do
    Logger.warning("Realtime session guard ignored an unknown cast: #{inspect(request)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({start_ref, result}, %{starts: starts} = state)
      when is_map_key(starts, start_ref) do
    Process.demonitor(start_ref, [:flush])
    {:noreply, finish_start(state, start_ref, result)}
  end

  def handle_info({:DOWN, start_ref, :process, _task, reason}, %{starts: starts} = state)
      when is_map_key(starts, start_ref) do
    Logger.error("Realtime session guard: a session start crashed: #{inspect(reason)}")
    {:noreply, finish_start(state, start_ref, {:error, {:session_start_failed, reason}})}
  end

  def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
    case Map.pop(state.bindings, owner) do
      {%{ref: ^ref} = binding, bindings} ->
        {:noreply, owner_gone(binding, %{state | bindings: bindings})}

      {_unbound, _bindings} ->
        {:noreply, state}
    end
  end

  def handle_info({:start_timeout, start_ref}, state) do
    case Map.fetch(state.starts, start_ref) do
      {:ok, %{owner: owner, from: from}} when is_pid(owner) ->
        Logger.warning(
          "Realtime session guard: a session start passed #{@start_timeout_ms} ms; " <>
            "its adapter is refused, and a session it still makes is torn down"
        )

        GenServer.reply(from, {:error, :session_start_timeout})
        {:noreply, forget_owner(state, owner)}

      _done_or_abandoned ->
        {:noreply, state}
    end
  end

  # Never raises on a message it does not know: a guard restart ends every
  # session it guards.
  def handle_info(message, state) do
    Logger.warning("Realtime session guard ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # The adapter is monitored before its session can exist, so its exit is seen
  # whichever comes first, the exit or the started session.
  defp begin_start(start, starter, opts, state) do
    owner_ref = Process.monitor(start.owner)

    case run_start(state.task_supervisor, starter, opts) do
      {:ok, start_ref} ->
        timer = Process.send_after(self(), {:start_timeout, start_ref}, @start_timeout_ms)

        binding = %{
          ref: owner_ref,
          session: nil,
          session_module: start.session_module,
          start: start_ref
        }

        {:noreply,
         %{
           state
           | bindings: Map.put(state.bindings, start.owner, binding),
             starts: Map.put(state.starts, start_ref, Map.put(start, :timer, timer))
         }}

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        Logger.error("Realtime session guard could not run a session start: #{inspect(reason)}")
        {:reply, {:error, {:session_start_failed, reason}}, state}
    end
  end

  # Unlinked: a start that crashes reaches the guard as its `:DOWN`.
  defp run_start(task_supervisor, starter, opts) do
    %Task{ref: start_ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn -> starter.(opts) end)

    {:ok, start_ref}
  catch
    :exit, reason -> {:error, reason}
  end

  defp finish_start(state, start_ref, result) do
    {start, starts} = Map.pop!(state.starts, start_ref)
    _remaining = Process.cancel_timer(start.timer)
    settle_start(start, result, %{state | starts: starts})
  end

  # The start's adapter is gone or was refused: whatever it made is torn down.
  defp settle_start(%{owner: nil} = start, {:ok, session}, state) when is_pid(session) do
    start_teardown(session, start.session_module, state.task_supervisor)
    state
  end

  defp settle_start(%{owner: nil}, _failed, state), do: state

  defp settle_start(%{owner: owner, from: from}, {:ok, session}, state) when is_pid(session) do
    GenServer.reply(from, {:ok, session})
    bindings = Map.update!(state.bindings, owner, &%{&1 | session: session, start: nil})
    %{state | bindings: bindings}
  end

  defp settle_start(%{owner: owner, from: from}, {:error, _reason} = refused, state) do
    GenServer.reply(from, refused)
    forget_owner(state, owner)
  end

  defp settle_start(start, other, state) do
    Logger.error("Realtime session guard: a session start returned #{inspect(other)}")
    settle_start(start, {:error, {:session_start_failed, {:bad_return, other}}}, state)
  end

  # A bound session is torn down; a start still running is abandoned, so the
  # session it makes is torn down when it arrives.
  defp owner_gone(%{session: session} = binding, state) when is_pid(session) do
    start_teardown(session, binding.session_module, state.task_supervisor)
    state
  end

  defp owner_gone(%{start: start_ref}, state), do: abandon(state, start_ref)

  # A start with an owner always has that owner's binding: whatever drops the
  # binding abandons the start. A start that already finished is left alone.
  defp abandon(state, start_ref) do
    case Map.fetch(state.starts, start_ref) do
      {:ok, start} -> %{state | starts: Map.put(state.starts, start_ref, abandoned(start))}
      :error -> state
    end
  end

  defp abandoned(start), do: %{start | owner: nil, from: nil}

  defp forget_owner(state, owner) do
    case Map.pop(state.bindings, owner) do
      {nil, _bindings} ->
        state

      {binding, bindings} ->
        Process.demonitor(binding.ref, [:flush])
        abandon(%{state | bindings: bindings}, binding.start)
    end
  end

  # Never raises: a guard restart ends every session it guards.
  defp start_teardown(session, session_module, task_supervisor) do
    case Task.Supervisor.start_child(task_supervisor, fn -> teardown(session, session_module) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> teardown_not_started(session, reason)
    end
  catch
    :exit, reason -> teardown_not_started(session, reason)
  end

  defp teardown_not_started(session, reason) do
    Logger.error(
      "Realtime session guard could not tear down #{inspect(session)}: #{inspect(reason)}"
    )
  end

  defp unavailable(operation, reason) do
    Logger.error("Realtime session guard refused #{operation}: #{inspect(reason)}")
    {:error, :session_guard_unavailable}
  end
end
