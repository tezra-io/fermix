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

  Seams: `:name`, `:switches` (0-arity, this computer's switches) and
  `:turns` (`HeldTurn.seams/0`).
  """

  use GenServer

  require Logger

  alias FermixCore.Browser.HeldTurn
  alias FermixCore.Computers.Switches

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

  @impl true
  def init(opts) do
    {:ok,
     %{
       switches: Keyword.get(opts, :switches, &Switches.current/0),
       turns: Keyword.get_lazy(opts, :turns, &HeldTurn.seams/0)
     }}
  end

  @impl true
  def handle_cast(:switches_changed, state) do
    if not Switches.on?(state.switches.(), :browser), do: :ok = HeldTurn.stop_all(state.turns)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("the browser's held turns ignore #{inspect(message)}")
    {:noreply, state}
  end
end
