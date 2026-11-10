defmodule FermixChannels.Desktop.ComputerFamily do
  @moduledoc """
  The primary's side of a computer's own record (M97 §3.2, §5.3): what the
  computer offers (`offers`) and the path its session runs (`link_path`),
  told to the home's live view of its computers
  (`FermixCore.Computers.Registry`).

  As the computer's peer starts, its session is up (`Registry.connected/3`,
  with when the peer registered); as the peer ends, the session ended
  (`Registry.disconnected/3`). Until the session's first `offers` the
  computer offers nothing.

  An `offers` payload is put back together by the peer (`Mobile.Chunks`,
  64 KiB), then decoded (`Computers.Offers.decode/1`) and checked against
  its header's `rev`. One refused is answered `error{code:"invalid_offers"}`
  with the sentence that names what was wrong, the session stays open, and
  the computer is recorded as offering nothing until it sends a payload the
  home takes: a bad payload fails closed for that computer alone.

  Options in the context (a test's seams): `:registry`, the Registry's name.
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias FermixChannels.Desktop.Peer
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Registry

  @paths %{"direct" => :direct, "relay" => :relay}

  @impl true
  def init(%{device_id: device_id, session: session, registry: peers} = context) do
    registry = Keyword.get(context.options, :registry, Registry)

    :ok =
      Registry.connected(registry, device_id, %{since: since(peers, device_id), session: session})

    {:ok, %{device_id: device_id, session: session, registry: registry}}
  end

  @impl true
  def handle_event("offers", %{"rev" => rev}, payload, state) do
    case checked(payload, rev) do
      {:ok, offers} ->
        :ok = Registry.offers(state.registry, state.device_id, state.session, offers, rev)
        {:ok, state}

      {:error, {:invalid_offers, sentence}} = refused ->
        Logger.warning(
          "computer #{state.device_id}: #{sentence} It offers nothing until it sends offers this server takes."
        )

        :ok = Registry.offers(state.registry, state.device_id, state.session, [], nil)
        {:error, elem(refused, 1), state}
    end
  end

  def handle_event("link_path", %{"path" => path}, _payload, state) do
    :ok = Registry.path(state.registry, state.device_id, state.session, Map.fetch!(@paths, path))
    {:ok, state}
  end

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state),
    do: Registry.disconnected(state.registry, state.device_id, state.session)

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
