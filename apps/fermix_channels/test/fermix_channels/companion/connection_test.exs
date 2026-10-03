defmodule FermixChannels.Companion.ConnectionTest do
  # End to end over a real 0600 Unix socket: the endpoint, a connection, the
  # shared request path, the request coordinator and the companion timeline on
  # a throwaway repo. Only the Gateway and the Queue are stand-ins.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Connection
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Output
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.ParentProcess

  defmodule GatewayStub do
    def ingest([message], opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, message, opts})
      :ok
    end
  end

  # Stands in for `Companion.Turns`, the settlement owner: every request
  # became a turn except an `inline-` one, which the gateway answered itself
  # and which this settles, as Turns does, then reports; each cancel is
  # reported too.
  defmodule TurnsStub do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:cancel, profile, client_msg_id}, _from, test_pid) do
      send(test_pid, {:turns_cancel, profile, client_msg_id})
      {:reply, :ok, test_pid}
    end

    @impl true
    def handle_cast(
          {:settle_unless_handed_off, {_profile, id}, _attempt, %{settle: settle}},
          test_pid
        ) do
      if String.starts_with?(id, "inline-"), do: send(test_pid, {:settled_inline, id, settle.()})
      {:noreply, test_pid}
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

    turns = start_supervised!({TurnsStub, self()})

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
      settlement_owner: turns
    ]

    endpoint_opts = [
      name: :"companion_conn_endpoint_#{unique}",
      socket_path: socket_path,
      max_clients: 2,
      connection_supervisor: connections,
      connection_opts: [registry: registry, request_opts: request_opts]
    ]

    start_supervised!({Endpoint, endpoint_opts})

    %{
      endpoint_opts: endpoint_opts,
      request_opts: request_opts,
      socket_path: socket_path,
      registry: registry,
      store_opts: store_opts,
      coordinator: coordinator,
      queue_owner: queue_owner,
      turns: turns
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
    assert recv(client) == %{"type" => "server_hello", "min_version" => 1, "max_version" => 2}

    send_line(client, %{"type" => "client_hello", "protocol_version" => 1})
    assert %{"type" => "error", "reason" => "unexpected_client_hello"} = recv(client)
    assert closed?(client)
  end

  # M56 §6: version 2 adds `turn_done`, and version 1 is still served. Each
  # connection is known by the version its hello declared, so the daemon can
  # tell whether any client attached would hang on a turn with no reply.
  test "a version 1 and a version 2 client are both served, each known by its version", ctx do
    old = hello(ctx.socket_path, 1)
    new = hello(ctx.socket_path, 2)

    versions =
      ctx.registry
      |> Registry.lookup("main")
      |> Enum.map(fn {_connection, version} -> version end)
      |> Enum.sort()

    assert versions == [1, 2]

    for client <- [old, new] do
      send_line(client, %{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 0})
      assert %{"type" => "read_state"} = recv(client)
    end
  end

  test "turn_done reaches a version 2 client only; a version 1 client never sees it", ctx do
    old = hello(ctx.socket_path, 1)
    new = hello(ctx.socket_path, 2)

    :ok = Companion.broadcast("main", Output.turn_done("turn-quiet"), ctx.registry)

    done = %{"t" => "text_done", "turn_id" => "turn-next", "server_seq" => 3, "text" => "Hi"}
    :ok = Companion.broadcast("main", done, ctx.registry)

    assert recv(new) == %{"type" => "turn_done", "turn_id" => "turn-quiet"}
    assert %{"type" => "text_done", "turn_id" => "turn-next"} = recv(new)
    assert %{"type" => "text_done", "turn_id" => "turn-next"} = recv(old)
  end

  # FEAT-2: a client that was not connected when an approval went out gets it
  # right after its server_hello, with the time it has left.
  test "an approval still waiting follows the server_hello", ctx do
    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         schedule: fn _message, _delay -> make_ref() end,
         announce: fn _profile, _card, _transport -> :ok end},
        id: :waiting_approvals
      )

    card = Output.approval(%{kind: :soul, text: "Apply?", token: "SOUL-T"})

    assert :ok = Approvals.announce(approvals, "main", card, :companion)
    restart_endpoint(ctx, approvals: approvals)

    client = connect(ctx.socket_path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 1})
    assert %{"type" => "server_hello"} = recv(client)

    assert %{"type" => "approval", "approval_id" => id, "ttl_s" => ttl} = recv(client)
    assert id == card["approval_id"]
    assert ttl in 299..300
  end

  # R1-2: a card raised on the phone resolves only from the phone (M19 §9.5),
  # so the Mac is never re-sent it, and what a Mac request resolves is told
  # to the Mac alone.
  test "the Mac is re-sent only its own waiting approvals, and hears only its resolutions",
       ctx do
    test_pid = self()

    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         schedule: fn _message, _delay -> make_ref() end,
         announce: fn profile, event, audience ->
           send(test_pid, {:announced, profile, event, audience})
           :ok
         end},
        id: :origin_approvals
      )

    phone_card = Output.approval(%{kind: :sandbox, text: "Phone?", token: "PHONE-T"})
    mac_card = Output.approval(%{kind: :sandbox, text: "Mac?", token: "MAC-T"})
    assert :ok = Approvals.announce(approvals, "main", phone_card, :mobile)
    assert :ok = Approvals.announce(approvals, "main", mac_card, :companion)

    stop_supervised!(Endpoint)

    ctx.endpoint_opts
    |> Keyword.put(:connection_opts,
      registry: ctx.registry,
      approvals: approvals,
      request_opts: ctx.request_opts ++ [approvals: approvals]
    )
    |> then(&start_supervised!({Endpoint, &1}))

    client = hello(ctx.socket_path)
    assert %{"type" => "approval", "token" => "MAC-T"} = recv(client)

    send_line(client, message("mac-approve", "/confirm MAC-T"))
    assert %{"type" => "accepted", "client_msg_id" => "mac-approve"} = recv(client)
    assert_receive {:gateway_ingest, _message, gateway_opts}, 2_000

    resolve = gateway_opts[:approval_resolution_fn]
    assert :ok = resolve.(%{kind: :sandbox, token: "MAC-T", outcome: :approved})

    assert_receive {:announced, "main", %{"t" => "approval_resolved", "outcome" => "approved"},
                    :companion}

    assert [%{"token" => "PHONE-T"}] = Approvals.pending(approvals, "main", :mobile)
    assert Approvals.pending(approvals, "main", :companion) == []
  end

  test "a client outside the window learns which side must update", %{socket_path: path} do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 3})

    assert recv(client) == %{
             "type" => "error",
             "reason" => "unsupported_protocol_version",
             "direction" => "client_too_new",
             "client_version" => 3,
             "min_version" => 1,
             "max_version" => 2
           }

    assert closed?(client)
  end

  test "a message is claimed once, acknowledged, and a resend never runs twice", ctx do
    client = hello(ctx.socket_path)
    watcher = hello(ctx.socket_path)
    msg = message("mac-1", "hello from the Mac")

    send_line(client, msg)

    assert %{"type" => "accepted", "client_msg_id" => "mac-1", "duplicate" => false} =
             recv(client)

    # The user's row is announced as it is written, to the sender and to every
    # other connection, whatever becomes of its turn.
    for socket <- [client, watcher] do
      assert %{
               "type" => "row",
               "profile_id" => "main",
               "server_seq" => 1,
               "role" => "user",
               "text" => "hello from the Mac",
               "client_msg_id" => "mac-1",
               "ts" => "20" <> _rest
             } = recv(socket)
    end

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
    assert {:error, :timeout} = :gen_tcp.recv(watcher, 0, 200)

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
    assert %{"type" => "row", "client_msg_id" => "mac-count"} = recv(client)

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
    assert %{"type" => "row", "client_msg_id" => "mac-2"} = recv(client)
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
    append_rows(ctx, 5)
    first = hello(ctx.socket_path)
    second = hello(ctx.socket_path)

    send_line(first, %{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 4})

    assert %{"type" => "read_state", "read_up_to_seq" => 4} = recv(first)
    assert %{"type" => "read_state", "read_up_to_seq" => 4} = recv(second)

    # A frontier is never ahead of the timeline.
    send_line(first, %{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 99})
    assert %{"type" => "read_state", "read_up_to_seq" => 5} = recv(first)
  end

  # The wire allows any u64 cursor and SQLite holds i64: every cursor past the
  # timeline answers, and the Repo that serves all of core stays up.
  test "cursors beyond SQLite's range answer on the companion socket", ctx do
    append_rows(ctx, 2)
    repo_pid = Process.whereis(ctx.store_opts[:repo])
    client = hello(ctx.socket_path)

    for cursor <- [
          9_223_372_036_854_775_807,
          9_223_372_036_854_775_808,
          18_446_744_073_709_551_615
        ] do
      send_line(client, %{
        "type" => "history_pull",
        "profile_id" => "main",
        "after_seq" => cursor,
        "limit" => 5
      })

      assert %{"type" => "history_page", "messages" => [], "next_after_seq" => ^cursor} =
               recv(client)

      send_line(client, %{
        "type" => "history_pull",
        "profile_id" => "main",
        "before_seq" => cursor,
        "limit" => 5
      })

      assert %{"type" => "history_page", "messages" => [_first, _second]} = recv(client)

      send_line(client, %{
        "type" => "history_search",
        "profile_id" => "main",
        "query" => "row",
        "before_seq" => cursor,
        "limit" => 5
      })

      assert %{"type" => "search_results", "hits" => [_ | _]} = recv(client)

      send_line(client, %{
        "type" => "read_state",
        "profile_id" => "main",
        "read_up_to_seq" => cursor
      })

      assert %{"type" => "read_state", "read_up_to_seq" => 2} = recv(client)
    end

    assert Process.whereis(ctx.store_opts[:repo]) == repo_pid
  end

  # One page is one line the Mac reads under a 64 KiB cap: rows are cut at the
  # byte budget, newest kept going back, oldest kept going forward.
  test "a history page is cut to fit one line", ctx do
    long = String.duplicate("z", 25 * 1_024)

    for _row <- 1..4 do
      assert {:ok, _row} =
               Timeline.append("main", %{role: "assistant", content: long}, ctx.store_opts)
    end

    client = hello(ctx.socket_path)

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "after_seq" => 0,
      "limit" => 10
    })

    forward = recv(client)
    assert Enum.map(forward["messages"], & &1["server_seq"]) == [1, 2]
    assert forward["next_after_seq"] == 2

    send_line(client, %{
      "type" => "history_pull",
      "profile_id" => "main",
      "before_seq" => 5,
      "limit" => 10
    })

    backward = recv(client)
    assert Enum.map(backward["messages"], & &1["server_seq"]) == [3, 4]
    assert backward["next_before_seq"] == 3
  end

  # A request the gateway answered without a turn (here a slash command typed
  # as text) is complete once ingest returns, instead of left running and run
  # again at every boot.
  test "a request answered without a turn is completed at once", ctx do
    client = hello(ctx.socket_path)
    send_line(client, message("inline-1", "/status"))
    assert %{"type" => "accepted", "client_msg_id" => "inline-1"} = recv(client)
    assert %{"type" => "row", "client_msg_id" => "inline-1"} = recv(client)
    assert_receive {:gateway_ingest, _message, _opts}, 2_000

    # The settlement owner reports once it has settled the request.
    assert_receive {:settled_inline, "inline-1", :ok}, 2_000

    assert {:ok, %{status: "completed"}} =
             Timeline.get_client_request("main", "inline-1", ctx.store_opts)
  end

  # R4-2: a request that fails after its worker returned (an inline settlement
  # the settlement owner could not record) is told through this socket's own
  # error builder, as a failed worker is; at boot recovery nobody is waiting.
  test "a request's late failure is told in this socket's own error", ctx do
    client = hello(ctx.socket_path)
    [{connection, 1}] = Registry.lookup(ctx.registry, "main")

    assert :ok = Connection.transport(connection).report_failure.("mac-late", {:exit, :timeout})

    assert recv(client) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "{:exit, :timeout}",
             "client_msg_id" => "mac-late"
           }

    assert :ok = Connection.transport(nil).report_failure.("mac-recovered", :already_settled)
  end

  test "turn events reach the socket, and each stream snapshot is sent as its unsent suffix",
       ctx do
    client = hello(ctx.socket_path)
    [{connection, 1}] = Registry.lookup(ctx.registry, "main")

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

  test "cancel records itself on the named request before stopping its turn, and answers nothing",
       ctx do
    client = hello(ctx.socket_path)
    send_line(client, message("mac-7", "a long answer, please"))
    assert %{"type" => "accepted", "duplicate" => false} = recv(client)
    assert %{"type" => "row", "client_msg_id" => "mac-7"} = recv(client)
    assert_receive {:gateway_ingest, _message, _opts}, 2_000

    send_line(client, %{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-7"})
    assert_receive {:turns_cancel, "main", "mac-7"}, 2_000
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 200)

    assert {:ok, %{status: "running", cancelled_at: %DateTime{}}} =
             Timeline.get_client_request("main", "mac-7", ctx.store_opts)

    # A request that already settled, or one never claimed, is left alone.
    assert {:ok, _request} =
             Timeline.complete_client_request("main", "mac-7", 1, %{}, ctx.store_opts)

    send_line(client, %{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-7"})
    send_line(client, %{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-8"})
    refute_receive {:turns_cancel, _profile, _id}, 200
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

    turns = ctx.turns

    recover = fn row, context, opts ->
      Connection.recover_request(
        row,
        context,
        opts ++ [gateway: GatewayStub, agent_server: queue_owner, settlement_owner: turns]
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

  describe "who is on the other end (SIDE-V1)" do
    test "a message from a client the daemon did not start stays an attended turn", ctx do
      message = ingested_message(ctx.socket_path, "mac-peer-1")

      assert message.metadata.caller == :independent
      assert TurnRunner.computer_use_origin(message) == :interactive
    end

    # An agent's shell command speaking the chat socket. This VM stands in for
    # it: the connection is told the daemon's process is this VM's parent, so the
    # kernel's peer pid and the real process table must place the client beneath it.
    test "a message from a client the daemon started reaches the agent unattended", ctx do
      restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())
      message = ingested_message(ctx.socket_path, "mac-peer-2")

      assert message.metadata.caller == :daemon_descendant
      assert TurnRunner.computer_use_origin(message) == :unattended
    end

    test "a connection the daemon cannot place is refused before the handshake", ctx do
      restart_endpoint(ctx, os: {:win32, :nt})

      {_result, log} =
        with_log(fn ->
          client = connect(ctx.socket_path)

          assert %{"type" => "error", "reason" => "unidentified_client", "message" => message} =
                   recv(client)

          assert message =~ "could not identify the process on this connection"
          assert closed?(client)
        end)

      assert log =~ "companion connection refusing a client"
    end

    # A client gone before it could be placed is nobody to refuse: the connection
    # ends quietly, as it does when it reads the socket closed.
    test "a client that hung up before it was placed is not refused" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-companion-#{System.unique_integer([:positive])}.sock"
        )

      on_exit(fn -> FermixTestSupport.SafeRm.rm(path) end)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
      {:ok, client} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, active: false])
      {:ok, accepted} = :gen_tcp.accept(listener, 1_000)
      :ok = :gen_tcp.close(client)

      {_result, log} =
        with_log(fn ->
          {:ok, connection} = GenServer.start(Connection, socket: accepted)
          ref = Process.monitor(connection)
          :ok = :gen_tcp.controlling_process(accepted, connection)
          send(connection, :socket_handover)

          assert_receive {:DOWN, ^ref, :process, ^connection, :normal}, 5_000
        end)

      :gen_tcp.close(listener)
      refute log =~ "refusing"
    end
  end

  test "the exported protocol documents every error reason the socket sends" do
    protocol = File.read!(Application.app_dir(:fermix_core, "priv/companion/PROTOCOL.md"))

    for reason <- Connection.error_reasons() do
      assert protocol =~ "`#{reason}`", "PROTOCOL.md does not document error #{reason}"
    end
  end

  defp append_rows(ctx, count) do
    Enum.each(1..count, fn index ->
      assert {:ok, _row} =
               Timeline.append(
                 "main",
                 %{role: "assistant", content: "row #{index}"},
                 ctx.store_opts
               )
    end)
  end

  defp forward(test_pid) do
    receive do
      message -> send(test_pid, message)
    end

    forward(test_pid)
  end

  defp hello(path, version \\ 1) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => version})
    assert %{"type" => "server_hello"} = recv(client)
    client
  end

  # The endpoint again, with `connection_opts` added to the ones setup gave it.
  defp restart_endpoint(ctx, connection_opts) do
    stop_supervised!(Endpoint)

    ctx.endpoint_opts
    |> Keyword.update!(:connection_opts, &(&1 ++ connection_opts))
    |> then(&start_supervised!({Endpoint, &1}))
  end

  # One `msg` on a fresh, handshaken connection; hands back the message the
  # Gateway was given.
  defp ingested_message(path, client_msg_id) do
    client = hello(path)
    send_line(client, message(client_msg_id, "take a screenshot"))
    assert %{"type" => "accepted", "client_msg_id" => ^client_msg_id} = recv(client)
    assert_receive {:gateway_ingest, message, _opts}, 2_000
    message
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
        packet: :line,
        buffer: 128 * 1_024
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
