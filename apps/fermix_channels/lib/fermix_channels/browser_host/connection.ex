defmodule FermixChannels.BrowserHost.Connection do
  @moduledoc """
  The Fermix app's browser host on `browser_host.sock`: the one connection the
  daemon drives the app's browser pane over.

  The endpoint starts it and hands it the accepted socket; from then on this
  process owns the socket, so the fd closes the instant it exits, however it
  exits, and its exit is what every pane task bound to it (`HostServer`) and
  the availability it reported (`HostAvailability`) watch. It reads
  newline-delimited JSON through `FermixCore.BrowserHost.Protocol`.

  ## The wire

  The app says `client_hello`, is answered `server_hello`, then says
  `attached`; only then is it the host (`HostAvailability.attached/3`). From
  there the daemon asks and the app answers: a pane task's request
  (`FermixCore.BrowserHost.Link`) is written with the next `id` of this
  connection, and the answer carrying that id goes back to the task that asked.
  Requests from every task share this one process, so they reach the socket in
  the order each task sent them: one FIFO toward the app, and the app's answers
  and events are read in the order it wrote them, the other.

  ## Tasks and their release

  A task is known here from its first request. Its `task.release` is written
  at most once: when the task says it is over, when its process exits without
  saying so, when the app quits, or when the person cancels it from the app's
  pane (`task.cancel`, told and released exactly like the others). A release
  travels behind the task's own requests, because they leave the same process
  in order.

  ## The app quitting

  `host_stopping` is handled in one callback: every task still bound here has
  its `task.release` written and is told the app is quitting, availability is
  marked stopping (final for this connection, so no later report reopens the
  pane, and the app is not opened on demand again until it attaches by itself),
  and the quit is answered with `host.stop_ack`, behind the releases. The app
  holds its quit for that answer, and ends the hold on its own bound when the
  answer is lost.

  ## Who is on the other end

  When the socket is handed over, before any line is read, the connection
  places the process that connected (`FermixCore.SocketPeer`). The host must
  be a process the daemon did not start: one the agent spawned could answer
  pages of its own making. Anything but an independent process is refused with
  one `error` (`untrusted_host`) and closed.

  A protocol violation is answered with one `error` and closes the connection,
  which fails every task bound to it.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Browser.HostAvailability
  alias FermixCore.BrowserHost.Link
  alias FermixCore.BrowserHost.Protocol
  alias FermixCore.SocketPeer
  alias FermixCore.Trace

  @handover_timeout_ms 5_000
  # Requests the app has not answered yet; past it a request is refused here
  # rather than queued behind an app that stopped answering.
  @max_pending 256
  @max_error_message 500
  @forwarded_events ~w(tab.closed dialog.opened download.began download.progress download.finished)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

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
      tasks: %{},
      pids: %{},
      daemon_os_pid: Keyword.get(opts, :daemon_os_pid, String.to_integer(System.pid())),
      os: Keyword.get(opts, :os, :os.type())
    }

    {:ok, state, @handover_timeout_ms}
  end

  @impl true
  def handle_info(:socket_handover, state) do
    case SocketPeer.classify(state.socket, state.daemon_os_pid, state.os) do
      {:ok, :independent} -> arm(state)
      {:ok, caller} -> refuse_peer("a process placed as #{caller}", state)
      {:error, :peer_closed} -> {:stop, :normal, state}
      {:error, reason} -> refuse_peer(inspect(reason), state)
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
    Logger.debug("browser host connection read error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:browser_host_request, pid, ref, task_id, type, payload}, state),
    do: continue(task_request(pid, ref, task_id, type, payload, state))

  def handle_info({:browser_host_release, _pid, task_id}, state),
    do: continue(release_task(task_id, state))

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{pids: pids} = state)
      when :erlang.map_get(pid, pids) == ref,
      do: continue(task_exited(pid, state))

  def handle_info(message, state) do
    Logger.debug("browser host connection ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.attached, do: trace("browser_host_detached", %{"connection" => state.connection_id})
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
    Logger.warning("browser host connection refusing a host the daemon did not trust: #{cause}")
    message = "the browser host must be a process the daemon did not start: #{cause}"
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
  defp dispatch({:event, "availability", payload}, state), do: availability(payload, state)
  defp dispatch({:event, "host_stopping", _payload}, state), do: host_stopping(state)
  defp dispatch({:event, "task.cancel", payload}, state), do: cancel_task(payload, state)
  defp dispatch({:event, type, payload}, state), do: forward(type, payload, state)
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

  # From here the app is the host: its connection is what a pane task binds to.
  defp attach(payload, state) do
    :ok = HostAvailability.attached(state.host_availability, self(), state.connection_id)

    trace("browser_host_attached", %{
      "connection" => state.connection_id,
      "host_version" => payload["host_version"],
      "profile_id" => payload["profile_id"]
    })

    {:cont, %{state | attached: true}}
  end

  # A report after `host_stopping` changes nothing: `HostAvailability` holds
  # stopping as final for this connection.
  defp availability(payload, state) do
    :ok =
      HostAvailability.report(state.host_availability, payload["available"], payload["reason"])

    trace("browser_host_availability", %{
      "connection" => state.connection_id,
      "available" => payload["available"],
      "reason" => payload["reason"]
    })

    {:cont, state}
  end

  # One callback: every task bound here is released and told, availability is
  # marked stopping, and the quit is answered behind the releases.
  defp host_stopping(%{stopping: true} = state), do: {:cont, state}

  defp host_stopping(state) do
    trace("browser_host_stopping", %{"connection" => state.connection_id})

    state =
      Enum.reduce(state.tasks, state, fn {task_id, pid}, state ->
        :ok = Link.stopping(pid, self())
        release_task(task_id, state) |> elem(1)
      end)

    :ok = HostAvailability.stopping(state.host_availability, self())
    pending = Map.filter(state.pending, fn {_id, request} -> is_nil(request.ref) end)
    write_request("host.stop_ack", %{}, nil, %{state | stopping: true, pending: pending})
  end

  # The app's news about a tab goes to every task bound here; each keeps what
  # concerns its own tabs.
  defp forward(type, payload, state) when type in @forwarded_events do
    Enum.each(Map.keys(state.pids), &Link.event(&1, self(), type, payload))
    {:cont, state}
  end

  # An answer whose request is not waiting (a late one, after its task stopped
  # waiting) is dropped.
  defp answered(id, outcome, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.debug("browser host connection dropped an answer to request #{id}")
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
        Logger.error("browser host answered #{type} off the protocol: #{inspect(reason)}")
        {:error, %{"reason" => "invalid_result", "message" => bounded_inspect(reason)}}
    end
  end

  defp checked(_type, {:error, error}), do: {:error, error}

  defp deliver(%{ref: nil, type: type}, {:error, error}),
    do: Logger.warning("browser host refused #{type}: #{inspect(error)}")

  defp deliver(%{ref: nil}, {:ok, _result}), do: :ok
  defp deliver(%{task: pid, ref: ref}, answer), do: Link.answer(pid, ref, answer)

  # ── requests from pane tasks ───────────────────────────────────────────────

  defp task_request(pid, ref, _task_id, _type, _payload, %{stopping: true} = state) do
    Link.answer(pid, ref, {:error, unavailable("the app is quitting")})
    {:cont, state}
  end

  defp task_request(pid, ref, _task_id, _type, _payload, state)
       when map_size(state.pending) >= @max_pending do
    Link.answer(pid, ref, {:error, unavailable("the app is not answering")})
    {:cont, state}
  end

  defp task_request(pid, ref, task_id, type, payload, state) do
    state = bind_task(task_id, pid, state)
    write_request(type, payload, %{task: pid, ref: ref, type: type}, state)
  end

  defp bind_task(task_id, pid, state) do
    pids =
      if Map.has_key?(state.pids, pid),
        do: state.pids,
        else: Map.put(state.pids, pid, Process.monitor(pid))

    %{state | tasks: Map.put(state.tasks, task_id, pid), pids: pids}
  end

  # Released at most once: a released task is forgotten here, so its second
  # release finds nothing. A task that never sent a request has nothing on the
  # app to release.
  defp release_task(task_id, state) do
    case Map.pop(state.tasks, task_id) do
      {nil, _tasks} ->
        {:cont, state}

      {_pid, tasks} ->
        state = %{state | tasks: tasks}
        write_request("task.release", %{"task_id" => task_id}, nil, state)
    end
  end

  # The person cancelled one task from the app: it is told, then released
  # exactly as `release_task/2` releases a task that ends on its own. A
  # task_id this connection never bound (already gone, or never made a
  # request) has nothing to cancel.
  defp cancel_task(%{"task_id" => task_id, "reason" => reason}, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, pid} ->
        :ok = Link.cancelled(pid, self(), reason)

        trace("browser_host_task_cancelled", %{
          "connection" => state.connection_id,
          "task_id" => task_id,
          "reason" => reason
        })

        release_task(task_id, state)

      :error ->
        {:cont, state}
    end
  end

  # A task whose process ended without releasing itself is released for it.
  defp task_exited(pid, state) do
    {released, kept} = Map.split_with(state.tasks, fn {_task_id, owner} -> owner == pid end)
    state = %{state | tasks: kept, pids: Map.delete(state.pids, pid)}

    Enum.reduce_while(released, {:cont, state}, fn {task_id, _pid}, {:cont, state} ->
      case write_request("task.release", %{"task_id" => task_id}, nil, state) do
        {:cont, state} -> {:cont, {:cont, state}}
        stop -> {:halt, stop}
      end
    end)
  end

  # The one writer of requests: the next id of this connection, the frame, and
  # who waits for its answer (`nil` for the daemon's own).
  defp write_request(type, payload, waiter, state) do
    id = state.next_id

    case Protocol.encode_request(id, type, payload) do
      {:ok, line} ->
        sent(
          :gen_tcp.send(state.socket, line),
          id,
          waiter || %{task: nil, ref: nil, type: type},
          state
        )

      {:error, reason} ->
        Logger.error("browser host connection could not encode #{type}: #{inspect(reason)}")
        refuse_encoding(waiter, reason)
        {:cont, state}
    end
  end

  defp sent(:ok, id, request, state),
    do: {:cont, %{state | next_id: id + 1, pending: Map.put(state.pending, id, request)}}

  defp sent({:error, _reason}, _id, _request, state), do: {:stop, state}

  defp refuse_encoding(nil, _reason), do: :ok

  defp refuse_encoding(%{task: pid, ref: ref}, reason),
    do:
      Link.answer(
        pid,
        ref,
        {:error, %{"reason" => "invalid_request", "message" => bounded_inspect(reason)}}
      )

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
    Trace.record(:agent_event, "browser_host", Map.put(data, "event", event))
  end
end
