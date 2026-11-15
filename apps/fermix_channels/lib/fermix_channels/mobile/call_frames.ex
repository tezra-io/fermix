defmodule FermixChannels.Mobile.CallFrames do
  @moduledoc """
  The bounds on a phone call's camera frames (M87 Phase 2), enforced by the
  primary whatever the phone sends: at most one a second (less the link's
  jitter, `jitter_ms/0`) and 60 a minute, counted in a fixed minute from the
  first frame taken (the next frame after it starts the next minute); and a
  frame identical to the last one taken (SHA-256 of its bytes) is dropped. A
  frame dropped here is the call's to say in its log, by why, with the count
  so far; it never ends the call.

  The bounds admit the phone's documented cadence for as long as the camera is
  on: a still each second while the owner speaks, each two otherwise, and each
  six once the scene is still (the app's `CallStills`, whose cadence is
  `ScreenFeed`'s). The minute's ceiling is not `ScreenFeed`'s 20: that bounds
  the frames appended to the Realtime model's input, each a token cost, and
  here the voice is blind and a still only waits for a hand-off, so 20 would
  leave a phone that speaks with no picture for the rest of each minute.

  The bytes are never kept: only the last frame's digest is. Pure: the call
  holds the struct.
  """

  @minute_ms 60_000
  # The phone's fastest cadence: a still each second while the owner speaks.
  @min_interval_ms 1_000
  # One a second over the whole minute: it admits the phone at its fastest,
  # and stops the jitter allowance below adding up across a minute.
  @max_frames_per_minute 60
  # A phone paced at one frame a second reaches the primary a little early or
  # late as its link jitters; a frame that came this much sooner than a second
  # after the last is still the phone's next, not a second one in the same
  # second. The minute's ceiling bounds the rate whatever the jitter.
  @jitter_ms 100

  @typedoc """
  Why a frame was dropped: too soon after the last one taken, the minute's
  ceiling reached, the same bytes as the last one taken, and the two the call
  decides itself, a camera that is off and a session that is not the call's.
  """
  @type reason :: :too_soon | :minute_full | :unchanged | :camera_off | :not_attached

  @type t :: %__MODULE__{
          last_at: integer() | nil,
          minute_started: integer() | nil,
          minute_frames: non_neg_integer(),
          digest: binary() | nil,
          dropped: %{reason() => pos_integer()}
        }

  defstruct last_at: nil, minute_started: nil, minute_frames: 0, digest: nil, dropped: %{}

  @doc "A call that has taken no frame yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "How much sooner than a second after the last frame the next one may come."
  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms, do: @jitter_ms

  @doc "The fastest the phone sends: one frame per this many milliseconds, less the jitter."
  @spec min_interval_ms() :: pos_integer()
  def min_interval_ms, do: @min_interval_ms

  @doc "The most frames taken in a minute."
  @spec max_frames_per_minute() :: pos_integer()
  def max_frames_per_minute, do: @max_frames_per_minute

  @doc """
  Takes `jpeg`, come at `now` on the call's clock, or drops it with why and
  how many have been dropped for that reason so far.
  """
  @spec admit(t(), binary(), integer()) :: {:ok, t()} | {:drop, reason(), pos_integer(), t()}
  def admit(%__MODULE__{} = frames, jpeg, now) when is_binary(jpeg) and is_integer(now) do
    cond do
      too_soon?(frames, now) -> refuse(frames, :too_soon)
      minute_full?(frames, now) -> refuse(frames, :minute_full)
      true -> admit_new(frames, :crypto.hash(:sha256, jpeg), now)
    end
  end

  # Hashed only once the rate would take it: a phone that floods costs the
  # call no digest per frame dropped.
  defp admit_new(%{digest: digest} = frames, digest, _now), do: refuse(frames, :unchanged)
  defp admit_new(frames, digest, now), do: {:ok, take(frames, digest, now)}

  @doc "Counts a frame the call dropped for a reason of its own: the count so far, and the struct."
  @spec drop(t(), :camera_off | :not_attached) :: {pos_integer(), t()}
  def drop(%__MODULE__{} = frames, reason) when reason in [:camera_off, :not_attached],
    do: count(frames, reason)

  @doc """
  Forgets the last picture, so the same bytes are taken again: after Camera
  off, or a detach, the session no longer holds that frame.
  """
  @spec forget_picture(t()) :: t()
  def forget_picture(%__MODULE__{} = frames), do: %{frames | digest: nil}

  defp refuse(frames, reason) do
    {dropped, frames} = count(frames, reason)
    {:drop, reason, dropped, frames}
  end

  defp count(frames, reason) do
    dropped = Map.get(frames.dropped, reason, 0) + 1
    {dropped, %{frames | dropped: Map.put(frames.dropped, reason, dropped)}}
  end

  defp too_soon?(%{last_at: nil}, _now), do: false

  defp too_soon?(frames, now),
    do: now - frames.last_at < @min_interval_ms - @jitter_ms

  defp minute_full?(frames, now),
    do: within_minute?(frames, now) and frames.minute_frames >= @max_frames_per_minute

  # The minute is the jitter allowance short: a minute whose first frame came
  # late and whose sixty-first, a second a frame later, came on time still
  # ends before that one, so a phone at one a second never meets the ceiling.
  defp within_minute?(%{minute_started: nil}, _now), do: false
  defp within_minute?(frames, now), do: now - frames.minute_started < @minute_ms - @jitter_ms

  defp take(frames, digest, now) do
    frames =
      if within_minute?(frames, now),
        do: %{frames | minute_frames: frames.minute_frames + 1},
        else: %{frames | minute_started: now, minute_frames: 1}

    %{frames | last_at: now, digest: digest}
  end
end
