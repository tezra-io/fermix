defmodule FermixCore.Realtime.LiveTurnTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.LiveTurn

  # `ms` of the assistant's voice as Live sends it: base64 24 kHz PCM16.
  defp reply(ms), do: Base.encode64(wave(24 * ms, 2_000))

  # Live's padding between replies: digital silence.
  defp padding(ms), do: Base.encode64(:binary.copy(<<0, 0>>, 24 * ms))

  defp wave(samples, amplitude) do
    for index <- 1..samples, into: <<>> do
      value = if rem(index, 2) == 0, do: amplitude, else: -amplitude
      <<value::little-signed-16>>
    end
  end

  # 100 ms of microphone: a square wave well above speech level, or silence.
  defp mic(:speech), do: square(3_000)
  defp mic(:silence), do: square(0)

  defp square(amplitude) do
    for index <- 1..2_400, into: <<>> do
      value = if rem(index, 2) == 0, do: amplitude, else: -amplitude
      <<value::little-signed-16>>
    end
  end

  describe "output/3" do
    test "reports how long a reply takes to play, across chunks" do
      {:voice, turn, 250} = LiveTurn.output(LiveTurn.new(), reply(250), 1_000)
      {:voice, _turn, 350} = LiveTurn.output(turn, reply(200), 1_100)
    end

    test "padding is not voice, but it is played before the voice after it" do
      {:silence, turn} = LiveTurn.output(LiveTurn.new(), padding(100), 0)
      {:silence, turn} = LiveTurn.output(turn, padding(100), 0)

      assert {:voice, _turn, 300} = LiveTurn.output(turn, reply(100), 0)
    end

    test "audio that does not decode is not voice" do
      assert {:silence, _turn} = LiveTurn.output(LiveTurn.new(), "not base64!", 0)
    end

    test "drops a stopped reply's voice until it has been quiet, and padding does not extend it" do
      turn = LiveTurn.interrupted(LiveTurn.new(), 1_000)

      assert {:drop, turn} = LiveTurn.output(turn, reply(20), 1_500)
      assert {:drop, turn} = LiveTurn.output(turn, reply(20), 2_200)
      assert {:silence, turn} = LiveTurn.output(turn, padding(100), 2_700)
      assert {:voice, _turn, _plays_for} = LiveTurn.output(turn, reply(20), 3_000)
    end
  end

  describe "input/4" do
    test "speech and then a quiet hangover announce thinking, once" do
      {nil, turn} = LiveTurn.input(LiveTurn.new(), mic(:speech), 0, false)
      {nil, turn} = LiveTurn.input(turn, mic(:silence), 600, false)
      {:thinking, turn} = LiveTurn.input(turn, mic(:silence), 700, false)

      assert {nil, _turn} = LiveTurn.input(turn, mic(:silence), 800, false)
    end

    test "silence alone is not a turn" do
      {nil, turn} = LiveTurn.input(LiveTurn.new(), mic(:silence), 0, false)

      assert {nil, _turn} = LiveTurn.input(turn, mic(:silence), 5_000, false)
    end

    test "padding is not heard back as the reply" do
      {:silence, turn} = LiveTurn.output(LiveTurn.new(), padding(5_000), 0)
      {nil, turn} = LiveTurn.input(turn, mic(:speech), 100, false)

      assert {:thinking, _turn} = LiveTurn.input(turn, mic(:silence), 800, false)
    end

    test "the reply heard back is not the operator, until its echo has passed" do
      {:voice, turn, 1_000} = LiveTurn.output(LiveTurn.new(), reply(1_000), 0)

      {nil, turn} = LiveTurn.input(turn, mic(:speech), 1_399, false)
      assert {nil, turn} = LiveTurn.input(turn, mic(:silence), 5_000, false)

      {nil, turn} = LiveTurn.input(turn, mic(:speech), 5_100, false)
      assert {:thinking, _turn} = LiveTurn.input(turn, mic(:silence), 5_800, false)
    end

    test "nothing is read while a reply is being announced" do
      {nil, turn} = LiveTurn.input(LiveTurn.new(), mic(:speech), 0, true)

      assert {nil, _turn} = LiveTurn.input(turn, mic(:silence), 5_000, false)
    end

    test "thinking ends when the operator speaks again, or when no reply comes" do
      {nil, turn} = LiveTurn.input(LiveTurn.new(), mic(:speech), 0, false)
      {:thinking, thinking} = LiveTurn.input(turn, mic(:silence), 700, false)

      assert {:listening, _turn} = LiveTurn.input(thinking, mic(:speech), 800, false)
      assert {nil, _turn} = LiveTurn.input(thinking, mic(:silence), 15_699, false)
      assert {:listening, _turn} = LiveTurn.input(thinking, mic(:silence), 15_700, false)
    end

    test "a reply ends the thinking it answers" do
      {nil, turn} = LiveTurn.input(LiveTurn.new(), mic(:speech), 0, false)
      {:thinking, turn} = LiveTurn.input(turn, mic(:silence), 700, false)

      {:voice, turn, _plays_for} = LiveTurn.output(turn, reply(20), 800)

      assert turn.thinking_since == nil
    end

    test "muting forgets the speech heard before it" do
      {nil, turn} = LiveTurn.input(LiveTurn.new(), mic(:speech), 0, false)

      assert {nil, _turn} = LiveTurn.input(LiveTurn.muted(turn), mic(:silence), 5_000, false)
    end
  end
end
