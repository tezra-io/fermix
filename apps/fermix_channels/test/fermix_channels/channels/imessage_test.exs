defmodule FermixChannels.Channels.IMessageTest do
  @moduledoc """
  The iMessage `Gateway.Channel` adapter (MILESTONE_54 §7.5, §8): row mapping,
  the plain dialect split at 4,000 and sent in order, media through the outbox
  under a claim, every disposition and helper error mapped onto the closed
  delivery vocabulary with `uncertain` never re-sent, `health_check` from the
  probe, and `download_attachment`. All against the scripted fake helper.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Outbound.Plain
  alias FermixChannels.Test.IMessageFakeHelper, as: FakeHelper
  alias FermixCore.Delivery.Error, as: DeliveryError
  alias FermixCore.IMessage.Control
  alias FermixTestSupport.SafeRm

  @owner "+15551234567"
  @dedicated %{posture: :dedicated_account, owner: @owner, handles: [@owner, "guest@example.com"]}

  setup do
    home = SafeRm.make_tmp_dir!("imessage-adapter")
    name = :"imessage_fake_#{System.unique_integer([:positive])}"
    start_supervised!({FakeHelper, name: name, home: home, test_pid: self()})
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    %{home: home, server: name, opts: [helper: FakeHelper, server: name]}
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "rowid" => 4021,
        "guid" => "guid-#{System.unique_integer([:positive])}",
        "chat" => %{
          "rowid" => 17,
          "guid" => "any;-;#{@owner}",
          "identifier" => @owner,
          "service" => "iMessage",
          "group" => false
        },
        "sender" => %{"handle" => @owner, "service" => "iMessage", "is_me" => false},
        "date" => "2026-10-03T12:00:00Z",
        "text" => "hello fermix",
        "decode_error" => nil,
        "reply_to_guid" => nil,
        "attachments" => [],
        "reaction" => nil
      },
      overrides
    )
  end

  defp media_file(home, name, bytes) do
    source = Path.join(home, name)
    File.write!(source, bytes)
    source
  end

  defp inbound(ctx, attachments) do
    row = row(%{"guid" => "MSG-1", "attachments" => attachments})

    {:ok, message} =
      IMessage.parse_row(row, @dedicated, %{helper: FakeHelper, server: ctx.server})

    message
  end

  defp inbox_file(home, name) do
    dir = Path.join([home, "imessage", "inbox", "MSG-1"])
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, "bytes")
    path
  end

  defp attach_channel_events do
    test_pid = self()
    handler_id = "imessage-adapter-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:fermix, :channel, :parse],
          [:fermix, :channel, :message],
          [:fermix, :channel, :render]
        ],
        fn event, measurements, metadata, _config ->
          if metadata.channel == :imessage and self() == test_pid do
            send(test_pid, {:channel_event, event, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "transport and capabilities" do
    test "has no webhook, no streaming edits, no reactions, no typing" do
      assert IMessage.parse_webhook(%{}) == {:error, :unsupported_transport}
      assert IMessage.verify_webhook(%Plug.Conn{}) == {:error, :unsupported_transport}
      assert IMessage.stream_capability() == :none
      assert IMessage.reaction_capability() == :none

      Code.ensure_loaded!(IMessage)

      for {fun, arity} <- [start_typing: 1, react: 2, send_ephemeral: 2, open_draft: 2] do
        refute function_exported?(IMessage, fun, arity), "#{fun}/#{arity} must not exist"
      end
    end
  end

  describe "parse_row/3 (§7.5)" do
    test "maps a dedicated-posture row onto the gateway message", %{server: server} do
      guid = "F1C2E3A4-0001"

      attachments = [
        %{
          "index" => 0,
          "guid" => "at0",
          "name" => "voice.caf",
          "mime" => "audio/x-caf",
          "bytes" => 4_821
        },
        %{
          "index" => 1,
          "guid" => "at1",
          "name" => "IMG.HEIC",
          "mime" => "image/heic",
          "bytes" => 9_000
        }
      ]

      row =
        row(%{
          "guid" => guid,
          "reply_to_guid" => "F1C2E3A4-0000",
          "attachments" => attachments,
          "sender" => %{
            "handle" => "Guest@Example.com",
            "service" => "iMessage",
            "is_me" => false
          }
        })

      assert {:ok, %Message{} = message} =
               IMessage.parse_row(row, @dedicated, %{helper: FakeHelper, server: server})

      assert message.id == guid
      assert message.content == "hello fermix"
      assert message.channel == "imessage"
      assert message.sender == "guest@example.com"
      assert message.chat_id == "guest@example.com"
      assert message.reply_target == "guest@example.com"

      assert %{
               user_id: "guest@example.com",
               sender_id: "guest@example.com",
               chat_type: "private",
               service: "iMessage",
               guid: ^guid,
               rowid: 4021,
               date: "2026-10-03T12:00:00Z",
               reply_to_guid: "F1C2E3A4-0000",
               posture: :dedicated_account,
               decode_error: nil
             } = message.metadata

      assert message.attachments == [
               %{kind: :audio, file_id: {guid, 0}, mime_type: "audio/x-caf", size_bytes: 4_821},
               %{kind: :image, file_id: {guid, 1}, mime_type: "image/heic", size_bytes: 9_000}
             ]
    end

    test "in the own posture the conversation and the sender are the owner" do
      own = %{posture: :own_account, owner: @owner, handles: [@owner]}
      row = row(%{"sender" => %{"handle" => nil, "service" => "iMessage", "is_me" => true}})

      assert {:ok, message} = IMessage.parse_row(row, own, %{})
      assert message.chat_id == @owner
      assert message.reply_target == @owner
      assert message.metadata.user_id == @owner
      assert message.metadata.posture == :own_account
    end

    test "a decode error is an empty message with a :decode_error parse status" do
      attach_channel_events()
      row = row(%{"text" => nil, "decode_error" => "typedstream_truncated"})

      assert {:ok, message} = IMessage.parse_row(row, @dedicated, %{})
      assert message.content == ""
      assert message.metadata.decode_error == "typedstream_truncated"

      assert_receive {:channel_event, [:fermix, :channel, :parse], %{duration_us: _},
                      %{status: :decode_error}}
    end

    test "a row without a usable guid or handle is refused, not guessed" do
      assert {:error, {:malformed_row, :guid}} =
               IMessage.parse_row(row(%{"guid" => nil}), @dedicated, %{})

      bad_sender = %{"handle" => "not a handle", "service" => "iMessage", "is_me" => false}

      assert {:error, {:malformed_row, :handle}} =
               IMessage.parse_row(row(%{"sender" => bad_sender}), @dedicated, %{})
    end

    test "parse_batch/3 emits one inbound message event per batch" do
      attach_channel_events()

      messages = IMessage.parse_batch([row(), row(), row(%{"guid" => nil})], @dedicated, %{})

      assert length(messages) == 2

      assert_receive {:channel_event, [:fermix, :channel, :message], %{count: 2},
                      %{direction: :inbound}}
    end
  end

  describe "send_message/3 (§8.1, §8.2)" do
    test "renders plain text and sends one recorded chunk", %{opts: opts, server: server} do
      attach_channel_events()

      assert :ok = IMessage.send_message(@owner, "a **bold** [link](https://x.test)", opts)

      assert_receive {:fake_helper_call, ^server, "send.text", params}
      assert params["to"] == @owner
      assert params["text"] == "a bold link: https://x.test"
      assert is_binary(params["idempotency_key"])

      assert_receive {:channel_event, [:fermix, :channel, :render], _measurements, %{status: :ok}}

      assert_receive {:channel_event, [:fermix, :channel, :message], %{count: 1},
                      %{direction: :outbound}}
    end

    test "splits at 4,000 rendered characters and sends every chunk in order", ctx do
      paragraph = String.duplicate("word ", 300) <> "\n\n"
      text = String.duplicate(paragraph, 20)

      assert :ok = IMessage.send_message(@owner, text, ctx.opts)

      sent = FakeHelper.calls(ctx.server, "send.text")
      assert length(sent) > 1
      assert Enum.all?(sent, &(Plain.rendered_length(&1["text"]) <= 4_000))

      assert Enum.map_join(sent, "", &String.replace(&1["text"], ~r/\s/, "")) ==
               String.replace(text, ~r/\s/, "")

      keys = Enum.map(sent, & &1["idempotency_key"])
      assert keys == Enum.uniq(keys)

      assert Enum.map(keys, &(&1 |> String.split(":") |> List.last())) ==
               Enum.map(0..(length(sent) - 1), &Integer.to_string/1)
    end

    test "the first failed chunk stops the rest", ctx do
      FakeHelper.script(ctx.server, "send.text", [
        {:ok, %{"disposition" => "recorded", "guid" => "g1", "rowid" => 1}},
        {:ok, %{"disposition" => "failed", "class" => "chat_not_found"}}
      ])

      text = String.duplicate(String.duplicate("word ", 300) <> "\n\n", 20)

      assert IMessage.send_message(@owner, text, ctx.opts) ==
               {:error, {:permanent, :remote_rejected}}

      assert length(FakeHelper.calls(ctx.server, "send.text")) == 2
    end

    test "a proactive send keys every attempt identically, so a retry is answered by the ledger",
         ctx do
      opts = ctx.opts ++ [proactive_key: "temporal:r-7"]

      assert :ok = IMessage.send_message(@owner, "Reminder: call mum", opts)
      assert :ok = IMessage.send_message(@owner, "Reminder: call mum", opts)

      [first, second] = FakeHelper.calls(ctx.server, "send.text")
      assert first["idempotency_key"] == second["idempotency_key"]
      assert first["idempotency_key"] =~ "temporal:r-7"
    end

    test "a turn reply is keyed by turn and attempt; an unkeyed send gets a fresh key", ctx do
      assert :ok = IMessage.send_message(@owner, "hi", ctx.opts ++ [turn_id: "t-42", attempt: 2])
      assert :ok = IMessage.send_message(@owner, "hi", ctx.opts)
      assert :ok = IMessage.send_message(@owner, "hi", ctx.opts)

      [turn, once_a, once_b] =
        Enum.map(FakeHelper.calls(ctx.server, "send.text"), & &1["idempotency_key"])

      assert turn == "turn:t-42:2:text:0"
      assert once_a != once_b
    end

    test "an invalid recipient is refused before anything is sent", ctx do
      assert IMessage.send_message("5551234567", "hi", ctx.opts) ==
               {:error, {:permanent, :invalid_destination}}

      assert FakeHelper.calls(ctx.server, "send.text") == []
    end
  end

  describe "the delivery vocabulary (§8.4)" do
    @cases [
      {{:ok, %{"disposition" => "uncertain"}}, {:transport, :timeout}},
      {{:ok, %{"disposition" => "failed", "class" => "automation_refused"}},
       {:permanent, :adapter_unavailable}},
      {{:ok, %{"disposition" => "failed", "class" => "chat_not_found"}},
       {:permanent, :remote_rejected}},
      {{:ok, %{"disposition" => "failed", "class" => "service_not_imessage"}},
       {:permanent, :remote_rejected}},
      {{:ok, %{"disposition" => "failed", "class" => "policy_violation"}},
       {:permanent, :remote_rejected}},
      {{:ok, %{"disposition" => "failed", "class" => "path_refused"}},
       {:permanent, :malformed_request}},
      {{:error, {:send_timeout, "osascript", %{}}}, {:transport, :timeout}},
      {{:error, {:request_timeout, "no answer", %{}}}, {:transport, :timeout}},
      {{:error, {:busy, "busy", %{}}}, {:transport, :pool_unavailable}},
      {{:error, {:helper_unavailable, "down", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:permission_denied, "FDA", %{"service" => "automation"}}},
       {:permanent, :adapter_unavailable}},
      {{:error, {:not_signed_in, "signed out", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:no_user_session, "ssh", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:db_unreadable, "locked", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:policy_absent, "none", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:policy_unconfirmed, "pending", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:automation_refused, "-1743", %{}}}, {:permanent, :adapter_unavailable}},
      {{:error, {:owner_is_this_mac, "signed in as the owner", %{}}},
       {:permanent, :adapter_unavailable}},
      {{:error, {:chat_not_found, "none", %{}}}, {:permanent, :remote_rejected}},
      {{:error, {:service_not_imessage, "sms", %{}}}, {:permanent, :remote_rejected}},
      {{:error, {:policy_violation, "outside", %{}}}, {:permanent, :remote_rejected}},
      {{:error, {:path_refused, "symlink", %{}}}, {:permanent, :malformed_request}},
      {{:error, {:attachment_too_large, "big", %{}}}, {:permanent, :malformed_request}},
      {{:error, {:protocol_error, "garbage", %{}}},
       {:unexpected_delivery_result, :invalid_contract}},
      {{:ok, %{"disposition" => "teleported"}}, {:unexpected_delivery_result, :invalid_contract}},
      {{:ok, %{"disposition" => "failed", "class" => "gremlins"}},
       {:unexpected_delivery_result, :invalid_contract}}
    ]

    test "every helper outcome maps into the closed vocabulary", ctx do
      for {reply, expected} <- @cases do
        FakeHelper.script(ctx.server, "send.text", reply)

        assert IMessage.send_message(@owner, "hi", ctx.opts) == {:error, expected}, inspect(reply)
        assert DeliveryError.normalize({:error, expected}) == {:error, expected}
      end
    end

    test "an uncertain send is reported as a transport timeout and the reply is not re-sent",
         ctx do
      FakeHelper.script(ctx.server, "send.text", {:ok, %{"disposition" => "uncertain"}})

      assert IMessage.send_message(@owner, "hi", ctx.opts) == {:error, {:transport, :timeout}}
      assert length(FakeHelper.calls(ctx.server, "send.text")) == 1
    end

    test "a channel that is not running is an unavailable adapter" do
      opts = [server: :imessage_port_never_started]

      assert IMessage.send_message(@owner, "hi", opts) ==
               {:error, {:permanent, :adapter_unavailable}}
    end
  end

  describe "send_media/3 (§8.3)" do
    test "copies the source into a private outbox entry, sends it, then removes the copy", ctx do
      source = media_file(ctx.home, "chart.png", "PNGDATA-#{System.unique_integer()}")
      test_pid = self()

      FakeHelper.script(ctx.server, "send.file", fn params ->
        send(test_pid, {:staged, params["path"], File.read(params["path"])})
        {:ok, %{"disposition" => "recorded", "guid" => "g", "rowid" => 1}}
      end)

      part = %{kind: :image, path: source, filename: "chart.png", mime_type: "image/png"}
      assert :ok = IMessage.send_media(@owner, part, ctx.opts)

      assert_receive {:staged, staged, {:ok, "PNGDATA-" <> _unique}}
      outbox = Path.join([ctx.home, "imessage", "outbox"])
      assert Path.dirname(Path.dirname(staged)) == outbox
      assert Path.basename(staged) == "chart.png"
      assert File.stat!(outbox).mode |> Bitwise.band(0o777) == 0o700
      refute File.exists?(staged)
      refute File.exists?(Path.dirname(staged))

      [params] = FakeHelper.calls(ctx.server, "send.file")
      assert params["to"] == @owner
      assert params["mime"] == "image/png"
      assert params["idempotency_key"] =~ ":media"
    end

    test "a caption follows the file as text", ctx do
      source = media_file(ctx.home, "a.png", "caption-#{System.unique_integer()}")
      part = %{kind: :image, path: source, mime_type: "image/png", caption: "the **chart**"}

      assert :ok = IMessage.send_media(@owner, part, ctx.opts)
      assert [%{"text" => "the chart"}] = FakeHelper.calls(ctx.server, "send.text")
    end

    test "the same media to the same chat inside the claim window is sent once", ctx do
      source = media_file(ctx.home, "same.png", "same-bytes-#{System.unique_integer()}")
      part = %{kind: :image, path: source, mime_type: "image/png"}

      assert :ok = IMessage.send_media(@owner, part, ctx.opts)
      assert :ok = IMessage.send_media(@owner, part, ctx.opts)
      assert length(FakeHelper.calls(ctx.server, "send.file")) == 1
    end

    test "a failed send releases the claim so the next attempt sends", ctx do
      source = media_file(ctx.home, "retry.png", "retry-#{System.unique_integer()}")
      part = %{kind: :image, path: source, mime_type: "image/png"}

      FakeHelper.script(ctx.server, "send.file", [
        {:error, {:helper_unavailable, "down", %{}}},
        {:ok, %{"disposition" => "recorded", "guid" => "g", "rowid" => 2}}
      ])

      assert IMessage.send_media(@owner, part, ctx.opts) ==
               {:error, {:permanent, :adapter_unavailable}}

      assert :ok = IMessage.send_media(@owner, part, ctx.opts)
      assert length(FakeHelper.calls(ctx.server, "send.file")) == 2
    end

    test "a missing source is refused as a malformed request and nothing is sent", ctx do
      part = %{kind: :image, path: Path.join(ctx.home, "absent.png"), mime_type: "image/png"}

      assert IMessage.send_media(@owner, part, ctx.opts) ==
               {:error, {:permanent, :malformed_request}}

      assert FakeHelper.calls(ctx.server, "send.file") == []
    end
  end

  describe "reply closures" do
    test "route through the helper the inbound message came from", ctx do
      {:ok, message} =
        IMessage.parse_row(row(), @dedicated, %{helper: FakeHelper, server: ctx.server})

      source = media_file(ctx.home, "reply.png", "reply-#{System.unique_integer()}")

      assert :ok = IMessage.build_text_reply(message).("reply")

      assert :ok =
               IMessage.build_media_reply(message).(%{
                 kind: :image,
                 path: source,
                 mime_type: "image/png"
               })

      assert [%{"to" => @owner, "text" => "reply"}] = FakeHelper.calls(ctx.server, "send.text")
      assert [%{"to" => @owner}] = FakeHelper.calls(ctx.server, "send.file")
    end
  end

  describe "download_attachment/2" do
    test "fetches into the inbox, converting audio and HEIC", ctx do
      audio = inbox_file(ctx.home, "0-voice.m4a")

      FakeHelper.script(ctx.server, "attachment.fetch", [
        {:ok, %{"path" => audio, "mime" => "audio/mp4", "bytes" => 5}},
        {:ok, %{"path" => audio, "mime" => "image/jpeg", "bytes" => 5}},
        {:ok, %{"path" => audio, "mime" => "image/png", "bytes" => 5}}
      ])

      message =
        inbound(ctx, [
          %{
            "index" => 0,
            "guid" => "a",
            "name" => "v.caf",
            "mime" => "audio/x-caf",
            "bytes" => 5
          },
          %{
            "index" => 1,
            "guid" => "b",
            "name" => "p.heic",
            "mime" => "image/heic",
            "bytes" => 5
          },
          %{"index" => 2, "guid" => "c", "name" => "p.png", "mime" => "image/png", "bytes" => 5}
        ])

      for attachment <- message.attachments do
        assert {:ok, ^audio} = IMessage.download_attachment(message, attachment)
      end

      assert [
               %{"message_guid" => "MSG-1", "index" => 0, "convert" => true},
               %{"message_guid" => "MSG-1", "index" => 1, "convert" => true},
               %{"message_guid" => "MSG-1", "index" => 2, "convert" => false}
             ] = FakeHelper.calls(ctx.server, "attachment.fetch")
    end

    test "a path outside this message's inbox entry is refused", ctx do
      outside = media_file(ctx.home, "elsewhere.m4a", "x")

      FakeHelper.script(
        ctx.server,
        "attachment.fetch",
        {:ok, %{"path" => outside, "mime" => "audio/mp4"}}
      )

      message =
        inbound(ctx, [
          %{"index" => 0, "guid" => "a", "name" => "v.caf", "mime" => "audio/x-caf", "bytes" => 1}
        ])

      assert {:error, {:attachment_path_refused, _reason}} =
               IMessage.download_attachment(message, hd(message.attachments))
    end

    test "a helper refusal is returned with its kind", ctx do
      FakeHelper.script(
        ctx.server,
        "attachment.fetch",
        {:error, {:attachment_not_admitted, "no", %{}}}
      )

      message =
        inbound(ctx, [
          %{"index" => 0, "guid" => "a", "name" => "v.caf", "mime" => "audio/x-caf", "bytes" => 1}
        ])

      assert {:error, {:attachment_not_admitted, "no"}} =
               IMessage.download_attachment(message, hd(message.attachments))
    end
  end

  describe "health_check/1 and the probe gate (§10.1)" do
    defmodule OkControl do
      def probe(opts) do
        send(self(), {:probed_with, opts})
        Control.decode_probe(FakeHelper.good_probe())
      end
    end

    defmodule UnconfirmedControl do
      def probe(_opts),
        do: Control.decode_probe(Map.put(FakeHelper.good_probe(), "policy", "unconfirmed"))
    end

    defmodule MissingControl do
      def probe(_opts), do: {:error, :not_installed}
    end

    defmodule OwnMacControl do
      def probe(_opts) do
        probe = Map.put(FakeHelper.good_probe(), "self_aliases", ["+1 (555) 123-4567"])
        Control.decode_probe(probe)
      end
    end

    test "is ok only when every gate is open, through the one-shot probe", ctx do
      assert {:ok, %{detail: detail, latency_ms: ms}} =
               IMessage.health_check(control: OkControl, home: ctx.home, owner: @owner)

      assert detail =~ "Fermix Messages"
      assert is_integer(ms)
      assert_received {:probed_with, [home: home]}
      assert home == ctx.home
    end

    test "names the first missing thing" do
      {:ok, good} = Control.decode_probe(FakeHelper.good_probe())

      cases = [
        {%{user_session: false}, :no_user_session},
        {%{full_disk_access: :denied}, {:permission_denied, :full_disk_access}},
        {%{db: :missing}, :db_missing},
        {%{db: :unreadable}, :db_unreadable},
        {%{db: :schema_unexpected}, :db_schema_unexpected},
        {%{policy: :absent}, :policy_absent},
        {%{policy: :unconfirmed}, :policy_unconfirmed},
        {%{automation: :not_determined}, {:permission_denied, :automation}},
        {%{signed_in: false}, :not_signed_in},
        {%{signed_in: :unknown}, :not_signed_in},
        {%{full_disk_access: :denied, policy: :absent}, {:permission_denied, :full_disk_access}}
      ]

      assert IMessage.probe_gate(good, @owner) == :ok

      for {override, class} <- cases do
        assert IMessage.probe_gate(Map.merge(good, override), @owner) == {:error, class},
               inspect(override)
      end
    end

    # The helper's own rule (owner ∈ the signed-in account's aliases), read from
    # the probe, so a tree-less Doctor names it too.
    test "an owner among the account's own aliases is this Mac's address" do
      {:ok, good} = Control.decode_probe(FakeHelper.good_probe())
      own_mac = %{good | self_aliases: ["+1 555 123 4567", "me@example.com"]}

      assert IMessage.probe_gate(own_mac, @owner) == {:error, :owner_is_this_mac}
      assert IMessage.probe_gate(own_mac, "friend@example.com") == :ok
      assert IMessage.probe_gate(%{good | self_aliases: nil}, @owner) == :ok
      assert IMessage.probe_gate(own_mac, nil) == :ok
    end

    test "names the separate Apple ID when Messages here is signed in as the owner" do
      assert IMessage.health_check(control: OwnMacControl, owner: @owner) ==
               {:error,
                {:owner_is_this_mac, "Sign Messages in with a separate Apple ID for Fermix"}}
    end

    test "returns the class and a sentence naming the remedy" do
      assert {:error, {:policy_unconfirmed, detail}} =
               IMessage.health_check(control: UnconfirmedControl, owner: @owner)

      assert detail =~ "Awaiting confirmation"
    end

    test "a helper that is not installed reports it as missing, without a daemon" do
      assert {:error, {:helper_missing, detail}} =
               IMessage.health_check(control: MissingControl, owner: @owner)

      assert detail =~ "not installed"
    end
  end

  describe "recipients_from_config/0" do
    setup do
      previous = Application.get_env(:fermix_channels, :imessage)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:fermix_channels, :imessage)
          config -> Application.put_env(:fermix_channels, :imessage, config)
        end
      end)
    end

    test "reads the normalized owner and every guest, and no account choice" do
      Application.put_env(:fermix_channels, :imessage,
        enabled: true,
        owner_user_id: "+1 (555) 123-4567",
        allowed_sender_ids: ["guest@example.com"]
      )

      assert IMessage.recipients_from_config() ==
               {:ok, %{owner: @owner, handles: [@owner, "guest@example.com"]}}
    end

    test "refuses a missing owner or an unparseable one" do
      Application.put_env(:fermix_channels, :imessage, enabled: true)
      assert {:error, :owner_not_configured} = IMessage.recipients_from_config()

      Application.put_env(:fermix_channels, :imessage, owner_user_id: "5551234567")
      assert {:error, {:invalid_handle, "5551234567"}} = IMessage.recipients_from_config()

      Application.delete_env(:fermix_channels, :imessage)
      assert {:error, :not_configured} = IMessage.recipients_from_config()
    end
  end
end
