defmodule FermixChannels.Desktop.TunnelAttachmentsTest do
  @moduledoc """
  The attach button after a move (M97 §9.3, D22): a client on this
  computer's own `companion.sock`, its `Desktop.Tunnel` and this computer's
  `Desktop.Uploads`, with a stand-in relay that plays the server's side of
  the chat (its `server_hello`) and of the upload (its `attach_status`). The
  upload over the real link is `Desktop.UploadsTest`'s.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Desktop.Relay.Media
  alias FermixChannels.Desktop.Tunnel
  alias FermixChannels.Desktop.Uploads
  alias FermixTestSupport.SafeRm

  @arrival_ms 10_000
  @bytes "the lease, page one"
  @server_hello ~s({"type":"server_hello","min_version":1,"max_version":8,"role":"primary","commands":[]})

  defmodule FakeRelay do
    @moduledoc false
    # The relay as the tunnel and the uploads see it: one channel, its lines
    # told to the test; a server whose bound is 4,096 bytes, or none.
    use GenServer

    def start_link({test, bound}), do: GenServer.start_link(__MODULE__, {test, bound})

    @impl true
    def init({test, bound}), do: {:ok, %{test: test, bound: bound}}

    @impl true
    def handle_call(:open_channel, {tunnel, _tag}, state) do
      send(state.test, {:tunnel, tunnel})
      {:reply, {:ok, 1, self()}, state}
    end

    def handle_call(:upload_bound, _from, state), do: {:reply, state.bound, state}

    def handle_call({:send, type, fields, payload}, _from, state) do
      send(state.test, {:sent, type, fields, payload})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:line, 1, _tunnel, line}, state) do
      send(state.test, {:to_server, Jason.decode!(line)})
      {:noreply, state}
    end

    def handle_cast({:close_channel, 1, _tunnel}, state), do: {:noreply, state}
  end

  setup do
    root = SafeRm.make_tmp_dir!("tunnel-attach")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root, inbox: Path.join(root, "inbox")}
  end

  test "a version 7 app is offered this computer's inbox, and its file goes to the server " <>
         "from here",
       ctx do
    %{socket: socket, uploads: uploads} = start_device!(ctx, {:ok, 4_096})
    client = connect(socket)

    send_line(client, %{"type" => "client_hello", "protocol_version" => 7})
    assert_receive {:tunnel, tunnel}, @arrival_ms
    assert_receive {:to_server, %{"type" => "client_hello"}}, @arrival_ms
    send(tunnel, {:relay_line, 1, @server_hello})

    assert %{"type" => "server_hello", "role" => "primary", "attachments" => offer} = recv(client)
    assert offer == %{"dir" => ctx.inbox, "max_bytes" => 4_096}

    File.write!(Path.join(ctx.inbox, "mac-att-7"), @bytes)
    send_line(client, attach_file("mac-att-7"))

    assert_receive {:sent, "attach_begin", %{"attach_id" => "mac-att-7", "sha256" => digest}, _},
                   @arrival_ms

    assert digest == sha256(@bytes)
    Uploads.handle(uploads, "attach_status", %{"attach_id" => "mac-att-7", "status" => "upload"})
    assert_receive {:sent, "attach_chunk", %{"index" => 0}, @bytes}, @arrival_ms
    assert_receive {:sent, "attach_end", %{"sha256" => ^digest}, <<>>}, @arrival_ms
    Uploads.handle(uploads, "attach_status", %{"attach_id" => "mac-att-7", "status" => "present"})

    assert recv(client) == %{
             "type" => "attach_status",
             "attach_id" => "mac-att-7",
             "status" => "present"
           }

    refute_received {:to_server, %{"type" => "attach_file"}}

    # The message that names it is the server's, which finds the file there.
    send_line(client, %{
      "type" => "msg",
      "client_msg_id" => "mac-1",
      "profile_id" => "main",
      "text" => "",
      "attach_ids" => ["mac-att-7"]
    })

    assert_receive {:to_server, %{"type" => "msg", "attach_ids" => ["mac-att-7"]}}, @arrival_ms
  end

  test "a refusal answers the file with the sentence and its attach id", ctx do
    %{socket: socket} = start_device!(ctx, {:ok, 4})
    client = hello_v7(socket)

    File.write!(Path.join(ctx.inbox, "mac-att-8"), @bytes)
    send_line(client, attach_file("mac-att-8"))

    assert recv(client) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "This file is too large: Fermix takes files of up to 4 bytes.",
             "attach_id" => "mac-att-8"
           }
  end

  # An older app, or a server that takes no upload from a computer: no
  # attachments are offered, and a file sent anyway is the server's to refuse.
  test "a version 6 app, or a server that takes none, is offered no inbox", ctx do
    %{socket: socket} = start_device!(ctx, {:error, :not_taken})

    for version <- [6, 7] do
      client = connect(socket)
      send_line(client, %{"type" => "client_hello", "protocol_version" => version})
      assert_receive {:tunnel, tunnel}, @arrival_ms
      assert_receive {:to_server, %{"type" => "client_hello"}}, @arrival_ms
      send(tunnel, {:relay_line, 1, @server_hello})
      hello = recv(client)
      refute Map.has_key?(hello, "attachments")

      if version == 7 do
        send_line(client, attach_file("mac-att-9"))
        assert_receive {:to_server, %{"type" => "attach_file"}}, @arrival_ms
      end
    end
  end

  # -- the device -----------------------------------------------------------------------

  defp start_device!(ctx, bound) do
    unique = System.unique_integer([:positive])
    relay = start_supervised!({FakeRelay, {self(), bound}})
    uploads = start_supervised!({Uploads, name: nil, dir: ctx.inbox, relay: relay})
    staging = Media.staging_dir(ctx.root)
    :ok = Media.prepare(staging)
    connections = :"tunnel_attach_conns_#{unique}"
    socket = Path.join(System.tmp_dir!(), "fx-ta-#{unique}.sock")
    on_exit(fn -> SafeRm.rm(socket) end)

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    start_supervised!(
      {Endpoint,
       name: :"tunnel_attach_endpoint_#{unique}",
       socket_path: socket,
       connection_supervisor: connections,
       connection_module: Tunnel,
       connection_opts: [relay: relay, staging: staging, uploads: uploads, status_watch: nil]}
    )

    %{socket: socket, uploads: uploads}
  end

  # -- the client -------------------------------------------------------------------------

  defp hello_v7(socket) do
    client = connect(socket)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 7})
    assert_receive {:tunnel, tunnel}, @arrival_ms
    # The server answers the hello it was sent.
    assert_receive {:to_server, %{"type" => "client_hello"}}, @arrival_ms
    send(tunnel, {:relay_line, 1, @server_hello})
    assert %{"type" => "server_hello", "attachments" => _offer} = recv(client)
    client
  end

  defp attach_file(attach_id),
    do: %{
      "type" => "attach_file",
      "attach_id" => attach_id,
      "kind" => "document",
      "mime" => "application/pdf",
      "size_bytes" => byte_size(@bytes),
      "sha256" => sha256(@bytes),
      "name" => "lease.pdf"
    }

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end
end
