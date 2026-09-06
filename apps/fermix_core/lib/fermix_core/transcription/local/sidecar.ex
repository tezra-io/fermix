defmodule FermixCore.Transcription.Local.Sidecar do
  @moduledoc """
  Port owner and codec for the `fermix-stt` sidecar.

  The wire is **NDJSON in both directions** — one JSON object per line, UTF-8,
  `\\n`-terminated — with PCM riding base64 inside `audio` frames. At 16 kHz mono
  s16le that is ~43 KB/s over a local pipe, so the bandwidth a binary framing
  would save is not worth running two framing disciplines on one file
  descriptor. The compux sidecar set the precedent, down to the perl fake this
  module is tested against.

  Frames the sidecar sends carry `"event"`; frames fermix sends carry `"op"`.
  The full vocabulary and the sidecar's obligations live in the fermix-stt
  repo's PROTOCOL.md, seeded from this contract; the golden fixtures beside the
  tests pin the exact bytes.

  `hello` is refused on any `protocol_version` other than the one this build
  speaks — the compiled-in codec and a separately installed binary must never
  silently drift, and the version is never negotiated.

  There is no process here on purpose: the caller owns the port, so port
  messages land in the caller's mailbox. `batch/2` is a one-shot call frame
  (spawn → hello → transcribe → result → shutdown); a stream is owned by
  `FermixCore.Transcription.Local.StreamSession`. Both close the port on every
  exit path.
  """

  alias FermixCore.ProcessGroup
  alias FermixCore.Timeouts
  alias FermixCore.Transcription.Local
  alias FermixCore.Transcription.Local.ModelStore
  alias FermixCore.Transcription.Local.SidecarInstaller

  @protocol_version 1

  # The port's line-reassembly window. Lines are routinely longer than this (a
  # 64 KB PCM chunk is ~87 KB of base64, a batch transcript can reach ~1 MB), so
  # `{:noeol, _}` fragments are the normal case, not an error case.
  @line_bytes 65_536
  # The bound on that reassembly: a line past this is a protocol error, never
  # more buffering.
  @max_line_bytes 8_388_608
  # Raw PCM bytes per `audio` frame, before base64.
  @audio_chunk_bytes 65_536

  @typedoc """
  An open sidecar: its port, the child's OS pid (its own process-group id — the
  kill target for a wedged teardown), the partial line being reassembled, and
  the correlation id.
  """
  @type state :: %{
          port: port() | nil,
          os_pid: pos_integer(),
          acc: binary(),
          session_id: String.t() | nil
        }

  # How long close/1 waits for the sidecar to honor the `shutdown` op before
  # SIGKILLing its process group. A healthy exit lands in milliseconds and pays
  # nothing; only a sidecar wedged in model load or inference burns the grace.
  @shutdown_grace_ms 500

  @typedoc "One decoded NDJSON frame from the sidecar."
  @type frame :: map()

  @doc "The wire protocol version this build speaks. Never negotiated."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Raw PCM bytes carried per `audio` frame."
  @spec audio_chunk_bytes() :: pos_integer()
  def audio_chunk_bytes, do: @audio_chunk_bytes

  @doc "Encodes one op map as an NDJSON line."
  @spec encode(map()) :: iodata()
  def encode(op) when is_map(op), do: [Jason.encode_to_iodata!(op), "\n"]

  @doc "Decodes one NDJSON line (the port strips the terminator) into a frame map."
  @spec decode_line(binary()) :: {:ok, frame()} | {:error, {:malformed, String.t()}}
  def decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{} = frame} -> {:ok, frame}
      {:ok, _other} -> {:error, {:malformed, preview(line)}}
      {:error, _reason} -> {:error, {:malformed, preview(line)}}
    end
  end

  @doc """
  Splits PCM into frames of at most `audio_chunk_bytes/0`. Sample alignment is
  preserved because the cap is even and callers push s16le.
  """
  @spec chunk_pcm(binary()) :: [binary()]
  def chunk_pcm(pcm) when is_binary(pcm) and byte_size(pcm) <= @audio_chunk_bytes, do: [pcm]

  def chunk_pcm(pcm) when is_binary(pcm) do
    <<head::binary-size(@audio_chunk_bytes), rest::binary>> = pcm
    [head | chunk_pcm(rest)]
  end

  @doc """
  Spawns the sidecar and completes the `hello` handshake, returning an open
  state ready for ops.

  `opts` carries the DI seams `binary_path:`, `env:`, `args:` and
  `hello_timeout_ms:`; production callers pass none of them.
  """
  @spec open(keyword()) :: {:ok, state()} | {:error, term()}
  def open(opts) when is_list(opts) do
    with {:ok, binary} <- binary_path(opts),
         :ok <- ensure_binary(binary),
         {:ok, state} <- spawn_port(binary, opts) do
      handshake(state, hello_timeout(opts))
    end
  end

  @doc """
  The model directory the sidecar loads for this build's engine/model, or the
  `model_dir:` override. Never downloads.
  """
  @spec model_dir(keyword()) :: {:ok, Path.t()} | {:error, :model_not_installed}
  def model_dir(opts) when is_list(opts) do
    case Keyword.fetch(opts, :model_dir) do
      {:ok, dir} -> {:ok, dir}
      :error -> resolved_model_dir()
    end
  end

  @doc "The hello/stream-start deadline, honoring the `hello_timeout_ms:` test seam."
  @spec hello_timeout(keyword()) :: pos_integer()
  def hello_timeout(opts) when is_list(opts),
    do: Keyword.get(opts, :hello_timeout_ms, Timeouts.stt_sidecar_hello())

  @doc "The `stream_end` → `stream_done` flush deadline, honoring the `flush_timeout_ms:` test seam."
  @spec flush_timeout(keyword()) :: pos_integer()
  def flush_timeout(opts) when is_list(opts),
    do: Keyword.get(opts, :flush_timeout_ms, Timeouts.stt_sidecar_flush())

  @doc "Sends one op frame. `{:error, :closed}` once the sidecar is gone."
  @spec send_op(state(), map()) :: :ok | {:error, :closed}
  def send_op(%{port: nil}, _op), do: {:error, :closed}

  def send_op(%{port: port}, op) when is_map(op) do
    Port.command(port, encode(op))
    :ok
  rescue
    # Port.command raises once the port is closed — the sidecar is gone.
    ArgumentError -> {:error, :closed}
  end

  @doc """
  Folds one `{:data, _}` payload from the port into the state, reassembling
  `{:noeol, _}` fragments until a whole line is available.
  """
  @spec handle_data(state(), {:eol | :noeol, binary()}) ::
          {:line, frame(), state()} | {:partial, state()} | {:error, term(), state()}
  def handle_data(state, {:eol, chunk}) when is_binary(chunk) do
    case accumulate(state.acc, chunk) do
      {:ok, line} -> decode_into(state, line)
      {:error, reason} -> {:error, reason, %{state | acc: ""}}
    end
  end

  def handle_data(state, {:noeol, chunk}) when is_binary(chunk) do
    case accumulate(state.acc, chunk) do
      {:ok, acc} -> {:partial, %{state | acc: acc}}
      {:error, reason} -> {:error, reason, %{state | acc: ""}}
    end
  end

  @doc """
  Blocks until the next whole frame arrives, the sidecar exits, or `timeout_ms`
  elapses. Used on the synchronous paths (handshake, batch, stream start); a
  running stream reads its port messages through `handle_data/2` instead.
  """
  @spec await(state(), pos_integer(), atom()) ::
          {:ok, frame(), state()} | {:error, term(), state()}
  def await(state, timeout_ms, name)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_atom(name) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    receive_line(state, deadline, name, timeout_ms)
  end

  @doc "The terminal reason carried by an `error` event."
  @spec error_reason(frame()) :: {:sidecar_error, String.t(), String.t()}
  def error_reason(frame) when is_map(frame) do
    {:sidecar_error, string(Map.get(frame, "code"), "internal"),
     string(Map.get(frame, "message"), "")}
  end

  @doc """
  Asks the sidecar to exit and proves it gone. Idempotent.

  A healthy sidecar honors the `shutdown` op within milliseconds and its
  `exit_status` is observed while the port is still attached. One that is
  wedged in ONNX compute reads neither the op nor the port's EOF, so after
  `@shutdown_grace_ms` its process group is SIGKILLed — Port.close alone only
  closes the pipe and would orphan the child with the model resident (rule 4:
  own resources on every path). `:esrch` on an already-gone group is silent
  success.
  """
  @spec close(state()) :: :ok
  def close(%{port: nil}), do: :ok

  # `Port.info/1` is nil once the port is closed, so a second close (terminal
  # then terminate) neither waits the grace again nor signals a pid that died
  # long enough ago to have been recycled.
  def close(%{port: port} = state) do
    if Port.info(port), do: shut_down(state), else: :ok
  end

  defp shut_down(%{port: port, os_pid: os_pid} = state) do
    _ = send_op(state, %{"op" => "shutdown"})
    graceful? = await_exit(port, @shutdown_grace_ms)
    port_close(port)
    unless graceful?, do: ProcessGroup.signal(os_pid, :sigkill)
    flush(port)
    :ok
  end

  defp await_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      grace_ms -> false
    end
  end

  @doc """
  One whole-file recognition: spawn, handshake, transcribe, shut down. The port
  is closed on every exit path, including a timeout or a sidecar crash.
  """
  @spec batch(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def batch(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, dir} <- model_dir(opts),
         {:ok, state} <- open(opts) do
      run_batch(state, path, dir, opts)
    end
  end

  defp run_batch(state, path, dir, opts) do
    op = %{
      "op" => "transcribe",
      "id" => "b1",
      "path" => Path.expand(path),
      "model_dir" => dir
    }

    case send_op(state, op) do
      :ok -> await_result(state, batch_timeout(opts))
      {:error, :closed} -> finish_batch(state, {:error, {:sidecar_exit, :closed}})
    end
  end

  defp await_result(state, timeout_ms) do
    case await(state, timeout_ms, :stt_sidecar_batch) do
      {:ok, %{"event" => "result", "text" => text}, state} when is_binary(text) ->
        finish_batch(state, {:ok, text})

      {:ok, %{"event" => "error"} = frame, state} ->
        finish_batch(state, {:error, error_reason(frame)})

      {:ok, frame, state} ->
        finish_batch(state, {:error, {:protocol_error, {:unexpected_event, event_name(frame)}}})

      {:error, reason, state} ->
        finish_batch(state, {:error, reason})
    end
  end

  defp finish_batch(state, result) do
    close(state)
    result
  end

  defp handshake(state, timeout_ms) do
    case await(state, timeout_ms, :stt_sidecar_hello) do
      {:ok, %{"event" => "hello", "protocol_version" => @protocol_version}, state} ->
        {:ok, state}

      {:ok, %{"event" => "hello", "protocol_version" => theirs}, state} ->
        refuse(state, {:protocol_mismatch, %{fermix: @protocol_version, sidecar: theirs}})

      {:ok, frame, state} ->
        refuse(state, {:protocol_error, {:hello_expected, event_name(frame)}})

      {:error, reason, state} ->
        refuse(state, reason)
    end
  end

  defp refuse(state, reason) do
    close(state)
    {:error, reason}
  end

  defp receive_line(state, deadline, name, budget_ms) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case remaining > 0 do
      true -> receive_data(state, deadline, name, budget_ms, remaining)
      false -> {:error, timeout_reason(state, name, budget_ms), state}
    end
  end

  defp receive_data(%{port: port} = state, deadline, name, budget_ms, remaining) do
    receive do
      {^port, {:data, data}} ->
        continue(handle_data(state, data), deadline, name, budget_ms)

      {^port, {:exit_status, status}} ->
        {:error, {:sidecar_exit, status}, %{state | port: nil}}
    after
      remaining -> {:error, timeout_reason(state, name, budget_ms), state}
    end
  end

  defp continue({:line, frame, state}, _deadline, _name, _budget_ms), do: {:ok, frame, state}

  defp continue({:error, reason, state}, _deadline, _name, _budget_ms),
    do: {:error, reason, state}

  defp continue({:partial, state}, deadline, name, budget_ms),
    do: receive_line(state, deadline, name, budget_ms)

  defp timeout_reason(state, name, ms) do
    {:error, reason} = Timeouts.expired(name, ms, %{session_id: state.session_id})
    reason
  end

  defp accumulate(acc, chunk) do
    next = acc <> chunk

    case byte_size(next) > @max_line_bytes do
      true -> {:error, {:protocol_error, {:line_too_long, byte_size(next)}}}
      false -> {:ok, next}
    end
  end

  defp decode_into(state, line) do
    case decode_line(line) do
      {:ok, frame} ->
        {:line, frame, %{state | acc: ""}}

      {:error, {:malformed, detail}} ->
        {:error, {:protocol_error, {:malformed, detail}}, blank(state)}
    end
  end

  defp blank(state), do: %{state | acc: ""}

  defp spawn_port(binary, opts) do
    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        {:line, @line_bytes},
        :use_stdio,
        :exit_status,
        :hide,
        {:args, Keyword.get(opts, :args, [])},
        {:env, Keyword.get(opts, :env, [])}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, %{port: port, os_pid: os_pid, acc: "", session_id: Keyword.get(opts, :session_id)}}
  rescue
    # A present but non-executable file: Port.open refuses with ArgumentError.
    ArgumentError -> {:error, {:spawn_failed, binary}}
  end

  defp ensure_binary(path) do
    if File.regular?(path), do: :ok, else: {:error, {:sidecar_missing, path}}
  end

  defp binary_path(opts) do
    case Keyword.fetch(opts, :binary_path) do
      {:ok, path} -> {:ok, path}
      :error -> SidecarInstaller.binary_path()
    end
  end

  defp resolved_model_dir do
    %{engine: engine, model: model} = Local.identity()
    ModelStore.model_dir(engine, model)
  end

  defp batch_timeout(opts), do: Keyword.get(opts, :batch_timeout_ms, Timeouts.stt_sidecar_batch())

  defp port_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp flush(port) do
    receive do
      {^port, _anything} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp event_name(frame), do: Map.get(frame, "event")

  defp string(value, _default) when is_binary(value), do: value
  defp string(_value, default), do: default

  defp preview(line), do: binary_part(line, 0, min(byte_size(line), 120))
end
