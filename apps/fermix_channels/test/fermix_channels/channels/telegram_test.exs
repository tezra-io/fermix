defmodule FermixChannels.Channels.TelegramTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway.Message

  # -- fixtures --

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

    test "returns {:ok, []} for non-message updates" do
      assert {:ok, []} = Telegram.parse_update(%{"callback_query" => %{}})
    end

    test "parses a photo message into an image attachment ref (largest variant, file_id only)" do
      update = %{
        "message" => %{
          "message_id" => 7,
          "caption" => "look at this",
          "photo" => [
            %{"file_id" => "small", "width" => 90, "height" => 60, "file_size" => 1_000},
            %{"file_id" => "big", "width" => 1280, "height" => 720, "file_size" => 50_000}
          ],
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.content == "look at this"

      assert [
               %{
                 kind: :image,
                 file_id: "big",
                 mime_type: "image/jpeg",
                 size_bytes: 50_000,
                 url: nil
               }
             ] =
               msg.attachments
    end

    test "carries media_group_id into metadata for album coalescing" do
      update = %{
        "message" => %{
          "message_id" => 8,
          "media_group_id" => "alb-123",
          "photo" => [%{"file_id" => "f1", "width" => 100, "height" => 100, "file_size" => 2_000}],
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.metadata.media_group_id == "alb-123"
    end

    test "omits media_group_id for a single (non-album) message" do
      update = %{
        "message" => %{
          "message_id" => 9,
          "text" => "hi",
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      refute Map.has_key?(msg.metadata, :media_group_id)
    end
  end

  # -- download_attachment/2 --

  describe "download_attachment/2" do
    test "refuses an over-cap declared size before any network call (fail loud)" do
      attachment = %{
        kind: :image,
        file_id: "x",
        mime_type: "image/jpeg",
        size_bytes: 21 * 1_024 * 1_024
      }

      assert {:error, {:byte_cap_exceeded, _actual, _allowed}} =
               Telegram.download_attachment(%{}, attachment)
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

    test "renders markdown headings as Telegram HTML by default" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = """
      ## **Run Summary**
      **Status:** failed
      ### Details
      - checked `mix test`
      """

      assert :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"

      assert body["text"] ==
               """
               <b>Run Summary</b>
               <b>Status:</b> failed
               <b>Details</b>
               • checked <code>mix test</code>
               """

      refute body["text"] =~ "##"
      refute body["text"] =~ "###"
      refute body["text"] =~ "**"
    end

    test "renders deeper markdown headings without nested bold tags" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = """
      #### Run **Summary** <tag>
      ###### Final Check
      """

      assert :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"

      assert body["text"] ==
               """
               <b>Run Summary &lt;tag&gt;</b>
               <b>Final Check</b>
               """

      refute body["text"] =~ "<b><b>"
      refute body["text"] =~ "</b></b>"
      refute body["text"] =~ "####"
      refute body["text"] =~ "**"
    end

    test "preserves unpaired ** markers in heading text" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = """
      ## Use ** as wildcard
      ### **mismatched bold
      """

      assert :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"

      assert body["text"] ==
               """
               <b>Use ** as wildcard</b>
               <b>**mismatched bold</b>
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

  describe "health_check/1" do
    test "returns ok when getMe authenticates the bot" do
      stub_telegram(self(), 200, %{"ok" => true, "result" => %{"username" => "fermix_bot"}})

      assert {:ok, %{detail: "bot @fermix_bot authenticated", latency_ms: ms}} =
               Telegram.health_check()

      assert is_integer(ms)
      assert_received {:telegram_request, "/bottest-bot-token/getMe", %{}}
    end

    test "classifies auth failures" do
      stub_telegram(self(), 401, %{"description" => "Unauthorized"})

      assert {:error, {:auth_failed, "Telegram API HTTP 401: Unauthorized"}} =
               Telegram.health_check()
    end

    test "explains Telegram 404 as an invalid bot token" do
      stub_telegram(self(), 404, %{"description" => "Not Found"})

      assert {:error,
              {:auth_failed,
               "invalid bot token (Telegram API HTTP 404: Not Found); paste the BotFather token without a bot prefix"}} =
               Telegram.health_check()
    end

    test "classifies server errors" do
      stub_telegram(self(), 500, %{"description" => "upstream failed"})

      assert {:error, {:server_error, 500, %{"description" => "upstream failed"}}} =
               Telegram.health_check()
    end

    test "classifies network failures" do
      Req.Test.stub(:telegram, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:network, %Req.TransportError{reason: :econnrefused}}} =
               Telegram.health_check()
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

  # -- Draft streaming contract (docs/design/CHANNEL_STREAMING.md §6) --

  defp draft_message(thread_ts \\ nil) do
    Message.new!(%{
      id: "1",
      content: "hi",
      sender: "alice",
      channel: "telegram",
      chat_id: "123",
      reply_target: "123",
      thread_ts: thread_ts,
      metadata: %{user_id: "111"}
    })
  end

  describe "stream_capability/0" do
    test "declares draft_edit" do
      assert Telegram.stream_capability() == :draft_edit
    end
  end

  describe "open_draft/2" do
    test "sends the rendered draft and returns the message_id" do
      stub_telegram(self(), 200, %{"ok" => true, "result" => %{"message_id" => 777}})

      assert {:ok, 777} = Telegram.open_draft(draft_message(), "**bold** start")

      assert_receive {:telegram_request, path, body}
      assert path =~ "/sendMessage"
      assert body["chat_id"] == "123"
      assert body["parse_mode"] == "HTML"
      assert body["text"] == "<b>bold</b> start"
    end

    test "carries the thread id" do
      stub_telegram(self(), 200, %{"ok" => true, "result" => %{"message_id" => 7}})

      assert {:ok, 7} = Telegram.open_draft(draft_message(99), "draft text here")

      assert_receive {:telegram_request, _path, body}
      assert body["message_thread_id"] == 99
    end

    test "surfaces API errors" do
      stub_telegram(self(), 403, %{"ok" => false, "description" => "Forbidden"})
      assert {:error, _reason} = Telegram.open_draft(draft_message(), "draft text")
    end
  end

  describe "edit_draft/3" do
    test "edits in place with the full re-rendered snapshot" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = Telegram.edit_draft(draft_message(), 777, "now *italic*")

      assert_receive {:telegram_request, path, body}
      assert path =~ "/editMessageText"
      assert body["chat_id"] == "123"
      assert body["message_id"] == 777
      assert body["parse_mode"] == "HTML"
      assert body["text"] == "now <i>italic</i>"
    end

    test "holds an overflowing draft to the largest fitting prefix" do
      stub_telegram(self(), 200, %{"ok" => true})
      long = String.duplicate("word ", 2_000)

      assert :ok = Telegram.edit_draft(draft_message(), 777, long)

      assert_receive {:telegram_request, _path, body}
      assert String.length(body["text"]) <= 4096
    end

    test "does not retry — interim edits are best-effort" do
      stub_telegram(self(), 429, %{"ok" => false, "parameters" => %{"retry_after" => 1}})

      assert {:error, {:rate_limited, 1_000}} = Telegram.edit_draft(draft_message(), 777, "text")

      assert_receive {:telegram_request, _path, _body}
      refute_receive {:telegram_request, _path2, _body2}, 100
    end
  end

  describe "seal_draft/3" do
    test "one in-place edit; no remainder for fitting text" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert {:ok, nil} = Telegram.seal_draft(draft_message(), 777, "final **answer**")

      assert_receive {:telegram_request, path, body}
      assert path =~ "/editMessageText"
      assert body["message_id"] == 777
      assert body["text"] == "final <b>answer</b>"
    end

    test "treats 'message is not modified' as success" do
      stub_telegram(self(), 400, %{
        "ok" => false,
        "description" => "Bad Request: message is not modified: text and reply markup unchanged"
      })

      assert {:ok, nil} = Telegram.seal_draft(draft_message(), 777, "same text")
    end

    test "overflow seals the prefix in place and returns the raw remainder" do
      stub_telegram(self(), 200, %{"ok" => true})
      long = String.duplicate("word ", 2_000)

      assert {:ok, remainder} = Telegram.seal_draft(draft_message(), 777, long)

      assert is_binary(remainder)
      assert String.ends_with?(long, remainder)

      assert_receive {:telegram_request, _path, body}
      assert String.length(body["text"]) <= 4096
    end

    test "retries a rate-limited seal honoring retry_after" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      test_pid = self()

      Req.Test.stub(:telegram, fn conn ->
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_request, conn.request_path, Jason.decode!(req_body)})
        attempt = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)

        {status, body} =
          if attempt == 1 do
            {429, %{"ok" => false, "parameters" => %{"retry_after" => 0}}}
          else
            {200, %{"ok" => true}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end)

      assert {:ok, nil} = Telegram.seal_draft(draft_message(), 777, "final")

      assert_receive {:telegram_request, _p1, _b1}
      assert_receive {:telegram_request, _p2, _b2}
    end

    test "persistent failure exhausts the bounded retries" do
      stub_telegram(self(), 500, %{"ok" => false})

      assert {:error, _reason} = Telegram.seal_draft(draft_message(), 777, "final")

      assert_receive {:telegram_request, _p1, _b1}
      assert_receive {:telegram_request, _p2, _b2}
      assert_receive {:telegram_request, _p3, _b3}
      refute_receive {:telegram_request, _p4, _b4}, 100
    end
  end

  describe "discard_draft/2" do
    test "deletes the draft message" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = Telegram.discard_draft(draft_message(), 777)

      assert_receive {:telegram_request, path, body}
      assert path =~ "/deleteMessage"
      assert body["chat_id"] == "123"
      assert body["message_id"] == 777
    end

    test "surfaces delete failures" do
      stub_telegram(self(), 400, %{"ok" => false, "description" => "message to delete not found"})
      assert {:error, _reason} = Telegram.discard_draft(draft_message(), 777)
    end
  end

  describe "reactions" do
    defp react_message(message_id \\ "42") do
      Message.new!(%{
        id: message_id,
        content: "thanks",
        sender: "user",
        channel: "telegram",
        chat_id: "123",
        reply_target: "123"
      })
    end

    test "reaction_capability advertises a restricted allowlist" do
      assert {:restricted, set} = Telegram.reaction_capability()
      assert is_list(set)
      assert "👍" in set
    end

    test "react posts setMessageReaction with an integer message_id" do
      stub_telegram(self(), 200, %{"ok" => true, "result" => true})

      assert :ok =
               Telegram.react(react_message(), "🙏", req_options: [plug: {Req.Test, :telegram}])

      assert_receive {:telegram_request, path, body}
      assert path =~ "/setMessageReaction"
      assert body["chat_id"] == "123"
      assert body["message_id"] == 42
      assert body["reaction"] == [%{"type" => "emoji", "emoji" => "🙏"}]
    end

    test "an off-allowlist emoji is refused loudly without hitting the API" do
      stub_telegram(self(), 200, %{"ok" => true, "result" => true})

      assert {:error, {:unsupported_emoji, "🦄"}} =
               Telegram.react(react_message(), "🦄", req_options: [plug: {Req.Test, :telegram}])

      refute_received {:telegram_request, _path, _body}
    end

    test "a non-numeric message id fails loud before any API call" do
      stub_telegram(self(), 200, %{"ok" => true, "result" => true})

      assert {:error, {:invalid_message_id, "abc"}} =
               Telegram.react(react_message("abc"), "👍",
                 req_options: [plug: {Req.Test, :telegram}]
               )

      refute_received {:telegram_request, _path, _body}
    end

    test "surfaces a Telegram API error" do
      stub_telegram(self(), 400, %{"ok" => false, "description" => "REACTION_INVALID"})

      assert {:error, _reason} =
               Telegram.react(react_message(), "👍", req_options: [plug: {Req.Test, :telegram}])
    end
  end
end
