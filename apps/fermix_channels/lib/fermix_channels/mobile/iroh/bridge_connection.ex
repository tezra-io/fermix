defmodule FermixChannels.Mobile.Iroh.BridgeConnection do
  @moduledoc """
  The iroh carrier of a phone's session: one bridge connection, which
  `fermix-iroh` opened for one iroh stream (M62 §3, stage 4).

  The `Companion.Connection` shape: `Iroh.Bridge` starts it and hands it the
  accepted socket, and from then on this process owns the socket. It reads the
  helper's 37-byte preamble (5 s), then the iroh carrier's frames
  (`Iroh.Carrier`, with `{:packet, 4}` and a `packet_size` bound that refuses an
  oversized frame before it is allocated), and drives `Mobile.Session` exactly
  as the WebSocket carrier does, holding the session's carrier contract:

  - the peer is `{:iroh, endpoint_id}`, the endpoint id the preamble names: for
    pairing-failure accounting only, never authorization;
  - the session's idle bound closes a connection nothing was read from, with
    `1002`, and the session's `terminate/2` sees `:timeout`;
  - the carrier's memory bound before `hello` is the session's, and the session
    raises it once a paired phone says `hello`;
  - frames go out in order before the next read; a `:stop` sends its frames,
    then a close frame, then closes the socket;
  - a stream the phone ended without a close frame ends the session with
    `:remote`, as a WebSocket the phone closed does;
  - a shutdown (the rail switched off, the daemon stopping) sends the close
    `1000` the protocol names for it, then runs the session's `terminate/2`
    with the shutdown's reason; the process traps exits for it.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Mobile.Iroh.Carrier
  alias FermixChannels.Mobile.Iroh.HelperProtocol
  alias FermixChannels.Mobile.Session

  @handover_timeout_ms 5_000
  @preamble_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    _previous = Process.flag(:max_heap_size, Session.unauthenticated_heap_cap())
    Process.flag(:trap_exit, true)

    state = %{
      socket: Keyword.fetch!(opts, :socket),
      session_opts: Map.new(Keyword.get(opts, :session_opts, [])),
      session: nil,
      idle_ms: Keyword.get(opts, :idle_timeout_ms, Session.idle_timeout_ms()),
      preamble_ms: Keyword.get(opts, :preamble_timeout_ms, @preamble_timeout_ms),
      idle: nil
    }

    {:ok, state, @handover_timeout_ms}
  end

  @impl true
  # The bridge died between starting this process and handing it the socket.
  def handle_info(:timeout, %{session: nil} = state),
    do: {:stop, {:shutdown, :handover_timeout}, state}

  def handle_info(:socket_handover, state) do
    with {:ok, preamble} <-
           :gen_tcp.recv(state.socket, HelperProtocol.preamble_bytes(), state.preamble_ms),
         {:ok, :phone, endpoint_id} <- HelperProtocol.decode_preamble(preamble),
         :ok <- frame_socket(state.socket) do
      start_session(endpoint_id, state)
    else
      {:error, reason} ->
        Logger.warning("bridge connection refused: #{inspect(reason)}")
        _ = :gen_tcp.close(state.socket)
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp, socket, frame}, %{socket: socket, session: session} = state)
      when not is_nil(session) do
    state = arm_idle(state)

    case Carrier.decode(frame) do
      {:message, payload} ->
        payload |> Session.handle_frame(session) |> carry(state)

      {:close, _code, _reason} ->
        finish(:remote, close_socket(state))

      {:error, reason} ->
        stop_session({:error, reason}, {1002, "mobile protocol error"}, [], session, state)
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket, session: session} = state)
      when not is_nil(session),
      do: finish(:remote, state)

  def handle_info({:tcp_error, socket, reason}, %{socket: socket, session: session} = state)
      when not is_nil(session),
      do: finish({:error, reason}, close_socket(state))

  def handle_info({:bridge_idle, token}, %{idle: {_timer, token}, session: session} = state),
    do: stop_session(:timeout, {1002, "no inbound frame"}, [], session, state)

  # The socket is linked to its owner; its exit says nothing `:tcp_closed` or a
  # failed send does not.
  def handle_info({:EXIT, socket, _reason}, %{socket: socket} = state),
    do: {:noreply, state}

  def handle_info(message, %{session: session} = state) when not is_nil(session),
    do: message |> Session.handle_info(session) |> carry(state)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  # Every other ending already ran the session's terminate and cleared it.
  def terminate(_reason, %{session: nil}), do: :ok

  def terminate(reason, state) do
    _ = :gen_tcp.send(state.socket, Carrier.close(1000, "daemon shutting down"))
    _ = :gen_tcp.close(state.socket)
    Session.terminate(reason, state.session)
  end

  defp frame_socket(socket) do
    :inet.setopts(socket, [
      {:packet, 4},
      {:packet_size, Carrier.max_frame_bytes()},
      {:active, :once}
    ])
  end

  defp start_session(endpoint_id, state) do
    opts = Map.put(state.session_opts, :peer, {:iroh, endpoint_id})

    case Session.init(opts) do
      {:ok, session} ->
        {:noreply, arm_idle(%{state | session: session})}

      {:stop, reason, failed} ->
        _ = Session.terminate(reason, failed)
        _ = :gen_tcp.close(state.socket)
        {:stop, :normal, state}
    end
  end

  # -- the session's results ----------------------------------------------------

  defp carry({:ok, session}, state), do: read_on(%{state | session: session})

  defp carry({:push, frames, session}, state) do
    case send_frames(frames, state) do
      :ok -> read_on(%{state | session: session})
      {:error, reason} -> finish({:error, reason}, close_socket(%{state | session: session}))
    end
  end

  defp carry({:stop, reason, close, session}, state),
    do: stop_session(reason, close, [], session, state)

  defp carry({:stop, reason, close, frames, session}, state),
    do: stop_session(reason, close, frames, session, state)

  defp stop_session(reason, {code, text}, frames, session, state) do
    state = %{state | session: session}
    _ = send_frames(frames, state)
    _ = :gen_tcp.send(state.socket, Carrier.close(code, text))
    finish(reason, close_socket(state))
  end

  defp finish(reason, state) do
    :ok = Session.terminate(reason, state.session)
    {:stop, :normal, %{state | session: nil}}
  end

  defp send_frames(frames, state) do
    Enum.reduce_while(frames, :ok, fn frame, :ok ->
      case :gen_tcp.send(state.socket, Carrier.message(frame)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_on(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> finish({:error, reason}, close_socket(state))
    end
  end

  defp close_socket(state) do
    _ = :gen_tcp.close(state.socket)
    state
  end

  # Every inbound frame restarts the idle bound; a stale timer's token no
  # longer matches.
  defp arm_idle(state) do
    case state.idle do
      {timer, _token} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    token = make_ref()
    %{state | idle: {Process.send_after(self(), {:bridge_idle, token}, state.idle_ms), token}}
  end
end
