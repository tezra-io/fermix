defmodule FermixChannels.Desktop.Relay.Outbox do
  @moduledoc """
  What a desktop's relay has to write to its primary and has not yet handed
  its writer, by lane (M97 §5.1, `Mobile.Lanes`).

  `take/1` answers the oldest live frame, else the oldest interactive one,
  else the oldest bulk one: strict priority, one frame at a time, so a bulk
  stream yields between its frames and a lane's own frames, a chunked
  payload's included, keep their order. An event's frames go in together or
  not at all (`put/4`), and each lane holds at most:

  | Lane | Bytes | Frames |
  |---|---|---|
  | `live` | 256 KiB | 4,096 |
  | `interactive` | 16 MiB | 4,096 |
  | `bulk` | 4 MiB | 4,096 |

  Bytes are the frames' raw tails, so a frame with none (an open, a close)
  still fits a lane its bytes fill. A put past either bound is refused,
  `{:error, :busy, outbox}`, and the lane counts it (`refused/2`). A lane
  stops refusing once it has drained to half of both bounds: `drained/1`
  answers each such lane with what it refused, once, so its owner says a run
  of refusals when it starts and when it ends, never per frame.

  A tag rides an event's last frame and comes back as that frame is taken,
  and every tag still queued when the session ends (`clear/1`).

  Pure.
  """

  alias FermixChannels.Mobile.Lanes

  @typedoc "One frame to write: its event type, its header fields and its raw tail."
  @type frame :: {String.t(), map(), binary()}

  @typedoc "What comes back as an event's last frame is taken: `nil` for nothing."
  @type tag :: term()

  @opaque t :: %{Lanes.lane() => lane_state()}

  @typep lane_state :: %{
           queue: :queue.queue({frame(), tag()}),
           bytes: non_neg_integer(),
           frames: non_neg_integer(),
           refused: non_neg_integer()
         }

  @kib 1_024
  @mib 1_024 * 1_024
  @bounds %{
    live: {256 * @kib, 4_096},
    interactive: {16 * @mib, 4_096},
    bulk: {4 * @mib, 4_096}
  }

  @doc "Each lane's bounds: `{bytes, frames}`."
  @spec bounds() :: %{Lanes.lane() => {pos_integer(), pos_integer()}}
  def bounds, do: @bounds

  @doc "An outbox with every lane empty."
  @spec new() :: t()
  def new,
    do: Map.new(Lanes.lanes(), &{&1, %{queue: :queue.new(), bytes: 0, frames: 0, refused: 0}})

  @doc """
  Queues one event's `frames`, in order, in `lane`, `tag` riding the last;
  all of them, or none when the lane cannot take them all.
  """
  @spec put(t(), Lanes.lane(), [frame(), ...], tag()) :: {:ok, t()} | {:error, :busy, t()}
  def put(outbox, lane, [_ | _] = frames, tag) when is_map_key(outbox, lane) do
    held = Map.fetch!(outbox, lane)
    {max_bytes, max_frames} = Map.fetch!(@bounds, lane)

    bytes =
      held.bytes +
        Enum.reduce(frames, 0, fn {_type, _fields, tail}, sum -> sum + byte_size(tail) end)

    count = held.frames + length(frames)

    if bytes <= max_bytes and count <= max_frames do
      queue = Enum.reduce(tagged(frames, tag), held.queue, &:queue.in/2)
      {:ok, Map.put(outbox, lane, %{held | queue: queue, bytes: bytes, frames: count})}
    else
      {:error, :busy, Map.put(outbox, lane, %{held | refused: held.refused + 1})}
    end
  end

  @doc "The next frame to write, by lane, with its tag and lane; `:empty` when none waits."
  @spec take(t()) :: {:ok, frame(), tag(), Lanes.lane(), t()} | :empty
  def take(outbox) do
    case Enum.find(Lanes.lanes(), &(Map.fetch!(outbox, &1).frames > 0)) do
      nil -> :empty
      lane -> take_from(outbox, lane)
    end
  end

  defp take_from(outbox, lane) do
    held = Map.fetch!(outbox, lane)
    {{:value, {{_type, _fields, tail} = frame, tag}}, queue} = :queue.out(held.queue)
    held = %{held | queue: queue, bytes: held.bytes - byte_size(tail), frames: held.frames - 1}
    {:ok, frame, tag, lane, Map.put(outbox, lane, held)}
  end

  @doc "How many puts `lane` refused since it last drained."
  @spec refused(t(), Lanes.lane()) :: non_neg_integer()
  def refused(outbox, lane) when is_map_key(outbox, lane), do: Map.fetch!(outbox, lane).refused

  @doc """
  The lanes that refused and have since drained to half of both bounds, each
  with what it refused; those lanes count from nothing again.
  """
  @spec drained(t()) :: {[{Lanes.lane(), pos_integer()}], t()}
  def drained(outbox) do
    Enum.reduce(Lanes.lanes(), {[], outbox}, fn lane, {done, outbox} ->
      held = Map.fetch!(outbox, lane)
      {max_bytes, max_frames} = Map.fetch!(@bounds, lane)

      if held.refused > 0 and held.bytes * 2 <= max_bytes and held.frames * 2 <= max_frames,
        do: {done ++ [{lane, held.refused}], Map.put(outbox, lane, %{held | refused: 0})},
        else: {done, outbox}
    end)
  end

  @doc "Empties every lane: the tags of the frames it held, in lane order."
  @spec clear(t()) :: {[tag()], t()}
  def clear(outbox) do
    tags =
      for lane <- Lanes.lanes(),
          {_frame, tag} <- :queue.to_list(Map.fetch!(outbox, lane).queue),
          tag != nil,
          do: tag

    {tags,
     Map.new(outbox, fn {lane, held} ->
       {lane, %{held | queue: :queue.new(), bytes: 0, frames: 0}}
     end)}
  end

  @doc "How many frames wait, in every lane."
  @spec size(t()) :: non_neg_integer()
  def size(outbox), do: Enum.reduce(outbox, 0, fn {_lane, held}, sum -> sum + held.frames end)

  defp tagged(frames, tag) do
    last = length(frames) - 1
    frames |> Enum.with_index() |> Enum.map(fn {frame, i} -> {frame, if(i == last, do: tag)} end)
  end
end
