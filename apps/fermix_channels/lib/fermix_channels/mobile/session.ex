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
  broadcasts never reach it. A desktop's `hello` names its engine's version
  (`app_version`), which the session records in the home's record of its
  computers (`FermixCore.Computers.Store`, under the identity's home); a
  record that fails is logged and the desktop is served all the same. It
  names its system too (`platform`, M97 §3.2), kept on its row when the row
  says none or another; a phone's `hello` never moves its row's platform. Its
  `hello_ack` says which of a computer's own events this server takes
  (`caps.computer`: `offers`, `link_path`, and `invoke` for the
  invocation's events either way, M97 §6.1), which a computer sends only when
  it is said, since an older server closes the session on an event it does
  not know. It says too where the computer stands against this server
  (`caps.computer.standing`, `FermixCore.Computers.Versions` of the
  `app_version` its hello named, M97 §3.4) and what this server speaks
  (`caps.computer.versions`: its engine version and its companion and
  management ranges); the desktop's peer is told the standing, and its
  companion family refuses chat to a computer past the window
  (`settings_only`), which keeps its link for settings alone.

  ## A phone's call

  A phone's call channel (M87; `call_open`, `call_line`, `call_audio`,
  `call_frame`, the camera's picture, and `call_close`) belongs to the
  device's `Mobile.Call`, which this session
  hands every call event to and never waits on. The call's frames come back
  as `{:mobile_call, call, :control | :stop | :audio, event}` and are written
  ahead of everything else queued here, controls first, then audio, so a large
  media or companion chunk never sits between the phone and its call. A
  `:stop` (the call's `playback_stop` line) drops that call's audio queued
  here before it, which the stop would otherwise overtake. While a call is
  attached to this session (from its `call_attached` until its `call_close`, or
  the call's end), the media this primary pushes to the phone waits, bounded,
  and goes after the call; text still flows. A call that ends without its
  `call_close` (it crashed) is closed `ended` here. A session its call found
  silent mid-stream (`{:mobile_call_silent, call}`) closes `1000`, so a phone
  whose link is alive reconnects and resumes. A phone's `hello_ack` says
  whether this primary serves calls (`caps.call`).

  ## Lanes

  What a session writes rides one of three lanes (`Mobile.Lanes`, M97 §5.1),
  one mechanism for a phone's session and a desktop's. Each read writes the
  live lane first: the call frames above, at most 128, the rest at the next
  read. A read for a bulk frame (a media push, a media fetch's step, a
  snapshot chunk) then writes up to 16 interactive events queued behind it,
  in the order they came, and only then its one bulk frame; past 16 the rest
  wait for the next read, so a flood of chat still lets one bulk frame
  through per 16. Bulk frames go one per read, in the order they came. Those
  two lanes queue nowhere but in the carrier's mailbox: their producers bound
  them (a desktop's forwarded calls and channels, the snapshot stream's
  catch-up every 16 chunks, the media fetch queue), and the carrier's memory
  bound past that. Each logical event is encoded whole, so an `event_part`
  run is never split, and `seq` rises by one per frame in the order written.

  ## A phone's list channel

  A phone's `hello_ack` says `caps.lists: true` (M85 E4): it may open one list
  channel, the companion family a desktop's tunnel uses. Its first
  `companion_open` starts its peer (`Desktop.Peer` with the companion family
  alone, `kind: :phone`, registered apart from the desktops'), which this
  session hands each of its companion events, as a desktop's; a phone that
  never opens one runs none. The channel ends with the session. Once the
  channel has pulled the index (`:list_channel_draws`), each `msg` and
  `command` this session queues says it draws lists, so the phone's turns are
  told their lists are drawn under the reply. The `hello_ack` says
  `caps.trips: true` too (M89 §06): the channel serves the owner's trips from
  companion 8, and once it has pulled the trips index (`:trip_channel_draws`)
  a session at mobile 3, the version that sends their block, says it draws
  trips.

  ## Blocks under a reply (mobile 3)

  Every frame is encoded after the one filter a reply's blocks leave by
  (`FermixCore.ReplyBlocks.for_session/4`): a `text_done`, a `row` and each
  message of a `history_page` keep only the block types this session's
  negotiated version carries, so a phone at mobile 2 is sent only `places`
  and `checklists`. Each `msg` and `command` this session queues says what
  it draws by the same answer (`ReplyBlocks.drawn_types/3`): its lists once
  its list channel pulled the index, its events from mobile 3.

  ## Web Push (mobile 3)

  A session at `Protocol.web_push_version/0` or later, on a daemon whose
  phone channel holds the home's Web Push key (`:web_push_key`, its public
  text), names `webpush` in `caps.push` and `pair_approved.push` and sends
  the key as `hello_ack.push_key`; a session at 2, or one with no key, is
  told exactly what it was before (M99 §14). A phone has one push
  registration, written whole: `push_subscribe` stores its subscription,
  only when it differs from the row this session holds (the one its hello
  read, kept as each write answers), `push_register` an APNs token with no
  subscription, and `push_unregister` neither.
  """

  require Logger
  require FermixChannels.Mobile.Lanes

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Desktop.Companion, as: DesktopCompanion
  alias FermixChannels.Desktop.Peer, as: DesktopPeer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Gateway.Commands.Registry, as: CommandRegistry
  alias FermixChannels.Home.EnrollmentResponder
  alias FermixChannels.Mobile.Attestation
  alias FermixChannels.Mobile.Call
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Lanes
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.BuildInfo
  alias FermixCore.Companion.Protocol, as: CompanionProtocol
  alias FermixCore.Companion.Timeline
  alias FermixCore.Computers.Store, as: ComputerStore
  alias FermixCore.Computers.Versions
  alias FermixCore.Management.Protocol, as: ManagementProtocol
  alias FermixCore.ReplyBlocks
  alias FermixCore.Setup.ConfigStore

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
  @call_frames ~w(call_line call_audio call_frame call_close)
  @media_pushes ~w(media_begin media_chunk media_end)
  # The call frames written ahead of everything else, per read: a bound on the
  # drain, past which the rest go at the next read.
  @max_call_frames_per_read 128
  # The interactive events written ahead of one bulk frame, per read: past it
  # the rest go at the next read, so a flood of chat still lets bulk through.
  @max_interactive_per_read 16
  @call_classes [:control, :stop, :audio]
  # The media a phone in a call is pushed waits here, up to this; a run past it
  # is dropped whole, and the phone fetches it by its ref once the call ends.
  @max_held_media_bytes 32 * 1_024 * 1_024
  @max_candidates 16
  # The rail's candidate comes last, after this many host candidates, so the
  # list stays within `@max_candidates`.
  @max_host_candidates_with_iroh 15
  # The refusals a phone can act on keep their own word as `error.code`; every
  # other failure is only the daemon's to explain, and is `request_failed`.
  @typed_refusals ~w(
    store_quota_exceeded media_too_large sha256_mismatch announced_hash_mismatch
    size_mismatch size_exceeded unexpected_chunk invalid_field missing_field
    attachment_unavailable unsupported_event push_environment_mismatch invalid_offers
  )a

  # Which of a computer's own events this server takes (M97 §5.3), in a
  # desktop's hello_ack, and that it applies M97 §19.3's rule: a management
  # setting's id names its machine, so it answers its own machine sections.
  @computer_caps %{
    "v" => 1,
    "offers" => true,
    "link_path" => true,
    "invoke" => true,
    "machine_settings" => true
  }

  # A phone's one push registration, written whole (M99 §14): an APNs token
  # is this with its `push_token` set, a Web Push subscription all four.
  @no_registration %{push_token: nil, push_service: nil, push_p256dh: nil, push_auth: nil}

  @type state :: map()

  @typedoc """
  How the carrier closes: a close code and its reason text, the same pair a
  WebSocket close frame carries. `1000` the session's lifetime ran out, or its
  call found it silent, `1002` a protocol error or a stale primary, `1008` the
  handshake deadline, `1009` a message over 65,535 bytes, `1011` a desktop's
  peer failed or did not start,
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
    |> Map.put_new(:web_push_key, nil)
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
    |> Map.put_new(:desktop_peers, FermixChannels.Desktop.Peers)
    |> Map.put_new(:desktop_peer_supervisor, FermixChannels.Desktop.PeerSupervisor)
    |> Map.put_new(:desktop_peer, nil)
    |> Map.put_new(:desktop_peer_ref, nil)
    |> Map.put_new(:phone_families, %{companion: {DesktopCompanion, [kind: :phone]}})
    |> Map.put_new(:draws_lists?, false)
    |> Map.put_new(:draws_trips?, false)
    |> Map.put_new(:calls, FermixChannels.Mobile.Calls)
    |> Map.put_new(:call_supervisor, FermixChannels.Mobile.CallSupervisor)
    |> Map.put_new(:call_options, [])
    |> Map.put_new(:call_hold, nil)
    |> Map.put_new(:held_media, [])
    |> Map.put_new(:held_media_bytes, 0)
    |> Map.put_new(:dropped_media, MapSet.new())
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
      lanes_first(event_lane(event), state, &push_fanout_event(event, &1))
    end
  end

  def handle_info(:mobile_media_step, %{phase: :ready} = state) do
    if session_expired?(state) do
      session_expired(state)
    else
      lanes_first(:bulk, state, &media_step/1)
    end
  end

  def handle_info({:mobile_call, call, class, event}, %{phase: :ready} = state)
      when is_pid(call) and class in @call_classes and is_map(event) do
    if session_expired?(state) do
      session_expired(state)
    else
      push_call_frames([{call, class, event}], state)
    end
  end

  def handle_info({:DOWN, ref, :process, _call, _reason}, %{call_hold: %{ref: ref}} = state),
    do: call_gone(state)

  # The call this session carries heard nothing from it mid-stream and let it
  # go (`Mobile.Call`): the link died without closing, or a phone that is in
  # fact there reconnects and resumes. Another call's word is not this one's.
  def handle_info({:mobile_call_silent, call}, %{call_hold: %{call: call}} = state)
      when is_pid(call),
      do: {:stop, :call_link_silent, {1000, "call link silent"}, state}

  def handle_info({:mobile_call_silent, call}, state) when is_pid(call), do: {:ok, state}

  # The phone's list channel pulled the index: its turns from now on say they
  # draw lists (moduledoc).
  def handle_info(:list_channel_draws, state), do: {:ok, %{state | draws_lists?: true}}

  # It pulled the trips index: from mobile 3 its turns say they draw trips.
  def handle_info(:trip_channel_draws, state), do: {:ok, %{state | draws_trips?: true}}

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
    |> Map.put_new(:iroh_hints, fn -> Helper.hints(iroh_helper) end)
    |> Map.put_new(:relay_list_acknowledged, fn -> Helper.relays_acknowledged(iroh_helper) end)
    |> Map.put_new(:close_iroh_peer, &Helper.close(iroh_helper, &1))
    |> Map.put_new(:pending_approvals, &Approvals.pending(Approvals.server(), &1, :mobile))
    |> Map.put_new(:media_descriptor, &Timeline.media_descriptor/2)
    |> Map.put_new(:event_router, &EventRouter.route/3)
    |> Map.put_new(:run_request, &Task.Supervisor.start_child(FermixCore.TaskSupervisor, &1))
    |> Map.put_new(:record_engine_version, engine_recorder(state.identity_root))
    |> put_peer_dependencies()
    |> put_call_dependencies()
  end

  # A phone's call: the device's `Mobile.Call`, found in the session's
  # registry of calls.
  defp put_call_dependencies(state) do
    call_opts = [
      calls: state.calls,
      call_supervisor: state.call_supervisor,
      call_options: state.call_options
    ]

    state
    |> Map.put_new(:open_call, &Call.open(&1, &2, &3, &4, call_opts))
    |> Map.put_new(:route_call, &Call.deliver(&1, &2, &3, &4, &5, call_opts))
    |> Map.put_new(:end_call, &Call.notify(state.calls, &1, &2))
    |> Map.put_new(:call_caps, &Call.caps/1)
  end

  # The home the session's identity is read from: a test's root, or this
  # engine's own home.
  defp engine_recorder(root) do
    fn device_id, version, at ->
      ComputerStore.record(root || ConfigStore.fermix_home(), device_id, %{
        engine_version: version,
        seen_at: at
      })
    end
  end

  # A desktop's peer.
  defp put_peer_dependencies(state) do
    supervisor = state.desktop_peer_supervisor

    state
    |> Map.put_new(:start_desktop_peer, &DesktopPeer.start(supervisor, &1))
    |> Map.put_new(:deliver_desktop_event, &DesktopPeer.deliver/2)
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
         :ok <- record_engine_version(event, state),
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

    # A call this copy still holds for the phone cannot resume here.
    :ok =
      state.end_call.(value(state.authenticated_device, :device_id), {:call_end, :stale_primary})

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

  # A phone's first companion event starts its list peer (moduledoc).
  defp dispatch_ready(%{type: type} = event, state) do
    if session_kind(state) == :phone and DesktopPeer.family_event?(type),
      do: open_list_peer(event, state),
      else: dispatch_event(event, state)
  end

  defp open_list_peer(event, state) do
    case start_desktop_peer(state, :phone) do
      {:ok, state} -> deliver_to_peer(event, state.desktop_peer, state)
      {:error, reason} -> {:close, {:desktop_peer_unavailable, reason}, state}
    end
  end

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
           {:ok, state} <- persist_hello(state, authenticated_id, hello_facts(payload, state)) do
        attach_authenticated(event, state, authenticated_id)
      end
    else
      {:error, :identity_mismatch, %{state | client_seq: event.seq}}
    end
  end

  defp accept_hello(_event, state), do: {:error, :hello_required, state}

  # A desktop's engine version, for the home's record of its computers, which
  # says where each stands against this server (M97 §3.4). It never refuses
  # the desktop: a record that fails is said in the log, and the next hello
  # records it again.
  defp record_engine_version(%{payload: payload}, %{peer_kind: :desktop} = state) do
    case state.record_engine_version.(
           state.device_id,
           payload["app_version"],
           state.wall_clock.()
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "the engine version of desktop #{state.device_id} could not be recorded: " <>
            inspect(reason)
        )
    end
  end

  defp record_engine_version(_event, _state), do: :ok

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

  # What a hello moves on its row: the relay list revision it names (M62
  # §3.1), and a computer's system when its row names none or another (M97
  # §3.2). A phone's row keeps the platform its attestation proved.
  defp hello_facts(payload, state) do
    facts = maybe_put(%{}, :relay_list_rev, payload["relay_list_rev"])

    case {session_kind(state), payload["platform"]} do
      {:desktop, platform} when is_binary(platform) -> computer_platform(facts, platform, state)
      _phone_or_unsaid -> facts
    end
  end

  defp computer_platform(facts, platform, state) do
    case value(state.authenticated_device, :platform) do
      ^platform ->
        facts

      nil ->
        Map.put(facts, :platform, platform)

      recorded ->
        Logger.warning(
          "computer #{value(state.authenticated_device, :device_id)} says it runs #{platform}, " <>
            "and its row said #{recorded}; the row now says #{platform}"
        )

        Map.put(facts, :platform, platform)
    end
  end

  # Every hello records when the phone was last seen, and what `hello_facts/2`
  # read from it; the store writes only what changed. A newly acknowledged
  # relay list revision can widen the relays the daemon's endpoint may use.
  defp persist_hello(state, device_id, facts) do
    wall_clock = Map.get(state, :wall_clock, &DateTime.utc_now/0)

    case wall_clock.() do
      %DateTime{} = seen_at ->
        attrs = Map.put(facts, :last_seen, seen_at)
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

  defp hello_ack(state, event) do
    state = put_standing(state, event)

    with {:ok, payload} <- build_hello_ack(state),
         {:ok, frames, state} <- encode_event("hello_ack", payload, <<>>, state) do
      {:ok, frames, state}
    end
  end

  # A phone hears what waits for the owner; a desktop's chat, approvals
  # included, rides its companion tunnel, and its peer starts once its
  # hello_ack is ready to go.
  defp after_hello_ack(:phone, frames, state), do: with_pending_approvals(frames, state)

  defp after_hello_ack(:desktop, frames, state) do
    case start_desktop_peer(state, :desktop) do
      {:ok, state} -> {:ok, frames, state}
      {:error, reason} -> {:error, {:desktop_peer_not_started, reason}, state}
    end
  end

  # The primary's side of a desktop's session failed, not the desktop.
  defp desktop_peer_failed(reason, state) do
    Logger.error("mobile desktop session closed: its peer failed: #{inspect(reason)}")
    {:stop, reason, {1011, "desktop peer failed"}, state}
  end

  # A desktop's peer serves every family it sends; a phone's, its list
  # channel alone, registered apart so it is never a connected desktop.
  defp start_desktop_peer(state, kind) do
    opts =
      [device_id: state.device_id, session: self(), connected_since: state.wall_clock.()] ++
        peer_place(kind, state)

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

      payload = %{
        "session_id" => session_id(),
        "min_version" => min_version,
        "max_version" => max_version,
        "profiles" => profiles(state),
        "candidates" => hello_candidates(state),
        "history_head_seq" => history_head,
        "read_up_to_seq" => read_up_to,
        "caps" => caps(state),
        "primary_epoch" => primary_epoch
      }

      {:ok, put_push_key(payload, state)}
    end
  end

  # The key comes exactly when the push list names `webpush` (M99 §14).
  defp put_push_key(payload, state) do
    if web_push?(state), do: Map.put(payload, "push_key", state.web_push_key), else: payload
  end

  # What a session is told it is pushed through: the services that run, and
  # `webpush` from the version that carries it, when the home has its key.
  defp push_services(state) do
    if web_push?(state), do: state.push_services ++ ["webpush"], else: state.push_services
  end

  defp web_push?(%{web_push_key: key, negotiated_version: version}),
    do: is_binary(key) and is_integer(version) and version >= Protocol.web_push_version()

  # A desktop's peer is the desktops', and its families know where the
  # computer stands and whether its hello said it applies M97 §19.3's rule;
  # a phone's runs its list channel alone. The version
  # window is a computer's (`Computers.Versions`): a phone, which its own
  # protocol versions govern, is served as one that stands current.
  defp peer_place(:desktop, state),
    do: [
      registry: state.desktop_peers,
      standing: state.computer_standing,
      machine_settings: Map.get(state, :computer_machine_settings, false)
    ]

  defp peer_place(:phone, state),
    do: [
      registry: DesktopSupervisor.phone_registry(state.desktop_peers),
      standing: :current,
      families: state.phone_families
    ]

  defp caps(state) do
    caps = %{
      "commands" => CommandRegistry.catalog(),
      "media" => true,
      "streaming" => true,
      "turn_done" => true,
      "max_media_bytes" => state.max_media_bytes,
      "push" => push_services(state)
    }

    # Whether this primary serves a call from the phone (M87), and that it
    # takes the phone's list channel (M85 E4) and serves trips on it (M89):
    # a phone's alone, since a desktop's own voice reaches its own computer's
    # socket and its lists ride its companion tunnel. A computer hears which
    # of its own events this server takes (M97 §5.3).
    case session_kind(state) do
      :phone ->
        Map.merge(caps, %{
          "call" => state.call_caps.(state.device_id),
          "lists" => true,
          "trips" => true
        })

      :desktop ->
        Map.put(caps, "computer", computer_caps(state))
    end
  end

  # A computer also hears where it stands against this server and the
  # versions this server speaks (M97 §3.4), so it can say "Update Fermix on
  # this computer" itself.
  defp computer_caps(state) do
    {companion_min, companion_max} = CompanionProtocol.supported_version_range()
    {management_min, management_max} = ManagementProtocol.supported_version_range()

    Map.merge(@computer_caps, %{
      "standing" => Atom.to_string(state.computer_standing),
      "versions" => %{
        "engine" => server_engine_version(state),
        "companion" => [companion_min, companion_max],
        "management" => [management_min, management_max]
      }
    })
  end

  # Where a desktop's engine stands against this one, by the version its
  # hello names (`Computers.Versions`): its chat is refused past the window,
  # by its peer's companion family. A phone has none. Whether its hello says
  # it applies M97 §19.3's rule rides beside it to its peer.
  defp put_standing(state, %{payload: payload}) do
    case session_kind(state) do
      :desktop ->
        standing = Versions.standing(payload["app_version"], server_engine_version(state))
        rule? = get_in(payload, ["caps", "computer", "machine_settings"]) == true

        state
        |> Map.put(:computer_standing, standing)
        |> Map.put(:computer_machine_settings, rule?)

      :phone ->
        state
    end
  end

  defp server_engine_version(state),
    do: Map.get_lazy(state, :engine_version, &BuildInfo.product_version/0)

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
      "push" => push_services(state),
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
  # name, so an Android phone's token is never sent through APNs. It is the
  # phone's whole registration, so it replaces a Web Push subscription.
  defp dispatch_event(%{type: "push_register", payload: payload}, state) do
    case validate_push_environment(payload["environment"], state.push_environment) do
      :ok -> write_registration(%{@no_registration | push_token: payload["apns_token"]}, state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The phone's notifications cannot show, so no push may come (M51 §10).
  defp dispatch_event(%{type: "push_unregister"}, state),
    do: write_registration(@no_registration, state)

  # A phone's Web Push subscription (M99 §14), sent after every hello_ack that
  # names `webpush`: refused by name where this session named none, and
  # written whole, only when it differs from the phone's row.
  defp dispatch_event(%{type: "push_subscribe", payload: payload}, state) do
    with :ok <- web_push_served(state),
         {:ok, registration} <- subscription(payload) do
      if registered?(state.authenticated_device, registration),
        do: {:ok, nil, state},
        else: write_registration(registration, state)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

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

  # A call's events are the device's call's, never a request: no client
  # message id, no ack, no replay. The call answers through its own frames; a
  # call this primary does not hold is answered here.
  defp dispatch_event(%{type: "call_open", payload: payload}, state) do
    %{"call_id" => call_id, "resume" => resume?} = payload
    call_answer(state.open_call.(state.device_id, self(), call_id, resume?), call_id, state)
  end

  defp dispatch_event(%{type: type, payload: payload, bytes: bytes}, state)
       when type in @call_frames do
    answer = state.route_call.(state.device_id, self(), type, payload, bytes)
    call_answer(answer, payload["call_id"], state)
  end

  defp dispatch_event(event, state) do
    case state.event_router.(event, ingress_context(state), router_opts(state)) do
      :ok -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
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
    event = with_draws(event, state)

    fn ->
      case router.(event, context, opts) do
        :ok -> :ok
        {:error, reason} -> report_request_failure(event, context, opts, reason)
      end
    end
  end

  # What this phone draws, by the one answer that also decides which blocks
  # it is sent (`ReplyBlocks.drawn_types/3`): its lists and its trips once its
  # list channel pulled each index (trips from mobile 3), its events from
  # mobile 3.
  defp with_draws(event, state) do
    pulled = for {kind, true} <- [lists: state.draws_lists?, trips: state.draws_trips?], do: kind
    drawn = ReplyBlocks.drawn_types(:mobile, state.negotiated_version, pulled)

    [draws_lists: "checklists", draws_trips: "trips", draws_events: "events"]
    |> Enum.filter(fn {_key, type} -> type in drawn end)
    |> Enum.reduce(event, fn {key, _type}, event -> Map.put(event, key, true) end)
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
  # A phone in a call fetches nothing; what it asked for waits for the call.
  defp media_step(%{call_hold: %{}} = state), do: {:ok, state}

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
  defp push_fanout_event(%{"t" => type} = event, %{call_hold: %{}} = state)
       when type in @media_pushes,
       do: {:ok, hold_media(event, state)}

  defp push_fanout_event(event, state) do
    started = System.monotonic_time()

    with :ok <- for_kind(event, session_kind(state)),
         {:ok, plaintexts} <- encode_plaintexts(event, state) do
      push_encrypted(plaintexts, state)
    else
      {:error, reason} -> drop_event(event, reason, started, state)
    end
  end

  # -- a phone's call ---------------------------------------------------------

  defp call_answer(:ok, _call_id, state), do: {:ok, nil, state}

  defp call_answer({:close, reason}, call_id, state) do
    encode_event_frames(%{"t" => "call_close", "call_id" => call_id, "reason" => reason}, state)
  end

  # -- lanes (M97 §5.1, `Mobile.Lanes`) -----------------------------------------

  # Each read writes the live lane first (the call's frames queued behind it);
  # a read for a bulk frame then writes the interactive events queued behind
  # it, at most @max_interactive_per_read, and only then what it is for.
  defp lanes_first(lane, state, next) do
    case write_call_frames(queued_call_frames([]), state) do
      {:ok, frames, state} -> prepend_frames(frames, interactive_first(lane, state, next))
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  defp interactive_first(:bulk, state, next),
    do: drain_interactive(@max_interactive_per_read, [], state, next)

  defp interactive_first(_lane, state, next), do: next.(state)

  # In the order they came; past the bound the rest wait for the next read.
  defp drain_interactive(0, frames, state, next), do: prepend_frames(frames, next.(state))

  defp drain_interactive(left, frames, state, next) do
    receive do
      {:mobile_event, %{"t" => type} = event} when Lanes.interactive?(type, event) ->
        write_interactive(event, left, frames, state, next)

      {:mobile_event, %{type: type, payload: payload} = event}
      when Lanes.interactive?(type, payload) ->
        write_interactive(event, left, frames, state, next)
    after
      0 -> prepend_frames(frames, next.(state))
    end
  end

  defp write_interactive(event, left, frames, state, next) do
    case push_fanout_event(event, state) do
      {:ok, state} -> drain_interactive(left - 1, frames, state, next)
      {:push, more, state} -> drain_interactive(left - 1, frames ++ more, state, next)
      stop -> prepend_frames(frames, stop)
    end
  end

  # An event the lane table does not name rides no lane: it is dropped by name
  # where it is encoded (`push_fanout_event/2`).
  defp event_lane(event) do
    case Lanes.lane(event_type(event), event_header(event)) do
      {:ok, lane} -> lane
      {:error, {:no_lane, _type}} -> :none
    end
  end

  defp event_header(%{payload: payload}) when is_map(payload), do: payload
  defp event_header(event), do: event

  defp push_call_frames(first, state) do
    case write_call_frames(queued_call_frames(first), state) do
      {:ok, frames, state} -> reply(frames, state)
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  # Controls first, then audio, each in the order it came; `first` is the one
  # this read is for, and came before everything drained.
  defp queued_call_frames(first) do
    {audio, controls} =
      (first ++ drain_call_frames(@max_call_frames_per_read))
      |> drop_overtaken()
      |> Enum.split_with(fn {_call, class, _event} -> class == :audio end)

    controls ++ audio
  end

  defp drain_call_frames(0), do: []

  defp drain_call_frames(remaining) do
    receive do
      {:mobile_call, call, class, event}
      when is_pid(call) and class in @call_classes and is_map(event) ->
        [{call, class, event} | drain_call_frames(remaining - 1)]
    after
      0 -> []
    end
  end

  # Written controls first, a call's playback stop would overtake that call's
  # audio queued before it, audio the stop made stale: it goes here. Walked
  # from the newest, so a stop sees everything queued before it.
  defp drop_overtaken(queued) do
    {kept, _stopped} =
      queued
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn {call, class, _event} = frame, {kept, stopped} ->
        cond do
          class == :stop -> {[frame | kept], MapSet.put(stopped, call)}
          class == :audio and MapSet.member?(stopped, call) -> {kept, stopped}
          true -> {[frame | kept], stopped}
        end
      end)

    kept
  end

  defp write_call_frames(queued, state) do
    Enum.reduce_while(queued, {:ok, [], state}, fn {call, _class, event}, {:ok, frames, state} ->
      case call_frame(call, event, state) do
        {:ok, more, state} -> {:cont, {:ok, frames ++ more, state}}
        {:error, _reason, _state} = error -> {:halt, error}
      end
    end)
  end

  # A frame this session cannot encode is dropped as a fan-out event is; one
  # it cannot encrypt ends the session, as any frame's does.
  defp call_frame(call, event, state) do
    case encode_plaintexts(event, state) do
      {:ok, plaintexts} ->
        with {:ok, frames, state} <- encrypt_batch(plaintexts, state) do
          after_call_frame(event, call, frames, state)
        end

      {:error, reason} ->
        {:ok, state} = drop_event(event, reason, System.monotonic_time(), state)
        {:ok, [], state}
    end
  end

  # From its `call_attached` until its `call_close`, or the call's end, the
  # call holds this phone's media.
  defp after_call_frame(%{"t" => "call_attached", "call_id" => id}, call, frames, state) do
    {:ok, frames, hold_for_call(state, call, id)}
  end

  defp after_call_frame(%{"t" => "call_close", "call_id" => id}, _call, frames, state) do
    case state.call_hold do
      %{call_id: ^id, ref: ref} ->
        Process.demonitor(ref, [:flush])
        release_held_media(%{state | call_hold: nil}, frames)

      _other_or_none ->
        {:ok, frames, state}
    end
  end

  defp after_call_frame(_event, _call, frames, state), do: {:ok, frames, state}

  defp hold_for_call(%{call_hold: %{call: call, call_id: id}} = state, call, id), do: state

  defp hold_for_call(state, call, id) do
    if state.call_hold, do: Process.demonitor(state.call_hold.ref, [:flush])
    %{state | call_hold: %{call: call, call_id: id, ref: Process.monitor(call)}}
  end

  # A call that exited without its `call_close` (a crash, a kill) is closed
  # here, so the phone is not left in a call nobody holds; its media follows.
  defp call_gone(%{call_hold: %{call_id: id}} = state) do
    close = %{"t" => "call_close", "call_id" => id, "reason" => "ended"}

    case encode_event_frames(close, %{state | call_hold: nil}) do
      {:ok, frames, state} -> release_media(state, frames)
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  defp release_media(state, frames) do
    case release_held_media(state, frames) do
      {:ok, frames, state} -> reply(frames, state)
      {:error, reason, state} -> protocol_error(reason, state)
    end
  end

  # The media held for the call goes now, in order, and a fetch it held
  # resumes.
  defp release_held_media(state, frames) do
    held = Enum.reverse(state.held_media)
    state = %{state | held_media: [], held_media_bytes: 0, dropped_media: MapSet.new()}
    :ok = schedule_media_step(state)

    Enum.reduce_while(held, {:ok, frames, state}, fn event, {:ok, frames, state} ->
      case call_frame(self(), event, state) do
        {:ok, more, state} -> {:cont, {:ok, frames ++ more, state}}
        {:error, _reason, _state} = error -> {:halt, error}
      end
    end)
  end

  defp hold_media(%{"ref" => ref} = event, state) do
    size = byte_size(Map.get(event, "bytes", <<>>))

    cond do
      MapSet.member?(state.dropped_media, ref) ->
        forget_dropped(event, state)

      state.held_media_bytes + size > @max_held_media_bytes ->
        drop_held_run(event, state)

      true ->
        %{
          state
          | held_media: [event | state.held_media],
            held_media_bytes: state.held_media_bytes + size
        }
    end
  end

  defp forget_dropped(%{"t" => "media_end", "ref" => ref}, state),
    do: %{state | dropped_media: MapSet.delete(state.dropped_media, ref)}

  defp forget_dropped(_event, state), do: state

  defp drop_held_run(%{"t" => type, "ref" => ref}, state) do
    Logger.warning(
      "mobile session dropped media #{ref} pushed during a call: past the " <>
        "#{@max_held_media_bytes}-byte hold; the phone fetches it by its ref"
    )

    kept = Enum.reject(state.held_media, &(&1["ref"] == ref))
    bytes = Enum.reduce(kept, 0, &(&2 + byte_size(Map.get(&1, "bytes", <<>>))))

    dropped =
      if type == "media_end", do: state.dropped_media, else: MapSet.put(state.dropped_media, ref)

    %{state | held_media: kept, held_media_bytes: bytes, dropped_media: dropped}
  end

  defp prepend_frames([], result), do: result
  defp prepend_frames(frames, {:ok, state}), do: {:push, frames, state}
  defp prepend_frames(frames, {:push, more, state}), do: {:push, frames ++ more, state}
  defp prepend_frames(frames, {:stop, why, close, state}), do: {:stop, why, close, frames, state}

  defp prepend_frames(frames, {:stop, why, close, more, state}),
    do: {:stop, why, close, frames ++ more, state}

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

  # Every frame this session writes is encoded here, after the one filter a
  # reply's blocks leave by: a `text_done`, a `row` and a history page's
  # messages keep only the block types this session's version carries
  # (`ReplyBlocks.for_session/4`; mobile 2 is sent no `events`).
  defp encode_plaintexts(event, state) do
    version = Map.get(state, :negotiated_version)

    with {:ok, type, payload, bytes} <- normalize_logical_event(event) do
      call_encoder(
        state.encode_server,
        type,
        ReplyBlocks.for_session(type, payload, :mobile, version),
        state.server_seq + 1,
        bytes,
        version
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

  # A desktop also hears where it may dial this engine directly (an Always
  # On server's tailnet addresses at its fixed port, `Iroh.Hints`), on the
  # rail's route; a phone's candidates are as they were.
  defp hello_candidates(state) do
    candidates = current_candidates(state)

    case session_kind(state) do
      :desktop -> with_hints(candidates, state.iroh_hints.())
      :phone -> candidates
    end
  end

  defp with_hints(candidates, []), do: candidates

  defp with_hints(candidates, hints) do
    Enum.map(candidates, fn
      %{"kind" => "iroh"} = iroh -> Map.put(iroh, "addrs", hints)
      host -> host
    end)
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

  # The row the store answers is the one the next `push_subscribe` is held to.
  defp write_registration(registration, state) do
    case state.update_device.(state.device_store, state.device_id, registration) do
      {:ok, device} -> {:ok, nil, %{state | authenticated_device: device}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp web_push_served(state),
    do: if(web_push?(state), do: :ok, else: {:error, :webpush_unavailable})

  # The codec held both keys to canonical base64url of their sizes.
  defp subscription(%{"service" => service, "token" => token} = payload) do
    with {:ok, public} <- decoded_key(payload, "p256dh"),
         {:ok, secret} <- decoded_key(payload, "auth") do
      {:ok, %{push_token: token, push_service: service, push_p256dh: public, push_auth: secret}}
    end
  end

  defp decoded_key(payload, field) do
    case Base.url_decode64(payload[field], padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_field, field}}
    end
  end

  defp registered?(%{} = device, registration),
    do: Enum.all?(registration, fn {field, stored} -> value(device, field) == stored end)

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
