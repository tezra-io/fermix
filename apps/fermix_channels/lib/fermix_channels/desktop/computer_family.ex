defmodule FermixChannels.Desktop.ComputerFamily do
  @moduledoc """
  The primary's side of a computer's own record (M97 §3.2, §5.3): what the
  computer offers (`offers`) and the path its session runs (`link_path`),
  told to the home's live view of its computers
  (`FermixCore.Computers.Registry`).

  As the computer's peer starts, its session is up (`Registry.connected/3`,
  with when the peer registered and where its session's hello found it
  standing); as the peer ends, the session ended
  (`Registry.disconnected/3`). Until the session's first `offers` the
  computer offers nothing.

  An `offers` payload is put back together by the peer (`Mobile.Chunks`,
  64 KiB), then decoded (`Computers.Offers.decode/1`) and checked against
  its header's `rev`. One refused is answered `error{code:"invalid_offers"}`
  with the sentence that names what was wrong, the session stays open, and
  the computer is recorded as offering nothing until it sends a payload the
  home takes: a bad payload fails closed for that computer alone.

  The family keeps what it last told the live view, so a view that restarted
  is told it all again (`announce/2`, which the view asks for as it starts,
  through `Home.Link`'s `announce_computers/1`): it is rebuilt from the open
  sessions, never left empty under them.

  Options in the context (a test's seams): `:registry`, the Registry's name.
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias FermixChannels.Desktop.Peer
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Registry

  @paths %{"direct" => :direct, "relay" => :relay}

  @doc """
  Asks the family of every computer whose session is up in `peers` (the
  primary's desktop peers) to tell the live view named `registry` its facts
  again. A family that reports to another view keeps still; a session that
  ended in between has nothing to tell.
  """
  @spec announce(atom(), GenServer.server()) :: :ok
  def announce(registry, peers) when is_atom(registry) do
    Enum.each(Peer.connected(peers), fn %{device_id: device_id} ->
      case Peer.tell(device_id, :computer, {:announce, registry}, registry: peers) do
        :ok -> :ok
        {:error, :not_connected} -> :ok
      end
    end)
  end

  @impl true
  def init(%{device_id: device_id, session: session, registry: peers} = context) do
    state = %{
      device_id: device_id,
      session: session,
      registry: Keyword.get(context.options, :registry, Registry),
      since: since(peers, device_id),
      standing: context.standing,
      offers: nil,
      path: nil
    }

    :ok = connected(state)
    {:ok, state}
  end

  @impl true
  def handle_event("offers", %{"rev" => rev}, payload, state) do
    case checked(payload, rev) do
      {:ok, offers} ->
        {:ok, offered(state, {offers, rev})}

      {:error, {:invalid_offers, sentence}} = refused ->
        Logger.warning(
          "computer #{state.device_id}: #{sentence} It offers nothing until it sends offers this server takes."
        )

        {:error, elem(refused, 1), offered(state, {[], nil})}
    end
  end

  def handle_event("link_path", %{"path" => path}, _payload, state) do
    state = %{state | path: Map.fetch!(@paths, path)}
    :ok = Registry.path(state.registry, state.device_id, state.session, state.path)
    {:ok, state}
  end

  # The live view it reports to restarted and asks again: everything it was
  # told, in the order it was first told it.
  @impl true
  def handle_info({:announce, registry}, %{registry: registry} = state) do
    :ok = connected(state)
    if state.offers, do: :ok = told_offers(state)
    if state.path, do: :ok = Registry.path(registry, state.device_id, state.session, state.path)
    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state),
    do: Registry.disconnected(state.registry, state.device_id, state.session)

  defp connected(state) do
    facts = %{since: state.since, session: state.session, standing: state.standing}
    Registry.connected(state.registry, state.device_id, facts)
  end

  # What the view is told offered, a refused payload as nothing.
  defp offered(state, offers) do
    state = %{state | offers: offers}
    :ok = told_offers(state)
    state
  end

  defp told_offers(%{offers: {offers, rev}} = state),
    do: Registry.offers(state.registry, state.device_id, state.session, offers, rev)

  # The payload is the one its revision names.
  defp checked(payload, rev) do
    with {:ok, offers} <- Offers.decode(payload) do
      if Offers.rev(payload) == rev,
        do: {:ok, offers},
        else:
          {:error, {:invalid_offers, "The offers were refused: rev is not the payload's own."}}
    end
  end

  # The peer registered itself before its families start: when its session
  # came up.
  defp since(peers, device_id) do
    case Peer.lookup(peers, device_id) do
      {:ok, _peer, %{connected_since: %DateTime{} = since}} -> since
      {:error, :not_connected} -> DateTime.utc_now()
    end
  end
end
