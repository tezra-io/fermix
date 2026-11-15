defmodule FermixAudit.Observer do
  @moduledoc """
  Audit-only trace sink. It preserves the handler's payload without truncation.
  Each encoded line is capped at 12 MiB and the stream at 40 MiB, including
  framing; 4 KiB is reserved for an explicit overflow marker. The external
  collector caps all daemon logs at 48 MiB, so other output may still cause a
  fail-closed collection. Limits invalidate the run; they never imply a complete
  truncated event. Provider request capture remains independent in the proxy.
  """
  use GenServer

  alias FermixCore.Trace.TelemetryHandler

  @prefix "FERMIX_AUDIT_TRACE "
  @max_line_bytes 12 * 1024 * 1024
  @max_total_bytes 40 * 1024 * 1024
  @error_reserve_bytes 4_096
  @max_pending 2_000
  @default_max_events 100_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if valid_options?(opts),
      do: GenServer.start_link(__MODULE__, opts),
      else: {:error, :invalid_options}
  end

  @spec flush(GenServer.server()) :: :ok
  def flush(server), do: GenServer.call(server, :flush, 5_000)

  defp valid_options?(opts) do
    Keyword.keyword?(opts) and valid_identity?(opts) and valid_limits?(opts) and
      valid_callbacks?(opts)
  end

  defp valid_identity?(opts) do
    run_id = Keyword.get(opts, :run_id)
    token = Keyword.get(opts, :token)
    prefix = Keyword.get(opts, :prefix)
    path = Keyword.get(opts, :socket_path)

    is_binary(run_id) and byte_size(run_id) in 1..128 and
      is_binary(token) and byte_size(token) in 8..4096 and not String.contains?(run_id, token) and
      is_binary(prefix) and byte_size(prefix) in 1..160 and valid_path?(path)
  end

  defp valid_path?(nil), do: true

  defp valid_path?(path) when is_binary(path),
    do:
      byte_size(path) in 1..100 and Path.type(path) == :absolute and
        not String.contains?(path, <<0>>)

  defp valid_path?(_), do: false

  defp valid_limits?(opts) do
    count = Keyword.get(opts, :max_events, @default_max_events)
    is_integer(count) and count in 1..@default_max_events
  end

  defp valid_callbacks?(opts) do
    is_function(Keyword.get(opts, :write, &IO.binwrite(:stdio, &1)), 1) and
      is_function(Keyword.get(opts, :fail, &fatal/1), 1) and
      is_function(Keyword.get(opts, :admit, &FermixCore.SocketPeer.admit/2), 2)
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    token = Keyword.fetch!(opts, :token)
    prefix = Keyword.fetch!(opts, :prefix)
    true = is_binary(run_id) and run_id != "" and is_binary(token) and byte_size(token) >= 8
    true = is_binary(prefix) and prefix != "" and not String.contains?(run_id, token)

    state = %{
      run_id: run_id,
      token: token,
      prefix: prefix,
      seq: 0,
      count: 0,
      bytes: 0,
      max_events: Keyword.get(opts, :max_events, @default_max_events),
      write: Keyword.get(opts, :write, &IO.binwrite(:stdio, &1)),
      fail: Keyword.get(opts, :fail, &fatal/1),
      socket_path: Keyword.get(opts, :socket_path),
      listener: nil
    }

    {:ok, _} = Application.ensure_all_started(:telemetry)

    {:ok, state} =
      start_listener(state, Keyword.get(opts, :admit, &FermixCore.SocketPeer.admit/2))

    case emit(state, %{kind: "start"}) do
      {:ok, state} ->
        :ok =
          TelemetryHandler.attach(trace_server: self(), handler_prefix: prefix)

        {:ok, state}

      {:error, reason} ->
        if state.listener, do: close_listener(state.listener, state.socket_path)
        state.fail.(reason)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call({:checkpoint, nonce}, _from, state) do
    case emit(state, %{kind: "checkpoint", nonce: nonce}) do
      {:ok, next} ->
        {:reply, {:ok, next.seq}, next}

      {:error, reason} ->
        report_failure(state, reason)
        {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:record, type, agent, data}, state) do
    {:message_queue_len, pending} = Process.info(self(), :message_queue_len)

    if pending > @max_pending or state.count >= state.max_events do
      stop_failed(state, :overflow)
    else
      record = %{kind: "event", type: type, agent: agent, data: data}

      case emit(state, record) do
        {:ok, next} -> {:noreply, %{next | count: next.count + 1}}
        {:error, reason} -> stop_failed(state, reason)
      end
    end
  end

  def handle_cast({:observer_error, reason}, state), do: stop_failed(state, reason)

  @impl true
  def terminate(_reason, state) do
    TelemetryHandler.detach(state.prefix)
    if state.listener, do: close_listener(state.listener, state.socket_path)
  end

  defp emit(state, record) do
    seq = state.seq + 1
    record = Map.merge(record, %{version: 1, run_id: state.run_id, seq: seq})

    with {:ok, json} <- encode(record),
         line = @prefix <> json <> "\n",
         :ok <- safe_line(line, state, record.kind),
         :ok <- write_line(state.write, line) do
      {:ok, %{state | seq: seq, bytes: state.bytes + byte_size(line)}}
    else
      {:error, reason} when reason in [:overflow, :token_exposure, :encode_failed] ->
        {:error, reason}

      _ ->
        {:error, :write_failed}
    end
  end

  defp encode(record) do
    case Jason.encode(record) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :encode_failed}
    end
  rescue
    _error in [Jason.EncodeError, Protocol.UndefinedError, UndefinedFunctionError] ->
      {:error, :encode_failed}
  end

  defp write_line(writer, line) do
    writer.(line)
  rescue
    _error -> {:error, :write_failed}
  catch
    :exit, _reason -> {:error, :write_failed}
  end

  defp safe_line(line, state, kind) do
    limit =
      if kind == "error", do: @max_total_bytes, else: @max_total_bytes - @error_reserve_bytes

    cond do
      byte_size(line) > @max_line_bytes -> {:error, :overflow}
      state.bytes + byte_size(line) > limit -> {:error, :overflow}
      :binary.match(line, state.token) != :nomatch -> {:error, :token_exposure}
      true -> :ok
    end
  end

  defp stop_failed(state, reason) do
    report_failure(state, reason)
    {:stop, :normal, state}
  end

  defp report_failure(state, reason) do
    _ = emit(state, %{kind: "error", reason: reason})
    state.fail.(reason)
  end

  defp start_listener(%{socket_path: nil} = state, _admit), do: {:ok, state}

  defp start_listener(state, admit) do
    path = state.socket_path
    if File.exists?(path), do: raise("checkpoint socket path already exists")

    opts = [
      :binary,
      active: false,
      packet: :line,
      packet_size: 1024,
      ifaddr: {:local, String.to_charlist(path)}
    ]

    with {:ok, listener} <- :gen_tcp.listen(0, opts) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, _} = start_checkpoint_worker(listener, admit)
          {:ok, %{state | listener: listener}}

        {:error, reason} ->
          close_listener(listener, path)
          {:error, {:checkpoint_socket, reason}}
      end
    end
  end

  defp close_listener(listener, path) do
    :ok = :gen_tcp.close(listener)

    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "FERMIX_AUDIT_OBSERVER_FAILURE socket_cleanup_#{reason}")
    end
  end

  defp start_checkpoint_worker(listener, admit) do
    observer = self()
    Task.start_link(fn -> checkpoint_worker(listener, observer, admit) end)
  end

  defp checkpoint_worker(listener, observer, admit) do
    accept_requests(listener, observer, admit, 10_000)
  rescue
    _error -> GenServer.cast(observer, {:observer_error, :socket_failed})
  catch
    :exit, _reason -> GenServer.cast(observer, {:observer_error, :socket_failed})
  end

  defp accept_requests(_listener, observer, _admit, 0) do
    GenServer.cast(observer, {:observer_error, :overflow})
  end

  defp accept_requests(listener, observer, admit, remaining) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          serve_checkpoint(socket, observer, admit)
        after
          :gen_tcp.close(socket)
        end

        accept_requests(listener, observer, admit, remaining - 1)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        GenServer.cast(observer, {:observer_error, :socket_failed})
    end
  end

  defp serve_checkpoint(socket, observer, admit) do
    with :ok <- admit.(socket, :os.type()),
         {:ok, line} <- :gen_tcp.recv(socket, 0, 2_000),
         {:ok, %{"op" => "checkpoint", "nonce" => nonce} = request} <- Jason.decode(line),
         true <- map_size(request) == 2 and is_binary(nonce),
         true <- Regex.match?(~r/\A[a-zA-Z0-9]{16,128}\z/, nonce),
         {:ok, seq} <- GenServer.call(observer, {:checkpoint, nonce}, 5_000),
         {:ok, reply} <- Jason.encode(%{nonce: nonce, seq: seq}) do
      :gen_tcp.send(socket, reply <> "\n")
    end
  catch
    :exit, _reason -> {:error, :checkpoint_failed}
  end

  defp fatal(reason) do
    IO.puts(:stderr, "FERMIX_AUDIT_OBSERVER_FAILURE #{reason}")
    System.halt(70)
  end
end
