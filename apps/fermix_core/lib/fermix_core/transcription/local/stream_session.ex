defmodule FermixCore.Transcription.Local.StreamSession do
  @moduledoc """
  On-device streaming session: s16le/16 kHz/mono PCM in over a `fermix-stt`
  sidecar, finalized segments out, per the
  `FermixCore.Transcription.StreamSession` contract.

  One sidecar is spawned per session, so the model-load cost is paid once and
  amortized over the stream. Audio rides base64 inside `audio` frames capped at
  `Sidecar.audio_chunk_bytes/0`; the sidecar's own VAD decides where segments
  end, and they arrive already in order because it recognizes serially.

  There is deliberately **no respawn**: the pipe is local, so a sidecar that
  dies is a bug to surface (`{:sidecar_exit, status}`), not a condition to retry
  around. The bounded things here are the two deadlines — model load at start
  and the flush after `stream_end` — both named in `FermixCore.Timeouts`.
  """

  use GenServer

  alias FermixCore.Timeouts
  alias FermixCore.Transcription.Local
  alias FermixCore.Transcription.Local.Sidecar
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.Support

  @provider :local
  @stream_id "s1"
  @sample_rate 16_000
  @format "s16le"
  @channels 1
  @stream_preview_chars 500

  @doc """
  Starts a local streaming session and returns its pid, with the sidecar
  spawned, handshaken, and its model loaded. Unlinked — the session is
  consumer-owned.
  """
  @spec open(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(consumer, opts) when is_pid(consumer) and is_list(opts),
    do: GenServer.start(__MODULE__, {consumer, opts})

  @impl true
  def init({consumer, opts}) do
    with {:ok, dir} <- Sidecar.model_dir(opts),
         {:ok, sidecar} <- Sidecar.open(opts),
         {:ok, sidecar} <- start_stream(sidecar, dir, opts) do
      {:ok, initial_state(consumer, opts, sidecar)}
    else
      {:error, reason} -> {:stop, reason}
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
  def handle_info({port, {:data, data}}, %{sidecar: %{port: port}} = state),
    do: port_data(state, data)

  def handle_info({port, {:exit_status, status}}, %{sidecar: %{port: port}} = state),
    do: fail(detached(state), {:sidecar_exit, status})

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{consumer_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:flush_timeout, state) do
    {:error, reason} =
      Timeouts.expired(:stt_sidecar_flush, Sidecar.flush_timeout(state.opts), %{
        session_id: Keyword.get(state.opts, :session_id)
      })

    fail(state, reason)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Sidecar.close(state.sidecar)
    :ok
  end

  # The stream-start wait covers model load, which is why it uses the hello
  # budget rather than a tighter one; raise it to `stt_sidecar_batch` if a
  # measured cold load on the gate hardware ever exceeds it.
  defp start_stream(sidecar, dir, opts) do
    op = %{
      "op" => "stream_start",
      "id" => @stream_id,
      "model_dir" => dir,
      "sample_rate" => @sample_rate,
      "format" => @format,
      "channels" => @channels
    }

    case Sidecar.send_op(sidecar, op) do
      :ok -> await_started(sidecar, opts)
      {:error, :closed} -> refuse(sidecar, {:sidecar_exit, :closed})
    end
  end

  defp await_started(sidecar, opts) do
    case Sidecar.await(sidecar, Sidecar.hello_timeout(opts), :stt_sidecar_hello) do
      {:ok, %{"event" => "stream_started"}, sidecar} ->
        {:ok, sidecar}

      {:ok, %{"event" => "error"} = frame, sidecar} ->
        refuse(sidecar, Sidecar.error_reason(frame))

      {:ok, frame, sidecar} ->
        refuse(sidecar, {:protocol_error, {:unexpected_event, Map.get(frame, "event")}})

      {:error, reason, sidecar} ->
        refuse(sidecar, reason)
    end
  end

  defp refuse(sidecar, reason) do
    Sidecar.close(sidecar)
    {:error, reason}
  end

  defp initial_state(consumer, opts, sidecar) do
    %{
      consumer: consumer,
      consumer_ref: Process.monitor(consumer),
      sidecar: sidecar,
      opts: opts,
      phase: :streaming,
      segments: 0,
      preview: "",
      started_at_ms: System.monotonic_time(:millisecond)
    }
  end

  # Audio pushed after `finish/1` would reach the sidecar behind its `stream_end`
  # and be refused as a protocol violation, so a late chunk is dropped here
  # rather than turning a benign race into a failed stream.
  defp push(%{phase: :draining} = state, _pcm), do: state

  defp push(state, pcm) do
    Enum.each(Sidecar.chunk_pcm(pcm), &send_audio(state, &1))
    state
  end

  defp send_audio(state, chunk) do
    Sidecar.send_op(state.sidecar, %{
      "op" => "audio",
      "id" => @stream_id,
      "pcm" => Base.encode64(chunk)
    })
  end

  defp finish(%{phase: :draining} = state), do: {:noreply, state}

  defp finish(state) do
    _timer = Process.send_after(self(), :flush_timeout, Sidecar.flush_timeout(state.opts))
    state = %{state | phase: :draining}

    case Sidecar.send_op(state.sidecar, %{"op" => "stream_end", "id" => @stream_id}) do
      :ok -> {:noreply, state}
      {:error, :closed} -> fail(state, {:sidecar_exit, :closed})
    end
  end

  defp port_data(state, data) do
    case Sidecar.handle_data(state.sidecar, data) do
      {:line, frame, sidecar} -> event(%{state | sidecar: sidecar}, frame)
      {:partial, sidecar} -> {:noreply, %{state | sidecar: sidecar}}
      {:error, reason, sidecar} -> fail(%{state | sidecar: sidecar}, reason)
    end
  end

  defp event(
         state,
         %{"event" => "segment", "text" => text, "t0_ms" => t0_ms, "t1_ms" => t1_ms}
       )
       when is_binary(text) and is_integer(t0_ms) and is_integer(t1_ms) and t0_ms >= 0 and
              t1_ms >= t0_ms do
    {:noreply, segment(state, String.trim(text), t0_ms, t1_ms)}
  end

  defp event(state, %{"event" => "segment"} = frame),
    do: fail(state, {:protocol_error, {:malformed_segment, Map.get(frame, "id")}})

  defp event(state, %{"event" => "stream_done"}), do: closed(state)

  defp event(state, %{"event" => "error"} = frame),
    do: fail(state, Sidecar.error_reason(frame))

  defp event(state, frame),
    do: fail(state, {:protocol_error, {:unexpected_event, Map.get(frame, "event")}})

  # A segment with no words in it is a VAD run that recognized nothing; the
  # contract says producers never emit empty segments.
  defp segment(state, "", _t0_ms, _t1_ms), do: state

  defp segment(state, text, t0_ms, t1_ms) do
    seg = %Segment{text: text, t0_ms: t0_ms, t1_ms: t1_ms, final?: true, words: nil}
    send(state.consumer, {:transcript_segment, self(), seg})

    %{state | segments: state.segments + 1, preview: extend_preview(state.preview, text)}
  end

  # A local stream drops nothing: there is no network between the two processes,
  # so a lost segment would be a crash, which is reported as an error instead.
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
    model = Local.identity().model
    Support.emit_stream_call(@provider, model, state.opts, result, duration_ms)
    Sidecar.close(state.sidecar)
  end

  defp detached(state), do: %{state | sidecar: %{state.sidecar | port: nil}}

  defp extend_preview(preview, text) do
    case String.length(preview) >= @stream_preview_chars do
      true -> preview
      false -> String.slice(join_preview(preview, text), 0, @stream_preview_chars)
    end
  end

  defp join_preview("", text), do: text
  defp join_preview(preview, text), do: preview <> " " <> text
end
