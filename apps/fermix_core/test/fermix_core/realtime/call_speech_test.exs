defmodule FermixCore.Realtime.CallSpeechTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.LiveText

  @marker LiveText.cut_marker()

  test "a new call has said nothing" do
    assert CallSpeech.text(CallSpeech.new()) == ""
  end

  test "deltas join verbatim into speaker runs, in the order they arrived" do
    speech =
      CallSpeech.new()
      |> CallSpeech.append(:user, "book the")
      |> CallSpeech.append(:user, " room for")
      |> CallSpeech.append(:user, " three")
      |> CallSpeech.append(:assistant, "On it,")
      |> CallSpeech.append(:assistant, " booking now.")
      |> CallSpeech.append(:user, "thanks")

    assert CallSpeech.text(speech) ==
             "user: book the room for three\nassistant: On it, booking now.\nuser: thanks"
  end

  test "an empty delta starts no run" do
    speech =
      CallSpeech.new()
      |> CallSpeech.append(:user, "hello")
      |> CallSpeech.append(:assistant, "")
      |> CallSpeech.append(:user, " there")

    assert CallSpeech.text(speech) == "user: hello there"
  end

  # M56 §4.2: the whole call fits in 32 KB at most, the oldest text giving way
  # behind the marker, and every run it keeps still names its speaker.
  test "past the cap the oldest text is dropped behind the marker" do
    speech =
      Enum.reduce(1..400, CallSpeech.new(), fn index, speech ->
        speaker = if rem(index, 2) == 0, do: :assistant, else: :user
        CallSpeech.append(speech, speaker, "turn #{index} " <> String.duplicate("word ", 30))
      end)

    text = CallSpeech.text(speech)

    assert byte_size(text) <= CallSpeech.max_bytes()
    assert String.starts_with?(text, @marker)
    assert String.ends_with?(text, "turn 400 " <> String.duplicate("word ", 30))
    refute text =~ "turn 1 "

    [_marker, kept] = String.split(text, @marker, parts: 2)

    for run <- String.split(kept, "\n") do
      assert String.starts_with?(run, ["user: ", "assistant: "]), "a kept run lost its speaker"
    end
  end

  test "one run longer than the cap keeps its newest text and its speaker" do
    long = String.duplicate("é", 20_000)
    speech = CallSpeech.append(CallSpeech.new(), :user, long <> "the end")

    text = CallSpeech.text(speech)

    assert byte_size(text) <= CallSpeech.max_bytes()
    assert String.valid?(text)
    assert String.starts_with?(text, @marker <> "user: ")
    assert String.ends_with?(text, "the end")
  end

  test "a view is cut from the front at its own bound, without changing the buffer" do
    speech =
      CallSpeech.new()
      |> CallSpeech.append(:user, String.duplicate("a", 3_000))
      |> CallSpeech.append(:assistant, String.duplicate("b", 3_000))
      |> CallSpeech.append(:user, "what did I ask?")

    view = CallSpeech.text(speech, 4_096)

    assert byte_size(view) == 4_096
    assert String.starts_with?(view, @marker <> "user: aaa")
    assert view =~ "\nassistant: " <> String.duplicate("b", 3_000) <> "\n"
    assert String.ends_with?(view, "user: what did I ask?")
    refute CallSpeech.text(speech) =~ @marker
  end
end
