defmodule Fermix.CLI.Daemon.Client do
  @moduledoc """
  Tiny client for the `Fermix.CLI.Daemon` control socket.

  Used by `fermix status` and `fermix stop` (and by `fermix doctor`).
  Returns `{:error, :not_running}` when the socket is missing or
  unreachable — callers treat that as the authoritative "not
  running" signal, not a degraded path.
  """

  @default_timeout_ms 3_000

  # `{:packet, :line}` truncates a line longer than the inet driver's read
  # buffer (9216 bytes by default, independent of OS), handing back the partial
  # chunk without its trailing newline. Accumulate chunks until one ends in "\n"
  # so large replies (e.g. a full skill body) decode whole. Bounded so a daemon
  # that never newline-terminates fails loud instead of looping forever.
  @max_response_bytes 4_194_304

  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []), do: request("status", opts)

  @spec shutdown(keyword()) :: {:ok, map()} | {:error, term()}
  def shutdown(opts \\ []), do: request("shutdown", opts)

  @spec agent_message(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def agent_message(params, opts \\ []) when is_map(params) do
    opts = Keyword.put(opts, :params, params)
    request("agent_message", opts)
  end

  @spec request(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, opts \\ []) when is_binary(method) do
    socket_path = Keyword.get(opts, :socket_path, default_socket_path())
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    case connect(socket_path, timeout) do
      {:ok, conn} -> exchange(conn, method, opts, timeout)
      {:error, reason} -> classify(reason)
    end
  end

  defp connect(socket_path, timeout) do
    :gen_tcp.connect(
      {:local, to_charlist(socket_path)},
      0,
      [:binary, {:active, false}, {:packet, :line}],
      timeout
    )
  end

  defp exchange(conn, method, opts, timeout) do
    payload = Jason.encode!(request_payload(method, opts)) <> "\n"

    try do
      with :ok <- :gen_tcp.send(conn, payload),
           {:ok, line} <- recv_line(conn, timeout, [], 0) do
        Jason.decode(String.trim(line))
      else
        {:error, reason} -> {:error, reason}
      end
    after
      :gen_tcp.close(conn)
    end
  end

  # `timeout` is the read deadline for each chunk, not the whole reply. That is
  # fine here: every caller talks to a trusted same-host daemon that writes the
  # reply as one line, so reads do not dribble across many chunks.
  @spec recv_line(:gen_tcp.socket(), non_neg_integer(), iodata(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp recv_line(_conn, _timeout, _acc, size) when size > @max_response_bytes,
    do: {:error, :response_too_large}

  defp recv_line(conn, timeout, acc, size) do
    case :gen_tcp.recv(conn, 0, timeout) do
      {:ok, chunk} when binary_part(chunk, byte_size(chunk), -1) == "\n" ->
        {:ok, IO.iodata_to_binary([acc, chunk])}

      {:ok, chunk} ->
        recv_line(conn, timeout, [acc, chunk], size + byte_size(chunk))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request_payload(String.t(), keyword()) :: map()
  defp request_payload(method, opts) do
    case Keyword.get(opts, :params, %{}) do
      params when params == %{} -> %{"method" => method}
      params when is_map(params) -> %{"method" => method, "params" => params}
    end
  end

  defp classify(reason)
       when reason in [:enoent, :econnrefused, :timeout, :eaddrnotavail],
       do: {:error, :not_running}

  defp classify(reason), do: {:error, reason}

  defp default_socket_path do
    fermix_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(fermix_home, "daemon.sock")
  end
end
