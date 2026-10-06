defmodule FermixChannels.AdapterTelemetryTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Discord
  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.Signal
  alias FermixChannels.Channels.Slack
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.CLI

  defmodule SignalClient do
    def send_message(_account, _recipient, _text, _opts), do: :ok
    def send_attachment(_account, _recipient, _caption, _path, _opts), do: :ok
  end

  # The Fermix Messages helper's answer to a send it recorded (MILESTONE_54 §8.2).
  defmodule IMessageHelper do
    def call(_server, "send.text", _params, _timeout),
      do: {:ok, %{"disposition" => "recorded", "guid" => "sent-1", "rowid" => 1}}
  end

  @imessage_policy %{
    posture: :dedicated_account,
    owner: "+15551234567",
    handles: ["+15551234567"]
  }

  setup do
    Req.Test.set_req_test_to_shared()

    put_channel_envs()

    on_exit(fn ->
      for channel <- [:telegram, :discord, :slack, :whatsapp, :signal] do
        Application.delete_env(:fermix_channels, channel)
      end
    end)

    :ok
  end

  test "emits bounded parse telemetry for inbound adapters" do
    handler_id = attach_adapter_events(self())

    assert {:ok, [_]} = Telegram.parse_update(telegram_update())
    assert_event(:telegram, [:fermix, :channel, :parse], :ok)
    assert_message_event(:telegram, :inbound)

    assert {:ok, [_]} = Discord.parse_gateway_event(discord_event())
    assert_event(:discord, [:fermix, :channel, :parse], :ok)
    assert_message_event(:discord, :inbound)

    assert {:ok, [_]} = Slack.parse_webhook(slack_payload())
    assert_event(:slack, [:fermix, :channel, :parse], :ok)
    assert_message_event(:slack, :inbound)

    assert {:ok, [_]} = WhatsApp.parse_webhook(whatsapp_payload())
    assert_event(:whatsapp, [:fermix, :channel, :parse], :ok)
    assert_message_event(:whatsapp, :inbound)

    assert {:ok, [_]} = Signal.parse_receive_entry(signal_entry())
    assert_event(:signal, [:fermix, :channel, :parse], :ok)
    assert_message_event(:signal, :inbound)

    assert {:ok, [_]} = CLI.parse_input("hello")
    assert_event(:cli, [:fermix, :channel, :parse], :ok)
    assert_message_event(:cli, :inbound)

    assert [_] = IMessage.parse_batch([imessage_row()], @imessage_policy, %{})
    assert_event(:imessage, [:fermix, :channel, :parse], :ok)
    assert_message_event(:imessage, :inbound)

    :telemetry.detach(handler_id)
  end

  test "emits duration telemetry for adapter outbound paths" do
    handler_id = attach_adapter_events(self())
    stub_http()

    assert :ok = Telegram.send_message("123", "hello", req_options: [plug: {Req.Test, :adapter}])
    assert_event(:telegram, [:fermix, :channel, :render], :ok)
    assert_message_event(:telegram, :outbound)

    assert :ok = Discord.send_message("D1", "hello", req_options: [plug: {Req.Test, :adapter}])
    assert_message_event(:discord, :outbound)

    assert :ok = Slack.send_message("C1", "hello", req_options: [plug: {Req.Test, :adapter}])
    assert_message_event(:slack, :outbound)

    assert :ok =
             WhatsApp.send_message("15551234567", "hello",
               req_options: [plug: {Req.Test, :adapter}]
             )

    assert_message_event(:whatsapp, :outbound)

    assert :ok =
             Signal.send_message("+15551234567", "hello",
               client: SignalClient,
               client_opts: []
             )

    assert_message_event(:signal, :outbound)

    assert :ok =
             IMessage.send_message("+15551234567", "hello",
               helper: IMessageHelper,
               server: :imessage_telemetry_helper
             )

    assert_event(:imessage, [:fermix, :channel, :render], :ok)
    assert_message_event(:imessage, :outbound)

    :telemetry.detach(handler_id)
  end

  defp attach_adapter_events(test_pid) do
    handler_id = "adapter-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:fermix, :channel, :authorize],
          [:fermix, :channel, :parse],
          [:fermix, :channel, :render],
          [:fermix, :channel, :message]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:adapter_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end

  defp assert_event(channel, event, status) do
    assert_receive {:adapter_telemetry, ^event, measurements, metadata}
    assert measurements.duration_us >= 0
    assert metadata.channel == channel
    assert metadata.status == status
  end

  defp assert_message_event(channel, direction) do
    assert_receive {:adapter_telemetry, [:fermix, :channel, :message], measurements, metadata}
    assert measurements.duration_us >= 0
    assert measurements.count >= 1
    assert metadata.channel == channel
    assert metadata.direction == direction
  end

  defp put_channel_envs do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "telegram-token",
      allowed_user_ids: ["111"]
    )

    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      bot_token: "discord-token",
      bot_user_id: "999",
      allowed_user_ids: ["111"]
    )

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      bot_token: "slack-token",
      signing_secret: "secret",
      allowed_user_ids: ["U12345"]
    )

    Application.put_env(:fermix_channels, :whatsapp,
      enabled: true,
      access_token: "whatsapp-token",
      phone_number_id: "123456789",
      allowed_sender_ids: ["15551234567"]
    )

    Application.put_env(:fermix_channels, :signal,
      enabled: true,
      account: "+15550001111",
      allowed_sender_ids: ["+15551234567"],
      client: SignalClient
    )
  end

  defp stub_http do
    Req.Test.stub(:adapter, fn conn ->
      body = response_body(conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  defp response_body("/api/files.getUploadURLExternal"),
    do: %{"ok" => true, "upload_url" => "https://slack-upload.test/upload", "file_id" => "F1"}

  defp response_body("/api/files.completeUploadExternal"), do: %{"ok" => true}
  defp response_body("/api/chat.postMessage"), do: %{"ok" => true}
  defp response_body("/upload"), do: %{"ok" => true}
  defp response_body(_path), do: %{"ok" => true, "id" => "media-1"}

  defp imessage_row do
    %{
      "rowid" => 4021,
      "guid" => "telemetry-#{System.unique_integer([:positive])}",
      "chat" => %{"identifier" => "+15551234567", "service" => "iMessage", "group" => false},
      "sender" => %{"handle" => "+15551234567", "service" => "iMessage", "is_me" => false},
      "date" => "2026-10-03T12:00:00Z",
      "text" => "hello",
      "decode_error" => nil,
      "reply_to_guid" => nil,
      "attachments" => [],
      "reaction" => nil
    }
  end

  defp telegram_update do
    %{
      "message" => %{
        "message_id" => 42,
        "text" => "hello",
        "chat" => %{"id" => 123},
        "from" => %{"id" => 111, "username" => "alice"}
      }
    }
  end

  defp discord_event do
    %{
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "id" => "message-1",
        "channel_id" => "dm-channel-1",
        "content" => "hello",
        "guild_id" => nil,
        "author" => %{"id" => "111", "username" => "alice", "bot" => false},
        "attachments" => []
      }
    }
  end

  defp slack_payload do
    %{
      "type" => "event_callback",
      "team_id" => "T12345",
      "event" => %{
        "type" => "message",
        "channel" => "D12345",
        "channel_type" => "im",
        "user" => "U12345",
        "username" => "Alice",
        "text" => "hello",
        "ts" => "1714000000.000100"
      }
    }
  end

  defp whatsapp_payload do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "metadata" => %{"phone_number_id" => "123456789"},
                "contacts" => [%{"wa_id" => "15551234567", "profile" => %{"name" => "Alice"}}],
                "messages" => [
                  %{
                    "from" => "15551234567",
                    "id" => "wamid.123",
                    "timestamp" => "1714000000",
                    "type" => "text",
                    "text" => %{"body" => "hello"}
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end

  defp signal_entry do
    %{
      "envelope" => %{
        "sourceNumber" => "+15551234567",
        "sourceName" => "Alice",
        "timestamp" => 1_714_000_000_000,
        "dataMessage" => %{"message" => "hello", "timestamp" => 1_714_000_000_000}
      }
    }
  end
end
