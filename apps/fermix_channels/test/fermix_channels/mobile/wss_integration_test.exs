defmodule FermixChannels.Mobile.WssIntegrationTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol

  @device_id "91d72be6-c253-4b73-8598-91c03f66b9d0"
  @timeout_ms 2_000

  defmodule WssClient do
    @moduledoc false

    use WebSockex

    @spec start_link({WebSockex.Conn.t(), pid()}) :: {:ok, pid()} | {:error, term()}
    def start_link({%WebSockex.Conn{} = conn, parent}) when is_pid(parent) do
      WebSockex.start_link(conn, __MODULE__, parent)
    end

    @impl true
    def handle_connect(conn, parent) do
      send(parent, {:wss_connected, self(), conn.transport, :ssl.peercert(conn.socket)})
      {:ok, parent}
    end

    @impl true
    def handle_frame({:binary, payload}, parent) when is_binary(payload) do
      send(parent, {:wss_binary, self(), payload})
      {:ok, parent}
    end

    def handle_frame(frame, parent) do
      send(parent, {:unexpected_wss_frame, self(), frame})
      {:ok, parent}
    end
  end

  test "WSS upgrade carries pinned TLS, Noise IK, hello, and application ping" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-wss-integration")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    assert {:ok, identity} = Identity.ensure(root: root)
    device = Noise.generate_keypair()
    registry = start_registry()
    listener = start_listener(root, device.public, registry)

    assert {:ok, {{127, 0, 0, 1}, port}} = Listener.listener_info(listener)
    assert port > 0

    cert_der = X509.Certificate.to_der(identity.tls_certificate)
    assert :crypto.hash(:sha256, cert_der) == identity.tls_fingerprint

    client = start_supervised!({WssClient, {pinned_connection(port), self()}})
    assert_receive {:wss_connected, ^client, :ssl, {:ok, presented_der}}, @timeout_ms

    # The app's trust model (design 6.1): TLS exists for iOS ATS, the chain is
    # never validated, and the leaf is accepted only because its SHA-256 equals
    # the fingerprint the QR carried. Trust lives in the Noise layer below.
    assert :crypto.hash(:sha256, presented_der) == identity.tls_fingerprint
    assert presented_der == cert_der

    assert {:ok, noise} =
             Noise.initialize(:initiator, :ik,
               static_keypair: device,
               remote_static: identity.gateway_public_key
             )

    noise = complete_handshake(client, noise)

    hello = %{
      "device_id" => @device_id,
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    {hello_ack, noise} = round_trip(client, "hello", hello, 1, noise)
    assert %{"t" => "hello_ack", "seq" => 1} = hello_ack
    assert hello_ack["profiles"] == [%{"id" => "main", "name" => "Orbit"}]

    {pong, _noise} = round_trip(client, "ping", %{}, 2, noise)
    assert %{"t" => "pong", "seq" => 2} = pong
  end

  defp start_registry do
    name = unique_name("Registry")

    start_supervised!(
      {DeviceRegistry,
       name: name, authorize_device: fn _store, @device_id -> {:ok, %{device_id: @device_id}} end}
    )
  end

  defp start_listener(root, device_public, registry) do
    listener_name = unique_name("Listener")

    router_opts = [
      device_store: :device_store,
      device_registry: registry,
      find_device: fn :device_store, ^device_public -> {:ok, %{device_id: @device_id}} end,
      update_device: fn :device_store, @device_id, %{last_seen: %DateTime{}} ->
        {:ok, %{device_id: @device_id}}
      end,
      profile_name: "Orbit",
      history_head: fn "main" -> {:ok, 0} end,
      read_frontier: fn "main" -> {:ok, 0} end,
      discover: fn -> {:ok, []} end
    ]

    start_supervised!(
      {Listener,
       name: listener_name, root: root, bind: {127, 0, 0, 1}, port: 0, router_opts: router_opts}
    )
  end

  defp pinned_connection(port) do
    url = "wss://127.0.0.1:#{port}/ws"

    assert %WebSockex.Conn{} =
             WebSockex.Conn.new(url,
               ssl_options: [verify: :verify_none],
               socket_connect_timeout: @timeout_ms,
               socket_recv_timeout: @timeout_ms
             )
  end

  defp complete_handshake(client, noise) do
    assert {:ok, first_wire, noise} = Noise.write_handshake(noise, <<>>)
    assert :ok = WebSockex.send_frame(client, {:binary, first_wire}, @timeout_ms)

    second_wire = receive_binary(client)
    assert {:ok, <<>>, noise} = Noise.read_handshake(noise, second_wire)
    noise
  end

  defp round_trip(client, type, payload, seq, noise) do
    plaintext = encode_client_frame(type, payload, seq)
    assert {:ok, ciphertext, noise} = Noise.encrypt(noise, plaintext)
    assert :ok = WebSockex.send_frame(client, {:binary, ciphertext}, @timeout_ms)

    response = receive_binary(client)
    assert {:ok, response_plaintext, noise} = Noise.decrypt(noise, response)
    {header, <<>>} = decode_server_frame(response_plaintext)
    {header, noise}
  end

  defp receive_binary(client) do
    receive do
      {:wss_binary, ^client, payload} -> payload
      {:unexpected_wss_frame, ^client, frame} -> flunk("unexpected WSS frame: #{inspect(frame)}")
    after
      @timeout_ms -> flunk("timed out waiting for WSS binary frame")
    end
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

  defp unique_name(prefix) do
    Module.concat(__MODULE__, "#{prefix}#{System.unique_integer([:positive, :monotonic])}")
  end
end
