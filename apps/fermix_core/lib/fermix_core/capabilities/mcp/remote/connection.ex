defmodule FermixCore.Capabilities.MCP.Remote.Connection do
  @moduledoc """
  One pinned TLS connection to a validated remote MCP endpoint (M27 §7.4).

  This is the dedicated per-origin connector the design calls for, and it is
  deliberately *not* the shared `FermixCore.Finch` pool:

    * **Pinned peer.** It connects to the address `Endpoint.resolve/2`
      validated, while presenting the signed hostname for the `Host` header,
      TLS SNI, and certificate verification. Handing a hostname to a pooled
      client would let the socket layer resolve it a second time, behind the
      guard — validating a name you then don't connect to is not a gate.
    * **Streaming caps.** The universal response cap has to bite *before* a
      body is buffered, which a request/response client cannot express. Mint in
      passive mode gives byte-level control and never touches the owner's
      mailbox, so a caller can be a GenServer without a blocking `receive`
      swallowing its casts.
    * **No redirects.** Any 3xx is terminal. Fermix does not resend a request —
      and therefore never resends the bearer — to an address the signed
      manifest did not name.

  The connection is HTTP/1 only. Streamable HTTP is defined over either
  version, but one wire shape means one code path to audit (Rule #12).

  The caller owns the returned struct and must `close/1` it on every path.
  """

  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.SSE
  alias FermixCore.Timeouts

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t(),
          endpoint: Endpoint.t(),
          peer: :inet.ip_address()
        }

  @enforce_keys [:conn, :endpoint, :peer]
  defstruct [:conn, :endpoint, :peer]

  @type body :: {:json, binary()} | {:sse, [SSE.event()]} | {:empty, binary()}
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: body()
        }

  @doc """
  Resolve, validate, and open a pinned connection.

  Resolution happens here, on every open, so a reconnect revalidates DNS
  instead of reusing an earlier decision.
  """
  @spec open(Endpoint.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Endpoint{} = endpoint, opts \\ []) when is_list(opts) do
    with {:ok, peer} <- Endpoint.resolve(endpoint, opts) do
      connect(endpoint, peer, opts)
    end
  end

  defp connect(endpoint, peer, opts) do
    connect_opts = [
      hostname: endpoint.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: tls_opts(endpoint.host, opts)
    ]

    case Mint.HTTP.connect(:https, peer, endpoint.port, connect_opts) do
      {:ok, conn} -> {:ok, %__MODULE__{conn: conn, endpoint: endpoint, peer: peer}}
      {:error, reason} -> {:error, {:remote_unreachable, transport_class(reason)}}
    end
  end

  # `hostname:` above already drives Host/SNI/cert checking in Mint; these are
  # spelled out anyway because this is the audited path — an implicit default
  # is not something a reviewer can confirm from the call site.
  defp tls_opts(host, opts) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      timeout: Keyword.get(opts, :connect_timeout_ms, Timeouts.mcp_remote_connect())
    ]
  end

  @doc """
  Send one request and read its complete response under `timeout_ms`.

  Returns the updated connection so the caller can reuse it, or an error. On
  error the connection is unusable and the caller must `close/1`.
  """
  @spec request(t(), String.t(), [{String.t(), String.t()}], binary() | nil, pos_integer()) ::
          {:ok, t(), response()} | {:error, t(), term()}
  def request(%__MODULE__{} = connection, method, headers, body, timeout_ms)
      when is_binary(method) and is_list(headers) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    target = connection.endpoint.path

    case Mint.HTTP.request(connection.conn, method, target, headers, body) do
      {:ok, conn, ref} ->
        read(%{connection | conn: conn}, ref, deadline, timeout_ms)

      # The send itself failed, so the peer never saw this request. That is a
      # materially different fact from a close mid-response: resending is not a
      # replay, because nothing was delivered. Tagging it is what lets the
      # session reconnect safely without ever repeating a request the server
      # may already have acted on (§7.8).
      {:error, conn, reason} ->
        {:error, %{connection | conn: conn}, {:not_sent, transport_class(reason)}}
    end
  end

  @doc "Close the socket. Safe on an already-failed connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{conn: conn}) do
    _ = Mint.HTTP.close(conn)
    :ok
  end

  defp read(connection, ref, deadline, budget_ms) do
    acc = %{
      status: nil,
      headers: [],
      header_bytes: 0,
      received: 0,
      chunks: [],
      sse: nil,
      events: []
    }

    recv_loop(connection, ref, acc, deadline, budget_ms)
  end

  defp recv_loop(connection, ref, acc, deadline, budget_ms) do
    case remaining(deadline) do
      {:ok, timeout} -> recv_chunk(connection, ref, acc, deadline, budget_ms, timeout)
      :expired -> {:error, connection, expired_deadline(budget_ms)}
    end
  end

  defp recv_chunk(connection, ref, acc, deadline, budget_ms, timeout) do
    case Mint.HTTP.recv(connection.conn, 0, timeout) do
      {:ok, conn, responses} ->
        apply_responses(%{connection | conn: conn}, ref, responses, acc, deadline, budget_ms)

      {:error, conn, %Mint.TransportError{reason: :timeout}, _responses} ->
        {:error, %{connection | conn: conn}, expired_deadline(budget_ms)}

      {:error, conn, reason, _responses} ->
        {:error, %{connection | conn: conn}, transport_class(reason)}
    end
  end

  defp apply_responses(connection, ref, responses, acc, deadline, budget_ms) do
    case Enum.reduce_while(responses, {:cont, acc}, &fold_response(&1, &2, ref)) do
      {:cont, acc} -> recv_loop(connection, ref, acc, deadline, budget_ms)
      {:done, acc} -> finish(connection, acc)
      {:halt, reason} -> {:error, connection, reason}
    end
  end

  defp fold_response({:status, ref, status}, {:cont, acc}, ref) do
    if status in 300..399 do
      {:halt, {:halt, {:remote_security_blocked, {:redirect_refused, status}}}}
    else
      {:cont, {:cont, %{acc | status: status}}}
    end
  end

  defp fold_response({:headers, ref, headers}, {:cont, acc}, ref) do
    case absorb_headers(acc, headers) do
      {:ok, acc} -> {:cont, {:cont, acc}}
      {:error, reason} -> {:halt, {:halt, reason}}
    end
  end

  defp fold_response({:data, ref, data}, {:cont, acc}, ref) do
    case absorb_data(acc, data) do
      {:ok, acc} -> {:cont, {:cont, acc}}
      {:error, reason} -> {:halt, {:halt, reason}}
    end
  end

  defp fold_response({:done, ref}, {:cont, acc}, ref), do: {:halt, {:done, acc}}

  defp fold_response({:error, ref, reason}, {:cont, _acc}, ref),
    do: {:halt, {:halt, transport_class(reason)}}

  # A response for another request reference cannot occur on a single-request
  # HTTP/1 connection; treat it as the invariant breach it would be.
  defp fold_response(other, {:cont, _acc}, _ref),
    do: {:halt, {:halt, {:remote_protocol_error, {:unexpected_response, elem(other, 0)}}}}

  defp absorb_headers(acc, headers) do
    block =
      Enum.reduce(headers, acc.header_bytes, fn {k, v}, sum ->
        sum + byte_size(k) + byte_size(v)
      end)

    oversized =
      Enum.find(headers, fn {_k, v} -> byte_size(v) > Limits.max_header_value_bytes() end)

    cond do
      oversized != nil ->
        {:error, {:remote_protocol_error, {:header_value_too_large, elem(oversized, 0)}}}

      block > Limits.max_header_block_bytes() ->
        {:error, {:remote_protocol_error, {:header_block_too_large, block}}}

      true ->
        {:ok, start_body(%{acc | headers: acc.headers ++ headers, header_bytes: block}, headers)}
    end
  end

  # Content-type decides how the body is consumed, but never whether it is
  # bounded: the universal cap is applied to raw received bytes below,
  # independent of status and content type.
  defp start_body(acc, headers) do
    if sse?(headers), do: %{acc | sse: SSE.new()}, else: acc
  end

  defp sse?(headers) do
    headers
    |> content_type()
    |> String.starts_with?("text/event-stream")
  end

  defp absorb_data(acc, data) do
    received = acc.received + byte_size(data)

    if received > Limits.max_response_bytes() do
      {:error, {:remote_protocol_error, {:response_too_large, received}}}
    else
      absorb_body(%{acc | received: received}, data)
    end
  end

  defp absorb_body(%{sse: nil} = acc, data), do: {:ok, %{acc | chunks: [data | acc.chunks]}}

  defp absorb_body(%{sse: sse} = acc, data) do
    case SSE.feed(sse, data) do
      {:ok, events, sse} -> {:ok, %{acc | sse: sse, events: acc.events ++ events}}
      {:error, reason} -> {:error, {:remote_protocol_error, reason}}
    end
  end

  defp finish(connection, acc) do
    case build_body(acc) do
      {:ok, body} ->
        {:ok, connection, %{status: acc.status, headers: acc.headers, body: body}}

      {:error, reason} ->
        {:error, connection, reason}
    end
  end

  defp build_body(%{sse: nil} = acc) do
    raw = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    if json?(acc.headers), do: {:ok, {:json, raw}}, else: {:ok, {:empty, raw}}
  end

  defp build_body(%{sse: sse} = acc) do
    case SSE.finish(sse) do
      :ok -> {:ok, {:sse, acc.events}}
      {:error, reason} -> {:error, {:remote_protocol_error, reason}}
    end
  end

  defp json?(headers) do
    headers |> content_type() |> String.starts_with?("application/json")
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {key, value} ->
      if String.downcase(key) == "content-type", do: String.downcase(value)
    end)
  end

  defp remaining(deadline) do
    left = deadline - System.monotonic_time(:millisecond)
    if left > 0, do: {:ok, left}, else: :expired
  end

  defp expired_deadline(budget_ms) do
    {:error, timeout} = Timeouts.expired(:mcp_remote_response, budget_ms)
    {:remote_unreachable, timeout}
  end

  # Transport failures are reduced to a CLASS before they leave this module.
  # A raw Mint/ssl reason can carry the peer address, certificate details, and
  # occasionally response text; §11.1 forbids any of that reaching a log,
  # trace, or status string.
  defp transport_class(%Mint.TransportError{reason: reason}), do: {:transport, reason}
  defp transport_class(%Mint.HTTPError{reason: reason}), do: {:http, http_reason_class(reason)}
  defp transport_class(reason) when is_atom(reason), do: {:transport, reason}
  defp transport_class({reason, _detail}) when is_atom(reason), do: {:transport, reason}
  defp transport_class(_reason), do: {:transport, :unknown}

  defp http_reason_class(reason) when is_atom(reason), do: reason
  defp http_reason_class(reason) when is_tuple(reason), do: elem(reason, 0)
  defp http_reason_class(_reason), do: :unknown
end
