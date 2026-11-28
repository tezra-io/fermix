defmodule FermixChannels.Gateway.AlbumBufferTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Test.AlbumBufferIdle
  alias FermixTestSupport.TelemetryCapture

  # Inject a dispatch seam that forwards to the test process, so the buffer's
  # logic is exercised without touching Gateway/Attachments/network. Defaults to
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
      attachments: [%{hint: :photo, file_id: "f-#{id}", mime_type: "image/jpeg", url: nil}]
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
      attachments: [%{hint: :photo, file_id: "tg-#{id}", mime_type: "image/jpeg", url: nil}]
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

  defp telegram_text(id, text, chat_id, thread_ts \\ nil) do
    Message.new!(%{
      id: id,
      content: text,
      sender: "alice",
      channel: "telegram",
      chat_id: chat_id,
      reply_target: chat_id,
      thread_ts: thread_ts,
      metadata: %{user_id: "111"},
      attachments: []
    })
  end

  # A dispatch that tells the test it entered, naming the message and its own
  # process, then holds until the test releases it with the result it should
  # return (`:ok`, `{:error, reason}`), a raise (`:raise`) or an exit
  # (`{:exit, reason}`). Released by a message, never by time; a hold the test
  # never releases ends with the buffer, which stops every dispatch it started.
  defp held_dispatch(test_pid) do
    fn [message], _opts ->
      send(test_pid, {:entered, message.id, self()})

      receive do
        {:release, :raise} -> raise "dispatch bug"
        {:release, {:exit, reason}} -> exit(reason)
        {:release, result} -> result
      end
    end
  end

  defp release(dispatch, result \\ :ok), do: send(dispatch, {:release, result})

  defp buffers(pid), do: :sys.get_state(pid).buffers

  # What the lanes hold once the buffer has handled every message the test sent
  # it so far: the dispatches running and the deliveries waiting.
  defp lanes(pid) do
    state = :sys.get_state(pid)
    %{running: map_size(state.tasks), waiting: state.lanes.waiting_count}
  end

  # An id no other test records, as a webhook controller would record it.
  defp recorded_id(prefix) do
    id = "#{prefix}-#{System.unique_integer([:positive])}"
    assert Idempotency.check_and_record(:whatsapp, id) == :fresh
    id
  end

  describe "ingress lanes (one conversation in order, conversations side by side)" do
    test "another chat's message is dispatched while one chat's dispatch is held" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(telegram_text("a1", "a slow album's turn", "100"), pid)
      assert_receive {:entered, "a1", held_a}

      AlbumBuffer.ingest(telegram_text("b1", "hello", "200"), pid)
      assert_receive {:entered, "b1", held_b}

      release(held_a)
      release(held_b)
    end

    test "WhatsApp: a trailing text flushes the album first and waits for its dispatch to end" do
      pid = start_buffer(dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(image_message("1", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", ""), pid)
      AlbumBuffer.ingest(text_message("3", "wa-1", "what are these?"), pid)

      # The merged album keeps its first part's id.
      assert_receive {:entered, "1", album}
      assert lanes(pid) == %{running: 1, waiting: 1}
      refute_received {:entered, "3", _dispatch}

      release(album)
      assert_receive {:entered, "3", text}
      release(text)
    end

    test "Telegram: a slow album holds its own chat's next message, not another chat's" do
      pid =
        start_buffer(
          channel: Telegram,
          idempotency_key: nil,
          debounce_ms: 20,
          dispatch: held_dispatch(self())
        )

      AlbumBuffer.ingest(telegram_album_part("1", "alb-1"), pid)
      AlbumBuffer.ingest(telegram_album_part("2", "alb-1"), pid)
      assert_receive {:entered, "1", album}

      AlbumBuffer.ingest(telegram_single("3", "and these?"), pid)
      AlbumBuffer.ingest(telegram_text("4", "hello", "77"), pid)
      assert_receive {:entered, "4", other_chat}
      assert lanes(pid) == %{running: 2, waiting: 1}
      refute_received {:entered, "3", _dispatch}

      release(album)
      assert_receive {:entered, "3", text}
      release(text)
      release(other_chat)
    end

    test "Telegram: a message without a group still passes an album that is buffering" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(telegram_album_part("1", "alb-1"), pid)
      AlbumBuffer.ingest(telegram_single("2", "hello"), pid)

      assert_receive {:entered, "2", text}
      assert map_size(buffers(pid)) == 1
      release(text)
    end

    test "two threads of one chat run side by side, and each thread keeps its order" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(telegram_text("t7-1", "first in topic 7", "42", 7), pid)
      assert_receive {:entered, "t7-1", topic_7}

      AlbumBuffer.ingest(telegram_text("t9-1", "first in topic 9", "42", 9), pid)
      assert_receive {:entered, "t9-1", topic_9}

      # The same topic, its id spelled as a string: one conversation, one lane.
      AlbumBuffer.ingest(telegram_text("t7-2", "second in topic 7", "42", "7"), pid)
      assert lanes(pid) == %{running: 2, waiting: 1}
      refute_received {:entered, "t7-2", _dispatch}

      release(topic_7)
      assert_receive {:entered, "t7-2", topic_7_again}
      release(topic_9)
      release(topic_7_again)
    end

    test "messages that name no conversation share one lane, in order, beside the others" do
      pid = start_buffer(dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(%{id: "bad-1"}, pid)
      assert_receive {:entered, "bad-1", first_bad}

      AlbumBuffer.ingest(%{id: "bad-2"}, pid)
      AlbumBuffer.ingest(text_message("ok-1", "wa-ok", "hi"), pid)
      assert_receive {:entered, "ok-1", good}
      assert lanes(pid) == %{running: 2, waiting: 1}

      release(first_bad)
      assert_receive {:entered, "bad-2", second_bad}
      release(good)
      release(second_bad)
    end

    test "a chat's album flushes on its debounce while another chat's dispatch is held" do
      pid = start_buffer(debounce_ms: 20, dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(text_message("h1", "wa-h", "held"), pid)
      assert_receive {:entered, "h1", held}

      AlbumBuffer.ingest(image_message("p1", "wa-p", "a picture"), pid)
      AlbumBuffer.ingest(image_message("p2", "wa-p", "another"), pid)
      assert_receive {:entered, "p1", album}

      release(held)
      release(album)
    end
  end

  describe "a dispatch that dies" do
    test "a raise ends only its task" do
      assert_death_contained(:raise)
    end

    test "an exit ends only its task" do
      assert_death_contained({:exit, :ingest_gone})
    end

    test "a dispatch that answers neither :ok nor an error settles as a failed one" do
      part = recorded_id("wa-odd")
      pid = start_buffer(dispatch: held_dispatch(self()))

      log =
        capture_log(fn ->
          AlbumBuffer.ingest(text_message(part, "wa-odd", "first"), pid)
          assert_receive {:entered, ^part, first}
          AlbumBuffer.ingest(text_message("odd-2", "wa-odd", "second"), pid)
          release(first, :maybe)
          assert_receive {:entered, "odd-2", second}
          release(second)
        end)

      assert log =~ "dispatch failed: {:unexpected_dispatch_result, :maybe}"
      assert Idempotency.check_and_record(:whatsapp, part) == :fresh
    end

    test "an answer or a death from a dispatch the buffer is not running is logged loudly" do
      pid = start_buffer([])

      log =
        capture_log(fn ->
          send(pid, {make_ref(), :ok})
          send(pid, {:DOWN, make_ref(), :process, self(), :killed})
          :sys.get_state(pid)
        end)

      assert [_answer, _death] = Regex.scan(~r/a dispatch it is not running/, log)
      assert log =~ ":ingress_exit, :killed"
      assert lanes(pid) == %{running: 0, waiting: 0}
    end
  end

  # Chat A's dispatch dies while A's next message waits behind it and chat B
  # has an album part buffered. The buffer that started the dispatch is the one
  # still serving: A's ids are forgotten, A's lane moves on, B's part flushes.
  defp assert_death_contained(death) do
    a_first = recorded_id("wa-death-a1")
    a_next = recorded_id("wa-death-a2")
    b_part = recorded_id("wa-death-b1")
    pid = start_buffer(dispatch: held_dispatch(self()))

    AlbumBuffer.ingest(image_message(b_part, "wa-b", "b's picture"), pid)
    AlbumBuffer.ingest(text_message(a_first, "wa-a", "first"), pid)
    assert_receive {:entered, ^a_first, first}
    AlbumBuffer.ingest(text_message(a_next, "wa-a", "second"), pid)
    assert lanes(pid) == %{running: 1, waiting: 1}

    log =
      capture_log(fn ->
        release(first, death)
        assert_receive {:entered, ^a_next, next}
        release(next)
      end)

    assert log =~ "album-buffer dispatch failed: {:ingress_exit"
    assert Idempotency.check_and_record(:whatsapp, a_first) == :fresh
    assert Idempotency.check_and_record(:whatsapp, a_next) == :duplicate

    # B's part survived in the same buffer; its debounce expiry, by hand.
    assert [{key, %{messages: [%{id: ^b_part}], token: token}}] = Map.to_list(buffers(pid))
    send(pid, {:flush, key, token})
    assert_receive {:entered, ^b_part, b_album}
    release(b_album)
  end

  describe "bounds" do
    test "at max_active further conversations wait, then start in order as slots free" do
      pid = start_buffer(dispatch: held_dispatch(self()), max_active: 2, max_waiting: 10)

      for chat <- ~w(c1 c2 c3 c4), do: AlbumBuffer.ingest(text_message(chat, chat, "hi"), pid)

      assert_receive {:entered, "c1", c1}
      assert_receive {:entered, "c2", c2}
      assert lanes(pid) == %{running: 2, waiting: 2}

      release(c1)
      assert_receive {:entered, next, c3}
      assert next == "c3"

      release(c2)
      assert_receive {:entered, "c4", c4}
      release(c3)
      release(c4)
    end

    test "past max_waiting a delivery is refused, logged, counted and forgotten; a re-delivery runs" do
      TelemetryCapture.attach([[:fermix, :dispatcher, :ingress_failed]],
        reason: :ingress_lanes_full
      )

      refused = recorded_id("wa-full")
      pid = start_buffer(dispatch: held_dispatch(self()), max_active: 1, max_waiting: 1)

      AlbumBuffer.ingest(text_message("f1", "wa-f1", "runs"), pid)
      assert_receive {:entered, "f1", first}
      AlbumBuffer.ingest(text_message("f2", "wa-f2", "waits"), pid)

      log =
        capture_log(fn ->
          AlbumBuffer.ingest(text_message(refused, "wa-f3", "refused"), pid)
          # The refusal, its forget included, runs in the cast's handler.
          :sys.get_state(pid)
        end)

      assert log =~ "#{inspect(WhatsApp)} album buffer refused a delivery"
      assert log =~ "max_waiting 1 reached, max_active 1"
      assert log =~ "dispatch failed: :ingress_lanes_full; forgetting 1 message id(s)"

      assert_receive {:telemetry, [:fermix, :dispatcher, :ingress_failed], %{count: 1},
                      %{channel: "whatsapp", reason: :ingress_lanes_full}}

      assert lanes(pid) == %{running: 1, waiting: 1}

      # WhatsApp sends it again: its id is fresh, and it runs once there is room.
      assert Idempotency.check_and_record(:whatsapp, refused) == :fresh
      release(first)
      assert_receive {:entered, "f2", second}
      AlbumBuffer.ingest(text_message(refused, "wa-f3", "refused"), pid)
      release(second)
      assert_receive {:entered, ^refused, again}
      release(again)
    end
  end

  describe "shutdown" do
    test "stopping the buffer stops every dispatch in flight" do
      pid = start_buffer(dispatch: held_dispatch(self()))

      AlbumBuffer.ingest(text_message("s1", "wa-s1", "held"), pid)
      AlbumBuffer.ingest(text_message("s2", "wa-s2", "held too"), pid)
      assert_receive {:entered, "s1", one}
      assert_receive {:entered, "s2", two}
      %{task_supervisor: task_supervisor} = :sys.get_state(pid)

      watched =
        for process <- [one, two, task_supervisor], do: {Process.monitor(process), process}

      :ok = stop_supervised!(AlbumBuffer)

      for {ref, process} <- watched do
        assert_receive {:DOWN, ^ref, :process, ^process, _reason}
      end
    end
  end

  describe "WhatsApp policy (coalesce by {phone, sender}, flush on non-image)" do
    test "buffers multiple images from one sender under a single key (no flush yet)" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", "first"), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("3", "wa-1", ""), pid)

      # The casts are handled and no dispatch is left in flight once this returns.
      state = AlbumBufferIdle.await_dispatches_done(pid)
      assert map_size(state.buffers) == 1
      assert [%{messages: messages}] = Map.values(state.buffers)
      assert length(messages) == 3
      refute_received {:dispatched, _}
    end

    test "flushes the album as ONE merged message with all attachments + joined captions" do
      pid = start_buffer(debounce_ms: 20)

      AlbumBuffer.ingest(image_message("1", "wa-1", "look at this"), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", "and this"), pid)

      assert_receive {:dispatched, [merged]}
      assert merged.content == "look at this\nand this"
      assert length(merged.attachments) == 2
      # No dispatch in flight and no part left to flush later.
      assert AlbumBufferIdle.await_dispatches_done(pid).buffers == %{}
      refute_received {:dispatched, _}
    end

    # The channel marks a forwarded part and each of its attachments; the album
    # it joins is forwarded, and every attachment keeps its own part's mark.
    test "an album with a forwarded part is forwarded, each attachment keeping its own mark" do
      pid = start_buffer(debounce_ms: 20)

      forwarded = Message.mark_forwarded(image_message("2", "wa-1", "and this"), true)

      AlbumBuffer.ingest(image_message("1", "wa-1", "look at this"), pid)
      AlbumBuffer.ingest(forwarded, pid)

      assert_receive {:dispatched, [merged]}
      assert merged.metadata.forwarded
      assert merged.content == "look at this\n[forwarded message]\nand this"
      assert [false, true] = Enum.map(merged.attachments, &Map.get(&1, :forwarded?, false))
    end

    test "ignores stale queued flushes after a debounce reset" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", "first"), pid)
      [key] = Map.keys(buffers(pid))

      AlbumBuffer.ingest(image_message("2", "wa-1", "second"), pid)
      send(pid, {:flush, key})

      state = AlbumBufferIdle.await_dispatches_done(pid)
      assert [%{messages: messages}] = Map.values(state.buffers)
      assert Enum.map(messages, & &1.id) == ["1", "2"]
      refute_received {:dispatched, _}
    end

    test "a text message flushes the pending album first, then dispatches (arrival order)" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(image_message("1", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("2", "wa-1", ""), pid)
      AlbumBuffer.ingest(text_message("3", "wa-1", "what are these?"), pid)

      assert_receive {:dispatched, [album]}
      assert length(album.attachments) == 2

      assert_receive {:dispatched, [text]}
      assert text.content == "what are these?"
      assert text.attachments == []
    end

    test "a lone text message dispatches immediately and is never buffered" do
      pid = start_buffer(debounce_ms: 10_000)

      AlbumBuffer.ingest(text_message("1", "wa-1", "hi"), pid)

      assert_receive {:dispatched, [msg]}
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
      first = recorded_id("wa-err-1")
      second = recorded_id("wa-err-2")
      test_pid = self()

      # Each dispatch signals the test the moment it runs, so we synchronize on
      # the real flush instead of guessing a delay. The album's fails; the
      # chat's next message dispatches fine.
      dispatch = fn [message], _opts ->
        send(test_pid, {:flush_dispatched, message.id})
        if message.id == "wa-err-3", do: :ok, else: {:error, :boom}
      end

      pid = start_buffer(debounce_ms: 20, dispatch: dispatch)

      log =
        capture_log(fn ->
          AlbumBuffer.ingest(image_message(first, "wa-9", "a"), pid)
          AlbumBuffer.ingest(image_message(second, "wa-9", "b"), pid)
          assert_receive {:flush_dispatched, ^first}

          # The barrier: a chat's next delivery starts only after the one before
          # it settled, and a failed dispatch settles by forgetting its ids (a
          # synchronous call into Idempotency), so once this one runs they are
          # gone.
          AlbumBuffer.ingest(text_message("wa-err-3", "wa-9", "and these?"), pid)
          assert_receive {:flush_dispatched, "wa-err-3"}
        end)

      assert log =~ "dispatch failed: :boom; forgetting 2 message id(s)"

      assert Idempotency.check_and_record(:whatsapp, first) == :fresh
      assert Idempotency.check_and_record(:whatsapp, second) == :fresh
    end
  end

  describe "Telegram policy (coalesce by media_group_id, passthrough otherwise)" do
    test "coalesces media-group parts into one merged message with all attachments" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, debounce_ms: 20)

      AlbumBuffer.ingest(telegram_album_part("1", "alb-1"), pid)
      AlbumBuffer.ingest(telegram_album_part("2", "alb-1"), pid)

      assert_receive {:dispatched, [merged]}
      assert length(merged.attachments) == 2
      # No dispatch in flight and no part left to flush later.
      assert AlbumBufferIdle.await_dispatches_done(pid).buffers == %{}
      refute_received {:dispatched, _}
    end

    test "a message without media_group_id passes through immediately, never buffered" do
      pid = start_buffer(channel: Telegram, idempotency_key: nil, debounce_ms: 10_000)

      AlbumBuffer.ingest(telegram_single("1", "hello"), pid)

      assert_receive {:dispatched, [msg]}
      assert msg.content == "hello"
      assert buffers(pid) == %{}
    end
  end

  describe "generic bounds" do
    test "max_keys bound dispatches an over-cap sender uncoalesced (fail loud, no growth)" do
      pid = start_buffer(debounce_ms: 10_000, max_keys: 1)

      AlbumBuffer.ingest(image_message("1", "wa-1", ""), pid)
      AlbumBuffer.ingest(image_message("2", "wa-2", ""), pid)

      assert_receive {:dispatched, [overflow]}
      assert overflow.id == "2"
      assert map_size(buffers(pid)) == 1
    end

    test "debounce_ms <= 0 disables buffering (every message dispatches immediately)" do
      pid = start_buffer(debounce_ms: 0)

      AlbumBuffer.ingest(image_message("1", "wa-1", "solo"), pid)

      assert_receive {:dispatched, [msg]}
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
