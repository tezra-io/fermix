defmodule FermixChannels.Mobile.EventRouterTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Memory.Repo
  alias FermixCore.Mobile.Store

  defmodule StoreStub do
    def claim_client_request(_profile, "duplicate", _type, _payload, _opts) do
      {:ok, {:duplicate, %{status: "completed", result_server_seq: 44}}}
    end

    def claim_client_request(_profile, "conflict", _type, _payload, _opts) do
      {:ok, {:conflict, %{status: "completed"}}}
    end

    def claim_client_request(_profile, "stranded", _type, _payload, _opts) do
      {:ok, {:duplicate, %{status: "accepted", result_server_seq: nil}}}
    end

    def claim_client_request(profile, id, type, payload, opts) do
      send(self(), {:claimed, profile, id, type, payload, opts[:authenticated_device_id]})
      {:ok, {:claimed, %{status: "running"}}}
    end

    def append_client_message(profile, client_id, attrs, _opts) do
      send(self(), {:appended, profile, attrs})

      status = if client_id == "stranded", do: :existing, else: :created
      {:ok, {status, attrs |> Map.put(:client_msg_id, client_id) |> Map.put(:server_seq, 12)}}
    end

    def settle_client_request(profile, id, status, fields, _opts) do
      send(self(), {:settled, profile, id, status, fields})
      {:ok, Map.merge(fields, %{status: Atom.to_string(status), result_server_seq: nil})}
    end

    def complete_client_request(profile, id, attempt, fields, _opts) do
      send(self(), {:completed, profile, id, attempt, fields})
      seq = if id in ["command-output", "deferred-output"], do: 88, else: nil
      {:ok, %{status: "completed", attempt: attempt, result_server_seq: seq}}
    end

    def fail_client_request(profile, id, attempt, fields, _opts) do
      send(self(), {:failed, profile, id, attempt, fields})
      {:ok, %{status: "failed", attempt: attempt, result_server_seq: 88}}
    end

    def update_client_message(profile, id, attempt, attrs, _opts) do
      send(self(), {:enriched, profile, id, attempt, attrs})
      {:ok, Map.merge(attrs, %{server_seq: 12})}
    end

    def history_page("main", opts) do
      if Keyword.get(opts, :after_seq) == 87 do
        {:ok, %{messages: [timeline_row(88, "done")], next_after_seq: 88}}
      else
        {:ok, %{messages: [timeline_row(9, "hi")], next_after_seq: 9}}
      end
    end

    # Shaped exactly like `Repo.mobile_timeline_row()`, internal columns included.
    defp timeline_row(server_seq, content) do
      %{
        agent_id: "agent",
        owner_id: "owner",
        profile_id: "main",
        server_seq: server_seq,
        kind: "text",
        role: "assistant",
        content: content,
        client_msg_id: nil,
        in_reply_to: "client-1",
        media_refs: [],
        metadata: nil,
        proactive_key: nil,
        request_client_msg_id: "client-1",
        request_attempt: 3,
        output_key: "final",
        created_at: ~U[2026-08-12 12:00:00Z]
      }
    end

    def advance_read_frontier("main", reported, _opts), do: {:ok, max(8, reported)}
  end

  defmodule CoordinatorStub do
    def acquire(_server, _profile, "duplicate", _opts) do
      {:ok, {:completed, %{attempt: 1, result_server_seq: 44}}}
    end

    def acquire(_server, _profile, _id, opts) do
      send(self(), {:acquired, opts})
      {:ok, {:started, %{attempt: 3}}}
    end

    def handoff(_server, profile, id, attempt, owner) do
      send(self(), {:handoff, profile, id, attempt, owner})
      :ok
    end
  end

  defmodule GatewayStub do
    def ingest(messages, opts) do
      send(self(), {:gateway_ingest, messages, opts})
      :ok
    end
  end

  defmodule DeferredGatewayStub do
    def ingest(messages, opts) do
      finish = opts |> Keyword.fetch!(:defer_command_fn) |> then(& &1.())
      send(self(), {:gateway_ingest, messages, opts})
      send(self(), {:deferred_finish, finish})
      :ok
    end
  end

  defmodule MediaStoreStub do
    def attachment(:media, "photo-1") do
      {:ok,
       %{
         attach_id: "photo-1",
         ref: String.duplicate("a", 64),
         kind: "image",
         mime_type: "image/jpeg",
         size_bytes: 42
       }}
    end

    def attachment(:media, "doc-1") do
      {:ok,
       %{
         attach_id: "doc-1",
         ref: String.duplicate("b", 64),
         kind: "document",
         mime_type: "application/pdf",
         size_bytes: 3,
         file_name: "answer.pdf"
       }}
    end

    def attachment(:media, _id), do: {:error, :unknown_attachment}
  end

  # Blocks the pre-ingest span until the test releases it, which is the window
  # in which the router process is killed.
  defmodule GatedMediaStore do
    def attachment(test_pid, attach_id) do
      send(test_pid, {:media_wait, self(), attach_id})

      receive do
        {:media_release, attachment} -> {:ok, attachment}
      after
        5_000 -> {:error, :media_gate_timeout}
      end
    end
  end

  defmodule CrashingMediaStore do
    def attachment(_server, "raise-1"), do: raise("attachment store exploded")
    def attachment(_server, "exit-1"), do: exit(:attachment_store_down)
  end

  defmodule ForwardingGatewayStub do
    def ingest(messages, opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, messages, opts})
      :ok
    end
  end

  setup do
    test_pid = self()

    opts = [
      store: StoreStub,
      coordinator: CoordinatorStub,
      request_coordinator: :coordinator,
      gateway: GatewayStub,
      media_store: MediaStoreStub,
      media_server: :media,
      event_sink: fn target, event ->
        send(test_pid, {:event, target, event})
        :ok
      end,
      agent: FermixChannels.Gateway.Queue,
      agent_server: self(),
      unfurl_launcher: fn task ->
        send(test_pid, :unfurl_started)
        task.()
        :ok
      end,
      unfurl: fn text, _store_thumbnail ->
        send(test_pid, {:unfurl_resolved, text})

        {:ok,
         [
           %{
             url: "https://example.com",
             site: "Example",
             title: "Example title",
             description: nil,
             image_ref: nil
           }
         ], []}
      end
    ]

    context = %{transport: :mobile, authenticated_device_id: "device-1"}
    {:ok, opts: opts, context: context}
  end

  test "a claimed message is durably recorded and enters Gateway with transport proof", ctx do
    event =
      decoded("msg", %{
        "client_msg_id" => "client-1",
        "profile_id" => "main",
        "text" => "look",
        "attach_ids" => ["photo-1"]
      })

    assert :ok = EventRouter.route(event, ctx.context, ctx.opts)
    assert_received {:claimed, "main", "client-1", "msg", _payload, "device-1"}

    assert_received {:appended, "main",
                     %{
                       content: "look",
                       media_refs: [ref]
                     }}

    assert ref["ref"] == String.duplicate("a", 64)
    assert_received {:event, {:device, "device-1"}, %{"t" => "accepted", "duplicate" => false}}

    assert_received {:gateway_ingest, [message], gateway_opts}
    assert message.channel == "mobile"
    assert message.chat_id == "main"
    assert [%{file_id: "photo-1", kind: :image}] = message.attachments
    assert gateway_opts[:ingress_context] == ctx.context
    assert message.metadata.mobile_attempt == 3

    assert :ok = gateway_opts[:ingest_enriched_fn].(%{message | content: "enriched"})
    assert_received {:enriched, "main", "client-1", 3, %{content: "enriched"}}
    resolution = gateway_opts[:approval_resolution_fn]
    token = "SECRET-TOKEN"
    assert :ok = resolution.(%{kind: :sandbox, token: token, outcome: :approved})

    assert_received {:event, {:profile, "main"},
                     %{
                       "t" => "approval_resolved",
                       "approval_id" => approval_id,
                       "outcome" => "approved"
                     }}

    refute approval_id =~ token
    assert_received :unfurl_started
    assert_received {:unfurl_resolved, "look"}

    assert_received {:event, {:profile, "main"},
                     %{
                       "t" => "link_preview",
                       "in_reply_to" => 12,
                       "url" => "https://example.com"
                     }}
  end

  # One wire object, one rule: an absent optional field is an absent key, never
  # an explicit null. `Channels.Mobile` already omits it, so the inbound side
  # must too or the client sees two shapes for the same `mediaRef`.
  test "a timeline media ref omits the filename an attachment does not carry", ctx do
    event =
      decoded("msg", %{
        "client_msg_id" => "client-refs",
        "profile_id" => "main",
        "text" => "look",
        "attach_ids" => ["photo-1", "doc-1"]
      })

    assert :ok = EventRouter.route(event, ctx.context, ctx.opts)
    assert_received {:appended, "main", %{media_refs: [unnamed, named]}}

    refute Map.has_key?(unnamed, "filename")
    assert named["filename"] == "answer.pdf"
  end

  test "accepted fanout failure never gates durable execution", ctx do
    test_pid = self()

    opts =
      Keyword.put(ctx.opts, :event_sink, fn
        {:device, "device-1"}, %{"t" => "accepted"} ->
          {:error, :disconnected}

        target, event ->
          send(test_pid, {:event, target, event})
          :ok
      end)

    event =
      decoded("msg", %{
        "client_msg_id" => "client-disconnected",
        "profile_id" => "main",
        "text" => "still run",
        "attach_ids" => []
      })

    assert :ok = EventRouter.route(event, ctx.context, opts)
    assert_received {:appended, "main", %{content: "still run"}}
    assert_received {:gateway_ingest, [_message], _gateway_opts}
    refute_received {:settled, "main", "client-disconnected", :failed, _fields}
  end

  test "a stored request is recovered with a new fenced attempt", ctx do
    row = %{
      profile_id: "main",
      client_msg_id: "stranded",
      request_type: "msg",
      payload: %{
        "client_msg_id" => "stranded",
        "profile_id" => "main",
        "text" => "recover",
        "attach_ids" => []
      }
    }

    assert :ok = EventRouter.recover_request(row, ctx.context, ctx.opts)
    assert_received {:appended, "main", %{content: "recover"}}
    assert_received {:gateway_ingest, [message], _gateway_opts}
    assert message.metadata.mobile_attempt == 3
    refute_received :unfurl_started
  end

  test "a durable duplicate is acknowledged without running Gateway twice", ctx do
    event =
      decoded("msg", %{
        "client_msg_id" => "duplicate",
        "profile_id" => "main",
        "text" => "same",
        "attach_ids" => []
      })

    assert :ok = EventRouter.route(event, ctx.context, ctx.opts)

    assert_received {:event, {:device, "device-1"},
                     %{"t" => "accepted", "duplicate" => true, "server_seq" => 44}}

    refute_received {:gateway_ingest, _messages, _opts}
  end

  test "a reused client id with different content fails loud", ctx do
    event =
      decoded("command", %{
        "client_msg_id" => "conflict",
        "profile_id" => "main",
        "name" => "help"
      })

    assert {:error, :client_message_conflict} = EventRouter.route(event, ctx.context, ctx.opts)
    refute_received {:event, {:device, "device-1"}, %{"t" => "error"}}
  end

  test "a synchronous command coalesces push after Gateway returns", ctx do
    test_pid = self()

    opts =
      Keyword.merge(ctx.opts,
        push_launcher: fn task ->
          task.()
          :ok
        end,
        push: fn profile, seq, preview ->
          send(test_pid, {:push, profile, seq, preview})
          {:ok, %{status: :sent, sent: 1}}
        end
      )

    event =
      decoded("command", %{
        "client_msg_id" => "command-output",
        "profile_id" => "main",
        "name" => "help"
      })

    assert :ok = EventRouter.route(event, ctx.context, opts)
    assert_received {:gateway_ingest, [_message], _gateway_opts}
    assert_received {:completed, "main", "command-output", 3, %{}}
    assert_received {:push, "main", 88, "done"}
    refute_received {:push, _, _, _}
  end

  test "a deferred command remains running until its terminal callback", ctx do
    test_pid = self()

    opts =
      Keyword.merge(ctx.opts,
        gateway: DeferredGatewayStub,
        push_launcher: fn task ->
          task.()
          :ok
        end,
        push: fn profile, seq, preview ->
          send(test_pid, {:push, profile, seq, preview})
          {:ok, %{status: :sent, sent: 1}}
        end
      )

    event =
      decoded("command", %{
        "client_msg_id" => "deferred-output",
        "profile_id" => "main",
        "name" => "background",
        "args" => "do it"
      })

    assert :ok = EventRouter.route(event, ctx.context, opts)
    assert_received {:gateway_ingest, [message], _gateway_opts}
    assert message.content == "/background do it"
    assert_received {:deferred_finish, finish}
    refute_received {:completed, "main", "deferred-output", 3, %{}}

    assert :ok = finish.(:completed)
    assert_received {:completed, "main", "deferred-output", 3, %{}}
    assert_received {:push, "main", 88, "done"}
    refute_received {:push, _, _, _}
  end

  test "a command whose args are not a string is refused and settled failed", ctx do
    event =
      decoded("command", %{
        "client_msg_id" => "bad-args",
        "profile_id" => "main",
        "name" => "background",
        "args" => ["do", "it"]
      })

    assert {:error, :invalid_command} = EventRouter.route(event, ctx.context, ctx.opts)
    refute_received {:gateway_ingest, _messages, _opts}
    assert_received {:failed, "main", "bad-args", 3, %{error: %{type: "command"}}}
  end

  test "a history page ships the exported message shape, never the store row", ctx do
    history = decoded("history_pull", %{"profile_id" => "main", "after_seq" => 0, "limit" => 20})
    assert :ok = EventRouter.route(history, ctx.context, ctx.opts)

    assert_received {:event, {:device, "device-1"},
                     %{"t" => "history_page", "messages" => [message]}}

    assert message == %{
             "server_seq" => 9,
             "role" => "assistant",
             "content" => "hi",
             "kind" => "text",
             "in_reply_to" => "client-1",
             "media_refs" => [],
             "ts" => "2026-08-12T12:00:00Z"
           }
  end

  test "history and monotonic read state use the durable store", ctx do
    history = decoded("history_pull", %{"profile_id" => "main", "after_seq" => 0, "limit" => 20})
    assert :ok = EventRouter.route(history, ctx.context, ctx.opts)

    assert_received {:event, {:device, "device-1"},
                     %{"t" => "history_page", "profile_id" => "main", "messages" => [_]}}

    read = decoded("read_state", %{"profile_id" => "main", "read_up_to_seq" => 11})
    assert :ok = EventRouter.route(read, ctx.context, ctx.opts)

    assert_received {:event, {:profile, "main"}, %{"t" => "read_state", "read_up_to_seq" => 11}}
  end

  test "mobile events cannot route without exact authenticated-device context", ctx do
    event = decoded("ping", %{})

    assert {:error, :unauthenticated_mobile_transport} = EventRouter.route(event, %{}, ctx.opts)

    assert {:error, :unauthenticated_mobile_transport} =
             EventRouter.route(
               event,
               %{transport: :acp, authenticated_device_id: "device-1"},
               ctx.opts
             )
  end

  test "a crash inside the pre-ingest span settles the attempt and still propagates", ctx do
    opts = Keyword.put(ctx.opts, :media_store, CrashingMediaStore)

    assert_raise RuntimeError, "attachment store exploded", fn ->
      EventRouter.route(crashing_event("raised", "raise-1"), ctx.context, opts)
    end

    assert_received {:failed, "main", "raised", 3, %{error: %{type: "msg"}}}

    assert catch_exit(EventRouter.route(crashing_event("exited", "exit-1"), ctx.context, opts)) ==
             :attachment_store_down

    assert_received {:failed, "main", "exited", 3, %{error: %{type: "msg"}}}
  end

  test "a runner killed before ingest releases its attempt so a resend re-runs" do
    test_pid = self()
    store_opts = [repo: start_mobile_repo(), agent_id: "agent-a", owner_id: "owner-a"]

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         store: Store,
         store_opts: store_opts,
         recover?: false,
         boot_epoch: "boot-router-kill",
         name: nil}
      )

    opts = [
      store: Store,
      store_opts: store_opts,
      request_coordinator: coordinator,
      gateway: ForwardingGatewayStub,
      media_store: GatedMediaStore,
      media_server: test_pid,
      agent_server: test_pid,
      unfurl_launcher: fn _task -> :ok end,
      event_sink: fn _target, _event -> :ok end
    ]

    context = %{transport: :mobile, authenticated_device_id: "device-1"}

    event =
      decoded("msg", %{
        "client_msg_id" => "killed-runner",
        "profile_id" => "main",
        "text" => "run me",
        "attach_ids" => ["photo-1"]
      })

    killed = spawn(fn -> EventRouter.route(event, context, opts) end)
    assert_receive {:media_wait, ^killed, "photo-1"}

    assert {:ok, %{status: "running", attempt: 1}} =
             Store.get_client_request("main", "killed-runner", store_opts)

    kill_and_settle(coordinator, killed)

    assert {:ok, %{status: "accepted", attempt: 1, runner_epoch: nil}} =
             Store.get_client_request("main", "killed-runner", store_opts)

    resend = spawn(fn -> EventRouter.route(event, context, opts) end)
    assert_receive {:media_wait, ^resend, "photo-1"}
    send(resend, {:media_release, gated_attachment()})

    assert_receive {:gateway_ingest, [message], _gateway_opts}
    assert message.content == "run me"
    assert message.metadata.mobile_attempt == 2

    assert {:ok, %{status: "running", attempt: 2, runner_epoch: "boot-router-kill"}} =
             Store.get_client_request("main", "killed-runner", store_opts)
  end

  test "an ingested client event counts one inbound message for the mobile channel", ctx do
    handler_id = attach_message_telemetry(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    event =
      decoded("msg", %{
        "client_msg_id" => "client-telemetry",
        "profile_id" => "main",
        "text" => "hello",
        "attach_ids" => []
      })

    assert :ok = EventRouter.route(event, ctx.context, ctx.opts)

    assert_receive {:telemetry, [:fermix, :channel, :message], %{count: 1, duration_us: us},
                    %{channel: :mobile, direction: :inbound}}

    assert us >= 0
  end

  defp attach_message_telemetry(test_pid) do
    handler_id = "router-message-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :message],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end

  defp start_mobile_repo do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-mobile-router-#{unique}.db")
    repo = :"mobile_router_repo_#{unique}"

    {Repo, name: repo, enabled: true, database_path: db_path}
    |> Supervisor.child_spec(id: repo)
    |> start_supervised!()

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo
  end

  # Kill the fenced process and block until the coordinator has drained the
  # resulting `:DOWN`, so the durable assertion never races the fence.
  defp kill_and_settle(coordinator, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _epoch = RequestCoordinator.epoch(coordinator)
    :ok
  end

  defp crashing_event(client_id, attach_id) do
    decoded("msg", %{
      "client_msg_id" => client_id,
      "profile_id" => "main",
      "text" => "crash",
      "attach_ids" => [attach_id]
    })
  end

  defp gated_attachment do
    %{
      attach_id: "photo-1",
      ref: String.duplicate("a", 64),
      kind: "image",
      mime_type: "image/jpeg",
      size_bytes: 42
    }
  end

  defp decoded(type, payload),
    do: %{type: type, payload: payload, seq: 1, version: 1, bytes: <<>>}
end
