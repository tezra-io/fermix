defmodule FermixChannels.Mobile.EventRouterTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.EventRouter

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
        {:ok,
         %{
           messages: [%{server_seq: 88, role: "assistant", kind: "text", content: "done"}],
           next_after_seq: 88
         }}
      else
        {:ok,
         %{messages: [%{server_seq: 9, role: "assistant", content: "hi"}], next_after_seq: 9}}
      end
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

    def attachment(:media, _id), do: {:error, :unknown_attachment}
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
      unfurl: fn text ->
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
        "args" => ["do", "it"]
      })

    assert :ok = EventRouter.route(event, ctx.context, opts)
    assert_received {:deferred_finish, finish}
    refute_received {:completed, "main", "deferred-output", 3, %{}}

    assert :ok = finish.(:completed)
    assert_received {:completed, "main", "deferred-output", 3, %{}}
    assert_received {:push, "main", 88, "done"}
    refute_received {:push, _, _, _}
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

  defp decoded(type, payload),
    do: %{type: type, payload: payload, seq: 1, version: 1, bytes: <<>>}
end
