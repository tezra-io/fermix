defmodule FermixChannels.Accessories.Call.Speaker do
  @moduledoc """
  The host's half of an accessory call's speaker (`priv/accessory/PROTOCOL.md`,
  *Speaker and credit*). Pure.

    * **Credit.** Nothing goes out past the accessory's outstanding credit,
      which it grants and the host's frames use; a grant past 8,192
      outstanding is `credit_overgrant`, which ends the call.
    * **Frames.** Even, at most 3,840 bytes (80 ms), each within credit.
    * **Segments.** Audio is sent in segments numbered from 1: one per reply,
      and a new one for each new Grok playback id. Only one takes audio at a
      time; a segment is open from its `spk.begin` until the accessory says it
      drained or a flush closes it, and a ninth open one waits for a drain.
    * **Backlog.** The engines hand over audio at the provider's pace (Grok's
      send-ahead is about ten seconds), so what credit does not cover waits
      here, up to two minutes of audio; past that the call ends
      (`speaker_backlog`) rather than drop words silently.

  `pump/1` answers what to send now, in order: `{:begin, segment,
  playback_id}`, `{:pcm, bytes}` and `{:end, segment}`.
  """

  @max_outstanding 8_192
  @max_frame 3_840
  @max_open 8
  # Two minutes of 24 kHz mono PCM16.
  @max_backlog 5_760_000

  defstruct credit: 0,
            backlog: :queue.new(),
            backlog_bytes: 0,
            odd: nil,
            taking: nil,
            open: MapSet.new(),
            next_segment: 1,
            reply: 0,
            starved?: false,
            counters: %{
              speaker_frames: 0,
              speaker_bytes: 0,
              segments: 0,
              flushes: 0,
              credit_waits: 0,
              backlog_peak_bytes: 0,
              speaker_bytes_dropped: 0
            }

  @type key :: %{playback_id: String.t() | nil, reply: non_neg_integer()}
  @type out ::
          {:begin, pos_integer(), String.t() | nil} | {:pcm, binary()} | {:end, pos_integer()}
  @type t :: %__MODULE__{}

  @doc "A call's speaker before its first grant."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The most audio the host holds for one call, in bytes."
  @spec max_backlog_bytes() :: pos_integer()
  def max_backlog_bytes, do: @max_backlog

  @doc """
  Queues one stretch of the engine's audio under its playback id (Grok's, or
  nil). A trailing odd byte waits for the next stretch of the same id and
  reply, which completes its sample; a stretch of another id or reply never
  takes it, so it is dropped and counted (`speaker_bytes_dropped`).
  """
  @spec audio(t(), binary(), String.t() | nil) :: {:ok, t()} | {:error, :speaker_backlog}
  def audio(%__MODULE__{} = s, pcm, playback_id)
      when is_binary(pcm) and (is_nil(playback_id) or is_binary(playback_id)) do
    key = %{playback_id: playback_id, reply: s.reply}
    {carried, s} = carried(s, key)
    data = carried <> pcm
    even = byte_size(data) - rem(byte_size(data), 2)
    <<samples::binary-size(even), odd::binary>> = data
    queued(%{s | odd: if(odd == <<>>, do: nil, else: {key, odd})}, key, samples)
  end

  defp carried(%{odd: nil} = s, _key), do: {<<>>, s}
  defp carried(%{odd: {key, byte}} = s, key), do: {byte, %{s | odd: nil}}

  defp carried(%{odd: {_other, byte}} = s, _key) do
    dropped = s.counters.speaker_bytes_dropped + byte_size(byte)
    {<<>>, %{s | odd: nil, counters: %{s.counters | speaker_bytes_dropped: dropped}}}
  end

  defp queued(s, _key, <<>>), do: {:ok, s}

  defp queued(s, key, samples) do
    bytes = s.backlog_bytes + byte_size(samples)

    if bytes > @max_backlog do
      {:error, :speaker_backlog}
    else
      peak = max(s.counters.backlog_peak_bytes, bytes)

      {:ok,
       %{
         s
         | backlog: :queue.in({key, samples}, s.backlog),
           backlog_bytes: bytes,
           counters: %{s.counters | backlog_peak_bytes: peak}
       }}
    end
  end

  @doc "The accessory granted `bytes` more credit."
  @spec credit(t(), pos_integer()) :: {:ok, t()} | {:error, :credit_overgrant}
  def credit(%__MODULE__{} = s, bytes) when is_integer(bytes) and bytes > 0 do
    if s.credit + bytes > @max_outstanding,
      do: {:error, :credit_overgrant},
      else: {:ok, %{s | credit: s.credit + bytes, starved?: false}}
  end

  @doc "The accessory played a segment's last sample."
  @spec drained(t(), pos_integer()) :: t()
  def drained(%__MODULE__{} = s, segment), do: %{s | open: MapSet.delete(s.open, segment)}

  @doc "The engine's reply ended (its state left speaking): later audio is a new segment."
  @spec reply_ended(t()) :: t()
  def reply_ended(%__MODULE__{} = s), do: %{s | reply: s.reply + 1}

  @doc """
  Drops everything queued and closes every open segment, as `spk.flush` does
  on the accessory. Answers whether there was anything to flush; credit is
  unchanged.
  """
  @spec flush(t()) :: {boolean(), t()}
  def flush(%__MODULE__{} = s) do
    anything? = s.taking != nil or MapSet.size(s.open) > 0 or s.backlog_bytes > 0
    flushes = s.counters.flushes + if(anything?, do: 1, else: 0)

    {anything?,
     %{
       s
       | backlog: :queue.new(),
         backlog_bytes: 0,
         odd: nil,
         taking: nil,
         open: MapSet.new(),
         reply: s.reply + 1,
         counters: %{s.counters | flushes: flushes}
     }}
  end

  @doc "What to send now, within credit and the segment rules, and the speaker after it."
  @spec pump(t()) :: {[out()], t()}
  def pump(%__MODULE__{} = s), do: pump(s, [], div(s.backlog_bytes, 2) + 2 * @max_open + 4)

  # Every step sends at least two bytes or begins or ends a segment, so the
  # backlog bounds the steps.
  defp pump(s, out, 0), do: {Enum.reverse(out), s}

  defp pump(s, out, budget) do
    case next(s) do
      {:wait, s} -> {Enum.reverse(out), s}
      {item, s} -> pump(s, [item | out], budget - 1)
    end
  end

  defp next(s) do
    case :queue.peek(s.backlog) do
      :empty -> idle(s)
      {:value, {key, samples}} -> audio_step(s, key, samples)
    end
  end

  # Nothing queued: a segment whose reply has ended is ended now.
  defp idle(%{taking: %{key: %{reply: reply}}} = s) when reply != s.reply, do: end_taking(s)
  defp idle(s), do: {:wait, s}

  defp audio_step(%{taking: %{key: taking}} = s, key, _samples) when taking != key,
    do: end_taking(s)

  defp audio_step(%{taking: nil} = s, key, _samples) do
    if MapSet.size(s.open) >= @max_open, do: {:wait, s}, else: begin(s, key)
  end

  defp audio_step(%{credit: credit} = s, _key, _samples) when credit < 2, do: starve(s)
  defp audio_step(s, _key, samples), do: send_frame(s, samples)

  defp starve(%{starved?: true} = s), do: {:wait, s}

  defp starve(s),
    do:
      {:wait,
       %{s | starved?: true, counters: %{s.counters | credit_waits: s.counters.credit_waits + 1}}}

  defp begin(s, key) do
    segment = s.next_segment

    {{:begin, segment, key.playback_id},
     %{
       s
       | taking: %{segment: segment, key: key},
         open: MapSet.put(s.open, segment),
         next_segment: segment + 1,
         counters: %{s.counters | segments: s.counters.segments + 1}
     }}
  end

  defp end_taking(s), do: {{:end, s.taking.segment}, %{s | taking: nil}}

  defp send_frame(s, samples) do
    size = Enum.min([@max_frame, s.credit - rem(s.credit, 2), byte_size(samples)])
    <<frame::binary-size(size), rest::binary>> = samples
    {_head, backlog} = :queue.out(s.backlog)
    backlog = if rest == <<>>, do: backlog, else: :queue.in_r({s.taking.key, rest}, backlog)

    {{:pcm, frame},
     %{
       s
       | backlog: backlog,
         backlog_bytes: s.backlog_bytes - size,
         credit: s.credit - size,
         counters: %{
           s.counters
           | speaker_frames: s.counters.speaker_frames + 1,
             speaker_bytes: s.counters.speaker_bytes + size
         }
     }}
  end

  @doc "Credit granted and not yet used."
  @spec outstanding(t()) :: non_neg_integer()
  def outstanding(%__MODULE__{credit: credit}), do: credit

  @doc "Audio waiting on the host, in bytes."
  @spec backlog_bytes(t()) :: non_neg_integer()
  def backlog_bytes(%__MODULE__{backlog_bytes: bytes}), do: bytes

  @doc "Segments begun and neither drained nor flushed."
  @spec open_segments(t()) :: non_neg_integer()
  def open_segments(%__MODULE__{open: open}), do: MapSet.size(open)

  @doc "What the speaker counted for the call's link event."
  @spec counters(t()) :: map()
  def counters(%__MODULE__{counters: counters}), do: counters
end
