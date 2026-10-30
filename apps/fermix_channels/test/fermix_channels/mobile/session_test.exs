defmodule FermixChannels.Mobile.SessionTest do
  # The seam between a phone's session and whatever carries it. The behaviour
  # itself is pinned through the WebSocket carrier in SocketHandlerTest; these
  # pin only what any carrier relies on.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Session
  alias FermixCore.Home.Epoch
  alias FermixTestSupport.SafeRm

  @peer {10, 0, 0, 7}
  @stale_sentence "This engine is at epoch 3; you have seen epoch 4: " <>
                    "the primary moved, reconnect to the current one"

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

  # M75 D14: the epoch a session announces is the one in the identity bundle
  # whose gateway key the handshake used, read once with that key.
  test "the handshake takes the primary epoch from the identity it loaded" do
    root = SafeRm.make_tmp_dir!("mobile_session_epoch") |> FermixTestSupport.PrimaryHome.booted!()
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    {:ok, identity} = Identity.ensure(root: root)
    {:ok, 2} = Epoch.bump(root)
    keypair = %{private: identity.gateway_private_key, public: identity.gateway_public_key}

    stubs =
      handshake_stubs()
      |> Map.delete(:gateway_keypair)
      |> Map.merge(%{
        identity_root: root,
        noise_initialize: fn :responder, :ik, static_keypair: ^keypair -> {:ok, {:ik, 0}} end
      })

    {:ok, fresh} = Session.init(stubs)
    assert fresh.primary_epoch == nil

    assert {:push, ["response"], paired} = Session.handle_frame(<<"FXM1", 1, "hs">>, fresh)
    assert paired.primary_epoch == 2
    refute Map.has_key?(paired, :load_gateway_keypair)
  end

  test "hello_ack announces the session's primary epoch; a lower or absent one is served" do
    for seen <- [nil, 1, 3] do
      fields = if seen, do: %{"primary_epoch" => seen}, else: %{}

      assert {:push, [ack], ready} =
               Session.handle_frame(hello_frame(fields), hello_state(primary_epoch: 3))

      assert %{"t" => "hello_ack", "primary_epoch" => 3} = header(ack)
      assert ready.phase == :ready
      assert_received {:device_updated, _attrs}
      assert_received :socket_attached
    end
  end

  test "a hello that has seen a higher epoch is refused stale_primary and served nothing" do
    state = hello_state(primary_epoch: 3)

    assert {:stop, :stale_primary, {1002, "stale primary"}, [refusal], stopped} =
             Session.handle_frame(hello_frame(%{"primary_epoch" => 4}), state)

    assert header(refusal) == %{
             "v" => 2,
             "t" => "error",
             "seq" => 1,
             "code" => "stale_primary",
             "message" => @stale_sentence
           }

    assert stopped.phase == :await_hello
    assert stopped.device_id == nil
    refute_received {:device_updated, _attrs}
    refute_received :socket_attached
  end

  test "a session without a primary epoch fails loud at hello and serves nothing" do
    for fields <- [%{}, %{"primary_epoch" => 1}] do
      assert {:stop, {:primary_epoch_unavailable, nil}, {1002, "mobile protocol error"}, _state} =
               Session.handle_frame(hello_frame(fields), hello_state(primary_epoch: nil))
    end

    refute_received {:device_updated, _attrs}
    refute_received :socket_attached
  end

  test "pair_approved gives a newly paired phone the daemon's primary epoch" do
    {:ok, state} =
      Session.init(%{
        peer: @peer,
        phase: :await_pair_decision,
        pairing_session_id: "pair-session",
        primary_epoch: 5,
        negotiated_version: 2,
        noise: :noise,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        discover: fn -> {:ok, []} end,
        iroh_candidate: fn -> :none end,
        profile_name: "Fermix",
        schedule_handshake_deadline: fn _message, _delay_ms -> make_ref() end,
        cancel_handshake_deadline: fn _ref -> false end
      })

    device = %{device_id: "new-device", apns_key_salt: <<3::256>>}
    decision = {:mobile_pair_decision, "pair-session", {:ok, device}}

    assert {:push, [approved], _state} = Session.handle_info(decision, state)
    assert %{"t" => "pair_approved", "primary_epoch" => 5} = header(approved)
  end

  # A paired phone's session at `hello`, with stubbed crypto that passes
  # plaintext through, and its device-store and registry calls reported.
  defp hello_state(overrides) do
    test_pid = self()

    {:ok, state} =
      %{
        peer: @peer,
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        device_store: :store,
        profile_name: "Fermix",
        noise: :noise,
        decrypt: fn :noise, frame -> {:ok, frame, :noise} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        update_device: fn :store, "paired-device", attrs ->
          send(test_pid, {:device_updated, attrs})
          {:ok, %{device_id: "paired-device"}}
        end,
        attach_socket: fn :registry, "paired-device", _pid, profile_id: "main" ->
          send(test_pid, :socket_attached)
          :ok
        end,
        history_head: fn "main" -> {:ok, 0} end,
        read_frontier: fn "main" -> {:ok, 0} end,
        discover: fn -> {:ok, []} end,
        iroh_candidate: fn -> :none end,
        pending_approvals: fn "main" -> [] end,
        pairing_pending: fn -> :none end,
        schedule_handshake_deadline: fn _message, _delay_ms -> make_ref() end,
        cancel_handshake_deadline: fn _ref -> false end
      }
      |> Map.merge(Map.new(overrides))
      |> Session.init()

    state
  end

  defp hello_frame(fields) do
    json =
      %{
        "v" => 2,
        "t" => "hello",
        "seq" => 1,
        "device_id" => "paired-device",
        "app_version" => "1.0.0",
        "last_server_seq" => 0,
        "protocol_v" => 2
      }
      |> Map.merge(fields)
      |> Jason.encode!()

    <<byte_size(json)::32, json::binary>>
  end

  defp header(<<size::32, json::binary-size(size), _bytes::binary>>), do: Jason.decode!(json)

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
