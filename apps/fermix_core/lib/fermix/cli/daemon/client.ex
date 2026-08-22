defmodule Fermix.CLI.Daemon.Client do
  @moduledoc """
  Tiny client for the `Fermix.CLI.Daemon` control socket.

  `request_v1/3` speaks the management protocol and is what `fermix status`,
  `fermix doctor`, and `fermix logs` use. `request/2` speaks the historical
  unversioned protocol that `fermix stop`, mobile pairing, and the remaining
  introspection verbs still use; a caller never has both for one answer.

  Returns `{:error, :not_running}` when the socket is missing or
  unreachable — callers treat that as the authoritative "not
  running" signal, not a degraded path.
  """

  alias FermixCore.Management.Protocol

  @default_timeout_ms 3_000

  # Upper bound on one reply frame. Without it a corrupt or version-skewed
  # header (e.g. a pre-packet-4 daemon's newline-framed JSON, whose first 4
  # ASCII bytes read as a ~2 GB length) buffers toward 2 GB until the timeout;
  # with it the read fails immediately with :emsgsize.
  @max_frame_bytes 4_194_304

  @type exchange_fun ::
          (String.t(), map(), pos_integer() -> {:ok, map()} | {:error, term()})

  @spec shutdown(keyword()) :: {:ok, map()} | {:error, term()}
  def shutdown(opts \\ []), do: request("shutdown", opts)

  @spec agent_message(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def agent_message(params, opts \\ []) when is_map(params) do
    opts = Keyword.put(opts, :params, params)
    request("agent_message", opts)
  end

  @spec mobile_request(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def mobile_request(method, params \\ %{}, opts \\ [])

  def mobile_request(method, params, opts)
      when is_binary(method) and is_map(params) and is_list(opts) do
    request(method, Keyword.put(opts, :params, params))
  end

  @doc "Runs bounded request exchanges over one control-socket connection."
  @spec with_connection((exchange_fun() -> term()), keyword()) :: term() | {:error, term()}
  def with_connection(callback, opts \\ [])
      when is_function(callback, 1) and is_list(opts) do
    socket_path = Keyword.get(opts, :socket_path, default_socket_path())
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    case connect(socket_path, timeout) do
      {:ok, conn} -> run_connected(conn, callback)
      {:error, reason} -> classify(reason)
    end
  end

  @spec request(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, opts \\ []) when is_binary(method) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    params = Keyword.get(opts, :params, %{})

    with_connection(
      fn exchange -> exchange.(method, params, timeout) end,
      opts
    )
  end

  @doc "Sends one management v1 request without retrying through v0."
  @spec request_v1(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_v1(method, params \\ %{}, opts \\ [])

  def request_v1(method, params, opts)
      when is_binary(method) and is_map(params) and is_list(opts) do
    socket_path = Keyword.get(opts, :socket_path, default_socket_path())
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    request_id = Keyword.get(opts, :request_id, next_request_id())
    version = Keyword.get(opts, :protocol_version, Protocol.protocol_version())
    request = v1_request(request_id, version, method, params)

    case connect(socket_path, timeout) do
      {:ok, conn} -> run_v1_exchange(conn, request, request_id, timeout)
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Renders one `request_v1/3` failure as the sentence an operator reads.

  A management error already carries the daemon's own wording plus a stable
  code; anything else is a transport failure that has no public sentence, so it
  is inspected rather than paraphrased into something friendlier and wrong.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:management_error, code, message, _details})
      when is_binary(code) and is_binary(message),
      do: "#{message} (#{code})"

  def describe_error(:invalid_management_response),
    do: "the daemon did not answer management protocol v1; restart it with `fermix restart`"

  def describe_error(reason), do: inspect(reason)

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

  defp run_connected(conn, callback) do
    exchange = fn method, params, timeout -> exchange(conn, method, params, timeout) end

    try do
      callback.(exchange)
    after
      :gen_tcp.close(conn)
    end
  end

  defp run_v1_exchange(conn, request, request_id, timeout) do
    exchange_v1(conn, request, request_id, timeout)
  after
    :gen_tcp.close(conn)
  end

  defp exchange_v1(conn, request, request_id, timeout) do
    payload = Jason.encode!(request)

    with :ok <- ensure_within_frame(payload),
         :ok <- :gen_tcp.send(conn, payload),
         {:ok, data} <- :gen_tcp.recv(conn, 0, timeout) do
      decode_v1_response(data, request_id)
    end
  end

  defp decode_v1_response(data, request_id) do
    with {:ok, response} when is_map(response) <- Jason.decode(data),
         :ok <- matching_request_id(response, request_id),
         :ok <- validate_v1_response_fields(response) do
      decode_v1_outcome(response)
    else
      {:ok, _other} ->
        {:error, :invalid_management_response}

      {:error, %Jason.DecodeError{position: position}} ->
        {:error, "response_decode_failed:#{position}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_request_id(%{"request_id" => request_id}, request_id), do: :ok
  defp matching_request_id(_response, _request_id), do: {:error, :response_request_id_mismatch}

  defp validate_v1_response_fields(response) do
    case Enum.sort(Map.keys(response)) do
      ["request_id", "result"] -> :ok
      ["error", "request_id"] -> validate_v1_error_fields(response["error"])
      _other -> {:error, :invalid_management_response}
    end
  end

  defp validate_v1_error_fields(error) when is_map(error) do
    if Enum.sort(Map.keys(error)) == ["code", "details", "message"],
      do: :ok,
      else: {:error, :invalid_management_response}
  end

  defp validate_v1_error_fields(_error), do: {:error, :invalid_management_response}

  defp decode_v1_outcome(%{"result" => result} = response) when is_map(result) do
    if Map.has_key?(response, "error"),
      do: {:error, :invalid_management_response},
      else: {:ok, result}
  end

  defp decode_v1_outcome(%{"error" => error} = response) when is_map(error) do
    if Map.has_key?(response, "result") do
      {:error, :invalid_management_response}
    else
      decode_v1_error(error)
    end
  end

  defp decode_v1_outcome(_response), do: {:error, :invalid_management_response}

  defp decode_v1_error(%{
         "code" => code,
         "message" => message,
         "details" => details
       })
       when is_binary(code) and is_binary(message) and is_map(details) do
    if code in Protocol.error_codes() do
      {:error, {:management_error, code, message, details}}
    else
      {:error, :invalid_management_response}
    end
  end

  defp decode_v1_error(_error), do: {:error, :invalid_management_response}

  defp v1_request(request_id, version, method, params) do
    %{
      "request_id" => request_id,
      "protocol_version" => version,
      "method" => method,
      "params" => params
    }
  end

  defp next_request_id do
    "req-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp exchange(conn, method, params, timeout)
       when is_binary(method) and is_map(params) and is_integer(timeout) and timeout > 0 do
    payload = Jason.encode!(request_payload(method, params))

    with :ok <- ensure_within_frame(payload),
         :ok <- :gen_tcp.send(conn, payload),
         {:ok, data} <- :gen_tcp.recv(conn, 0, timeout) do
      decode_response(data)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_response(data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{position: pos}} ->
        # A packet-4 frame arrives whole or not at all, so a decode
        # failure means malformed JSON, not truncation.
        {:error, "response_decode_failed:#{pos}"}
    end
  end

  # The socket is framed at @max_frame_bytes on both ends ({:packet, 4} +
  # {:packet_size}), so an oversized request (e.g. large base64 image
  # attachments) would otherwise fail on send with an opaque :emsgsize. Reject it
  # before send with a structured, actionable error instead.
  defp ensure_within_frame(payload) do
    size = byte_size(payload)

    if size > @max_frame_bytes do
      {:error, {:request_too_large, size, @max_frame_bytes}}
    else
      :ok
    end
  end

  @spec request_payload(String.t(), map()) :: map()
  defp request_payload(method, params) do
    case params do
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
