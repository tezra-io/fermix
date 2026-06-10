defmodule Fermix.CLI.Daemon.Client do
  @moduledoc """
  Tiny client for the `Fermix.CLI.Daemon` control socket.

  Used by `fermix status` and `fermix stop` (and by `fermix doctor`).
  Returns `{:error, :not_running}` when the socket is missing or
  unreachable — callers treat that as the authoritative "not
  running" signal, not a degraded path.
  """

  @default_timeout_ms 3_000

  # Upper bound on one reply frame. Without it a corrupt or version-skewed
  # header (e.g. a pre-packet-4 daemon's newline-framed JSON, whose first 4
  # ASCII bytes read as a ~2 GB length) buffers toward 2 GB until the timeout;
  # with it the read fails immediately with :emsgsize.
  @max_frame_bytes 4_194_304

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
      [:binary, {:active, false}, {:packet, 4}, {:packet_size, @max_frame_bytes}],
      timeout
    )
  catch
    # AF_UNIX paths beyond the OS limit (104 bytes on macOS) make
    # :gen_tcp.connect exit :badarg instead of returning an error tuple.
    # No daemon can be listening on a path the OS cannot address, so it
    # classifies with the other unreachable-socket reasons.
    :exit, :badarg -> {:error, :badarg}
  end

  defp exchange(conn, method, opts, timeout) do
    payload = Jason.encode!(request_payload(method, opts))

    try do
      with :ok <- :gen_tcp.send(conn, payload),
           {:ok, data} <- :gen_tcp.recv(conn, 0, timeout) do
        case Jason.decode(data) do
          {:ok, decoded} ->
            {:ok, decoded}

          {:error, %Jason.DecodeError{position: pos}} ->
            # A packet-4 frame arrives whole or not at all, so a decode
            # failure means malformed JSON, not truncation.
            {:error, "response_decode_failed:#{pos}"}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    after
      :gen_tcp.close(conn)
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
       when reason in [:enoent, :econnrefused, :timeout, :eaddrnotavail, :badarg],
       do: {:error, :not_running}

  defp classify(reason), do: {:error, reason}

  defp default_socket_path do
    fermix_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(fermix_home, "daemon.sock")
  end
end
