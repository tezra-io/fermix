defmodule FermixCore.Meetings.SpeakerTimelineTest do
  # Pure module — no processes, no I/O, no global state.
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.SpeakerTimeline

  @unknown "Unknown speaker"

  defp roster(timeline, pairs) do
    SpeakerTimeline.note_roster(
      timeline,
      Enum.map(pairs, fn {id, name} -> %{id: id, name: name} end)
    )
  end

  describe "attribute/3" do
    test "a single speaker owns every segment inside their interval" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada Lovelace"}])
        |> SpeakerTimeline.note_active("p1", 0)

      assert SpeakerTimeline.attribute(timeline, 0, 5_000) == "Ada Lovelace"
      assert SpeakerTimeline.attribute(timeline, 60_000, 61_000) == "Ada Lovelace"
    end

    test "a handover mid-segment goes to the speaker with the most overlap" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}, {"p2", "Grace"}])
        |> SpeakerTimeline.note_active("p1", 0)
        |> SpeakerTimeline.note_active("p2", 3_000)

      assert SpeakerTimeline.attribute(timeline, 0, 4_000) == "Ada"
      assert SpeakerTimeline.attribute(timeline, 2_000, 6_000) == "Grace"
    end

    test "equal overlap goes to the later-starting interval" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}, {"p2", "Grace"}])
        |> SpeakerTimeline.note_active("p1", 0)
        |> SpeakerTimeline.note_active("p2", 1_000)

      assert SpeakerTimeline.attribute(timeline, 0, 2_000) == "Grace"
    end

    test "interleaved intervals are summed per speaker, not counted per interval" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}, {"p2", "Grace"}])
        |> SpeakerTimeline.note_active("p1", 0)
        |> SpeakerTimeline.note_active("p2", 1_000)
        |> SpeakerTimeline.note_active("p1", 1_400)
        |> SpeakerTimeline.note_active("p2", 2_400)

      # Ada: [0,1000) + [1400,2400) = 2000 ms. Grace: [1000,1400) + [2400,3000) = 1000 ms.
      assert SpeakerTimeline.attribute(timeline, 0, 3_000) == "Ada"
    end

    test "a zero-overlap window falls to whoever covers its start" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}, {"p2", "Grace"}])
        |> SpeakerTimeline.note_active("p1", 0)
        |> SpeakerTimeline.note_active("p2", 4_000)

      assert SpeakerTimeline.attribute(timeline, 1_500, 1_500) == "Ada"
      assert SpeakerTimeline.attribute(timeline, 9_000, 9_000) == "Grace"
    end

    test "no events at all is Unknown speaker" do
      assert SpeakerTimeline.attribute(SpeakerTimeline.new(), 0, 5_000) == @unknown
    end

    test "an id that never appeared in a roster is Unknown speaker" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}])
        |> SpeakerTimeline.note_active("ghost", 0)

      assert SpeakerTimeline.attribute(timeline, 0, 1_000) == @unknown
    end

    test "a later roster renames the same id" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}])
        |> SpeakerTimeline.note_active("p1", 0)
        |> roster([{"p1", "Ada Lovelace (host)"}])

      assert SpeakerTimeline.attribute(timeline, 0, 1_000) == "Ada Lovelace (host)"
    end

    test "roster names are capped at 120 characters" do
      long = String.duplicate("x", 200)

      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", long}])
        |> SpeakerTimeline.note_active("p1", 0)

      assert SpeakerTimeline.attribute(timeline, 0, 1_000) == String.duplicate("x", 120)
    end
  end

  describe "note_active/3 clamping" do
    test "a mark earlier than the newest interval is clamped forward" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}, {"p2", "Grace"}])
        |> SpeakerTimeline.note_active("p1", 5_000)
        |> SpeakerTimeline.note_active("p2", 3_000)

      # Grace's interval opens at 5_000 (clamped), collapsing Ada's to zero width.
      assert SpeakerTimeline.attribute(timeline, 0, 6_000) == "Grace"
      assert SpeakerTimeline.attribute(timeline, 0, 5_000) == @unknown
    end
  end

  describe "participants_peak/1" do
    test "keeps the largest roster snapshot seen" do
      timeline =
        SpeakerTimeline.new()
        |> roster([{"p1", "Ada"}])
        |> roster([{"p1", "Ada"}, {"p2", "Grace"}, {"p3", "Alan"}])
        |> roster([{"p1", "Ada"}])

      assert SpeakerTimeline.participants_peak(timeline) == 3
    end

    test "a fresh timeline has no participants" do
      assert SpeakerTimeline.participants_peak(SpeakerTimeline.new()) == 0
    end
  end
end
