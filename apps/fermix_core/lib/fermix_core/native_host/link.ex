defmodule FermixCore.NativeHost.Link do
  @moduledoc """
  The Fermix app's native host on `native_host.sock` (M76 §4.4): the one
  connection the daemon asks the app for this Mac's own services over.

  The server (`NativeHost.Server`) starts it and hands it the accepted socket;
  from then on this process owns the socket, so the fd closes the instant it
  exits, however it exits, and its exit is what `Native.HostAvailability`
  watches. It reads newline-delimited JSON through
  `FermixCore.NativeHost.Protocol`.

  ## The wire

  The app says `client_hello`, is answered `server_hello`, then says
  `attached`; only then is it the host (`Native.HostAvailability.attached/4`).
  Its `capabilities` reports go to the same record. From there the daemon
  asks: a caller's `request/4` is written with the next `id` of this
  connection, and the answer carrying that id is the caller's reply. There
  are no tasks: a request is one grant question or one post, and nothing is
  released after it. Requests leave in the order this process takes them, and
  the app's answers and events are read in the order it wrote them.

  ## The app quitting

  `host_stopping` marks the record stopping, final for this connection, and is
  answered with `host.stop_ack`. A request after it is refused here, before
  it reaches the wire, with `host_unavailable`; one already written may still
  be answered, or ends when the connection closes. The app holds its quit for
  `host.stop_ack`, and ends the hold on its own bound when the answer is lost.

  ## Who is on the other end

  When the socket is handed over, before any line is read, the connection
  places the process that connected (`FermixCore.SocketPeer`). The host must
  be a process the daemon did not start: one the agent spawned could answer
  as the app. Anything but an independent process is refused with one `error`
  (`untrusted_host`) and closed.

  A protocol violation is answered with one `error` and closes the connection.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Native.HostAvailability
  alias FermixCore.NativeHost.Protocol
  alias FermixCore.SocketPeer
  alias FermixCore.Temporal.Registry
  alias FermixCore.Trace

  @handover_timeout_ms 5_000
  # Requests the app has not answered yet; past it a request is refused here
  # rather than queued behind an app that stopped answering.
  @max_pending 64
  @max_error_message 500

  @typedoc """
  What a request is answered with: the app's result or its error, or, when no
  answer came, `:timeout` (the caller's bound ran out) or `:closed` (the
  connection ended first).
  """
  @type answer ::
          {:ok, map()} | {:error, %{String.t() => String.t()}} | {:error, :timeout | :closed}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Send one request to the app attached on `link` and wait up to `timeout_ms`
  for its answer. An answer that arrives after the bound is dropped.
  """
  @spec request(pid(), String.t(), map(), pos_integer()) :: answer()
  def request(link, type, payload, timeout_ms)
      when is_pid(link) and is_binary(type) and is_map(payload) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    GenServer.call(link, {:request, type, payload}, timeout_ms)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :closed}
    :exit, {{:shutdown, _cause}, _call} -> {:error, :closed}
  end

  @impl true
  def init(opts) do
    state = %{
      socket: Keyword.fetch!(opts, :socket),
      connection_id: Keyword.fetch!(opts, :connection_id),
      host_availability: Keyword.get(opts, :host_availability, HostAvailability),
      buffer: "",
      version: nil,
      attached: false,
      stopping: false,
      next_id: 1,
      pending: %{},
      daemon_os_pid: Keyword.get(opts, :daemon_os_pid, String.to_integer(System.pid())),
      os: Keyword.get(opts, :os, :os.type()),
      snooze: Keyword.get(opts, :snooze, &Registry.snooze_from_notification/3)
    }

    {:ok, state, @handover_timeout_ms}
  end

  @impl true
  def handle_call({:request, type, payload}, from, state),
    do: continue(caller_request(type, payload, from, state))

  @impl true
  def handle_info(:socket_handover, state) do
    case SocketPeer.classify(state.socket, state.daemon_os_pid, state.os) do
      {:ok, :independent} -> arm(state)
      {:ok, caller} -> refuse_peer("a process placed as #{caller}", state)
      {:error, :peer_closed} -> {:stop, :normal, state}
      {:error, reason} -> refuse_peer(inspect(reason), state)
    end
  end

  # The server died between starting this process and handing it the socket.
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
    Logger.debug("native host connection read error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    Logger.debug("native host connection ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.attached, do: trace("native_host_detached", %{"connection" => state.connection_id})
    :ok
  end

  defp continue({:cont, state}), do: {:noreply, state}
  defp continue({:stop, state}), do: {:stop, :normal, state}

  defp arm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, {:socket_arm_failed, reason}}, state}
    end
  end

  defp rearm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp refuse_peer(cause, state) do
    Logger.warning("native host connection refusing a host the daemon did not trust: #{cause}")
    message = "the native host must be a process the daemon did not start: #{cause}"
    _ = send_frame("error", error_payload({:untrusted_host, message}), state)
    {:stop, :normal, state}
  end

  # ── lines from the app ─────────────────────────────────────────────────────

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
    case Protocol.decode_host_frame(line) do
      {:ok, frame} -> dispatch(frame, state)
      {:error, reason} -> refuse(reason, state)
    end
  end

  defp dispatch({:hello, version}, %{version: nil} = state), do: hello(version, state)
  defp dispatch({:hello, _version}, state), do: refuse(:unexpected_client_hello, state)
  defp dispatch(_frame, %{version: nil} = state), do: refuse(:handshake_required, state)

  defp dispatch({:event, "attached", payload}, %{attached: false} = state),
    do: attach(payload, state)

  defp dispatch({:event, "attached", _payload}, state), do: refuse(:unexpected_attached, state)
  defp dispatch(_frame, %{attached: false} = state), do: refuse(:attach_required, state)
  defp dispatch({:event, "capabilities", payload}, state), do: capabilities(payload, state)
  defp dispatch({:event, "host_stopping", _payload}, state), do: host_stopping(state)

  defp dispatch({:event, "notification.action", payload}, state),
    do: notification_action(payload, state)

  defp dispatch({:response, id, outcome}, state), do: answered(id, outcome, state)

  defp hello(version, state) do
    case Protocol.negotiate(version) do
      :ok -> server_hello(version, state)
      {:error, direction} -> refuse_version(direction, version, state)
    end
  end

  defp server_hello(version, state) do
    {min, max} = Protocol.supported_version_range()

    case send_frame("server_hello", %{"min_version" => min, "max_version" => max}, state) do
      :ok -> {:cont, %{state | version: version}}
      {:error, _reason} -> {:stop, state}
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

    _ = send_frame("error", payload, state)
    {:stop, state}
  end

  # From here the app is the host: the connection callers ask on.
  defp attach(%{"host_version" => host_version}, state) do
    :ok =
      HostAvailability.attached(
        state.host_availability,
        self(),
        state.connection_id,
        host_version
      )

    trace("native_host_attached", %{
      "connection" => state.connection_id,
      "host_version" => host_version
    })

    {:cont, %{state | attached: true}}
  end

  # A report after `host_stopping` changes nothing: the record holds stopping
  # as final for this connection.
  defp capabilities(%{"notifications" => notifications}, state) do
    :ok = HostAvailability.report(state.host_availability, notifications)

    trace("native_host_capabilities", %{
      "connection" => state.connection_id,
      "notifications" => notifications
    })

    {:cont, state}
  end

  defp host_stopping(%{stopping: true} = state), do: {:cont, state}

  defp host_stopping(state) do
    trace("native_host_stopping", %{"connection" => state.connection_id})
    :ok = HostAvailability.stopping(state.host_availability, self())
    write_request("host.stop_ack", %{}, nil, %{state | stopping: true})
  end

  # The person's press on a notification's action, validated by the codec:
  # Snooze 10 minutes on a reminder that rang here, the owner's own act,
  # applied through the one snooze path with no model turn (M76 D6). The press
  # has no answer on the wire, so a snooze the registry refuses is logged with
  # its own sentence, and the connection goes on.
  defp notification_action(%{"reminder_id" => reminder_id, "action" => action}, state) do
    minutes = Protocol.snooze_minutes(action)

    case snooze(state, reminder_id, minutes) do
      {:ok, _snoozed} ->
        Logger.info("reminder #{reminder_id} snoozed #{minutes} minutes from its notification")

      {:error, reason} ->
        Logger.warning(
          "reminder #{reminder_id} was not snoozed from its notification: " <>
            Registry.describe_error(reason)
        )

      {:exit, reason} ->
        Logger.error(
          "reminder #{reminder_id} was not snoozed from its notification: the registry did " <>
            "not answer (#{inspect(reason, limit: 5, printable_limit: 200)})"
        )
    end

    {:cont, state}
  end

  # The registry's Repo and scheduler calls can exit (a Repo call that timed
  # out); the press then fails alone, and the app's connection stays up.
  defp snooze(state, reminder_id, minutes) do
    state.snooze.(reminder_id, minutes, [])
  catch
    :exit, reason -> {:exit, reason}
  end

  # An answer whose request is not waiting any more (a late one, after its
  # caller's bound ran out) finds its caller gone, and the reply is dropped.
  defp answered(id, outcome, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.debug("native host connection dropped an answer to request #{id}")
        {:cont, state}

      {request, pending} ->
        deliver(request, checked(request.type, outcome))
        {:cont, %{state | pending: pending}}
    end
  end

  defp checked(type, {:ok, result}) do
    case Protocol.validate_result(type, result) do
      :ok ->
        {:ok, result}

      {:error, reason} ->
        Logger.error("native host answered #{type} off the protocol: #{inspect(reason)}")
        {:error, %{"reason" => "invalid_result", "message" => bounded_inspect(reason)}}
    end
  end

  defp checked(_type, {:error, error}), do: {:error, error}

  defp deliver(%{from: nil, type: type}, {:error, error}),
    do: Logger.warning("native host refused #{type}: #{inspect(error)}")

  defp deliver(%{from: nil}, {:ok, _result}), do: :ok
  defp deliver(%{from: from}, answer), do: GenServer.reply(from, answer)

  # ── requests from callers ──────────────────────────────────────────────────

  defp caller_request(_type, _payload, from, %{attached: false} = state) do
    GenServer.reply(from, {:error, unavailable("the app is not attached")})
    {:cont, state}
  end

  defp caller_request(_type, _payload, from, %{stopping: true} = state) do
    GenServer.reply(from, {:error, unavailable("the app is quitting")})
    {:cont, state}
  end

  defp caller_request(_type, _payload, from, state)
       when map_size(state.pending) >= @max_pending do
    GenServer.reply(from, {:error, unavailable("the app is not answering")})
    {:cont, state}
  end

  defp caller_request(type, payload, from, state), do: write_request(type, payload, from, state)

  # The one writer of requests: the next id of this connection, the frame, and
  # who waits for its answer (`nil` for the daemon's own).
  defp write_request(type, payload, from, state) do
    id = state.next_id

    case Protocol.encode_request(id, type, payload) do
      {:ok, line} ->
        sent(:gen_tcp.send(state.socket, line), id, %{from: from, type: type}, state)

      {:error, reason} ->
        Logger.error("native host connection could not encode #{type}: #{inspect(reason)}")
        refuse_encoding(from, reason)
        {:cont, state}
    end
  end

  defp sent(:ok, id, request, state),
    do: {:cont, %{state | next_id: id + 1, pending: Map.put(state.pending, id, request)}}

  defp sent({:error, _reason}, _id, _request, state), do: {:stop, state}

  defp refuse_encoding(nil, _reason), do: :ok

  defp refuse_encoding(from, reason) do
    GenServer.reply(
      from,
      {:error, %{"reason" => "invalid_request", "message" => bounded_inspect(reason)}}
    )
  end

  defp unavailable(message), do: %{"reason" => "host_unavailable", "message" => message}

  # ── frames to the app ──────────────────────────────────────────────────────

  defp refuse(reason, state) do
    _ = send_frame("error", error_payload(reason), state)
    {:stop, state}
  end

  defp send_frame(type, payload, state) do
    with {:ok, line} <- Protocol.encode_daemon_frame(type, payload) do
      :gen_tcp.send(state.socket, line)
    end
  end

  defp error_payload({field_error, field}) when field_error in [:missing_field, :invalid_field],
    do: %{"reason" => Atom.to_string(field_error), "field" => field}

  defp error_payload({:unknown_event, type}), do: %{"reason" => "unknown_event", "event" => type}

  defp error_payload({:untrusted_host, message}),
    do: %{"reason" => "untrusted_host", "message" => String.slice(message, 0, @max_error_message)}

  defp error_payload(reason) when is_atom(reason), do: %{"reason" => Atom.to_string(reason)}

  defp bounded_inspect(term) do
    term |> inspect(limit: 5, printable_limit: 256) |> String.slice(0, @max_error_message)
  end

  defp trace(event, data) do
    Trace.record(:agent_event, "native_host", Map.put(data, "event", event))
  end
end
