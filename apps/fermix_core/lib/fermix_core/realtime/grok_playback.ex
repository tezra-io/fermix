defmodule FermixCore.Realtime.GrokPlayback do
  @moduledoc """
  Assistant audio for one Grok call, from the vendor's deltas to what the
  caller has actually heard.

  Grok streams a response faster than it plays, and only the client knows how
  much of it has played. That number is what a barge-in truncates the
  assistant item to, what decides when a continuation may speak, and what
  shows the client has stalled. So every chunk travels under a call-local
  playback id (`"p<n>"`, one per vendor `{item_id, content_index}`), the client
  reports progress per id, and this module answers from those reports alone.

  Pacing keeps the client's buffer bounded: audio is forwarded while the
  unplayed audio the client holds is under `window_ms`, and held here past
  that, up to `backlog_max_ms`. A backlog beyond that is an overflow the
  session ends the call on, never audio silently dropped.

  Every duration is derived from byte counts: PCM16 at 24 kHz mono is 48 bytes
  per millisecond. A chunk is decoded only to be measured and checked; what
  the client receives is the vendor's base64 as it came.

  A report is trusted only as far as the audio sent: an unknown id, an offset
  that moves backwards, or one beyond the audio forwarded for that id is an
  error, so a confused client cannot make the daemon truncate at a point the
  caller never reached.

  The state is bounded. Playback records are capped at 64, forgetting the
  oldest settled one (fenced, or fully reported played with nothing held)
  first; fenced response ids are remembered for the last 64 fences. The vendor
  streams only the response in progress, so a key that old never receives
  audio again.
  """

  @bytes_per_ms 48
  @default_window_ms 10_000
  @default_backlog_max_ms 120_000
  @max_playbacks 64
  @max_fenced_responses 64

  @type playback_id :: String.t()

  @type target :: %{
          item_id: String.t(),
          content_index: non_neg_integer(),
          played_ms: non_neg_integer()
        }

  @type playback :: %{
          id: playback_id(),
          response_id: String.t(),
          item_id: String.t(),
          content_index: non_neg_integer(),
          forwarded_bytes: non_neg_integer(),
          acked_bytes: non_neg_integer(),
          played_ms: non_neg_integer(),
          queued_bytes: non_neg_integer(),
          fenced?: boolean()
        }

  @type t :: %__MODULE__{
          window_bytes: pos_integer(),
          backlog_max_bytes: pos_integer(),
          next_id: pos_integer(),
          playbacks: %{playback_id() => playback()},
          by_key: %{{String.t(), non_neg_integer()} => playback_id()},
          order: :queue.queue(playback_id()),
          queue: :queue.queue({playback_id(), String.t(), pos_integer()}),
          queued_bytes: non_neg_integer(),
          fenced_responses: MapSet.t(String.t()),
          fence_order: :queue.queue(String.t()),
          acked_total_bytes: non_neg_integer()
        }

  @enforce_keys [:window_bytes, :backlog_max_bytes]
  defstruct [
    :window_bytes,
    :backlog_max_bytes,
    next_id: 1,
    playbacks: %{},
    by_key: %{},
    order: :queue.new(),
    queue: :queue.new(),
    queued_bytes: 0,
    fenced_responses: MapSet.new(),
    fence_order: :queue.new(),
    # Every byte the client ever reported playing, across all playbacks: it
    # only grows, so a stalled client is one whose total stopped moving.
    acked_total_bytes: 0
  ]

  @doc """
  A fresh tracker. `window_ms` is the most unplayed audio the client may hold
  (default #{@default_window_ms}); `backlog_max_ms` is the most held here beyond
  that window (default #{@default_backlog_max_ms}). Unknown options raise.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts =
      Keyword.validate!(opts,
        window_ms: @default_window_ms,
        backlog_max_ms: @default_backlog_max_ms
      )

    %__MODULE__{
      window_bytes: positive!(opts, :window_ms) * @bytes_per_ms,
      backlog_max_bytes: positive!(opts, :backlog_max_ms) * @bytes_per_ms
    }
  end

  @doc """
  Take one vendor audio delta.

  The first chunk for an `{item_id, content_index}` mints its playback id. The
  chunk is forwarded at once when nothing is held and the client's unplayed
  audio is under the window, and held otherwise, in arrival order. A chunk of
  a fenced response or playback is dropped without being examined.
  """
  @spec audio(t(), String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, t(), [{playback_id(), String.t()}]} | {:error, :invalid_audio | :overflow}
  def audio(%__MODULE__{} = t, response_id, item_id, content_index, base64)
      when is_binary(response_id) and response_id != "" and is_binary(item_id) and
             item_id != "" and is_integer(content_index) and content_index >= 0 and
             is_binary(base64) do
    key = {item_id, content_index}

    if fenced?(t, response_id, key) do
      {:ok, t, []}
    else
      take_audio(t, response_id, key, base64)
    end
  end

  @doc """
  Apply one client report for `playback_id`.

  `played_ms` is how much of that playback the client has rendered; it may not
  move backwards or pass the audio forwarded for the id. `drained?` says the
  client has played everything it was sent for the id, whatever its rounding
  of `played_ms`. Returns the held audio the report made room for.
  """
  @spec progress(t(), playback_id(), non_neg_integer(), boolean()) ::
          {:ok, t(), [{playback_id(), String.t()}]}
          | {:error, :unknown_playback | :playback_regressed | :playback_beyond_sent}
  def progress(%__MODULE__{} = t, playback_id, played_ms, drained?)
      when is_binary(playback_id) and is_integer(played_ms) and played_ms >= 0 and
             is_boolean(drained?) do
    with {:ok, playback} <- fetch_playback(t, playback_id),
         :ok <- check_offset(playback, played_ms) do
      acknowledged = acknowledge(playback, played_ms, drained?)
      advanced = acknowledged.acked_bytes - playback.acked_bytes

      %{t | acked_total_bytes: t.acked_total_bytes + advanced}
      |> put_playback(acknowledged)
      |> release()
    end
  end

  @doc """
  Barge-in or interrupt: fence every live playback and its response, and drop
  everything held.

  Returns, in the order the playbacks began, the truncation target for each one
  the caller has not heard to its end: forwarded audio not reported played, or
  audio still held. A playback heard to its end gets no target, because cutting
  it at the client's rounded offset could cut the last word from the model's
  transcript.
  """
  @spec stop(t()) :: {t(), [target()]}
  def stop(%__MODULE__{} = t) do
    live = live_playbacks(t)

    targets =
      for playback <- live, unheard?(playback) do
        %{
          item_id: playback.item_id,
          content_index: playback.content_index,
          played_ms: playback.played_ms
        }
      end

    fenced =
      Enum.reduce(live, t.playbacks, fn playback, acc ->
        Map.put(acc, playback.id, %{playback | fenced?: true, queued_bytes: 0})
      end)

    t = %{t | playbacks: fenced, queue: :queue.new(), queued_bytes: 0}
    {Enum.reduce(live, t, &add_fence(&2, &1.response_id)), targets}
  end

  @doc """
  Fence one response: its later chunks are dropped, and so are its chunks still
  held here, because a fenced response must not be heard any further. Audio
  already forwarded stays live — the client is playing it and still reports
  on it — so it keeps its place in the window and in `awaiting_ack?/1`.
  """
  @spec fence_response(t(), String.t()) :: t()
  def fence_response(%__MODULE__{} = t, response_id)
      when is_binary(response_id) and response_id != "" do
    t
    |> add_fence(response_id)
    |> drop_held(response_id)
  end

  @doc """
  True when the caller has heard every part of `item_id` that reached it: no
  live playback of the item has forwarded audio unreported or audio still
  held. An item with no playback (a text-only reply, or one long forgotten)
  has nothing left to hear.
  """
  @spec heard?(t(), String.t()) :: boolean()
  def heard?(%__MODULE__{} = t, item_id) when is_binary(item_id) do
    not Enum.any?(t.playbacks, fn {_id, p} ->
      p.item_id == item_id and not p.fenced? and
        (p.acked_bytes < p.forwarded_bytes or p.queued_bytes > 0)
    end)
  end

  @doc """
  How much audio, in milliseconds, the client has ever reported playing. Only
  grows: a client whose reports stop moving it has stopped playing.
  """
  @spec heard_ms(t()) :: non_neg_integer()
  def heard_ms(%__MODULE__{acked_total_bytes: bytes}), do: div(bytes, @bytes_per_ms)

  @doc "True when nothing forwarded is unplayed and nothing is held."
  @spec drained?(t()) :: boolean()
  def drained?(%__MODULE__{} = t), do: :queue.is_empty(t.queue) and not awaiting_ack?(t)

  @doc """
  True while some forwarded audio of a live playback has not been reported
  played or drained. The session ends a call that stays here too long.
  """
  @spec awaiting_ack?(t()) :: boolean()
  def awaiting_ack?(%__MODULE__{} = t) do
    Enum.any?(t.playbacks, fn {_id, p} -> not p.fenced? and p.acked_bytes < p.forwarded_bytes end)
  end

  # -- audio -------------------------------------------------------------------

  defp take_audio(t, response_id, key, base64) do
    case audio_bytes(base64) do
      {:ok, 0} -> {:ok, t, []}
      {:ok, bytes} -> place(t, response_id, key, base64, bytes)
      {:error, :invalid_audio} = error -> error
    end
  end

  defp place(t, response_id, key, base64, bytes) do
    with {:ok, t, id} <- playback_for(t, response_id, key) do
      forward_or_hold(t, id, base64, bytes)
    end
  end

  # PCM16 samples are two bytes, so an odd length is a corrupt chunk. An empty
  # one is valid and carries nothing; it mints nothing and sends nothing.
  defp audio_bytes(base64) do
    case Base.decode64(base64) do
      {:ok, pcm} when rem(byte_size(pcm), 2) == 0 -> {:ok, byte_size(pcm)}
      _other -> {:error, :invalid_audio}
    end
  end

  # Held audio is released eagerly, so a non-empty queue already means the
  # window is full; the queue check states the ordering rule outright rather
  # than leaving it to that invariant.
  defp forward_or_hold(t, id, base64, bytes) do
    cond do
      :queue.is_empty(t.queue) and outstanding_bytes(t) < t.window_bytes ->
        {:ok, forward(t, id, bytes), [{id, base64}]}

      t.queued_bytes + bytes > t.backlog_max_bytes ->
        {:error, :overflow}

      true ->
        {:ok, hold(t, id, base64, bytes), []}
    end
  end

  defp forward(t, id, bytes) do
    update_playback(t, id, fn p -> %{p | forwarded_bytes: p.forwarded_bytes + bytes} end)
  end

  defp hold(t, id, base64, bytes) do
    t = %{
      t
      | queue: :queue.in({id, base64, bytes}, t.queue),
        queued_bytes: t.queued_bytes + bytes
    }

    update_playback(t, id, fn p -> %{p | queued_bytes: p.queued_bytes + bytes} end)
  end

  # Forwards held audio, oldest first, until the client's unplayed audio
  # reaches the window. Every step takes one chunk off a finite queue, so the
  # recursion ends; every held chunk belongs to a live playback (a fence drops
  # its own), so each one forwarded adds its bytes to what is outstanding.
  defp release(t), do: release(t, outstanding_bytes(t), [])

  defp release(t, outstanding, sent) when outstanding >= t.window_bytes,
    do: {:ok, t, Enum.reverse(sent)}

  defp release(t, outstanding, sent) do
    case :queue.out(t.queue) do
      {:empty, _queue} ->
        {:ok, t, Enum.reverse(sent)}

      {{:value, {id, base64, bytes}}, rest} ->
        t =
          %{t | queue: rest, queued_bytes: t.queued_bytes - bytes}
          |> update_playback(id, fn p -> %{p | queued_bytes: p.queued_bytes - bytes} end)
          |> forward(id, bytes)

        release(t, outstanding + bytes, [{id, base64} | sent])
    end
  end

  defp outstanding_bytes(t) do
    Enum.reduce(t.playbacks, 0, fn
      {_id, %{fenced?: true}}, acc -> acc
      {_id, p}, acc -> acc + p.forwarded_bytes - p.acked_bytes
    end)
  end

  # -- progress ----------------------------------------------------------------

  defp fetch_playback(t, id) do
    case Map.fetch(t.playbacks, id) do
      {:ok, playback} -> {:ok, playback}
      :error -> {:error, :unknown_playback}
    end
  end

  defp check_offset(playback, played_ms) do
    cond do
      played_ms < playback.played_ms -> {:error, :playback_regressed}
      played_ms > ceil_ms(playback.forwarded_bytes) -> {:error, :playback_beyond_sent}
      true -> :ok
    end
  end

  # Drained covers everything forwarded so far, so audio forwarded later is
  # measured from there rather than from the client's rounded offset.
  defp acknowledge(playback, played_ms, true) do
    %{playback | played_ms: played_ms, acked_bytes: playback.forwarded_bytes}
  end

  defp acknowledge(playback, played_ms, false) do
    played_bytes = min(played_ms * @bytes_per_ms, playback.forwarded_bytes)
    %{playback | played_ms: played_ms, acked_bytes: max(playback.acked_bytes, played_bytes)}
  end

  defp ceil_ms(bytes), do: div(bytes + @bytes_per_ms - 1, @bytes_per_ms)

  # -- playback records --------------------------------------------------------

  defp playback_for(t, response_id, key) do
    case Map.fetch(t.by_key, key) do
      {:ok, id} -> {:ok, t, id}
      :error -> mint(t, response_id, key)
    end
  end

  defp mint(t, response_id, {item_id, content_index} = key) do
    with {:ok, t} <- make_room(t) do
      id = "p" <> Integer.to_string(t.next_id)

      playback = %{
        id: id,
        response_id: response_id,
        item_id: item_id,
        content_index: content_index,
        forwarded_bytes: 0,
        acked_bytes: 0,
        played_ms: 0,
        queued_bytes: 0,
        fenced?: false
      }

      {:ok,
       %{
         t
         | next_id: t.next_id + 1,
           playbacks: Map.put(t.playbacks, id, playback),
           by_key: Map.put(t.by_key, key, id),
           order: :queue.in(id, t.order)
       }, id}
    end
  end

  # At the cap, the oldest settled record goes. With none settled every record
  # still holds audio the client has not accounted for, and forgetting one would
  # turn its next report into an unknown id, so the cap is an overflow instead.
  defp make_room(t) when map_size(t.playbacks) < @max_playbacks, do: {:ok, t}

  defp make_room(t) do
    case Enum.find(:queue.to_list(t.order), &settled?(Map.fetch!(t.playbacks, &1))) do
      nil -> {:error, :overflow}
      id -> {:ok, forget(t, id)}
    end
  end

  defp settled?(%{fenced?: true}), do: true
  defp settled?(p), do: p.queued_bytes == 0 and p.acked_bytes == p.forwarded_bytes

  defp forget(t, id) do
    playback = Map.fetch!(t.playbacks, id)

    %{
      t
      | playbacks: Map.delete(t.playbacks, id),
        by_key: Map.delete(t.by_key, {playback.item_id, playback.content_index}),
        order: :queue.filter(&(&1 != id), t.order)
    }
  end

  defp live_playbacks(t) do
    t.order
    |> :queue.to_list()
    |> Enum.map(&Map.fetch!(t.playbacks, &1))
    |> Enum.reject(& &1.fenced?)
  end

  defp unheard?(p), do: p.queued_bytes > 0 or p.acked_bytes < p.forwarded_bytes

  defp put_playback(t, playback),
    do: %{t | playbacks: Map.put(t.playbacks, playback.id, playback)}

  defp update_playback(t, id, fun), do: %{t | playbacks: Map.update!(t.playbacks, id, fun)}

  # -- fences ------------------------------------------------------------------

  defp fenced?(t, response_id, key) do
    MapSet.member?(t.fenced_responses, response_id) or
      case Map.fetch(t.by_key, key) do
        {:ok, id} -> Map.fetch!(t.playbacks, id).fenced?
        :error -> false
      end
  end

  defp add_fence(t, response_id) do
    if MapSet.member?(t.fenced_responses, response_id) do
      t
    else
      t
      |> Map.update!(:fenced_responses, &MapSet.put(&1, response_id))
      |> Map.update!(:fence_order, &:queue.in(response_id, &1))
      |> trim_fences()
    end
  end

  defp trim_fences(t) do
    if :queue.len(t.fence_order) > @max_fenced_responses do
      {{:value, oldest}, rest} = :queue.out(t.fence_order)
      %{t | fence_order: rest, fenced_responses: MapSet.delete(t.fenced_responses, oldest)}
    else
      t
    end
  end

  defp drop_held(t, response_id) do
    {dropped, kept} =
      t.queue
      |> :queue.to_list()
      |> Enum.split_with(fn {id, _b64, _bytes} ->
        Map.fetch!(t.playbacks, id).response_id == response_id
      end)

    t = %{t | queue: :queue.from_list(kept), queued_bytes: t.queued_bytes - held_bytes(dropped)}

    Enum.reduce(dropped, t, fn {id, _b64, bytes}, acc ->
      update_playback(acc, id, fn p -> %{p | queued_bytes: p.queued_bytes - bytes} end)
    end)
  end

  defp held_bytes(chunks),
    do: Enum.reduce(chunks, 0, fn {_id, _b64, bytes}, acc -> acc + bytes end)

  defp positive!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
