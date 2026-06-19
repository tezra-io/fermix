defmodule FermixChannels.Gateway.AlbumBufferTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Message

  # Inject a dispatch seam that forwards to the test process, so the buffer's
  # logic is exercised without touching Gateway/MediaIngest/network. Defaults to
  # the WhatsApp channel (per-image webhooks); Telegram tests override `channel:`.
  defp start_buffer(opts) do
    test_pid = self()

    dispatch =
      Keyword.get(opts, :dispatch, fn messages, _opts ->
        send(test_pid, {:dispatched, messages})
        :ok
      end)

    defaults = [
      channel: WhatsApp,
      idempotency_key: :whatsapp,
      debounce_ms: 10_000,
      name: :"album_buffer_#{System.unique_integer([:positive])}"
    ]

    start_supervised!(
      {AlbumBuffer, Keyword.merge(defaults, opts) |> Keyword.put(:dispatch, dispatch)}
    )
  end

  defp image_message(id, wa_id, caption, opts \\ []) do
    Message.new!(%{
      id: id,
      content: caption,
      sender: "alice",
      channel: "whatsapp",
      chat_id: wa_id,
      reply_target: wa_id,
      metadata: %{
        phone_number_id: Keyword.get(opts, :phone, "biz-1"),
        sender_id: wa_id,
        user_id: wa_id
      },
      attachments: [%{kind: :image, file_id: "f-#{id}", mime_type: "image/jpeg", url: nil}]
    })
  end

  defp text_message(id, wa_id, text) do
    Message.new!(%{
      id: id,
      content: text,
      sender: "alice",
      channel: "whatsapp",
      chat_id: wa_id,
      reply_target: wa_id,
      metadata: %{phone_number_id: "biz-1", sender_id: wa_id, user_id: wa_id},
      attachments: []
    })
  end

  defp telegram_album_part(id, group_id) do
    Message.new!(%{
      id: id,
      content: "",
      sender: "alice",
      channel: "telegram",
      chat_id: "42",
      reply_target: "42",
      metadata: %{user_id: "111", media_group_id: group_id},
      attachments: [%{kind: :image, file_id: "tg-#{id}", mime_type: "image/jpeg", url: nil}]
    })
  end

  defp telegram_single(id, text) do
    Message.new!(%{
      id: id,
      content: text,
      sender: "alice",
      channel: "telegram",
      chat_id: "42",
      reply_target: "42",
      metadata: %{user_id: "111"},
      attachments: []
    })
  end

  defp buffers(pid), do: :sys.get_state(pid).buffers

  describe "WhatsApp policy (coalesce by {phone, sender}, flush on non-image)" do
    test "buffers multiple images from one sender under a single key (no flush yet)" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", "first"), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("3", "wa-1", ""), pid)

      # Cast ordering: a sync call flushes the mailbox so the casts are processed.
      state = :sys.get_state(pid)
      assert map_size(state.buffers) == 1
      assert [%{messages: messages}] = Map.values(state.buffers)
      assert length(messages) == 3
      refute_received {:dispatched, _}
    end

    test "flushes the album as ONE merged message with all attachments + joined captions" do
      pid = start_buffer(debounce_ms: 20)

      AlbumBuffer.ingest(image_message("1", "wa-1", "look at this"), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", "and this"), pid)

      assert_receive {:dispatched, [merged]}, 1_000
      assert merged.content == "look at this\nand this"
      assert length(merged.attachments) == 2
      refute_received {:dispatched, _}
    end

    test "ignores stale queued flushes after a debounce reset" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", "first"), pid)
      [key] = Map.keys(buffers(pid))

      AlbumBuffer.ingest(image_message("2", "wa-1", "second"), pid)
      send(pid, {:flush, key})

      assert [%{messages: messages}] = Map.values(buffers(pid))
      assert Enum.map(messages, & &1.id) == ["1", "2"]
      refute_received {:dispatched, _}
    end

    test "a text message flushes the pending album first, then dispatches (arrival order)" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", ""), pid)
      AlbumBuffer.ingest(text_message("3", "wa-1", "what are these?"), pid)

      assert_receive {:dispatched, [album]}, 1_000
      assert length(album.attachments) == 2

      assert_receive {:dispatched, [text]}, 1_000
      assert text.content == "what are these?"
      assert text.attachments == []
    end

    test "a lone text message dispatches immediately and is never buffered" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(text_message("1", "wa-1", "hi"), pid)

      assert_receive {:dispatched, [msg]}, 1_000
      assert msg.content == "hi"
      assert buffers(pid) == %{}
    end

    test "isolates albums per {phone_number_id, sender_id}" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("2", "wa-2", ""), pid)
      AlbumBuffer.ingest(image_message("3", "wa-1", "", phone: "biz-2"), pid)

      assert map_size(buffers(pid)) == 3
    end

    test "on flush dispatch error, forgets every buffered part id so a re-delivery can re-run" do
      # Record the ids as the controller would, then make dispatch fail; the
      # buffer must forget them (observable: check_and_record returns :fresh).
      assert Idempotency.check_and_record(:whatsapp, "wa-err-1") == :fresh
      assert Idempotency.check_and_record(:whatsapp, "wa-err-2") == :fresh

      pid =
        start_buffer(debounce_ms: 20, dispatch: fn _messages, _opts -> {:error, :boom} end)

      AlbumBuffer.ingest(image_message("wa-err-1", "wa-9", "a"), pid)
      AlbumBuffer.ingest(image_message("wa-err-2", "wa-9", "b"), pid)

      # Wait for the debounce flush to run (and forget).
      Process.sleep(120)

      assert Idempotency.check_and_record(:whatsapp, "wa-err-1") == :fresh
      assert Idempotency.check_and_record(:whatsapp, "wa-err-2") == :fresh
    end
  end

  describe "Telegram policy (coalesce by media_group_id, passthrough otherwise)" do
    test "coalesces media-group parts into one merged message with all attachments" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, debounce_ms: 20)

      AlbumBuffer.ingest(telegram_album_part("1", "alb-1"), pid)
      AlbumBuffer.ingest(telegram_album_part("2", "alb-1"), pid)

      assert_receive {:dispatched, [merged]}, 1_000
      assert length(merged.attachments) == 2
      refute_received {:dispatched, _}
    end

    test "a message without media_group_id passes through immediately, never buffered" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, debounce_ms: 10_000)

      AlbumBuffer.ingest(telegram_single("1", "hello"), pid)

      assert_receive {:dispatched, [msg]}, 1_000
      assert msg.content == "hello"
      assert buffers(pid) == %{}
    end
  end

  describe "generic bounds" do
    test "max_keys bound dispatches an over-cap sender uncoalesced (fail loud, no growth)" do
      pid = start_buffer(debounce_ms: 10_000, max_keys: 1)

      AlbumBuffer.ingest(image_message("1", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("2", "wa-2", ""), pid)

      assert_receive {:dispatched, [overflow]}, 1_000
      assert overflow.id == "2"
      assert map_size(buffers(pid)) == 1
    end

    test "debounce_ms <= 0 disables buffering (every message dispatches immediately)" do
      pid = start_buffer(debounce_ms: 0)

      AlbumBuffer.ingest(image_message("1", "wa-1", "solo"), pid)

      assert_receive {:dispatched, [msg]}, 1_000
      assert msg.id == "1"
      assert buffers(pid) == %{}
    end

    test "raises if the channel does not implement album_classify/1" do
      assert_raise ArgumentError, ~r/album_classify/, fn ->
        AlbumBuffer.init(channel: FermixChannels.Channels.Slack)
      end
    end
  end
end
