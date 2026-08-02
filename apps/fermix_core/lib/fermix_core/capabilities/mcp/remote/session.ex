defmodule FermixCore.Capabilities.MCP.Remote.Session do
  @moduledoc """
  One authenticated MCP session over Streamable HTTP (M27 §7.4, §7.8).

  This process is the only place a resolved bearer credential exists. It is
  passed an opaque `AuthRef` and resolves it in `init/1`, so no supervisor
  child spec, crash report, or registry entry can carry the value.

  A started session is an *initialized* session: `init/1` resolves, connects,
  runs `initialize`, checks the negotiated protocol version, and sends
  `notifications/initialized`, all inside the startup deadline. A failure stops
  the process with a classified reason rather than leaving a half-connected
  client that looks ready. The owner turns that reason into operator-visible
  status; this module never retries on its own — bounded recovery is the
  owner's job, and a second retry owner is how ambiguous writes get duplicated.

  Requests are serialized by construction: the HTTP exchange happens inside
  `handle_call/3`, so one session performs exactly one in-flight JSON-RPC
  request. Admission, queueing, pacing, and backpressure belong to the caller
  above (`Remote.Client`), which is why they are not here.

  MCP `2025-06-18` is pinned. A server that negotiates any other version is
  refused rather than silently driven with different semantics.
  """

  use GenServer

  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Connection
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Json
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Timeouts

  @protocol_version "2025-06-18"

  @type opt ::
          {:endpoint, Endpoint.t()}
          | {:auth_ref, AuthRef.t()}
          | {:client_info, map()}
          | {:resolver, (String.t() -> String.t() | nil)}
          | {:connect_opts, keyword()}
          | {:transport, module()}

  @doc "The MCP protocol version this rail pins."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Issue one JSON-RPC request and return its `result`."
  @spec request(GenServer.server(), String.t(), map(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request(session, method, params, timeout_ms, opts \\ [])
      when is_binary(method) and is_map(params) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      session,
      {:request, method, params, timeout_ms, opts},
      call_timeout(timeout_ms)
    )
  end

  @doc """
  Best-effort authenticated session teardown, then close.

  Teardown uses the same pinned origin, bearer, protocol-version header, and
  no-redirect policy as every other request. Any 2xx is success; 405 means the
  server does not implement session deletion; anything else is reported before
  the local socket closes, because a failure nobody can see is a failure nobody
  can diagnose.
  """
  @spec teardown(GenServer.server()) :: :ok | {:error, term()}
  def teardown(session) do
    GenServer.call(session, :teardown, call_timeout(Timeouts.mcp_remote_teardown()))
  catch
    :exit, {:noproc, _} -> :ok
  end

  # The GenServer.call budget outlives the HTTP deadline it wraps, so the inner
  # deadline reports the timeout instead of the caller exiting first and
  # desyncing the two (the pattern `Timeouts` was written for).
  defp call_timeout(timeout_ms), do: timeout_ms + 5_000

  @impl true
  def init(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    auth_ref = Keyword.fetch!(opts, :auth_ref)
    deadline = System.monotonic_time(:millisecond) + Timeouts.mcp_remote_startup()

    transport = Keyword.get(opts, :transport, Connection)

    with {:ok, credential} <- AuthRef.resolve(auth_ref, resolver_opts(opts)),
         {:ok, connection} <- open(transport, endpoint, opts) do
      state = %{
        endpoint: endpoint,
        transport: transport,
        credential: credential,
        connection: connection,
        client_info: Keyword.get(opts, :client_info, default_client_info()),
        session_id: nil,
        next_id: 1
      }

      handshake(state, deadline)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolver_opts(opts) do
    case Keyword.fetch(opts, :resolver) do
      {:ok, resolver} -> [resolver: resolver]
      :error -> []
    end
  end

  defp open(transport, endpoint, opts) do
    transport.open(endpoint, Keyword.get(opts, :connect_opts, []))
  end

  defp default_client_info do
    %{"name" => "fermix", "version" => to_string(Application.spec(:fermix_core, :vsn))}
  end

  # Own the socket on every failure path: a stopped init must not leak the TLS
  # connection it opened.
  defp handshake(state, deadline) do
    case initialize(state, deadline) do
      {:ok, state} -> {:ok, state}
      {:error, state, reason} -> stop_with(state, reason)
    end
  end

  defp stop_with(state, reason) do
    state.transport.close(state.connection)
    {:stop, reason}
  end

  # Every step returns the 3-tuple `{:error, state, reason}` so the caller
  # always has the post-exchange connection to close. A validation step that
  # returned a bare `{:error, reason}` would leave the socket unowned.
  defp initialize(state, deadline) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => state.client_info
    }

    case exchange(state, "initialize", params, initialize_timeout(deadline)) do
      {:ok, state, result, headers} -> finish_initialize(state, result, headers, deadline)
      {:error, state, reason} -> {:error, state, reason}
    end
  end

  defp finish_initialize(state, result, headers, deadline) do
    with :ok <- check_negotiated_version(result),
         {:ok, state} <- adopt_session_id(state, headers) do
      send_initialized(state, deadline)
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp initialize_timeout(deadline) do
    min(Timeouts.mcp_remote_initialize(), max(deadline - System.monotonic_time(:millisecond), 1))
  end

  # The version is a hard gate, not a hint: `2025-06-18` fixes the signed
  # descriptor boundary (no `execution.taskSupport` field), so accepting a
  # different negotiated version would silently change what a signed hash
  # covers.
  defp check_negotiated_version(%{"protocolVersion" => @protocol_version}), do: :ok

  defp check_negotiated_version(%{"protocolVersion" => other}),
    do: {:error, {:remote_protocol_error, {:unsupported_protocol_version, other}}}

  defp check_negotiated_version(_result),
    do: {:error, {:remote_protocol_error, :missing_protocol_version}}

  defp send_initialized(state, deadline) do
    timeout =
      min(
        Timeouts.mcp_remote_initialize(),
        max(deadline - System.monotonic_time(:millisecond), 1)
      )

    case notify(state, "notifications/initialized", %{}, timeout) do
      {:ok, state} -> {:ok, state}
      {:error, _state, reason} -> {:error, state, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params, timeout_ms, _opts}, _from, state) do
    case exchange(state, method, params, timeout_ms) do
      {:ok, state, result, _headers} -> {:reply, {:ok, result}, state}
      {:error, state, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:teardown, _from, state) do
    {:reply, delete_session(state), state}
  end

  @impl true
  def terminate(_reason, %{transport: transport, connection: connection})
      when not is_nil(connection) do
    transport.close(connection)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp exchange(state, method, params, timeout_ms) do
    id = state.next_id
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case encode(payload) do
      {:ok, body} -> post_and_classify(%{state | next_id: id + 1}, body, timeout_ms, id)
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp post_and_classify(state, body, timeout_ms, id) do
    case post(state, body, timeout_ms) do
      {:ok, state, response} -> classify(state, response, id)
      {:error, state, reason} -> {:error, state, reason}
    end
  end

  defp notify(state, method, params, timeout_ms) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    case encode(payload) do
      {:ok, body} -> post_and_accept(state, body, timeout_ms)
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp post_and_accept(state, body, timeout_ms) do
    case post(state, body, timeout_ms) do
      {:ok, state, response} -> accept_notification(state, response)
      {:error, state, reason} -> {:error, state, reason}
    end
  end

  defp encode(payload) do
    case Json.encode(payload) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:remote_protocol_error, reason}}
    end
  end

  defp post(state, body, timeout_ms) do
    case state.transport.request(state.connection, "POST", headers(state), body, timeout_ms) do
      {:ok, connection, response} -> {:ok, %{state | connection: connection}, response}
      {:error, connection, reason} -> {:error, %{state | connection: connection}, reason}
    end
  end

  # Streamable HTTP POSTs advertise BOTH response forms; the server chooses.
  # Advertising only JSON is how a client silently loses every streamed reply.
  defp headers(state) do
    [
      AuthRef.header(state.credential),
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"}
    ]
    |> put_session(state.session_id)
    |> put_protocol_version(state.session_id)
  end

  defp put_session(headers, nil), do: headers
  defp put_session(headers, id), do: headers ++ [{"mcp-session-id", id}]

  # The negotiated version rides every request AFTER initialization; during
  # initialize there is nothing negotiated yet.
  defp put_protocol_version(headers, nil), do: headers

  defp put_protocol_version(headers, _id),
    do: headers ++ [{"mcp-protocol-version", @protocol_version}]

  defp classify(state, %{status: status, body: body, headers: headers}, id)
       when status in 200..299 do
    case decode_result(body, id) do
      {:ok, result} -> {:ok, state, result, headers}
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp classify(state, response, _id), do: {:error, state, http_error(state, response)}

  defp accept_notification(state, %{status: status}) when status in 200..299, do: {:ok, state}
  defp accept_notification(state, response), do: {:error, state, http_error(state, response)}

  defp http_error(state, %{status: 401}), do: {:reauthorization_required, state.endpoint.host}
  defp http_error(%{session_id: id}, %{status: 404}) when is_binary(id), do: :session_expired
  defp http_error(_state, %{status: 429} = response), do: rate_limited(response)
  defp http_error(_state, %{status: status}), do: {:remote_http_error, status}

  defp rate_limited(%{headers: headers}) do
    case retry_after_ms(headers) do
      {:ok, ms} -> {:rate_limited, ms}
      :error -> {:remote_protocol_error, :invalid_retry_after}
    end
  end

  # An absent header is legal (Eden documents it as optional) and uses one
  # fixed local backoff. A value beyond the bound is refused rather than
  # honoured: server-controlled state must not create an unbounded timer.
  defp retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil -> {:ok, Limits.default_retry_after_ms()}
      raw -> parse_retry_after(String.trim(raw))
    end
  end

  defp parse_retry_after(raw) do
    case Integer.parse(raw) do
      {seconds, ""} when seconds >= 0 -> bound_retry_after(seconds * 1000)
      _not_an_integer -> parse_retry_after_date(raw)
    end
  end

  defp parse_retry_after_date(raw) do
    with {:ok, at} <- parse_http_date(raw) do
      bound_retry_after(DateTime.diff(at, DateTime.utc_now(), :millisecond))
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # RFC 9110 IMF-fixdate only ("Sun, 06 Nov 1994 08:49:37 GMT"). The two
  # obsolete formats are refused rather than parsed: senders MUST use
  # IMF-fixdate, and a second date grammar is a second code path whose only
  # effect would be to honour a header this rail already bounds tightly.
  defp parse_http_date(raw) do
    with [_day_name, day, month, year, time, "GMT"] <- String.split(raw, [" ", ","], trim: true),
         {:ok, month} <- month_number(month),
         [hour, minute, second] <- String.split(time, ":"),
         {:ok, date} <- build_date(year, month, day),
         {:ok, time} <- build_time(hour, minute, second) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _unparseable -> :error
    end
  end

  defp month_number(month) do
    case Enum.find_index(@months, &(&1 == month)) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  defp build_date(year, month, day) do
    with {year, ""} <- Integer.parse(year), {day, ""} <- Integer.parse(day) do
      Date.new(year, month, day)
    else
      _unparseable -> :error
    end
  end

  defp build_time(hour, minute, second) do
    with {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second) do
      Time.new(hour, minute, second)
    else
      _unparseable -> :error
    end
  end

  defp bound_retry_after(ms) when is_integer(ms) and ms >= 0 do
    if ms <= Limits.max_retry_after_ms(), do: {:ok, ms}, else: :error
  end

  defp bound_retry_after(_ms), do: :error

  defp decode_result({:json, raw}, id), do: raw |> decode_message() |> extract(id)
  defp decode_result({:sse, events}, id), do: events |> sse_message(id) |> extract(id)
  defp decode_result({:empty, _raw}, _id), do: {:error, {:invalid_remote_result, :empty_body}}

  defp decode_message(raw) do
    Json.decode(raw,
      max_bytes: Limits.max_result_bytes(),
      max_depth: Limits.max_result_depth()
    )
  end

  defp sse_message(events, id) do
    events
    |> Enum.map(& &1.data)
    |> Enum.map(&decode_message/1)
    |> Enum.find(:error, &matches_id?(&1, id))
    |> case do
      :error -> {:error, {:invalid_remote_result, :no_matching_message}}
      found -> found
    end
  end

  defp matches_id?({:ok, %{"id" => id}}, id), do: true
  defp matches_id?(_message, _id), do: false

  defp extract({:ok, %{"id" => id, "result" => result}}, id) when is_map(result),
    do: {:ok, result}

  defp extract({:ok, %{"id" => id, "error" => %{"code" => code} = error}}, id),
    do: {:error, {:remote_jsonrpc_error, code, Map.get(error, "message")}}

  defp extract({:ok, _other}, _id), do: {:error, {:invalid_remote_result, :id_mismatch}}
  defp extract({:error, reason}, _id), do: {:error, {:invalid_remote_result, reason}}

  defp adopt_session_id(state, headers) do
    case header_value(headers, "mcp-session-id") do
      nil -> {:ok, state}
      raw -> validate_session_id(state, raw)
    end
  end

  # A session id is opaque and server-chosen, so it is bounded and
  # character-checked before it is ever echoed back in a header.
  defp validate_session_id(state, raw) do
    cond do
      byte_size(raw) < 1 or byte_size(raw) > Limits.max_session_id_bytes() ->
        {:error, {:remote_protocol_error, :session_id_length}}

      not visible_ascii?(raw) ->
        {:error, {:remote_protocol_error, :session_id_charset}}

      true ->
        {:ok, %{state | session_id: raw}}
    end
  end

  defp visible_ascii?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 0x21 and &1 <= 0x7E))
  end

  defp delete_session(%{session_id: nil}), do: :ok

  defp delete_session(state) do
    case state.transport.request(
           state.connection,
           "DELETE",
           headers(state),
           nil,
           Timeouts.mcp_remote_teardown()
         ) do
      {:ok, _connection, %{status: status}} when status in 200..299 -> :ok
      {:ok, _connection, %{status: 405}} -> :ok
      {:ok, _connection, %{status: status}} -> {:error, {:teardown_failed, status}}
      {:error, _connection, reason} -> {:error, {:teardown_failed, reason}}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end
end
