defmodule FermixChannels.Mobile.PeersTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Mobile.PeerEvents
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol

  # The pairing session (IKpsk2, before the owner approved) is the session's
  # own phase, not a kind: it alone sends `pair_request` and is sent the
  # verdict.
  @pairing_client ~w(pair_request)
  @pairing_server ~w(pair_approved pair_denied)

  test "every event the codec knows is some kind's, or the pairing session's" do
    allowed_client = Enum.flat_map(Peers.kinds(), &Peers.client_events/1)
    allowed_server = Enum.flat_map(Peers.kinds(), &Peers.server_events/1)

    assert Enum.sort(Enum.uniq(allowed_client ++ @pairing_client)) ==
             Enum.sort(Protocol.client_events())

    assert Enum.sort(Enum.uniq(allowed_server ++ @pairing_server)) ==
             Enum.sort(Protocol.server_events())
  end

  # M75 §5.2: a desktop sends its own family's events plus four of a phone's.
  test "a desktop sends its families' events and hello, ping, media_fetch and ack" do
    families = Map.keys(Peer.event_families())

    assert Enum.sort(Peers.client_events(:desktop)) ==
             Enum.sort(families ++ ~w(hello ping media_fetch ack))

    for type <- ~w(msg command cancel history_pull attach_begin push_register read_state
                   request_status unpair) do
      assert {:error, {:unsupported_event, ^type}} = Peers.authorize(:desktop, type)
    end

    for type <- families do
      assert {:error, {:unsupported_event, ^type}} = Peers.authorize(:phone, type)
    end
  end

  test "an enrollment and a move session send only their own events, and keep alive" do
    assert Peers.client_events(:enrollment) == ~w(enroll_request ping)

    assert Peers.client_events(:move) ==
             ~w(move_offer move_chunk move_end move_commit move_resume ping)

    assert Enum.sort(Peers.server_events(:move) -- ["error"]) ==
             ~w(move_accept move_done move_ready pong)

    assert Peers.server_event?(:enrollment, "pong")
    refute Peers.client_event?(:move, "hello")
    refute Peers.client_event?(:enrollment, "hello")
  end

  test "every M75 event belongs to a kind in its direction" do
    for type <- PeerEvents.client_events() do
      assert Enum.any?(Peers.kinds(), &Peers.client_event?(&1, type)), type
    end

    for type <- PeerEvents.server_events() do
      assert Enum.any?(Peers.kinds(), &Peers.server_event?(&1, type)), type
    end
  end
end
