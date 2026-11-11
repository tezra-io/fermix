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

  One per server turn, by the turn's session id. It ends:
    * when the server says the turn ended (`finish/3`, the server's
      `Browser.ComputerTurn`): normally, so a turn that handed its tabs to the
      person keeps its pane task for the conversation's next turn, as a turn
      on the server does; or stopped (cancelled or crashed), which ends it;
    * after #{div(10 * 60_000, 60_000)} minutes with no request, normally: the bound
      for a server that never says so (its link dropped).

  Requests run one at a time, in order, which is how a turn makes them.
  """

  use GenServer, restart: :temporary

  require Logger

  @idle_ms 10 * 60_000
  @max_attempts 3
  @session ~r/\A[A-Za-z0-9._:-]{1,128}\z/

  @typedoc "Where the held turns live: their registry and their supervisor."
  @type seams :: %{registry: atom(), supervisor: atom()}

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
  Runs `fun` in the process that stands for the server's turn `session_id`,
  started on its first request, and answers what `fun` answered.
  """
  @spec run(seams(), String.t(), (-> term())) :: term()
  def run(%{registry: _, supervisor: _} = seams, session_id, fun) when is_function(fun, 0) do
    true = session?(session_id)
    run(seams, session_id, fun, @max_attempts)
  end

  @doc """
  The server's turn `session_id` ended (`"ended"`) or was stopped
  (`"stopped"`): its process ends once the request it runs, if any, is
  answered. A turn with no process here is already done.
  """
  @spec finish(seams(), String.t(), ending()) :: :ok
  def finish(%{registry: registry}, session_id, ending) when ending in ["ended", "stopped"] do
    true = session?(session_id)

    case Registry.lookup(registry, key(session_id)) do
      [{pid, _value}] -> GenServer.cast(pid, {:finish, reason(ending)})
      [] -> :ok
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name =
      {:via, Registry, {Keyword.fetch!(opts, :registry), key(Keyword.fetch!(opts, :session))}}

    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :session), name: name)
  end

  @impl true
  def init(session_id), do: {:ok, arm(%{session: session_id, idle: nil})}

  @impl true
  def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), arm(state)}

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
  defp run(_seams, session_id, _fun, 0),
    do: raise("the browser turn #{session_id} could not be held here")

  defp run(seams, session_id, fun, attempts) do
    GenServer.call(ensure(seams, session_id), {:run, fun}, :infinity)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal] ->
      run(seams, session_id, fun, attempts - 1)

    :exit, {{:shutdown, _why}, _call} ->
      run(seams, session_id, fun, attempts - 1)
  end

  defp ensure(seams, session_id) do
    spec = {__MODULE__, registry: seams.registry, session: session_id}

    case DynamicSupervisor.start_child(seams.supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp arm(state) do
    ref = make_ref()
    _timer = Process.send_after(self(), {:idle, ref}, @idle_ms)
    %{state | idle: ref}
  end

  defp key(session_id), do: {:held_turn, session_id}

  defp reason("ended"), do: :normal
  defp reason("stopped"), do: {:shutdown, :turn_stopped}
end
