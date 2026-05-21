defmodule FermixChannels.SlackTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Dispatcher
  alias FermixChannels.Slack
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

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :webhook,
      bot_token: "xoxb-test-token",
      signing_secret: "slack-signing-secret",
      # F-02: empty allowlist now denies; tests need an explicit allow.
      allowed_user_ids: ["U12345"],
      req_options: [plug: {Req.Test, :slack}]
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :slack) end)

    :ok
  end

  describe "parse_webhook/1" do
    test "normalizes inbound direct-message events" do
      assert {:ok, [message]} = Slack.parse_webhook(dm_payload("hello slack"))

      assert message.id == "1714000000.000100"
      assert message.content == "hello slack"
      assert message.sender == "Alice"
      assert message.channel == "slack"
      assert message.chat_id == "D12345"
      assert message.reply_target == "D12345"
      assert message.thread_ts == nil
      assert message.metadata.user_id == "U12345"
      assert message.metadata.chat_type == "im"
      assert message.metadata.message_type == "message"
      assert message.attachments == []
    end

    test "normalizes app mentions and scopes replies to the mention thread" do
      assert {:ok, [message]} = Slack.parse_webhook(app_mention_payload("<@U999> hello there"))

      assert message.content == "hello there"
      assert message.chat_id == "C12345"
      assert message.reply_target == "C12345"
      assert message.thread_ts == "1714000000.000100"
      assert message.metadata.channel_type == "channel"
      assert message.metadata.chat_type == "channel"
    end

    test "drops bot-authored events" do
      payload =
        dm_payload("from a bot")
        |> put_in(["event", "bot_id"], "B123")

      assert {:ok, []} = Slack.parse_webhook(payload)
    end

    test "drops senders outside the allowlist" do
      Application.put_env(:fermix_channels, :slack,
        enabled: true,
        bot_token: "xoxb-test-token",
        signing_secret: "slack-signing-secret",
        allowed_user_ids: ["U99999"]
      )

      assert {:ok, []} = Slack.parse_webhook(dm_payload("blocked"))
    end
  end

  describe "dispatch and reply" do
    test "routes inbound direct text through dispatcher and replies via chat.postMessage" do
      test_pid = self()

      Req.Test.stub(:slack, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:slack_request, conn.request_path, Jason.decode!(body), conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "ts" => "1714000001.000100"}))
      end)

      assert {:ok, messages} = Slack.parse_webhook(dm_payload("hello"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: Slack,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}

      assert agent_message.content == "hello"
      assert :ok = agent_message.reply_fn.({:text, "reply from fermix"})

      assert_receive {:slack_request, "/api/chat.postMessage", body, headers}
      assert body["channel"] == "D12345"
      assert body["text"] == "reply from fermix"
      refute Map.has_key?(body, "thread_ts")
      assert {"authorization", "Bearer xoxb-test-token"} in headers
    end

    test "routes app mentions through MainAgent and replies in the mention thread" do
      test_pid = self()
      agent_name = :"slack_main_agent_#{System.unique_integer([:positive])}"
      store_name = :"slack_conversation_store_#{System.unique_integer([:positive])}"

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

      Req.Test.stub(:slack, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:slack_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "ts" => "1714000001.000100"}))
      end)

      assert {:ok, messages} =
               Slack.parse_webhook(app_mention_payload("<@U999> hello main agent"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: Slack,
                 agent: MainAgent,
                 agent_server: agent
               )

      assert_receive {:slack_request, "/api/chat.postMessage", body}, 5_000
      assert body["channel"] == "C12345"
      assert body["text"] == "reply from main agent"
      assert body["thread_ts"] == "1714000000.000100"
    end
  end

  describe "send_media/3" do
    test "uses Slack external upload URL POST flow and complete parameters" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("slack-send-media")
      test_pid = self()

      Req.Test.stub(:slack, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.request_path do
          "/api/files.getUploadURLExternal" ->
            send(test_pid, {:slack_upload_url, Jason.decode!(body), conn.req_headers})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "ok" => true,
                "upload_url" => "https://files.slack.test/upload/F123",
                "file_id" => "F123"
              })
            )

          "/upload/F123" ->
            send(test_pid, {:slack_upload_post, body, conn.req_headers})
            Plug.Conn.send_resp(conn, 200, "")

          "/api/files.completeUploadExternal" ->
            send(test_pid, {:slack_complete, Jason.decode!(body), conn.req_headers})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
        end
      end)

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "report")

        assert :ok =
                 Slack.send_media(
                   "C12345",
                   %{
                     kind: :document,
                     path: path,
                     caption: "Report",
                     filename: "report.txt",
                     mime_type: "text/plain"
                   },
                   thread_ts: "1714000000.000100"
                 )

        assert_receive {:slack_upload_url, upload_url_body, upload_url_headers}
        assert upload_url_body == %{"filename" => "report.txt", "length" => 6}
        assert {"authorization", "Bearer xoxb-test-token"} in upload_url_headers

        assert_receive {:slack_upload_post, "report", upload_headers}
        assert {"content-type", "text/plain"} in upload_headers
        assert {"content-length", "6"} in upload_headers

        assert_receive {:slack_complete, complete_body, complete_headers}
        assert complete_body["channel_id"] == "C12345"
        assert complete_body["files"] == [%{"id" => "F123", "title" => "report.txt"}]
        assert complete_body["initial_comment"] == "Report"
        assert complete_body["thread_ts"] == "1714000000.000100"
        assert {"authorization", "Bearer xoxb-test-token"} in complete_headers
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "rejects media over the Slack cap before upload" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("slack-send-media-cap")

      try do
        path = Path.join(tmp_dir, "oversize.bin")
        write_sparse_file!(path, 100 * 1_024 * 1_024 + 1)

        assert {:error, {:byte_cap_exceeded, actual, allowed}} =
                 Slack.send_media("C12345", %{
                   kind: :document,
                   path: path,
                   filename: "oversize.bin"
                 })

        assert actual == 100 * 1_024 * 1_024 + 1
        assert allowed == 100 * 1_024 * 1_024
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "verify_webhook/1" do
    test "accepts valid Slack request signatures" do
      body = Jason.encode!(dm_payload("signed"))
      timestamp = Integer.to_string(System.os_time(:second))
      signature = slack_signature(body, timestamp)

      conn =
        Plug.Test.conn(:post, "/webhook/slack", body)
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)
        |> Plug.Conn.put_req_header("x-slack-signature", signature)
        |> Plug.Conn.assign(:raw_body, body)

      assert :ok = Slack.verify_webhook(conn)
    end

    test "rejects missing send configuration" do
      Application.put_env(:fermix_channels, :slack, enabled: true)

      assert {:error, :not_configured} = Slack.send_message("D12345", "hello")
    end

    test "rejects text over Slack's hard truncation bound before send" do
      assert {:error, {:text_cap_exceeded, 40_001, 40_000}} =
               Slack.send_message("D12345", String.duplicate("a", 40_001))
    end

    test "returns structured rate limit errors when Slack provides Retry-After" do
      Req.Test.stub(:slack, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"ok" => false, "error" => "ratelimited"}))
      end)

      assert {:error, {:rate_limited, 2_000}} = Slack.send_message("D12345", "hello")
    end
  end

  defp dm_payload(text) do
    %{
      "type" => "event_callback",
      "team_id" => "T12345",
      "api_app_id" => "A12345",
      "event" => %{
        "type" => "message",
        "channel" => "D12345",
        "channel_type" => "im",
        "user" => "U12345",
        "username" => "Alice",
        "text" => text,
        "ts" => "1714000000.000100"
      }
    }
  end

  defp app_mention_payload(text) do
    %{
      "type" => "event_callback",
      "team_id" => "T12345",
      "api_app_id" => "A12345",
      "event" => %{
        "type" => "app_mention",
        "channel" => "C12345",
        "channel_type" => "channel",
        "user" => "U12345",
        "username" => "alice",
        "text" => text,
        "ts" => "1714000000.000100"
      }
    }
  end

  defp slack_signature(body, timestamp) do
    digest =
      :crypto.mac(:hmac, :sha256, "slack-signing-secret", "v0:#{timestamp}:#{body}")

    "v0=" <> Base.encode16(digest, case: :lower)
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
