defmodule FermixChannels.TelegramTest do
  use ExUnit.Case, async: false

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
      # F-02: empty allowlist now denies; tests need an explicit allow.
      allowed_user_ids: ["111"],
      req_options: [plug: {Req.Test, :telegram}]
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)
  end

  # -- parse_webhook/1 --

  describe "parse_webhook/1" do
    test "returns unsupported_transport" do
      assert {:error, :unsupported_transport} = Telegram.parse_webhook(%{})
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
      assert msg.metadata.user_id == "111"
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
        allowed_user_ids: [111]
      )

      payload = message_payload()
      assert {:ok, [msg]} = Telegram.parse_update(payload)
      assert msg.sender == "alice"
    end

    test "silently drops message when user ID is not in allow-list" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        allowed_user_ids: [999]
      )

      payload = message_payload()
      assert {:ok, []} = Telegram.parse_update(payload)
    end

    test "denies all messages when allowed_user_ids is an empty list (F-02)" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        allowed_user_ids: []
      )

      payload = message_payload()
      assert {:ok, []} = Telegram.parse_update(payload)
    end

    test "denies all messages when neither allowed_user_ids nor owner_user_id are set (F-02)" do
      Application.put_env(:fermix_channels, :telegram, bot_token: "test-bot-token")

      payload = message_payload()
      assert {:ok, []} = Telegram.parse_update(payload)
    end

    test "defaults ingress allowlist to owner_user_id when allowed_user_ids is not configured" do
      Application.put_env(:fermix_channels, :telegram,
        bot_token: "test-bot-token",
        owner_user_id: "111"
      )

      assert {:ok, [msg]} = Telegram.parse_update(message_payload())
      assert msg.sender == "alice"

      payload =
        message_payload(%{
          "message" => %{
            "message_id" => 43,
            "text" => "hello bot",
            "chat" => %{"id" => 123_456},
            "from" => %{"id" => 222, "username" => "bob", "first_name" => "Bob"}
          }
        })

      assert {:ok, []} = Telegram.parse_update(payload)
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

    test "renders common markdown as Telegram HTML by default" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = """
      **Title**
      - *first* item
      - _second_ with `code`
      1. link to [Fermix](https://example.com?q=1&x=2)
      ~~done~~
      ```elixir
      IO.puts("<ok>")
      ```
      """

      assert :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"

      assert body["text"] ==
               """
               <b>Title</b>
               • <i>first</i> item
               • <i>second</i> with <code>code</code>
               1. link to <a href="https://example.com?q=1&amp;x=2">Fermix</a>
               <s>done</s>
               <pre><code class="language-elixir">IO.puts(&quot;&lt;ok&gt;&quot;)</code></pre>
               """
    end

    test "can send plain text without Telegram parse mode" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "hello **world** <3", format: :plain)

      assert_received {:telegram_request, _path, body}
      refute Map.has_key?(body, "parse_mode")
      assert body["text"] == "hello **world** <3"
    end

    test "respects parse_mode option" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "hello **world**", parse_mode: "MarkdownV2")

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "MarkdownV2"
      assert body["text"] == "hello **world**"
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
      refute_received {:telegram_request, _path, _body}
    end

    test "splits using Telegram post-render entity length" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = String.duplicate("**a**", 4097)
      :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body1}
      assert_received {:telegram_request, _path, body2}
      assert body1["parse_mode"] == "HTML"
      assert body2["parse_mode"] == "HTML"
      assert body1["text"] == String.duplicate("<b>a</b>", 4096)
      assert body2["text"] == "<b>a</b>"
      refute_received {:telegram_request, _path, _body}
    end

    test "prefers semantic split boundaries for rendered Telegram HTML" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = String.duplicate("a", 4_090) <> " [Fermix](https://example.com) tail"
      :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body1}
      assert_received {:telegram_request, _path, body2}
      assert body1["text"] == String.duplicate("a", 4_090) <> " "
      assert body2["text"] == ~s(<a href="https://example.com">Fermix</a> tail)
      refute_received {:telegram_request, _path, _body}
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

    test "returns structured rate limit errors when Telegram provides retry_after" do
      stub_telegram(self(), 429, %{
        "ok" => false,
        "parameters" => %{"retry_after" => 3}
      })

      assert {:error, {:rate_limited, 3_000}} = send_msg("123", "hello")
    end

    test "returns error on connection failure" do
      Req.Test.stub(:telegram, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} =
               send_msg("123", "hello")
    end
  end

  # -- build_text_reply/1 --

  describe "build_text_reply/1" do
    test "requires a normalized message struct" do
      assert_raise FunctionClauseError, fn ->
        apply(Telegram, :build_text_reply, [%{reply_target: "123", thread_ts: nil}])
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

      assert is_function(Telegram.build_text_reply(message), 1)
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

      reply = Telegram.build_text_reply(message)

      assert :ok = reply.("thread reply")
      assert_received {:telegram_request, _path, body}
      assert body["message_thread_id"] == 456
    end

    test "reply function renders markdown bold for Telegram" do
      stub_telegram(self(), 200, %{"ok" => true})

      message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "alice",
          channel: "telegram",
          chat_id: "123",
          reply_target: "123"
        })

      reply = Telegram.build_text_reply(message)

      assert :ok = reply.("answer with **bold**")
      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"
      assert body["text"] == "answer with <b>bold</b>"
    end
  end

  # -- verify_webhook/1 --

  describe "verify_webhook/1" do
    test "returns unsupported_transport" do
      conn = Plug.Test.conn(:post, "/webhook/telegram")
      assert {:error, :unsupported_transport} = Telegram.verify_webhook(conn)
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

  describe "send_media/3" do
    test "routes each media kind to the Telegram method and form field" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("telegram-send-media")

      cases = [
        {:image, "sendPhoto", "photo"},
        {:voice, "sendVoice", "voice"},
        {:audio, "sendAudio", "audio"},
        {:video, "sendVideo", "video"},
        {:document, "sendDocument", "document"}
      ]

      test_pid = self()

      Req.Test.stub(:telegram, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_media_request, conn.request_path, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      try do
        Enum.each(cases, fn {kind, method, field} ->
          path = Path.join(tmp_dir, "#{kind}.bin")
          File.write!(path, "media-#{kind}")

          assert :ok =
                   Telegram.send_media(
                     "123",
                     %{
                       kind: kind,
                       path: path,
                       caption: "caption #{kind}",
                       filename: "#{kind}.dat",
                       mime_type: "application/octet-stream"
                     }
                   )

          assert_receive {:telegram_media_request, request_path, body}
          assert request_path == "/bottest-bot-token/#{method}"
          assert body =~ ~s(name="#{field}")
          assert body =~ "#{kind}.dat"
          assert body =~ "caption #{kind}"
        end)
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "rejects media over the Telegram cap before upload" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("telegram-send-media-cap")

      try do
        path = Path.join(tmp_dir, "voice.ogg")
        File.write!(path, :binary.copy("x", 1 * 1_024 * 1_024 + 1))

        assert {:error, {:byte_cap_exceeded, actual, allowed}} =
                 Telegram.send_media("123", %{
                   kind: :voice,
                   path: path,
                   filename: "voice.ogg",
                   mime_type: "audio/ogg"
                 })

        assert actual == 1 * 1_024 * 1_024 + 1
        assert allowed == 1 * 1_024 * 1_024
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  # -- telemetry --

  describe "telemetry" do
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
