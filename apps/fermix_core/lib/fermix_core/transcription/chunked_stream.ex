defmodule FermixCore.Transcription.ChunkedStream do
  @moduledoc """
  Serves the `FermixCore.Transcription.StreamSession` contract on top of a
  backend that only speaks batch files.

  Pushed PCM goes through `FermixCore.Transcription.EnergyVad`; each speech
  chunk it completes is written as a 16 kHz mono WAV under a session-owned temp
  dir (created `0700`, since in-flight speech is as sensitive as the transcript
  it becomes) and handed to `backend.transcribe/2` in a supervised task.
  Results come back out of order and are held until the in-order gate reaches
  them, so the consumer always sees segments in `t0_ms` order.

  Every unbounded thing has a named cap: `@max_inflight` transcribe calls run at
  once, `@max_pending` chunks queue behind them (overflow drops the NEWEST
  chunk, keeping delivered timestamps monotone), and a failing segment is tried
  `@segment_attempts` times before it is dropped. Drops are logged, counted, and
  reported in the terminal `closed` summary — the backend's own errored provider
  spans carry the reason, so no stream-level telemetry event is minted here (the
  batch spans already account for every call this adapter makes).
  """

  use GenServer

  require Logger

  alias FermixCore.Transcription.EnergyVad
  alias FermixCore.Transcription.Segment

  @max_inflight 8
  @max_pending 24
  # 1 initial attempt + 1 retry, then the segment is dropped.
  @segment_attempts 2

  @doc """
  Starts a chunked stream session for `backend` and returns its pid. Unlinked
  (the session is consumer-owned) and ready to accept audio on return.
  """
  @spec open(pid(), module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(consumer, backend, opts)
      when is_pid(consumer) and is_atom(backend) and is_list(opts) do
    GenServer.start(__MODULE__, {consumer, backend, opts})
  end

  @impl true
  def init({consumer, backend, opts}) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "fermix_stt_chunks_#{System.unique_integer([:positive])}")

    case own_dir(tmp_dir) do
      :ok -> {:ok, initial_state(consumer, backend, opts, tmp_dir)}
      {:error, reason} -> {:stop, reason}
    end
  end

  # The WAVs under here are meeting/voice-note speech — the same sensitivity
  # TranscriptStore pins at 0700/0600 — and `System.tmp_dir!()` is shared and
  # world-traversable, so the session's own dir is owner-only before any audio
  # is written. A chmod that fails refuses the session rather than streaming
  # speech into a readable directory.
  defp own_dir(tmp_dir) do
    with :ok <- File.mkdir_p(tmp_dir) do
      File.chmod(tmp_dir, 0o700)
    end
  end

  @impl true
  def handle_cast({:push_pcm, pcm}, state) do
    {vad, chunks} = EnergyVad.push(state.vad, pcm)
    {:noreply, %{state | vad: vad} |> enqueue_all(chunks) |> dispatch()}
  end

  def handle_cast(:finish, state) do
    {vad, chunks} = EnergyVad.flush(state.vad)

    %{state | vad: vad, finishing?: true}
    |> enqueue_all(chunks)
    |> dispatch()
    |> maybe_close()
  end

  @impl true
  def handle_call(:stop, _from, state) do
    state = cancel_inflight(state)
    cleanup(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({ref, {_index, result, t0_ms, t1_ms}}, %{inflight: inflight} = state)
      when is_reference(ref) and is_map_key(inflight, ref) do
    Process.demonitor(ref, [:flush])
    {job, remaining} = Map.pop(inflight, ref)

    %{state | inflight: remaining}
    |> record_result(job, result, t0_ms, t1_ms)
    |> deliver_ready()
    |> dispatch()
    |> maybe_close()
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{consumer_ref: ref} = state) do
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{inflight: inflight} = state)
      when is_map_key(inflight, ref) do
    {job, remaining} = Map.pop(inflight, ref)

    %{state | inflight: remaining}
    |> record_result(job, {:error, {:task_exit, reason}}, job.chunk.t0_ms, job.chunk.t1_ms)
    |> deliver_ready()
    |> dispatch()
    |> maybe_close()
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp initial_state(consumer, backend, opts, tmp_dir) do
    %{
      consumer: consumer,
      consumer_ref: Process.monitor(consumer),
      backend: backend,
      opts: opts,
      vad: EnergyVad.new(),
      tmp_dir: tmp_dir,
      next_index: 0,
      emit_index: 0,
      inflight: %{},
      pending: :queue.new(),
      results: %{},
      attempts: %{},
      dropped: 0,
      finishing?: false,
      segments_emitted: 0
    }
  end

  defp enqueue_all(state, chunks), do: Enum.reduce(chunks, state, &enqueue/2)

  # Drop-newest on overflow: the queue only fills when the backend is running
  # many minutes behind realtime, and dropping the newest keeps every delivered
  # timestamp monotone.
  defp enqueue(chunk, state) do
    case :queue.len(state.pending) >= @max_pending do
      true -> drop_overflow(state, chunk)
      false -> accept(state, chunk)
    end
  end

  defp accept(state, chunk) do
    %{
      state
      | pending: :queue.in({state.next_index, chunk}, state.pending),
        next_index: state.next_index + 1
    }
  end

  defp drop_overflow(state, chunk) do
    Logger.error("transcription chunk dropped (pending queue full): t0=#{chunk.t0_ms}ms")
    %{state | dropped: state.dropped + 1}
  end

  # Bounded: one task per free slot, at most @max_inflight live at any moment.
  defp dispatch(%{inflight: inflight} = state) when map_size(inflight) >= @max_inflight, do: state

  defp dispatch(state) do
    case :queue.out(state.pending) do
      {:empty, _queue} -> state
      {{:value, {index, chunk}}, rest} -> state |> start_task(index, chunk, rest) |> dispatch()
    end
  end

  defp start_task(state, index, chunk, rest) do
    %{backend: backend, opts: opts, tmp_dir: tmp_dir} = state

    task =
      Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn ->
        run_segment(backend, opts, tmp_dir, index, chunk)
      end)

    job = %{index: index, pid: task.pid, chunk: chunk}
    %{state | pending: rest, inflight: Map.put(state.inflight, task.ref, job)}
  end

  # Runs inside the task: own the WAV file end to end, removing it on both arms.
  defp run_segment(backend, opts, tmp_dir, index, chunk) do
    path = Path.join(tmp_dir, "seg_#{index}.wav")

    result =
      case File.write(path, wav_bytes(chunk.pcm)) do
        :ok -> backend.transcribe(path, opts)
        {:error, reason} -> {:error, {:wav_write_failed, reason}}
      end

    _ = File.rm(path)
    {index, result, chunk.t0_ms, chunk.t1_ms}
  end

  defp record_result(state, job, {:ok, text}, t0_ms, t1_ms) do
    case String.trim(text) do
      "" -> resolve(state, job.index, :skip)
      trimmed -> resolve(state, job.index, segment(trimmed, t0_ms, t1_ms))
    end
  end

  defp record_result(state, job, {:error, reason}, _t0_ms, _t1_ms) do
    attempts = Map.get(state.attempts, job.index, 0) + 1
    state = %{state | attempts: Map.put(state.attempts, job.index, attempts)}
    retry_or_drop(state, job, reason, attempts)
  end

  defp retry_or_drop(state, job, _reason, attempts) when attempts < @segment_attempts do
    %{state | pending: :queue.in_r({job.index, job.chunk}, state.pending)}
  end

  defp retry_or_drop(state, job, reason, _attempts) do
    Logger.error(
      "transcription segment dropped after #{@segment_attempts} attempts: " <>
        "#{inspect(reason)} t0=#{job.chunk.t0_ms}ms"
    )

    state
    |> Map.update!(:dropped, &(&1 + 1))
    |> resolve(job.index, :skip)
  end

  defp segment(text, t0_ms, t1_ms) when is_binary(text) and t1_ms >= t0_ms do
    %Segment{text: text, t0_ms: t0_ms, t1_ms: t1_ms, final?: true}
  end

  defp resolve(state, index, outcome),
    do: %{state | results: Map.put(state.results, index, outcome)}

  # In-order gate: bounded by the held results, which the in-flight cap bounds.
  defp deliver_ready(state) do
    case Map.pop(state.results, state.emit_index) do
      {nil, _results} -> state
      {outcome, results} -> state |> deliver(outcome, results) |> deliver_ready()
    end
  end

  defp deliver(state, :skip, results) do
    %{state | results: results, emit_index: state.emit_index + 1}
  end

  defp deliver(state, %Segment{} = segment, results) do
    send(state.consumer, {:transcript_segment, self(), segment})

    %{
      state
      | results: results,
        emit_index: state.emit_index + 1,
        segments_emitted: state.segments_emitted + 1
    }
  end

  defp maybe_close(state) do
    case state.finishing? and :queue.is_empty(state.pending) and state.inflight == %{} do
      true -> close(state)
      false -> {:noreply, state}
    end
  end

  defp close(state) do
    summary = %{segments: state.segments_emitted, dropped: state.dropped}
    send(state.consumer, {:transcript_stream_closed, self(), summary})
    cleanup(state)
    {:stop, :normal, state}
  end

  defp cancel_inflight(state) do
    Enum.each(state.inflight, fn {ref, job} ->
      Process.demonitor(ref, [:flush])
      Task.Supervisor.terminate_child(FermixCore.TaskSupervisor, job.pid)
    end)

    %{state | inflight: %{}}
  end

  # The temp dir is this session's own, created under a unique prefix in init.
  defp cleanup(state), do: File.rm_rf(state.tmp_dir)

  # Canonical 44-byte header: PCM, mono, 16 kHz, 16-bit — the one shape the
  # batch backends receive from this adapter.
  defp wav_bytes(pcm) do
    <<"RIFF", 36 + byte_size(pcm)::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, 16_000::little-32, 32_000::little-32, 2::little-16, 16::little-16, "data",
      byte_size(pcm)::little-32, pcm::binary>>
  end
end
