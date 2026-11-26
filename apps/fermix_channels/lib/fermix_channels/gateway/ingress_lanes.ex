defmodule FermixChannels.Gateway.IngressLanes do
  @moduledoc """
  The ordering rule for inbound work that is ready to run: first in, first out
  within one conversation, side by side across conversations, and bounded.

  Pure data, no process and no I/O. `Gateway.AlbumBuffer` keeps one, pushes
  each delivery under its conversation's key and runs what it is told to
  start; when that run ends it calls `finish/2` and runs what that returns.

    * At most one item of a key runs at a time, and a key's items start in the
      order they were pushed.
    * At most `max_active` items run at once. Keys waiting for a free slot are
      served in the order they became ready, and a key whose item just finished
      goes behind the keys already waiting, so one busy conversation cannot
      starve the others.
    * At most `max_waiting` items wait in all. A push beyond that is `:full`:
      the item is not kept, and the caller refuses it.
  """

  @enforce_keys [:max_active, :max_waiting]
  defstruct [
    :max_active,
    :max_waiting,
    # The keys with an item running.
    running: MapSet.new(),
    # Each key's waiting items, oldest first (a `:queue`); a key with none is absent.
    waiting: %{},
    # The keys with waiting items and none running, in the order they became
    # ready: the order free slots serve them.
    ready: :queue.new(),
    waiting_count: 0
  ]

  @type key :: term()
  @type item :: term()

  @type t :: %__MODULE__{
          max_active: pos_integer(),
          max_waiting: pos_integer(),
          running: MapSet.t(key()),
          waiting: %{optional(key()) => :queue.queue(item())},
          ready: :queue.queue(key()),
          waiting_count: non_neg_integer()
        }

  @doc "Empty lanes with these bounds (`max_active:` and `max_waiting:`, both required)."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      max_active: fetch_bound!(opts, :max_active),
      max_waiting: fetch_bound!(opts, :max_waiting)
    }
  end

  @doc """
  Offer `item` under `key`: `{:start, item, lanes}` when it may run now,
  `{:queued, lanes}` when it waits behind its key's running item or for a free
  slot, `{:full, lanes}` (unchanged) when `max_waiting` items already wait.
  """
  @spec push(t(), key(), item()) :: {:start, item(), t()} | {:queued, t()} | {:full, t()}
  def push(%__MODULE__{} = lanes, key, item) do
    cond do
      busy?(lanes, key) -> enqueue(lanes, key, item)
      MapSet.size(lanes.running) < lanes.max_active -> {:start, item, run(lanes, key)}
      true -> enqueue(lanes, key, item)
    end
  end

  @doc """
  The running item of `key` ended: free its slot and name what runs next,
  `{:start, key, item, lanes}` (of any key) or `{:idle, lanes}`. Finishing a key
  with nothing running is a defect in the caller and raises.
  """
  @spec finish(t(), key()) :: {:start, key(), item(), t()} | {:idle, t()}
  def finish(%__MODULE__{} = lanes, key) do
    ensure_running!(lanes, key)

    %{lanes | running: MapSet.delete(lanes.running, key)}
    |> requeue_behind_waiting(key)
    |> start_next()
  end

  defp fetch_bound!(opts, name) do
    case Keyword.fetch(opts, name) do
      {:ok, bound} when is_integer(bound) and bound > 0 ->
        bound

      other ->
        raise ArgumentError,
              "IngressLanes.new/1 needs #{name}: as a positive integer, got: #{inspect(other)}"
    end
  end

  defp ensure_running!(lanes, key) do
    if MapSet.member?(lanes.running, key),
      do: :ok,
      else:
        raise(ArgumentError, "IngressLanes.finish/2: nothing is running under #{inspect(key)}")
  end

  defp busy?(lanes, key),
    do: MapSet.member?(lanes.running, key) or Map.has_key?(lanes.waiting, key)

  defp run(lanes, key), do: %{lanes | running: MapSet.put(lanes.running, key)}

  defp enqueue(%__MODULE__{waiting_count: count, max_waiting: max} = lanes, _key, _item)
       when count >= max,
       do: {:full, lanes}

  # A key becomes ready when its first item waits with nothing of it running;
  # a running key becomes ready when that run finishes (`finish/2`).
  defp enqueue(lanes, key, item) do
    ready =
      if busy?(lanes, key), do: lanes.ready, else: :queue.in(key, lanes.ready)

    queue = Map.get(lanes.waiting, key, :queue.new())

    {:queued,
     %{
       lanes
       | waiting: Map.put(lanes.waiting, key, :queue.in(item, queue)),
         ready: ready,
         waiting_count: lanes.waiting_count + 1
     }}
  end

  defp requeue_behind_waiting(lanes, key) do
    if Map.has_key?(lanes.waiting, key),
      do: %{lanes | ready: :queue.in(key, lanes.ready)},
      else: lanes
  end

  # A slot was just freed, so the first ready key, if any, runs its oldest item.
  defp start_next(lanes) do
    case :queue.out(lanes.ready) do
      {:empty, _ready} -> {:idle, lanes}
      {{:value, key}, ready} -> take(%{lanes | ready: ready}, key)
    end
  end

  defp take(lanes, key) do
    {{:value, item}, queue} = :queue.out(Map.fetch!(lanes.waiting, key))

    waiting =
      if :queue.is_empty(queue),
        do: Map.delete(lanes.waiting, key),
        else: Map.put(lanes.waiting, key, queue)

    lanes = %{lanes | waiting: waiting, waiting_count: lanes.waiting_count - 1}
    {:start, key, item, run(lanes, key)}
  end
end
