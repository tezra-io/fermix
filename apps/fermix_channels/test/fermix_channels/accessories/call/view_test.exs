defmodule FermixChannels.Accessories.Call.ViewTest do
  # What the Mac shows of an accessory's call (M91 E3): folded from the frames
  # the call already reads, bounded, and labelled with the voice the call
  # started with.
  use ExUnit.Case, async: true

  alias FermixChannels.Accessories.Call.View

  defp view, do: View.new(%{engine: "xai_realtime", model: "grok-voice-3.0", voice: "eve"})

  defp fold(view, frames), do: Enum.reduce(frames, view, &View.engine(&2, &1))

  test "a new call carries its start-time voice and nothing else" do
    assert %{engine: "xai_realtime", voice: "eve", state: nil, transcript: [], tasks: []} = view()
  end

  test "captions build one line per turn, concatenated as received" do
    view =
      fold(view(), [
        %{type: "caption", speaker: "user", delta: "Summarize ", start_ms: 0, end_ms: 1},
        %{type: "caption", speaker: "user", delta: "the document.", start_ms: 1, end_ms: 2},
        %{type: "caption", speaker: "assistant", delta: "On it.", start_ms: 3, end_ms: 4}
      ])

    assert view.transcript == [
             %{speaker: :user, text: "Summarize the document.", final?: true},
             %{speaker: :assistant, text: "On it.", final?: false}
           ]
  end

  test "OpenAI Realtime's whole utterance and streamed reply become lines too" do
    view =
      fold(view(), [
        %{type: "transcript_delta", text: "What time is it?", role: "user"},
        %{type: "assistant_text_delta", text: "It is "},
        %{type: "assistant_text_delta", text: "noon"},
        %{type: "assistant_text_done", text: "It is noon."}
      ])

    assert view.transcript == [
             %{speaker: :user, text: "What time is it?", final?: true},
             %{speaker: :assistant, text: "It is noon.", final?: true}
           ]
  end

  test "the transcript keeps its newest six lines, each at most 400 characters" do
    frames =
      for n <- 1..8,
          do: %{type: "transcript_delta", text: "line #{n} " <> String.duplicate("x", 500)}

    view = fold(view(), frames)

    assert length(view.transcript) == 6
    assert hd(view.transcript).text =~ "x"
    assert Enum.all?(view.transcript, &(String.length(&1.text) == 400))
  end

  test "tasks keep their place, take newer revisions only, and say when they reached the chat" do
    view =
      fold(view(), [
        %{type: "task", delegation_id: "d1", revision: 2, status: "pending", summary: "Looking"},
        %{type: "task", delegation_id: "d1", revision: 1, status: "failed"},
        %{type: "task", delegation_id: "d1", revision: 2, status: "completed", server_seq: 41},
        %{type: "task", delegation_id: "d2", revision: 1, status: "running", detached: true}
      ])

    assert view.tasks == [
             %{task: "d1", revision: 2, status: "completed", summary: "Looking", in_chat?: true}
           ]
  end

  test "an OpenAI Realtime tool batch is a task, as the robot sees it" do
    view =
      View.task_events(view(), [%{task: "rt:1", revision: 1, status: "running", in_chat: false}])

    assert [%{task: "rt:1", status: "running", summary: nil}] = view.tasks
  end

  test "usage keeps what it knows and never reads a missing field as zero" do
    view =
      fold(view(), [
        %{type: "usage", voice_seconds: 12.5, voice_cost_cents: 1.25, accounting: "running"},
        %{type: "usage", status: "reported"}
      ])

    assert view.usage == %{cost_cents: 1.25, voice_seconds: 12.5, accounting: "running"}
  end

  test "the voice state, the call's identity and its mute are kept" do
    view =
      view()
      |> fold([
        %{type: "state", state: "listening"},
        %{type: "state", state: "idle"},
        %{type: "call_ready", call_uuid: "u-1", conversation: "chat", engine: "xai_realtime"}
      ])
      |> View.muted(:mac)

    assert {view.state, view.call_uuid, view.conversation, view.muted_by} ==
             {"listening", "u-1", "chat", :mac}
  end
end
