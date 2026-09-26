defmodule FermixChannels.Companion.ConnectionTest do
  # End to end over a real 0600 Unix socket: the endpoint, a connection, the
  # shared request path, the request coordinator and the companion timeline on
  # a throwaway repo. Only the Gateway and the Queue are stand-ins.
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Connection
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo

  defmodule GatewayStub do
    def ingest([message], opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, message, opts})
      :ok
    end
  end

  # Answers `Queue.stop_turn/3` and reports it.
  defmodule QueueStub do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:stop_turn, key, message_id}, _from, test_pid) do
      send(test_pid, {:stop_turn, key, message_id})
      {:reply, {:ok, :not_found}, test_pid}
    end
  end

  # Reads a page, then announces a later row the way a turn's end does, inside
  # the window between the read and the page reaching the socket.
  defmodule AnnouncingStore do
    def history_page(profile, opts) do
      {registry, opts} = Keyword.pop!(opts, :announce_registry)
      page = Timeline.history_page(profile, opts)
      late = %{"t" => "text_done", "turn_id" => "turn-late", "server_seq" => 99, "text" => "late"}
      :ok = Companion.broadcast(profile, late, registry)
      page
    end
  end

  setup do
    test_pid = self()
    unique = System.unique_integer([:positive])
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("companion-conn")
    db_path = Path.join(dir, "memory.db")
    repo = :"companion_conn_repo_#{unique}"
    registry = :"companion_conn_registry_#{unique}"
    connections = :"companion_conn_sup_#{unique}"
    # A socket address is short: it lives directly under the temp root.
    socket_path = Path.join(System.tmp_dir!(), "fermix-companion-#{unique}.sock")

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(dir)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    # The stand-in queue a turn's settlement is handed to. Started first so it
    # outlives the coordinator fencing on it: a test's end is not a dead queue.
    queue_owner = start_supervised!({Task, fn -> forward(test_pid) end}, id: :queue_owner)

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({Registry, keys: :duplicate, name: registry})
    store_opts = [repo: repo, agent_id: "agent-c", owner_id: "owner-c"]

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil,
         boot_epoch: "boot-companion",
         store_opts: [transport: "companion"] ++ store_opts,
         recover?: false}
      )

    queue = start_supervised!({QueueStub, self()})

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    request_opts = [
      store_opts: store_opts,
      request_coordinator: coordinator,
      gateway: GatewayStub,
      agent_server: queue_owner,
      settlement_owner: queue_owner
    ]

    start_supervised!(
      {Endpoint,
       name: :"companion_conn_endpoint_#{unique}",
       socket_path: socket_path,
       max_clients: 2,
       connection_supervisor: connections,
       connection_opts: [registry: registry, queue: queue, request_opts: request_opts]}
    )

    %{
      socket_path: socket_path,
      registry: registry,
      store_opts: store_opts,
      coordinator: coordinator,
      queue_owner: queue_owner
    }
  end

  test "the socket is owner-only", %{socket_path: path} do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "the handshake is mandatory and one-shot", %{socket_path: path} do
    early = connect(path)
    send_line(early, %{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 1})
    assert %{"type" => "error", "reason" => "handshake_required"} = recv(early)
    assert closed?(early)

    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 1})
    assert recv(client) == %{"type" => "server_hello", "min_version" => 1, "max_version" => 1}

    send_line(client, %{"type" => "client_hello", "protocol_version" => 1})
    assert %{"type" => "error", "reason" => "unexpected_client_hello"} = recv(client)
    assert closed?(client)
  end

  test "a client outside the window learns which side must update", %{socket_path: path} do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 2})

    assert recv(client) == %{
             "type" => "error",
             "reason" => "unsupported_protocol_version",
             "direction" => "client_too_new",
             "client_version" => 2,
             "min_version" => 1,
             "max_version" => 1
           }

    assert closed?(client)
  end

  test "a message is claimed once, acknowledged, and a resend never runs twice", ctx do
    client = hello(ctx.socket_path)
    msg = message("mac-1", "hello from the Mac")

    send_line(client, msg)

    assert %{"type" => "accepted", "client_msg_id" => "mac-1", "duplicate" => false} =
             recv(client)

    assert_receive {:gateway_ingest, message, gateway_opts}, 2_000

    assert message.channel == "companion"
    assert message.chat_id == "main"
    assert message.content == "hello from the Mac"
    assert message.metadata.companion_attempt == 1
    assert gateway_opts[:channel] == Companion
    assert gateway_opts[:ingress_context] == %{transport: :companion}

    send_line(client, msg)
    assert %{"type" => "accepted", "client_msg_id" => "mac-1", "duplicate" => true} = recv(client)
    refute_receive {:gateway_ingest, _message, _opts}, 200

    assert {:ok, %{status: "running", transport: "companion", authenticated_device_id: nil}} =
             Timeline.get_client_request("main", "mac-1", ctx.store_opts)
  end

  test "a message counts once as an inbound companion message, and its resend not again",
       ctx do
    test_pid = self()
    handler = "companion-inbound-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:fermix, :channel, :parse], [:fermix, :channel, :message]],
        fn event, measurements, metadata, _config ->
          if metadata.channel == :companion, do: send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    client = hello(ctx.socket_path)
    msg = message("mac-count", "count me once")

    send_line(client, msg)
    assert %{"type" => "accepted", "duplicate" => false} = recv(client)

    assert_receive {[:fermix, :channel, :parse], %{duration_us: _parse_us}, %{status: :ok}},
                   2_000

    assert_receive {[:fermix, :channel, :message], %{count: 1, duration_us: us},
                    %{direction: :inbound}}

    assert is_integer(us) and us >= 0

    send_line(client, msg)
    assert %{"type" => "accepted", "duplicate" => true} = recv(client)
    refute_receive {[:fermix, :channel, :message], _measurements, %{direction: :inbound}}, 200
  end

  test "a reused id with other content is a conflict and the connection stays", ctx do
    client = hello(ctx.socket_path)
    send_line(client, message("mac-2", "first"))
    assert %{"type" => "accepted"} = recv(client)
    assert_receive {:gateway_ingest, _message, _opts}, 2_000

    send_line(client, message("mac-2", "different"))

    assert %{
             "type" => "error",
             "reason" => "client_message_conflict",
             "client_msg_id" => "mac-2"
           } = recv(client)

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "after_seq" => 0,
      "limit" => 10
    })

    assert %{"type" => "history_page"} = recv(client)
  end

  test "history pages forward and backward over the shared timeline", ctx do
    Enum.each(1..3, fn index ->
      assert {:ok, _row} =
               Timeline.append(
                 "main",
                 %{role: "assistant", content: "row #{index}"},
                 ctx.store_opts
               )
    end)

    client = hello(ctx.socket_path)

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "after_seq" => 0,
      "limit" => 2
    })

    assert %{
             "type" => "history_page",
             "messages" => [
               %{"server_seq" => 1, "ts" => _ts, "media_refs" => []},
               %{"server_seq" => 2}
             ],
             "next_after_seq" => 2,
             "history_head_seq" => 3
           } = recv(client)

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "before_seq" => 3,
      "limit" => 1
    })

    page = recv(client)
    assert [%{"server_seq" => 2, "content" => "row 2"}] = page["messages"]
    assert page["next_before_seq"] == 2
    refute Map.has_key?(page, "next_after_seq")
  end

  test "a row announced while its page is read reaches the socket after the page", ctx do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-companion-page-#{unique}.sock")
    connections = :"companion_page_sup_#{unique}"
    on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    request_opts = [
      store: AnnouncingStore,
      store_opts: [announce_registry: ctx.registry] ++ ctx.store_opts
    ]

    start_supervised!(
      {Endpoint,
       name: :"companion_page_endpoint_#{unique}",
       socket_path: socket_path,
       max_clients: 1,
       connection_supervisor: connections,
       connection_opts: [registry: ctx.registry, request_opts: request_opts]},
      id: :page_endpoint
    )

    client = hello(socket_path)

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "after_seq" => 0,
      "limit" => 5
    })

    assert %{"type" => "history_page", "messages" => []} = recv(client)
    assert %{"type" => "text_done", "server_seq" => 99} = recv(client)
  end

  test "search answers hits with plain excerpts and their matched ranges", ctx do
    assert {:ok, _row} =
             Timeline.append("main", %{role: "user", content: "book the dentist"}, ctx.store_opts)

    client = hello(ctx.socket_path)

    send_line(client, %{
      "type" => "history_search",
      "profile_id" => "main",
      "query" => "dent",
      "limit" => 5
    })

    assert %{
             "type" => "search_results",
             "profile_id" => "main",
             "query" => "dent",
             "hits" => [
               %{
                 "server_seq" => 1,
                 "role" => "user",
                 "excerpt" => "book the dentist",
                 "ranges" => [%{"start" => 9, "length" => 7}]
               }
             ]
           } = recv(client)
  end

  test "read state is told to every connection watching the profile", ctx do
    first = hello(ctx.socket_path)
    second = hello(ctx.socket_path)

    send_line(first, %{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 4})

    assert %{"type" => "read_state", "read_up_to_seq" => 4} = recv(first)
    assert %{"type" => "read_state", "read_up_to_seq" => 4} = recv(second)
  end

  test "turn events reach the socket, and each stream snapshot is sent as its unsent suffix",
       ctx do
    client = hello(ctx.socket_path)
    [{connection, nil}] = Registry.lookup(ctx.registry, "main")

    send(connection, {:companion_stream, "turn-1", {:snapshot, "Hel"}})
    send(connection, {:companion_stream, "turn-1", {:snapshot, "Hello"}})
    send(connection, {:companion_stream, "turn-1", :reset})
    send(connection, {:companion_stream, "turn-1", {:snapshot, "Next"}})

    assert %{"type" => "text_delta", "turn_id" => "turn-1", "text" => "Hel"} = recv(client)
    assert %{"type" => "text_delta", "text" => "lo"} = recv(client)
    assert %{"type" => "text_delta", "text" => "Next"} = recv(client)

    send(
      connection,
      {:companion_event,
       %{"t" => "text_done", "turn_id" => "turn-1", "server_seq" => 9, "text" => "Hello Next"}}
    )

    assert %{"type" => "text_done", "server_seq" => 9} = recv(client)
  end

  test "cancel stops only the named request's turn and answers nothing itself", ctx do
    client = hello(ctx.socket_path)
    send_line(client, %{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-7"})
    assert_receive {:stop_turn, {"companion", "main", :root}, "mac-7"}, 2_000
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 200)

    send_line(client, %{"type" => "cancel", "profile_id" => "work", "client_msg_id" => "mac-7"})
    assert %{"type" => "error", "reason" => "unsupported_profile"} = recv(client)
  end

  test "protocol violations are answered once and close the connection", ctx do
    oversized = hello(ctx.socket_path)
    :ok = :gen_tcp.send(oversized, String.duplicate("x", 65_537))
    assert %{"type" => "error", "reason" => "line_too_large"} = recv(oversized)
    assert closed?(oversized)

    unknown = hello(ctx.socket_path)
    send_line(unknown, %{"type" => "ping"})
    assert %{"type" => "error", "reason" => "unknown_event", "event" => "ping"} = recv(unknown)
    assert closed?(unknown)
  end

  test "a message carrying attachments is refused on this wire", ctx do
    client = hello(ctx.socket_path)
    send_line(client, %{message("mac-3", "look") | "attach_ids" => ["photo"]})
    assert %{"type" => "error", "reason" => "attachments_unsupported"} = recv(client)
    assert closed?(client)
    refute_receive {:gateway_ingest, _message, _opts}, 100
  end

  test "a client over the cap is told so and closed", ctx do
    _first = hello(ctx.socket_path)
    _second = hello(ctx.socket_path)
    third = connect(ctx.socket_path)
    assert %{"type" => "error", "reason" => "max_clients_reached"} = recv(third)
    assert closed?(third)
  end

  test "boot recovery reruns a companion request an earlier boot left running", ctx do
    store_opts = [transport: "companion"] ++ ctx.store_opts

    payload = %{
      "client_msg_id" => "mac-9",
      "profile_id" => "main",
      "text" => "again",
      "attach_ids" => []
    }

    assert {:ok, {:claimed, _request}} =
             Timeline.claim_client_request("main", "mac-9", "msg", payload, store_opts)

    assert {:ok, {:started, _request}} =
             Timeline.start_client_request("main", "mac-9", "boot-earlier", store_opts)

    queue_owner = ctx.queue_owner

    recover = fn row, context, opts ->
      Connection.recover_request(
        row,
        context,
        opts ++ [gateway: GatewayStub, agent_server: queue_owner, settlement_owner: queue_owner]
      )
    end

    start_supervised!(
      {RequestCoordinator,
       name: nil,
       boot_epoch: "boot-later",
       store_opts: store_opts,
       recover_request: recover,
       recovery_launcher: fn task -> {:ok, spawn(task)} end},
      id: :recovering_coordinator
    )

    assert_receive {:gateway_ingest, message, _opts}, 2_000
    assert message.content == "again"
    assert message.metadata.companion_attempt == 2

    assert {:ok, %{status: "running", runner_epoch: "boot-later"}} =
             Timeline.get_client_request("main", "mac-9", ctx.store_opts)
  end

  test "the exported protocol documents every error reason the socket sends" do
    protocol = File.read!(Application.app_dir(:fermix_core, "priv/companion/PROTOCOL.md"))

    for reason <- Connection.error_reasons() do
      assert protocol =~ "`#{reason}`", "PROTOCOL.md does not document error #{reason}"
    end
  end

  defp forward(test_pid) do
    receive do
      message -> send(test_pid, message)
    end

    forward(test_pid)
  end

  defp hello(path) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 1})
    assert %{"type" => "server_hello"} = recv(client)
    client
  end

  defp message(client_msg_id, text) do
    %{
      "type" => "msg",
      "client_msg_id" => client_msg_id,
      "profile_id" => "main",
      "text" => text,
      "attach_ids" => []
    }
  end

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
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    Jason.decode!(line)
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}
end
