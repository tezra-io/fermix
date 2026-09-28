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

  describe "words/3 and tick/3" do
    test "words and then a second with none announce thinking, once" do
      {nil, turn} = LiveTurn.words(LiveTurn.new(), 0, false)
      {nil, turn} = LiveTurn.tick(turn, 900, false)
      {:thinking, turn} = LiveTurn.tick(turn, 1_000, false)

      assert {nil, _turn} = LiveTurn.tick(turn, 1_100, false)
    end

    test "the clock alone is not a turn" do
      {nil, turn} = LiveTurn.tick(LiveTurn.new(), 0, false)

      assert {nil, _turn} = LiveTurn.tick(turn, 5_000, false)
    end

    test "padding is not heard back as the reply" do
      {:silence, turn} = LiveTurn.output(LiveTurn.new(), padding(5_000), 0)
      {nil, turn} = LiveTurn.words(turn, 100, false)

      assert {:thinking, _turn} = LiveTurn.tick(turn, 1_100, false)
    end

    test "words heard while the reply can still be heard are not the operator" do
      {:voice, turn, 1_000} = LiveTurn.output(LiveTurn.new(), reply(1_000), 0)

      {nil, turn} = LiveTurn.words(turn, 1_399, false)
      assert {nil, turn} = LiveTurn.tick(turn, 5_000, false)

      {nil, turn} = LiveTurn.words(turn, 5_100, false)
      assert {:thinking, _turn} = LiveTurn.tick(turn, 6_100, false)
    end

    test "nothing is read while a reply is being announced" do
      {nil, turn} = LiveTurn.words(LiveTurn.new(), 0, true)

      assert {nil, _turn} = LiveTurn.tick(turn, 5_000, false)
    end

    test "thinking ends when the operator speaks again, or when no reply comes" do
      {nil, turn} = LiveTurn.words(LiveTurn.new(), 0, false)
      {:thinking, thinking} = LiveTurn.tick(turn, 1_000, false)

      assert {:listening, _turn} = LiveTurn.words(thinking, 1_100, false)
      assert {nil, _turn} = LiveTurn.tick(thinking, 15_999, false)
      assert {:listening, _turn} = LiveTurn.tick(thinking, 16_000, false)
    end

    test "a reply ends the thinking it answers" do
      {nil, turn} = LiveTurn.words(LiveTurn.new(), 0, false)
      {:thinking, turn} = LiveTurn.tick(turn, 1_000, false)

      {:voice, turn, _plays_for} = LiveTurn.output(turn, reply(20), 1_100)

      assert turn.thinking_since == nil
    end

    test "muting forgets the words heard before it" do
      {nil, turn} = LiveTurn.words(LiveTurn.new(), 0, false)

      assert {nil, _turn} = LiveTurn.tick(LiveTurn.muted(turn), 5_000, false)
    end
  end
end
