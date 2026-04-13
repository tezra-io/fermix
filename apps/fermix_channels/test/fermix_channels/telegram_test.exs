defmodule FermixChannels.TelegramTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Message
  alias FermixChannels.Telegram

  # -- fixtures --

  defp message_payload(overrides \\ %{}) do
    base = %{
      "message" => %{
        "message_id" => 42,
        "text" => "hello bot",
        "chat" => %{"id" => 123_456},
        "from" => %{"id" => 111, "username" => "alice", "first_name" => "Alice"}
      }
    }

    Map.merge(base, overrides)
  end

  defp stub_telegram(test_pid, status, body) do
    Req.Test.stub(:telegram, fn conn ->
      {:ok, req_body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(req_body)
      send(test_pid, {:telegram_request, conn.request_path, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp send_msg(chat_id, text, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:req_options, plug: {Req.Test, :telegram})

    Telegram.send_message(chat_id, text, opts)
  end

  defp typing(chat_id, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:req_options, plug: {Req.Test, :telegram})

    Telegram.start_typing(chat_id, opts)
  end

  setup do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test-bot-token",
      webhook_secret: "test-secret",
      req_options: [plug: {Req.Test, :telegram}]
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)
  end

  # -- parse_webhook/1 --

  describe "parse_webhook/1" do
    test "parses text message into standard message" do
      payload = message_payload()

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.id == "42"
      assert msg.content == "hello bot"
      assert msg.sender == "alice"
      assert msg.channel == "telegram"
      assert msg.chat_id == "123456"
      assert msg.reply_target == "123456"
      assert msg.thread_ts == nil
    end

    test "preserves Telegram message_thread_id as an integer thread id" do
      payload = put_in(message_payload(), ["message", "message_thread_id"], 456)

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.thread_ts == 456
      assert msg.thread_scope == :thread
    end

    test "parses edited_message" do
      payload = %{
        "edited_message" => %{
          "message_id" => 99,
          "text" => "edited text",
          "chat" => %{"id" => 789},
          "from" => %{"username" => "bob", "first_name" => "Bob"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.id == "99"
      assert msg.content == "edited text"
      assert msg.sender == "bob"
    end

    test "falls back to first_name when no username" do
      payload = %{
        "message" => %{
          "message_id" => 1,
          "text" => "hi",
          "chat" => %{"id" => 1},
          "from" => %{"first_name" => "Charlie"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.sender == "Charlie"
    end

    test "falls back to unknown when no from info" do
      payload = %{
        "message" => %{
          "message_id" => 1,
          "text" => "hi",
          "chat" => %{"id" => 1},
          "from" => %{}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.sender == "unknown"
    end

    test "uses caption when no text (photo with caption)" do
      payload = %{
        "message" => %{
          "message_id" => 1,
          "caption" => "look at this",
          "chat" => %{"id" => 1},
          "from" => %{"username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.content == "look at this"
    end

    test "returns empty content when no text or caption" do
      payload = %{
        "message" => %{
          "message_id" => 1,
          "chat" => %{"id" => 1},
          "from" => %{"username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.content == ""
    end

    test "returns {:ok, []} for unhandled update types" do
      assert {:ok, []} = Telegram.parse_webhook(%{"callback_query" => %{}})
      assert {:ok, []} = Telegram.parse_webhook(%{"inline_query" => %{}})
    end
  end

  # -- parse_update/1 --

  describe "parse_update/1" do
    test "parses a message update into standard message" do
      update = %{
        "message" => %{
          "message_id" => 42,
          "text" => "hello",
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.content == "hello"
      assert msg.sender == "alice"
      assert msg.chat_id == "123"
    end

    test "returns {:ok, []} for unauthorized user" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        webhook_secret: "test-secret",
        allowed_user_ids: [999]
      )

      update = %{
        "message" => %{
          "message_id" => 1,
          "text" => "hi",
          "chat" => %{"id" => 1},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, []} = Telegram.parse_update(update)
    end

    test "returns {:ok, []} for non-message updates" do
      assert {:ok, []} = Telegram.parse_update(%{"callback_query" => %{}})
    end
  end

  # -- allowed_user_ids --

  describe "allowed_user_ids filtering" do
    test "allows message when user ID is in allow-list" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        webhook_secret: "test-secret",
        allowed_user_ids: [111]
      )

      payload = message_payload()
      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.sender == "alice"
    end

    test "silently drops message when user ID is not in allow-list" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        webhook_secret: "test-secret",
        allowed_user_ids: [999]
      )

      payload = message_payload()
      assert {:ok, []} = Telegram.parse_webhook(payload)
    end

    test "allows all messages when allowed_user_ids is empty list" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        webhook_secret: "test-secret",
        allowed_user_ids: []
      )

      payload = message_payload()
      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.sender == "alice"
    end

    test "allows all messages when allowed_user_ids is not configured" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        webhook_secret: "test-secret"
      )

      payload = message_payload()
      assert {:ok, [msg]} = Telegram.parse_webhook(payload)
      assert msg.sender == "alice"
    end
  end

  # -- send_message/3 --

  describe "send_message/3" do
    test "posts to Telegram sendMessage endpoint" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = send_msg("123", "hello")

      assert_received {:telegram_request, path, body}
      assert path == "/bottest-bot-token/sendMessage"
      assert body["chat_id"] == "123"
      assert body["text"] == "hello"
    end

    test "sends without parse_mode by default" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "hello")

      assert_received {:telegram_request, _path, body}
      refute Map.has_key?(body, "parse_mode")
    end

    test "respects parse_mode option" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "hello", parse_mode: "HTML")

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"
    end

    test "includes reply_to_message_id when reply_to given" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "reply", reply_to: "42")

      assert_received {:telegram_request, _path, body}
      assert body["reply_to_message_id"] == "42"
    end

    test "includes integer message_thread_id when given" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "thread reply", message_thread_id: 456)

      assert_received {:telegram_request, _path, body}
      assert body["message_thread_id"] == 456
    end

    test "omits reply_to_message_id when not given" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "no reply")

      assert_received {:telegram_request, _path, body}
      refute Map.has_key?(body, "reply_to_message_id")
    end

    test "splits long messages at 4096 char limit" do
      stub_telegram(self(), 200, %{"ok" => true})

      long_text = String.duplicate("a", 5000)
      :ok = send_msg("123", long_text)

      assert_received {:telegram_request, _path, body1}
      assert_received {:telegram_request, _path, body2}
      assert String.length(body1["text"]) <= 4096
      assert String.length(body2["text"]) <= 4096
      assert body1["text"] <> body2["text"] == long_text
    end

    test "does not split messages under 4096 chars" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = String.duplicate("a", 4096)
      :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, _body}
      refute_received {:telegram_request, _path, _body}
    end

    test "returns error on non-200 status" do
      stub_telegram(self(), 400, %{"ok" => false, "description" => "Bad Request"})

      assert {:error, msg} = send_msg("123", "hello")
      assert msg =~ "400"
    end

    test "returns error on connection failure" do
      Req.Test.stub(:telegram, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} =
               send_msg("123", "hello")
    end
  end

  # -- build_reply/1 --

  describe "build_reply/1" do
    test "requires a normalized message struct" do
      assert_raise FunctionClauseError, fn ->
        apply(Telegram, :build_reply, [%{reply_target: "123", thread_ts: nil}])
      end
    end

    test "returns a reply function for normalized messages" do
      message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "alice",
          channel: "telegram",
          chat_id: "123",
          reply_target: "123",
          thread_ts: 456
        })

      assert is_function(Telegram.build_reply(message), 1)
    end

    test "builds threaded replies with integer message_thread_id" do
      stub_telegram(self(), 200, %{"ok" => true})

      message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "alice",
          channel: "telegram",
          chat_id: "123",
          reply_target: "123",
          thread_ts: 456
        })

      reply = Telegram.build_reply(message)

      assert :ok = reply.("thread reply")
      assert_received {:telegram_request, _path, body}
      assert body["message_thread_id"] == 456
    end
  end

  # -- verify_webhook/1 --

  describe "verify_webhook/1" do
    test "returns :ok when secret token header matches" do
      conn = Plug.Test.conn(:post, "/webhook/telegram")
      conn = Plug.Conn.put_req_header(conn, "x-telegram-bot-api-secret-token", "test-secret")

      assert :ok = Telegram.verify_webhook(conn)
    end

    test "returns error when header does not match" do
      conn = Plug.Test.conn(:post, "/webhook/telegram")
      conn = Plug.Conn.put_req_header(conn, "x-telegram-bot-api-secret-token", "wrong-secret")

      assert {:error, :invalid_token} = Telegram.verify_webhook(conn)
    end

    test "returns error when header is missing" do
      conn = Plug.Test.conn(:post, "/webhook/telegram")

      assert {:error, :missing_token} = Telegram.verify_webhook(conn)
    end
  end

  # -- start_typing/1 --

  describe "start_typing/2" do
    test "posts sendChatAction with typing" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = typing("123")

      assert_received {:telegram_request, path, body}
      assert path == "/bottest-bot-token/sendChatAction"
      assert body["chat_id"] == "123"
      assert body["action"] == "typing"
    end
  end

  # -- telemetry --

  describe "telemetry" do
    test "emits [:fermix, :channel, :message] on inbound parse" do
      _ref =
        :telemetry.attach(
          "test-channel-inbound",
          [:fermix, :channel, :message],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      payload = message_payload()
      {:ok, [_msg]} = Telegram.parse_webhook(payload)

      assert_received {:telemetry, [:fermix, :channel, :message], measurements, metadata}
      assert metadata.channel == :telegram
      assert metadata.direction == :inbound
      assert is_integer(measurements.count)

      :telemetry.detach("test-channel-inbound")
    after
      :telemetry.detach("test-channel-inbound")
    end

    test "emits [:fermix, :channel, :message] on outbound send" do
      _ref =
        :telemetry.attach(
          "test-channel-outbound",
          [:fermix, :channel, :message],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      stub_telegram(self(), 200, %{"ok" => true})
      :ok = send_msg("123", "hello")

      assert_received {:telemetry, [:fermix, :channel, :message], measurements, metadata}
      assert metadata.channel == :telegram
      assert metadata.direction == :outbound
      assert is_integer(measurements.count)

      :telemetry.detach("test-channel-outbound")
    after
      :telemetry.detach("test-channel-outbound")
    end
  end
end
