defmodule FermixCore.Transcription.DeepgramStream do
  @moduledoc """
  Native Deepgram streaming session: s16le/16 kHz/mono PCM in over one
  WebSocket, finalized segments out, per the
  `FermixCore.Transcription.StreamSession` contract.

  Audio rides as binary frames; the only text frames sent are `KeepAlive` every
  `@keepalive_interval_ms` (Deepgram closes an idle connection after ~10 s, and
  a meeting is mostly silence) and `CloseStream` on `finish/1`, after which the
  session drains until Deepgram's final results and its own close arrive. A
  drain the socket does not survive — a crash, a cut connection — ends as
  `{:drain_interrupted, status}`: the tail Deepgram had not sent yet is lost,
  and a lost tail must never be reported as a clean close.

  Every unbounded thing is capped: `@max_reconnects` reconnects per stream
  lifetime, `@pcm_buffer_max_bytes` of audio held across a reconnect gap
  (overflow is dropped, logged once, and counted), and `@max_malformed_frames`
  undecodable frames before the stream fails as `{:protocol_error, detail}`. A
  failed reconnect is terminal — the bounded reconnect IS the single recovery
  step, and there is no second mechanism behind it.

  Timestamp caveat: Deepgram restarts its media clock on every connection, so
  the session carries an `offset_ms` base advanced by the audio it has actually
  sent. Audio buffered but not yet sent when a connection drops is not counted,
  which shifts post-reconnect timestamps by at most the buffer cap's worth of
  audio. That imprecision is accepted in this phase and bounded by the cap.
  """

  use GenServer

  require Logger

  alias FermixCore.Timeouts
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.Support
  alias FermixCore.Transcription.WsSocket

  @base_url "wss://api.deepgram.com/v1/listen"
  @provider :deepgram
  @sample_rate 16_000

  # Per stream LIFETIME, not consecutive: a stream that keeps losing its socket
  # is broken, and retrying forever hides that from the operator.
  @max_reconnects 3
  # A brief backoff before re-dialing, so a vendor that just dropped us is not
  # hammered — and so pushed audio lands in the bounded buffer rather than an
  # unbounded mailbox while we wait.
  @reconnect_delay_ms 250
  # 30 s of audio held while reconnecting.
  @pcm_buffer_max_bytes 960_000
  @max_malformed_frames 5
  @keepalive_interval_ms 5_000
  @stream_preview_chars 500

  @doc """
  Starts a Deepgram streaming session and returns its pid, connected and ready
  to accept audio. Unlinked — the session is consumer-owned.
  """
  @spec open(pid(), String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(consumer, api_key, model, opts)
      when is_pid(consumer) and is_binary(api_key) and is_binary(model) and is_list(opts) do
    GenServer.start(__MODULE__, {consumer, api_key, model, opts})
  end

  @doc """
  The streaming URL for `model`. `encoding`/`sample_rate`/`channels` pin the one
  PCM format a session speaks; `smart_format` matches the batch backend's
  punctuated output; interim results are off in this phase.
  """
  @spec url(String.t()) :: String.t()
  def url(model) when is_binary(model) do
    @base_url <>
      "?model=" <>
      URI.encode_www_form(model) <>
      "&encoding=linear16&sample_rate=#{@sample_rate}&channels=1" <>
      "&smart_format=true&interim_results=false"
  end

  @doc "The upgrade headers: Deepgram's `Token` auth scheme, same as the batch endpoint."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) when is_binary(api_key), do: [{"Authorization", "Token #{api_key}"}]

  @doc "The periodic control frame that keeps an idle connection from being closed."
  @spec keepalive_frame() :: String.t()
  def keepalive_frame, do: ~s({"type":"KeepAlive"})

  @doc "The control frame that tells Deepgram no more audio is coming."
  @spec close_frame() :: String.t()
  def close_frame, do: ~s({"type":"CloseStream"})

  @doc """
  Decodes one text frame against the stream-absolute `offset_ms` base.

  A final `Results` frame with text becomes a segment; an empty one (a silence
  flush) and every other known frame type are ignored; anything undecodable or
  shaped unexpectedly is reported so the caller can count it against the
  malformed-frame cap.
  """
  @spec decode_frame(binary(), non_neg_integer()) ::
          {:segment, Segment.t()} | :ignore | {:error, {:malformed, String.t()}}
  def decode_frame(payload, offset_ms) when is_binary(payload) and is_integer(offset_ms) do
    case Jason.decode(payload) do
      {:ok, %{} = event} -> decode_event(event, offset_ms, payload)
      {:ok, _other} -> {:error, {:malformed, preview(payload)}}
      {:error, _reason} -> {:error, {:malformed, preview(payload)}}
    end
  end

  defp decode_event(
         %{
           "type" => "Results",
           "is_final" => true,
           "start" => start,
           "duration" => duration,
           "channel" => %{"alternatives" => [alternative | _rest]}
         },
         offset_ms,
         payload
       )
       when is_number(start) and is_number(duration) and is_map(alternative) do
    result_segment(alternative, start, duration, offset_ms, payload)
  end

  defp decode_event(%{"type" => "Results", "is_final" => false}, _offset_ms, _payload),
    do: :ignore

  defp decode_event(%{"type" => "Results"}, _offset_ms, payload),
    do: {:error, {:malformed, preview(payload)}}

  defp decode_event(%{"type" => type}, _offset_ms, _payload) when is_binary(type), do: :ignore

  defp decode_event(_event, _offset_ms, payload), do: {:error, {:malformed, preview(payload)}}

  defp result_segment(%{"transcript" => transcript} = alternative, start, duration, offset_ms, _p)
       when is_binary(transcript) do
    case String.trim(transcript) do
      "" ->
        :ignore

      text ->
        {:segment,
         %Segment{
           text: text,
           t0_ms: ms(offset_ms, start),
           t1_ms: ms(offset_ms, start + duration),
           final?: true,
           words: words(Map.get(alternative, "words"), offset_ms)
         }}
    end
  end

  defp result_segment(_alternative, _start, _duration, _offset_ms, payload),
    do: {:error, {:malformed, preview(payload)}}

  # Word timings are auxiliary: a list we cannot map entry-for-entry yields
  # `nil` rather than failing a segment whose transcript is perfectly good.
  defp words(list, offset_ms) when is_list(list),
    do: list |> Enum.map(&word(&1, offset_ms)) |> validated_words()

  defp words(_other, _offset_ms), do: nil

  defp word(%{"word" => text, "start" => start, "end" => stop}, offset_ms)
       when is_binary(text) and is_number(start) and is_number(stop) do
    %{text: text, t0_ms: ms(offset_ms, start), t1_ms: ms(offset_ms, stop)}
  end

  defp word(_other, _offset_ms), do: nil

  defp validated_words([]), do: nil

  defp validated_words(mapped) do
    case Enum.any?(mapped, &is_nil/1) do
      true -> nil
      false -> mapped
    end
  end

  defp ms(offset_ms, seconds), do: offset_ms + round(seconds * 1000)

  defp preview(payload), do: binary_part(payload, 0, min(byte_size(payload), 120))

  @impl true
  def init({consumer, api_key, model, opts}) do
    socket_mod = Keyword.get(opts, :socket_mod, WsSocket)

    case socket_mod.start(url: url(model), headers: headers(api_key), parent: self()) do
      {:ok, socket} ->
        {:ok, initial_state(consumer, api_key, model, opts, socket_mod, socket)}

      {:error, reason} ->
        {:stop, {:ws_start_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:push_pcm, pcm}, state), do: {:noreply, push(state, pcm)}

  def handle_cast(:finish, state), do: finish(state)

  @impl true
  def handle_call(:stop, _from, state) do
    terminal(state, {:error, :aborted})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:transcription_ws, socket, {:frame, {:text, payload}}}, %{socket: socket} = s),
    do: text_frame(s, payload)

  def handle_info(
        {:transcription_ws, socket, {:frame, {:binary, _payload}}},
        %{socket: socket} = s
      ),
      do: malformed(s, "unexpected binary frame")

  def handle_info({:transcription_ws, socket, {:disconnect, status}}, %{socket: socket} = state),
    do: disconnected(state, status)

  # No consumer send (it is the process that just died) — but the terminal
  # span still goes out: a consumer crash is the one terminal where only the
  # trace can say what the stream cost and why it ended.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{consumer_ref: ref} = state) do
    terminal(state, {:error, :consumer_down})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{socket_ref: ref} = state),
    do: disconnected(state, {:down, reason})

  def handle_info(:reconnect, state), do: connect(state)

  def handle_info(:keepalive, state), do: keepalive(state)

  def handle_info(:drain_timeout, state) do
    {:error, reason} =
      Timeouts.expired(:transcription_ws_close_drain, Timeouts.transcription_ws_close_drain(), %{
        session_id: Keyword.get(state.opts, :session_id)
      })

    fail(state, reason)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_socket(state)
    :ok
  end

  defp initial_state(consumer, api_key, model, opts, socket_mod, socket) do
    %{
      consumer: consumer,
      consumer_ref: Process.monitor(consumer),
      socket: socket,
      socket_ref: Process.monitor(socket),
      socket_mod: socket_mod,
      api_key: api_key,
      model: model,
      opts: opts,
      sent_samples: 0,
      offset_ms: 0,
      buffer: [],
      buffer_bytes: 0,
      reconnects: 0,
      malformed: 0,
      phase: :streaming,
      started_at_ms: System.monotonic_time(:millisecond),
      segments: 0,
      dropped_bytes: 0,
      preview: "",
      drain_timer: nil,
      keepalive_timer: Process.send_after(self(), :keepalive, @keepalive_interval_ms)
    }
  end

  defp push(%{socket: nil} = state, pcm), do: buffer(state, pcm)

  defp push(state, pcm) do
    :ok = state.socket_mod.send_binary(state.socket, pcm)
    %{state | sent_samples: state.sent_samples + div(byte_size(pcm), 2)}
  end

  defp buffer(state, pcm) do
    case state.buffer_bytes + byte_size(pcm) > @pcm_buffer_max_bytes do
      true -> drop(state, pcm)
      false -> hold(state, pcm)
    end
  end

  defp hold(state, pcm) do
    %{
      state
      | buffer: [state.buffer, pcm],
        buffer_bytes: state.buffer_bytes + byte_size(pcm)
    }
  end

  defp drop(%{dropped_bytes: 0} = state, pcm) do
    Logger.error(
      "deepgram stream buffer full while reconnecting: dropping audio " <>
        "(cap #{@pcm_buffer_max_bytes} bytes)"
    )

    %{state | dropped_bytes: byte_size(pcm)}
  end

  defp drop(state, pcm), do: %{state | dropped_bytes: state.dropped_bytes + byte_size(pcm)}

  defp flush_buffer(%{buffer_bytes: 0} = state), do: state

  defp flush_buffer(state) do
    pcm = IO.iodata_to_binary(state.buffer)
    :ok = state.socket_mod.send_binary(state.socket, pcm)

    %{
      state
      | buffer: [],
        buffer_bytes: 0,
        sent_samples: state.sent_samples + div(byte_size(pcm), 2)
    }
  end

  defp finish(%{phase: :draining} = state), do: {:noreply, state}

  defp finish(state) do
    drain_timer =
      Process.send_after(self(), :drain_timeout, Timeouts.transcription_ws_close_drain())

    {:noreply, send_close(%{state | phase: :draining, drain_timer: drain_timer})}
  end

  # The close frame waits for the socket when one is being re-established; the
  # reconnect path sends it as soon as the new connection is up.
  defp send_close(%{socket: nil} = state), do: state

  defp send_close(state) do
    :ok = state.socket_mod.send_text(state.socket, close_frame())
    state
  end

  defp text_frame(state, payload) do
    case decode_frame(payload, state.offset_ms) do
      {:segment, segment} -> {:noreply, emit(state, segment)}
      :ignore -> {:noreply, state}
      {:error, {:malformed, detail}} -> malformed(state, detail)
    end
  end

  defp emit(state, %Segment{} = segment) do
    send(state.consumer, {:transcript_segment, self(), segment})

    %{
      state
      | segments: state.segments + 1,
        preview: extend_preview(state.preview, segment.text)
    }
  end

  defp malformed(state, detail) do
    Logger.warning("deepgram stream frame undecodable: #{detail}")
    state = %{state | malformed: state.malformed + 1}

    case state.malformed > @max_malformed_frames do
      true -> fail(state, {:protocol_error, detail})
      false -> {:noreply, state}
    end
  end

  defp disconnected(%{phase: :draining} = state, status) do
    case drain_close?(status) do
      true -> closed(state)
      false -> fail(state, {:drain_interrupted, status})
    end
  end

  defp disconnected(%{reconnects: reconnects} = state, status)
       when reconnects >= @max_reconnects do
    fail(state, {:reconnect_exhausted, status})
  end

  defp disconnected(state, _status) do
    Process.demonitor(state.socket_ref, [:flush])
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)

    {:noreply,
     %{
       state
       | socket: nil,
         socket_ref: nil,
         reconnects: state.reconnects + 1,
         offset_ms: state.offset_ms + samples_to_ms(state.sent_samples),
         sent_samples: 0
     }}
  end

  # Deepgram's own close after `CloseStream` arrives as a remote-normal status:
  # WebSockex spells a code-less close frame `{:remote, :normal}` and a close
  # carrying 1000 — the RFC form of normal closure — `{:remote, 1000, payload}`
  # (`:closed` is the same close reported without a reason). Anything else — a
  # socket crash routed here as `{:down, reason}`, a transport error, a status
  # this codec has never seen — cut the drain before the final results, so it
  # fails loudly instead of passing for a finished stream.
  defp drain_close?(%{reason: {:remote, :normal}}), do: true
  defp drain_close?(%{reason: {:remote, 1000, _payload}}), do: true
  defp drain_close?(:closed), do: true
  defp drain_close?({:down, :normal}), do: true
  defp drain_close?(_status), do: false

  defp connect(state) do
    opened =
      state.socket_mod.start(
        url: url(state.model),
        headers: headers(state.api_key),
        parent: self()
      )

    case opened do
      {:ok, socket} -> {:noreply, resumed(state, socket)}
      {:error, reason} -> fail(state, {:ws_start_failed, reason})
    end
  end

  defp resumed(state, socket) do
    %{state | socket: socket, socket_ref: Process.monitor(socket)}
    |> flush_buffer()
    |> send_close_if_draining()
  end

  defp send_close_if_draining(%{phase: :draining} = state), do: send_close(state)
  defp send_close_if_draining(state), do: state

  defp keepalive(%{phase: :draining} = state), do: {:noreply, state}

  defp keepalive(%{socket: nil} = state), do: {:noreply, schedule_keepalive(state)}

  defp keepalive(state) do
    :ok = state.socket_mod.send_text(state.socket, keepalive_frame())
    {:noreply, schedule_keepalive(state)}
  end

  defp schedule_keepalive(state),
    do: %{state | keepalive_timer: Process.send_after(self(), :keepalive, @keepalive_interval_ms)}

  # A native stream drops no segments: the byte-level drops a reconnect can
  # cause are logged and ride the span, not the consumer's close summary.
  defp closed(state) do
    send(
      state.consumer,
      {:transcript_stream_closed, self(), %{segments: state.segments, dropped: 0}}
    )

    terminal(state, {:ok, state.preview})
    {:stop, :normal, state}
  end

  defp fail(state, reason) do
    send(state.consumer, {:transcript_stream_error, self(), reason})
    terminal(state, {:error, reason})
    {:stop, :normal, state}
  end

  defp terminal(state, result) do
    duration_ms = System.monotonic_time(:millisecond) - state.started_at_ms
    Support.emit_stream_call(@provider, state.model, state.opts, result, duration_ms)
    log_dropped_bytes(state)
    close_socket(state)
  end

  defp log_dropped_bytes(%{dropped_bytes: 0}), do: :ok

  defp log_dropped_bytes(state),
    do: Logger.error("deepgram stream dropped #{state.dropped_bytes} bytes of audio")

  defp close_socket(%{socket: nil}), do: :ok
  defp close_socket(state), do: state.socket_mod.close(state.socket)

  defp samples_to_ms(samples), do: div(samples * 1000, @sample_rate)

  defp extend_preview(preview, text) do
    case String.length(preview) >= @stream_preview_chars do
      true -> preview
      false -> String.slice(join_preview(preview, text), 0, @stream_preview_chars)
    end
  end

  defp join_preview("", text), do: text
  defp join_preview(preview, text), do: preview <> " " <> text
end
