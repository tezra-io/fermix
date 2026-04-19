defmodule FermixChannels.WhatsAppTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Dispatcher
  alias FermixChannels.WhatsApp
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

    @impl true
    def chat(_messages, _opts) do
      {:ok,
       %{
         content: "reply from main agent",
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
       }}
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  setup do
    Req.Test.set_req_test_to_shared()

    Application.put_env(:fermix_channels, :whatsapp,
      enabled: true,
      mode: :webhook,
      access_token: "whatsapp-access-token",
      phone_number_id: "123456789",
      verify_token: "verify-token",
      app_secret: "app-secret",
      req_options: [plug: {Req.Test, :whatsapp}]
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :whatsapp) end)

    :ok
  end

  describe "parse_webhook/1" do
    test "normalizes inbound Cloud API text messages" do
      assert {:ok, [message]} = WhatsApp.parse_webhook(payload("hello from whatsapp"))

      assert message.id == "wamid.123"
      assert message.content == "hello from whatsapp"
      assert message.sender == "Alice"
      assert message.channel == "whatsapp"
      assert message.chat_id == "15551234567"
      assert message.reply_target == "15551234567"
      assert message.metadata.phone_number_id == "123456789"
      assert message.metadata.message_type == "text"
      assert message.attachments == []
    end

    test "keeps audio attachment metadata for the transcription path" do
      audio_message =
        payload("", %{
          "messages" => [
            %{
              "from" => "15551234567",
              "id" => "wamid.audio",
              "timestamp" => "1714000000",
              "type" => "audio",
              "audio" => %{
                "id" => "audio-media-id",
                "mime_type" => "audio/ogg",
                "sha256" => "media-sha"
              }
            }
          ]
        })

      assert {:ok, [message]} = WhatsApp.parse_webhook(audio_message)

      assert message.content == ""

      assert message.attachments == [
               %{
                 kind: :audio,
                 url: nil,
                 mime_type: "audio/ogg",
                 file_id: "audio-media-id",
                 size_bytes: nil
               }
             ]
    end

    test "drops senders outside the allowlist" do
      Application.put_env(:fermix_channels, :whatsapp,
        enabled: true,
        allowed_sender_ids: ["19999999999"]
      )

      assert {:ok, []} = WhatsApp.parse_webhook(payload("blocked"))
    end

    test "does not fall back to allowed_user_ids when sender allowlist is unset" do
      Application.put_env(:fermix_channels, :whatsapp,
        enabled: true,
        allowed_user_ids: ["19999999999"]
      )

      assert {:ok, [message]} = WhatsApp.parse_webhook(payload("hello from whatsapp"))
      assert message.chat_id == "15551234567"
    end
  end

  describe "dispatch and reply" do
    test "routes inbound text through dispatcher and replies with Cloud API text send" do
      test_pid = self()

      Req.Test.stub(:whatsapp, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:whatsapp_request, conn.request_path, Jason.decode!(body), conn.req_headers}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"messages" => [%{"id" => "reply-id"}]}))
      end)

      assert {:ok, messages} = WhatsApp.parse_webhook(payload("hello"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: WhatsApp,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}

      assert agent_message.content == "hello"
      assert :ok = agent_message.reply_fn.("reply from fermix")

      assert_receive {:whatsapp_request, "/v19.0/123456789/messages", body, headers}
      assert body["messaging_product"] == "whatsapp"
      assert body["to"] == "15551234567"
      assert body["type"] == "text"
      assert body["text"]["body"] == "reply from fermix"
      assert {"authorization", "Bearer whatsapp-access-token"} in headers
    end

    test "routes inbound text through MainAgent and sends the agent reply" do
      test_pid = self()
      agent_name = :"whatsapp_main_agent_#{System.unique_integer([:positive])}"
      store_name = :"whatsapp_conversation_store_#{System.unique_integer([:positive])}"

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

      Req.Test.stub(:whatsapp, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:whatsapp_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"messages" => [%{"id" => "reply-id"}]}))
      end)

      assert {:ok, messages} = WhatsApp.parse_webhook(payload("hello main agent"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: WhatsApp,
                 agent: MainAgent,
                 agent_server: agent
               )

      assert_receive {:whatsapp_request, "/v19.0/123456789/messages", body}, 5_000
      assert body["to"] == "15551234567"
      assert body["text"]["body"] == "reply from main agent"
    end
  end

  describe "verify_webhook/1" do
    test "accepts valid HMAC signatures" do
      body = Jason.encode!(payload("signed"))
      digest = :crypto.mac(:hmac, :sha256, "app-secret", body)
      signature = "sha256=" <> Base.encode16(digest, case: :lower)

      conn =
        Plug.Test.conn(:post, "/webhook/whatsapp", body)
        |> Plug.Conn.put_req_header("x-hub-signature-256", signature)
        |> Plug.Conn.assign(:raw_body, body)

      assert :ok = WhatsApp.verify_webhook(conn)
    end

    test "rejects missing send configuration" do
      Application.put_env(:fermix_channels, :whatsapp, enabled: true)

      assert {:error, :not_configured} = WhatsApp.send_message("15551234567", "hello")
    end
  end

  describe "verify_challenge/1" do
    test "returns the challenge for a valid verify token" do
      assert {:ok, "challenge-value"} =
               WhatsApp.verify_challenge(%{
                 "hub.mode" => "subscribe",
                 "hub.verify_token" => "verify-token",
                 "hub.challenge" => "challenge-value"
               })
    end

    test "rejects wrong verify tokens" do
      assert {:error, :invalid_token} =
               WhatsApp.verify_challenge(%{
                 "hub.mode" => "subscribe",
                 "hub.verify_token" => "wrong",
                 "hub.challenge" => "challenge-value"
               })
    end
  end

  defp payload(text, overrides \\ %{}) do
    value =
      Map.merge(
        %{
          "messaging_product" => "whatsapp",
          "metadata" => %{"phone_number_id" => "123456789"},
          "contacts" => [
            %{"wa_id" => "15551234567", "profile" => %{"name" => "Alice"}}
          ],
          "messages" => [
            %{
              "from" => "15551234567",
              "id" => "wamid.123",
              "timestamp" => "1714000000",
              "type" => "text",
              "text" => %{"body" => text}
            }
          ]
        },
        overrides
      )

    %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{"id" => "waba-id", "changes" => [%{"field" => "messages", "value" => value}]}
      ]
    }
  end
end
