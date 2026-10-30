defmodule FermixChannels.Mobile.Session do
  @moduledoc """
  One phone's session, whatever carries it: the Noise prelude and handshake,
  `hello` or pairing, then the ready socket's events, its timers, its requests
  and its media.

  The clear five-byte prelude selects one Noise mode exactly once. The complete
  first wire is then passed to `Mobile.Noise`, which binds that prelude into the
  transcript. Paired sockets are registered only after the authenticated static
  key and the encrypted `hello.device_id` agree.

  ## The carrier's side of the contract

  This is a callback module, not a process. It runs inside the process that owns
  the carrier: `Mobile.SocketHandler`, the WebSocket carrier Bandit runs. That
  process:

  - calls `init/1` once the carrier is established, with a required `:peer`
    (`t:peer/0`) naming where the connection came from. The peer keys
    pairing-failure accounting and never authorizes anything;
  - hands `handle_frame/2` one whole Noise message at a time. Message boundaries
    are the carrier's; the carrier refuses an oversized message before reading it
    where it can, and the session refuses one past 65,535 bytes either way;
  - hands every mailbox message it does not claim for the carrier itself to
    `handle_info/2`, after its own carrier messages: the device registry, the
    pair manager, the request worker and the session's own timers all message
    this process;
  - sends the frames of `{:push, frames, state}` in order before it reads again,
    which is the session's back-pressure;
  - closes with the `t:close/0` a `:stop` names, after sending its frames;
  - calls `terminate/2` once as it closes, also after `init/1` itself stopped,
    passing the reason of the session's `:stop` unchanged, `:timeout` when it
    closed an idle carrier, or `:made_room` when it closed one not yet
    `past_handshake?/1` to make room for another, with the handshake deadline's
    close.

  The carrier also sets its own process's memory bound before `hello`; the
  session raises it to `:authenticated_max_heap_size` once a paired phone says
  `hello`.

  ## Phones and desktops

  A paired session's kind is its device row's (M75 §3): a `phone`, or a
  `desktop` engine. `Mobile.Peers` is the one table of what each kind may
  send; a known event its kind may not send is answered
  `error{code:"unsupported_event"}` and the session stays open, and a server
  event its kind may not be sent is dropped as an event it cannot encode is.
  A desktop's session starts its `Desktop.Peer` once `hello` is answered and
  hands it every desktop-family event; it gets no approval cards, and phone
  broadcasts never reach it.

  A phone can open a pairing window and decide on the phone waiting in one
  (D16): `pair_start` is `mobile.pair.start`'s path and answers `pair_window`
  with the link, which is never logged or kept; `pair_decide` is
  `mobile.pair.decide`'s. The pair manager tells every phone of a request
  waiting (`pair_pending`) and of how it ended (`pair_decided`), and a phone
  that says `hello` while one waits hears it again after its `hello_ack`.
  """

  require Logger

  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Desktop.Peer, as: DesktopPeer
  alias FermixChannels.Home.EnrollmentResponder
  alias FermixChannels.Mobile.Attestation
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Companion.Timeline

  @max_wire_bytes 65_535
  # The modes a phone or a desktop dials in, and M75's own preludes with the
  # responder serving each (`begin_handshake/2`); a carrier's options replace
  # either (a candidate serves the move alone).
  @phone_modes [:ik, :ikpsk2]
  @responders %{ikpsk2_enroll: {EnrollmentResponder, []}}
  # The upgrade or bridge connection comes before the prelude picks paired or
  # pairing mode, so one idle bound covers both. It must outlive the
  # owner-approval window, or the carrier closes a pairing socket while the
  # owner is still deciding.
  @idle_grace_ms 30_000
  # A connection that has not said `hello` needs only a handshake's memory; one
  # that outgrows it is killed instead of the VM.
  @unauthenticated_heap_bytes 4 * 1_024 * 1_024
  # A paired device's connection carries media: a fetched blob with its frames
  # and their ciphertext, and fan-out events queued in its mailbox.
  @authenticated_heap_floor_bytes 64 * 1_024 * 1_024
  @default_max_media_bytes 20 * 1_024 * 1_024
  @rekey_after_frames 1_048_576
  @session_lifetime_ms 3_600_000
  @handshake_deadline_ms 10_000
  @handshake_deadline_close {1008, "mobile handshake deadline"}
  # The phases a peer passes through before it is a paired device or a phone
  # waiting for the owner; the handshake deadline bounds all of them.
  @deadline_phases [:prelude, :await_hello, :await_pair_request]
  @profile_id "main"
  @queued_events ~w(msg command)
  @max_pending_requests 32
  @max_media_fetch_queue 8
  @max_candidates 16
  # The rail's candidate comes last, after this many host candidates, so the
  # list stays within `@max_candidates`.
  @max_host_candidates_with_iroh 15
  # The refusals a phone can act on keep their own word as `error.code`; every
  # other failure is only the daemon's to explain, and is `request_failed`.
  @typed_refusals ~w(
    store_quota_exceeded media_too_large sha256_mismatch announced_hash_mismatch
    size_mismatch size_exceeded unexpected_chunk invalid_field missing_field
    attachment_unavailable unsupported_event push_environment_mismatch
  )a

  @type state :: map()

  @typedoc """
  How the carrier closes: a close code and its reason text, the same pair a
  WebSocket close frame carries. `1000` the session's lifetime ran out, `1002` a
  protocol error or a stale primary, `1008` the handshake deadline, `1009` a
  message over 65,535 bytes, `1011` a desktop's peer failed or did not start,
  `4001` replaced by a newer connection, `4003` revoked (live, or a key with
  no row at the handshake), refused pairing or a mismatched device.
  """
  @type close :: {1000 | 1002 | 1008 | 1009 | 1011 | 4001 | 4003, String.t()}

  @typedoc "Where a connection came from, for pairing-failure accounting only."
  @type peer :: PairManager.source()

  @typedoc "What the carrier does next."
  @type result ::
          {:ok, state()}
          | {:push, [binary()], state()}
          | {:stop, term(), close(), state()}
          | {:stop, term(), close(), [binary()], state()}

  @doc """
  The most candidates a phone is given, best first: `hello_ack`'s,
  `pair_approved`'s and the pairing link's.
  """
  @spec max_candidates() :: pos_integer()
  def max_candidates, do: @max_candidates

  @doc """
  The refusals whose own word is `error.code`, besides every atom reason's
  own; any other failure is `request_failed`.
  """
  @spec typed_refusals() :: [String.t()]
  def typed_refusals, do: Enum.map(@typed_refusals, &Atom.to_string/1)

  @doc """
  How long every carrier keeps a connection nothing was read from: past the
  longest owner-approval window, so a pairing never times out under the owner.
  """
  @spec idle_timeout_ms() :: pos_integer()
  def idle_timeout_ms, do: PairManager.max_ttl_ms() + @idle_grace_ms

  @doc """
  Whether the peer is past its handshake: its IK handshake proved a paired
  phone's key (`authenticated_device`, which an approved pairing phone also
  holds), or its pairing request waits for the owner. Until then the connection
  may be a stranger's, held for as long as the handshake deadline lets it:
  IKpsk2's first message proves no pairing secret, so a peer awaiting its
  `pair_request` has shown only that it knows the gateway key, which every
  pairing QR shows.

  A replayed IK first message gets past too, until its deadline, but capturing
  one takes breaking the transport's encryption (iroh's QUIC TLS, the
  WebSocket's TLS) or an endpoint, not a stranger's stream.
  """
  @spec past_handshake?(state()) :: boolean()
  def past_handshake?(%{phase: :delegated, delegate: {module, delegated}}),
    do: module.past_handshake?(delegated)

  def past_handshake?(%{phase: :await_pair_decision}), do: true
  def past_handshake?(%{authenticated_device: device}), do: not is_nil(device)

  @doc """
  The close of a connection the handshake deadline ends, which a carrier short
  of room also gives a connection not yet `past_handshake?/1`.
  """
  @spec handshake_deadline_close() :: close()
  def handshake_deadline_close, do: @handshake_deadline_close

  @doc "The carrier process's memory bound before the phone has said `hello`."
  @spec unauthenticated_heap_cap() :: map()
  def unauthenticated_heap_cap, do: heap_cap(@unauthenticated_heap_bytes)

  @doc """
  The memory bound the session raises the carrier process to once a paired phone
  has said `hello`: room for one fetched blob, its frames and their ciphertext.
  """
  @spec authenticated_heap_cap(pos_integer()) :: map()
  def authenticated_heap_cap(max_media_bytes)
      when is_integer(max_media_bytes) and max_media_bytes > 0,
      do: heap_cap(@authenticated_heap_floor_bytes + 4 * max_media_bytes)

  defp heap_cap(bytes) do
    %{
      size: div(bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: true,
      include_shared_binaries: true
    }
  end

  @doc """
  Starts a session on an established carrier. `opts` must name the connection's
  `:peer`: an IP address for a WebSocket.
  """
  @spec init(keyword() | %{required(:peer) => peer(), optional(atom()) => term()}) ::
          {:ok, state()} | {:stop, {:invalid_profile_name, term()}, map()}
  def init(opts) when is_list(opts), do: init(Map.new(opts))

  def init(%{peer: peer} = opts) when not is_nil(peer) do
    case profile_name(opts) do
      {:ok, profile_name} -> {:ok, opts |> build_state(profile_name) |> arm_handshake_deadline()}
      {:error, reason} -> {:stop, reason, opts}
    end
  end

  def init(opts) when is_map(opts) do
    raise ArgumentError,
          "a mobile session needs its carrier's :peer, got #{inspect(Map.get(opts, :peer))}"
  end

  defp build_state(opts, profile_name) do
    opts
    |> normalize_identity_loader()
    |> Map.put(:profile_name, profile_name)
    |> Map.put_new(:phase, :prelude)
    |> Map.put_new(:device_store, DeviceStore)
    |> Map.put_new(:device_registry, DeviceRegistry)
    |> Map.put_new(:pair_manager, PairManager)
    |> Map.put_new(:request_coordinator, RequestCoordinator)
    |> Map.put_new(:identity_root, nil)
    |> Map.put_new(:primary_epoch, nil)
    |> Map.put_new(:media_store, MediaStore)
    |> Map.put_new(:discovery, Discovery)
    |> Map.put_new(:max_media_bytes, @default_max_media_bytes)
    |> Map.put_new(:push_environment, nil)
    |> Map.put_new(:push_services, [])
    |> Map.put_new(:profile_id, @profile_id)
    |> Map.put_new(:device_id, nil)
    |> Map.put_new(:authenticated_device, nil)
    |> Map.put_new(:peer_kind, :phone)
    |> Map.put_new(:client_seq, 0)
    |> Map.put_new(:server_seq, 0)
    |> Map.put_new(:negotiated_version, nil)
    |> Map.put_new(:uploads, MapSet.new())
    |> Map.put_new(:pending_requests, [])
    |> Map.put_new(:request_ref, nil)
    |> Map.put_new(:request_client_msg_id, nil)
    |> Map.put_new(:media_transfer, nil)
    |> Map.put_new(:media_queue, [])
    |> Map.put_new(:session_started_ms, nil)
    |> Map.put_new(:session_timer_ref, nil)
    |> Map.put_new(:session_timer_token, nil)
    |> Map.put_new(:handshake_deadline_ref, nil)
    |> Map.put_new(:handshake_deadline_token, nil)
    |> Map.put_new(:pair_failure_recorded?, false)
    |> Map.put_new(:listener, Listener)
    |> Map.put_new(:pairing_opts, [])
    |> Map.put_new(:desktop_peers, FermixChannels.Desktop.Peers)
    |> Map.put_new(:desktop_peer_supervisor, FermixChannels.Desktop.PeerSupervisor)
    |> Map.put_new(:desktop_peer, nil)
    |> Map.put_new(:desktop_peer_ref, nil)
    |> Map.put_new(:clock, clock(opts))
    |> Map.put_new(:wall_clock, &DateTime.utc_now/0)
    |> put_default_dependencies()
  end

  @doc "Takes one whole Noise message from the carrier."
  @spec handle_frame(binary(), state()) :: result()
  def handle_frame(payload, state) when byte_size(payload) > @max_wire_bytes do
    {:stop, :frame_too_large, {1009, "mobile frame too large"}, state}
  end

  def handle_frame(wire, %{phase: :delegated, delegate: {module, delegated}} = state)
      when is_binary(wire),
      do: wrap_delegated(module, module.handle_frame(wire, delegated), state)

  def handle_frame(wire, %{phase: :prelude} = state) when is_binary(wire) do
    begin_handshake(wire, state)
  end

  def handle_frame(ciphertext, %{phase: :await_hello} = state) when is_binary(ciphertext) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_hello(ciphertext, state)
    end
  end

  def handle_frame(ciphertext, %{phase: :await_pair_request} = state)
      when is_binary(ciphertext) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_pair_request(ciphertext, state)
    end
  end

  def handle_frame(ciphertext, %{phase: :await_pair_decision} = state)
      when is_binary(ciphertext) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_pending_decision(ciphertext, state)
    end
  end

  def handle_frame(ciphertext, %{phase: :ready} = state) when is_binary(ciphertext) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_ready_event(ciphertext, state)
    end
  end

  def handle_frame(ciphertext, state) when is_binary(ciphertext) do
    protocol_error(:invalid_connection_state, state)
  end

  @doc "Takes one mailbox message the carrier did not claim for itself."
  @spec handle_info(term(), state()) :: result()
  def handle_info(message, %{phase: :delegated, delegate: {module, delegated}} = state),
    do: wrap_delegated(module, module.handle_info(message, delegated), state)

  def handle_info({:mobile_replaced, _new_pid}, state) do
    {:stop, :replaced, {4001, "connection replaced"}, state}
  end

  def handle_info({:mobile_revoked, _device_id}, state) do
    {:stop, :revoked, {4003, "device revoked"}, state}
  end

  def handle_info({:mobile_event, event}, %{phase: :ready} = state) when is_map(event) do
    if session_expired?(state) do
      session_expired(state)
    else
      push_fanout_event(event, state)
    end
  end

  def handle_info(:mobile_media_step, %{phase: :ready} = state) do
    if session_expired?(state) do
      session_expired(state)
    else
      media_step(state)
    end
  end

  def handle_info(
        {:mobile_handshake_deadline, token},
        %{handshake_deadline_token: token, phase: phase} = state
      )
      when is_reference(token) and phase in @deadline_phases do
    handshake_deadline(state)
  end

  def handle_info({:mobile_pair_decision, session_id, result}, state) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_pair_decision(session_id, result, state)
    end
  end

  def handle_info({:mobile_session_expired, token}, state) do
    if Map.get(state, :session_timer_token) == token,
      do: session_expired(state),
      else: {:ok, state}
  end

  def handle_info({:DOWN, ref, :process, _peer, reason}, %{desktop_peer_ref: ref} = state)
      when is_reference(ref),
      do: desktop_peer_failed({:desktop_peer_down, reason}, state)

  def handle_info({:DOWN, ref, :process, _worker, reason}, %{request_ref: ref} = state) do
    client_msg_id = state.request_client_msg_id

    case start_next_request(%{state | request_ref: nil, request_client_msg_id: nil}) do
      {:ok, next} -> finished_request_reply(reason, client_msg_id, next)
      {:error, start_reason, failed_state} -> protocol_error(start_reason, failed_state)
    end
  end

  # A process streaming to this session (the desktop snapshot target) waits
  # for what it handed over to be written before it hands over more. The
  # carrier pushes each event's frames before it reads its next message, so by
  # the time this one is read every frame handed over before it is written.
  def handle_info({:mobile_sync, from, ref}, state) when is_pid(from) and is_reference(ref) do
    send(from, {:mobile_synced, ref})
    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @doc "Releases the session's resources; the carrier calls it once, as it closes."
  @spec terminate(term(), state()) :: :ok
  def terminate(reason, %{phase: :delegated, delegate: {module, delegated}}),
    do: module.terminate(reason, delegated)

  def terminate(reason, state) do
    cancel_session_timer(state)
    detach_socket(state)
    cancel_uploads(state)
    close_media_transfer(state)
    record_abandoned_pair(reason, state)
    close_unauthenticated_iroh_peer(state)
  end

  defp put_default_dependencies(state) do
    discovery = state.discovery
    iroh_helper = Map.get(state, :iroh_helper, Helper)

    state
    |> Map.put_new(:noise_initialize, &Noise.initialize/3)
    |> Map.put_new(:noise_read, &Noise.read_handshake/2)
    |> Map.put_new(:noise_write, &Noise.write_handshake/2)
    |> Map.put_new(:noise_remote_static, &Noise.remote_static/1)
    |> Map.put_new(:noise_sas, &Noise.sas/1)
    |> Map.put_new(:noise_rekey, &Noise.rekey/2)
    |> Map.put_new(:decrypt, &Noise.decrypt/2)
    |> Map.put_new(:encrypt, &Noise.encrypt/2)
    |> Map.put_new(:decode_client, &Protocol.decode_client_frame/2)
    |> Map.put_new(:encode_server, fn type, payload, seq, bytes, version ->
      Protocol.encode_server_event(type, payload, seq, bytes, version: version)
    end)
    |> Map.put_new(:find_device, &DeviceStore.find_by_noise_pk/2)
    |> Map.put_new(:update_device, &DeviceStore.update/3)
    |> Map.put_new(:current_pair, &PairManager.current/2)
    |> Map.put_new(:verify_pair, &verify_pair/3)
    |> Map.put_new(:refuse_pair, &PairManager.refuse/3)
    |> Map.put_new(:submit_pair, &PairManager.submit_request/3)
    |> Map.put_new(:record_pair_failure, &PairManager.record_failure/3)
    |> Map.put_new(:attach_socket, &DeviceRegistry.attach/4)
    |> Map.put_new(:send_device_event, &DeviceRegistry.send_device_event/3)
    |> Map.put_new(:authorize_socket, &DeviceRegistry.authorized?/3)
    |> Map.put_new(:discover, fn -> Discovery.candidates(discovery) end)
    |> Map.put_new(:iroh_candidate, fn -> Helper.candidate(iroh_helper) end)
    |> Map.put_new(:relay_list_acknowledged, fn -> Helper.relays_acknowledged(iroh_helper) end)
    |> Map.put_new(:close_iroh_peer, &Helper.close(iroh_helper, &1))
    |> Map.put_new(:pending_approvals, &Approvals.pending(Approvals.server(), &1, :mobile))
    |> Map.put_new(:media_descriptor, &Timeline.media_descriptor/2)
    |> Map.put_new(:event_router, &EventRouter.route/3)
    |> Map.put_new(:run_request, &Task.Supervisor.start_child(FermixCore.TaskSupervisor, &1))
    |> put_peer_dependencies(iroh_helper)
  end

  # A desktop's peer, and a phone's pairing (D16) and device verbs, which run
  # the management facade's own path with this session's processes.
  defp put_peer_dependencies(state, iroh_helper) do
    supervisor = state.desktop_peer_supervisor
    pair_manager = state.pair_manager

    pairing =
      Keyword.merge(
        [
          pair_manager: pair_manager,
          listener: state.listener,
          discovery: state.discovery,
          iroh_helper: iroh_helper,
          device_store: state.device_store
        ],
        state.pairing_opts
      )

    state
    |> Map.put_new(:start_desktop_peer, &DesktopPeer.start(supervisor, &1))
    |> Map.put_new(:deliver_desktop_event, &DesktopPeer.deliver/2)
    |> Map.put_new(:pair_start, fn -> Management.pair_start(pairing) end)
    |> Map.put_new(:pair_decide, &Management.pair_decide(&1, &2, pairing))
    |> Map.put_new(:pairing_pending, fn -> PairManager.pending_event(pair_manager) end)
    |> Map.put_new(:devices_list, fn -> Management.devices_list(pairing) end)
    |> Map.put_new(
      :device_revoke,
      &Management.devices_revoke(
        &1,
        Keyword.put(pairing, :device_registry, state.device_registry)
      )
    )
  end

  # M75's own preludes (enrollment, the move) branch here, and only here: a
  # mode one of `state.responders` serves right now (`Home.Responder`) hands
  # the whole stream to that responder (`delegate/4`); every other stream is
  # a phone's or a desktop's, in the modes `state.phone_modes` names (the
  # paired and pairing modes, none on a candidate). Any other prelude closes
  # `1002` before any Noise state exists, as before.
  defp begin_handshake(wire, state) do
    case Noise.parse_prelude(wire, served_modes(state)) do
      {:ok, pattern, _body} -> continue_by_mode(pattern, wire, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp served_modes(state) do
    serving = for {mode, {module, opts}} <- responders(state), module.serving?(opts), do: mode
    Map.get(state, :phone_modes, @phone_modes) ++ serving
  end

  defp responders(state), do: Map.get(state, :responders, @responders)

  defp continue_by_mode(pattern, wire, state) do
    case Map.fetch(responders(state), pattern) do
      {:ok, {module, opts}} -> delegate(module, opts, wire, state)
      :error -> load_and_continue_handshake(pattern, wire, state)
    end
  end

  defp delegate(module, opts, wire, state) do
    loader = state.load_gateway_keypair
    root = state.identity_root

    opts =
      Keyword.merge(opts, peer: state.peer, load_gateway_keypair: fn -> loader.(root) end)

    state =
      state
      |> stop_handshake_deadline()
      |> scrub_identity_source()
      |> Map.put(:phase, :delegated)

    wrap_delegated(module, module.init(wire, opts), state)
  end

  defp wrap_delegated(module, result, state) do
    case result do
      {:ok, delegated} ->
        {:ok, delegated_state(state, module, delegated)}

      {:push, frames, delegated} ->
        {:push, frames, delegated_state(state, module, delegated)}

      {:stop, why, close, delegated} ->
        {:stop, why, close, delegated_state(state, module, delegated)}

      {:stop, why, close, frames, delegated} ->
        {:stop, why, close, frames, delegated_state(state, module, delegated)}
    end
  end

  defp delegated_state(state, module, delegated),
    do: Map.put(state, :delegate, {module, delegated})

  defp load_and_continue_handshake(pattern, wire, state) do
    case gateway_keypair(state) do
      {:ok, keypair, state} -> continue_handshake(pattern, wire, keypair, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp continue_handshake(pattern, wire, keypair, state) do
    case handshake_options(pattern, keypair, state) do
      {:ok, noise_opts, pairing, bound_state} ->
        run_handshake(pattern, wire, noise_opts, pairing, bound_state)

      {:error, reason, failed_state} ->
        handshake_error(pattern, reason, failed_state)
    end
  end

  defp run_handshake(pattern, wire, noise_opts, pairing, state) do
    with {:ok, noise} <- state.noise_initialize.(:responder, pattern, noise_opts),
         {:ok, <<>>, noise} <- state.noise_read.(noise, wire),
         {:ok, response, noise} <- state.noise_write.(noise, <<>>),
         {:ok, remote_static} <- state.noise_remote_static.(noise),
         {:ok, state} <- authenticate_handshake(pattern, remote_static, noise, pairing, state) do
      {:push, [response], state}
    else
      {:error, reason, failed_state} -> handshake_error(pattern, reason, failed_state)
      {:error, reason} -> handshake_error(pattern, reason, state)
      _unexpected -> handshake_error(pattern, :invalid_handshake_payload, state)
    end
  end

  defp handshake_error(:ikpsk2, reason, state), do: pairing_error(reason, state)

  # A key the trust store holds no row for belongs to a device that was revoked
  # (or never paired): told so (`4003`), so a phone or a desktop stops trying,
  # where any other handshake failure is a protocol error.
  defp handshake_error(:ik, {:unpaired_device, {:noise_identity_not_found, _key}}, state),
    do: {:stop, :unknown_device, {4003, "device unknown"}, state}

  defp handshake_error(:ik, reason, state), do: protocol_error(reason, state)

  defp handshake_options(:ik, keypair, state) when not is_nil(keypair) do
    {:ok, [static_keypair: keypair], nil, state}
  end

  defp handshake_options(:ikpsk2, keypair, state) when not is_nil(keypair) do
    case state.current_pair.(state.pair_manager, state.peer) do
      {:ok, %{secret: secret} = window} ->
        bound =
          Map.merge(state, %{
            pairing_session_id: window.session_id,
            pair_failure_recorded?: false
          })

        {:ok, [static_keypair: keypair, psk: secret], window, bound}

      :none ->
        {:error, :pairing_unavailable, state}
    end
  end

  defp handshake_options(_pattern, _keypair, state),
    do: {:error, :gateway_identity_unavailable, state}

  defp authenticate_handshake(:ik, remote_static, noise, _pairing, state) do
    case state.find_device.(state.device_store, remote_static) do
      {:ok, device} ->
        {:ok,
         Map.merge(state, %{
           phase: :await_hello,
           noise: noise,
           authenticated_device: device,
           peer_kind: device_kind(device)
         })
         |> scrub_identity_source()
         |> mark_session_start()}

      {:error, reason} ->
        {:error, {:unpaired_device, reason}}
    end
  end

  defp authenticate_handshake(:ikpsk2, remote_static, noise, pairing, state) do
    sas = state.noise_sas.(noise)

    {:ok,
     state
     |> Map.merge(%{
       phase: :await_pair_request,
       noise: noise,
       pairing_session_id: pairing.session_id,
       pairing_remote_static: remote_static,
       pairing_sas: sas,
       pairing_challenge: Attestation.challenge(pairing.secret)
     })
     |> scrub_identity_source()
     |> mark_session_start()}
  end

  defp handle_hello(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state),
         {:ok, state} <- accept_hello(event, state),
         {:ok, frames, state} <- hello_ack(state, event),
         {:ok, frames, state} <- after_hello_ack(session_kind(state), frames, state) do
      reply(frames, state)
    else
      {:error, {:unsupported_protocol_version, direction, version}, state} ->
        refuse_version(direction, version, state)

      {:error, :identity_mismatch, state} ->
        identity_mismatch(state)

      {:error, {:stale_primary, mine, theirs}, state} ->
        refuse_stale_primary(mine, theirs, state)

      {:error, {:desktop_peer_not_started, reason}, state} ->
        desktop_peer_failed(reason, state)

      {:error, reason, state} ->
        protocol_error(reason, state)

      {:error, reason} ->
        protocol_error(reason, state)
    end
  end

  # M75 D14: a phone that has seen a higher primary epoch has met the engine
  # this copy of the home moved to. It is told so by name and served nothing:
  # no device update, no registry entry, no hello_ack.
  defp refuse_stale_primary(mine, theirs, state) do
    Logger.warning(
      "mobile hello refused as a stale primary: this engine is at epoch #{mine}, " <>
        "the phone has seen epoch #{theirs}"
    )

    payload = %{
      "code" => "stale_primary",
      "message" =>
        "This engine is at epoch #{mine}; you have seen epoch #{theirs}: " <>
          "the primary moved, reconnect to the current one"
    }

    case encode_event("error", payload, <<>>, state) do
      {:ok, frames, state} -> {:stop, :stale_primary, {1002, "stale primary"}, frames, state}
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  defp handle_pair_request(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state) do
      pair_request_reply(event, state)
    else
      {:error, {:unsupported_protocol_version, direction, version}, state} ->
        refuse_version(direction, version, state)

      {:error, reason, state} ->
        pairing_error(reason, state)

      {:error, reason} ->
        protocol_error(reason, state)
    end
  end

  # The Noise session works but the client speaks a version outside the
  # window, so it is told which side must update, at the daemon's own version
  # since there is no negotiated one, and the session closes. An app to update
  # is not a failed pairing attempt: nothing counts against the window.
  defp refuse_version(direction, client_version, state) do
    {min, max} = Protocol.supported_version_range()

    payload = %{
      "code" => "unsupported_protocol_version",
      "message" => "client protocol #{client_version} is outside #{min}..#{max}",
      "direction" => Atom.to_string(direction),
      "client_version" => client_version,
      "min_version" => min,
      "max_version" => max
    }

    state = Map.put(state, :negotiated_version, Protocol.protocol_version())

    case encode_event("error", payload, <<>>, state) do
      {:ok, frames, state} ->
        {:stop, {:unsupported_protocol_version, direction},
         {1002, "unsupported mobile protocol version"}, frames, state}

      {:error, reason, state} ->
        protocol_error(reason, state)
    end
  end

  # Owner approval is a human decision that can outlast the client keepalive
  # interval, so a pairing socket answers `ping` while a decision is pending.
  # Nothing else is serviced before the decision arrives.
  defp handle_pending_decision(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state) do
      pending_decision_reply(event, state)
    else
      {:error, reason, failed_state} -> pairing_error(reason, failed_state)
      {:error, reason} -> pairing_error(reason, state)
    end
  end

  defp pending_decision_reply(%{type: "ping"}, state) do
    case encode_event("pong", %{}, <<>>, state) do
      {:ok, frames, state} -> reply(frames, state)
      {:error, reason, state} -> pairing_error(reason, state)
    end
  end

  defp pending_decision_reply(_event, state),
    do: protocol_error(:pairing_decision_pending, state)

  defp handle_ready_event(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state),
         :ok <- reject_repeated_hello(event, state),
         :ok <- authorize_ready_socket(state),
         :ok <- authorize_kind(event, state) do
      case dispatch_ready(event, state) do
        {:ok, reply, state} ->
          reply(reply, state)

        {:error, reason, state} ->
          application_error(reason, state)

        {:error, reason} ->
          application_error(reason, state)

        {:close, {:desktop_peer_unavailable, _exit} = reason, state} ->
          desktop_peer_failed(reason, state)

        {:close, reason, state} ->
          protocol_error(reason, state)
      end
    else
      {:error, :repeated_hello, failed_state} ->
        terminal_protocol_error(:repeated_hello, failed_state)

      {:error, {:unsupported_event, _type} = reason, failed_state} ->
        application_error(reason, failed_state)

      {:error, {:unknown_event, _type} = reason, failed_state} ->
        terminal_protocol_error(reason, failed_state)

      {:error, {:socket_not_authorized, _reason} = reason, failed_state} ->
        protocol_error(reason, failed_state)

      {:error, reason, state} ->
        protocol_error(reason, state)

      {:error, reason} ->
        protocol_error(reason, state)
    end
  end

  defp reject_repeated_hello(%{type: "hello"}, state),
    do: {:error, :repeated_hello, state}

  defp reject_repeated_hello(_event, _state), do: :ok

  # M75 §5.3: a known event this session's kind may not send is refused, and
  # the session stays open.
  defp authorize_kind(%{type: type}, state) do
    case Peers.authorize(session_kind(state), type) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A desktop hands its peer every desktop-family event; the phone events it
  # may send (`hello`, `ping`, `media_fetch`, `ack`) are served here, as a
  # phone's are.
  defp dispatch_ready(%{type: type} = event, %{desktop_peer: peer} = state) when is_pid(peer) do
    if DesktopPeer.family_event?(type),
      do: deliver_to_peer(event, peer, state),
      else: dispatch_event(event, state)
  end

  defp dispatch_ready(event, state), do: dispatch_event(event, state)

  defp deliver_to_peer(event, peer, state) do
    case state.deliver_desktop_event.(peer, event) do
      :ok -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
      {:close, reason} -> {:close, reason, state}
    end
  end

  # What the IK handshake proved, read once from the device's row: a row that
  # names no kind is a phone's, as is every device a pairing approves.
  defp session_kind(state), do: Map.get(state, :peer_kind, :phone)

  defp device_kind(device) do
    case value(device, :kind) do
      :desktop -> :desktop
      kind when kind in [nil, :phone] -> :phone
    end
  end

  defp authorize_ready_socket(state) do
    case state.authorize_socket.(state.device_registry, state.device_id, self()) do
      :ok -> :ok
      {:error, reason} -> {:error, {:socket_not_authorized, reason}, state}
      other -> {:error, {:socket_not_authorized, {:invalid_reply, other}}, state}
    end
  end

  defp decrypt_event(ciphertext, state) do
    with {:ok, state} <- maybe_rekey(state, :receive),
         {:ok, plaintext, noise} <- state.decrypt.(state.noise, ciphertext),
         {:ok, event} <- decode_event(plaintext, state) do
      {:ok, event, %{state | noise: noise}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp decode_event(plaintext, state) do
    state.decode_client.(plaintext, max_media_bytes: state.max_media_bytes)
  end

  defp next_sequence(%{seq: seq}, %{client_seq: prior}) when seq == prior + 1, do: :ok

  defp next_sequence(%{seq: seq}, %{client_seq: prior}) when seq <= prior,
    do: {:error, :replayed_sequence}

  defp next_sequence(%{seq: _seq}, _state), do: {:error, :out_of_order_sequence}
  defp next_sequence(_event, _state), do: {:error, :missing_sequence}

  defp consume_event(event, state) do
    with :ok <- next_sequence(event, state),
         {:ok, state} <- bind_protocol_version(event, state) do
      {:ok, %{state | client_seq: event.seq}}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp bind_protocol_version(%{version: version}, state) when is_integer(version) do
    case Map.get(state, :negotiated_version) do
      nil -> {:ok, Map.put(state, :negotiated_version, version)}
      ^version -> {:ok, state}
      _different -> {:error, :protocol_version_mismatch, state}
    end
  end

  defp bind_protocol_version(_event, state),
    do: {:error, :protocol_version_mismatch, state}

  defp accept_hello(%{type: "hello", payload: payload} = event, state) do
    authenticated_id = value(state.authenticated_device, :device_id)

    if payload["device_id"] == authenticated_id do
      with :ok <- current_primary(payload["primary_epoch"], state),
           {:ok, state} <- persist_hello(state, authenticated_id, payload["relay_list_rev"]) do
        attach_authenticated(event, state, authenticated_id)
      end
    else
      {:error, :identity_mismatch, %{state | client_seq: event.seq}}
    end
  end

  defp accept_hello(_event, state), do: {:error, :hello_required, state}

  # The phone's highest-seen epoch against the one this session's identity
  # carries; a phone that has seen none, or no higher one, is served.
  defp current_primary(theirs, state) do
    case session_primary_epoch(state) do
      {:ok, mine} when is_integer(theirs) and theirs > mine ->
        {:error, {:stale_primary, mine, theirs}, state}

      {:ok, _mine} ->
        :ok

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp session_primary_epoch(%{primary_epoch: epoch}) when is_integer(epoch) and epoch > 0,
    do: {:ok, epoch}

  defp session_primary_epoch(state),
    do: {:error, {:primary_epoch_unavailable, Map.get(state, :primary_epoch)}}

  defp attach_authenticated(_event, state, device_id) do
    case state.attach_socket.(state.device_registry, device_id, self(),
           profile_id: state.profile_id
         ) do
      :ok ->
        :ok = raise_heap_cap(state)

        {:ok,
         state
         |> Map.merge(%{phase: :ready, device_id: device_id})
         |> stop_handshake_deadline()}

      {:error, reason} ->
        {:error, {:registry_attach_failed, reason}, state}
    end
  end

  # The router caps an unauthenticated connection's heap (`Mobile.Router`); an
  # attached device's socket carries media and gets the larger cap it passed.
  defp raise_heap_cap(%{authenticated_max_heap_size: cap}) when is_map(cap) do
    _previous = Process.flag(:max_heap_size, cap)
    :ok
  end

  defp raise_heap_cap(_state), do: :ok

  # Every hello records when the phone was last seen, and the relay list
  # revision it names (M62 §3.1); the store writes only what changed. A newly
  # acknowledged revision can widen the relays the daemon's endpoint may use.
  defp persist_hello(state, device_id, relay_list_rev) do
    wall_clock = Map.get(state, :wall_clock, &DateTime.utc_now/0)

    case wall_clock.() do
      %DateTime{} = seen_at ->
        attrs = maybe_put(%{last_seen: seen_at}, :relay_list_rev, relay_list_rev)
        update_hello(state, device_id, attrs)

      other ->
        {:error, {:invalid_wall_clock, other}, state}
    end
  end

  defp update_hello(state, device_id, attrs) do
    previous = value(state.authenticated_device, :relay_list_rev)

    case state.update_device.(state.device_store, device_id, attrs) do
      {:ok, device} ->
        :ok = acknowledge_relays(previous, value(device, :relay_list_rev), state)
        {:ok, %{state | authenticated_device: device}}

      {:error, reason} ->
        {:error, {:last_seen_update_failed, reason}, state}

      other ->
        {:error, {:invalid_last_seen_update_reply, other}, state}
    end
  end

  defp acknowledge_relays(same, same, _state), do: :ok
  defp acknowledge_relays(_previous, _current, state), do: state.relay_list_acknowledged.()

  defp hello_ack(state, _event) do
    with {:ok, payload} <- build_hello_ack(state),
         {:ok, frames, state} <- encode_event("hello_ack", payload, <<>>, state) do
      {:ok, frames, state}
    end
  end

  # A phone hears what waits for the owner; a desktop's chat, approvals
  # included, rides its companion tunnel, and its peer starts once its
  # hello_ack is ready to go.
  defp after_hello_ack(:phone, frames, state) do
    with {:ok, frames, state} <- with_pending_approvals(frames, state) do
      with_pending_pairing(frames, state)
    end
  end

  defp after_hello_ack(:desktop, frames, state) do
    case start_desktop_peer(state) do
      {:ok, state} -> {:ok, frames, state}
      {:error, reason} -> {:error, {:desktop_peer_not_started, reason}, state}
    end
  end

  # The primary's side of a desktop's session failed, not the desktop.
  defp desktop_peer_failed(reason, state) do
    Logger.error("mobile desktop session closed: its peer failed: #{inspect(reason)}")
    {:stop, reason, {1011, "desktop peer failed"}, state}
  end

  defp start_desktop_peer(state) do
    opts = [
      device_id: state.device_id,
      session: self(),
      registry: state.desktop_peers,
      max_media_bytes: state.max_media_bytes,
      connected_since: state.wall_clock.()
    ]

    case state.start_desktop_peer.(opts) do
      {:ok, peer} when is_pid(peer) ->
        {:ok, %{state | desktop_peer: peer, desktop_peer_ref: Process.monitor(peer)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_peer_start, other}}
    end
  end

  # An approval still waiting for the owner follows the hello_ack in the same
  # push, so a phone that was away when it went out shows it. The socket is
  # attached already, so a resolution can only arrive after it. A card this
  # socket cannot encode is dropped as a fan-out event is.
  defp with_pending_approvals(frames, state) do
    state.pending_approvals.(state.profile_id)
    |> Enum.reduce_while({:ok, frames, state}, &append_pending_approval/2)
  end

  # A phone waiting for the owner's decision follows them (D16), so this phone
  # can approve it although it connected after the request was made.
  defp with_pending_pairing(frames, state) do
    case state.pairing_pending.() do
      {:ok, pending} ->
        {_step, result} = append_pending_approval(pending, {:ok, frames, state})
        result

      :none ->
        {:ok, frames, state}
    end
  end

  defp append_pending_approval(approval, {:ok, frames, state}) do
    with {:ok, plaintexts} <- encode_plaintexts(approval, state),
         {:ok, more, state} <- encrypt_batch(plaintexts, state) do
      {:cont, {:ok, frames ++ more, state}}
    else
      {:error, reason, failed_state} ->
        {:halt, {:error, reason, failed_state}}

      {:error, reason} ->
        {:ok, state} = drop_event(approval, reason, System.monotonic_time(), state)
        {:cont, {:ok, frames, state}}
    end
  end

  defp build_hello_ack(%{hello_ack_builder: builder} = state) when is_function(builder, 1) do
    builder.(state)
  end

  defp build_hello_ack(state) do
    with {:ok, history_head} <- history_head(state.profile_id, state),
         {:ok, read_up_to} <- read_frontier(state.profile_id, state),
         {:ok, primary_epoch} <- session_primary_epoch(state) do
      {min_version, max_version} = Protocol.supported_version_range()

      {:ok,
       %{
         "session_id" => session_id(),
         "min_version" => min_version,
         "max_version" => max_version,
         "profiles" => profiles(state),
         "candidates" => current_candidates(state),
         "history_head_seq" => history_head,
         "read_up_to_seq" => read_up_to,
         "caps" => %{
           "commands" => Mobile.command_catalog(),
           "media" => true,
           "streaming" => true,
           "turn_done" => true,
           "max_media_bytes" => state.max_media_bytes,
           "push" => state.push_services
         },
         "primary_epoch" => primary_epoch
       }}
    end
  end

  # M51 D3: the phone's key attestation is verified before the owner hears of
  # the phone. A refusal ends the session: the pairing manager closes the
  # window as failed and the phone is told why.
  defp pair_request_reply(%{type: "pair_request", payload: payload} = event, state) do
    evidence = attestation_evidence(event, state)

    case state.verify_pair.(state.pair_manager, state.pairing_session_id, evidence) do
      {:ok, facts} -> submit_pair_request(payload, facts, state)
      {:error, %{reason: _reason} = refusal} -> refuse_pair_request(refusal, payload, state)
      {:error, reason} -> pairing_error(reason, state)
    end
  end

  defp pair_request_reply(_event, state), do: pairing_error(:pair_request_required, state)

  defp attestation_evidence(%{payload: payload, bytes: chain}, state) do
    %{
      platform: payload["platform"],
      kind: payload["attestation"]["kind"],
      cert_lengths: payload["attestation"]["cert_lengths"],
      chain: chain,
      noise_pk: state.pairing_remote_static,
      challenge: state.pairing_challenge
    }
  end

  # The pinned roots and signers were embedded when the verifier compiled;
  # Google's status list comes from the pairing manager for each pairing.
  defp verify_pair(manager, session_id, evidence) do
    with {:ok, statuses} <- pairing_statuses(manager, session_id) do
      trust = Map.merge(Attestation.signers(), %{roots: Attestation.roots(), statuses: statuses})
      Attestation.verify(evidence, trust, DateTime.utc_now())
    end
  end

  # A status list that cannot be used is the verifier's to refuse; a window
  # that closed meanwhile ends this request.
  defp pairing_statuses(manager, session_id) do
    case PairManager.attestation_statuses(manager, session_id) do
      {:error, :session_not_found} -> {:error, :session_not_found}
      statuses -> {:ok, statuses}
    end
  end

  defp refuse_pair_request(%{reason: reason, check: check, detail: detail}, payload, state) do
    Logger.warning("mobile pairing refused: #{reason} (#{check}: #{inspect(detail)})")
    refused = %{reason: reason, check: check, platform: payload["platform"]}

    case state.refuse_pair.(state.pair_manager, state.pairing_session_id, refused) do
      :ok ->
        payload = %{"reason" => Atom.to_string(reason)}
        state = %{state | pair_failure_recorded?: true}
        send_event_then_stop("pair_denied", payload, reason, state)

      {:error, failure} ->
        pairing_error(failure, state)
    end
  end

  defp submit_pair_request(payload, facts, state) do
    attrs = %{
      name: payload["device_name"],
      model: payload["model"],
      app_version: payload["app_version"],
      platform: payload["platform"],
      noise_pk: state.pairing_remote_static,
      sas: state.pairing_sas,
      attestation: facts,
      socket_pid: self()
    }

    case state.submit_pair.(state.pair_manager, state.pairing_session_id, attrs) do
      {:ok, _request} -> {:ok, stop_handshake_deadline(%{state | phase: :await_pair_decision})}
      {:error, reason} -> pairing_error(reason, state)
    end
  end

  defp handle_pair_decision(session_id, {:ok, device}, %{pairing_session_id: session_id} = state) do
    case session_primary_epoch(state) do
      {:ok, epoch} -> approve_pairing(device, epoch, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp handle_pair_decision(
         session_id,
         {:error, reason},
         %{pairing_session_id: session_id} = state
       ) do
    payload = %{"reason" => Atom.to_string(reason)}
    send_event_then_stop("pair_denied", payload, reason, %{state | pair_failure_recorded?: true})
  end

  defp handle_pair_decision(_session_id, _result, state), do: {:ok, state}

  # The push salt is the device's own, for the key its notifications are
  # encrypted under (see *Push notifications* in the protocol). The primary
  # epoch is where the new phone's highest-seen epoch starts (M75 D14).
  defp approve_pairing(device, epoch, state) do
    payload = %{
      "device_id" => value(device, :device_id),
      "candidates" => current_candidates(state),
      "profiles" => profiles(state),
      "push_salt" => Base.encode64(value(device, :apns_key_salt)),
      "push" => state.push_services,
      "primary_epoch" => epoch
    }

    # The owner's decision can come at any time in the window, so the hello
    # that follows gets a deadline of its own, not what was left of the first.
    state =
      start_handshake_deadline(%{state | phase: :await_hello, authenticated_device: device})

    case encode_event("pair_approved", payload, <<>>, state) do
      {:ok, frames, state} -> reply(frames, state)
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  defp dispatch_event(%{type: "attach_begin", payload: payload}, state) do
    spec = %{
      attach_id: payload["attach_id"],
      kind: payload["kind"],
      mime: payload["mime"],
      size_bytes: payload["size_bytes"],
      sha256: payload["sha256"],
      name: payload["name"],
      poster_of: payload["poster_of"]
    }

    case MediaStore.begin_upload(state.media_store, spec) do
      {:ok, status} -> attach_begin_reply(payload["attach_id"], status, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch_event(%{type: "attach_chunk", payload: payload, bytes: bytes}, state) do
    case MediaStore.write_chunk(state.media_store, payload["attach_id"], payload["index"], bytes) do
      :ok -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch_event(%{type: "attach_end", payload: payload}, state) do
    case MediaStore.finish_upload(state.media_store, payload["attach_id"], payload["sha256"]) do
      {:ok, _ref} -> attach_end_reply(payload["attach_id"], state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Kept for every phone: Push sends only an iPhone's, and refuses the rest by
  # name, so an Android phone's token is never sent through APNs.
  defp dispatch_event(%{type: "push_register", payload: payload}, state) do
    case validate_push_environment(payload["environment"], state.push_environment) do
      :ok -> store_push_token(payload["apns_token"], state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The phone's notifications cannot show, so no push may come (M51 §10).
  defp dispatch_event(%{type: "push_unregister"}, state), do: store_push_token(nil, state)

  defp dispatch_event(%{type: "media_fetch", payload: payload}, state) do
    queue_media_fetch(payload["ref"], state)
  end

  defp dispatch_event(%{type: "ack", payload: payload}, state) do
    {:ok, nil, Map.put(state, :last_ack_seq, payload["server_seq"])}
  end

  defp dispatch_event(%{type: "unpair"}, state) do
    with :ok <- DeviceRegistry.revoke(state.device_registry, state.device_id) do
      {:ok, nil, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch_event(%{type: type} = event, state) when type in @queued_events do
    queue_request(event, state)
  end

  defp dispatch_event(%{type: "pair_start"}, state), do: pair_start(state)

  defp dispatch_event(%{type: "pair_decide", payload: payload}, state),
    do: pair_decide(payload["session_id"], payload["approved"], state)

  defp dispatch_event(%{type: "devices_list"}, state), do: devices(state)

  defp dispatch_event(%{type: "device_revoke", payload: payload}, state),
    do: device_revoke(payload["device_id"], state)

  defp dispatch_event(event, state) do
    case state.event_router.(event, ingress_context(state), router_opts(state)) do
      :ok -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # D16: the window opens exactly as `mobile.pair.start` opens it, and the
  # link goes to this phone alone, encrypted, to show as a QR code: it is
  # never logged or kept. A refusal is the facade's own word.
  defp pair_start(state) do
    case state.pair_start.() do
      {:ok, %{session: session, uri: link}} ->
        encode_event_frames(pair_window(session, link), state)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp pair_window(session, link) do
    %{
      "t" => "pair_window",
      "session_id" => session.session_id,
      "link" => link,
      "expires_in_s" => session.ttl_ms |> div_ceil(1_000) |> max(1) |> min(120)
    }
  end

  defp div_ceil(value, by), do: div(value + by - 1, by)

  # The decision is `mobile.pair.decide`'s; how the request ends reaches every
  # phone as `pair_decided`, from the pair manager.
  defp pair_decide(session_id, approved, state) do
    case state.pair_decide.(session_id, approved) do
      {:ok, _session} -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The owner's devices as `mobile.devices.list` answers them, so a phone can
  # see the computers and phones paired with this Fermix.
  defp devices(state) do
    case state.devices_list.() do
      {:ok, rows} ->
        event = %{"t" => "devices", "devices" => Enum.map(rows, &device_wire(&1, state))}
        encode_event_frames(event, state)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # A phone is an owner device: it revokes a device exactly as
  # `mobile.devices.revoke` does (a stolen computer, with the owner's other
  # computer out of reach), and hears the list that is left.
  defp device_revoke(device_id, state) do
    case state.device_revoke.(device_id) do
      {:ok, _revoked} -> devices(state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp device_wire(row, state) do
    %{
      "device_id" => row.device_id,
      "name" => row.name,
      "model" => row.model,
      "kind" => Atom.to_string(row.kind),
      "created_at" => row.created_at,
      "this_device" => row.device_id == state.device_id
    }
    |> maybe_put("last_seen", row.last_seen)
    |> maybe_put("executor", row.executor)
  end

  # A `msg` or `command` carries the whole pre-turn pipeline — attachment
  # resolution, voice-note transcription, the durable append, gateway ingest —
  # which runs for tens of seconds on a large upload. Inline, it would starve
  # ping and every control frame on this socket until it finished and the client
  # would reconnect mid-processing, so it runs in one supervised worker at a
  # time: per-connection order is preserved, concurrency stays at one, and the
  # coordinator's liveness fence follows the worker that actually owns
  # settlement until ingest hands the turn to the queue.
  defp queue_request(_event, %{pending_requests: pending} = state)
       when length(pending) >= @max_pending_requests do
    {:error, :request_backlog_full, state}
  end

  defp queue_request(event, state) do
    queued = %{state | pending_requests: state.pending_requests ++ [event]}

    case start_next_request(queued) do
      {:ok, next} -> {:ok, nil, next}
      {:error, reason, failed_state} -> {:error, reason, failed_state}
    end
  end

  defp start_next_request(%{request_ref: ref} = state) when is_reference(ref), do: {:ok, state}
  defp start_next_request(%{pending_requests: []} = state), do: {:ok, state}

  defp start_next_request(%{pending_requests: [event | rest]} = state) do
    case state.run_request.(request_job(event, state)) do
      {:ok, worker} when is_pid(worker) ->
        {:ok,
         %{
           state
           | pending_requests: rest,
             request_ref: Process.monitor(worker),
             request_client_msg_id: event.payload["client_msg_id"]
         }}

      other ->
        {:error, {:request_worker_unavailable, other}, state}
    end
  end

  # The job carries only what the pipeline needs: the socket's Noise state never
  # leaves this process, and the reply path is the same registry fanout every
  # other asynchronous mobile event already uses. A failure is told to the
  # device through the registry, never to this socket's pid, so a socket that
  # replaced this one still hears it, correlated by its `client_msg_id`.
  defp request_job(event, state) do
    router = state.event_router
    context = ingress_context(state)
    opts = router_opts(state)

    fn ->
      case router.(event, context, opts) do
        :ok -> :ok
        {:error, reason} -> report_request_failure(event, context, opts, reason)
      end
    end
  end

  defp report_request_failure(event, context, opts, reason) do
    client_msg_id = event.payload["client_msg_id"]
    failure = request_error(reason, client_msg_id)

    case Keyword.fetch!(opts, :event_sink).({:device, context.authenticated_device_id}, failure) do
      :ok ->
        :ok

      {:error, sink_reason} ->
        Logger.warning(
          "mobile request #{client_msg_id} failed (#{inspect(reason)}) and its device " <>
            "could not be told: #{inspect(sink_reason)}"
        )
    end
  end

  defp finished_request_reply(:normal, _client_msg_id, state), do: {:ok, state}

  defp finished_request_reply(reason, client_msg_id, state),
    do: application_error({:request_failed, reason}, state, client_msg_id)

  defp ingress_context(state),
    do: %{transport: :mobile, authenticated_device_id: state.device_id}

  defp router_opts(state) do
    registry = state.device_registry
    send_device_event = state.send_device_event

    event_sink = fn
      {:device, device_id}, logical ->
        send_device_event.(registry, device_id, logical)

      {:profile, profile_id}, logical ->
        Fanout.announce(profile_id, logical, device_registry: registry)

      {:phones, profile_id}, logical ->
        Fanout.announce(profile_id, logical, audience: :mobile, device_registry: registry)
    end

    [
      media_server: state.media_store,
      request_coordinator: state.request_coordinator,
      event_sink: event_sink
    ]
  end

  defp attach_begin_reply(attach_id, status, state) do
    state =
      if status == :upload,
        do: %{state | uploads: MapSet.put(state.uploads, attach_id)},
        else: state

    logical = %{
      "t" => "attach_status",
      "attach_id" => attach_id,
      "status" => Atom.to_string(status)
    }

    encode_event_frames(logical, state)
  end

  defp attach_end_reply(attach_id, state) do
    state = %{state | uploads: MapSet.delete(state.uploads, attach_id)}
    logical = %{"t" => "attach_status", "attach_id" => attach_id, "status" => "present"}
    encode_event_frames(logical, state)
  end

  # A blob streams one chunk per mailbox step, so ping, ack and msg are read
  # between chunks instead of waiting out a whole transfer, and only one chunk
  # is ever held. A fetch that arrives mid-transfer waits its turn, so each blob
  # stays one contiguous media_begin..media_end run. One step message is in
  # flight exactly while a transfer or a queued fetch is pending.
  defp queue_media_fetch(ref, %{media_queue: queue} = state)
       when length(queue) >= @max_media_fetch_queue do
    encode_event_frames(media_error(ref, :media_fetch_backlog_full), state)
  end

  defp queue_media_fetch(ref, state) do
    idle? = not media_pending?(state)
    state = %{state | media_queue: state.media_queue ++ [ref]}
    if idle?, do: send(self(), :mobile_media_step)
    {:ok, nil, state}
  end

  defp media_pending?(state), do: not is_nil(state.media_transfer) or state.media_queue != []

  defp schedule_media_step(state) do
    if media_pending?(state), do: send(self(), :mobile_media_step)
    :ok
  end

  defp media_step(%{media_transfer: nil, media_queue: []} = state), do: {:ok, state}

  defp media_step(%{media_transfer: nil, media_queue: [ref | rest]} = state),
    do: start_media_transfer(ref, %{state | media_queue: rest})

  defp media_step(%{media_transfer: transfer} = state),
    do: advance_media_transfer(transfer, state)

  defp start_media_transfer(ref, state) do
    case open_media(ref, state) do
      {:ok, transfer} ->
        push_media_event(media_begin(transfer), %{state | media_transfer: transfer})

      {:error, reason} ->
        media_failed(ref, reason, state)
    end
  end

  defp open_media(ref, state) do
    with {:ok, descriptor} <- state.media_descriptor.(state.profile_id, ref),
         {:ok, media} <- Timeline.normalize_media_descriptor(descriptor, ref),
         {:ok, blob} <- MediaStore.fetch(state.media_store, ref),
         :ok <- matching_blob_size(blob, media),
         {:ok, io} <- File.open(blob.path, [:read, :binary, :raw]) do
      {:ok,
       %{ref: ref, media: media, io: io, index: 0, sent: 0, hash: :crypto.hash_init(:sha256)}}
    end
  end

  defp matching_blob_size(blob, media) do
    if value(blob, :size_bytes) == media.size_bytes,
      do: :ok,
      else: {:error, :media_descriptor_mismatch}
  end

  defp media_begin(%{ref: ref, media: media}) do
    %{
      "t" => "media_begin",
      "ref" => ref,
      "server_seq" => media.server_seq,
      "kind" => media.kind,
      "mime" => media.mime,
      "size_bytes" => media.size_bytes,
      "sha256" => media.sha256
    }
    |> maybe_put("filename", media.filename)
    |> maybe_put("caption", media.caption)
  end

  defp advance_media_transfer(transfer, state) do
    case :file.read(transfer.io, Protocol.max_raw_chunk_bytes()) do
      {:ok, chunk} -> push_media_chunk(chunk, transfer, state)
      :eof -> finish_media_transfer(transfer, state)
      {:error, reason} -> abort_media_transfer(transfer.ref, reason, state)
    end
  end

  # The size bound is checked per chunk, so a blob that grew on disk ends at
  # the descriptor's size instead of streaming past it.
  defp push_media_chunk(chunk, transfer, state) do
    sent = transfer.sent + byte_size(chunk)

    if sent > transfer.media.size_bytes do
      abort_media_transfer(transfer.ref, :media_descriptor_mismatch, state)
    else
      hash = :crypto.hash_update(transfer.hash, chunk)
      next = %{transfer | index: transfer.index + 1, sent: sent, hash: hash}
      push_media_event(media_chunk(transfer, chunk), %{state | media_transfer: next})
    end
  end

  defp media_chunk(transfer, chunk),
    do: %{
      "t" => "media_chunk",
      "ref" => transfer.ref,
      "index" => transfer.index,
      "bytes" => chunk
    }

  # media_end goes out only once the digest of everything streamed matches
  # the descriptor; a blob that changed on disk ends with a typed error.
  defp finish_media_transfer(transfer, state) do
    close_media_transfer(state)
    state = %{state | media_transfer: nil}
    digest = transfer.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    if digest == transfer.media.sha256 and transfer.sent == transfer.media.size_bytes,
      do:
        push_media_event(%{"t" => "media_end", "ref" => transfer.ref, "sha256" => digest}, state),
      else: media_failed(transfer.ref, :media_descriptor_mismatch, state)
  end

  defp push_media_event(event, state) do
    case encode_plaintexts(event, state) do
      {:ok, plaintexts} -> push_media_plaintexts(plaintexts, state)
      {:error, reason} -> abort_media_transfer(event["ref"], reason, state)
    end
  end

  defp abort_media_transfer(ref, reason, state) do
    close_media_transfer(state)
    media_failed(ref, reason, %{state | media_transfer: nil})
  end

  # The typed error names the blob: it can arrive after other frames, not only
  # as the direct reply to its media_fetch.
  defp media_failed(ref, reason, state) do
    case encode_plaintexts(media_error(ref, reason), state) do
      {:ok, plaintexts} -> push_media_plaintexts(plaintexts, state)
      {:error, _encode_reason} -> protocol_error(reason, state)
    end
  end

  defp media_error(ref, reason) do
    %{
      "t" => "error",
      "code" => error_code(reason),
      "message" => Output.error_message(reason),
      "ref" => ref
    }
  end

  defp push_media_plaintexts(plaintexts, state) do
    :ok = schedule_media_step(state)
    push_encrypted(plaintexts, state)
  end

  defp close_media_transfer(%{media_transfer: %{io: io, ref: ref}}) do
    case File.close(io) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("mobile media #{ref} close failed: #{inspect(reason)}")
    end
  end

  defp close_media_transfer(_state), do: :ok

  # A fan-out event this socket cannot encode is the daemon's own bug, not the
  # peer's: it is dropped for this device, reported where the operator reads,
  # and the session stays up. Encoding finishes before anything is encrypted,
  # so a dropped event never moves the send nonce.
  defp push_fanout_event(event, state) do
    started = System.monotonic_time()

    with :ok <- for_kind(event, session_kind(state)),
         {:ok, plaintexts} <- encode_plaintexts(event, state) do
      push_encrypted(plaintexts, state)
    else
      {:error, reason} -> drop_event(event, reason, started, state)
    end
  end

  # M75 §5.3: a server event this session's kind is never sent.
  defp for_kind(event, kind) do
    type = event_type(event)
    if Peers.server_event?(kind, type), do: :ok, else: {:error, {:not_for_kind, kind}}
  end

  defp drop_event(event, reason, started, state) do
    duration_us =
      System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    Logger.error(
      "mobile socket dropped a #{event_type(event)} event: " <>
        inspect(reason, limit: 5, printable_limit: 256)
    )

    ChannelTelemetry.emit_render(:mobile, {:error, error_class(reason)}, duration_us)
    {:ok, state}
  end

  defp event_type(%{"t" => type}) when is_binary(type), do: type
  defp event_type(%{type: type}) when is_binary(type), do: type
  defp event_type(_event), do: "malformed"

  # Telemetry metadata stays an atom, so no event content reaches a trace.
  defp error_class(reason) when is_atom(reason), do: reason

  defp error_class(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp error_class(_reason), do: :encode_failed

  # An encryption failure after an earlier frame of the run already moved the
  # send nonce leaves the client unable to follow, so the session closes.
  defp push_encrypted(plaintexts, state) do
    case encrypt_batch(plaintexts, state) do
      {:ok, frames, state} -> reply(frames, state)
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  # One logical event is encoded whole, every event_part of a long one
  # included, before any frame is encrypted. Encrypting as we go would advance
  # the Noise send cipher for frames a later encoding failure then discards,
  # and the frame that replaced them would carry a nonce the client cannot
  # follow: an undiagnosable desync instead of one typed refusal.
  defp encode_event_frames(event, state) do
    case encode_plaintexts(event, state) do
      {:ok, plaintexts} -> encrypt_batch(plaintexts, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp encrypt_batch(plaintexts, state) do
    Enum.reduce_while(plaintexts, {:ok, [], state}, fn plaintext, {:ok, frames, state} ->
      case encrypt_frame(plaintext, state) do
        {:ok, frame, state} -> {:cont, {:ok, [frame | frames], state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
    |> then(fn
      {:ok, frames, state} -> {:ok, Enum.reverse(frames), state}
      error -> error
    end)
  end

  defp encode_plaintexts(event, state) do
    with {:ok, type, payload, bytes} <- normalize_logical_event(event) do
      call_encoder(
        state.encode_server,
        type,
        payload,
        state.server_seq + 1,
        bytes,
        Map.get(state, :negotiated_version)
      )
    end
  end

  defp normalize_logical_event(%{"t" => type} = event) when is_binary(type) do
    {:ok, type, Map.drop(event, ["t", "bytes"]), Map.get(event, "bytes", <<>>)}
  end

  defp normalize_logical_event(%{type: type, payload: payload} = event)
       when is_binary(type) and is_map(payload) do
    {:ok, type, payload, Map.get(event, :bytes, <<>>)}
  end

  defp normalize_logical_event(event), do: {:error, {:invalid_server_event, event}}

  defp encode_event(type, payload, bytes, state),
    do: encode_event_frames(%{type: type, payload: payload, bytes: bytes}, state)

  defp encrypt_frame(plaintext, state) do
    with {:ok, state} <- maybe_rekey(state, :send),
         {:ok, ciphertext, noise} <- state.encrypt.(state.noise, plaintext) do
      {:ok, ciphertext, %{state | noise: noise, server_seq: state.server_seq + 1}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp call_encoder(encoder, type, payload, seq, bytes, version) do
    encoded =
      case :erlang.fun_info(encoder, :arity) do
        {:arity, 3} -> encoder.(type, payload, seq)
        {:arity, 4} -> encoder.(type, payload, seq, bytes)
        {:arity, 5} -> encoder.(type, payload, seq, bytes, version)
      end

    plaintext_run(encoded)
  end

  # An encoder answers with the run of plaintexts one logical event needs; a
  # lone plaintext is a run of one.
  defp plaintext_run({:ok, plaintext}) when is_binary(plaintext), do: {:ok, [plaintext]}
  defp plaintext_run({:ok, [_first | _rest] = plaintexts}), do: {:ok, plaintexts}
  defp plaintext_run({:error, _reason} = error), do: error

  defp maybe_rekey(%{noise: nil} = state, _direction), do: {:ok, state}

  defp maybe_rekey(state, direction) do
    frame_count =
      if is_map(state.noise), do: Map.get(state.noise, frame_counter(direction), 0), else: 0

    if frame_count >= @rekey_after_frames do
      with {:ok, noise} <- state.noise_rekey.(state.noise, direction) do
        {:ok, %{state | noise: noise}}
      end
    else
      {:ok, state}
    end
  end

  defp frame_counter(:send), do: :send_frames
  defp frame_counter(:receive), do: :receive_frames

  # A carrier's keepalives (WebSocket pings) keep its idle timer alive, so
  # without this a peer that never completes its handshake and hello, or its
  # pair request, holds a carrier, a process and one of the listener's
  # connection slots indefinitely. The deadline stops when the socket leaves those phases: a
  # request waiting for the owner is bounded by its window, whose close the
  # pair manager reports, and a ready socket said hello in time. A pairing
  # approval arms a fresh one for the hello. The token keeps a deadline that
  # was already in the mailbox from closing the socket after either.
  defp arm_handshake_deadline(%{phase: :prelude} = state), do: start_handshake_deadline(state)
  defp arm_handshake_deadline(state), do: state

  defp start_handshake_deadline(state) do
    state = stop_handshake_deadline(state)
    schedule = Map.get(state, :schedule_handshake_deadline, &Process.send_after(self(), &1, &2))
    token = make_ref()
    timer_ref = schedule.({:mobile_handshake_deadline, token}, @handshake_deadline_ms)
    %{state | handshake_deadline_ref: timer_ref, handshake_deadline_token: token}
  end

  defp stop_handshake_deadline(%{handshake_deadline_ref: nil} = state),
    do: %{state | handshake_deadline_token: nil}

  defp stop_handshake_deadline(state) do
    cancel = Map.get(state, :cancel_handshake_deadline, &Process.cancel_timer/1)
    _cancelled_or_elapsed = cancel.(state.handshake_deadline_ref)
    %{state | handshake_deadline_ref: nil, handshake_deadline_token: nil}
  end

  # A peer that proved the gateway key and then never sent its pair request
  # failed its pairing handshake, and is counted against its own address.
  defp handshake_deadline(%{phase: :await_pair_request} = state),
    do: handshake_timeout(record_pair_failure(state))

  defp handshake_deadline(state), do: handshake_timeout(state)

  defp handshake_timeout(state),
    do: {:stop, :handshake_timeout, @handshake_deadline_close, state}

  # A desktop's session (M75) is meant to stay up: it has no lifetime, and the
  # 2^20-frame rekey still bounds every key. Every other session ends after an
  # hour.
  defp mark_session_start(%{peer_kind: :desktop} = state), do: state

  defp mark_session_start(state) do
    now = Map.get(state, :clock, fn -> System.monotonic_time(:millisecond) end).()
    token = make_ref()
    schedule = Map.get(state, :schedule_session_timer, &Process.send_after(self(), &1, &2))
    timer_ref = schedule.({:mobile_session_expired, token}, @session_lifetime_ms)

    Map.merge(state, %{
      session_started_ms: now,
      session_timer_ref: timer_ref,
      session_timer_token: token
    })
  end

  defp session_expired?(state) do
    case Map.get(state, :session_started_ms) do
      nil -> false
      started -> Map.get(state, :clock, fn -> started end).() - started >= @session_lifetime_ms
    end
  end

  defp session_expired(state) do
    {:stop, :session_expired, {1000, "Noise session lifetime reached"}, state}
  end

  defp cancel_session_timer(state) do
    case Map.get(state, :session_timer_ref) do
      nil ->
        :ok

      ref ->
        cancel = Map.get(state, :cancel_session_timer, &Process.cancel_timer/1)
        _cancelled_or_elapsed = cancel.(ref)
        :ok
    end
  end

  defp reply(nil, state), do: {:ok, state}
  defp reply([], state), do: {:ok, state}
  defp reply(frames, state) when is_list(frames), do: {:push, frames, state}

  defp send_event_then_stop(type, payload, reason, state) do
    case encode_event(type, payload, <<>>, state) do
      {:ok, frames, state} ->
        {:stop, reason, {4003, "pairing #{reason}"}, frames, state}

      {:error, _encode_reason, state} ->
        {:stop, reason, {4003, "pairing #{reason}"}, state}
    end
  end

  defp application_error(reason, state, client_msg_id \\ nil) do
    case encode_event("error", error_payload(reason, client_msg_id), <<>>, state) do
      {:ok, frames, state} -> reply(frames, state)
      {:error, _encode_reason, state} -> protocol_error(reason, state)
    end
  end

  defp pairing_error(reason, state) do
    state = record_pair_failure(state)
    protocol_error({:pairing_failed, reason}, state)
  end

  defp terminal_protocol_error(reason, state) do
    payload = %{"code" => terminal_error_code(reason), "message" => Output.error_message(reason)}

    case encode_event("error", payload, <<>>, state) do
      {:ok, frames, state} ->
        {:stop, reason, {1002, "mobile protocol error"}, frames, state}

      {:error, _encode_reason, failed_state} ->
        protocol_error(reason, failed_state)
    end
  end

  defp terminal_error_code({:unknown_event, _type}), do: "unsupported"
  defp terminal_error_code(:repeated_hello), do: "repeated_hello"

  defp protocol_error(:invalid_prelude, state) do
    {:stop, :invalid_prelude, {1002, "invalid mobile prelude"}, state}
  end

  defp protocol_error(reason, state) do
    {:stop, reason, {1002, "mobile protocol error"}, state}
  end

  defp identity_mismatch(state) do
    {:stop, :identity_mismatch, {4003, "authenticated device mismatch"}, state}
  end

  defp detach_socket(%{device_id: device_id, device_registry: registry})
       when is_binary(device_id) do
    _ = DeviceRegistry.detach(registry, device_id, self())
    :ok
  end

  defp detach_socket(_state), do: :ok

  defp cancel_uploads(%{uploads: uploads, media_store: media_store}) do
    Enum.each(uploads, fn attach_id ->
      case MediaStore.cancel_upload(media_store, attach_id) do
        :ok -> :ok
        {:error, :unknown_upload} -> :ok
        {:error, reason} -> Logger.warning("mobile upload cleanup failed: #{inspect(reason)}")
      end
    end)
  end

  defp cancel_uploads(_state), do: :ok

  # A socket that idled out while the owner was still deciding is a slow human,
  # not a failed handshake: section 6.2 rate-limits failed handshakes only, so
  # counting this would spend the pairing window on the owner's own thinking time.
  defp record_abandoned_pair(:timeout, _state), do: :ok

  defp record_abandoned_pair(_reason, %{phase: :await_pair_decision} = state),
    do: record_pair_failure(state)

  defp record_abandoned_pair(_reason, _state), do: :ok

  # A peer whose session failed before hello or a pair request keeps no iroh
  # connection: otherwise stream after failing stream holds one of the
  # helper's connection places for as long as the peer likes.
  defp close_unauthenticated_iroh_peer(%{peer: {:iroh, endpoint_id}, phase: phase} = state)
       when phase in @deadline_phases,
       do: :ok = state.close_iroh_peer.(endpoint_id)

  defp close_unauthenticated_iroh_peer(_state), do: :ok

  defp record_pair_failure(%{pair_failure_recorded?: true} = state), do: state

  defp record_pair_failure(%{pairing_session_id: session_id, pair_manager: manager} = state)
       when is_binary(session_id) do
    case state.record_pair_failure.(manager, session_id, state.peer) do
      {:ok, _count} ->
        %{state | pair_failure_recorded?: true}

      {:error, reason} ->
        Logger.debug("mobile pairing failure terminal: #{inspect(reason)}")
        %{state | pair_failure_recorded?: true}
    end
  end

  defp record_pair_failure(state), do: state

  defp history_head(profile, %{history_head: fun}) when is_function(fun, 1), do: fun.(profile)

  defp history_head(profile, _state),
    do: apply(Timeline, :history_head, [profile])

  defp read_frontier(profile, %{read_frontier: fun}) when is_function(fun, 1), do: fun.(profile)

  defp read_frontier(profile, _state),
    do: apply(Timeline, :read_frontier, [profile])

  # Candidates are routes for later reconnects; the phone already holds the
  # QR's and the last hello_ack's. A failed enumeration must not undo an
  # approved pairing or close a reconnect, so it ships no host candidates and
  # says so where the operator reads. The rail's candidate, when it is ready,
  # comes last (M62 §2).
  defp current_candidates(state) do
    case state.iroh_candidate.() do
      {:ok, iroh} -> host_candidates(state, @max_host_candidates_with_iroh) ++ [iroh]
      :none -> host_candidates(state, @max_candidates)
    end
  end

  defp host_candidates(state, limit) do
    case state.discover.() do
      {:ok, candidates} ->
        encode_candidates(candidates, limit)

      {:error, reason} ->
        Logger.warning("mobile candidate discovery failed: #{inspect(reason)}")
        []
    end
  end

  # Discovery orders candidates best first, so the cap keeps the likeliest routes.
  defp encode_candidates(candidates, limit) do
    candidates
    |> Enum.take(limit)
    |> Enum.map(fn candidate ->
      %{
        "host" => candidate.address,
        "interface" => candidate.interface,
        "scope" => Atom.to_string(candidate.scope)
      }
    end)
  end

  defp profiles(state) do
    name = Map.get(state, :profile_name, configured_profile_name())
    [%{"id" => state.profile_id, "name" => name}]
  end

  defp session_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  The `error` event that tells a device its request `client_msg_id` failed
  for `reason`, as every failed request's is built: `code` is the reason's
  own word when it has one (an atom, or one of `typed_refusals/0`), else
  `request_failed`.
  """
  @spec request_error(term(), String.t()) :: map()
  def request_error(reason, client_msg_id) when is_binary(client_msg_id),
    do: Map.put(error_payload(reason, client_msg_id), "t", "error")

  defp error_payload(reason, client_msg_id) do
    %{"code" => error_code(reason), "message" => Output.error_message(reason)}
    |> maybe_put("client_msg_id", client_msg_id)
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp error_code(reason)
       when is_tuple(reason) and tuple_size(reason) > 1 and elem(reason, 0) in @typed_refusals,
       do: reason |> elem(0) |> Atom.to_string()

  defp error_code(_reason), do: "request_failed"

  defp store_push_token(token, state) do
    case state.update_device.(state.device_store, state.device_id, %{push_token: token}) do
      {:ok, _device} -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp validate_push_environment(received, configured)
       when received in ["development", "production"] and
              configured in [:development, :production] do
    validate_push_environment(received, Atom.to_string(configured))
  end

  defp validate_push_environment(environment, environment), do: :ok

  defp validate_push_environment(received, configured),
    do: {:error, {:push_environment_mismatch, configured, received}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp clock(opts) do
    Map.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
  end

  defp profile_name(opts) do
    configured = Map.get(opts, :profile_name, configured_profile_name())

    case configured do
      name when is_binary(name) -> validate_profile_name(name)
      other -> {:error, {:invalid_profile_name, other}}
    end
  end

  defp configured_profile_name do
    :fermix_core
    |> Application.get_env(:agent, [])
    |> Keyword.get(:name, "Fermix")
  end

  defp validate_profile_name(name) do
    trimmed = String.trim(name)

    if byte_size(trimmed) in 1..128,
      do: {:ok, trimmed},
      else: {:error, {:invalid_profile_name, name}}
  end

  defp normalize_identity_loader(opts) do
    case Map.pop(opts, :gateway_keypair) do
      {nil, state} ->
        Map.put_new(state, :load_gateway_keypair, &load_gateway_keypair/1)

      {keypair, state} ->
        Map.put_new(state, :load_gateway_keypair, fn _root -> {:ok, keypair} end)
    end
  end

  defp scrub_identity_source(state) do
    state
    |> Map.delete(:gateway_keypair)
    |> Map.delete(:load_gateway_keypair)
  end

  defp gateway_keypair(%{gateway_keypair: keypair} = state) when not is_nil(keypair),
    do: {:ok, keypair, state}

  # The identity the handshake loads carries its primary epoch, kept in the
  # session for `hello` and `pair_approved`: one load, one bundle, so the
  # epoch announced is the one that came with the key (M75 D14).
  defp gateway_keypair(state) do
    case state.load_gateway_keypair.(state.identity_root) do
      {:ok, %{private: private, public: public} = loaded}
      when byte_size(private) == 32 and byte_size(public) == 32 ->
        {:ok, %{private: private, public: public},
         Map.merge(state, Map.take(loaded, [:primary_epoch]))}

      {:error, reason} ->
        {:error, {:gateway_identity_unavailable, reason}}

      other ->
        {:error, {:invalid_gateway_identity_reply, other}}
    end
  end

  defp load_gateway_keypair(root) do
    opts = if is_nil(root), do: [], else: [root: root]

    case Identity.load(opts) do
      {:ok, identity} ->
        {:ok,
         %{
           private: identity.gateway_private_key,
           public: identity.gateway_public_key,
           primary_epoch: identity.primary_epoch
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
