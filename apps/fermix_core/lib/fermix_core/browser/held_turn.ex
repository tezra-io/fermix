defmodule FermixCore.Browser.HeldTurn do
  @moduledoc """
  A server's turn, on the computer whose browser it uses (M97 §6.4): the
  one process here that stands for it, so the browser treats each of the
  turn's requests as one turn's.

  A pane task is bound to the process that made its first call and ends when
  that process ends (`HostServer`), and a turn whose pane went away is marked
  against that same process (`TurnMarker`). Here each request of a server's
  turn arrives as an invocation of its own, run by a process that ends with
  it, so every request is made from this process instead (`run/3`): the pane
  task and its tabs live across the turn's requests, a sign-in's two halves
  included, and a lost pane answers every later request of the turn the same
  way, as on the server's own browser.

  One per server turn, by the turn's session id and its conversation (both
  in the request). It ends:
    * when the server says the turn ended (`finish/3`, the server's
      `Browser.ComputerTurn`): normally, so a turn that handed its tabs to the
      person keeps its pane task for the conversation's next turn, as a turn
      on the server does; or stopped (cancelled or crashed), which ends it;
    * when the conversation's next turn makes its first request here before
      that word arrived: on the server a conversation's turns run one at a
      time, so the earlier one is over. It ends normally first, as its own
      end would, and only then does the next turn's request run, so the pane
      task it held never passes to the next turn and ends under it. A
      delegated worker (origin `worker`) works inside its turn, in its tab,
      as on the server: its requests end no other turn;
    * with the run of the request it runs (INVOKE-1): each request is linked
      to the invocation's run for as long as it runs here, so whatever ends
      that run (the master switch off, a cancel, a deadline, a restart of the
      computer's invocations) ends the request and this turn with it, and
      its pane task ends as a stopped turn's does. A request whose run ended
      before this process took it is never started;
    * when this computer's master or `browser` switch goes off (`stop_all/1`,
      from `Browser.HeldTurnListener`), stopped;
    * after #{div(10 * 60_000, 60_000)} minutes with no request, normally: the bound
      for a server that never says so (its link dropped).

  Requests run one at a time, in order, which is how a turn makes them.
  """

  use GenServer, restart: :temporary

  require Logger

  @idle_ms 10 * 60_000
  @max_attempts 3
  # How long the conversation's earlier turn may take to answer the request
  # it still runs before it is ended where it stands.
  @supersede_ms 30_000
  @session ~r/\A[A-Za-z0-9._:-]{1,128}\z/

  @typedoc "Where the held turns live: their registry and their supervisor."
  @type seams :: %{registry: atom(), supervisor: atom()}

  @typedoc """
  The server's turn a request comes from: its session id, the conversation
  it belongs to, and whether it is a delegated worker's.
  """
  @type turn :: %{session: String.t(), conversation: String.t(), worker?: boolean()}

  @typedoc "How the server's turn ended: `ended` normally, `stopped` otherwise."
  @type ending :: String.t()

  @doc "The production registry and supervisor (`Browser.Supervisor`)."
  @spec seams() :: seams()
  def seams,
    do: %{registry: FermixCore.Browser.Turns, supervisor: FermixCore.Browser.TurnSupervisor}

  @doc "Whether `session_id` is a turn's session id as the wire carries it."
  @spec session?(term()) :: boolean()
  def session?(session_id), do: is_binary(session_id) and Regex.match?(@session, session_id)

  @doc """
  Runs `fun` in the process that stands for the server's turn `turn`,
  started on its first request, and answers what `fun` answered. The
  caller's end ends `fun` where it stands (the moduledoc).
  """
  @spec run(seams(), turn(), (-> term())) :: term()
  def run(%{registry: _, supervisor: _} = seams, turn, fun) when is_function(fun, 0) do
    %{session: session, conversation: conversation, worker?: worker?} = turn
    true = session?(session) and is_binary(conversation) and is_boolean(worker?)
    run(seams, turn, fun, @max_attempts)
  end

  @doc """
  The server's turn `session_id` ended (`"ended"`) or was stopped
  (`"stopped"`): its process ends once the request it runs, if any, is
  answered. A turn with no process here is already done.
  """
  @spec finish(seams(), String.t(), ending()) :: :ok
  def finish(%{registry: registry}, session_id, ending) when ending in ["ended", "stopped"] do
    true = session?(session_id)

    registry
    |> Registry.select([{{{:held_turn, session_id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&GenServer.cast(&1, {:finish, reason(ending)}))
  end

  @doc """
  Ends every turn held here at once, stopped, the request each runs
  included: this computer's master or `browser` switch went off
  (`Browser.HeldTurnListener`). Each one's pane task ends with it, whatever
  it handed over.
  """
  @spec stop_all(seams()) :: :ok
  def stop_all(%{supervisor: supervisor}) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) do
      case DynamicSupervisor.terminate_child(supervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    :ok
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    turn = Keyword.fetch!(opts, :turn)
    name = {:via, Registry, {Keyword.fetch!(opts, :registry), key(turn), turn.worker?}}
    GenServer.start_link(__MODULE__, turn.session, name: name)
  end

  @impl true
  def init(session_id), do: {:ok, arm(%{session: session_id, idle: nil})}

  # The request runs linked to its caller, the invocation's run, so the run's
  # end is the request's; a caller already gone is answered by nothing and
  # its request never starts.
  @impl true
  def handle_call({:run, fun}, {caller, _tag}, state) do
    case link(caller) do
      :linked ->
        answer = fun.()
        true = Process.unlink(caller)
        {:reply, answer, arm(state)}

      :gone ->
        Logger.info("held browser turn #{state.session}: a request whose run ended was dropped")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:finish, reason}, state), do: {:stop, reason, state}

  @impl true
  def handle_info({:idle, ref}, %{idle: ref} = state), do: {:stop, :normal, state}
  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("held browser turn #{state.session}: dropped #{inspect(message)}")
    {:noreply, state}
  end

  # A process that ended between its lookup and the call (its turn finished,
  # or it idled out) ran nothing: a fresh one is started, a bounded number of
  # times.
  defp run(_seams, turn, _fun, 0),
    do: raise("the browser turn #{turn.session} could not be held here")

  defp run(seams, turn, fun, attempts) do
    GenServer.call(ensure(seams, turn), {:run, fun}, :infinity)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal] ->
      run(seams, turn, fun, attempts - 1)

    :exit, {{:shutdown, _why}, _call} ->
      run(seams, turn, fun, attempts - 1)
  end

  defp ensure(seams, turn) do
    case Registry.lookup(seams.registry, key(turn)) do
      [{pid, _worker?}] ->
        pid

      [] ->
        :ok = supersede(seams, turn)
        start(seams, turn)
    end
  end

  defp start(seams, turn) do
    spec = {__MODULE__, registry: seams.registry, turn: turn}

    case DynamicSupervisor.start_child(seams.supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # A conversation's own turn takes it over: every other turn held here for
  # the conversation, and every worker of one, has ended on the server.
  defp supersede(_seams, %{worker?: true}), do: :ok

  defp supersede(seams, %{session: session, conversation: conversation}) do
    seams.registry
    |> Registry.select([{{{:held_turn, :"$1", conversation}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {other, pid} -> if other != session, do: superseded(pid) end)
  end

  # The earlier turn ends as its own end would, normally, once the request
  # it runs is answered, so a tab it handed over waits for this turn; one
  # still running past the bound is ended where it stands.
  defp superseded(pid) do
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:finish, :normal})

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @supersede_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end

  defp link(caller) do
    true = Process.link(caller)
    :linked
  catch
    :error, :noproc -> :gone
  end

  defp arm(state) do
    ref = make_ref()
    _timer = Process.send_after(self(), {:idle, ref}, @idle_ms)
    %{state | idle: ref}
  end

  defp key(turn), do: {:held_turn, turn.session, turn.conversation}

  defp reason("ended"), do: :normal
  defp reason("stopped"), do: {:shutdown, :turn_stopped}
end
