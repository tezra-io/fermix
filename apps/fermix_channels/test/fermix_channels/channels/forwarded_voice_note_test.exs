defmodule FermixChannels.Channels.ForwardedVoiceNoteTest do
  # A voice recording is the owner's own words only when the owner made it. The
  # channel declares the media as it is (`hint`: `:voice`, `:video_note`,
  # `:audio`), and separately whether the message was forwarded (`forwarded?`).
  # A forwarded recording keeps its hint, so it is processed exactly as the
  # owner's would be, but it counts as content someone else could have written
  # (`UntrustedContent`).
  # async: false — WhatsApp reads whether its ingress is on from app env.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixCore.Attachments
  alias FermixCore.Capabilities.UntrustedContent

  @outside MapSet.new([{:attachment, "attached audio"}])

  # What the gateway builds from a declared recording once transcribed: hint and
  # forwarded flag copied as declared, which decide whether it counts.
  defp sources(declared) do
    UntrustedContent.attachment_sources([
      %Attachments{
        kind: :audio,
        mime_type: "audio/ogg",
        hint: declared.hint,
        forwarded?: Map.get(declared, :forwarded?, false),
        status: :transcribed
      }
    ])
  end

  describe "Telegram" do
    defp update(media, extra) do
      %{
        "message" =>
          Map.merge(
            %{
              "message_id" => 40,
              "chat" => %{"id" => 123},
              "from" => %{"id" => 111, "username" => "alice"}
            },
            Map.merge(media, extra)
          )
      }
    end

    @voice %{"voice" => %{"file_id" => "voice-40", "duration" => 3, "file_size" => 900}}
    @video_note %{"video_note" => %{"file_id" => "note-40", "duration" => 5, "length" => 240}}
    @audio %{"audio" => %{"file_id" => "song-40", "mime_type" => "audio/mpeg"}}
    @markers [
      %{"forward_origin" => %{"type" => "user", "date" => 1_760_000_000}},
      %{"forward_from" => %{"id" => 222, "first_name" => "Brook"}},
      %{"forward_sender_name" => "Brook"},
      %{"forward_date" => 1_760_000_000}
    ]

    test "the owner's own voice note and video note are not forwarded and do not count" do
      for {media, hint} <- [{@voice, :voice}, {@video_note, :video_note}] do
        assert {:ok, [msg]} = Telegram.parse_update(update(media, %{}))
        assert [%{hint: ^hint} = declared] = msg.attachments
        refute Map.get(declared, :forwarded?, false)
        assert sources(declared) == MapSet.new()
      end
    end

    test "a forwarded voice note or video note keeps its hint, is marked, and counts" do
      for {media, hint} <- [{@voice, :voice}, {@video_note, :video_note}], marker <- @markers do
        assert {:ok, [msg]} = Telegram.parse_update(update(media, marker))
        assert [%{hint: ^hint, forwarded?: true} = declared] = msg.attachments, inspect(marker)
        assert sources(declared) == @outside
      end
    end

    test "an audio file counts, forwarded or not" do
      assert {:ok, [msg]} = Telegram.parse_update(update(@audio, %{}))
      assert [%{hint: :audio} = declared] = msg.attachments
      assert sources(declared) == @outside
    end
  end

  describe "WhatsApp" do
    setup do
      previous = Application.get_env(:fermix_channels, :whatsapp)
      Application.put_env(:fermix_channels, :whatsapp, enabled: true, mode: :webhook)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fermix_channels, :whatsapp, previous),
          else: Application.delete_env(:fermix_channels, :whatsapp)
      end)

      :ok
    end

    # The Cloud API shape: a voice note is `type: "audio"` with `audio.voice`
    # true; an audio file the owner attached has no `voice` flag.
    defp audio_webhook(audio, extra) do
      message =
        Map.merge(
          %{
            "from" => "15551234567",
            "id" => "wamid.voice",
            "timestamp" => "1760000000",
            "type" => "audio",
            "audio" => Map.merge(%{"id" => "voice-media-id", "mime_type" => "audio/ogg"}, audio)
          },
          extra
        )

      %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "waba-id",
            "changes" => [
              %{
                "field" => "messages",
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "123456789"},
                  "contacts" => [%{"wa_id" => "15551234567", "profile" => %{"name" => "Alice"}}],
                  "messages" => [message]
                }
              }
            ]
          }
        ]
      }
    end

    test "the owner's own voice note is a voice recording and does not count" do
      assert {:ok, [msg]} = WhatsApp.parse_webhook(audio_webhook(%{"voice" => true}, %{}))
      assert [%{hint: :voice} = declared] = msg.attachments
      refute Map.get(declared, :forwarded?, false)
      assert sources(declared) == MapSet.new()
    end

    test "a forwarded voice note keeps its hint, is marked, and counts" do
      for context <- [%{"forwarded" => true}, %{"frequently_forwarded" => true}] do
        webhook = audio_webhook(%{"voice" => true}, %{"context" => context})
        assert {:ok, [msg]} = WhatsApp.parse_webhook(webhook)
        assert [%{hint: :voice, forwarded?: true} = declared] = msg.attachments, inspect(context)
        assert sources(declared) == @outside
      end
    end

    test "an attached audio file is plain audio and counts" do
      assert {:ok, [msg]} = WhatsApp.parse_webhook(audio_webhook(%{}, %{}))
      assert [%{hint: :audio} = declared] = msg.attachments
      assert sources(declared) == @outside
    end
  end
end
