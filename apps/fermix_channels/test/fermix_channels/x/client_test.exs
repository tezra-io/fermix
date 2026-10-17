defmodule FermixChannels.X.ClientTest do
  # The connection to Connect (priv/connect/PROTOCOL.md §3) with the socket
  # injected: no network. The pump is the test process, so every report the
  # client makes to it arrives as a `$gen_cast`; the instance key lives under
  # a home of the test's own.
  use ExUnit.Case, async: true

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Client
  alias FermixChannels.X.Client.Socket
  alias FermixChannels.X.Pairing
  alias FermixCore.Net.Egress
  alias FermixTestSupport.SafeRm

  @nonce String.duplicate("n", 43)
  @ready %{
    "t" => "ready",
    "session_ttl_s" => 900,
    "max_assignment_bytes" => 32_768,
    "max_result_bytes" => 16_384
  }

  defmodule FakeSocket do
    @moduledoc false
    # Stands in for `X.Client.Socket`: linked to the client like the real one,
    # it reports each frame the client sends to the test and exits when told.

    def start_link(url, %{owner: owner}, opts) when is_pid(owner) do
      test = Keyword.fetch!(opts, :test)

      case Keyword.get(opts, :refuse) do
        nil ->
          socket = spawn_link(fn -> loop(test) end)
          send(test, {:dialed, url, opts, socket})
          {:ok, socket}

        reason ->
          {:error, reason}
      end
    end

    def send_json(socket, json) do
      send(socket, {:sent, json})
      :ok
    end

    def close(socket) do
      send(socket, {:exit, :normal})
      :ok
    end

    defp loop(test) do
      receive do
        {:sent, json} ->
          send(test, {:socket_sent, Jason.decode!(json)})
          loop(test)

        {:exit, reason} ->
          exit(reason)
      end
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("x-client")
    on_exit(fn -> SafeRm.rm_rf(home) end)
    pairing = [root: home]
    {:ok, public_key} = Pairing.ensure_key(pairing)
    {connect_public, _seed} = Fixtures.connect_key()
    record = Fixtures.record(connect_public, %{key_id: Pairing.key_id(public_key)})

    %{record: record, pairing: pairing, public_key: public_key}
  end

  defp start_client(ctx, opts \\ []) do
    defaults = [
      name: :"x_client_#{System.unique_integer([:positive])}",
      pump: self(),
      pairing: ctx.pairing,
      socket_module: FakeSocket,
      socket_options: [test: self()],
      egress: %Egress{},
      jitter: fn _max -> 0 end
    ]

    {:ok, client} = Client.start_link(ctx.record, Keyword.merge(defaults, opts))
    assert_receive {:dialed, url, dial_opts, socket}
    %{client: client, socket: socket, url: url, opts: dial_opts}
  end

  defp frame(%{client: client, socket: socket}, frame),
    do: send(client, {:x_socket, socket, {:frame, frame}})

  defp ready!(conn) do
    frame(conn, %{"t" => "challenge", "nonce" => @nonce})
    assert_receive {:socket_sent, %{"t" => "hello"}}
    frame(conn, @ready)
    assert_receive {:"$gen_cast", {:connection, {:connected, _limits}}}
  end

  test "TLS options are set last, over anything the caller passed" do
    assert {:ok, opts} =
             Client.start_options("wss://connect.fermix.example/v1/connect",
               ssl_options: [verify: :verify_none]
             )

    assert opts[:ssl_options][:verify] == :verify_peer
    assert opts[:ssl_options][:server_name_indication] == ~c"connect.fermix.example"
    assert {:error, :ws_url_without_host} = Client.start_options("wss:///v1/connect", [])
  end

  test "it dials the origin's socket with the instance's headers and no secret", ctx do
    conn = start_client(ctx)

    assert conn.url == "wss://connect.fermix.example/v1/connect"

    assert conn.opts[:extra_headers] == [
             {"X-Fermix-Instance", "ins_7f3c2a9e1b4d"},
             {"X-Fermix-Key-Id", ctx.record.key_id},
             {"Sec-WebSocket-Protocol", "fermix-connect.v1"}
           ]

    assert conn.opts[:ssl_options][:verify] == :verify_peer
    assert_receive {:"$gen_cast", {:connection, :connecting}}
  end

  test "a challenge is answered with a hello signed over the session string", ctx do
    conn = start_client(ctx)
    frame(conn, %{"t" => "challenge", "nonce" => @nonce})

    assert_receive {:socket_sent, %{"t" => "hello"} = hello}
    assert hello["protocol_version"] == 1
    assert hello["capabilities"] == %{"final_only" => true, "max_result_bytes" => 16_384}

    signed = "fermix-connect-session|https://connect.fermix.example|ins_7f3c2a9e1b4d|#{@nonce}|1"
    assert Client.session_message(ctx.record, @nonce) == signed
    {:ok, signature} = Base.url_decode64(hello["signature"], padding: false)
    assert Pairing.verify(signed, signature, ctx.public_key)
  end

  test "ready connects the pump with the session's caps; frames then flow both ways", ctx do
    conn = start_client(ctx)
    frame(conn, %{"t" => "assignment", "jws" => "early"})
    ready!(conn)
    refute_received {:"$gen_cast", {:frame, %{"jws" => "early"}}}

    frame(conn, %{"t" => "assignment", "jws" => "a.b.c"})
    assert_receive {:"$gen_cast", {:frame, %{"t" => "assignment", "jws" => "a.b.c"}}}

    assert :ok = Client.send_receipt(conn.client, "as_1", {:rejected, :over_cap})

    assert_receive {:socket_sent,
                    %{
                      "t" => "receipt",
                      "assignment_id" => "as_1",
                      "outcome" => "rejected",
                      "reason" => "over_cap"
                    }}

    assert :ok = Client.send_start(conn.client, "as_1")
    assert_receive {:socket_sent, %{"t" => "start", "assignment_id" => "as_1"}}
  end

  test "nothing is sent before the session is ready", ctx do
    conn = start_client(ctx)
    assert {:error, :not_connected} = Client.send_cancel_ack(conn.client, "as_1")
  end

  test "a 4401 close is refused for good and never redialed", ctx do
    conn = start_client(ctx)
    ready!(conn)

    send(conn.client, {:x_socket, conn.socket, {:closed, {:remote, 4401, "revoked"}}})
    send(conn.socket, {:exit, {:remote, 4401, "revoked"}})

    assert_receive {:"$gen_cast", {:connection, {:refused, :revoked}}}
    refute_received {:dialed, _url, _opts, _socket}
  end

  test "a lost socket reports down and is redialed after its backoff", ctx do
    conn = start_client(ctx)
    ready!(conn)

    send(conn.socket, {:exit, {:remote, :closed}})

    assert_receive {:"$gen_cast", {:connection, :down}}
    assert_receive {:dialed, _url, _opts, _socket}, 10_000
  end

  test "the session's TTL closes the socket and dials again", ctx do
    conn = start_client(ctx)
    frame(conn, %{"t" => "challenge", "nonce" => @nonce})
    assert_receive {:socket_sent, %{"t" => "hello"}}
    frame(conn, %{@ready | "session_ttl_s" => 1})
    assert_receive {:"$gen_cast", {:connection, {:connected, _limits}}}

    assert_receive {:dialed, _url, _opts, _socket}, 10_000
    refute_received {:"$gen_cast", {:connection, :down}}
  end

  test "the socket is handed the client's route" do
    proxied = Egress.new(proxy: "http://proxy.fermix.example:3128")
    {connect_public, _seed} = Fixtures.connect_key()
    home = SafeRm.make_tmp_dir!("x-client-route")
    on_exit(fn -> SafeRm.rm_rf(home) end)

    {:ok, _client} =
      Client.start_link(Fixtures.record(connect_public),
        name: :"x_client_#{System.unique_integer([:positive])}",
        pump: self(),
        pairing: [root: home],
        socket_module: FakeSocket,
        socket_options: [test: self()],
        egress: proxied
      )

    assert_receive {:dialed, _url, opts, _socket}
    assert opts[:egress] == proxied
  end

  test "the socket refuses a proxied route before it dials" do
    proxied = Egress.new(proxy: "http://proxy.fermix.example:3128")

    assert {:error, :proxy_unsupported_transport} =
             Socket.start_link("wss://connect.fermix.example/v1/connect", %{owner: self()},
               egress: proxied
             )
  end

  test "a proxy refusal from the socket is final: the pump is told and nothing redials", ctx do
    {:ok, _client} =
      Client.start_link(ctx.record,
        name: :"x_client_#{System.unique_integer([:positive])}",
        pump: self(),
        pairing: ctx.pairing,
        socket_module: FakeSocket,
        socket_options: [test: self(), refuse: :proxy_unsupported_transport],
        egress: %Egress{}
      )

    assert_receive {:"$gen_cast", {:connection, {:refused, :proxy_unsupported_transport}}}
    refute_received {:dialed, _url, _opts, _socket}
  end
end
