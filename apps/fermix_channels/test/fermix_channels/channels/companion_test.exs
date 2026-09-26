defmodule FermixChannels.Channels.CompanionTest do
  # The adapter broadcasts through the one application-wide companion registry,
  # and each test joins it under the only profile, so the tests run alone.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source

  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule StoreStub do
    def append(profile, attrs, _opts) do
      send(self(), {:append, profile, attrs})
      {:ok, Map.merge(attrs, %{profile_id: profile, server_seq: 41})}
    end

    def append_client_output(profile, client_id, attempt, key, attrs, _opts) do
      send(self(), {:client_output, profile, client_id, attempt, key, attrs})
      {:ok, {:created, Map.merge(attrs, %{profile_id: profile, server_seq: 42})}}
    end

    def append_proactive(profile, key, attrs, _opts) do
      send(self(), {:proactive, profile, key, attrs})
      {:ok, {:existing, Map.merge(attrs, %{profile_id: profile, server_seq: 43})}}
    end

    def complete_client_request(profile, client_id, attempt, _fields, _opts) do
      send(self(), {:completed, profile, client_id, attempt})
      {:ok, %{status: "completed"}}
    end

    def fail_client_request(profile, client_id, attempt, fields, _opts) do
      send(self(), {:failed, profile, client_id, attempt, fields})
      {:ok, %{status: "failed"}}
    end
  end

  setup do
    previous = Application.fetch_env(:fermix_channels, :companion_store)
    Application.put_env(:fermix_channels, :companion_store, StoreStub)
    {:ok, _owner} = Registry.register(Companion.registry(), "main", nil)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :companion_store, value)
        :error -> Application.delete_env(:fermix_channels, :companion_store)
      end
    end)

    :ok
  end

  describe "registry entry" do
    test "carries the local-operator shape with slash commands on" do
      entry = Enum.find(ChannelRegistry.channels(), &(&1.name == "companion"))

      assert entry == %{
               name: "companion",
               config_key: nil,
               adapter: Companion,
               remote?: true,
               trust: :local_operator,
               transport: :loopback,
               child: nil
             }

      assert ChannelRegistry.commands?("companion")

      refute "companion" in Enum.map(
               ChannelRegistry.transport_children(%{status: :ready}),
               &elem(&1, 0)
             )
    end

    test "authorizes as the operator with no sender id and no ingress list" do
      source = Source.from_message(%{channel: "companion", chat_id: "main", metadata: %{}})
      assert {:ok, %{role: :operator, trust: :operator}} = Authorizer.resolve(source)
    end

    test "the shipped config delivers scheduled jobs back into the companion timeline" do
      channels =
        @config_exs
        |> Config.Reader.read!(env: :prod, target: :host)
        |> Keyword.fetch!(:fermix_core)
        |> Keyword.fetch!(:jobs)
        |> Keyword.fetch!(:delivery_channels)

      assert channels["companion"] == Companion
    end
  end

  test "parses a message and a command onto the companion conversation" do
    assert {:ok, [message]} =
             Companion.parse_event(%{
               type: "msg",
               payload: %{
                 "client_msg_id" => "mac-1",
                 "profile_id" => "main",
                 "text" => "hi",
                 "attach_ids" => []
               }
             })

    assert %Message{channel: "companion", chat_id: "main", reply_target: "main"} = message
    assert message.metadata.turn_id == "turn-mac-1"
    assert Companion.conversation_key("main") == {"companion", "main", :root}

    assert {:ok, [command]} =
             Companion.parse_event(%{
               type: "command",
               payload: %{
                 "client_msg_id" => "mac-2",
                 "profile_id" => "main",
                 "name" => "confirm",
                 "args" => "TOKEN"
               }
             })

    assert command.content == "/confirm TOKEN"

    assert {:error, :unsupported_profile} =
             Companion.parse_event(%{type: "msg", payload: %{"profile_id" => "work"}})

    assert {:error, :attachments_unsupported} =
             Companion.parse_event(%{
               type: "msg",
               payload: %{
                 "client_msg_id" => "mac-3",
                 "profile_id" => "main",
                 "text" => "x",
                 "attach_ids" => ["a"]
               }
             })
  end

  test "a message ingests as the operator with the raw stream and every turn closure" do
    {:ok, [message]} =
      Companion.parse_event(%{
        type: "msg",
        payload: %{
          "client_msg_id" => "mac-7",
          "profile_id" => "main",
          "text" => "what is on today",
          "attach_ids" => []
        }
      })

    assert :ok =
             Gateway.ingest([message],
               channel: Companion,
               agent: CapturingAgent,
               agent_server: self(),
               ingress_context: %{transport: :companion}
             )

    assert_receive {:agent_message, agent_message}
    assert agent_message.channel == "companion"
    assert agent_message.source_trust == :operator
    assert %{mode: :raw, callback: callback} = agent_message.stream_spec
    assert is_function(callback, 1)
    assert is_function(agent_message.activity_callback, 1)
    assert is_function(agent_message.turn_result_fn, 1)
  end

  test "the raw stream announces the turn and relays cumulative snapshots" do
    message = request_message()
    assert Companion.stream_capability() == :raw
    stream = Companion.build_raw_stream_callback(message)

    stream.({:session_started, "session-1"})

    assert_receive {:companion_event,
                    %{
                      "t" => "turn_started",
                      "profile_id" => "main",
                      "turn_id" => "turn-mac-1",
                      "in_reply_to" => "mac-1"
                    }}

    stream.({:text_delta, "Hel"})
    stream.({:iteration_started, 2})
    stream.({:reasoning_delta, "thinking"})
    stream.({:text_done, "Hello"})

    assert_receive {:companion_stream, "turn-mac-1", {:snapshot, "Hel"}}
    assert_receive {:companion_stream, "turn-mac-1", :reset}
    assert_receive {:companion_stream, "turn-mac-1", {:snapshot, "Hello"}}
    refute_receive {:companion_stream, _turn, {:snapshot, "thinking"}}
  end

  test "a request's reply is its attempt's output and is announced at its row" do
    reply = Companion.build_text_reply(request_message())
    assert :ok = reply.("the answer")

    assert_receive {:client_output, "main", "mac-1", 3, "text:" <> _digest, attrs}
    assert attrs.content == "the answer"
    assert attrs.in_reply_to == "mac-1"

    assert_receive {:companion_event,
                    %{"t" => "text_done", "turn_id" => "turn-mac-1", "server_seq" => 42}}
  end

  test "a scheduled job's delivery is a plain row, announced whether or not anyone listens" do
    handler = attach_message_telemetry()
    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Companion.send_message("main", "your 9am summary", [])

    assert_receive {:append, "main", %{role: "assistant", content: "your 9am summary"}}
    assert_receive {:companion_event, %{"t" => "text_done", "server_seq" => 41}}

    assert_receive {:telemetry, %{count: 1}, %{channel: :companion, direction: :outbound}}

    assert :ok = Companion.send_message("main", "again", proactive_key: "reminder-1")
    assert_receive {:proactive, "main", "reminder-1", _attrs}
    refute_receive {:companion_event, %{"t" => "text_done", "server_seq" => 43}}

    assert {:error, :unsupported_profile} = Companion.send_message("work", "x", [])
  end

  test "the turn result settles the request and a failure is announced" do
    message = request_message()
    result = Companion.build_turn_result(message)

    assert :ok = result.({:completed})
    assert_receive {:completed, "main", "mac-1", 3}

    assert :ok = result.({:cancelled})
    assert_receive {:failed, "main", "mac-1", 3, _fields}

    assert_receive {:companion_event,
                    %{"t" => "turn_error", "turn_id" => "turn-mac-1", "code" => "cancelled"}}

    assert :ok = result.({:failed, {:provider_error, 500}})
    assert_receive {:companion_event, %{"t" => "turn_error", "code" => "turn_failed"}}
  end

  test "tool activity and approvals reach the profile, with no null fields" do
    message = request_message()
    activity = Companion.build_activity_callback(message)
    assert :ok = activity.({:tool_start, "shell"})

    assert_receive {:companion_event,
                    %{"t" => "tool_event", "tool" => "shell", "phase" => "start"}}

    assert :ok = Companion.send_approval(message, "Allow this? /confirm TOK", "TOK")
    assert_receive {:companion_event, %{"t" => "approval"} = approval}

    assert approval["approve_command"] == "/confirm TOK"
    assert approval["deny_command"] == "/deny TOK"
    assert approval["text"] == "Allow this?"
    refute Map.has_key?(approval, "detail")
  end

  test "media does not travel on this socket" do
    assert {:error, :unsupported_media} =
             Companion.send_media("main", %{kind: :image, path: "/tmp/x.png"}, [])
  end

  defp request_message do
    Message.new!(%{
      id: "mac-1",
      content: "hello",
      sender: "Companion owner",
      channel: "companion",
      chat_id: "main",
      reply_target: "main",
      metadata: %{client_msg_id: "mac-1", companion_attempt: 3, turn_id: "turn-mac-1"}
    })
  end

  defp attach_message_telemetry do
    handler_id = "companion-message-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :message],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

    handler_id
  end
end
