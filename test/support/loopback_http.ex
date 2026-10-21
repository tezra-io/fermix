defmodule FermixTestSupport.LoopbackHttp do
  @moduledoc """
  A plain HTTP/1.1 server on 127.0.0.1, or on another loopback address
  (`{handler, {0, 0, 0, 0, 0, 0, 0, 1}}` listens on `::1` only), for tests
  that drive a real client
  socket: the remote MCP rail's connection over `http` to this machine, which
  `Remote.Endpoint.operator/1` admits for a loopback URL (M74 E4).

  `handler` is called in the connection's own process with each request,
  `%{method, path, headers, body}` (header names downcased), and answers one
  of:

    * `{status, headers, body}`: a complete response, the connection kept
      open for the next request;
    * `{:stream, status, headers, chunk}`: the head and one chunk with no
      length, then the connection held open with nothing more written, the
      way an event stream that never ends looks to a client.

  Every request is also recorded, in arrival order and before it is answered,
  for `requests/1`. The
  server, its acceptor and its connections end with the process that started
  it.
  """

  use GenServer

  @type request :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type response ::
          {pos_integer(), [{String.t(), String.t()}], binary()}
          | {:stream, pos_integer(), [{String.t(), String.t()}], binary()}

  @spec start_link((request() -> response()) | {(request() -> response()), :inet.ip_address()}) ::
          GenServer.on_start()
  def start_link({handler, ip}) when is_function(handler, 1) and is_tuple(ip),
    do: GenServer.start_link(__MODULE__, {handler, ip})

  def start_link(handler) when is_function(handler, 1),
    do: GenServer.start_link(__MODULE__, {handler, {127, 0, 0, 1}})

  @doc "The port it listens on."
  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Every request it has read, in arrival order."
  @spec requests(pid()) :: [request()]
  def requests(server), do: GenServer.call(server, :requests)

  @impl true
  def init({handler, ip}) do
    {:ok, listen} =
      :gen_tcp.listen(0, family(ip) ++ [:binary, ip: ip, packet: :http_bin, active: false])

    {:ok, port} = :inet.port(listen)
    server = self()
    acceptor = spawn_link(fn -> accept_loop(listen, server, handler) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)
    {:ok, %{port: port, requests: []}}
  end

  defp family(ip) when tuple_size(ip) == 8, do: [:inet6]
  defp family(_ip), do: [:inet]

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  def handle_call({:request, request}, _from, state),
    do: {:reply, :ok, %{state | requests: state.requests ++ [request]}}

  defp accept_loop(listen, server, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    connection = spawn_link(fn -> receive(do: (:go -> serve(socket, server, handler))) end)
    :ok = :gen_tcp.controlling_process(socket, connection)
    send(connection, :go)
    accept_loop(listen, server, handler)
  end

  # One request after another on the one socket, until the client closes it.
  defp serve(socket, server, handler) do
    case read_request(socket) do
      {:ok, request} ->
        :ok = GenServer.call(server, {:request, request})
        respond(socket, handler.(request), server, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp respond(socket, {status, headers, body}, server, handler) do
    head = head(status, headers ++ [{"content-length", Integer.to_string(byte_size(body))}])
    :ok = :gen_tcp.send(socket, [head, body])
    serve(socket, server, handler)
  end

  defp respond(socket, {:stream, status, headers, chunk}, _server, _handler) do
    :ok = :gen_tcp.send(socket, [head(status, headers), chunk])
    :ok = :inet.setopts(socket, packet: :raw)
    hold(socket)
  end

  # Nothing more is written; the client's close ends it.
  defp hold(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _bytes} -> hold(socket)
      {:error, _closed} -> :ok
    end
  end

  defp head(status, headers) do
    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    ["HTTP/1.1 ", Integer.to_string(status), " ", reason(status), "\r\n", lines, "\r\n"]
  end

  defp reason(status) when status in 200..299, do: "OK"
  defp reason(status) when status in 300..399, do: "Redirect"
  defp reason(_status), do: "Error"

  defp read_request(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        read_headers(socket, %{method: to_string(method), path: path, headers: []})

      {:error, _closed} ->
        {:error, :closed}
    end
  end

  defp read_headers(socket, request) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _index, name, _reserved, value}} ->
        header = {name |> to_string() |> String.downcase(), value}
        read_headers(socket, %{request | headers: request.headers ++ [header]})

      {:ok, :http_eoh} ->
        read_body(socket, request)

      {:error, _closed} ->
        {:error, :closed}
    end
  end

  defp read_body(socket, request) do
    length =
      case List.keyfind(request.headers, "content-length", 0) do
        {_name, value} -> String.to_integer(value)
        nil -> 0
      end

    {:ok, body} = body(socket, length)
    :ok = :inet.setopts(socket, packet: :http_bin)
    {:ok, Map.put(request, :body, body)}
  end

  defp body(_socket, 0), do: {:ok, ""}

  defp body(socket, length) do
    :ok = :inet.setopts(socket, packet: :raw)
    :gen_tcp.recv(socket, length)
  end
end
