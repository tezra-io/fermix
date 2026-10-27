defmodule FermixChannels.Mobile.SessionTest do
  # The seam between a phone's session and whatever carries it. The behaviour
  # itself is pinned through the WebSocket carrier in SocketHandlerTest; these
  # pin only what any carrier relies on.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Session

  @peer {10, 0, 0, 7}

  test "a session that ends before hello or a pair request closes its iroh peer, and only then" do
    test_pid = self()

    close = fn id ->
      send(test_pid, {:close_iroh_peer, id})
      :ok
    end

    id = String.duplicate("ab", 32)
    iroh = {:iroh, id}

    ended = fn peer, phase ->
      {:ok, state} = Session.init(device_registry: :registry, peer: peer, close_iroh_peer: close)
      :ok = Session.terminate(:handshake_timeout, %{state | phase: phase})
    end

    for phase <- [:prelude, :await_hello, :await_pair_request] do
      ended.(iroh, phase)
      assert_received {:close_iroh_peer, ^id}
    end

    # A phone the owner is deciding on, or a paired phone's session, ends with
    # its own close; a WebSocket peer has no iroh connection.
    ended.(iroh, :await_pair_decision)
    ended.(iroh, :ready)
    ended.(@peer, :prelude)
    refute_received {:close_iroh_peer, _id}
  end

  test "a session needs its carrier's peer, and fails loud without one" do
    assert_raise ArgumentError, ~r/:peer/, fn -> Session.init(device_registry: :registry) end
    assert {:ok, %{peer: @peer}} = Session.init(device_registry: :registry, peer: @peer)
  end

  test "frames come back as a list of whole messages, in no carrier's shape" do
    device = %{device_id: "paired-device"}

    state = %{
      phase: :prelude,
      device_store: :store,
      pair_manager: :pair,
      gateway_keypair: :gateway,
      noise_initialize: fn :responder, :ik, static_keypair: :gateway -> {:ok, :noise0} end,
      noise_read: fn :noise0, <<"FXM1", 1, "handshake">> -> {:ok, <<>>, :noise1} end,
      noise_write: fn :noise1, <<>> -> {:ok, "response", :noise2} end,
      noise_remote_static: fn :noise2 -> {:ok, <<7::256>>} end,
      find_device: fn :store, <<7::256>> -> {:ok, device} end
    }

    assert {:push, ["response"], next} =
             Session.handle_frame(<<"FXM1", 1, "handshake">>, state)

    assert next.phase == :await_hello
  end

  # A carrier short of room may close only a connection a stranger could hold.
  # IK's first message proves a paired phone's key; IKpsk2's carries no proof of
  # the pairing secret (the psk is mixed in the daemon's reply), so a peer
  # awaiting its pair request has proved nothing but that it knows the gateway
  # key, which every pairing QR shows.
  test "a peer is past its handshake once IK proved its key or its request waits for the owner" do
    {:ok, fresh} = Session.init(handshake_stubs())
    refute Session.past_handshake?(fresh)

    assert {:push, ["response"], paired} =
             Session.handle_frame(<<"FXM1", 1, "handshake">>, fresh)

    assert paired.phase == :await_hello
    assert Session.past_handshake?(paired)
    assert Session.past_handshake?(%{paired | phase: :ready})

    assert {:push, ["response"], pairing} = Session.handle_frame(<<"FXM1", 2, "pairing">>, fresh)
    assert pairing.phase == :await_pair_request
    refute Session.past_handshake?(pairing)
    assert Session.past_handshake?(%{pairing | phase: :await_pair_decision})
  end

  test "the session's own bounds close the same way on every carrier" do
    {:ok, state} = Session.init(device_registry: :registry, peer: @peer)

    assert {:stop, :frame_too_large, {1009, "mobile frame too large"}, ^state} =
             Session.handle_frame(:binary.copy(<<0>>, 65_536), state)

    assert {:stop, :invalid_prelude, {1002, "invalid mobile prelude"}, ^state} =
             Session.handle_frame(<<"NOPE", 1, 0, 1>>, state)
  end

  test "pairing calls carry the session's peer, so failures count against it alone" do
    test_pid = self()

    {:ok, state} =
      Session.init(%{
        peer: @peer,
        gateway_keypair: %{private: <<1::256>>, public: <<2::256>>},
        pair_manager: :pair,
        current_pair: fn :pair, peer ->
          send(test_pid, {:current_pair, peer})
          {:ok, %{session_id: "pair-session", secret: <<1::256>>}}
        end,
        noise_initialize: fn :responder, :ikpsk2, _opts -> {:ok, :noise} end,
        noise_read: fn :noise, _wire -> {:error, :authentication_failed} end,
        record_pair_failure: fn :pair, "pair-session", peer ->
          send(test_pid, {:failure_recorded, peer})
          {:ok, 1}
        end
      })

    assert {:stop, {:pairing_failed, :authentication_failed}, {1002, _text}, _stopped} =
             Session.handle_frame(<<"FXM1", 2, "bad">>, state)

    assert_receive {:current_pair, @peer}
    assert_receive {:failure_recorded, @peer}
  end

  # Both Noise modes with stubbed crypto, no timer left running.
  defp handshake_stubs do
    %{
      peer: @peer,
      device_registry: :registry,
      device_store: :store,
      pair_manager: :pair,
      gateway_keypair: %{private: <<1::256>>, public: <<2::256>>},
      schedule_handshake_deadline: fn _message, _delay_ms -> make_ref() end,
      cancel_handshake_deadline: fn _ref -> false end,
      schedule_session_timer: fn _message, _delay_ms -> make_ref() end,
      current_pair: fn :pair, @peer -> {:ok, %{session_id: "pair", secret: <<3::256>>}} end,
      noise_initialize: fn :responder, pattern, _opts -> {:ok, {pattern, 0}} end,
      noise_read: fn {pattern, 0}, _wire -> {:ok, <<>>, {pattern, 1}} end,
      noise_write: fn {pattern, 1}, <<>> -> {:ok, "response", {pattern, 2}} end,
      noise_remote_static: fn {_pattern, 2} -> {:ok, <<7::256>>} end,
      noise_sas: fn {:ikpsk2, 2} -> "123456" end,
      find_device: fn :store, <<7::256>> -> {:ok, %{device_id: "paired-device"}} end
    }
  end
end
