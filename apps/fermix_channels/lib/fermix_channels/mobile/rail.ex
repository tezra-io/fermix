defmodule FermixChannels.Mobile.Rail do
  @moduledoc """
  The one initiator-side session client of the mobile wire (M75 §4.2): how an
  engine reaches another engine over the iroh rail, as a phone reaches the
  daemon. The desktop relay, the move worker and a candidate's enrollment all
  go through it.

  `open/3` dials the route's `node_id` through `Iroh.Helper.dial/3` (the
  helper's protocol 3), writes the prelude and runs the Noise handshake for the
  mode as initiator, and returns a session process that carries the mobile
  wire exactly as a phone does (`fermix_core/priv/mobile/PROTOCOL.md`):

  - iroh stream frames (`Iroh.Carrier`: type `1` one Noise message, type `2` a
    close), read with `{:packet, 4}` and the carrier's frame bound;
  - Noise transport, with each direction's REKEY after exactly 2^20 frames;
  - the plaintext frame codec of `Mobile.Protocol` (`encode_client_frame/5`,
    `decode_server_frame/1`, `decode_server_event/3`), the same rules the
    responder holds each side to;
  - client `seq` from 1, and every server frame's `seq` exactly one past the
    last, at the session's `v`;
  - a server `event_part` run reassembled into the event it carries;
  - `ping` every 60 s once the owner has sent its first event (the responder
    takes nothing before `hello`, or a mode's own first event), a session with
    no inbound frame for 150 s closed `1002`, and the session closed `1000`
    after one hour, as the responder would close it, except a desktop's
    (`:ik`), which is meant to stay up and has no lifetime on either side:
    the 2^20-frame rekey still bounds every key. A move's (`:ik_move`) has
    none either: it carries a whole home, which a slow uplink may need more
    than an hour for, and its responder, the candidate, closes it on no clock.

  It does not reassemble M75's chunked payloads (`index`/`last`): that is
  `Mobile.Chunks`, which consumers run on the events they get.

  ## The owner

  The process that calls `open/3` owns the session and is linked to it. It
  gets each decoded server event as `{:rail, rail, {:event, header, tail}}`,
  where `header` is the event's JSON header (`v`, `t`, `seq` and its fields)
  and `tail` its raw bytes, and every ending it did not ask for as
  `{:rail, rail, {:closed, reason}}`. The session then exits `:normal`, so the
  link carries only a crash (an owner that traps exits also sees that
  `{:EXIT, rail, :normal}`). An owner that exits takes the session down with a
  close `1000`.

  ## Modes

  | Mode | Prelude | Keys |
  |---|---|---|
  | `:ik` | `FXM1 0x01` | `static_keypair` (a desktop's), `remote_static` (the primary's gateway key) |
  | `:ikpsk2_enroll` | `FXM1 0x03` | `static_keypair` (the candidate's), `remote_static` (the code's `gateway_pk`), `psk` (the code's secret) |
  | `:ik_move` | `FXM1 0x04` | `static_keypair` (the source's gateway key), `remote_static` (the candidate's key) |

  A test connects to a Unix socket of its own instead of dialing (`:connect`),
  and injects the timers (`:schedule`, `:cancel_timer`).
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Mobile.Iroh.Carrier
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol

  @modes [:ik, :ikpsk2_enroll, :ik_move]
  # The responder's handshake deadline is 10 s from the stream's start; its
  # reply to the first message comes well inside it.
  @handshake_timeout_ms 10_000
  @ping_interval_ms 60_000
  @idle_timeout_ms 150_000
  @session_lifetime_ms 3_600_000
  @rekey_after_frames 1_048_576
  # The dial (`Iroh.Helper.dial/3` waits 25 s at most) and the handshake, with
  # room to spare: past it the opener stops waiting and kills the session.
  @open_timeout_ms 40_000
  # A frame the far end does not take within this ends the session; a send
  # waits for it, and no longer.
  @send_timeout_ms 30_000
  @send_call_timeout_ms @send_timeout_ms + 5_000
  @max_event_parts div(
                     Protocol.max_event_bytes() + Protocol.max_raw_chunk_bytes() - 1,
                     Protocol.max_raw_chunk_bytes()
                   )

  @typedoc """
  Where to dial: a route as `hello_ack`'s `iroh` candidate names one (relays as
  the wire carries them). `addrs` (direct `ip:port` addresses) only in a test
  that knows where the peer listens.
  """
  @type route :: %{
          required(:node_id) => String.t(),
          required(:relays) => [map()],
          required(:relays_rev) => String.t(),
          optional(:addrs) => [String.t()]
        }

  @type mode :: :ik | :ikpsk2_enroll | :ik_move

  @typedoc "Why a session ended without the owner asking."
  @type closed_reason ::
          {:remote, 0..65_535, String.t()}
          | :remote_ended
          | :idle
          | :lifetime
          | {:protocol_error, term()}
          | {:socket, term()}

  @doc """
  Dials `route`, runs the handshake for `mode`, and returns the session once it
  is complete. Bounded: the dial and the handshake together take at most 40 s.

  Options: `:static_keypair` and `:remote_static` (always), `:psk` (only and
  always for `:ikpsk2_enroll`), `:helper` (the `Iroh.Helper` to dial through),
  or the test seams `:connect` (a function the session calls to get a
  connected, passive, binary socket instead of dialing), `:schedule` and
  `:cancel_timer`.
  """
  @spec open(route(), mode(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(%{node_id: node_id, relays: [_ | _], relays_rev: rev} = route, mode, opts)
      when is_binary(node_id) and is_binary(rev) and mode in @modes and is_list(opts) do
    with :ok <- valid_node_id(node_id),
         :ok <- valid_keys(mode, opts),
         :ok <- valid_connect(opts) do
      {:ok, rail} = GenServer.start_link(__MODULE__, {route, mode, opts, self()})
      await_open(rail)
    end
  end

  @doc """
  Sends one client event: `type`, its fields and its raw tail, at the session's
  next `seq`. A frame the codec refuses is refused here and costs no `seq`.
  Returns once the frame is written; a far end that takes nothing for 30 s
  ends the session, and this answers `{:error, :timeout}`.
  """
  @spec send_event(pid(), String.t(), map(), binary()) :: :ok | {:error, term()}
  def send_event(rail, type, payload, bytes \\ <<>>)
      when is_pid(rail) and is_binary(type) and is_map(payload) and is_binary(bytes),
      do: GenServer.call(rail, {:send, type, payload, bytes}, @send_call_timeout_ms)

  @doc "Ends the session with a close `1000`; the owner gets no `:closed` for it."
  @spec close(pid()) :: :ok
  def close(rail) when is_pid(rail), do: GenServer.call(rail, :close)

  defp valid_node_id(node_id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, node_id), do: :ok, else: {:error, :invalid_node_id}
  end

  defp valid_keys(mode, opts) do
    keypair = Keyword.get(opts, :static_keypair)
    remote = Keyword.get(opts, :remote_static)
    psk = Keyword.get(opts, :psk)

    cond do
      not match?(%{private: <<_::256>>, public: <<_::256>>}, keypair) ->
        {:error, :invalid_static_keypair}

      not match?(<<_::256>>, remote) ->
        {:error, :invalid_remote_static}

      mode == :ikpsk2_enroll and not match?(<<_::256>>, psk) ->
        {:error, :invalid_psk}

      mode != :ikpsk2_enroll and not is_nil(psk) ->
        {:error, :psk_not_allowed}

      true ->
        :ok
    end
  end

  defp valid_connect(opts) do
    cond do
      is_function(Keyword.get(opts, :connect), 0) -> :ok
      Keyword.has_key?(opts, :helper) -> :ok
      true -> {:error, :no_helper}
    end
  end

  # The session says how its opening went, then exits `:normal` on a failure,
  # so the link never takes the opener down for one.
  defp await_open(rail) do
    monitor = Process.monitor(rail)

    receive do
      {:rail_opened, ^rail, result} ->
        Process.demonitor(monitor, [:flush])
        if result == :ok, do: {:ok, rail}, else: result

      {:DOWN, ^monitor, :process, ^rail, reason} ->
        {:error, {:rail_down, reason}}
    after
      @open_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        Process.unlink(rail)
        Process.exit(rail, :kill)

        receive do
          {:rail_opened, ^rail, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :open_timeout}
    end
  end

  # -- the session process -----------------------------------------------------

  @impl true
  def init({route, mode, opts, owner}) do
    # So the owner's exit, however it exits, runs `terminate/2` and its close.
    Process.flag(:trap_exit, true)

    state = %{
      owner: owner,
      route: route,
      mode: mode,
      opts: opts,
      socket: nil,
      noise: nil,
      version: Protocol.protocol_version(),
      client_seq: 0,
      server_seq: 0,
      parts: nil,
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      cancel_timer: Keyword.get(opts, :cancel_timer, &Process.cancel_timer/1),
      timers: %{idle: nil, ping: nil, lifetime: nil}
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    case connect_and_handshake(state) do
      {:ok, state} ->
        send(state.owner, {:rail_opened, self(), :ok})
        {:noreply, state |> arm(:idle, @idle_timeout_ms) |> arm_lifetime()}

      {:error, reason} ->
        send(state.owner, {:rail_opened, self(), {:error, reason}})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:send, type, payload, bytes}, _from, state) do
    case send_frame(type, payload, bytes, state) do
      {:ok, state} -> {:reply, :ok, ping_after_first_send(state)}
      {:refused, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> end_session({:socket, reason}, state, {:reply, {:error, reason}})
    end
  end

  def handle_call(:close, _from, state) do
    :ok = send_close(state, 1000, "session closed")
    _ = close_socket(state)
    {:stop, :normal, :ok, %{state | socket: nil}}
  end

  @impl true
  def handle_info({:tcp, socket, frame}, %{socket: socket} = state) do
    state = arm(state, :idle, @idle_timeout_ms)

    case Carrier.decode(frame) do
      {:message, ciphertext} -> receive_message(ciphertext, state)
      {:close, code, reason} -> end_session({:remote, code, reason}, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: end_session(:remote_ended, %{state | socket: nil})

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: end_session({:socket, reason}, state)

  def handle_info({:rail_timer, kind, token}, state) do
    case state.timers do
      %{^kind => {_ref, ^token}} ->
        timer_fired(kind, %{state | timers: Map.put(state.timers, kind, nil)})

      _stale ->
        {:noreply, state}
    end
  end

  # The socket is linked to its owner, and the helper's word that the dialed
  # stream ended arrives after the socket says so: neither adds anything.
  def handle_info(_message, state), do: {:noreply, state}

  # The owner is the session's parent: its exit, whatever its reason, stops the
  # session here (`gen_server` handles a parent's exit itself). Every other
  # ending already closed the socket.
  @impl true
  def terminate(_reason, state) do
    :ok = send_close(state, 1000, "session closed")
    _ = close_socket(state)
    :ok
  end

  # A desktop's session stays up as long as both ends do; every other mode is
  # closed after an hour, as its responder would close it.
  defp arm_lifetime(%{mode: :ik} = state), do: state
  defp arm_lifetime(%{mode: :ik_move} = state), do: state
  defp arm_lifetime(state), do: arm(state, :lifetime, @session_lifetime_ms)

  # -- opening -------------------------------------------------------------------

  # A socket whose handshake fails is closed here; only a session that opened
  # keeps it.
  defp connect_and_handshake(state) do
    with {:ok, socket} <- connect(state) do
      case handshake(socket, state) do
        {:ok, noise} ->
          {:ok, %{state | socket: socket, noise: noise}}

        {:error, reason} ->
          _ = :gen_tcp.close(socket)
          {:error, reason}
      end
    end
  end

  defp handshake(socket, state) do
    with :ok <- frame_socket(socket),
         {:ok, noise} <- initiator(state),
         {:ok, first, noise} <- Noise.write_handshake(noise, <<>>),
         :ok <- :gen_tcp.send(socket, Carrier.message(first)),
         {:ok, noise} <- read_reply(socket, noise),
         :ok <- :inet.setopts(socket, active: :once) do
      {:ok, noise}
    end
  end

  defp connect(%{opts: opts, route: route}) do
    case Keyword.fetch(opts, :connect) do
      {:ok, connect} -> connect.()
      :error -> dial(Keyword.fetch!(opts, :helper), route)
    end
  end

  defp dial(helper, route) do
    target = Map.take(route, [:node_id, :relays, :addrs])

    case Helper.dial(helper, target) do
      {:ok, socket, _path} -> {:ok, socket}
      {:error, reason} -> {:error, {:dial, reason}}
    end
  end

  defp frame_socket(socket) do
    :inet.setopts(socket, [
      :binary,
      {:packet, 4},
      {:packet_size, Carrier.max_frame_bytes()},
      {:send_timeout, @send_timeout_ms},
      {:send_timeout_close, true},
      {:active, false}
    ])
  end

  defp initiator(%{mode: mode, opts: opts}) do
    keys = [static_keypair: opts[:static_keypair], remote_static: opts[:remote_static]]
    keys = if mode == :ikpsk2_enroll, do: keys ++ [psk: opts[:psk]], else: keys
    Noise.initialize(:initiator, mode, keys)
  end

  defp read_reply(socket, noise) do
    with {:ok, frame} <- :gen_tcp.recv(socket, 0, @handshake_timeout_ms) do
      case Carrier.decode(frame) do
        {:message, reply} -> handshake_reply(noise, reply)
        {:close, code, reason} -> {:error, {:remote, code, reason}}
        {:error, reason} -> {:error, {:protocol_error, reason}}
      end
    end
  end

  defp handshake_reply(noise, reply) do
    case Noise.read_handshake(noise, reply) do
      {:ok, <<>>, noise} -> {:ok, noise}
      {:ok, _payload, _noise} -> {:error, {:protocol_error, :handshake_payload}}
      {:error, reason} -> {:error, {:handshake, reason}}
    end
  end

  # -- sending -------------------------------------------------------------------

  defp send_frame(type, payload, bytes, state) do
    seq = state.client_seq + 1

    case Protocol.encode_client_frame(type, payload, seq, bytes, version: state.version) do
      {:ok, plaintext} -> seal_and_send(plaintext, %{state | client_seq: seq})
      {:error, reason} -> {:refused, reason}
    end
  end

  defp seal_and_send(plaintext, state) do
    with {:ok, noise} <- rekey_due(state.noise, :send),
         {:ok, ciphertext, noise} <- Noise.encrypt(noise, plaintext),
         :ok <- :gen_tcp.send(state.socket, Carrier.message(ciphertext)) do
      {:ok, %{state | noise: noise}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Each direction rekeys once it has carried exactly 2^20 frames under its
  # key, as the responder does: the same frame count on both sides.
  defp rekey_due(noise, direction) do
    count = if direction == :send, do: noise.send_frames, else: noise.receive_frames
    if count >= @rekey_after_frames, do: Noise.rekey(noise, direction), else: {:ok, noise}
  end

  defp ping_after_first_send(%{timers: %{ping: nil}} = state),
    do: arm(state, :ping, @ping_interval_ms)

  defp ping_after_first_send(state), do: state

  # -- receiving -----------------------------------------------------------------

  defp receive_message(ciphertext, state) do
    with {:ok, noise} <- rekey_due(state.noise, :receive),
         {:ok, plaintext, noise} <- Noise.decrypt(noise, ciphertext),
         {:ok, event} <- Protocol.decode_server_frame(plaintext),
         :ok <- in_sequence(event, state) do
      take_event(event, %{state | noise: noise, server_seq: event.seq})
    else
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp in_sequence(%{version: version, seq: seq}, state) do
    cond do
      version != state.version -> {:error, {:version, version}}
      seq != state.server_seq + 1 -> {:error, {:seq, seq, state.server_seq + 1}}
      true -> :ok
    end
  end

  defp take_event(%{type: "event_part"} = part, state) do
    case add_part(part, state.parts) do
      {:more, parts} -> read_on(%{state | parts: parts})
      {:done, event} -> deliver(event, %{state | parts: nil})
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp take_event(_event, %{parts: %{}} = state),
    do: protocol_error(:event_inside_event_part_run, state)

  defp take_event(event, state), do: deliver(event, state)

  # A run starts at index 0 with its count, goes on in order with the same
  # count, and ends at its last index; its size is bounded as one event is.
  defp add_part(%{payload: %{"index" => 0, "count" => count}} = part, nil)
       when count in 2..@max_event_parts,
       do:
         {:more,
          %{count: count, next: 1, first: part, tails: [part.bytes], size: byte_size(part.bytes)}}

  defp add_part(
         %{payload: %{"index" => index, "count" => count}} = part,
         %{next: index, count: count} = parts
       ) do
    size = parts.size + byte_size(part.bytes)
    tails = [parts.tails, part.bytes]

    cond do
      size > Protocol.max_event_bytes() -> {:error, :event_part_run_too_large}
      index + 1 < count -> {:more, %{parts | next: index + 1, tails: tails, size: size}}
      true -> logical_event(tails, parts.first)
    end
  end

  defp add_part(_part, _parts), do: {:error, :event_part_out_of_order}

  defp logical_event(tails, first) do
    json = IO.iodata_to_binary(tails)

    case Protocol.decode_server_event(json, first.version, first.seq) do
      {:ok, event} -> {:done, event}
      {:error, reason} -> {:error, {:event_part_run, reason}}
    end
  end

  defp deliver(event, state) do
    header =
      Map.merge(event.payload, %{"v" => event.version, "t" => event.type, "seq" => event.seq})

    send(state.owner, {:rail, self(), {:event, header, event.bytes}})
    read_on(state)
  end

  defp read_on(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> end_session({:socket, reason}, state)
    end
  end

  # -- timers and endings --------------------------------------------------------

  defp arm(state, kind, delay_ms) do
    case state.timers[kind] do
      {ref, _token} -> state.cancel_timer.(ref)
      nil -> :ok
    end

    token = make_ref()
    ref = state.schedule.({:rail_timer, kind, token}, delay_ms)
    %{state | timers: Map.put(state.timers, kind, {ref, token})}
  end

  defp timer_fired(:ping, state) do
    case send_frame("ping", %{}, <<>>, state) do
      {:ok, state} -> {:noreply, arm(state, :ping, @ping_interval_ms)}
      {:refused, reason} -> protocol_error({:ping, reason}, state)
      {:error, reason, state} -> end_session({:socket, reason}, state)
    end
  end

  defp timer_fired(:idle, state),
    do: close_with(:idle, {1002, "no inbound frame"}, state)

  defp timer_fired(:lifetime, state),
    do: close_with(:lifetime, {1000, "Noise session lifetime reached"}, state)

  defp protocol_error(reason, state) do
    Logger.warning(
      "rail session to #{short(state.route.node_id)} refused a frame: #{inspect(reason)}"
    )

    close_with({:protocol_error, reason}, {1002, "mobile protocol error"}, state)
  end

  defp close_with(reason, {code, text}, state) do
    :ok = send_close(state, code, text)
    end_session(reason, state)
  end

  # A close frame is the last word on a socket that may already be gone.
  defp send_close(%{socket: nil}, _code, _text), do: :ok

  defp send_close(%{socket: socket}, code, text) do
    _ = :gen_tcp.send(socket, Carrier.close(code, text))
    :ok
  end

  defp end_session(reason, state, reply \\ nil) do
    _ = close_socket(state)
    send(state.owner, {:rail, self(), {:closed, reason}})
    state = %{state | socket: nil}

    case reply do
      nil -> {:stop, :normal, state}
      {:reply, answer} -> {:stop, :normal, answer, state}
    end
  end

  defp close_socket(%{socket: nil}), do: :ok
  defp close_socket(%{socket: socket}), do: :gen_tcp.close(socket)

  defp short(node_id), do: binary_part(node_id, 0, 12)
end
