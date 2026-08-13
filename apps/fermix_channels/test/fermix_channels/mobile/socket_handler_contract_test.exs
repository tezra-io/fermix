defmodule FermixChannels.Mobile.SocketHandlerContractTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.SocketHandler

  @device_id "91d72be6-c253-4b73-8598-91c03f66b9d0"
  @new_device_id "1508aa90-2d73-4d7f-a49c-1cdedcd4c298"

  test "paired IK carries hello and ping over independent session sequences" do
    gateway = Noise.generate_keypair()
    device = Noise.generate_keypair()
    registry = start_registry()
    test_pid = self()

    assert {:ok, client} =
             Noise.initialize(:initiator, :ik,
               static_keypair: device,
               remote_static: gateway.public
             )

    assert {:ok, socket} =
             SocketHandler.init(
               gateway_keypair: gateway,
               device_store: :device_store,
               device_registry: registry,
               find_device: fn :device_store, remote_static ->
                 send(test_pid, {:resolved_device_key, remote_static})
                 {:ok, %{device_id: @device_id}}
               end,
               profile_name: "Orbit",
               update_device: fn :device_store, @device_id, %{last_seen: %DateTime{}} ->
                 {:ok, %{device_id: @device_id}}
               end,
               history_head: fn "main" -> {:ok, 73} end,
               read_frontier: fn "main" -> {:ok, 71} end,
               discover: fn -> {:ok, []} end
             )

    {client, socket} = complete_handshake(client, socket)
    assert_receive {:resolved_device_key, resolved_key}
    assert resolved_key == device.public
    refute Map.has_key?(socket, :gateway_keypair)
    refute Map.has_key?(socket, :load_gateway_keypair)
    assert socket.noise.static_keypair == nil
    assert socket.noise.ephemeral_keypair == nil
    assert socket.noise.psk == nil
    assert socket.noise.symmetric == nil

    hello = %{
      "device_id" => @device_id,
      "app_version" => "1.0.0",
      "last_server_seq" => 73,
      "protocol_v" => Protocol.protocol_version()
    }

    {hello_ack, client, socket} = client_round_trip("hello", hello, 1, client, socket)

    assert hello_ack["t"] == "hello_ack"
    assert hello_ack["seq"] == 1
    assert hello_ack["profiles"] == [%{"id" => "main", "name" => "Orbit"}]
    assert socket.client_seq == 1
    assert socket.server_seq == 1

    ping_plaintext = encode_client_frame("ping", %{}, 2)
    assert {:ok, %{type: "ping", seq: 2}} = Protocol.decode_client_frame(ping_plaintext)
    assert {:ok, ping_ciphertext, client} = Noise.encrypt(client, ping_plaintext)

    assert {:ok, socket} =
             SocketHandler.handle_in({ping_ciphertext, opcode: :binary}, socket)

    assert_receive {:mobile_event, %{"t" => "pong"} = pong}

    assert {:push, {:binary, pong_ciphertext}, socket} =
             SocketHandler.handle_info({:mobile_event, pong}, socket)

    assert {:ok, pong_plaintext, _client} = Noise.decrypt(client, pong_ciphertext)
    assert {%{"t" => "pong", "seq" => 2}, <<>>} = decode_server_frame(pong_plaintext)
    assert socket.client_seq == 2
    assert socket.server_seq == 2
  end

  test "IKpsk2 carries pair request and approval before the authenticated hello" do
    gateway = Noise.generate_keypair()
    device = Noise.generate_keypair()
    registry = start_registry()
    pair_manager = start_pair_manager(gateway)

    assert {:ok, window} = PairManager.open(pair_manager)

    assert {:ok, client} =
             Noise.initialize(:initiator, :ikpsk2,
               static_keypair: device,
               remote_static: gateway.public,
               psk: window.secret
             )

    assert {:ok, socket} =
             SocketHandler.init(
               gateway_keypair: gateway,
               device_registry: registry,
               pair_manager: pair_manager,
               update_device: fn _store, @new_device_id, %{last_seen: %DateTime{}} ->
                 {:ok, %{device_id: @new_device_id}}
               end,
               hello_ack_builder: fn _state -> {:ok, hello_ack_payload()} end
             )

    {client, socket} = complete_handshake(client, socket)
    assert socket.phase == :await_pair_request

    request = %{
      "device_name" => "Contract iPhone",
      "model" => "iPhone17,1",
      "app_version" => "1.0.0"
    }

    request_plaintext = encode_client_frame("pair_request", request, 1)

    assert {:ok, %{type: "pair_request", seq: 1}} =
             Protocol.decode_client_frame(request_plaintext)

    assert {:ok, request_ciphertext, client} = Noise.encrypt(client, request_plaintext)

    assert {:ok, socket} =
             SocketHandler.handle_in({request_ciphertext, opcode: :binary}, socket)

    assert socket.phase == :await_pair_decision
    assert {:ok, pending} = PairManager.await_request(pair_manager, window.session_id, 100)
    assert pending.noise_pk == device.public
    assert pending.sas == Noise.sas(client)

    assert {:ok, device_record} = PairManager.approve(pair_manager, window.session_id)

    assert_receive {:mobile_pair_decision, session_id, {:ok, ^device_record}} = decision
    assert session_id == window.session_id

    assert {:push, {:binary, approved_ciphertext}, socket} =
             SocketHandler.handle_info(decision, socket)

    assert {:ok, approved_plaintext, client} = Noise.decrypt(client, approved_ciphertext)
    {approved, <<>>} = decode_server_frame(approved_plaintext)
    assert approved["t"] == "pair_approved"
    assert approved["seq"] == 1
    assert approved["device_id"] == @new_device_id

    hello = %{
      "device_id" => @new_device_id,
      "app_version" => "1.0.0",
      "last_server_seq" => 91,
      "protocol_v" => Protocol.protocol_version()
    }

    {hello_ack, _client, socket} = client_round_trip("hello", hello, 2, client, socket)
    assert hello_ack["t"] == "hello_ack"
    assert hello_ack["seq"] == 2
    assert socket.phase == :ready
    assert socket.client_seq == 2
    assert socket.server_seq == 2
  end

  defp start_registry do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")

    start_supervised!(
      {DeviceRegistry,
       name: name,
       authorize_device: fn _store, device_id -> {:ok, %{device_id: device_id}} end,
       delete_device: fn _store, _device_id -> :ok end}
    )
  end

  defp start_pair_manager(gateway) do
    name = Module.concat(__MODULE__, "PairManager#{System.unique_integer([:positive])}")

    start_supervised!(
      {PairManager,
       name: name,
       ensure_identity: fn -> {:ok, %{gateway_keypair: gateway}} end,
       activate_listener: fn _identity -> :ok end,
       persist_device: fn attrs -> {:ok, attrs} end,
       emit_pair: fn _status, _duration_us -> :ok end,
       device_id_generator: fn -> @new_device_id end}
    )
  end

  defp complete_handshake(client, socket) do
    assert {:ok, first_wire, client} = Noise.write_handshake(client, <<>>)

    assert {:push, {:binary, second_wire}, socket} =
             SocketHandler.handle_in({first_wire, opcode: :binary}, socket)

    assert {:ok, <<>>, client} = Noise.read_handshake(client, second_wire)
    {client, socket}
  end

  defp client_round_trip(type, payload, seq, client, socket) do
    plaintext = encode_client_frame(type, payload, seq)
    assert {:ok, %{type: ^type, seq: ^seq}} = Protocol.decode_client_frame(plaintext)
    assert {:ok, ciphertext, client} = Noise.encrypt(client, plaintext)

    assert {:push, {:binary, response}, socket} =
             SocketHandler.handle_in({ciphertext, opcode: :binary}, socket)

    assert {:ok, response_plaintext, client} = Noise.decrypt(client, response)
    {header, <<>>} = decode_server_frame(response_plaintext)
    {header, client, socket}
  end

  defp encode_client_frame(type, payload, seq) do
    header =
      payload
      |> Map.merge(%{"v" => Protocol.protocol_version(), "t" => type, "seq" => seq})
      |> Jason.encode!()

    <<byte_size(header)::unsigned-big-32, header::binary>>
  end

  defp decode_server_frame(<<header_size::unsigned-big-32, rest::binary>>) do
    <<header::binary-size(header_size), bytes::binary>> = rest
    {Jason.decode!(header), bytes}
  end

  defp hello_ack_payload do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "contract-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 73,
      "read_up_to_seq" => 71,
      "caps" => %{"commands" => [], "media" => true, "streaming" => true}
    }
  end
end
