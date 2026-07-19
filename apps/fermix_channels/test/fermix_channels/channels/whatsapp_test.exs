defmodule FermixChannels.Channels.WhatsAppTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Dispatcher
  alias FermixChannels.Gateway.Message
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

  defmodule FakeTranscriptionBackend do
    def name, do: :fake_transcription

    def transcribe(path, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:whatsapp_transcription, path, File.read!(path), Keyword.fetch!(opts, :metadata)}
      )

      {:ok, "voice note from whatsapp"}
    end
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
      # F-02: empty allowlist now denies; tests need an explicit allow.
      allowed_sender_ids: ["15551234567"],
      req_options: [plug: {Req.Test, :whatsapp}]
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :whatsapp) end)

    :ok
  end

  describe "reactions" do
    defp whatsapp_react_message do
      Message.new!(%{
        id: "wamid.123",
        content: "thanks",
        sender: "15551234567",
        channel: "whatsapp",
        chat_id: "15551234567",
        reply_target: "15551234567"
      })
    end

    test "reaction_capability is any_emoji" do
      assert WhatsApp.reaction_capability() == :any_emoji
    end

    test "react posts a type:reaction message targeting the inbound wamid" do
      test_pid = self()

      Req.Test.stub(:whatsapp, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:whatsapp_request, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.reply"}]})
      end)

      assert :ok = WhatsApp.react(whatsapp_react_message(), "👍")

      assert_receive {:whatsapp_request, path, body}
      assert path =~ "/messages"
      assert body["type"] == "reaction"
      assert body["to"] == "15551234567"
      assert body["reaction"] == %{"message_id" => "wamid.123", "emoji" => "👍"}
    end

    test "surfaces an API error (e.g. outside the 24h window)" do
      Req.Test.stub(:whatsapp, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"message" => "re-engagement"}}))
      end)

      assert {:error, _reason} = WhatsApp.react(whatsapp_react_message(), "👍")
    end
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
      assert message.metadata.user_id == "15551234567"
      assert message.metadata.chat_type == "private"
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
      assert :ok = agent_message.reply_fn.({:text, "reply from fermix"})

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

      queue =
        start_supervised!(
          {FermixChannels.Gateway.Queue,
           [name: :"queue_#{System.unique_integer([:positive])}", main_agent: agent]}
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
                 agent: FermixChannels.Gateway.Queue,
                 agent_server: queue
               )

      assert_receive {:whatsapp_request, "/v19.0/123456789/messages", body}, 5_000
      assert body["to"] == "15551234567"
      assert body["text"]["body"] == "reply from main agent"
    end

    test "routes inbound audio through transcription and MainAgent and sends the agent reply" do
      test_pid = self()
      agent_name = :"whatsapp_voice_agent_#{System.unique_integer([:positive])}"
      store_name = :"whatsapp_voice_store_#{System.unique_integer([:positive])}"

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

      queue =
        start_supervised!(
          {FermixChannels.Gateway.Queue,
           [name: :"queue_#{System.unique_integer([:positive])}", main_agent: agent]}
        )

      Req.Test.stub(:whatsapp, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v19.0/audio-media-id"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"url" => "https://lookaside.fbsbx.com/media/audio-media-id"})
            )

          {"GET", "/media/audio-media-id"} ->
            Plug.Conn.send_resp(conn, 200, "voice-bytes")

          {"POST", "/v19.0/123456789/messages"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:whatsapp_request, conn.request_path, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"messages" => [%{"id" => "reply-id"}]}))
        end
      end)

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
                "mime_type" => "audio/ogg"
              }
            }
          ]
        })

      assert {:ok, messages} = WhatsApp.parse_webhook(audio_message)

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: WhatsApp,
                 agent: FermixChannels.Gateway.Queue,
                 agent_server: queue,
                 transcription: [backend: FakeTranscriptionBackend, test_pid: self()]
               )

      assert_receive {:whatsapp_transcription, path, "voice-bytes", metadata}
      assert metadata[:attachment][:file_id] == "audio-media-id"
      refute File.exists?(path)

      assert_receive {:whatsapp_request, "/v19.0/123456789/messages", body}, 5_000
      assert body["to"] == "15551234567"
      assert body["text"]["body"] == "reply from main agent"
    end
  end

  describe "send_media/3" do
    test "maps voice attachments to WhatsApp audio messages with required MIME" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("whatsapp-send-media")
      test_pid = self()

      Req.Test.stub(:whatsapp, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case conn.request_path do
          "/v19.0/123456789/media" ->
            send(test_pid, {:whatsapp_media_upload, body, conn.req_headers})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "media-id-1"}))

          "/v19.0/123456789/messages" ->
            send(test_pid, {:whatsapp_media_message, Jason.decode!(body), conn.req_headers})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"messages" => [%{"id" => "reply-id"}]}))
        end
      end)

      try do
        path = Path.join(tmp_dir, "voice.ogg")
        File.write!(path, "voice")

        assert :ok =
                 WhatsApp.send_media("15551234567", %{
                   kind: :voice,
                   path: path,
                   filename: "voice.ogg",
                   mime_type: "audio/ogg; codecs=opus"
                 })

        assert_receive {:whatsapp_media_upload, upload_body, upload_headers}
        assert upload_body =~ ~s(name="messaging_product")
        assert upload_body =~ "voice.ogg"
        assert upload_body =~ "audio/ogg; codecs=opus"
        assert {"authorization", "Bearer whatsapp-access-token"} in upload_headers

        assert_receive {:whatsapp_media_message, message_body, message_headers}
        assert message_body["messaging_product"] == "whatsapp"
        assert message_body["to"] == "15551234567"
        assert message_body["type"] == "audio"
        assert message_body["audio"] == %{"id" => "media-id-1"}
        assert {"authorization", "Bearer whatsapp-access-token"} in message_headers
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "rejects voice attachments without the WhatsApp opus MIME" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("whatsapp-send-media-mime")

      try do
        path = Path.join(tmp_dir, "voice.ogg")
        File.write!(path, "voice")

        assert {:error, "WhatsApp voice attachments must be audio/ogg; codecs=opus"} =
                 WhatsApp.send_media("15551234567", %{
                   kind: :voice,
                   path: path,
                   filename: "voice.ogg",
                   mime_type: "audio/ogg"
                 })
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "rejects media over the WhatsApp outbound cap before upload" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("whatsapp-send-media-cap")

      try do
        path = Path.join(tmp_dir, "oversize.jpg")
        write_sparse_file!(path, 5 * 1_024 * 1_024 + 1)

        assert {:error, {:byte_cap_exceeded, actual, allowed}} =
                 WhatsApp.send_media("15551234567", %{
                   kind: :image,
                   path: path,
                   filename: "oversize.jpg",
                   mime_type: "image/jpeg"
                 })

        assert actual == 5 * 1_024 * 1_024 + 1
        assert allowed == 5 * 1_024 * 1_024
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "download_attachment/2" do
    test "downloads WhatsApp media to a temp file for transcription" do
      Req.Test.stub(:whatsapp, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v19.0/audio-media-id"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"url" => "https://lookaside.fbsbx.com/media/audio-media-id"})
            )

          {"GET", "/media/audio-media-id"} ->
            Plug.Conn.send_resp(conn, 200, "voice-bytes")
        end
      end)

      message = payload("", %{})
      {:ok, [normalized_message]} = WhatsApp.parse_webhook(message)

      audio_attachment = %{
        "kind" => "audio",
        "file_id" => "audio-media-id",
        "mime_type" => "audio/ogg",
        "url" => nil,
        "size_bytes" => nil
      }

      assert {:ok, path} = WhatsApp.download_attachment(normalized_message, audio_attachment)
      assert File.read!(path) == "voice-bytes"
      assert String.ends_with?(path, ".ogg")

      FermixTestSupport.SafeRm.rm!(path)
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

    test "rejects text over the WhatsApp Cloud API body cap before send" do
      assert {:error, {:text_cap_exceeded, 4_097, 4_096}} =
               WhatsApp.send_message("15551234567", String.duplicate("a", 4_097))
    end

    test "returns structured rate limit errors when Meta provides Retry-After" do
      Req.Test.stub(:whatsapp, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "4")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => %{"message" => "rate limited"}}))
      end)

      assert {:error, {:rate_limited, 4_000}} =
               WhatsApp.send_message("15551234567", "hello")
    end
  end

  describe "health_check/1" do
    test "returns ok when the phone number id matches config" do
      Req.Test.stub(:whatsapp, fn conn ->
        assert conn.request_path == "/v19.0/123456789"

        Req.Test.json(conn, %{
          "id" => "123456789",
          "verified_name" => "Fermix"
        })
      end)

      assert {:ok, %{detail: "WhatsApp Fermix authenticated", latency_ms: ms}} =
               WhatsApp.health_check()

      assert is_integer(ms)
    end

    test "classifies phone number id mismatches as misconfigured" do
      Req.Test.stub(:whatsapp, fn conn ->
        Req.Test.json(conn, %{"id" => "000000000"})
      end)

      assert {:error,
              {:misconfigured, "whatsapp phone_number_id 123456789 does not match 000000000"}} =
               WhatsApp.health_check()
    end

    test "classifies auth failures" do
      Req.Test.stub(:whatsapp, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "bad token"}}))
      end)

      assert {:error, {:auth_failed, "WhatsApp API HTTP 401: bad token"}} =
               WhatsApp.health_check()
    end

    test "classifies server errors" do
      Req.Test.stub(:whatsapp, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "server error"}}))
      end)

      assert {:error, {:server_error, 500, %{"error" => %{"message" => "server error"}}}} =
               WhatsApp.health_check()
    end

    test "classifies network failures" do
      Req.Test.stub(:whatsapp, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      assert {:error, {:network, %Req.TransportError{reason: :nxdomain}}} =
               WhatsApp.health_check()
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
