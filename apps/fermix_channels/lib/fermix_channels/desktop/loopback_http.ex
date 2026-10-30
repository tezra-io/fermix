defmodule FermixChannels.Desktop.LoopbackHttp do
  @moduledoc """
  The minimal HTTP/1.1 both ends of the sign-in loopback forward speak
  (M75 D17): the desktop reads the browser's request (`read_request/3`) and
  writes back the answer (`write_response/4`), and the primary replays the
  request against its own `127.0.0.1` listener (`replay/4`).

  One request per connection, `Connection: close` both ways. Within the
  wire's bounds (`priv/mobile/PROTOCOL.md`, *Desktop sessions*): a method of
  1 to 16 capitals, an origin-form target of at most 2,048 bytes, at most 64
  headers (a name of at most 256 bytes, a value of at most 4,096 with no CR,
  LF or NUL), the whole head at most 64 KiB, a request body at most 16 KiB
  (by `Content-Length`; a chunked body is refused) and a response body at
  most 256 KiB. Hop-by-hop headers (`Connection`, `Keep-Alive`,
  `Transfer-Encoding`, …) and `Content-Length` never cross the rail: each end
  writes its own.
  """

  @max_head_bytes 65_536
  @max_request_body 16_384
  @max_response_body 262_144
  @max_headers 64
  @max_target_bytes 2_048
  @method ~r/\A[A-Z]{1,16}\z/
  @header_name ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]{1,256}\z/
  @forbidden_value ~r/[\r\n\x00]/
  @hop_by_hop ~w(connection keep-alive proxy-connection transfer-encoding upgrade te trailer
                 content-length)

  @type headers :: [[String.t()]]
  @type request :: %{method: String.t(), target: String.t(), headers: headers(), body: binary()}
  @type response :: %{status: 100..599, headers: headers(), body: binary()}

  @doc "The most bytes one forwarded request's body may carry."
  @spec max_request_body() :: pos_integer()
  def max_request_body, do: @max_request_body

  @doc "The most bytes one forwarded response's body may carry."
  @spec max_response_body() :: pos_integer()
  def max_response_body, do: @max_response_body

  @doc """
  Reads one request from `socket` (passive) by `deadline` (monotonic ms):
  `{:ok, request}`, or why not (`{:error, {status, reason}}`, the status the
  browser is answered with).
  """
  @spec read_request(:gen_tcp.socket(), integer(), (-> integer())) ::
          {:ok, request()} | {:error, {pos_integer(), atom()}}
  def read_request(socket, deadline, clock \\ &now/0) do
    with {:ok, head, rest} <- read_head(socket, "", deadline, clock),
         {:ok, method, target, headers} <- parse_request_head(head),
         {:ok, length} <- request_length(headers),
         {:ok, body} <- read_body(socket, rest, length, deadline, clock) do
      {:ok, %{method: method, target: target, headers: end_to_end(headers), body: body}}
    end
  end

  @doc "Writes `status`, `headers` and `body` to `socket` as a complete response."
  @spec write_response(:gen_tcp.socket(), 100..599, headers(), binary()) :: :ok | {:error, term()}
  def write_response(socket, status, headers, body)
      when status in 100..599 and is_list(headers) and is_binary(body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\n",
      Enum.map(end_to_end(headers), fn [name, value] -> [name, ": ", value, "\r\n"] end),
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\nConnection: close\r\n\r\n",
      body
    ])
  end

  @doc """
  Replays `request` against `127.0.0.1:port` and answers the response, read
  until the listener closes, within `timeout_ms`.
  """
  @spec replay(:inet.port_number(), request(), pos_integer(), (-> integer())) ::
          {:ok, response()} | {:error, term()}
  def replay(port, request, timeout_ms, clock \\ &now/0)
      when is_integer(port) and is_map(request) and is_integer(timeout_ms) do
    deadline = clock.() + timeout_ms
    opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect({127, 0, 0, 1}, port, opts, timeout_ms) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, request_bytes(request)),
               {:ok, raw} <- read_all(socket, "", deadline, clock) do
            parse_response(raw)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  @doc "The headers of `headers` that may cross the rail: no hop-by-hop ones, no length."
  @spec end_to_end(headers()) :: headers()
  def end_to_end(headers),
    do: Enum.reject(headers, fn [name, _value] -> String.downcase(name) in @hop_by_hop end)

  @doc "Whether `headers` are within the wire's bounds."
  @spec valid_headers?(term()) :: boolean()
  def valid_headers?(headers) when is_list(headers) and length(headers) <= @max_headers,
    do: Enum.all?(headers, &valid_header?/1)

  def valid_headers?(_headers), do: false

  defp valid_header?([name, value]) when is_binary(name) and is_binary(value) do
    Regex.match?(@header_name, name) and byte_size(value) <= 4_096 and String.valid?(value) and
      not Regex.match?(@forbidden_value, value)
  end

  defp valid_header?(_header), do: false

  # -- the request ------------------------------------------------------------

  defp read_head(socket, acc, deadline, clock) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] when byte_size(acc) > @max_head_bytes ->
        {:error, {431, :head_too_large}}

      [_partial] ->
        with {:ok, more} <- recv(socket, deadline, clock, {408, :request_timeout}),
             do: read_head(socket, acc <> more, deadline, clock)
    end
  end

  defp parse_request_head(head) do
    [line | lines] = String.split(head, "\r\n")

    with [method, target, "HTTP/1." <> _minor] <- String.split(line, " "),
         true <- Regex.match?(@method, method),
         true <- target?(target),
         {:ok, headers} <- parse_headers(lines) do
      {:ok, method, target, headers}
    else
      {:error, _reason} = error -> error
      _malformed -> {:error, {400, :malformed_request}}
    end
  end

  defp target?("/" <> _rest = target),
    do:
      byte_size(target) <= @max_target_bytes and String.valid?(target) and
        not Regex.match?(~r/[\s\x00-\x1f\x7f]/, target)

  defp target?(_target), do: false

  defp parse_headers(lines) when length(lines) > @max_headers,
    do: {:error, {431, :too_many_headers}}

  defp parse_headers(lines) do
    headers =
      Enum.map(lines, fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> [name, String.trim(value)]
          [_bare] -> :malformed
        end
      end)

    if Enum.all?(headers, &valid_header?/1),
      do: {:ok, headers},
      else: {:error, {400, :malformed_header}}
  end

  defp request_length(headers) do
    cond do
      header(headers, "transfer-encoding") != nil ->
        {:error, {411, :chunked_body}}

      length = header(headers, "content-length") ->
        body_length(Integer.parse(length))

      true ->
        {:ok, 0}
    end
  end

  defp body_length({length, ""}) when length >= 0 and length <= @max_request_body,
    do: {:ok, length}

  defp body_length({length, ""}) when length > @max_request_body,
    do: {:error, {413, :body_too_large}}

  defp body_length(_invalid), do: {:error, {400, :malformed_length}}

  defp read_body(_socket, rest, length, _deadline, _clock) when byte_size(rest) >= length,
    do: {:ok, binary_part(rest, 0, length)}

  defp read_body(socket, rest, length, deadline, clock) do
    with {:ok, more} <- recv(socket, deadline, clock, {408, :request_timeout}),
         do: read_body(socket, rest <> more, length, deadline, clock)
  end

  defp recv(socket, deadline, clock, timeout_error) do
    remaining = deadline - clock.()

    if remaining <= 0 do
      {:error, timeout_error}
    else
      case :gen_tcp.recv(socket, 0, remaining) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :timeout} -> {:error, timeout_error}
        {:error, _closed} -> {:error, {400, :connection_closed}}
      end
    end
  end

  # -- the replay ----------------------------------------------------------------

  defp request_bytes(%{method: method, target: target, headers: headers, body: body}) do
    length =
      if body == "",
        do: [],
        else: ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n"]

    [
      method,
      " ",
      target,
      " HTTP/1.1\r\n",
      Enum.map(end_to_end(headers), fn [name, value] -> [name, ": ", value, "\r\n"] end),
      length,
      "Connection: close\r\n\r\n",
      body
    ]
  end

  defp read_all(socket, acc, deadline, clock) do
    cond do
      byte_size(acc) > @max_head_bytes + @max_response_body ->
        {:error, :response_too_large}

      clock.() >= deadline ->
        {:error, :response_timeout}

      true ->
        case :gen_tcp.recv(socket, 0, max(deadline - clock.(), 1)) do
          {:ok, bytes} -> read_all(socket, acc <> bytes, deadline, clock)
          {:error, :closed} -> {:ok, acc}
          {:error, :timeout} -> {:error, :response_timeout}
          {:error, reason} -> {:error, {:recv_failed, reason}}
        end
    end
  end

  defp parse_response(raw) do
    with [head, body] <- :binary.split(raw, "\r\n\r\n"),
         [status_line | lines] = String.split(head, "\r\n"),
         ["HTTP/1." <> _minor, code | _reason] <- String.split(status_line, " ", parts: 3),
         {status, ""} when status in 100..599 <- Integer.parse(code),
         {:ok, headers} <- parse_headers(lines),
         {:ok, body} <- response_body(headers, body) do
      {:ok, %{status: status, headers: end_to_end(headers), body: body}}
    else
      {:error, :response_too_large} = error -> error
      _malformed -> {:error, :malformed_response}
    end
  end

  defp response_body(headers, body) do
    case header(headers, "content-length") do
      nil -> bounded(body)
      length -> declared_body(Integer.parse(length), body)
    end
  end

  defp declared_body({length, ""}, body) when byte_size(body) >= length,
    do: bounded(binary_part(body, 0, length))

  defp declared_body(_invalid, _body), do: {:error, :malformed_response}

  defp bounded(body) when byte_size(body) <= @max_response_body, do: {:ok, body}
  defp bounded(_body), do: {:error, :response_too_large}

  defp header(headers, name) do
    Enum.find_value(headers, fn [key, value] ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(302), do: "Found"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(408), do: "Request Timeout"
  defp reason_phrase(410), do: "Gone"
  defp reason_phrase(411), do: "Length Required"
  defp reason_phrase(413), do: "Content Too Large"
  defp reason_phrase(429), do: "Too Many Requests"
  defp reason_phrase(431), do: "Request Header Fields Too Large"
  defp reason_phrase(502), do: "Bad Gateway"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(504), do: "Gateway Timeout"
  defp reason_phrase(_status), do: "Status"

  defp now, do: System.monotonic_time(:millisecond)
end
