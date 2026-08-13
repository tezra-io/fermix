defmodule FermixChannels.Channels.DiscordTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias FermixChannels.Channels.Discord
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

    test "attaches the channel reaction_spec and delivers a reaction through the same reply_fn" do
      Req.Test.stub(:discord, fn conn ->
        send(self(), {:discord_reaction, conn.method, conn.request_path})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, messages} = Discord.parse_gateway_event(dm_event("thanks"))

      assert :ok =
               Dispatcher.dispatch(messages,
                 channel: Discord,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}
      # Discord is :any_emoji → the gateway flattens the capability to plain data.
      assert agent_message.reaction_spec == %{emoji_set: :any}

      # The very same reply_fn dispatches a reaction to the channel's react/2.
      assert :ok = agent_message.reply_fn.({:react, "👍"})
      assert_receive {:discord_reaction, "PUT", path}
      assert path =~ "/channels/dm-channel-1/messages/message-1/reactions/"
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

      queue =
        start_supervised!(
          {FermixChannels.Gateway.Queue,
           [name: :"queue_#{System.unique_integer([:positive])}", main_agent: agent]}
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
                 agent: FermixChannels.Gateway.Queue,
                 agent_server: queue
               )

      assert_receive {:discord_request, "/api/v10/channels/dm-channel-1/messages", body}, 5_000
      assert body["content"] == "reply from main agent"
      assert body["message_reference"]["message_id"] == "message-1"
    end
  end

  describe "send_message/3" do
    # M30 §11.3: see the Slack counterpart — a missing bot token is
    # `{:permanent, :adapter_unavailable}`, not a bare `:not_configured`.
    test "rejects missing send configuration as an unavailable adapter" do
      Application.put_env(:fermix_channels, :discord, enabled: true)

      assert {:error, {:permanent, :adapter_unavailable}} =
               Discord.send_message("dm-channel-1", "hello")
    end

    # CHANNEL_LONGFORM_PRESENTATION §3.1: a reply over Discord's content cap is
    # split on the shared boundary ladder and delivered as sequential messages.
    # It is never refused — a long final answer used to be undeliverable here.
    test "splits text over the Discord content cap into sequential sends" do
      stub_recording_sends(fail_at: nil)

      text = paragraph_fixture(24)

      assert :ok = Discord.send_message("dm-channel-1", text)

      chunks = collect_chunks()
      assert length(chunks) == 3
      assert Enum.all?(chunks, &(String.length(&1) <= 2_000))
      # Paragraph-boundary cuts: rejoining reproduces the source exactly.
      assert Enum.join(chunks, "\n\n") == String.trim(text)
    end

    test "cuts long text on word boundaries, never mid-word" do
      stub_recording_sends(fail_at: nil)

      text = sentence_fixture(120)

      assert :ok = Discord.send_message("dm-channel-1", text)

      chunks = collect_chunks()
      assert length(chunks) > 1
      # A chunk that began or ended mid-word would split one source word in two.
      assert Enum.flat_map(chunks, &String.split/1) == String.split(text)
    end

    # Discord's cap counts codepoints, so a ZWJ-emoji body can sit far under the
    # cap in graphemes and still be a 400 on the wire. Measured in graphemes this
    # text is one message; measured the way Discord measures it, it is several.
    test "splits emoji text that is under the cap in graphemes but over it in codepoints" do
      stub_recording_sends(fail_at: nil)

      # 5 codepoints / 1 grapheme per family, plus a space to cut on.
      text = String.duplicate("👩‍👩‍👦 ", 400)

      assert String.length(text) <= 2_000
      assert codepoints(text) > 2_000

      assert :ok = Discord.send_message("dm-channel-1", text)

      chunks = collect_chunks()
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(codepoints(&1) <= 2_000))
      assert Enum.flat_map(chunks, &String.split/1) == String.split(text)
    end

    test "the first failing chunk aborts the remaining sends" do
      stub_recording_sends(fail_at: 2)

      assert {:error, {:http_status, 403}} =
               Discord.send_message("dm-channel-1", paragraph_fixture(24))

      # Three chunks were due; the send stopped at the failure.
      assert length(collect_chunks()) == 2
    end

    test "sends under-cap text as a single unchanged message" do
      stub_recording_sends(fail_at: nil)

      assert :ok = Discord.send_message("dm-channel-1", "short reply")

      assert collect_chunks() == ["short reply"]
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

    # M30 §11.3: a non-2xx becomes the structured status form.
    test "returns a structured {:http_status, status} on a non-2xx status" do
      Req.Test.stub(:discord, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Missing Permissions"}))
      end)

      assert {:error, {:http_status, 403}} = Discord.send_message("dm-channel-1", "hello")
    end

    test "leaves a raw transport error untouched for the central normalizer" do
      Req.Test.stub(:discord, fn conn -> Req.Test.transport_error(conn, :econnreset) end)

      assert {:error, %Req.TransportError{reason: :econnreset}} =
               Discord.send_message("dm-channel-1", "hello")
    end
  end

  # -- telemetry --

  # One delivered message is one outbound row (design §8). Before S4 the adapter
  # emitted a single `count: N` row only when EVERY chunk of a reply landed — so
  # a reply that half-landed reported nothing at all.
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
      assert metadata.channel == :discord
      assert metadata.direction == :outbound
    end

    test "emits one row per delivered chunk, not one row per reply" do
      attach_message_events("test-discord-outbound-per-chunk")
      stub_recording_sends(fail_at: nil)

      assert :ok = Discord.send_message("dm-channel-1", paragraph_fixture(24))

      chunks = collect_chunks()
      assert length(chunks) == 3

      rows = outbound_rows()
      assert length(rows) == length(chunks)
      Enum.each(rows, &assert_single_message_row/1)
    end

    test "a partial failure leaves truthful rows for the chunks that were delivered" do
      attach_message_events("test-discord-outbound-partial")
      stub_recording_sends(fail_at: 2)

      assert {:error, {:http_status, 403}} =
               Discord.send_message("dm-channel-1", paragraph_fixture(24))

      # Chunk 1 reached the channel and chunk 2 was rejected: exactly one row,
      # where the all-or-nothing emission reported none.
      assert [row] = outbound_rows()
      assert_single_message_row(row)
    end

    test "a send that fails on its first chunk emits nothing" do
      attach_message_events("test-discord-outbound-first-chunk-failed")
      stub_recording_sends(fail_at: 1)

      assert {:error, {:http_status, 403}} = Discord.send_message("dm-channel-1", "short reply")

      assert outbound_rows() == []
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

  describe "download_attachment/2" do
    @media_cap 10 * 1_024 * 1_024

    defp cdn_attachment do
      %{
        kind: :image,
        url: "https://cdn.discordapp.com/attachments/1/2/photo.png",
        mime_type: "image/png",
        file_id: "2",
        size_bytes: nil
      }
    end

    test "downloads a CDN attachment to an owner-only temp file" do
      Req.Test.stub(:discord, fn conn ->
        Plug.Conn.send_resp(conn, 200, "png-bytes")
      end)

      assert {:ok, path} = Discord.download_attachment(%{}, cdn_attachment())

      try do
        assert File.read!(path) == "png-bytes"
        assert String.ends_with?(path, ".png")
        assert (File.stat!(path).mode &&& 0o777) == 0o600
      after
        FermixTestSupport.SafeRm.rm!(path)
      end
    end

    # The gateway's declared `size` is the sender's claim; the CDN response is
    # the only fact. This has to halt mid-transfer, not measure a resident body.
    test "halts a CDN body that outgrows the declared size at the media cap" do
      Req.Test.stub(:discord, fn conn ->
        Plug.Conn.send_resp(conn, 200, :binary.copy("x", @media_cap + 1))
      end)

      assert {:error, {:byte_cap_exceeded, received, allowed}} =
               Discord.download_attachment(%{}, cdn_attachment())

      assert allowed == @media_cap
      assert received == allowed + 1
    end

    # Proof the fetch runs through the streaming collector: Req only advertises
    # `accept-encoding` when `into:` is nil, and a buffered body is gunzipped by
    # Req's `decompress_body` step before any cap can see it.
    test "never advertises accept-encoding, so there is no decompression amplifier" do
      Req.Test.stub(:discord, fn conn ->
        assert Plug.Conn.get_req_header(conn, "accept-encoding") == []
        Plug.Conn.send_resp(conn, 200, "png-bytes")
      end)

      assert {:ok, path} = Discord.download_attachment(%{}, cdn_attachment())
      on_exit(fn -> FermixTestSupport.SafeRm.rm!(path) end)
    end

    test "refuses a compressed CDN body by name rather than inflating it" do
      Req.Test.stub(:discord, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("png-bytes"))
      end)

      assert {:error, {:unexpected_content_encoding, "gzip"}} =
               Discord.download_attachment(%{}, cdn_attachment())
    end

    test "hands a CDN non-2xx back as a download failure" do
      Req.Test.stub(:discord, fn conn ->
        Plug.Conn.send_resp(conn, 403, "forbidden")
      end)

      assert {:error, {:download_failed, 403}} =
               Discord.download_attachment(%{}, cdn_attachment())
    end
  end

  describe "health_check/1" do
    test "returns ok when the bot identity matches config" do
      Req.Test.stub(:discord, fn conn ->
        assert conn.request_path == "/api/v10/users/@me"
        Req.Test.json(conn, %{"id" => "999"})
      end)

      assert {:ok, %{detail: "Discord bot 999 authenticated", latency_ms: ms}} =
               Discord.health_check()

      assert is_integer(ms)
    end

    test "classifies bot id mismatches as misconfigured" do
      Req.Test.stub(:discord, fn conn ->
        Req.Test.json(conn, %{"id" => "000"})
      end)

      assert {:error, {:misconfigured, "discord bot_user_id 999 does not match 000"}} =
               Discord.health_check()
    end

    test "classifies auth failures" do
      Req.Test.stub(:discord, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Unauthorized"}))
      end)

      assert {:error, {:auth_failed, "Discord API HTTP 401: Unauthorized"}} =
               Discord.health_check()
    end

    test "classifies server errors" do
      Req.Test.stub(:discord, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "server error"}))
      end)

      assert {:error, {:server_error, 500, %{"message" => "server error"}}} =
               Discord.health_check()
    end

    test "classifies network failures" do
      Req.Test.stub(:discord, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      assert {:error, {:network, %Req.TransportError{reason: :closed}}} =
               Discord.health_check()
    end
  end

  describe "reactions" do
    defp react_message do
      Message.new!(%{
        id: "555",
        content: "thanks",
        sender: "user",
        channel: "discord",
        chat_id: "999999",
        reply_target: "999999"
      })
    end

    test "reaction_capability is any_emoji" do
      assert Discord.reaction_capability() == :any_emoji
    end

    test "react PUTs a @me reaction and succeeds on 204" do
      test_pid = self()

      Req.Test.stub(:discord, fn conn ->
        send(test_pid, {:discord_request, conn.method, conn.request_path})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = Discord.react(react_message(), "👍")

      assert_receive {:discord_request, "PUT", path}
      assert path =~ "/channels/999999/messages/555/reactions/"
      assert path =~ "/@me"
    end

    test "react surfaces an API error on a non-2xx status" do
      Req.Test.stub(:discord, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Missing Permissions"}))
      end)

      assert {:error, {:discord_api_error, 403, _body}} = Discord.react(react_message(), "👍")
    end
  end

  # -- send_approval/3 (Approve/Deny buttons) --

  describe "send_approval/3" do
    defp approval_message(chat_id) do
      Message.new!(%{
        id: "message-1",
        content: "x",
        sender: "alice",
        channel: "discord",
        chat_id: chat_id,
        reply_target: chat_id
      })
    end

    test "attaches Approve and Deny buttons with namespaced tokens" do
      test_pid = self()

      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:discord_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
      end)

      assert :ok =
               Discord.send_approval(
                 approval_message("dm-channel-1"),
                 "Approve with `/confirm TOK12345`",
                 "TOK12345"
               )

      assert_receive {:discord_request, "/api/v10/channels/dm-channel-1/messages", body}
      assert body["content"] =~ "Approve"
      assert body["message_reference"]["message_id"] == "message-1"

      assert body["components"] == [
               %{
                 "type" => 1,
                 "components" => [
                   %{
                     "type" => 2,
                     "style" => 3,
                     "label" => "Approve",
                     "custom_id" => "grant:TOK12345"
                   },
                   %{
                     "type" => 2,
                     "style" => 4,
                     "label" => "Deny",
                     "custom_id" => "deny:TOK12345"
                   }
                 ]
               }
             ]
    end

    test "a plain text send carries no components (no button regression)" do
      test_pid = self()

      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:discord_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
      end)

      assert :ok = Discord.send_message("dm-channel-1", "hello")

      assert_receive {:discord_request, _path, body}
      refute Map.has_key?(body, "components")
    end
  end

  describe "send_proposal/3" do
    test "attaches a two-button action row with skillcur-namespaced payloads" do
      test_pid = self()

      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:discord_request, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
      end)

      assert :ok = Discord.send_proposal(%{chat_id: "dm-channel-1"}, "Skill proposal", "TOK12345")

      assert_receive {:discord_request, "/api/v10/channels/dm-channel-1/messages", body}

      assert body["components"] == [
               %{
                 "type" => 1,
                 "components" => [
                   %{
                     "type" => 2,
                     "style" => 3,
                     "label" => "Approve",
                     "custom_id" => "skillcur:a:TOK12345"
                   },
                   %{
                     "type" => 2,
                     "style" => 4,
                     "label" => "Deny",
                     "custom_id" => "skillcur:d:TOK12345"
                   }
                 ]
               }
             ]
    end
  end

  describe "skillcur interaction taps" do
    test "an approve tap synthesizes the typed /skills approve command" do
      assert {:ok, interaction} =
               Discord.parse_interaction(interaction_event("skillcur:a:TOK12345", guild: true))

      assert interaction.message.content == "/skills approve TOK12345"
      assert interaction.message.channel == "discord"
      assert interaction.message.metadata.user_id == "111"
    end

    test "a deny tap synthesizes the typed /skills deny command" do
      assert {:ok, interaction} =
               Discord.parse_interaction(interaction_event("skillcur:d:TOK12345", guild: false))

      assert interaction.message.content == "/skills deny TOK12345"
      assert interaction.message.chat_id == "dm-channel-1"
    end
  end

  # -- parse_interaction/1 (button-click INTERACTION_CREATE) --

  describe "parse_interaction/1" do
    test "synthesizes a /confirm message from a guild tap (member.user.id)" do
      assert {:ok, interaction} =
               Discord.parse_interaction(interaction_event("grant:TOK12345", guild: true))

      assert interaction.id == "interaction-1"
      assert interaction.token == "interaction-token-1"

      message = interaction.message
      assert message.content == "/confirm TOK12345"
      assert message.channel == "discord"
      assert message.chat_id == "guild-channel-1"
      assert message.reply_target == "guild-channel-1"
      assert message.thread_ts == nil
      assert message.metadata.user_id == "111"
    end

    test "reads the tapper id from user.id in a DM interaction" do
      assert {:ok, interaction} =
               Discord.parse_interaction(interaction_event("grant:TOK12345", guild: false))

      assert interaction.message.metadata.user_id == "111"
      assert interaction.message.chat_id == "dm-channel-1"
    end

    test "synthesizes a /deny message from a denial tap" do
      assert {:ok, interaction} =
               Discord.parse_interaction(interaction_event("deny:TOK12345", guild: false))

      assert interaction.message.content == "/deny TOK12345"
      assert interaction.message.metadata.user_id == "111"
    end

    test "ignores a non-grant custom_id" do
      assert :ignore =
               Discord.parse_interaction(interaction_event("other:payload", guild: true))
    end

    test "ignores a non-component interaction (type != 3)" do
      event = put_in(interaction_event("grant:TOK12345", guild: true), ["d", "type"], 2)
      assert :ignore = Discord.parse_interaction(event)
    end

    test "ignores a non-interaction event" do
      assert :ignore = Discord.parse_interaction(dm_event("hello"))
    end
  end

  # -- respond_interaction/4 (interaction callback REST) --

  describe "respond_interaction/4" do
    test "posts to the interaction callback endpoint using the interaction id + token" do
      test_pid = self()

      Req.Test.stub(:discord, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:discord_request, conn.request_path, Jason.decode!(body), conn.req_headers}
        )

        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               Discord.respond_interaction(
                 "interaction-1",
                 "interaction-token-1",
                 %{type: 7, data: %{components: []}},
                 req_options: [plug: {Req.Test, :discord}]
               )

      assert_receive {:discord_request, path, body, headers}
      assert path == "/api/v10/interactions/interaction-1/interaction-token-1/callback"
      # The per-interaction token in the URL authenticates — no bot-token header.
      refute Enum.any?(headers, fn {k, _v} -> k == "authorization" end)
      assert body["type"] == 7
    end

    test "surfaces a non-2xx as an interaction_ack_failed error" do
      Req.Test.stub(:discord, fn conn ->
        Plug.Conn.send_resp(conn, 404, Jason.encode!(%{"message" => "Unknown interaction"}))
      end)

      assert {:error, {:interaction_ack_failed, 404}} =
               Discord.respond_interaction("interaction-1", "interaction-token-1", %{type: 7},
                 req_options: [plug: {Req.Test, :discord}]
               )
    end
  end

  # -- outbound chunking fixtures --

  # Records every outbound message body, and with `fail_at:` rejects exactly
  # that 1-based send so the sequencing after a failure is observable.
  defp stub_recording_sends(opts) do
    test_pid = self()
    fail_at = Keyword.fetch!(opts, :fail_at)
    counter = :counters.new(1, [])

    Req.Test.stub(:discord, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      send(test_pid, {:discord_chunk, Jason.decode!(body)["content"]})
      respond_chunk(conn, :counters.get(counter, 1), fail_at)
    end)
  end

  defp respond_chunk(conn, index, fail_at) when index == fail_at do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Missing Permissions"}))
  end

  defp respond_chunk(conn, _index, _fail_at), do: Req.Test.json(conn, %{"id" => "reply-id"})

  @max_recorded_chunks 32

  defp collect_chunks, do: collect_chunks(@max_recorded_chunks, [])

  defp collect_chunks(0, _acc) do
    raise "more than #{@max_recorded_chunks} chunk sends recorded"
  end

  defp collect_chunks(remaining, acc) do
    receive do
      {:discord_chunk, content} -> collect_chunks(remaining - 1, [content | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # What Discord counts, as opposed to what String.length/1 counts.
  defp codepoints(text), do: length(String.to_charlist(text))

  defp paragraph_fixture(count) do
    Enum.map_join(1..count, "\n\n", &fixture_paragraph/1)
  end

  defp fixture_paragraph(n) do
    "Paragraph #{n}. " <> Enum.map_join(1..20, " ", fn w -> "word-#{n}-#{w}" end) <> "."
  end

  defp sentence_fixture(count) do
    Enum.map_join(1..count, " ", fn n ->
      "Sentence #{n} about alpha bravo charlie delta echo foxtrot golf hotel."
    end)
  end

  defp interaction_event(custom_id, opts) do
    guild? = Keyword.fetch!(opts, :guild)

    data =
      %{
        "id" => "interaction-1",
        "token" => "interaction-token-1",
        "type" => 3,
        "channel_id" => if(guild?, do: "guild-channel-1", else: "dm-channel-1"),
        "data" => %{"custom_id" => custom_id, "component_type" => 2}
      }
      |> put_interaction_actor(guild?)

    %{"t" => "INTERACTION_CREATE", "d" => data}
  end

  defp put_interaction_actor(data, true) do
    Map.merge(data, %{
      "guild_id" => "guild-1",
      "member" => %{"user" => %{"id" => "111", "username" => "alice"}}
    })
  end

  defp put_interaction_actor(data, false) do
    Map.put(data, "user", %{"id" => "111", "username" => "alice"})
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
