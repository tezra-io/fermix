defmodule FermixChannels.Channels.TelegramTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway.Message

  # Presentation constants pinned by docs/design/CHANNEL_LONGFORM_PRESENTATION.md
  # §4.2 / §9 decision 4 — the adapter's own attributes are private, so the
  # section-card size and entity budget are restated here on purpose: a change
  # to either is a deliberate change to how every long reply lands.
  @chunk_limit_units 1_400
  @entity_budget 90

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

  # Like `stub_telegram/3` but hands back a distinct `result.message_id` per
  # request, in the given order — what the ephemeral thought path collects so a
  # later sweep can delete each message.
  defp stub_message_ids(test_pid, ids) do
    {:ok, agent} = Agent.start_link(fn -> ids end)

    Req.Test.stub(:telegram, fn conn ->
      {:ok, req_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram_request, conn.request_path, Jason.decode!(req_body)})
      id = Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ok" => true, "result" => %{"message_id" => id}})
      )
    end)
  end

  # Answers 200 for the first `ok_count` requests and `status`/`body` after —
  # the shape a partially delivered reply takes on the wire.
  defp stub_ok_then_error(test_pid, ok_count, status, body) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(:telegram, fn conn ->
      {:ok, req_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram_request, conn.request_path, Jason.decode!(req_body)})
      seen = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

      {resp_status, resp_body} =
        if seen < ok_count, do: {200, %{"ok" => true}}, else: {status, body}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(resp_status, Jason.encode!(resp_body))
    end)
  end

  # Drains every sendMessage body this test's stub recorded, in send order.
  defp sent_bodies(acc \\ []) do
    receive do
      {:telegram_request, _path, body} -> sent_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # UTF-16 units of a rendered chunk's visible text (the budget Telegram
  # enforces). The fixtures are ASCII, so graphemes and UTF-16 units coincide.
  defp rendered_units(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.length()
  end

  defp opening_word(html) do
    String.replace(html, ~r/^(<[^>]+>|•|\s)+/, "")
  end

  # A slice of the live Florida Keys dive reply that motivated the design (the
  # 6,018-char research answer of §1). The old splitter cut the "Conch Republic
  # Divers advertises …" bullet in half; the sections here are sized so the
  # ladder has to cut somewhere inside the list.
  defp dive_reply_fixture do
    """
    ## Best operators

    - [Rainbow Reef Dive Center](https://example.com/rainbow) runs two-tank morning trips to Molasses Reef and the Spiegel Grove, and is the only shop on the upper Keys with a dedicated wreck boat every day of the week.
    - [Horizon Divers](https://example.com/horizon) keeps groups small, which matters on the Duane where the current can pick up quickly in the afternoon and stragglers lose the mooring line.
    - Conch Republic Divers advertises a customer lodging discount at three Tavernier motels, which is worth asking about when you book the boat rather than after.
    - [Quiescence Diving](https://example.com/quiescence) is the quiet pick for night dives on the shallow patch reefs, with a two-boat limit and no walk-up sales.
    - [Ocean Divers](https://example.com/ocean) has the largest fleet in Key Largo and the most forgiving cancellation policy, which is the one thing that matters if the wind swings north the night before your trip.
    - [Sea Dwellers](https://example.com/seadwellers) runs the earliest departure of any shop on the island, and the reef is noticeably emptier at that hour than it is on the mid-morning boats.
    - [Amoray Dive Resort](https://example.com/amoray) is the only operator here that lets you walk from the room to the boat, which is worth a surcharge on a three-day trip with heavy gear.

    ## Where to stay

    Tavernier and Key Largo both put you within twenty minutes of every dock listed above, and the difference is mostly whether you want restaurants inside walking distance or a quieter room.

    - Islander Resort has the easiest parking for a truck with tanks in the bed.
    - Bayside Inn is the cheapest option that still has a rinse tank for gear.

    ## What to book first

    The Spiegel Grove slots fill first on weekends, so book that boat before the room. Everything else in the plan can move around it.
    """
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

    test "returns {:ok, []} for a callback_query without data" do
      assert {:ok, []} = Telegram.parse_update(%{"callback_query" => %{"id" => "x"}})
    end

    test "ignores a callback_query whose payload is not grant-namespaced" do
      update = %{
        "callback_query" => %{
          "id" => "cbq-1",
          "data" => "AB12CD34",
          "from" => %{"id" => 111, "username" => "alice"},
          "message" => %{"message_id" => 55, "chat" => %{"id" => 123, "type" => "private"}}
        }
      }

      assert {:ok, []} = Telegram.parse_update(update)
    end

    test "synthesizes a /confirm message from an inline-button (callback_query) tap" do
      update = %{
        "callback_query" => %{
          "id" => "cbq-1",
          "data" => "grant:AB12CD34",
          "from" => %{"id" => 111, "username" => "alice"},
          "message" => %{
            "message_id" => 55,
            "chat" => %{"id" => 123, "type" => "private"},
            "message_thread_id" => 9
          }
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      # Funnels through the exact typed-/confirm path; origin fields come from the
      # callback (from.id is Telegram-authenticated).
      assert msg.content == "/confirm AB12CD34"
      assert msg.channel == "telegram"
      assert msg.chat_id == "123"
      assert msg.reply_target == "123"
      assert msg.thread_ts == 9
      assert msg.metadata.user_id == "111"
    end

    test "synthesizes a /deny message from a denial tap" do
      update = %{
        "callback_query" => %{
          "id" => "cbq-2",
          "data" => "deny:AB12CD34",
          "from" => %{"id" => 111, "username" => "alice"},
          "message" => %{"message_id" => 55, "chat" => %{"id" => 123, "type" => "private"}}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.content == "/deny AB12CD34"
      assert msg.metadata.user_id == "111"
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

    test "parses a voice note into an audio attachment (audio/ogg, file_id only)" do
      update = %{
        "message" => %{
          "message_id" => 10,
          "voice" => %{
            "file_id" => "voice-1",
            "duration" => 4,
            "mime_type" => "audio/ogg",
            "file_size" => 12_345
          },
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.content == ""

      assert [
               %{
                 kind: :audio,
                 file_id: "voice-1",
                 mime_type: "audio/ogg",
                 size_bytes: 12_345,
                 url: nil
               }
             ] = msg.attachments
    end

    test "keeps a voice-note caption as message content alongside the audio attachment" do
      update = %{
        "message" => %{
          "message_id" => 11,
          "caption" => "summarize this",
          "voice" => %{"file_id" => "voice-2", "file_size" => 500},
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.content == "summarize this"
      assert [%{kind: :audio, file_id: "voice-2", mime_type: "audio/ogg"}] = msg.attachments
    end

    test "parses an audio file using its declared mime type" do
      update = %{
        "message" => %{
          "message_id" => 12,
          "audio" => %{"file_id" => "audio-1", "mime_type" => "audio/mpeg", "file_size" => 999},
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)

      assert [
               %{
                 kind: :audio,
                 file_id: "audio-1",
                 mime_type: "audio/mpeg",
                 size_bytes: 999,
                 url: nil
               }
             ] = msg.attachments
    end

    test "parses a video note into an audio attachment tagged video/mp4" do
      update = %{
        "message" => %{
          "message_id" => 13,
          "video_note" => %{
            "file_id" => "vnote-1",
            "length" => 240,
            "duration" => 8,
            "file_size" => 7_777
          },
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)

      assert [
               %{
                 kind: :audio,
                 file_id: "vnote-1",
                 mime_type: "video/mp4",
                 size_bytes: 7_777,
                 url: nil
               }
             ] = msg.attachments
    end

    test "parses an audio-MIME document into an audio attachment" do
      update = %{
        "message" => %{
          "message_id" => 14,
          "document" => %{
            "file_id" => "doc-1",
            "mime_type" => "audio/x-wav",
            "file_name" => "memo.wav",
            "file_size" => 4_242
          },
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)

      assert [
               %{
                 kind: :audio,
                 file_id: "doc-1",
                 mime_type: "audio/x-wav",
                 size_bytes: 4_242,
                 url: nil
               }
             ] = msg.attachments
    end

    test "leaves a non-audio document unparsed (unchanged behavior)" do
      update = %{
        "message" => %{
          "message_id" => 15,
          "document" => %{
            "file_id" => "doc-2",
            "mime_type" => "application/pdf",
            "file_size" => 4_242
          },
          "chat" => %{"id" => 123},
          "from" => %{"id" => 111, "username" => "alice"}
        }
      }

      assert {:ok, [msg]} = Telegram.parse_update(update)
      assert msg.attachments == []
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

    test "refuses an over-cap voice note by declared size before any network call" do
      attachment = %{
        kind: :audio,
        file_id: "voice-big",
        mime_type: "audio/ogg",
        size_bytes: 21 * 1_024 * 1_024
      }

      assert {:error, {:byte_cap_exceeded, _actual, _allowed}} =
               Telegram.download_attachment(%{}, attachment)
    end

    test "a mime-less audio attachment gets its extension from the getFile file_path (not .bin)" do
      # Telegram makes the Audio `mime_type` optional; a clip without it must not
      # land in a `.bin` temp file (which the hosted backends reject as
      # application/octet-stream). The getFile `file_path` carries the real ext.
      Req.Test.stub(:telegram, fn conn ->
        if String.ends_with?(conn.request_path, "/getFile") do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"ok" => true, "result" => %{"file_path" => "music/track.mp3"}})
          )
        else
          Plug.Conn.send_resp(conn, 200, "AUDIOBYTES")
        end
      end)

      attachment = %{kind: :audio, file_id: "audio-nomime", mime_type: nil}

      assert {:ok, path} = Telegram.download_attachment(%{}, attachment)

      try do
        assert Path.extname(path) == ".mp3"
        assert File.read!(path) == "AUDIOBYTES"
      after
        FermixTestSupport.SafeRm.rm!(path)
      end
    end

    test "halts a lying upstream's oversize body at the inbound cap" do
      # No declared size, so the preflight cannot help: the only guard left is
      # the streaming cap on the body itself.
      Req.Test.stub(:telegram, fn conn ->
        if String.ends_with?(conn.request_path, "/getFile") do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"ok" => true, "result" => %{"file_path" => "photos/big.jpg"}})
          )
        else
          Plug.Conn.send_resp(conn, 200, :binary.copy("x", 20 * 1_024 * 1_024 + 1))
        end
      end)

      attachment = %{kind: :image, file_id: "big", mime_type: "image/jpeg", size_bytes: nil}

      assert {:error, {:byte_cap_exceeded, received, allowed}} =
               Telegram.download_attachment(%{}, attachment)

      assert allowed == 20 * 1_024 * 1_024
      assert received == allowed + 1
    end

    test "refuses a compressed body by name instead of writing bytes nobody can read" do
      Req.Test.stub(:telegram, fn conn ->
        if String.ends_with?(conn.request_path, "/getFile") do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"ok" => true, "result" => %{"file_path" => "photos/p.jpg"}})
          )
        else
          conn
          |> Plug.Conn.put_resp_header("content-encoding", "gzip")
          |> Plug.Conn.send_resp(200, :zlib.gzip("PHOTOBYTES"))
        end
      end)

      attachment = %{kind: :image, file_id: "gz", mime_type: "image/jpeg", size_bytes: nil}

      assert {:error, {:unexpected_content_encoding, "gzip"}} =
               Telegram.download_attachment(%{}, attachment)
    end
  end

  # -- send_message/3 --

  describe "send_message/3" do
    # M30 §11.3: an unconfigured bot token is an unavailable adapter, a reason
    # the closed delivery vocabulary already owns — not a bare atom the reminder
    # normalizer has to log as a contract violation.
    test "rejects a missing bot token as an unavailable adapter" do
      Application.put_env(:fermix_channels, :telegram, allowed_user_ids: ["111"])

      assert {:error, {:permanent, :adapter_unavailable}} = send_msg("123", "hello")
    end

    test "posts to Telegram sendMessage endpoint" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = send_msg("123", "hello")

      assert_received {:telegram_request, path, body}
      assert path == "/bottest-bot-token/sendMessage"
      assert body["chat_id"] == "123"
      assert body["text"] == "hello"
    end

    # MILESTONE_31 §18 row "Channels": a place answer's links have to arrive
    # clickable on an HTML-rendered surface, and the URLs have to survive exactly
    # as the tool returned them — a rewritten or stripped link is a broken
    # citation (§9.5). Query strings and redirect tokens are where that breaks.
    test "renders place, source, and media links from a place answer as clickable HTML" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = """
      - [Example Coffee](https://example.coffee/?utm=brave) — 4.6/5, 0.4 km away. [Photo](https://cdn.example/p.jpg)
      Source: [provider page](https://provider.example/place/abc?token=xyz)
      """

      assert :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body}
      assert body["parse_mode"] == "HTML"

      assert body["text"] =~
               ~s(<a href="https://example.coffee/?utm=brave">Example Coffee</a>)

      assert body["text"] =~ ~s(<a href="https://cdn.example/p.jpg">Photo</a>)

      assert body["text"] =~
               ~s(<a href="https://provider.example/place/abc?token=xyz">provider page</a>)
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

      # The splitter emits trimmed chunks, so the trailing newline of the source
      # never reaches the wire.
      assert body["text"] ==
               String.trim("""
               <b>Title</b>
               • <i>first</i> item
               • <i>second</i> with <code>code</code>
               1. link to <a href="https://example.com?q=1&amp;x=2">Fermix</a>
               <s>done</s>
               <pre><code class="language-elixir">IO.puts(&quot;&lt;ok&gt;&quot;)</code></pre>
               """)
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
               String.trim("""
               <b>Run Summary</b>
               <b>Status:</b> failed
               <b>Details</b>
               • checked <code>mix test</code>
               """)

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
               String.trim("""
               <b>Run Summary &lt;tag&gt;</b>
               <b>Final Check</b>
               """)

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
               String.trim("""
               <b>Use ** as wildcard</b>
               <b>**mismatched bold</b>
               """)
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

    # A boundary-free run has no ladder rung to land on, so the hard cut is what
    # bounds it — every chunk under the section-card limit, nothing dropped.
    test "hard-cuts a boundary-free run at the chunk limit, losing nothing" do
      stub_telegram(self(), 200, %{"ok" => true})

      long_text = String.duplicate("a", 5000)
      :ok = send_msg("123", long_text)

      bodies = sent_bodies()
      assert length(bodies) == 4
      assert Enum.all?(bodies, &(rendered_units(&1["text"]) <= @chunk_limit_units))
      assert bodies |> Enum.map_join(& &1["text"]) |> Kernel.==(long_text)
    end

    # Entity budget as an independent fill condition: dense inline markup can sit
    # far under the length limit while blowing past Telegram's entity cap.
    test "caps formatting entities per chunk independently of length" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = String.duplicate("**a** ", 300)
      :ok = send_msg("123", text)

      bodies = sent_bodies()
      assert length(bodies) > 1

      Enum.each(bodies, fn body ->
        assert body["parse_mode"] == "HTML"
        assert rendered_units(body["text"]) <= @chunk_limit_units
        assert body["text"] |> String.split("<b>") |> length() |> Kernel.-(1) <= @entity_budget
      end)
    end

    test "prefers semantic split boundaries for rendered Telegram HTML" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = String.duplicate("a", 1_396) <> " [Fermix](https://example.com) tail"
      :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, body1}
      assert_received {:telegram_request, _path, body2}
      assert body1["text"] == String.duplicate("a", 1_396)
      assert body2["text"] == ~s(<a href="https://example.com">Fermix</a> tail)
      refute_received {:telegram_request, _path, _body}
    end

    test "does not split a reply that fits one section card" do
      stub_telegram(self(), 200, %{"ok" => true})

      text = String.duplicate("a", @chunk_limit_units)
      :ok = send_msg("123", text)

      assert_received {:telegram_request, _path, _body}
      refute_received {:telegram_request, _path, _body}
    end

    # §4.3: one reply, one ring.
    test "only the first chunk of a reply rings; every later chunk is silent" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", String.duplicate("a", 5000))

      [first | rest] = sent_bodies()
      refute Map.has_key?(first, "disable_notification")
      assert rest != []
      assert Enum.all?(rest, &(&1["disable_notification"] == true))
    end

    test "disables link previews on every outbound text send" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", "see [Fermix](https://example.com)")

      assert_received {:telegram_request, _path, body}
      assert body["link_preview_options"] == %{"is_disabled" => true}
    end

    # §4.2: boundaries carry the structure — a message opens at a section, never
    # mid-sentence.
    test "cuts a sectioned reply at section starts, under the card limit" do
      stub_telegram(self(), 200, %{"ok" => true})

      text =
        Enum.map_join(1..6, "\n\n", fn n ->
          "## Section #{n}\n\n" <> String.duplicate("Sentence #{n} of the section body. ", 20)
        end)

      :ok = send_msg("123", text)

      bodies = sent_bodies()
      assert length(bodies) > 1

      Enum.each(bodies, fn body ->
        assert rendered_units(body["text"]) <= @chunk_limit_units
        assert String.starts_with?(body["text"], "<b>Section ")
      end)
    end

    # The reported defect (design §1.1 item 2): the old "last whitespace before
    # 4096" cut split the "- Conch Republic Divers advertises …" bullet, so the
    # next message opened lowercase, mid-sentence.
    test "never opens a chunk mid-sentence on the dive-reply fixture" do
      stub_telegram(self(), 200, %{"ok" => true})

      :ok = send_msg("123", dive_reply_fixture())

      bodies = sent_bodies()
      assert length(bodies) > 1

      Enum.each(bodies, fn body ->
        refute String.match?(opening_word(body["text"]), ~r/^[a-z]/)
      end)
    end

    test "resends a chunk unformatted when Telegram cannot parse the entities" do
      test_pid = self()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(:telegram, fn conn ->
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_request, conn.request_path, Jason.decode!(req_body)})
        attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

        {status, body} =
          if attempt == 1 do
            {400,
             %{
               "ok" => false,
               "description" => "Bad Request: can't parse entities: unsupported start tag"
             }}
          else
            {200, %{"ok" => true}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end)

      :telemetry.attach(
        "test-plain-fallback",
        [:fermix, :channel, :render],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:render_telemetry, metadata.status})
        end,
        nil
      )

      log =
        capture_log(fn ->
          assert :ok = send_msg("123", "answer with **bold**")
        end)

      :telemetry.detach("test-plain-fallback")

      assert [formatted, plain] = sent_bodies()
      assert formatted["text"] == "answer with <b>bold</b>"
      assert formatted["parse_mode"] == "HTML"
      # The resend is the RAW markdown with no parse mode — never the HTML that
      # Telegram just refused.
      assert plain["text"] == "answer with **bold**"
      refute Map.has_key?(plain, "parse_mode")

      assert log =~ "can't parse entities"
      assert_received {:render_telemetry, :plain_fallback}
    end

    test "a second parse failure returns the error instead of retrying again" do
      stub_telegram(self(), 400, %{
        "ok" => false,
        "description" => "Bad Request: can't parse entities: unsupported start tag"
      })

      capture_log(fn ->
        assert {:error, {:http_status, 400}} = send_msg("123", "**bold**")
      end)

      assert length(sent_bodies()) == 2
    end

    # M30 §11.3: adapters own platform knowledge and return the structured
    # status form; no interpolated "Telegram API error: 400" string survives.
    test "returns a structured {:http_status, status} on a non-2xx status" do
      stub_telegram(self(), 400, %{"ok" => false, "description" => "Bad Request"})

      assert {:error, {:http_status, 400}} = send_msg("123", "hello")
    end

    test "returns a structured {:http_status, status} on a server error" do
      stub_telegram(self(), 503, %{"ok" => false, "description" => "Service Unavailable"})

      assert {:error, {:http_status, 503}} = send_msg("123", "hello")
    end

    test "leaves a raw transport error untouched for the central normalizer" do
      Req.Test.stub(:telegram, fn conn ->
        Req.Test.transport_error(conn, :econnreset)
      end)

      assert {:error, %Req.TransportError{reason: :econnreset}} = send_msg("123", "hello")
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

    # §4.2: a fence too big for one message cannot be split without corrupting
    # both halves, so it ships as a file after the text chunks land.
    test "promotes an oversized code block to a document and cleans up its temp file" do
      test_pid = self()

      Req.Test.stub(:telegram, fn conn ->
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram_call, conn.request_path, req_body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      code = String.duplicate("IO.puts(:hello)\n", 300)

      assert :ok = send_msg("123", "Here is the script:\n\n```elixir\n" <> code <> "```\n")

      assert_receive {:telegram_call, "/bottest-bot-token/sendMessage", text_body}
      assert Jason.decode!(text_body)["text"] =~ "full code attached as a file"
      refute Jason.decode!(text_body)["text"] =~ "IO.puts"

      assert_receive {:telegram_call, "/bottest-bot-token/sendDocument", doc_body}
      assert doc_body =~ ~s(name="document")
      assert doc_body =~ "code-1.txt"
      assert doc_body =~ "Code from this reply (elixir)"
      assert doc_body =~ "IO.puts(:hello)"

      assert Path.wildcard(Path.join(System.tmp_dir!(), "fermix-telegram-code-*")) == []
    end

    test "a plain text send carries no reply_markup (no button regression)" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = send_msg("123", "hello")

      assert_received {:telegram_request, _path, body}
      refute Map.has_key?(body, "reply_markup")
    end
  end

  # -- send_approval/3 (Approve/Deny buttons) --

  describe "send_approval/3" do
    defp approval_message(chat_id, thread_ts \\ nil) do
      Message.new!(%{
        id: "1",
        content: "x",
        sender: "alice",
        channel: "telegram",
        chat_id: chat_id,
        reply_target: chat_id,
        thread_ts: thread_ts
      })
    end

    test "attaches Approve and Deny buttons with namespaced tokens" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok =
               Telegram.send_approval(
                 approval_message("123"),
                 "Approve with `/confirm TOK12345`",
                 "TOK12345"
               )

      assert_received {:telegram_request, path, body}
      assert path == "/bottest-bot-token/sendMessage"
      assert body["chat_id"] == "123"
      assert body["text"] =~ "Approve"

      assert body["reply_markup"]["inline_keyboard"] == [
               [
                 %{"text" => "✅ Approve", "callback_data" => "grant:TOK12345"},
                 %{"text" => "❌ Deny", "callback_data" => "deny:TOK12345"}
               ]
             ]
    end

    test "carries the forum thread id when the origin has one" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = Telegram.send_approval(approval_message("123", 77), "approve", "TOK12345")

      assert_received {:telegram_request, _path, body}
      assert body["message_thread_id"] == 77
    end
  end

  describe "send_proposal/3" do
    test "attaches a two-button row with skillcur-namespaced payloads" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok =
               Telegram.send_proposal(%{chat_id: "123"}, "Skill proposal text", "TOK12345")

      assert_received {:telegram_request, path, body}
      assert path == "/bottest-bot-token/sendMessage"
      assert body["chat_id"] == "123"

      assert body["reply_markup"]["inline_keyboard"] == [
               [
                 %{"text" => "✅ Approve", "callback_data" => "skillcur:a:TOK12345"},
                 %{"text" => "❌ Deny", "callback_data" => "skillcur:d:TOK12345"}
               ]
             ]
    end
  end

  describe "skillcur callback taps" do
    defp proposal_callback(data) do
      %{
        "callback_query" => %{
          "id" => "cbq-9",
          "data" => data,
          "from" => %{"id" => 111, "username" => "alice"},
          "message" => %{
            "message_id" => 56,
            "chat" => %{"id" => 123, "type" => "private"}
          }
        }
      }
    end

    test "an approve tap synthesizes the typed /skills approve command" do
      assert {:ok, [msg]} = Telegram.parse_update(proposal_callback("skillcur:a:TOK12345"))
      assert msg.content == "/skills approve TOK12345"
      assert msg.channel == "telegram"
      assert msg.chat_id == "123"
      assert msg.metadata.user_id == "111"
    end

    test "a deny tap synthesizes the typed /skills deny command" do
      assert {:ok, [msg]} = Telegram.parse_update(proposal_callback("skillcur:d:TOK12345"))
      assert msg.content == "/skills deny TOK12345"
    end

    test "an unknown namespace stays ignored" do
      assert {:ok, []} = Telegram.parse_update(proposal_callback("mystery:TOK12345"))
    end
  end

  # -- acknowledge_callback/2 (spinner + strip used button) --

  describe "acknowledge_callback/2" do
    test "answers the callback query and strips the used button" do
      stub_telegram(self(), 200, %{"ok" => true})

      callback = %{
        "id" => "cbq-9",
        "message" => %{"message_id" => 55, "chat" => %{"id" => 123}}
      }

      assert :ok =
               Telegram.acknowledge_callback(callback, req_options: [plug: {Req.Test, :telegram}])

      assert_received {:telegram_request, "/bottest-bot-token/answerCallbackQuery", answer_body}
      assert answer_body["callback_query_id"] == "cbq-9"

      assert_received {:telegram_request, "/bottest-bot-token/editMessageReplyMarkup", edit_body}
      assert edit_body["chat_id"] == "123"
      assert edit_body["message_id"] == 55
      assert edit_body["reply_markup"]["inline_keyboard"] == []
    end

    test "answers the query even when the callback carries no message to edit" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok =
               Telegram.acknowledge_callback(%{"id" => "cbq-9"},
                 req_options: [plug: {Req.Test, :telegram}]
               )

      assert_received {:telegram_request, "/bottest-bot-token/answerCallbackQuery", _body}
      refute_received {:telegram_request, "/bottest-bot-token/editMessageReplyMarkup", _}
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

  # One delivered message is one outbound row (design §8). Before S4 the adapter
  # emitted a single `count: N` row only when EVERY chunk of a reply landed — so
  # a partial failure reported nothing at all, and a draft-streamed answer that
  # sealed in place left zero outbound rows for the whole turn.
  describe "outbound telemetry" do
    defp attach_message_events(handler_id) do
      :ok =
        :telemetry.attach(
          handler_id,
          [:fermix, :channel, :message],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    # Drains the outbound `channel_msg` rows recorded so far, in emission order.
    defp outbound_rows(acc \\ []) do
      receive do
        {:telemetry, [:fermix, :channel, :message], measurements,
         %{direction: :outbound} = metadata} ->
          outbound_rows([{measurements, metadata} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp assert_single_message_row({measurements, metadata}) do
      assert measurements.count == 1
      assert measurements.duration_us >= 0
      assert metadata.channel == :telegram
      assert metadata.direction == :outbound
    end

    test "emits one row per delivered chunk, not one row per reply" do
      attach_message_events("test-outbound-per-chunk")
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = send_msg("123", dive_reply_fixture())

      bodies = sent_bodies()
      assert length(bodies) > 1

      rows = outbound_rows()
      assert length(rows) == length(bodies)
      Enum.each(rows, &assert_single_message_row/1)
    end

    test "a partial failure leaves truthful rows for the chunks that were delivered" do
      attach_message_events("test-outbound-partial")
      stub_ok_then_error(self(), 1, 403, %{"ok" => false, "description" => "Forbidden"})

      assert {:error, _reason} = send_msg("123", dive_reply_fixture())

      # The first chunk reached the chat and the send then aborted: exactly one
      # row, where the all-or-nothing emission reported none.
      assert [row] = outbound_rows()
      assert_single_message_row(row)
    end

    test "a chunk rescued by the unformatted resend still counts as one message" do
      attach_message_events("test-outbound-resend")

      capture_log(fn ->
        stub_ok_then_error(self(), 0, 400, %{
          "ok" => false,
          "description" => "Bad Request: can't parse entities: unexpected tag"
        })

        assert {:error, _reason} = send_msg("123", "**bold**")
      end)

      # Both attempts failed here, so nothing was delivered and nothing is
      # reported — the resend is a second attempt at ONE message, never a
      # second message.
      assert outbound_rows() == []
    end

    test "a created draft bubble emits exactly one row" do
      attach_message_events("test-outbound-draft-open")
      stub_telegram(self(), 200, %{"ok" => true, "result" => %{"message_id" => 777}})

      assert {:ok, 777} = Telegram.open_draft(draft_message(), "**bold** start")

      assert [row] = outbound_rows()
      assert_single_message_row(row)
    end

    test "a failed draft open emits nothing" do
      attach_message_events("test-outbound-draft-open-failed")
      stub_telegram(self(), 403, %{"ok" => false, "description" => "Forbidden"})

      assert {:error, _reason} = Telegram.open_draft(draft_message(), "draft text")
      assert outbound_rows() == []
    end

    # Edits and seals rewrite a bubble that has already been counted; they are
    # visible as [:fermix, :channel, :stream] phases, and counting them would
    # report one answer as one "message" per streaming tick.
    test "editing and sealing an existing bubble emit nothing" do
      attach_message_events("test-outbound-draft-edit")
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = Telegram.edit_draft(draft_message(), 777, "now *italic*")
      assert {:ok, nil} = Telegram.seal_draft(draft_message(), 777, "final text")

      assert outbound_rows() == []
    end

    test "a swept thought leaves its outbound row, and the sweep delete leaves none" do
      attach_message_events("test-outbound-ephemeral")
      stub_message_ids(self(), [4_001])

      assert {:ok, ["4001"]} =
               Telegram.send_ephemeral(draft_message(), "💭 Checking the calendar")

      assert [row] = outbound_rows()
      assert_single_message_row(row)

      stub_telegram(self(), 200, %{"ok" => true})
      assert :ok = Telegram.delete_message(draft_message(), "4001")

      assert outbound_rows() == []
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

  describe "rotation_spec/0" do
    test "rotates on the same card size a finished reply is split into" do
      %{measure: measure, rotate_at: rotate_at} = Telegram.rotation_spec()

      assert rotate_at == @chunk_limit_units
      # The measurer is the rendered UTF-16 length, not graphemes: an emoji
      # counts two units on the wire and must count two here.
      assert measure.("ab") == 2
      assert measure.("😀") == 2
      assert measure.("**bold**") == 4
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
      assert body["link_preview_options"] == %{"is_disabled" => true}
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
      assert body["link_preview_options"] == %{"is_disabled" => true}
    end

    test "holds an overflowing draft to the largest fitting prefix" do
      stub_telegram(self(), 200, %{"ok" => true})
      long = String.duplicate("word ", 2_000)

      assert :ok = Telegram.edit_draft(draft_message(), 777, long)

      assert_receive {:telegram_request, _path, body}
      assert rendered_units(body["text"]) <= 4_000
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
      # The remainder is a verbatim suffix of the draft text, so the caller can
      # deliver it without re-deriving what was already sealed.
      assert String.ends_with?(long, remainder)

      assert_receive {:telegram_request, _path, body}
      assert rendered_units(body["text"]) <= 4_000
      assert body["link_preview_options"] == %{"is_disabled" => true}
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

  # -- Ephemeral thought messages (CHANNEL_LONGFORM_PRESENTATION §5) --

  describe "send_ephemeral/2" do
    test "sends every chunk silently and returns the message ids in order" do
      stub_message_ids(self(), [4_001, 4_002, 4_003])

      # Long enough that the ladder has to produce more than one chunk, so the
      # notification-suppression assertion covers the FIRST chunk too.
      long = String.duplicate("A thought line about the plan. ", 120)

      assert {:ok, ids} = Telegram.send_ephemeral(draft_message(), long)
      assert length(ids) > 1
      assert ids == Enum.take(["4001", "4002", "4003"], length(ids))

      bodies = sent_bodies()
      assert length(bodies) == length(ids)
      assert Enum.all?(bodies, &(&1["disable_notification"] == true))
      assert Enum.all?(bodies, &(&1["chat_id"] == "123"))
      assert Enum.all?(bodies, &(&1["link_preview_options"] == %{"is_disabled" => true}))
    end

    test "a single thought line is one silent message" do
      stub_message_ids(self(), [77])

      assert {:ok, ["77"]} = Telegram.send_ephemeral(draft_message(), "💭 Checking the calendar")

      assert_received {:telegram_request, path, body}
      assert path =~ "/sendMessage"
      assert body["disable_notification"] == true
      assert body["text"] == "💭 Checking the calendar"
    end

    test "carries the thread id" do
      stub_message_ids(self(), [78])

      assert {:ok, ["78"]} = Telegram.send_ephemeral(draft_message(99), "💭 In a topic")

      assert_received {:telegram_request, _path, body}
      assert body["message_thread_id"] == 99
    end

    test "surfaces a send failure" do
      stub_telegram(self(), 403, %{"ok" => false, "description" => "Forbidden"})

      assert {:error, _reason} = Telegram.send_ephemeral(draft_message(), "💭 Nope")
    end

    test "refuses loudly when the API answers 200 without a message id" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert {:error, :missing_message_id} = Telegram.send_ephemeral(draft_message(), "💭 Hmm")
    end
  end

  describe "delete_message/2" do
    test "posts deleteMessage for the id it was given" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert :ok = Telegram.delete_message(draft_message(), "4001")

      assert_received {:telegram_request, path, body}
      assert path =~ "/deleteMessage"
      assert body["chat_id"] == "123"
      assert body["message_id"] == 4_001
    end

    test "a non-numeric id fails loud before any API call" do
      stub_telegram(self(), 200, %{"ok" => true})

      assert {:error, {:invalid_message_id, "abc"}} =
               Telegram.delete_message(draft_message(), "abc")

      refute_received {:telegram_request, _path, _body}
    end

    test "surfaces a delete failure" do
      stub_telegram(self(), 400, %{"ok" => false, "description" => "message to delete not found"})

      assert {:error, _reason} = Telegram.delete_message(draft_message(), "4001")
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
