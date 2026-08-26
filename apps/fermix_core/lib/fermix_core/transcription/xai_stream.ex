defmodule FermixCore.Transcription.XAIStream do
  @moduledoc """
  Native SpaceXAI (xAI) streaming session: s16le/16 kHz/mono PCM in over one
  WebSocket, finalized segments out, per the
  `FermixCore.Transcription.StreamSession` contract.

  Wire shape taken from xAI's streaming speech-to-text reference
  (https://docs.x.ai/developers/model-capabilities/audio/speech-to-text,
  retrieved 2026-08-17), which pins all three things this codec needs: the
  connection is configured entirely by query parameters (`encoding=pcm`,
  `sample_rate`, `channels`, `interim_results`) with no setup message, the
  upgrade authenticates with `Authorization: Bearer <key>`, and the server
  events are `transcript.created`, `transcript.partial` (`text`, `is_final`,
  `speech_final`, `start`, `duration`, `words`), `transcript.done` and `error`.
  The endpoint is modelless — `"grok-stt"` is a telemetry label only.

  `transcript.created` is a readiness signal the docs require waiting on before
  sending audio, so pushed PCM is held in the same bounded buffer a reconnect
  uses and flushed the moment it arrives. `finish/1` sends `audio.done`; the
  server then flushes and closes, and the session ends on `transcript.done` or
  the close, whichever lands first. A drain the socket does not survive — a
  crash, a cut connection — ends as `{:drain_interrupted, status}`: the tail
  xAI had not sent yet is lost, and a lost tail must never be reported as a
  clean close.

  Caps: `@max_reconnects` reconnects per stream lifetime,
  `@pcm_buffer_max_bytes` of held audio (overflow dropped, logged once,
  counted), `@max_malformed_frames` undecodable frames before
  `{:protocol_error, detail}`. A vendor `error` event fails the stream
  immediately, carrying xAI's own words — retrying past a refusal would only
  hide it.

  Timestamps are stream-absolute across a reconnect via an `offset_ms` base
  advanced by the audio actually sent, with the same in-flight imprecision (and
  the same buffer-cap bound) as the Deepgram session.
  """

  use GenServer

  require Logger

  alias FermixCore.Timeouts
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.Support
  alias FermixCore.Transcription.WsSocket
  alias FermixCore.Transcription.XAI

  @base_url "wss://api.x.ai/v1/stt"
  @provider :xai
  @sample_rate 16_000

  @max_reconnects 3
  @reconnect_delay_ms 250
  @pcm_buffer_max_bytes 960_000
  @max_malformed_frames 5
  @stream_preview_chars 500

  @doc """
  Starts an xAI streaming session and returns its pid, connected and ready to
  accept audio. Unlinked — the session is consumer-owned.
  """
  @spec open(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(consumer, api_key, opts)
      when is_pid(consumer) and is_binary(api_key) and is_list(opts) do
    GenServer.start(__MODULE__, {consumer, api_key, opts})
  end

  @doc """
  The streaming URL. No `model` parameter — the endpoint runs a single fixed
  model; `encoding=pcm` is xAI's spelling for signed 16-bit little-endian.
  """
  @spec url() :: String.t()
  def url do
    @base_url <> "?encoding=pcm&sample_rate=#{@sample_rate}&channels=1&interim_results=false"
  end

  @doc "The upgrade headers: xAI's API key as a bearer token (Grok OAuth is not accepted here)."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) when is_binary(api_key), do: [{"Authorization", "Bearer #{api_key}"}]

  @doc "The control frame that tells xAI no more audio is coming."
  @spec done_frame() :: String.t()
  def done_frame, do: ~s({"type":"audio.done"})

  @doc """
  Decodes one text frame against the stream-absolute `offset_ms` base.

  A final `transcript.partial` with text becomes a segment; `transcript.created`
  reports readiness; `transcript.done` ends the drain (its `text` repeats the
  whole transcript already delivered segment by segment, so it is never emitted
  again); an `error` event carries the vendor's own message out; anything
  undecodable or unexpectedly shaped is reported for the malformed-frame cap.
  """
  @spec decode_frame(binary(), non_neg_integer()) ::
          {:segment, Segment.t()}
          | :ready
          | :done
          | :ignore
          | {:error, {:malformed, String.t()} | {:vendor, String.t()}}
  def decode_frame(payload, offset_ms) when is_binary(payload) and is_integer(offset_ms) do
    case Jason.decode(payload) do
      {:ok, %{} = event} -> decode_event(event, offset_ms, payload)
      {:ok, _other} -> {:error, {:malformed, preview(payload)}}
      {:error, _reason} -> {:error, {:malformed, preview(payload)}}
    end
  end

  defp decode_event(%{"type" => "transcript.created"}, _offset_ms, _payload), do: :ready

  defp decode_event(%{"type" => "transcript.done"}, _offset_ms, _payload), do: :done

  defp decode_event(%{"type" => "error", "message" => message}, _offset_ms, _payload)
       when is_binary(message) do
    {:error, {:vendor, message}}
  end

  defp decode_event(
         %{
           "type" => "transcript.partial",
           "is_final" => true,
           "text" => text,
           "start" => start,
           "duration" => duration
         } = event,
         offset_ms,
         payload
       )
       when is_binary(text) and is_number(start) and is_number(duration) do
    partial_segment(event, text, start, duration, offset_ms, payload)
  end

  defp decode_event(%{"type" => "transcript.partial", "is_final" => false}, _offset_ms, _payload),
    do: :ignore

  defp decode_event(%{"type" => "transcript.partial"}, _offset_ms, payload),
    do: {:error, {:malformed, preview(payload)}}

  defp decode_event(%{"type" => type}, _offset_ms, _payload) when is_binary(type), do: :ignore

  defp decode_event(_event, _offset_ms, payload), do: {:error, {:malformed, preview(payload)}}

  defp partial_segment(event, text, start, duration, offset_ms, _payload) do
    case String.trim(text) do
      "" ->
        :ignore

      trimmed ->
        {:segment,
         %Segment{
           text: trimmed,
           t0_ms: ms(offset_ms, start),
           t1_ms: ms(offset_ms, start + duration),
           final?: true,
           words: words(Map.get(event, "words"), offset_ms)
         }}
    end
  end

  # Word timings are auxiliary: a list we cannot map entry-for-entry yields
  # `nil` rather than failing a segment whose transcript is perfectly good.
  defp words(list, offset_ms) when is_list(list),
    do: list |> Enum.map(&word(&1, offset_ms)) |> validated_words()

  defp words(_other, _offset_ms), do: nil

  defp word(%{"text" => text, "start" => start, "end" => stop}, offset_ms)
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
  def init({consumer, api_key, opts}) do
    socket_mod = Keyword.get(opts, :socket_mod, WsSocket)

    case socket_mod.start(url: url(), headers: headers(api_key), parent: self()) do
      {:ok, socket} -> {:ok, initial_state(consumer, api_key, opts, socket_mod, socket)}
      {:error, reason} -> {:stop, {:ws_start_failed, reason}}
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

  defp initial_state(consumer, api_key, opts, socket_mod, socket) do
    %{
      consumer: consumer,
      consumer_ref: Process.monitor(consumer),
      socket: socket,
      socket_ref: Process.monitor(socket),
      socket_mod: socket_mod,
      api_key: api_key,
      opts: opts,
      ready?: false,
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
      drain_timer: nil
    }
  end

  # Audio waits for `transcript.created` (and for a reconnect to complete): the
  # server documents itself as not ready before it, so sending early loses it.
  defp push(%{ready?: false} = state, pcm), do: buffer(state, pcm)

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
    %{state | buffer: [state.buffer, pcm], buffer_bytes: state.buffer_bytes + byte_size(pcm)}
  end

  defp drop(%{dropped_bytes: 0} = state, pcm) do
    Logger.error(
      "xai stream buffer full before the connection was ready: dropping audio " <>
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

    {:noreply, send_done(%{state | phase: :draining, drain_timer: drain_timer})}
  end

  # `audio.done` waits for readiness so the buffered audio precedes it.
  defp send_done(%{ready?: false} = state), do: state

  defp send_done(state) do
    :ok = state.socket_mod.send_text(state.socket, done_frame())
    state
  end

  defp text_frame(state, payload) do
    case decode_frame(payload, state.offset_ms) do
      {:segment, segment} -> {:noreply, emit(state, segment)}
      :ready -> {:noreply, ready(state)}
      :done -> closed(state)
      :ignore -> {:noreply, state}
      {:error, {:vendor, message}} -> fail(state, {:protocol_error, message})
      {:error, {:malformed, detail}} -> malformed(state, detail)
    end
  end

  defp ready(state) do
    %{state | ready?: true}
    |> flush_buffer()
    |> send_done_if_draining()
  end

  defp send_done_if_draining(%{phase: :draining} = state), do: send_done(state)
  defp send_done_if_draining(state), do: state

  defp emit(state, %Segment{} = segment) do
    send(state.consumer, {:transcript_segment, self(), segment})

    %{
      state
      | segments: state.segments + 1,
        preview: extend_preview(state.preview, segment.text)
    }
  end

  defp malformed(state, detail) do
    Logger.warning("xai stream frame undecodable: #{detail}")
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
         ready?: false,
         reconnects: state.reconnects + 1,
         offset_ms: state.offset_ms + samples_to_ms(state.sent_samples),
         sent_samples: 0
     }}
  end

  # xAI's own close after `audio.done` arrives as a remote-normal status:
  # WebSockex spells a code-less close frame `{:remote, :normal}` and a close
  # carrying 1000 — the RFC form of normal closure — `{:remote, 1000, payload}`
  # (`:closed` is the same close reported without a reason). Anything else — a
  # socket crash routed here as `{:down, reason}`, a transport error, a status
  # this codec has never seen — cut the drain before `transcript.done`, so it
  # fails loudly instead of passing for a finished stream.
  defp drain_close?(%{reason: {:remote, :normal}}), do: true
  defp drain_close?(%{reason: {:remote, 1000, _payload}}), do: true
  defp drain_close?(:closed), do: true
  defp drain_close?({:down, :normal}), do: true
  defp drain_close?(_status), do: false

  defp connect(state) do
    opened = state.socket_mod.start(url: url(), headers: headers(state.api_key), parent: self())

    case opened do
      {:ok, socket} ->
        {:noreply, %{state | socket: socket, socket_ref: Process.monitor(socket)}}

      {:error, reason} ->
        fail(state, {:ws_start_failed, reason})
    end
  end

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
    Support.emit_stream_call(@provider, XAI.telemetry_model(), state.opts, result, duration_ms)
    log_dropped_bytes(state)
    close_socket(state)
  end

  defp log_dropped_bytes(%{dropped_bytes: 0}), do: :ok

  defp log_dropped_bytes(state),
    do: Logger.error("xai stream dropped #{state.dropped_bytes} bytes of audio")

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
