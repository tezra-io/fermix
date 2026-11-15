defmodule FermixCore.Browser.HeldTurnListener do
  @moduledoc """
  The server's turns this computer's browser holds, as its switches see them
  (M97 §7.4, INVOKE-1): the switches' fourth listener
  (`Computers.Switches.browser_listener/0`), as this computer's screen is
  their third (`ComputerUse.Seat`). When the master or the `browser` switch
  goes off, every turn held here ends at once (`Browser.HeldTurn.stop_all/1`),
  a request one of them runs included, and each pane task and its tabs with
  it, so nothing the server asked of this browser starts or goes on once
  the computer said no. Later requests are refused where they arrive
  (`Desktop.Invoke.Admission`).

  **The record** (M97 §8.7). It is also the one writer of the browser's
  record for the computer-history recorder (`ComputerUse.ServerControl`):
  each turn held here says it began (`held/2`, from its own start), and this
  process watches it; the stretch opens when the first one begins while none
  is held and closes when the last one ends, however it ends (its turn
  finished or stopped, its run ended, it idled out, it was killed), or at
  once when a switch going off ends them all. A stretch a stopped engine left
  open is closed when this process starts, unless a turn it finds still held
  keeps it open; a turn found held with none open opens one. A write that
  fails is logged and the turn goes on.

  Seams: `:name`, `:switches` (0-arity, this computer's switches), `:turns`
  (`HeldTurn.seams/0`), `:home` (whose record) and `:clock` (0-arity
  `DateTime`).
  """

  use GenServer

  require Logger

  alias FermixCore.Browser.HeldTurn
  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse.ServerControl
  alias FermixCore.Setup.ConfigStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: Keyword.get(opts, :name, Switches.browser_listener())
      )

  @doc "The switches changed: each turn held here ends if the browser is no longer offered."
  @spec changed(GenServer.server()) :: :ok
  def changed(server \\ Switches.browser_listener()),
    do: GenServer.cast(server, :switches_changed)

  @doc "The held turn `pid` began here: its life is part of the browser's stretch."
  @spec held(GenServer.server(), pid()) :: :ok
  def held(server, pid) when is_pid(pid), do: GenServer.cast(server, {:held, pid})

  @impl true
  def init(opts) do
    state = %{
      switches: Keyword.get(opts, :switches, &Switches.current/0),
      turns: Keyword.get_lazy(opts, :turns, &HeldTurn.seams/0),
      home: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      held: %{}
    }

    {:ok, reconcile(state)}
  end

  @impl true
  def handle_cast(:switches_changed, state) do
    if Switches.on?(state.switches.(), :browser),
      do: {:noreply, state},
      else: {:noreply, switched_off(state)}
  end

  def handle_cast({:held, pid}, state), do: {:noreply, watch(state, pid)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{held: held} = state)
      when is_map_key(held, ref) do
    held = Map.delete(held, ref)
    if held == %{}, do: record(ServerControl.browser_ended(state.home, state.clock.(), :closed))
    {:noreply, %{state | held: held}}
  end

  def handle_info(message, state) do
    Logger.debug("the browser's held turns ignore #{inspect(message)}")
    {:noreply, state}
  end

  # -- the record -----------------------------------------------------------------

  defp watch(state, pid) do
    if pid in Map.values(state.held), do: state, else: watch_new(state, pid)
  end

  defp watch_new(state, pid) do
    if state.held == %{}, do: record(ServerControl.browser_started(state.home, state.clock.()))
    %{state | held: Map.put(state.held, Process.monitor(pid), pid)}
  end

  # Every turn ends here at once, so the stretch closes now, not as each one's
  # end arrives.
  defp switched_off(state) do
    :ok = HeldTurn.stop_all(state.turns)
    Enum.each(Map.keys(state.held), &Process.demonitor(&1, [:flush]))

    if state.held != %{},
      do: record(ServerControl.browser_ended(state.home, state.clock.(), :switched_off))

    %{state | held: %{}}
  end

  # At start: the turns still held (this process restarted beside them) are
  # watched again, and the record is made to agree with them.
  defp reconcile(state) do
    live = held_now(state.turns)

    case {ServerControl.browser_open?(state.home), live} do
      {{:ok, true}, []} ->
        record(ServerControl.browser_ended(state.home, state.clock.(), :closed))

      {{:ok, false}, [_ | _]} ->
        record(ServerControl.browser_started(state.home, state.clock.()))

      {{:ok, _agrees}, _live} ->
        :ok

      {{:error, reason}, _live} ->
        unreadable(reason)
    end

    %{state | held: Map.new(live, &{Process.monitor(&1), &1})}
  end

  defp held_now(%{supervisor: supervisor}) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        do: pid
  end

  defp unreadable(reason),
    do:
      Logger.warning(
        "browser: the record of the server's browser work could not be read: #{inspect(reason)}"
      )

  defp record(:ok), do: :ok

  defp record({:error, reason}),
    do:
      Logger.warning(
        "browser: the record of the server's browser work was not written: #{inspect(reason)}"
      )
end
