defmodule FermixCore.Cues.Source.Stream.Socket do
  @moduledoc """
  The WebSocket transport of `Cues.Source.Stream` (M60 §3.6), on Mint.WebSocket:
  deliberately dumb. It carries frames and pongs to its owner and reads no
  message. Slack's Socket Mode client (`FermixChannels.Channels.Slack.SocketMode`)
  is its second owner, and the one that writes text frames once connected
  (`send_text/2`, its envelope acknowledgements).

  `start/3` refuses a URL with no host, and a route the outbound proxy would
  have to carry (`Net.Egress.ensure_direct/2`: this socket cannot tunnel, so it
  never dials around the proxy). Otherwise it returns at once with a process
  nobody is linked to and a monitor on it, taken in the caller's process (the
  owner) by `spawn_monitor/1`, so the owner sees every exit, even one that comes
  at once. Everything else happens in that process, bounded as a whole by
  `:handshake_timeout`: `Net.Guard` checks the `wss://` address under the
  feed's public-web policy (a refused address exits `:address_refused`), the
  connection goes to the first address it validated while the URL's host name
  is kept for SNI, the certificate check against the OS trust store (`Net.Tls`)
  and `Host`, the upgrade carries `:headers`, and once it is accepted
  `:messages` are written in order, before the owner hears `:connected`. An
  answer other than 101 exits `{:upgrade_refused, status}`: no redirect is
  followed. A write the peer does not take within 10 seconds closes the
  connection.

  Once connected the socket is read with `active: :once`. Each frame header is
  read before its payload is decoded, so the socket knows what Mint would hold
  for a frame or a fragmented message that is not whole yet: the payloads its
  data frames announced so far. Past `:max_frame_bytes` it closes (1009) and
  exits `:frame_too_large` before the frame is whole. A control frame, which
  may come between fragments, counts on its own against RFC 6455's 125 bytes
  and leaves the message alone; a longer one breaks the protocol. At most 64
  frames are forwarded ahead of the owner's `ack/1`: Mint runs in passive mode,
  so nothing re-arms the socket but this module, which stops reading at the
  window and queues what one read decoded past it. A fast service then fills
  its TCP window instead of the owner's mailbox. A stall at the window is not
  an error here and has no timer; the owner's stall rule covers liveness. When
  the peer ends the connection, the frames still queued reach the owner before
  the exit does. A server ping is answered with a pong. Once connected the
  socket monitors its owner and closes when the owner is gone.

  A plain process rather than a GenServer: its exit reason is the API (the
  list is in `Cues.Source.Stream.Transport`), and a GenServer would write an
  error report, with its state, for every one of them. The upgrade headers
  and the messages carry credentials: they live only in the handshake, in a
  struct whose inspection leaves them out, and never reach a log line, the
  connected state or an exit reason.

  Messages to the owner: `{:cue_stream, socket, :connected}`,
  `{:cue_stream, socket, {:frame, {:text | :binary, payload}}}` and
  `{:cue_stream, socket, :pong}`.
  """

  @behaviour FermixCore.Cues.Source.Stream.Transport

  require Logger

  alias FermixCore.Net.Egress
  alias FermixCore.Net.Guard
  alias FermixCore.Net.Tls

  defmodule Handshake do
    @moduledoc false
    # What the handshake needs. Inspecting it (a log line, an exception's
    # blame) leaves out the headers and messages, which carry credentials.
    @derive {Inspect, except: [:headers, :messages]}
    @enforce_keys [
      :url,
      :host,
      :port,
      :path,
      :guard,
      :tls,
      :headers,
      :messages,
      :timeout,
      :max_frame_bytes
    ]
    defstruct @enforce_keys
  end

  # Frames forwarded to the owner and not yet acknowledged.
  @window 64
  # How long a close waits for the peer's close frame.
  @close_wait_ms 2_000
  # Reads of the upgrade reply before it counts as one that never ends.
  @max_upgrade_reads 32
  # A write the peer does not take within this closes the connection.
  @send_timeout_ms 10_000
  # RFC 6455 §5.5: a control frame's payload is at most 125 bytes.
  @max_control_bytes 125
  # Between frames, with no fragmented message held.
  @fresh_meter %{at: {:header, <<>>}, message: 0}

  @doc """
  Options beyond the contract's, each for a test only: `:cacerts` (the trust
  store `Net.Tls` verifies against in place of the OS store), `:resolver` (the
  lookup `Net.Guard` makes) and `:guard` (replaces the address check, by
  default `Net.Guard.resolve_and_validate/2` with `schemes: ["wss"]`, so that a
  test can reach its own loopback server). Production passes none of them.
  """
  @impl FermixCore.Cues.Source.Stream.Transport
  def start(url, owner, opts) when is_binary(url) and is_pid(owner) and is_list(opts) do
    egress = Keyword.get_lazy(opts, :egress, &Egress.active/0)

    with {:ok, uri} <- target(url),
         :ok <- Egress.ensure_direct(url, egress) do
      plan = plan(url, uri, opts)
      {pid, ref} = spawn_monitor(fn -> run(plan, owner) end)
      {:ok, pid, ref}
    end
  end

  @impl FermixCore.Cues.Source.Stream.Transport
  def ack(socket) when is_pid(socket), do: tell(socket, :ack)

  @impl FermixCore.Cues.Source.Stream.Transport
  def ping(socket) when is_pid(socket), do: tell(socket, :ping)

  @impl FermixCore.Cues.Source.Stream.Transport
  def close(socket) when is_pid(socket), do: tell(socket, :close)

  @doc """
  Writes one text frame to the peer, in order with every other write. Not part
  of the stream contract: a cue stream sends nothing once connected. Dropped
  once the socket is closing; a write that fails ends the connection.
  """
  @spec send_text(pid(), String.t()) :: :ok
  def send_text(socket, text) when is_pid(socket) and is_binary(text),
    do: tell(socket, {:text, text})

  defp tell(socket, request) do
    send(socket, {__MODULE__, request})
    :ok
  end

  # --- start -------------------------------------------------------------------------

  defp target(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} = uri when is_binary(host) and host != "" -> {:ok, uri}
      %URI{scheme: "wss"} -> {:error, :url_without_host}
      %URI{} -> raise ArgumentError, "a cue stream dials wss:// only"
    end
  end

  defp plan(url, %URI{host: host, port: port} = uri, opts) do
    timeout = Keyword.fetch!(opts, :handshake_timeout)
    max_frame_bytes = Keyword.fetch!(opts, :max_frame_bytes)
    headers = Keyword.get(opts, :headers, [])
    messages = Keyword.get(opts, :messages, [])
    resolver = Keyword.get(opts, :resolver)
    true = is_integer(timeout) and timeout > 0
    true = is_integer(max_frame_bytes) and max_frame_bytes > 0

    true =
      Enum.all?(headers, &match?({name, value} when is_binary(name) and is_binary(value), &1))

    true = Enum.all?(messages, &is_binary/1)

    guard = &Guard.resolve_and_validate(&1, schemes: ["wss"], resolver: resolver)

    %Handshake{
      url: url,
      host: host,
      port: port,
      path: request_path(uri),
      guard: Keyword.get(opts, :guard, guard),
      tls: Tls.client_options(host, Keyword.take(opts, [:cacerts])),
      headers: headers,
      messages: messages,
      timeout: timeout,
      max_frame_bytes: max_frame_bytes
    }
  end

  defp request_path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  # --- the handshake -----------------------------------------------------------------

  defp run(%Handshake{} = plan, owner) do
    case handshake(plan) do
      {:ok, opened} -> enter(opened, plan.max_frame_bytes, owner)
      {:error, reason} -> exit(reason)
    end
  end

  # The whole handshake runs in a task so that one bound covers the lookup, the
  # dial, TLS and the upgrade: a step that hangs is killed with the task, and
  # the connection it was making closes with its owner.
  defp handshake(plan) do
    socket = self()
    task = Task.async(fn -> open(plan, socket) end)

    case Task.yield(task, plan.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:connect_failed, :timeout}}
    end
  end

  defp open(plan, socket) do
    with {:ok, peer} <- peer(plan),
         {:ok, conn} <- dial(plan, peer) do
      conn |> upgrade(plan) |> write_messages(plan.messages) |> hand_over(socket)
    end
  end

  # The address the guard validated, which the connection is pinned to; an IP
  # literal the guard found public is its own address.
  defp peer(plan) do
    case plan.guard.(plan.url) do
      {:ok, ip} ->
        {:ok, ip}

      :ok ->
        {:ok, ip} = :inet.parse_address(String.to_charlist(plan.host))
        {:ok, ip}

      {:error, {:dns_resolution_failed, _reason} = failure} ->
        {:error, {:connect_failed, failure}}

      {:error, {kind, _detail} = refusal}
      when kind in [:blocked_host, :resolved_to_private_address] ->
        Logger.debug("Cue stream socket: #{plan.host} refused: #{inspect(refusal)}")
        {:error, :address_refused}

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  # The dial goes to `peer`; `hostname:` is what SNI, the certificate check and
  # `Host` carry.
  defp dial(plan, peer) do
    opts = [
      hostname: plan.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts:
        plan.tls ++
          [timeout: plan.timeout, send_timeout: @send_timeout_ms, send_timeout_close: true] ++
          family(peer)
    ]

    case Mint.HTTP.connect(:https, peer, plan.port, opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, error} -> {:error, {:connect_failed, cause(error)}}
    end
  end

  defp family({_a, _b, _c, _d}), do: []
  defp family({_a, _b, _c, _d, _e, _f, _g, _h}), do: [inet6: true, inet4: false]

  # The headers are written here, and nothing after this reads them.
  defp upgrade(conn, plan) do
    case Mint.WebSocket.upgrade(:wss, conn, plan.path, plan.headers) do
      {:ok, conn, ref} ->
        reply = %{status: nil, headers: nil, data: []}
        await_upgrade(conn, ref, plan.timeout, reply, @max_upgrade_reads)

      {:error, conn, error} ->
        {:error, conn, {:connect_failed, cause(error)}}
    end
  end

  defp await_upgrade(conn, _ref, _timeout, _reply, 0),
    do: {:error, conn, {:connect_failed, :upgrade_reply_too_long}}

  defp await_upgrade(conn, ref, timeout, reply, reads_left) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        reply = Enum.reduce(responses, reply, &collect(&1, &2, ref))
        upgraded(conn, ref, timeout, reply, reads_left - 1)

      {:error, conn, error, _responses} ->
        {:error, conn, {:connect_failed, cause(error)}}
    end
  end

  defp collect({:status, ref, status}, reply, ref), do: %{reply | status: status}
  defp collect({:headers, ref, headers}, reply, ref), do: %{reply | headers: headers}
  defp collect({:data, ref, data}, reply, ref), do: %{reply | data: [reply.data, data]}
  defp collect(_done, reply, _ref), do: reply

  # The status line and headers decide; a refusal's body is never read. Bytes
  # after a 101 are the first frames.
  defp upgraded(conn, ref, timeout, %{headers: nil} = reply, reads_left),
    do: await_upgrade(conn, ref, timeout, reply, reads_left)

  defp upgraded(conn, _ref, _timeout, %{status: status}, _reads_left) when status != 101,
    do: {:error, conn, {:upgrade_refused, status}}

  defp upgraded(conn, ref, _timeout, reply, _reads_left) do
    case Mint.WebSocket.new(conn, ref, 101, reply.headers, mode: :passive) do
      {:ok, conn, websocket} ->
        {:ok, conn, %{ref: ref, websocket: websocket, first: IO.iodata_to_binary(reply.data)}}

      {:error, conn, reason} ->
        {:error, conn, {:connect_failed, cause(reason)}}
    end
  end

  # The messages, written in order as soon as the upgrade is accepted; nothing
  # after this reads them. A write that fails is the connection ending under
  # it, as the peer's.
  defp write_messages({:ok, conn, opened}, [text | rest]) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(opened.websocket, {:text, text}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, opened.ref, data) do
      write_messages({:ok, conn, %{opened | websocket: websocket}}, rest)
    else
      {:error, _websocket_or_conn, reason} ->
        Logger.debug("Cue stream socket: a message was not written: #{inspect(cause(reason))}")
        {:error, conn, {:remote_closed, nil}}
    end
  end

  defp write_messages(upgraded_or_failed, _messages_left), do: upgraded_or_failed

  defp hand_over({:ok, conn, opened}, socket) do
    case Mint.HTTP.controlling_process(conn, socket) do
      {:ok, conn} ->
        {:ok, Map.put(opened, :conn, conn)}

      {:error, error} ->
        {:ok, _closed} = Mint.HTTP.close(conn)
        {:error, {:connect_failed, cause(error)}}
    end
  end

  defp hand_over({:error, conn, reason}, _socket) do
    {:ok, _closed} = Mint.HTTP.close(conn)
    {:error, reason}
  end

  # A header value Mint refuses is named by its header only: the value is a
  # credential.
  defp cause(%Mint.TransportError{reason: reason}), do: reason

  defp cause(%Mint.HTTPError{reason: {:invalid_header_value, name, _value}}),
    do: {:invalid_header_value, name}

  defp cause(%Mint.HTTPError{reason: reason}), do: reason
  defp cause(reason), do: reason

  # --- connected ---------------------------------------------------------------------

  defp enter(opened, max_frame_bytes, owner) do
    send(owner, {:cue_stream, self(), :connected})

    state = %{
      owner: owner,
      owner_ref: Process.monitor(owner),
      conn: opened.conn,
      ref: opened.ref,
      websocket: opened.websocket,
      socket: Mint.HTTP.get_socket(opened.conn),
      max_frame_bytes: max_frame_bytes,
      meter: @fresh_meter,
      pending: :queue.new(),
      in_flight: 0,
      armed?: false,
      phase: :open
    }

    state |> on_data(opened.first) |> continue()
  end

  defp continue({:cont, state}), do: loop(state)

  defp continue({:stop, reason, state}) do
    hand_on_queued(state, reason)
    {:ok, _closed} = Mint.HTTP.close(state.conn)
    exit(reason)
  end

  # Frames queued past the window still reach the owner, ahead of the exit,
  # when the connection ends under them. Past the cap they are dropped with the
  # read the owner records as a gap.
  defp hand_on_queued(_state, :frame_too_large), do: :ok

  defp hand_on_queued(state, _reason) do
    for frame <- :queue.to_list(state.pending),
        do: send(state.owner, {:cue_stream, self(), {:frame, frame}})

    :ok
  end

  defp loop(state) do
    receive do
      message -> message |> handle(state) |> continue()
    end
  end

  defp handle({:ssl, socket, data}, %{socket: socket} = state),
    do: on_data(%{state | armed?: false}, data)

  defp handle({:ssl_closed, socket}, %{socket: socket} = state),
    do: {:stop, ending(state, {:remote_closed, nil}), state}

  defp handle({:ssl_error, socket, reason}, %{socket: socket} = state),
    do: transport_ended(state, reason)

  defp handle({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: begin_close(state)

  defp handle({__MODULE__, :ack}, state), do: on_ack(state)
  defp handle({__MODULE__, :close}, state), do: begin_close(state)
  defp handle({__MODULE__, _request}, %{phase: :closing} = state), do: {:cont, state}
  defp handle({__MODULE__, :ping}, state), do: send_frame(state, {:ping, ""})
  defp handle({__MODULE__, {:text, text}}, state), do: send_frame(state, {:text, text})
  defp handle(:close_wait_over, %{phase: :closing} = state), do: {:stop, :normal, state}
  defp handle(_other, state), do: {:cont, state}

  # Once closing, the owner asked for the end, and every way it comes is the
  # `:normal` the owner was promised.
  defp ending(%{phase: :closing}, _reason), do: :normal
  defp ending(_state, reason), do: reason

  defp on_ack(%{in_flight: 0} = state) do
    Logger.warning("Cue stream socket: an acknowledgement with no frame outstanding")
    {:cont, state}
  end

  defp on_ack(state), do: %{state | in_flight: state.in_flight - 1} |> forward() |> rearm()

  # --- reading -----------------------------------------------------------------------

  defp on_data(state, data) do
    case measure(state.meter, data, state.max_frame_bytes) do
      {:ok, meter} -> decode(%{state | meter: meter}, data)
      :too_large -> refuse(state, 1009, :frame_too_large)
      {:broken, reason} -> broken(state, reason)
    end
  end

  defp decode(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> take(frames, {:cont, %{state | websocket: websocket}})
      {:error, websocket, reason} -> broken(%{state | websocket: websocket}, reason)
    end
  end

  defp take([frame | rest], {:cont, state}), do: take(rest, on_frame(frame, state))
  defp take([], {:cont, state}), do: state |> forward() |> rearm()
  defp take(_frames, stop), do: stop

  defp on_frame({kind, payload}, %{phase: :open} = state) when kind in [:text, :binary],
    do: {:cont, %{state | pending: :queue.in({kind, payload}, state.pending)}}

  defp on_frame({kind, _payload}, state) when kind in [:text, :binary], do: {:cont, state}
  defp on_frame({:ping, payload}, state), do: send_frame(state, {:pong, payload})

  defp on_frame({:pong, _payload}, %{phase: :open} = state) do
    send(state.owner, {:cue_stream, self(), :pong})
    {:cont, state}
  end

  defp on_frame({:pong, _payload}, state), do: {:cont, state}

  defp on_frame({:close, code, _reason}, %{phase: :open} = state) do
    courtesy_close(state, code)
    {:stop, {:remote_closed, code}, state}
  end

  defp on_frame({:close, _code, _reason}, state), do: {:stop, :normal, state}
  defp on_frame({:error, reason}, state), do: broken(state, reason)

  # The window: at most @window frames run ahead of the owner's acks.
  defp forward(%{in_flight: in_flight} = state) when in_flight >= @window, do: state

  defp forward(state) do
    case :queue.out(state.pending) do
      {{:value, frame}, pending} ->
        send(state.owner, {:cue_stream, self(), {:frame, frame}})
        forward(%{state | pending: pending, in_flight: state.in_flight + 1})

      {:empty, _pending} ->
        state
    end
  end

  # Only this reads the socket again. `forward/1` runs first, so a frame still
  # queued means the window is full and the socket stays unread; a closing
  # socket reads on, for the peer's close frame.
  defp rearm(%{armed?: false, phase: :closing} = state), do: arm(state)

  defp rearm(%{armed?: false, in_flight: in_flight} = state) when in_flight < @window,
    do: arm(state)

  defp rearm(state), do: {:cont, state}

  defp arm(state) do
    case :ssl.setopts(state.socket, active: :once) do
      :ok -> {:cont, %{state | armed?: true}}
      {:error, reason} -> transport_ended(state, reason)
    end
  end

  # --- the frame meter ---------------------------------------------------------------
  #
  # It walks the bytes before Mint decodes them, so it knows each frame's
  # announced length as soon as the frame's header is in. `at` is a header
  # still arriving (its bytes so far) or a payload with `left` bytes to come;
  # `message` is what a fragmented data message holds so far. Each step
  # consumes a header or a payload, so the walk ends with the bytes.

  defp measure(meter, <<>>, _max), do: {:ok, meter}

  defp measure(%{at: {:payload, left}} = meter, data, _max) when byte_size(data) < left,
    do: {:ok, %{meter | at: {:payload, left - byte_size(data)}}}

  defp measure(%{at: {:payload, left}} = meter, data, max) do
    <<_payload::binary-size(left), rest::binary>> = data
    measure(%{meter | at: {:header, <<>>}}, rest, max)
  end

  defp measure(%{at: {:header, held}} = meter, data, max) do
    bytes = held <> data

    with {:ok, header, rest} <- frame_header(bytes),
         {:ok, meter} <- admit(meter, header, max) do
      measure(%{meter | at: {:payload, header.length}}, rest, max)
    else
      :partial -> {:ok, %{meter | at: {:header, bytes}}}
      refused -> refused
    end
  end

  defp frame_header(<<fin::1, _rsv::3, opcode::4, masked::1, length::7, rest::binary>>) do
    with {:ok, length, rest} <- payload_length(length, rest),
         {:ok, rest} <- skip_mask(masked, rest) do
      {:ok, %{fin?: fin == 1, opcode: opcode, length: length}, rest}
    end
  end

  defp frame_header(_short), do: :partial

  defp payload_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(length, rest) when length < 126, do: {:ok, length, rest}
  defp payload_length(_length, _short), do: :partial

  defp skip_mask(0, rest), do: {:ok, rest}
  defp skip_mask(1, <<_key::binary-size(4), rest::binary>>), do: {:ok, rest}
  defp skip_mask(1, _short), do: :partial

  # A control frame (opcode 8 and up) may come between a message's fragments:
  # it counts on its own, against RFC 6455's limit rather than the cap, and
  # leaves the message alone. A continuation (opcode 0) adds to the message; a
  # text or binary frame starts one; a final frame ends it.
  defp admit(meter, %{opcode: opcode, length: length}, _max) when opcode >= 8 do
    if length > @max_control_bytes, do: {:broken, :control_frame_too_long}, else: {:ok, meter}
  end

  defp admit(meter, %{opcode: opcode, length: length, fin?: fin?}, max) do
    held = if opcode == 0, do: meter.message + length, else: length

    cond do
      held > max -> :too_large
      fin? -> {:ok, %{meter | message: 0}}
      true -> {:ok, %{meter | message: held}}
    end
  end

  # --- writing and closing -----------------------------------------------------------

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:cont, %{state | websocket: websocket, conn: conn}}
    else
      {:error, _websocket_or_conn, reason} -> transport_ended(state, cause(reason))
    end
  end

  defp begin_close(%{phase: :closing} = state), do: {:cont, state}

  defp begin_close(state) do
    case send_frame(state, {:close, 1000, ""}) do
      {:cont, state} ->
        Process.send_after(self(), :close_wait_over, @close_wait_ms)
        rearm(%{state | phase: :closing, pending: :queue.new()})

      {:stop, _reason, state} ->
        {:stop, :normal, state}
    end
  end

  # The peer broke the protocol: the connection ends as if the peer had closed
  # it, and only the kind of break is logged, never the bytes.
  defp broken(state, reason) do
    Logger.warning(
      "Cue stream socket: the service broke the WebSocket protocol (#{kind(reason)})"
    )

    refuse(state, 1002, {:remote_closed, nil})
  end

  defp refuse(state, code, reason) do
    courtesy_close(state, code)
    {:stop, ending(state, reason), state}
  end

  # A close frame on a connection that ends either way: a failure to send it
  # changes nothing, and is still said.
  defp courtesy_close(state, code) do
    case send_frame(state, {:close, code, ""}) do
      {:cont, _state} -> :ok
      {:stop, _reason, _state} -> Logger.debug("Cue stream socket: the close frame was not sent")
    end
  end

  defp transport_ended(state, reason) do
    Logger.debug("Cue stream socket: the connection ended: #{inspect(reason)}")
    {:stop, ending(state, {:remote_closed, nil}), state}
  end

  defp kind(reason) when is_atom(reason), do: inspect(reason)

  defp kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: inspect(elem(reason, 0))

  defp kind(_reason), do: "unrecognised"
end
