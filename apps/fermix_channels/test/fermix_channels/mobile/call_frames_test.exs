defmodule FermixChannels.Mobile.CallFramesTest do
  @moduledoc """
  The bounds on a phone call's camera frames (M87 Phase 2): one a second and 60
  a minute, enforced by the primary whatever the phone sends, which admit the
  phone's documented cadence, and a count of every frame dropped, by why.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.CallFrames
  @second CallFrames.min_interval_ms()

  test "a frame a second is taken; one sooner is dropped, give or take the link's jitter" do
    {:ok, frames} = CallFrames.admit(CallFrames.new(), "a", 0)

    assert {:drop, :too_soon, 1, frames} =
             CallFrames.admit(frames, "b", @second - CallFrames.jitter_ms() - 1)

    assert {:ok, _frames} = CallFrames.admit(frames, "b", @second - CallFrames.jitter_ms())
  end

  # A phone that sends as early as the jitter allows, every time, is held to
  # one a second over the minute.
  test "at most 60 a minute, and the next minute takes more" do
    ceiling = CallFrames.max_frames_per_minute()
    early = @second - CallFrames.jitter_ms()
    assert ceiling == 60

    frames =
      Enum.reduce(0..(ceiling - 1), CallFrames.new(), fn n, frames ->
        {:ok, frames} = CallFrames.admit(frames, "frame #{n}", n * early)
        frames
      end)

    assert {:drop, :minute_full, 1, frames} =
             CallFrames.admit(frames, "one too many", ceiling * early)

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

  # The phone's documented cadence (M87 Phase 2, the app's `CallStills`): a
  # still each second while the owner speaks, each two otherwise, and each six
  # once the scene is still. Each reaches the primary up to the link's jitter
  # late, here the worst way for the minute: the minute's first frame late, its
  # sixty-first on time.
  @cadence [{1_000, 70_000}, {2_000, 30_000}, {6_000, 36_000}, {1_000, 20_000}, {6_000, 24_000}]

  test "a phone at its documented cadence for three minutes is never dropped" do
    arrivals = arrivals(@cadence, CallFrames.jitter_ms())
    assert List.last(arrivals) >= 170_000

    {_frames, drops} =
      arrivals
      |> Enum.with_index()
      |> Enum.reduce({CallFrames.new(), []}, fn {at, n}, {frames, drops} ->
        case CallFrames.admit(frames, "still #{n}", at) do
          {:ok, frames} -> {frames, drops}
          {:drop, reason, _count, frames} -> {frames, [{n, at, reason} | drops]}
        end
      end)

    assert drops == []
  end

  test "a drop the call decides is counted by its own reason" do
    frames = CallFrames.new()

    assert {1, frames} = CallFrames.drop(frames, :camera_off)
    assert {2, frames} = CallFrames.drop(frames, :camera_off)
    assert {1, _frames} = CallFrames.drop(frames, :not_attached)
  end

  # When each still of `cadence` ({every ms, for ms}) reaches the primary: one
  # in seven `jitter` ms late, the rest on time.
  defp arrivals(cadence, jitter) do
    {sends, _end} =
      Enum.flat_map_reduce(cadence, 0, fn {every, span}, start ->
        {Enum.to_list(start..(start + span - every)//every), start + span}
      end)

    Enum.with_index(sends, fn send, n -> if rem(n, 7) == 0, do: send + jitter, else: send end)
  end
end
