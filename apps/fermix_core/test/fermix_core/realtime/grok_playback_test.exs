defmodule FermixCore.Realtime.GrokPlaybackTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.GrokPlayback, as: Playback

  # Small bounds keep the arithmetic readable: 100 ms in the client, 300 ms
  # held here.
  @opts [window_ms: 100, backlog_max_ms: 300]

  describe "new/1" do
    test "defaults to a 10 s window and a 120 s backlog" do
      playback = Playback.new()

      assert playback.window_bytes == 10_000 * 48
      assert playback.backlog_max_bytes == 120_000 * 48
    end

    test "an unknown option or a bound that is not a positive integer raises" do
      assert_raise ArgumentError, fn -> Playback.new(window: 100) end
      assert_raise ArgumentError, ~r/window_ms/, fn -> Playback.new(window_ms: 0) end
      assert_raise ArgumentError, ~r/backlog_max_ms/, fn -> Playback.new(backlog_max_ms: 1.5) end
    end
  end

  describe "audio/5" do
    test "one playback id per item and content part, minted by its first chunk" do
      chunk = pcm(10)
      playback = Playback.new()

      {playback, [{"p1", ^chunk}]} = audio!(playback, "r1", "msg_1", 0, chunk)
      {playback, [{"p1", ^chunk}]} = audio!(playback, "r1", "msg_1", 0, chunk)
      {playback, [{"p2", ^chunk}]} = audio!(playback, "r1", "msg_1", 1, chunk)
      {_playback, [{"p3", ^chunk}]} = audio!(playback, "r2", "msg_2", 0, chunk)
    end

    test "forwards while the client holds less than the window, then holds in order" do
      {a, b, c, d} = {pcm(60), pcm(60), pcm(60), pcm(30)}
      playback = Playback.new(@opts)

      {playback, [{"p1", ^a}]} = audio!(playback, "r1", "msg_1", 0, a)
      # 60 ms outstanding is under the 100 ms window, so this one goes too.
      {playback, [{"p1", ^b}]} = audio!(playback, "r1", "msg_1", 0, b)
      {playback, []} = audio!(playback, "r1", "msg_1", 0, c)
      # A second playback queues behind the first: arrival order is kept.
      {playback, []} = audio!(playback, "r1", "msg_2", 0, d)

      # 120 forwarded − 50 played = 70 ms outstanding: room for one chunk.
      {playback, [{"p1", ^c}]} = progress!(playback, "p1", 50, false)
      {playback, []} = progress!(playback, "p1", 60, false)
      {_playback, [{"p2", ^d}]} = progress!(playback, "p1", 120, false)
    end

    test "a backlog past its bound is an overflow, and the state it was given is unchanged" do
      playback = Playback.new(@opts)
      {playback, [_sent]} = audio!(playback, "r1", "msg_1", 0, pcm(100))
      {playback, []} = audio!(playback, "r1", "msg_1", 0, pcm(200))
      {playback, []} = audio!(playback, "r1", "msg_1", 0, pcm(100))

      assert Playback.audio(playback, "r1", "msg_1", 0, pcm(1)) == {:error, :overflow}
      # A new item would have minted an id; the overflow keeps the mint too.
      assert Playback.audio(playback, "r1", "msg_2", 0, pcm(1)) == {:error, :overflow}

      {_playback, [{"p1", _chunk} | _rest]} = progress!(playback, "p1", 100, true)
    end

    test "audio that is not base64 PCM16 is invalid" do
      playback = Playback.new()

      assert Playback.audio(playback, "r1", "msg_1", 0, "not base64!") == {:error, :invalid_audio}

      assert Playback.audio(playback, "r1", "msg_1", 0, Base.encode64(<<1, 2, 3>>)) ==
               {:error, :invalid_audio}
    end

    test "an empty chunk carries nothing, sends nothing and mints nothing" do
      playback = Playback.new()

      assert {:ok, ^playback, []} = Playback.audio(playback, "r1", "msg_1", 0, "")

      {_playback, [{"p1", _chunk}]} = audio!(playback, "r1", "msg_1", 0, pcm(1))
    end
  end

  describe "progress/4" do
    test "an id never sent is unknown" do
      assert Playback.progress(Playback.new(), "p1", 0, false) == {:error, :unknown_playback}
    end

    test "an offset that moves backwards is refused" do
      {playback, _sent} = audio!(Playback.new(), "r1", "msg_1", 0, pcm(50))
      {playback, []} = progress!(playback, "p1", 30, false)

      assert Playback.progress(playback, "p1", 20, false) == {:error, :playback_regressed}
      assert {:ok, _playback, []} = Playback.progress(playback, "p1", 30, false)
    end

    # 482 bytes is 10.04 ms, so the client may round up to 11 but no further.
    test "an offset past the audio forwarded for the id is refused" do
      chunk = Base.encode64(:binary.copy(<<0>>, 482))
      {playback, _sent} = audio!(Playback.new(), "r1", "msg_1", 0, chunk)

      assert {:ok, _playback, []} = Playback.progress(playback, "p1", 11, false)
      assert Playback.progress(playback, "p1", 12, false) == {:error, :playback_beyond_sent}
    end

    test "held audio is not sent audio" do
      playback = Playback.new(@opts)
      {playback, [_sent]} = audio!(playback, "r1", "msg_1", 0, pcm(100))
      {playback, []} = audio!(playback, "r1", "msg_1", 0, pcm(50))

      assert Playback.progress(playback, "p1", 101, false) == {:error, :playback_beyond_sent}
    end

    test "drained settles a playback until more is forwarded for it" do
      chunk = Base.encode64(:binary.copy(<<0>>, 482))
      {playback, _sent} = audio!(Playback.new(), "r1", "msg_1", 0, chunk)

      assert Playback.awaiting_ack?(playback)
      refute Playback.drained?(playback)

      # The client rounds 10.04 ms down; drained still covers every byte.
      {playback, []} = progress!(playback, "p1", 10, true)
      refute Playback.awaiting_ack?(playback)
      assert Playback.drained?(playback)

      {playback, [_sent]} = audio!(playback, "r1", "msg_1", 0, pcm(20))
      assert Playback.awaiting_ack?(playback)
      refute Playback.drained?(playback)

      # 30 ms is 1_440 of the 1_442 bytes sent: the last fraction of a
      # millisecond stays awaited until the client reports the drain.
      {playback, []} = progress!(playback, "p1", 30, false)
      assert Playback.awaiting_ack?(playback)

      {playback, []} = progress!(playback, "p1", 30, true)
      refute Playback.awaiting_ack?(playback)
      assert Playback.drained?(playback)
    end

    test "a played offset short of what was sent is still awaited" do
      {playback, _sent} = audio!(Playback.new(), "r1", "msg_1", 0, pcm(50))
      {playback, []} = progress!(playback, "p1", 49, false)

      assert Playback.awaiting_ack?(playback)
      {playback, []} = progress!(playback, "p1", 50, false)
      refute Playback.awaiting_ack?(playback)
    end

    test "a drain releases held audio, so the tracker is not drained while any is held" do
      playback = Playback.new(@opts)
      {playback, [_first]} = audio!(playback, "r1", "msg_1", 0, pcm(120))
      held = pcm(60)
      {playback, []} = audio!(playback, "r1", "msg_1", 0, held)

      {playback, [{"p1", ^held}]} = progress!(playback, "p1", 120, true)

      refute Playback.drained?(playback)
      assert Playback.awaiting_ack?(playback)
    end
  end

  describe "stop/1" do
    test "fences every live playback and returns a target for each one not heard to its end" do
      playback = Playback.new(@opts)
      # p1 heard to its end, p2 partly played, p3 entirely held.
      {playback, [_p1]} = audio!(playback, "r1", "msg_1", 0, pcm(20))
      {playback, []} = progress!(playback, "p1", 20, true)
      {playback, [_p2]} = audio!(playback, "r2", "msg_2", 0, pcm(80))
      {playback, [_p2_more]} = audio!(playback, "r2", "msg_2", 0, pcm(80))
      # 160 forwarded − 30 played is still past the window.
      {playback, []} = progress!(playback, "p2", 30, false)
      {playback, []} = audio!(playback, "r2", "msg_3", 1, pcm(40))

      {playback, targets} = Playback.stop(playback)

      assert targets == [
               %{item_id: "msg_2", content_index: 0, played_ms: 30},
               %{item_id: "msg_3", content_index: 1, played_ms: 0}
             ]

      assert Playback.drained?(playback)
      refute Playback.awaiting_ack?(playback)
    end

    test "late chunks of a stopped playback or its response are dropped" do
      {playback, _sent} = audio!(Playback.new(), "r1", "msg_1", 0, pcm(20))
      {playback, [_target]} = Playback.stop(playback)

      assert {:ok, ^playback, []} = Playback.audio(playback, "r1", "msg_1", 0, pcm(20))
      # A new item of the stopped response, too.
      assert {:ok, ^playback, []} = Playback.audio(playback, "r1", "msg_9", 0, pcm(20))
      # Dropped unexamined: a late chunk is never an error.
      assert {:ok, ^playback, []} = Playback.audio(playback, "r1", "msg_1", 0, "not base64!")

      {_playback, [{"p2", _chunk}]} = audio!(playback, "r2", "msg_2", 0, pcm(20))
    end

    # The client reports immediately on stop, after the daemon has fenced.
    test "a fenced playback still takes the client's final report, checked the same way" do
      {playback, _sent} = audio!(Playback.new(), "r1", "msg_1", 0, pcm(50))
      {playback, []} = progress!(playback, "p1", 20, false)
      {playback, _targets} = Playback.stop(playback)

      assert {:ok, playback, []} = Playback.progress(playback, "p1", 35, true)
      assert Playback.progress(playback, "p1", 30, false) == {:error, :playback_regressed}
      assert Playback.progress(playback, "p1", 51, false) == {:error, :playback_beyond_sent}
    end

    test "a stop with nothing live returns no targets" do
      assert {%Playback{}, []} = Playback.stop(Playback.new())
    end
  end

  describe "fence_response/2" do
    test "drops the response's later and held chunks, and keeps its forwarded audio awaited" do
      playback = Playback.new(@opts)
      {playback, [_p1]} = audio!(playback, "r1", "msg_1", 0, pcm(100))
      {playback, []} = audio!(playback, "r1", "msg_1", 0, pcm(60))
      other = pcm(30)
      {playback, []} = audio!(playback, "r2", "msg_2", 0, other)

      playback = Playback.fence_response(playback, "r1")

      assert {:ok, ^playback, []} = Playback.audio(playback, "r1", "msg_1", 0, pcm(10))
      assert {:ok, ^playback, []} = Playback.audio(playback, "r1", "msg_5", 0, pcm(10))
      assert Playback.awaiting_ack?(playback)

      # The held r1 chunk is gone; the held r2 chunk is next once there is room.
      {playback, [{"p2", ^other}]} = progress!(playback, "p1", 100, true)
      assert Playback.awaiting_ack?(playback)
    end

    test "fencing leaves other responses alone" do
      playback = Playback.fence_response(Playback.new(), "r1")

      {_playback, [{"p1", _chunk}]} = audio!(playback, "r2", "msg_2", 0, pcm(10))
    end

    test "only the most recent 64 fences are remembered" do
      playback = Enum.reduce(1..65, Playback.new(), &Playback.fence_response(&2, "r#{&1}"))

      {_playback, [{"p1", _chunk}]} = audio!(playback, "r1", "msg_1", 0, pcm(1))
      assert {:ok, _playback, []} = Playback.audio(playback, "r2", "msg_2", 0, pcm(1))
    end
  end

  describe "bounded records" do
    test "past 64 playbacks the oldest settled one is forgotten" do
      playback = Enum.reduce(1..64, Playback.new(), &settled_playback(&2, &1))

      {playback, [{"p65", _chunk}]} = audio!(playback, "r65", "msg_65", 0, pcm(1))

      assert Playback.progress(playback, "p1", 1, true) == {:error, :unknown_playback}
      assert {:ok, _playback, []} = Playback.progress(playback, "p2", 1, true)
    end

    test "with every record still unplayed, a new playback is an overflow" do
      playback =
        Enum.reduce(1..64, Playback.new(), fn n, acc ->
          {acc, [_sent]} = audio!(acc, "r#{n}", "msg_#{n}", 0, pcm(1))
          acc
        end)

      assert Playback.audio(playback, "r65", "msg_65", 0, pcm(1)) == {:error, :overflow}

      {playback, []} = progress!(playback, "p7", 1, true)
      {playback, [{"p65", _chunk}]} = audio!(playback, "r65", "msg_65", 0, pcm(1))
      assert Playback.progress(playback, "p7", 1, true) == {:error, :unknown_playback}
    end

    test "a stopped playback counts as settled" do
      playback =
        Enum.reduce(1..64, Playback.new(), fn n, acc ->
          {acc, [_sent]} = audio!(acc, "r#{n}", "msg_#{n}", 0, pcm(1))
          acc
        end)

      {playback, targets} = Playback.stop(playback)
      assert length(targets) == 64

      {_playback, [{"p65", _chunk}]} = audio!(playback, "r65", "msg_65", 0, pcm(1))
    end
  end

  # PCM16 at 24 kHz mono: 48 bytes per millisecond.
  defp pcm(ms), do: Base.encode64(:binary.copy(<<0, 0>>, ms * 24))

  defp audio!(playback, response_id, item_id, content_index, base64) do
    assert {:ok, playback, sent} =
             Playback.audio(playback, response_id, item_id, content_index, base64)

    {playback, sent}
  end

  defp progress!(playback, id, played_ms, drained?) do
    assert {:ok, playback, sent} = Playback.progress(playback, id, played_ms, drained?)
    {playback, sent}
  end

  defp settled_playback(playback, n) do
    {playback, [{id, _chunk}]} = audio!(playback, "r#{n}", "msg_#{n}", 0, pcm(1))
    {playback, []} = progress!(playback, id, 1, true)
    playback
  end
end
