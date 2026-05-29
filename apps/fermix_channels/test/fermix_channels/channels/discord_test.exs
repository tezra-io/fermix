defmodule FermixChannels.Channels.DiscordTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Discord
  alias FermixChannels.Dispatcher
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.ConversationStore

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule StaticProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: {:ok, response()}

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(_messages, _capabilities, _opts), do: {:ok, turn()}

    @impl FermixCore.Providers.Adapter
    def continue(_provider_state, _tool_results, _opts), do: {:ok, turn()}

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp response do
      %{
        content: "reply from main agent",
        tool_calls: [],
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      }
    end

    defp turn do
      %{
        content: "reply from main agent",
        tool_calls: [],
        provider_state: %{},
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock-model"
      }
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()

    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      mode: :gateway,
      bot_token: "discord-bot-token",
      bot_user_id: "999",
      # F-02: empty allowlist now denies; tests need an explicit allow.
      allowed_user_ids: ["111"],
      req_options: [plug: {Req.Test, :discord}]
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :discord) end)

    :ok
  end

  describe "parse_gateway_event/1" do
    test "normalizes direct message events" do
      assert {:ok, [message]} = Discord.parse_gateway_event(dm_event("hello discord"))

      assert message.id == "message-1"
      assert message.content == "hello discord"
      assert message.sender == "alice"
      assert message.channel == "discord"
      assert message.chat_id == "dm-channel-1"
      assert message.reply_target == "dm-channel-1"
      assert message.metadata.guild_id == nil
      assert message.metadata.user_id == "111"
      assert message.metadata.chat_type == "private"
      refute Map.has_key?(message.metadata, :author_id)
      assert message.attachments == []
    end

    test "accepts guild app mentions and strips the bot mention from content" do
      assert {:ok, [message]} = Discord.parse_gateway_event(mention_event("<@999> hello there"))

      assert message.content == "hello there"
      assert message.chat_id == "guild-channel-1"
      assert message.metadata.guild_id == "guild-1"
      assert message.metadata.chat_type == "guild"
    end

    test "drops guild messages that do not mention the bot" do
      assert {:ok, []} = Discord.parse_gateway_event(mention_event("hello there", []))
    end

    test "drops bot-authored messages" do
      event =
        dm_event("from a bot")
        |> put_in(["d", "author", "bot"], true)

      assert {:ok, []} = Discord.parse_gateway_event(event)
    end

    test "keeps file attachment metadata" do
      event =
        dm_event("see file")
        |> put_in(["d", "attachments"], [
          %{
            "id" => "attachment-1",
            "url" => "https://cdn.discordapp.com/file.png",
            "content_type" => "image/png",
            "size" => 12_345
          }
        ])

      assert {:ok, [message]} = Discord.parse_gateway_event(event)

      assert message.attachments == [
               %{
                 kind: :image,
                 url: "https://cdn.discordapp.com/file.png",
                 mime_type: "image/png",
                 file_id: "attachment-1",
                 size_bytes: 12_345
               }
             ]
    end

    test "drops senders outside the allowlist" do
      Application.put_env(:fermix_channels, :discord,
        enabled: true,
        bot_user_id: "999",
        allowed_user_ids: ["222"]
      )

      assert {:ok, []} = Discord.parse_gateway_event(dm_event("blocked"))
    end
  end

  describe "webhook transport" do
    test "reports webhook parsing as unsupported" do
      assert {:error, :unsupported_transport} = Discord.parse_webhook(%{})
    end

    test "reports webhook verification as unsupported" do
      assert {:error, :unsupported_transport} =
               Discord.verify_webhook(Plug.Test.conn(:post, "/webhook/discord", "{}"))
    end
  end

  describe "dispatch and reply" do
    test "routes inbound direct text through dispatcher and replies through REST" do
      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(self(), {:discord_request, conn.request_path, Jason.decode!(body), conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
      end)

      assert {:ok, messages} = Discord.parse_gateway_event(dm_event("hello"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: Discord,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}

      assert agent_message.content == "hello"
      assert :ok = agent_message.reply_fn.({:text, "reply from fermix"})

      assert_receive {:discord_request, "/api/v10/channels/dm-channel-1/messages", body, headers}
      assert body["content"] == "reply from fermix"
      assert body["message_reference"]["message_id"] == "message-1"
      assert body["allowed_mentions"] == %{"parse" => []}
      assert {"authorization", "Bot discord-bot-token"} in headers
    end

    test "routes inbound direct text through MainAgent and sends the agent reply" do
      test_pid = self()
      agent_name = :"discord_main_agent_#{System.unique_integer([:positive])}"
      store_name = :"discord_conversation_store_#{System.unique_integer([:positive])}"

      conversation_store = start_supervised!({ConversationStore, [name: store_name]})

      agent =
        start_supervised!(
          {MainAgent,
           [
             name: agent_name,
             provider: StaticProvider,
             conversation_store: conversation_store
           ]}
        )

      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:discord_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
      end)

      assert {:ok, messages} = Discord.parse_gateway_event(dm_event("hello main agent"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: Discord,
                 agent: MainAgent,
                 agent_server: agent
               )

      assert_receive {:discord_request, "/api/v10/channels/dm-channel-1/messages", body}, 5_000
      assert body["content"] == "reply from main agent"
      assert body["message_reference"]["message_id"] == "message-1"
    end
  end

  describe "send_message/3" do
    test "rejects missing send configuration" do
      Application.put_env(:fermix_channels, :discord, enabled: true)

      assert {:error, :not_configured} = Discord.send_message("dm-channel-1", "hello")
    end

    test "rejects text over the Discord content cap before send" do
      assert {:error, {:text_cap_exceeded, 2_001, 2_000}} =
               Discord.send_message("dm-channel-1", String.duplicate("a", 2_001))
    end

    test "returns structured rate limit errors when Discord provides retry_after" do
      Req.Test.stub(:discord, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"retry_after" => 1.5}))
      end)

      assert {:error, {:rate_limited, 1_500}} =
               Discord.send_message("dm-channel-1", "hello")
    end
  end

  describe "send_media/3" do
    test "posts multipart media with payload metadata" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("discord-send-media")
      test_pid = self()

      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:discord_media_request, conn.request_path, body, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
      end)

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "report")

        assert :ok =
                 Discord.send_media(
                   "dm-channel-1",
                   %{
                     kind: :document,
                     path: path,
                     caption: "Report",
                     filename: "report.txt",
                     mime_type: "text/plain"
                   },
                   reply_to: "message-1"
                 )

        assert_receive {:discord_media_request, request_path, body, headers}
        assert request_path == "/api/v10/channels/dm-channel-1/messages"
        assert {"authorization", "Bot discord-bot-token"} in headers
        assert body =~ ~s(name="payload_json")
        assert body =~ ~s("content":"Report")
        assert body =~ ~s("message_id":"message-1")
        assert body =~ ~s(name="files[0]")
        assert body =~ "report.txt"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "rejects media over the Discord cap before upload" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("discord-send-media-cap")

      try do
        path = Path.join(tmp_dir, "oversize.bin")
        write_sparse_file!(path, 10 * 1_024 * 1_024 + 1)

        assert {:error, {:byte_cap_exceeded, actual, allowed}} =
                 Discord.send_media("dm-channel-1", %{
                   kind: :document,
                   path: path,
                   filename: "oversize.bin"
                 })

        assert actual == 10 * 1_024 * 1_024 + 1
        assert allowed == 10 * 1_024 * 1_024
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  defp dm_event(content) do
    %{
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "id" => "message-1",
        "channel_id" => "dm-channel-1",
        "content" => content,
        "guild_id" => nil,
        "author" => %{"id" => "111", "username" => "alice", "bot" => false},
        "attachments" => []
      }
    }
  end

  defp mention_event(content, mentions \\ [%{"id" => "999"}]) do
    %{
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "id" => "message-2",
        "channel_id" => "guild-channel-1",
        "content" => content,
        "guild_id" => "guild-1",
        "author" => %{"id" => "111", "username" => "alice", "bot" => false},
        "mentions" => mentions,
        "attachments" => []
      }
    }
  end

  defp write_sparse_file!(path, size) when is_binary(path) and is_integer(size) and size > 0 do
    {:ok, file} = File.open(path, [:write, :binary])

    try do
      {:ok, _position} = :file.position(file, size - 1)
      :ok = IO.binwrite(file, <<0>>)
    after
      File.close(file)
    end
  end
end
