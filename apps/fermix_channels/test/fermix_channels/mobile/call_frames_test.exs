defmodule FermixChannels.Mobile.CallFramesTest do
  @moduledoc """
  The bounds on a phone call's camera frames (M87 Phase 2): ScreenFeed's own
  ceiling, enforced by the primary whatever the phone sends, and a count of
  every frame dropped, by why.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.CallFrames
  alias FermixCore.Realtime.ScreenFeed

  @second ScreenFeed.min_interval_ms()

  test "a frame a second is taken; one sooner is dropped, give or take the link's jitter" do
    {:ok, frames} = CallFrames.admit(CallFrames.new(), "a", 0)

    assert {:drop, :too_soon, 1, frames} =
             CallFrames.admit(frames, "b", @second - CallFrames.jitter_ms() - 1)

    assert {:ok, _frames} = CallFrames.admit(frames, "b", @second - CallFrames.jitter_ms())
  end

  test "at most 20 a minute, ScreenFeed's ceiling, and the next minute takes more" do
    ceiling = ScreenFeed.max_frames_per_minute()

    frames =
      Enum.reduce(0..(ceiling - 1), CallFrames.new(), fn n, frames ->
        {:ok, frames} = CallFrames.admit(frames, "frame #{n}", n * @second)
        frames
      end)

    assert {:drop, :minute_full, 1, frames} =
             CallFrames.admit(frames, "one too many", ceiling * @second)

    assert {:ok, _frames} = CallFrames.admit(frames, "next minute", 60_000)
  end

  test "a frame identical to the last one taken is dropped, until the picture is forgotten" do
    {:ok, frames} = CallFrames.admit(CallFrames.new(), "same", 0)

    assert {:drop, :unchanged, 1, frames} = CallFrames.admit(frames, "same", 2 * @second)
    assert {:drop, :unchanged, 2, frames} = CallFrames.admit(frames, "same", 3 * @second)

    assert {:ok, _frames} =
             frames |> CallFrames.forget_picture() |> CallFrames.admit("same", 4 * @second)
  end

  test "a dropped frame is not counted against the ceiling" do
    {:ok, frames} = CallFrames.admit(CallFrames.new(), "a", 0)
    {:drop, :too_soon, 1, frames} = CallFrames.admit(frames, "b", 10)
    assert {:ok, _frames} = CallFrames.admit(frames, "b", @second)
  end

  test "a drop the call decides is counted by its own reason" do
    frames = CallFrames.new()

    assert {1, frames} = CallFrames.drop(frames, :camera_off)
    assert {2, frames} = CallFrames.drop(frames, :camera_off)
    assert {1, _frames} = CallFrames.drop(frames, :not_attached)
  end
end
