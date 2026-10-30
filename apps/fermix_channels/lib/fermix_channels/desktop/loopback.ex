defmodule FermixChannels.Desktop.Loopback do
  @moduledoc """
  The desktop's half of the sign-in loopback forward (M75 D17, §9), in the
  device role.

  A sign-in the owner starts from this desktop runs on the primary, and its
  authorize url opens in this desktop's browser, so the provider's redirect
  comes to this machine's `127.0.0.1`. The primary says which port its
  listener has (`loopback_open`); this process listens on `127.0.0.1` on that
  port until the primary closes it (`loopback_close`) or the time it gave
  runs out, and forwards each request the browser makes there
  (`loopback_request`, `LoopbackHttp.read_request/3`) and writes the
  primary's answer back to the browser (`loopback_response`). At most 8
  requests per loopback; a ninth is answered `429` here. A request the
  primary does not answer within 30 s is answered `504`.

  It listens only on a port nothing else on this machine listens on: it binds
  without `SO_REUSEADDR`, and when the port is taken it asks the port itself
  (a connect to `127.0.0.1`): a port something answers on is refused, and only
  a port held by closed connections alone (a previous sign-in's) is bound
  again with `SO_REUSEADDR`. Ports below 1024 and this engine's own listeners
  (its setup page, its phone listener) are never taken, and at most 8
  loopbacks are open at once, so the primary can never take over a service
  this computer runs on `localhost`.

  A port this machine will not or cannot listen on (another program has it,
  the system refuses, it is one Fermix keeps, or 8 loopbacks are open) is
  reported to the primary (`loopback_failed`), whose sign-in then fails with
  that sentence.

  The relay hands it the primary's events (`handle/3`, one line each in
  `Desktop.Relay`'s `@inbound`); every connection is served in a task of its
  own, which reaches the primary through the relay. Test seams: `:name`,
  `:send` (a 2-arity function of the event and its payload, in place of
  `Desktop.Relay.send_event/3`), `:task_supervisor`, `:read_timeout_ms`,
  `:answer_timeout_ms`, `:schedule` (in place of `Process.send_after/3`, given
  the message and the delay), `:bind_port` (the port to listen on for a
  port the primary names: a test runs both ends on one machine, where the
  primary's own listener already has that port) and `:own_ports` (this
  engine's own listener ports).
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.LoopbackHttp
  alias FermixChannels.Desktop.Relay

  @events ~w(loopback_open loopback_response loopback_close)
  @max_requests 8
  @max_loopbacks 8
  @read_timeout_ms 10_000
  @answer_timeout_ms 30_000
  # How long the probe of a taken port waits for something to answer on it.
  @probe_timeout_ms 500
  @first_unreserved_port 1_024

  @doc "The primary's events this process serves."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Serves one of the primary's loopback events, from the relay."
  @spec handle(String.t(), map(), binary()) :: :ok | {:error, :not_running}
  def handle(type, fields, payload) when type in @events and is_map(fields),
    do: handle(__MODULE__, type, fields, payload)

  @doc false
  @spec handle(GenServer.server(), String.t(), map(), binary()) :: :ok | {:error, :not_running}
  def handle(server, type, fields, payload) when type in @events do
    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, {:event, type, fields, payload})
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The ports this desktop listens on now, by loopback."
  @spec listening(GenServer.server()) :: %{String.t() => [:inet.port_number()]}
  def listening(server \\ __MODULE__), do: GenServer.call(server, :listening)

  @impl true
  def init(opts) do
    {:ok,
     %{
       send: Keyword.get(opts, :send, &Relay.send_event(Relay, &1, &2)),
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
       read_timeout_ms: Keyword.get(opts, :read_timeout_ms, @read_timeout_ms),
       schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
       bind_port: Keyword.get(opts, :bind_port, & &1),
       own_ports: Keyword.get_lazy(opts, :own_ports, &own_ports/0),
       answer_timeout_ms: Keyword.get(opts, :answer_timeout_ms, @answer_timeout_ms),
       loopbacks: %{},
       pending: %{}
     }}
  end

  @impl true
  def handle_call(:listening, _from, state),
    do: {:reply, Map.new(state.loopbacks, fn {id, lb} -> {id, Map.keys(lb.listeners)} end), state}

  # A connection's request: counted against the loopback's 8, and given the
  # id its answer comes back under.
  def handle_call({:request, id}, {handler, _tag}, state) do
    case Map.fetch(state.loopbacks, id) do
      {:ok, %{requests: count}} when count >= @max_requests ->
        {:reply, {:error, :too_many_requests}, state}

      {:ok, loopback} ->
        request_id = "rq-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        ref = Process.monitor(handler)
        state = put_in(state.loopbacks[id], %{loopback | requests: loopback.requests + 1})
        {:reply, {:ok, request_id}, put_in(state.pending[request_id], {handler, ref})}

      :error ->
        {:reply, {:error, :closed}, state}
    end
  end

  @impl true
  def handle_cast({:event, "loopback_open", fields, _payload}, state),
    do: {:noreply, open(fields, state)}

  def handle_cast({:event, "loopback_close", %{"loopback_id" => id}, _payload}, state),
    do: {:noreply, close(id, state)}

  def handle_cast(
        {:event, "loopback_response", %{"request_id" => request_id} = fields, body},
        state
      ) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        Logger.warning("desktop loopback: an answer to #{request_id}, which no browser waits for")
        {:noreply, state}

      {{handler, ref}, pending} ->
        Process.demonitor(ref, [:flush])
        send(handler, {:loopback_answer, request_id, fields["status"], fields["headers"], body})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:expire, id, token}, state) do
    case Map.fetch(state.loopbacks, id) do
      {:ok, %{token: ^token}} -> {:noreply, close(id, state)}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _handler, _reason}, state) do
    pending = state.pending |> Enum.reject(fn {_id, {_pid, r}} -> r == ref end) |> Map.new()
    {:noreply, %{state | pending: pending}}
  end

  def handle_info(message, state) do
    Logger.warning("desktop loopback: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.loopbacks, fn {_id, loopback} -> close_listeners(loopback) end)
  end

  # A loopback the primary opens again (this desktop reconnected) keeps the
  # listeners it has.
  defp open(%{"loopback_id" => id}, state) when is_map_key(state.loopbacks, id), do: state

  # Past 8 open loopbacks every port is refused: no sign-in needs more.
  defp open(%{"loopback_id" => id, "ports" => ports}, state)
       when map_size(state.loopbacks) >= @max_loopbacks do
    Enum.each(ports, &report_failure(id, &1, :too_many_loopbacks, state))
    state
  end

  defp open(%{"loopback_id" => id, "ports" => ports, "expires_in_s" => seconds}, state) do
    listeners =
      ports
      |> Enum.map(&{&1, take_port(&1, state)})
      |> Enum.flat_map(fn
        {port, {:ok, socket}} -> [{port, socket}]
        {port, {:error, reason}} -> report_failure(id, port, reason, state)
      end)
      |> Map.new()

    Enum.each(listeners, fn {_port, socket} -> accept(socket, id, state) end)
    token = make_ref()
    state.schedule.({:expire, id, token}, seconds * 1_000)
    put_in(state.loopbacks[id], %{listeners: listeners, requests: 0, token: token})
  end

  # A port below 1024 or one of this engine's own is never taken; any other is
  # taken only when nothing listens on it.
  defp take_port(port, state) do
    if port < @first_unreserved_port or port in state.own_ports,
      do: {:error, :reserved},
      else: listen(state.bind_port.(port))
  end

  # Without `SO_REUSEADDR` a port another socket listens on (a wildcard one
  # included) is refused. Taken, it is asked: something answering keeps it;
  # only closed connections of an earlier listener (nothing answers) let it be
  # bound again with the option.
  defp listen(port) do
    case bind(port, false) do
      {:error, :eaddrinuse} -> rebind(port)
      result -> result
    end
  end

  defp rebind(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @probe_timeout_ms) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)
        {:error, :eaddrinuse}

      {:error, :econnrefused} ->
        bind(port, true)

      {:error, _unanswered} ->
        {:error, :eaddrinuse}
    end
  end

  defp bind(port, reuse?) do
    :gen_tcp.listen(port, [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: reuse?,
      ip: {127, 0, 0, 1}
    ])
  end

  # This engine's own TCP listeners: the setup page and the phone listener,
  # as configured for this run.
  defp own_ports do
    web =
      :fermix_web
      |> Application.get_env(FermixWebWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port)

    mobile = :fermix_channels |> Application.get_env(:mobile, []) |> Keyword.get(:port)
    Enum.filter([web, mobile], &is_integer/1)
  end

  defp report_failure(id, port, reason, state) do
    Logger.warning("desktop loopback: port #{port} could not be opened: #{inspect(reason)}")

    event = %{
      "t" => "loopback_failed",
      "loopback_id" => id,
      "port" => port,
      "reason" => failure_word(reason)
    }

    tell_primary(state, event, <<>>)
    []
  end

  defp failure_word(:eaddrinuse), do: "port_in_use"
  defp failure_word(:eacces), do: "not_permitted"
  defp failure_word(:eperm), do: "not_permitted"
  defp failure_word(:reserved), do: "not_permitted"
  defp failure_word(_reason), do: "failed"

  defp close(id, state) do
    case Map.pop(state.loopbacks, id) do
      {nil, _loopbacks} ->
        state

      {loopback, loopbacks} ->
        close_listeners(loopback)
        %{state | loopbacks: loopbacks}
    end
  end

  # Closing a listener ends its acceptor's `accept`; a connection being served
  # finishes on its own.
  defp close_listeners(%{listeners: listeners}),
    do: Enum.each(listeners, fn {_port, socket} -> :gen_tcp.close(socket) end)

  defp accept(listener, id, state) do
    server = self()
    serve = &serve(&1, id, server, state)

    {:ok, _acceptor} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        accept_loop(listener, serve, state.task_supervisor)
      end)

    :ok
  end

  defp accept_loop(listener, serve, task_supervisor) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        {:ok, handler} =
          Task.Supervisor.start_child(task_supervisor, fn -> await_socket(serve) end)

        :ok = :gen_tcp.controlling_process(conn, handler)
        send(handler, {:socket, conn})
        accept_loop(listener, serve, task_supervisor)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("desktop loopback: accept stopped: #{inspect(reason)}")
    end
  end

  defp await_socket(serve) do
    receive do
      {:socket, conn} -> serve.(conn)
    end
  end

  # One connection: its request, forwarded once it is whole; the primary's
  # answer, written back; the connection closed on every path.
  defp serve(conn, id, server, state) do
    deadline = System.monotonic_time(:millisecond) + state.read_timeout_ms

    try do
      case LoopbackHttp.read_request(conn, deadline) do
        {:ok, request} -> forward(conn, id, request, server, state)
        {:error, {status, _reason}} -> refuse(conn, status, "This request cannot be forwarded.")
      end
    after
      :gen_tcp.close(conn)
    end
  end

  defp forward(conn, id, request, server, state) do
    case GenServer.call(server, {:request, id}) do
      {:ok, request_id} ->
        event = %{
          "t" => "loopback_request",
          "loopback_id" => id,
          "request_id" => request_id,
          "method" => request.method,
          "target" => request.target,
          "headers" => request.headers
        }

        tell_primary(state, event, request.body)
        await_answer(conn, request_id, state)

      {:error, :too_many_requests} ->
        refuse(conn, 429, "This sign-in has had all the requests it takes.")

      {:error, :closed} ->
        refuse(conn, 410, "This sign-in has ended.")
    end
  end

  defp await_answer(conn, request_id, state) do
    receive do
      {:loopback_answer, ^request_id, status, headers, body} ->
        LoopbackHttp.write_response(conn, status, headers, body)
    after
      state.answer_timeout_ms ->
        refuse(conn, 504, "The server did not answer the sign-in in time.")
    end
  end

  defp refuse(conn, status, text) do
    headers = [["Content-Type", "text/plain; charset=utf-8"], ["Cache-Control", "no-store"]]
    LoopbackHttp.write_response(conn, status, headers, text)
  end

  defp tell_primary(state, %{"t" => type} = event, payload) do
    case state.send.(event, payload) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("desktop loopback: #{type} not sent: #{inspect(reason)}")
    end
  end
end
