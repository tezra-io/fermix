defmodule Fermix.CLI.Daemon.Client do
  @moduledoc """
  Tiny client for the `Fermix.CLI.Daemon` control socket.

  Used by `fermix status` and `fermix stop` (and by `fermix doctor`).
  Returns `{:error, :not_running}` when the socket is missing or
  unreachable — callers treat that as the authoritative "not
  running" signal, not a degraded path.
  """

  @default_timeout_ms 3_000

  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []), do: request("status", opts)

  @spec shutdown(keyword()) :: {:ok, map()} | {:error, term()}
  def shutdown(opts \\ []), do: request("shutdown", opts)

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
           {:ok, line} <- :gen_tcp.recv(conn, 0, timeout) do
        Jason.decode(String.trim(line))
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
       when reason in [:enoent, :econnrefused, :timeout, :eaddrnotavail],
       do: {:error, :not_running}

  defp classify(reason), do: {:error, reason}

  defp default_socket_path do
    fermix_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(fermix_home, "daemon.sock")
  end
end
