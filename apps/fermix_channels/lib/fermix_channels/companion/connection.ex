defmodule FermixChannels.Companion.Connection do
  @moduledoc """
  One client connection on `companion.sock`.

  The endpoint starts it and hands it the accepted socket; from then on this
  process owns the socket, so the fd closes the instant it exits, however it
  exits. It reads newline-delimited JSON through `FermixCore.Companion.Protocol`,
  enforces the mandatory hello handshake exactly as the Realtime socket does,
  and serves the chat vocabulary through the request path the phone shares
  (`Companion.Requests`).

  A `msg` or `command` runs in one supervised worker at a time, so this process
  stays free for `cancel`, history and search while a request is claimed and
  ingested; the worker is not linked, because a claimed request must settle
  whether or not its client stays. Everything the turn says afterwards arrives
  here from `Channels.Companion` through the registry this connection joins
  after its handshake.

  A protocol violation (a malformed or oversized line, an unknown event, an
  event before the handshake, a second hello) is answered with one `error` and
  the connection closes. A request that fails is answered with one `error` and
  the connection stays open.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Requests
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Companion.Protocol

  @profile "main"
  @max_pending_requests 32
  @max_tracked_streams 8
  @max_error_message 512
  @handover_timeout_ms 5_000

  # The closed vocabulary of `error.reason` this socket sends, besides
  # `unsupported_protocol_version`, `max_clients_reached` (the endpoint's), the
  # field and event errors that name what they refused, and `request_failed`,
  # which every other failure becomes.
  @named_reasons ~w(
    invalid_json invalid_event missing_type attachments_unsupported missing_protocol_version
    invalid_protocol_version line_too_large handshake_required unexpected_client_hello
    client_message_conflict unsupported_profile request_backlog_full
  )a

  @type state :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Every `error.reason` this socket can send."
  @spec error_reasons() :: [String.t()]
  def error_reasons do
    Enum.map(@named_reasons, &Atom.to_string/1) ++
      ~w(missing_field invalid_field unknown_event unsupported_protocol_version
         max_clients_reached request_failed)
  end

  @doc """
  Recover one stored companion request at boot. Nobody is waiting for its
  `accepted`; its turn speaks to every connection that has joined by then.
  """
  @spec recover_request(map(), map(), keyword()) :: :ok | {:error, term()}
  def recover_request(row, %{transport: :companion}, opts) when is_map(row) and is_list(opts) do
    sink = &sink(Companion.registry(), &1, &2)

    opts =
      [agent: Turns, settlement_owner: Turns]
      |> Keyword.merge(opts)
      |> Keyword.put(:event_sink, sink)

    Requests.recover(row, transport(nil), opts)
  end

  @impl true
  def init(opts) do
    state = %{
      socket: Keyword.fetch!(opts, :socket),
      buffer: "",
      version: nil,
      streams: %{},
      pending: [],
      worker: nil,
      registry: Keyword.get(opts, :registry, Companion.registry()),
      queue: Keyword.get(opts, :queue, Queue),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      request_opts: Keyword.get(opts, :request_opts, [])
    }

    {:ok, state, @handover_timeout_ms}
  end

  @impl true
  def handle_info(:socket_handover, state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, {:socket_arm_failed, reason}}, state}
    end
  end

  # The endpoint died between starting this process and handing it the socket.
  def handle_info(:timeout, %{version: nil, buffer: ""} = state),
    do: {:stop, {:shutdown, :handover_timeout}, state}

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case drain_lines(%{state | buffer: state.buffer <> bytes}) do
      {:cont, state} -> rearm(state)
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.debug("companion connection read error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:companion_event, event}, state),
    do: write_event(event, forget_stream(event, state))

  def handle_info({:companion_stream, turn_id, update}, state),
    do: write_stream(turn_id, update, state)

  def handle_info({:companion_request_failed, client_msg_id, reason}, state),
    do: write_request_error(reason, client_msg_id, state)

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: {ref, client_msg_id}} = state) do
    state = %{state | worker: nil}

    with {:noreply, state} <- worker_exit(reason, client_msg_id, state) do
      start_next_request(state)
    end
  end

  def handle_info(message, state) do
    Logger.debug("companion connection ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp rearm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp drain_lines(%{buffer: buffer} = state) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> process_line(line, %{state | buffer: rest})
      [_partial] -> partial_line(state)
    end
  end

  defp partial_line(state) do
    if byte_size(state.buffer) > Protocol.max_line_bytes(),
      do: refuse(:line_too_large, state),
      else: {:cont, state}
  end

  defp process_line(line, state) do
    cond do
      byte_size(line) > Protocol.max_line_bytes() -> refuse(:line_too_large, state)
      String.trim(line) == "" -> drain_lines(state)
      true -> line |> String.trim() |> handle_line(state) |> continue_draining()
    end
  end

  defp continue_draining({:cont, state}), do: drain_lines(state)
  defp continue_draining({:stop, state}), do: {:stop, state}

  defp handle_line(line, state) do
    case Protocol.decode_client_event(line) do
      {:ok, event} -> dispatch(event, state)
      {:error, reason} -> refuse(reason, state)
    end
  end

  defp dispatch(%{type: "client_hello", payload: payload}, state), do: hello(payload, state)
  defp dispatch(_event, %{version: nil} = state), do: refuse(:handshake_required, state)

  defp dispatch(%{type: type} = event, state) when type in ["msg", "command"],
    do: queue_request(event, state)

  defp dispatch(%{type: "cancel", payload: payload}, state), do: cancel(payload, state)

  defp dispatch(%{type: "history_pull", payload: payload}, state),
    do: answer(Requests.history(payload, transport(self()), read_opts(state)), state)

  defp dispatch(%{type: "history_search", payload: payload}, state),
    do: answer(Requests.search(payload, transport(self()), read_opts(state)), state)

  defp dispatch(%{type: "read_state", payload: payload}, state),
    do: answer(Requests.read_state(payload, request_opts(state)), state)

  # A repeat hello is a protocol violation: the handshake is one transition.
  defp hello(_payload, %{version: version} = state) when is_integer(version),
    do: refuse(:unexpected_client_hello, state)

  defp hello(%{"protocol_version" => version}, state) do
    case Protocol.negotiate(version) do
      :ok -> join(version, state)
      {:error, direction} -> refuse_version(direction, version, state)
    end
  end

  defp join(version, state) do
    {min, max} = Protocol.supported_version_range()

    with {:ok, _owner} <- Registry.register(state.registry, @profile, nil),
         :ok <- send_event("server_hello", %{"min_version" => min, "max_version" => max}, state) do
      {:cont, %{state | version: version}}
    else
      _failed -> {:stop, state}
    end
  end

  defp refuse_version(direction, client_version, state) do
    {min, max} = Protocol.supported_version_range()

    payload = %{
      "reason" => "unsupported_protocol_version",
      "direction" => Atom.to_string(direction),
      "client_version" => client_version,
      "min_version" => min,
      "max_version" => max
    }

    _ = send_event("error", payload, state)
    {:stop, state}
  end

  # Stops the one turn the request named, running or waiting, and writes
  # nothing itself: the turn ends on the wire from the queue's outcome, a
  # `turn_error` (code `cancelled`), or its `text_done` when it had already
  # finished. Other clients' turns in the conversation are untouched.
  defp cancel(%{"profile_id" => @profile, "client_msg_id" => client_msg_id}, state) do
    key = Companion.conversation_key(@profile)
    {:ok, _stopped} = Queue.stop_turn(key, client_msg_id, state.queue)
    {:cont, state}
  end

  defp cancel(_payload, state), do: answer({:error, :unsupported_profile}, state)

  defp answer(:ok, state), do: {:cont, state}

  defp answer({:error, reason}, state) do
    case send_event("error", error_payload(reason, nil), state) do
      :ok -> {:cont, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  defp queue_request(_event, %{pending: pending} = state)
       when length(pending) >= @max_pending_requests,
       do: answer({:error, :request_backlog_full}, state)

  defp queue_request(event, state) do
    case start_next_request(%{state | pending: state.pending ++ [event]}) do
      {:noreply, state} -> {:cont, state}
      {:stop, _reason, state} -> {:stop, state}
    end
  end

  defp start_next_request(%{worker: {_ref, _id}} = state), do: {:noreply, state}
  defp start_next_request(%{pending: []} = state), do: {:noreply, state}

  defp start_next_request(%{pending: [event | rest]} = state) do
    client_msg_id = event.payload["client_msg_id"]

    case Task.Supervisor.start_child(state.task_supervisor, request_job(event, state)) do
      {:ok, pid} ->
        {:noreply, %{state | pending: rest, worker: {Process.monitor(pid), client_msg_id}}}

      {:error, reason} ->
        {:stop, {:shutdown, {:request_worker_unavailable, reason}}, state}
    end
  end

  defp request_job(event, state) do
    connection = self()
    transport = transport(connection)
    opts = request_opts(state)
    client_msg_id = event.payload["client_msg_id"]

    fn ->
      case Requests.request(event, transport, opts) do
        :ok -> :ok
        {:error, reason} -> send(connection, {:companion_request_failed, client_msg_id, reason})
      end
    end
  end

  defp worker_exit(:normal, _client_msg_id, state), do: {:noreply, state}

  defp worker_exit(reason, client_msg_id, state),
    do: write_request_error({:request_failed, reason}, client_msg_id, state)

  defp write_request_error(reason, client_msg_id, state) do
    case send_event("error", error_payload(reason, client_msg_id), state) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp write_event(%{"t" => type} = event, state) do
    case Protocol.encode_server_event(type, Map.delete(event, "t")) do
      {:ok, line} -> write_line(line, state)
      {:error, reason} -> drop_event(type, reason, state)
    end
  end

  defp write_line(line, state) do
    case :gen_tcp.send(state.socket, line) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  # An event this wire has no shape for is a daemon bug, reported where the
  # daemon's operator reads, never forwarded half-formed to the client.
  defp drop_event(type, reason, state) do
    Logger.error("companion connection dropped a #{type} event: #{inspect(reason)}")
    {:noreply, state}
  end

  defp write_stream(turn_id, :reset, state),
    do: {:noreply, %{state | streams: track(state.streams, turn_id, "")}}

  defp write_stream(turn_id, {:snapshot, text}, state) do
    sent = Map.get(state.streams, turn_id, "")
    state = %{state | streams: track(state.streams, turn_id, text)}

    case unsent_suffix(sent, text) do
      "" -> {:noreply, state}
      suffix -> write_event(%{"t" => "text_delta", "turn_id" => turn_id, "text" => suffix}, state)
    end
  end

  # A snapshot that does not extend what was written restarted its text, so it
  # is sent whole.
  defp unsent_suffix(sent, text) do
    if String.starts_with?(text, sent),
      do: binary_part(text, byte_size(sent), byte_size(text) - byte_size(sent)),
      else: text
  end

  # Turns run one at a time per conversation, so only a turn whose terminal
  # event never arrived (its queue died) can linger; the bound drops those.
  defp track(streams, turn_id, text) do
    streams =
      if Map.has_key?(streams, turn_id) or map_size(streams) < @max_tracked_streams,
        do: streams,
        else: %{}

    Map.put(streams, turn_id, text)
  end

  defp forget_stream(%{"t" => type, "turn_id" => turn_id}, state)
       when type in ["text_done", "turn_error"],
       do: %{state | streams: Map.delete(state.streams, turn_id)}

  defp forget_stream(_event, state), do: state

  defp refuse(reason, state) do
    _ = send_event("error", error_payload(reason, nil), state)
    {:stop, state}
  end

  defp send_event(type, payload, state) do
    with {:ok, line} <- Protocol.encode_server_event(type, payload) do
      :gen_tcp.send(state.socket, line)
    end
  end

  defp error_payload(reason, client_msg_id) do
    reason
    |> error_fields()
    |> maybe_put("client_msg_id", client_msg_id)
  end

  defp error_fields({field_error, field}) when field_error in [:missing_field, :invalid_field],
    do: %{"reason" => Atom.to_string(field_error), "field" => field}

  defp error_fields({:unknown_event, type}), do: %{"reason" => "unknown_event", "event" => type}

  defp error_fields(reason) when reason in @named_reasons,
    do: %{"reason" => Atom.to_string(reason)}

  # A failure reason can carry an exception and its stacktrace: the message is
  # bounded so the error that reports it can always be written.
  defp error_fields({:request_failed, cause}),
    do: %{"reason" => "request_failed", "message" => bounded_inspect(cause)}

  defp error_fields(reason),
    do: %{"reason" => "request_failed", "message" => bounded_inspect(reason)}

  defp bounded_inspect(term) do
    term |> inspect(limit: 5, printable_limit: 256) |> String.slice(0, @max_error_message)
  end

  defp transport(reply_to) do
    %{
      name: :companion,
      channel: Companion,
      claimant: [],
      ingress_context: %{transport: :companion},
      reply_to: reply_to,
      attempt_key: :companion_attempt,
      after_user_append: &announce_user_row/4,
      after_command: nil
    }
  end

  # A user's row is announced to every connection watching the profile as it
  # is written, the sender's own included, carrying its `client_msg_id`.
  defp announce_user_row(profile, row, _text, opts),
    do: Keyword.fetch!(opts, :event_sink).({:profile, profile}, Companion.row_event(profile, row))

  defp request_opts(state) do
    registry = state.registry
    Keyword.put(state.request_opts, :event_sink, &sink(registry, &1, &2))
  end

  # A page or a search answer is written to the socket in the step that read
  # it, the way `server_hello` is, never through this process's mailbox: a live
  # event for a row written after the read can then only reach the socket after
  # the page, so every row is in the page or announced after it.
  defp read_opts(state) do
    Keyword.put(state.request_opts, :event_sink, fn _reply_to, %{"t" => type} = event ->
      send_event(type, Map.delete(event, "t"), state)
    end)
  end

  defp sink(_registry, pid, event) when is_pid(pid) do
    send(pid, {:companion_event, event})
    :ok
  end

  defp sink(registry, {:profile, profile_id}, event),
    do: Companion.broadcast(profile_id, event, registry)

  defp sink(_registry, nil, _event), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
