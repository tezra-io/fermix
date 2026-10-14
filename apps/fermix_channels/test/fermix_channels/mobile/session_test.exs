defmodule FermixChannels.Mobile.SessionTest do
  # The seam between a phone's session and whatever carries it. The behaviour
  # itself is pinned through the WebSocket carrier in SocketHandlerTest; these
  # pin only what any carrier relies on.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Session

  @peer {10, 0, 0, 7}

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
end
