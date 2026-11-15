defmodule FermixChannels.Desktop.Offers do
  @moduledoc """
  What this computer offers its server (M97 §3.2, §5.3), worked out here and
  sent as the `offers` event, on a linked computer, beside the relay
  (`Desktop.DeviceServices`).

  The offers are every offer module (`FermixCore.Computers.Offers.modules/0`),
  in the order the computer lists them. Each module's state comes from this
  computer's switches (`FermixCore.Computers.Switches`) and its facts
  (`FermixCore.Computers.Facts`, its recorder's setting among them).

  When it sends:

    * at each session's start, once the relay has the server's `hello_ack`
      (`connected/2`): always, since the server holds no offers from an
      earlier session;
    * when the switches are written or the recorder is switched
      (`FermixCore.Computers.Switches` and `FermixCore.ComputerHistory` tell
      this process, registered under `Switches.listener/0`), and when the
      facts are read again, every #{60} seconds: only when the offers'
      revision moved since the last one sent.

  Only a server whose `hello_ack` says it takes them (`caps.computer.offers`)
  is sent offers; an older server closes the session on an event it does not
  know, and the relay refuses the event as well (`Desktop.Relay`). A send
  the relay refuses is logged and tried again at the next change or tick.

  **A computer that moved before M97** has a link and no switches: as this
  process starts, its switches are derived as a move would have kept them,
  waiting for the owner's review (`FermixCore.Computers.Consent.derive_moved/2`),
  once; until the review it offers nothing.

  `:one_for_one` under `Desktop.DeviceServices`: a crash forgets the last
  revision sent, so the next tick sends again. Seams: `:home`, `:name`, `:relay` (the
  relay's name), `:modules`, `:facts` (0-arity, the facts), `:switches`
  (0-arity, the switches), `:timer` (2-arity `Process.send_after/3` to this
  process) and `:interval_ms`.
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Relay
  alias FermixCore.Computers.Consent
  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches
  alias FermixCore.Setup.ConfigStore

  @interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do:
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, Switches.listener()))

  @doc """
  A session is up, and `caps` is its `hello_ack`'s: the offers go now when
  the server takes them.
  """
  @spec connected(GenServer.server(), map()) :: :ok
  def connected(server \\ Switches.listener(), caps) when is_map(caps),
    do: GenServer.cast(server, {:connected, caps})

  @doc "The switches changed: the offers go again if their revision moved."
  @spec changed(GenServer.server()) :: :ok
  def changed(server \\ Switches.listener()), do: GenServer.cast(server, :switches_changed)

  @doc "What this computer offers now."
  @spec current(GenServer.server()) :: [Offers.offer()]
  def current(server \\ Switches.listener()), do: GenServer.call(server, :current)

  @impl true
  def init(opts) do
    :ok = derive_moved(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0))

    state = %{
      relay: Keyword.get(opts, :relay, Relay),
      modules: Keyword.get(opts, :modules, Offers.modules()),
      facts: Keyword.get(opts, :facts, fn -> Facts.read() end),
      switches: Keyword.get(opts, :switches, &Switches.current/0),
      timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      takes: false,
      sent: nil
    }

    _timer = state.timer.(:offers_tick, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:connected, caps}, state) do
    takes = get_in(caps, ["computer", "offers"]) == true
    {:noreply, send_offers(%{state | takes: takes, sent: nil})}
  end

  def handle_cast(:switches_changed, state), do: {:noreply, send_offers(state)}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, compute(state), state}

  @impl true
  def handle_info(:offers_tick, state) do
    _timer = state.timer.(:offers_tick, state.interval_ms)
    {:noreply, send_offers(state)}
  end

  # Once, at the first start of a computer that moved before M97.
  defp derive_moved(home) do
    case Consent.derive_moved(home) do
      :unchanged ->
        :ok

      {:derived, switches} ->
        Logger.info(
          "this computer moved before its server could ask what it may use here; it offers " <>
            "nothing until you review it (proposed: #{inspect(Consent.proposed(switches))})"
        )

      {:error, reason} ->
        Logger.error("this computer's switches could not be derived: #{inspect(reason)}")
    end
  end

  defp compute(state), do: Offers.compute(state.modules, state.switches.(), state.facts.())

  # Sent only to a server that takes them, and only when the revision moved.
  defp send_offers(%{takes: false} = state), do: state

  defp send_offers(state) do
    {:ok, payload, rev} = Offers.encode(compute(state))

    if rev == state.sent, do: state, else: sent(state, payload, rev)
  end

  defp sent(state, payload, rev) do
    case Relay.send_event(state.relay, %{"t" => "offers", "rev" => rev}, payload) do
      :ok ->
        %{state | sent: rev}

      {:error, reason} ->
        Logger.warning("this computer's offers were not sent to its server: #{inspect(reason)}")
        state
    end
  end
end
