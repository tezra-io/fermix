defmodule FermixCore.Transcription.OutboxTest do
  # async: true — the outbox is a pure struct; nothing here touches process or
  # global state.
  use ExUnit.Case, async: true

  alias FermixCore.Transcription.Outbox

  @inflight_cap Outbox.inflight_max_bytes()
  @buffer_cap Outbox.buffer_max_bytes()

  describe "push/3 onto a socket that can take audio" do
    test "casts while the in-flight window has room, counting the bytes as in flight" do
      pcm = :binary.copy(<<0, 1>>, 8)

      assert {:cast, ^pcm, outbox} = Outbox.push(Outbox.new(), pcm, true)
      assert outbox.inflight_bytes == byte_size(pcm)
      assert outbox.buffer_bytes == 0
    end

    test "holds instead of casting once the window is full" do
      outbox = fill_window(Outbox.new())
      assert Outbox.window_full?(outbox)

      assert {:held, held} = Outbox.push(outbox, <<1, 2>>, true)
      assert held.buffer_bytes == 2
      assert held.inflight_bytes == @inflight_cap
    end

    test "never casts past audio that is already waiting" do
      # A reopened window does not license a later chunk to overtake a held one:
      # that would reorder the stream the vendor is transcribing.
      {:held, held} = Outbox.push(fill_window(Outbox.new()), <<1, 2>>, true)

      assert {:held, outbox} = Outbox.push(%{held | inflight_bytes: 0}, <<3, 4>>, true)
      assert outbox.buffer_bytes == 4
    end
  end

  describe "push/3 with nowhere to send" do
    test "holds every chunk, whatever the window says" do
      assert {:held, outbox} = Outbox.push(Outbox.new(), <<1, 2>>, false)
      assert outbox.buffer_bytes == 2
      assert outbox.inflight_bytes == 0
    end

    test "drops and counts what will not fit, keeping the audio already held" do
      {:held, full} = Outbox.push(Outbox.new(), :binary.copy(<<0>>, @buffer_cap), false)

      assert {:dropped, outbox} = Outbox.push(full, :binary.copy(<<1>>, 32_000), false)
      assert outbox.dropped_bytes == 32_000
      assert outbox.buffer_bytes == @buffer_cap

      assert {:dropped, outbox} = Outbox.push(outbox, :binary.copy(<<2>>, 1_000), false)
      assert outbox.dropped_bytes == 33_000
    end
  end

  describe "acked/2" do
    test "credits the bytes the socket reported written" do
      {:cast, _pcm, outbox} = Outbox.push(Outbox.new(), :binary.copy(<<0>>, 100), true)

      assert {:ok, credited} = Outbox.acked(outbox, 100)
      assert credited.inflight_bytes == 0
    end

    test "reopens the window and hands back the held audio in one flush" do
      outbox = fill_window(Outbox.new())
      {:held, outbox} = Outbox.push(outbox, <<1, 2>>, true)
      {:held, outbox} = Outbox.push(outbox, <<3, 4>>, true)

      assert {:flush, <<1, 2, 3, 4>>, flushed} = Outbox.acked(outbox, @inflight_cap)
      assert flushed.buffer_bytes == 0
      # The flush is itself in flight until the socket acknowledges it.
      assert flushed.inflight_bytes == 4
    end

    test "keeps holding while a credit leaves the window full" do
      # A reconnect flush puts more than one window's worth in flight at once, so
      # a single ack does not necessarily reopen anything.
      {:cast, _pcm, outbox} =
        Outbox.push(Outbox.new(), :binary.copy(<<0>>, @inflight_cap * 2), true)

      {:held, outbox} = Outbox.push(outbox, <<1, 2>>, true)

      assert {:ok, still_full} = Outbox.acked(outbox, @inflight_cap)
      assert still_full.buffer_bytes == 2
      assert Outbox.window_full?(still_full)
    end

    test "an over-credit cannot drive the window negative" do
      assert {:ok, outbox} = Outbox.acked(Outbox.new(), 500)
      assert outbox.inflight_bytes == 0
    end
  end

  describe "flush/1" do
    test "empties the buffer into one binary and counts it in flight" do
      {:held, outbox} = Outbox.push(Outbox.new(), <<1, 2>>, false)
      {:held, outbox} = Outbox.push(outbox, <<3>>, false)

      assert {:flush, <<1, 2, 3>>, flushed} = Outbox.flush(outbox)
      assert flushed.buffer_bytes == 0
      assert flushed.inflight_bytes == 3
    end

    test "reports an empty buffer rather than a zero-length frame" do
      assert {:empty, %Outbox{}} = Outbox.flush(Outbox.new())
    end
  end

  describe "disconnected/1" do
    test "forgets the window and keeps what the stream still owes" do
      outbox = fill_window(Outbox.new())
      {:held, outbox} = Outbox.push(outbox, <<9>>, true)

      reset = Outbox.disconnected(outbox)

      # The socket that owed those acks is gone; the audio it never took is not.
      assert reset.inflight_bytes == 0
      assert reset.buffer_bytes == 1
    end
  end

  describe "guards" do
    test "reject a non-binary chunk, a non-boolean sendability, and an empty credit" do
      assert_raise FunctionClauseError, fn -> Outbox.push(Outbox.new(), :pcm, true) end
      assert_raise FunctionClauseError, fn -> Outbox.push(Outbox.new(), <<1>>, :maybe) end
      assert_raise FunctionClauseError, fn -> Outbox.acked(Outbox.new(), 0) end
    end
  end

  defp fill_window(outbox) do
    {:cast, _pcm, filled} = Outbox.push(outbox, :binary.copy(<<0>>, @inflight_cap), true)
    filled
  end
end
