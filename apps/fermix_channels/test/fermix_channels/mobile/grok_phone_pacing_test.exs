defmodule FermixChannels.Mobile.GrokPhonePacingTest do
  @moduledoc """
  A Grok reply on a phone's call, paced end to end (M87 §06): the Grok
  session's playback window (`GrokPlayback`, sized by the call's endpoint)
  feeding the call's audio bounds (`CallAudio`), and a phone that plays in
  real time and reports every 100 ms. Pure: a 20 ms tick drives all three.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.CallAudio
  alias FermixCore.Realtime.Endpoint
  alias FermixCore.Realtime.GrokPlayback

  @phone {:phone, "0d7f6a52-91c3-4b8e-a1f0-5e2d9c4b7a13"}
  @tick_ms 20
  @reply_ms 5_000
  @frame_ms 100
  @bytes_per_ms 48

  test "a phone's Grok window fits inside the call's credit" do
    assert Keyword.fetch!(Endpoint.grok_playback_opts(@phone), :window_ms) < CallAudio.credit_ms()
    assert Endpoint.grok_playback_opts(:desktop) == []
  end

  # Grok streams a 5 s reply at one chunk a tick (in 1 s of 100 ms chunks, in
  # 0.5 s of 200 ms ones); the phone keeps up.
  for chunk_ms <- [100, 200] do
    test "a 5 s reply in #{chunk_ms} ms chunks reaches the phone whole and in order, acked as it plays" do
      chunk_ms = unquote(chunk_ms)
      chunks = div(@reply_ms, chunk_ms)

      run =
        run(%{
          grok: GrokPlayback.new(Endpoint.grok_playback_opts(@phone)),
          audio: CallAudio.new(),
          chunk_ms: chunk_ms,
          chunks: chunks,
          received: [],
          buffer_ms: 0,
          played_ms: 0,
          dropped: 0
        })

      assert run.dropped == 0
      received = Enum.reverse(run.received)
      assert length(received) == div(@reply_ms, @frame_ms)
      assert Enum.dedup(received) == Enum.to_list(1..chunks)
      assert run.played_ms == @reply_ms
      assert GrokPlayback.heard_ms(run.grok) == run.played_ms
      refute CallAudio.too_slow?(run.audio, 7_000)
    end
  end

  # 7 s of ticks: the reply arrives over the first second at most, then plays out.
  defp run(state) do
    Enum.reduce(0..div(7_000, @tick_ms), state, fn tick, state ->
      now = tick * @tick_ms

      state
      |> vendor(tick, now)
      |> deliver(now)
      |> play(now)
    end)
  end

  defp vendor(%{chunks: chunks} = state, tick, now) when tick < chunks do
    pcm = :binary.copy(<<tick + 1>>, state.chunk_ms * @bytes_per_ms)
    {:ok, grok, forwarded} = GrokPlayback.audio(state.grok, "r1", "i1", 0, Base.encode64(pcm))
    forward(%{state | grok: grok}, forwarded, now)
  end

  defp vendor(state, _tick, _now), do: state

  defp forward(state, forwarded, now) do
    Enum.reduce(forwarded, state, fn {id, base64}, state ->
      {:ok, audio} = CallAudio.put(state.audio, id, Base.decode64!(base64), now)
      %{state | audio: audio}
    end)
  end

  defp deliver(state, now) do
    {audio, frames, dropped} = CallAudio.take(state.audio, now, true)

    %{
      state
      | audio: audio,
        dropped: state.dropped + dropped,
        received:
          Enum.reduce(frames, state.received, fn {_id, <<n, _::binary>>}, acc -> [n | acc] end),
        buffer_ms: state.buffer_ms + Enum.sum(Enum.map(frames, &frame_ms/1))
    }
  end

  defp frame_ms({_id, pcm}), do: div(byte_size(pcm), @bytes_per_ms)

  # Plays in real time; reports every 100 ms, and at once when it drains.
  defp play(state, now) do
    step = min(@tick_ms, state.buffer_ms)
    state = %{state | buffer_ms: state.buffer_ms - step, played_ms: state.played_ms + step}
    drained? = state.buffer_ms == 0 and state.received != []

    if state.received != [] and (rem(now, 100) == 0 or (drained? and step > 0)),
      do: report(state, drained?, now),
      else: state
  end

  defp report(state, drained?, now) do
    {:ok, audio} = CallAudio.progress(state.audio, "p1", state.played_ms, drained?)
    {:ok, grok, released} = GrokPlayback.progress(state.grok, "p1", state.played_ms, drained?)
    forward(%{state | audio: audio, grok: grok}, released, now)
  end
end
