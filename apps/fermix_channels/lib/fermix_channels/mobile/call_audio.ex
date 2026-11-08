defmodule FermixChannels.Mobile.CallAudio do
  @moduledoc """
  The assistant's audio on its way down to a phone in a call (M87 §06): what
  waits to be written to the phone's session, and what the phone holds
  unplayed. Pure: the call process (`Mobile.Call`) owns the clock and the
  writing.

  The phone's mobile session is one ordered stream, so audio the link cannot
  take would pile up behind everything else on it. Three bounds keep it from
  doing so:

    * **age:** audio that has waited here 300 ms is dropped before it is
      written, oldest first, so what reaches the phone is still worth playing;
    * **credit:** at most 500 ms of audio is outstanding on the phone, sent and
      not yet reported played (`progress/4`, from the phone's
      `playback_progress` against each `playback_id`, checked as the voice
      session checks it); a playback the phone reported drained counts
      nothing of what was sent before that report. Some audio is never
      reported: what the phone drops after a playback stop, and what was in
      flight when its link went. So a stop (`clear/1`) and a resume
      (`settle/1`) count everything sent so far as drained, keeping what was
      sent and played, so later reports are still checked against it;
    * **behind:** a link that keeps audio waiting here for 5 s without once
      catching up is too slow for a call (`too_slow?/2`), and the call ends
      with `link_too_slow`. A report that frees credit is the link catching
      up, and starts the count again.

  Every duration is derived from byte counts: PCM16 at 24 kHz mono is 48 bytes
  per millisecond. Audio is cut into frames of at most 100 ms (4,800 bytes),
  the wire's frame, each keeping its playback id.

  The state is bounded: at most 64 frames wait (the oldest is dropped past
  that), and at most 64 playbacks are remembered, the oldest forgotten first.
  """

  @bytes_per_ms 48
  @frame_bytes 4_800
  @max_age_ms 300
  @credit_ms 500
  @behind_limit_ms 5_000
  @max_queued 64
  @max_playbacks 64

  @typedoc """
  One playback on the phone: bytes sent, the ms it reported played, and the
  bytes counted played whatever the report says (all sent, as of the last
  drain, stop or resume).
  """
  @type playback :: %{
          sent: non_neg_integer(),
          played_ms: non_neg_integer(),
          acked: non_neg_integer()
        }

  @type t :: %__MODULE__{
          queue: :queue.queue({integer(), String.t(), binary()}),
          queued: non_neg_integer(),
          playbacks: %{String.t() => playback()},
          order: [String.t()],
          behind_since: integer() | nil
        }

  defstruct queue: :queue.new(), queued: 0, playbacks: %{}, order: [], behind_since: nil

  @doc "No audio waiting, none outstanding."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The wire's largest audio frame: 100 ms of PCM16 at 24 kHz mono."
  @spec frame_bytes() :: pos_integer()
  def frame_bytes, do: @frame_bytes

  @doc "How old audio may be before it is written: older is dropped."
  @spec max_age_ms() :: pos_integer()
  def max_age_ms, do: @max_age_ms

  @doc "How much unplayed audio the phone may hold."
  @spec credit_ms() :: pos_integer()
  def credit_ms, do: @credit_ms

  @doc "How long the link may stay behind before the call ends."
  @spec behind_limit_ms() :: pos_integer()
  def behind_limit_ms, do: @behind_limit_ms

  @doc """
  Queues one stretch of PCM16 under `playback_id`, cut into frames, stamped
  `now`. Past the bound the oldest frames go. An odd-length stretch is not
  PCM16 and is refused.
  """
  @spec put(t(), String.t(), binary(), integer()) :: {:ok, t()} | {:error, :invalid_audio}
  def put(%__MODULE__{} = t, playback_id, pcm, now)
      when is_binary(playback_id) and is_binary(pcm) and is_integer(now) do
    if rem(byte_size(pcm), 2) == 0,
      do:
        {:ok, pcm |> frames() |> Enum.reduce(t, &enqueue(&2, {now, playback_id, &1})) |> bound()},
      else: {:error, :invalid_audio}
  end

  @doc """
  Takes what may be written now: frames older than the age bound are dropped
  first, then, while the phone is `attached?`, frames in order while the
  credit allows. Answers the frames to write, as `{playback_id, pcm}`, and how
  many were dropped. The link is behind from the first take that leaves audio
  waiting for an attached phone until a take leaves none.
  """
  @spec take(t(), integer(), boolean()) :: {t(), [{String.t(), binary()}], non_neg_integer()}
  def take(%__MODULE__{} = t, now, attached?) when is_integer(now) and is_boolean(attached?) do
    {t, dropped} = drop_aged(t, now, 0)
    {t, sent} = if attached?, do: send_within_credit(t, []), else: {t, []}
    {mark_behind(t, now, attached?), Enum.reverse(sent), dropped}
  end

  @doc """
  The phone's report on one playback: `played_ms` of it rendered, `drained?`
  when everything sent under it has played. A report the phone could not have
  made is refused as the voice session refuses it (`GrokPlayback`): an id this
  side never sent, or long forgot (`:unknown_playback`), a `played_ms` below
  one already reported (`:playback_regressed`) or past what was sent under the
  id (`:playback_beyond_sent`).
  """
  @spec progress(t(), String.t(), non_neg_integer(), boolean()) ::
          {:ok, t()} | {:error, :unknown_playback | :playback_regressed | :playback_beyond_sent}
  def progress(%__MODULE__{} = t, playback_id, played_ms, drained?)
      when is_binary(playback_id) and is_integer(played_ms) and played_ms >= 0 and
             is_boolean(drained?) do
    with {:ok, playback} <- fetch_playback(t, playback_id),
         :ok <- check_played(playback, played_ms) do
      acked = if drained?, do: playback.sent, else: playback.acked
      played = %{playback | played_ms: played_ms, acked: acked}
      t = %{t | playbacks: Map.put(t.playbacks, playback_id, played)}
      t = if unplayed_ms(played) < unplayed_ms(playback), do: caught_up(t), else: t
      {:ok, t}
    end
  end

  @doc """
  The assistant's playback stopped: what still waits here is stale, and goes,
  and what the phone was sent is settled (`settle/1`), since it drops the rest
  of a stopped playback without reporting it.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = t), do: settle(%{t | queue: :queue.new(), queued: 0})

  @doc """
  Counts everything sent so far as played: the phone will never report it.
  For a stop, and for a resume, where the gap outlasted what the phone held.
  Each playback keeps what was sent and played, so a later report is still
  checked against all of it, and audio sent later counts from here.
  """
  @spec settle(t()) :: t()
  def settle(%__MODULE__{} = t) do
    settled =
      Map.new(t.playbacks, fn {id, playback} -> {id, %{playback | acked: playback.sent}} end)

    caught_up(%{t | playbacks: settled})
  end

  @doc "Whether the link has stayed behind past the bound at `now`."
  @spec too_slow?(t(), integer()) :: boolean()
  def too_slow?(%__MODULE__{behind_since: nil}, _now), do: false
  def too_slow?(%__MODULE__{behind_since: since}, now), do: now - since >= @behind_limit_ms

  @doc "Whether any audio waits here, or was sent and not yet reported played."
  @spec unheard?(t()) :: boolean()
  def unheard?(%__MODULE__{} = t), do: t.queued > 0 or outstanding_ms(t) > 0

  @doc "Milliseconds of audio sent to the phone and not yet reported played."
  @spec outstanding_ms(t()) :: non_neg_integer()
  def outstanding_ms(%__MODULE__{playbacks: playbacks}) do
    Enum.reduce(playbacks, 0, fn {_id, playback}, sum -> sum + unplayed_ms(playback) end)
  end

  defp fetch_playback(t, playback_id) do
    case Map.fetch(t.playbacks, playback_id) do
      {:ok, playback} -> {:ok, playback}
      :error -> {:error, :unknown_playback}
    end
  end

  defp check_played(playback, played_ms) do
    cond do
      played_ms < playback.played_ms ->
        {:error, :playback_regressed}

      played_ms > div(playback.sent + @bytes_per_ms - 1, @bytes_per_ms) ->
        {:error, :playback_beyond_sent}

      true ->
        :ok
    end
  end

  defp frames(pcm) when byte_size(pcm) <= @frame_bytes, do: [pcm]

  defp frames(pcm) do
    count = div(byte_size(pcm) + @frame_bytes - 1, @frame_bytes)

    for index <- 0..(count - 1) do
      binary_part(
        pcm,
        index * @frame_bytes,
        min(@frame_bytes, byte_size(pcm) - index * @frame_bytes)
      )
    end
  end

  defp enqueue(t, frame), do: %{t | queue: :queue.in(frame, t.queue), queued: t.queued + 1}

  defp bound(%{queued: queued} = t) when queued <= @max_queued, do: t

  defp bound(t) do
    {_oldest, queue} = :queue.out(t.queue)
    bound(%{t | queue: queue, queued: t.queued - 1})
  end

  defp drop_aged(t, now, dropped) do
    case :queue.peek(t.queue) do
      {:value, {at, _id, _pcm}} when now - at >= @max_age_ms ->
        {_aged, queue} = :queue.out(t.queue)
        drop_aged(%{t | queue: queue, queued: t.queued - 1}, now, dropped + 1)

      _fresh_or_empty ->
        {t, dropped}
    end
  end

  # Bounded by the queue, itself at most `@max_queued` frames.
  defp send_within_credit(t, sent) do
    case :queue.peek(t.queue) do
      {:value, {_at, id, pcm}} ->
        if outstanding_ms(t) + div(byte_size(pcm), @bytes_per_ms) <= @credit_ms do
          {_frame, queue} = :queue.out(t.queue)
          t = %{t | queue: queue, queued: t.queued - 1} |> account(id, byte_size(pcm))
          send_within_credit(t, [{id, pcm} | sent])
        else
          {t, sent}
        end

      :empty ->
        {t, sent}
    end
  end

  defp account(t, id, bytes) do
    case Map.fetch(t.playbacks, id) do
      {:ok, playback} ->
        sent = %{playback | sent: playback.sent + bytes}
        %{t | playbacks: Map.put(t.playbacks, id, sent)}

      :error ->
        playback = %{sent: bytes, played_ms: 0, acked: 0}

        forget_oldest(%{
          t
          | playbacks: Map.put(t.playbacks, id, playback),
            order: t.order ++ [id]
        })
    end
  end

  defp forget_oldest(%{order: [oldest | rest]} = t) when length(t.order) > @max_playbacks,
    do: %{t | playbacks: Map.delete(t.playbacks, oldest), order: rest}

  defp forget_oldest(t), do: t

  defp unplayed_ms(%{sent: sent, played_ms: played_ms, acked: acked}),
    do: div(max(sent - max(acked, played_ms * @bytes_per_ms), 0), @bytes_per_ms)

  defp caught_up(t), do: %{t | behind_since: nil}

  defp mark_behind(%{queued: 0} = t, _now, _attached?), do: %{t | behind_since: nil}
  defp mark_behind(t, _now, false), do: %{t | behind_since: nil}
  defp mark_behind(%{behind_since: nil} = t, now, true), do: %{t | behind_since: now}
  defp mark_behind(t, _now, true), do: t
end
