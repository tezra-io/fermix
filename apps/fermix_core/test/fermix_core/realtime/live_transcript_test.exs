defmodule FermixCore.Realtime.LiveTranscriptTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.LiveTranscript

  describe "append/5" do
    test "keeps fragment bytes verbatim and joins them without inserting spaces" do
      transcript =
        LiveTranscript.new()
        |> LiveTranscript.append(:user, "book ", 0, 400)
        |> LiveTranscript.append(:user, "the ", 400, 700)
        |> LiveTranscript.append(:user, "room", 700, 1_000)

      assert LiveTranscript.context_since(transcript, 1_000, 30_000) == "user: book the room"
    end

    test "bounds the buffer to the most recent fragments" do
      transcript =
        Enum.reduce(1..200, LiveTranscript.new(), fn index, acc ->
          LiveTranscript.append(acc, :user, "f#{index} ", index * 10, index * 10 + 5)
        end)

      assert length(LiveTranscript.fragments(transcript)) == 128
      context = LiveTranscript.context_since(transcript, 2_000, 30_000)
      refute context =~ "f1 "
      assert context =~ "f200"
    end
  end

  describe "context_since/3" do
    test "labels each speaker and orders fragments by start_ms" do
      transcript =
        LiveTranscript.new()
        |> LiveTranscript.append(:assistant, "sure", 2_000, 2_400)
        |> LiveTranscript.append(:user, "what is the weather", 500, 1_800)
        |> LiveTranscript.append(:user, "in Berlin", 2_600, 3_100)

      assert LiveTranscript.context_since(transcript, 3_100, 30_000) ==
               "user: what is the weather\nassistant: sure\nuser: in Berlin"
    end

    test "drops fragments that ended before the window opened" do
      transcript =
        LiveTranscript.new()
        |> LiveTranscript.append(:user, "old news", 0, 500)
        |> LiveTranscript.append(:user, "fresh", 9_000, 9_500)

      assert LiveTranscript.context_since(transcript, 10_000, 2_000) == "user: fresh"
    end

    test "is empty when nothing falls inside the window" do
      transcript = LiveTranscript.append(LiveTranscript.new(), :user, "old", 0, 500)

      assert LiveTranscript.context_since(transcript, 60_000, 1_000) == ""
    end
  end

  describe "sufficient?/2" do
    test "is true when a user fragment ends within the lookback" do
      transcript = LiveTranscript.append(LiveTranscript.new(), :user, "yes", 3_000, 3_400)

      assert LiveTranscript.sufficient?(transcript, 4_000)
    end

    test "is false when only assistant speech is in the window" do
      transcript = LiveTranscript.append(LiveTranscript.new(), :assistant, "on it", 3_000, 3_400)

      refute LiveTranscript.sufficient?(transcript, 4_000)
    end

    test "is false when the newest user fragment is older than the lookback" do
      transcript = LiveTranscript.append(LiveTranscript.new(), :user, "hello", 0, 500)

      refute LiveTranscript.sufficient?(transcript, 9_000)
    end
  end

  describe "latest_user_end_ms/1" do
    test "reports the newest user fragment end and nil when the user never spoke" do
      transcript =
        LiveTranscript.new()
        |> LiveTranscript.append(:user, "a", 0, 500)
        |> LiveTranscript.append(:user, "b", 800, 1_200)

      assert LiveTranscript.latest_user_end_ms(transcript) == 1_200
      assert LiveTranscript.latest_user_end_ms(LiveTranscript.new()) == nil
    end
  end
end
