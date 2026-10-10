defmodule FermixChannels.Mobile.SocketHandler do
  @moduledoc """
  Bandit-owned WebSocket state for one authenticated mobile device.

  The clear five-byte prelude selects one Noise mode exactly once. The complete
  first wire is then passed to `Mobile.Noise`, which binds that prelude into the
  transcript. Paired sockets are registered only after the authenticated static
  key and the encrypted `hello.device_id` agree.
  """

  @behaviour WebSock

  require Logger

  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixChannels.Mobile.TlsTransport
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Companion.Timeline

  @max_wire_bytes 65_535
  @default_max_media_bytes 20 * 1_024 * 1_024
  @rekey_after_frames 1_048_576
  @session_lifetime_ms 3_600_000
  @handshake_deadline_ms 10_000
  # The phases a peer passes through before it is a paired device or a phone
  # waiting for the owner; the handshake deadline bounds all of them.
  @deadline_phases [:prelude, :await_hello, :await_pair_request]
  @profile_id "main"
  @queued_events ~w(msg command)
  @max_pending_requests 32
  @max_media_fetch_queue 8
  @max_candidates 16
  # The refusals a phone can act on keep their own word as `error.code`; every
  # other failure is only the daemon's to explain, and is `request_failed`.
  @typed_refusals ~w(
    store_quota_exceeded media_too_large sha256_mismatch announced_hash_mismatch
    size_mismatch size_exceeded unexpected_chunk invalid_field missing_field
    attachment_unavailable unsupported_event push_environment_mismatch
  )a

  @type state :: map()

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

  @impl true
  @spec init(keyword() | map()) ::
          {:ok, state()} | {:stop, {:invalid_profile_name, term()}, state()}
  def init(opts) when is_list(opts), do: init(Map.new(opts))

  def init(opts) when is_map(opts) do
    # Bandit runs this in the connection's own process, right after the upgrade.
    :ok = TlsTransport.clear_upgrade_deadline()

    case profile_name(opts) do
      {:ok, profile_name} -> {:ok, opts |> build_state(profile_name) |> arm_handshake_deadline()}
      {:error, reason} -> {:stop, reason, opts}
    end
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
    |> Map.put_new(:media_store, MediaStore)
    |> Map.put_new(:discovery, Discovery)
    |> Map.put_new(:max_media_bytes, @default_max_media_bytes)
    |> Map.put_new(:push_environment, nil)
    |> Map.put_new(:profile_id, @profile_id)
    |> Map.put_new(:device_id, nil)
    |> Map.put_new(:authenticated_device, nil)
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
    |> Map.put_new(:clock, clock(opts))
    |> Map.put_new(:wall_clock, &DateTime.utc_now/0)
    |> put_default_dependencies()
  end

  @impl true
  def handle_in({_payload, opcode: :text}, state) do
    {:stop, :unsupported_frame, {1003, "binary frames required"}, state}
  end

  def handle_in({payload, opcode: :binary}, state) when byte_size(payload) > @max_wire_bytes do
    {:stop, :frame_too_large, {1009, "mobile frame too large"}, state}
  end

  def handle_in({wire, opcode: :binary}, %{phase: :prelude} = state) do
    begin_handshake(wire, state)
  end

  def handle_in({ciphertext, opcode: :binary}, %{phase: :await_hello} = state) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_hello(ciphertext, state)
    end
  end

  def handle_in({ciphertext, opcode: :binary}, %{phase: :await_pair_request} = state) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_pair_request(ciphertext, state)
    end
  end

  def handle_in({ciphertext, opcode: :binary}, %{phase: :await_pair_decision} = state) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_pending_decision(ciphertext, state)
    end
  end

  def handle_in({ciphertext, opcode: :binary}, %{phase: :ready} = state) do
    if session_expired?(state) do
      session_expired(state)
    else
      handle_ready_event(ciphertext, state)
    end
  end

  def handle_in({_ciphertext, opcode: :binary}, state) do
    protocol_error(:invalid_connection_state, state)
  end

  @impl true
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

  def handle_info({:DOWN, ref, :process, _worker, reason}, %{request_ref: ref} = state) do
    client_msg_id = state.request_client_msg_id

    case start_next_request(%{state | request_ref: nil, request_client_msg_id: nil}) do
      {:ok, next} -> finished_request_reply(reason, client_msg_id, next)
      {:error, start_reason, failed_state} -> protocol_error(start_reason, failed_state)
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    cancel_session_timer(state)
    detach_socket(state)
    cancel_uploads(state)
    close_media_transfer(state)
    record_abandoned_pair(reason, state)
    :ok
  end

  defp put_default_dependencies(state) do
    discovery = state.discovery

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
    |> Map.put_new(:current_pair, &PairManager.current/1)
    |> Map.put_new(:submit_pair, &PairManager.submit_request/3)
    |> Map.put_new(:record_pair_failure, &PairManager.record_failure/2)
    |> Map.put_new(:attach_socket, &DeviceRegistry.attach/4)
    |> Map.put_new(:send_device_event, &DeviceRegistry.send_device_event/3)
    |> Map.put_new(:authorize_socket, &DeviceRegistry.authorized?/3)
    |> Map.put_new(:discover, fn -> Discovery.candidates(discovery) end)
    |> Map.put_new(:pending_approvals, &Approvals.pending(Approvals.server(), &1, :mobile))
    |> Map.put_new(:media_descriptor, &Timeline.media_descriptor/2)
    |> Map.put_new(:event_router, &EventRouter.route/3)
    |> Map.put_new(:run_request, &Task.Supervisor.start_child(FermixCore.TaskSupervisor, &1))
  end

  defp begin_handshake(wire, state) do
    case Noise.parse_prelude(wire, :any) do
      {:ok, pattern, _body} -> load_and_continue_handshake(pattern, wire, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp load_and_continue_handshake(pattern, wire, state) do
    case gateway_keypair(state) do
      {:ok, keypair} -> continue_handshake(pattern, wire, keypair, state)
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
      {:push, {:binary, response}, state}
    else
      {:error, reason, failed_state} -> handshake_error(pattern, reason, failed_state)
      {:error, reason} -> handshake_error(pattern, reason, state)
      _unexpected -> handshake_error(pattern, :invalid_handshake_payload, state)
    end
  end

  defp handshake_error(:ikpsk2, reason, state), do: pairing_error(reason, state)
  defp handshake_error(:ik, reason, state), do: protocol_error(reason, state)

  defp handshake_options(:ik, keypair, state) when not is_nil(keypair) do
    {:ok, [static_keypair: keypair], nil, state}
  end

  defp handshake_options(:ikpsk2, keypair, state) when not is_nil(keypair) do
    case state.current_pair.(state.pair_manager) do
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
         Map.merge(state, %{phase: :await_hello, noise: noise, authenticated_device: device})
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
       pairing_sas: sas
     })
     |> scrub_identity_source()
     |> mark_session_start()}
  end

  defp handle_hello(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state),
         {:ok, state} <- accept_hello(event, state),
         {:ok, frames, state} <- hello_ack(state, event),
         {:ok, frames, state} <- with_pending_approvals(frames, state) do
      websocket_reply(frames, state)
    else
      {:error, {:unsupported_protocol_version, direction, version}, state} ->
        refuse_version(direction, version, state)

      {:error, :identity_mismatch, state} ->
        identity_mismatch(state)

      {:error, reason, state} ->
        protocol_error(reason, state)

      {:error, reason} ->
        protocol_error(reason, state)
    end
  end

  defp handle_pair_request(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state) do
      case submit_pair_request(event, state) do
        :ok -> {:ok, stop_handshake_deadline(%{state | phase: :await_pair_decision})}
        {:error, reason} -> pairing_error(reason, state)
      end
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
         {1002, "unsupported mobile protocol version"}, binary_frames(frames), state}

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
      {:ok, frames, state} -> websocket_reply(frames, state)
      {:error, reason, state} -> pairing_error(reason, state)
    end
  end

  defp pending_decision_reply(_event, state),
    do: protocol_error(:pairing_decision_pending, state)

  defp handle_ready_event(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state),
         :ok <- reject_repeated_hello(event, state),
         :ok <- authorize_ready_socket(state) do
      case dispatch_event(event, state) do
        {:ok, reply, state} -> websocket_reply(reply, state)
        {:error, reason, state} -> application_error(reason, state)
        {:error, reason} -> application_error(reason, state)
      end
    else
      {:error, :repeated_hello, failed_state} ->
        terminal_protocol_error(:repeated_hello, failed_state)

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
      with {:ok, state} <- persist_last_seen(state, authenticated_id) do
        attach_authenticated(event, state, authenticated_id)
      end
    else
      {:error, :identity_mismatch, %{state | client_seq: event.seq}}
    end
  end

  defp accept_hello(_event, state), do: {:error, :hello_required, state}

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

  defp persist_last_seen(state, device_id) do
    wall_clock = Map.get(state, :wall_clock, &DateTime.utc_now/0)

    case wall_clock.() do
      %DateTime{} = seen_at -> update_last_seen(state, device_id, seen_at)
      other -> {:error, {:invalid_wall_clock, other}, state}
    end
  end

  defp update_last_seen(state, device_id, seen_at) do
    case state.update_device.(state.device_store, device_id, %{last_seen: seen_at}) do
      {:ok, device} -> {:ok, %{state | authenticated_device: device}}
      {:error, reason} -> {:error, {:last_seen_update_failed, reason}, state}
      other -> {:error, {:invalid_last_seen_update_reply, other}, state}
    end
  end

  defp hello_ack(state, _event) do
    with {:ok, payload} <- build_hello_ack(state),
         {:ok, frames, state} <- encode_event("hello_ack", payload, <<>>, state) do
      {:ok, frames, state}
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
         {:ok, candidates} <- state.discover.() do
      {min_version, max_version} = Protocol.supported_version_range()

      {:ok,
       %{
         "session_id" => session_id(),
         "min_version" => min_version,
         "max_version" => max_version,
         "profiles" => profiles(state),
         "candidates" => encode_candidates(candidates),
         "history_head_seq" => history_head,
         "read_up_to_seq" => read_up_to,
         "caps" => %{
           "commands" => Mobile.command_catalog(),
           "media" => true,
           "streaming" => true,
           "turn_done" => true,
           "max_media_bytes" => state.max_media_bytes
         }
       }}
    end
  end

  defp submit_pair_request(%{type: "pair_request", payload: payload}, state) do
    attrs = %{
      name: payload["device_name"],
      model: payload["model"],
      app_version: payload["app_version"],
      platform: payload["platform"],
      noise_pk: state.pairing_remote_static,
      sas: state.pairing_sas,
      socket_pid: self()
    }

    case state.submit_pair.(state.pair_manager, state.pairing_session_id, attrs) do
      {:ok, _request} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_pair_request(_event, _state), do: {:error, :pair_request_required}

  # The push salt is the device's own, for the key its notifications are
  # encrypted under (see *Push notifications* in the protocol).
  defp handle_pair_decision(session_id, {:ok, device}, %{pairing_session_id: session_id} = state) do
    payload = %{
      "device_id" => value(device, :device_id),
      "candidates" => current_candidates(state),
      "profiles" => profiles(state),
      "push_salt" => Base.encode64(value(device, :apns_key_salt))
    }

    # The owner's decision can come at any time in the window, so the hello
    # that follows gets a deadline of its own, not what was left of the first.
    state =
      start_handshake_deadline(%{state | phase: :await_hello, authenticated_device: device})

    case encode_event("pair_approved", payload, <<>>, state) do
      {:ok, frames, state} -> websocket_reply(frames, state)
      {:error, reason, state} -> protocol_error(reason, state)
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

  defp dispatch_event(%{type: "attach_begin", payload: payload}, state) do
    spec = %{
      attach_id: payload["attach_id"],
      kind: payload["kind"],
      mime: payload["mime"],
      size_bytes: payload["size_bytes"],
      sha256: payload["sha256"],
      name: payload["name"]
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

  defp dispatch_event(%{type: "push_register", payload: payload}, state) do
    with :ok <- validate_push_environment(payload["environment"], state.push_environment),
         result <-
           state.update_device.(state.device_store, state.device_id, %{
             push_token: payload["apns_token"]
           }) do
      case result do
        {:ok, _device} -> {:ok, nil, state}
        {:error, reason} -> {:error, reason, state}
      end
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
         {:ok, media} <- normalize_media_descriptor(descriptor, ref),
         {:ok, blob} <- MediaStore.fetch(state.media_store, ref),
         :ok <- matching_blob_size(blob, media),
         {:ok, io} <- File.open(blob.path, [:read, :binary, :raw]) do
      {:ok,
       %{ref: ref, media: media, io: io, index: 0, sent: 0, hash: :crypto.hash_init(:sha256)}}
    end
  end

  defp normalize_media_descriptor(descriptor, ref) when is_map(descriptor) do
    server_seq = value(descriptor, :server_seq)
    media = value(descriptor, :media)

    with true <- is_integer(server_seq) and server_seq > 0,
         true <- is_map(media),
         {:ok, fields} <- media_fields(media, ref) do
      {:ok, Map.put(fields, :server_seq, server_seq)}
    else
      false -> {:error, :invalid_media_descriptor}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_media_descriptor(_descriptor, _ref), do: {:error, :invalid_media_descriptor}

  defp media_fields(media, ref) do
    fields = %{
      ref: value(media, :ref),
      sha256: value(media, :sha256) || ref,
      kind: value(media, :kind),
      mime: value(media, :mime),
      size_bytes: value(media, :size_bytes),
      filename: value(media, :filename),
      caption: value(media, :caption)
    }

    with :ok <- validate_media_fields(fields, ref) do
      {:ok, fields}
    end
  end

  defp validate_media_fields(fields, ref) do
    valid_required =
      fields.ref == ref and fields.sha256 == ref and nonempty?(fields.kind) and
        nonempty?(fields.mime) and is_integer(fields.size_bytes) and fields.size_bytes >= 0

    if valid_required and optional_nonempty?(fields.filename) and
         optional_nonempty?(fields.caption),
       do: :ok,
       else: {:error, :invalid_media_descriptor}
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp optional_nonempty?(nil), do: true
  defp optional_nonempty?(value), do: nonempty?(value)

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

    case encode_plaintexts(event, state) do
      {:ok, plaintexts} -> push_encrypted(plaintexts, state)
      {:error, reason} -> drop_event(event, reason, started, state)
    end
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
      {:ok, frames, state} -> websocket_reply(frames, state)
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

  # WebSocket pings keep the transport's idle timer alive, so without this a
  # peer that never completes its handshake and hello, or its pair request,
  # holds a TLS session, a process and one of the listener's connection slots
  # indefinitely. The deadline stops when the socket leaves those phases: a
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
    do: {:stop, :handshake_timeout, {1008, "mobile handshake deadline"}, state}

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

  defp websocket_reply(nil, state), do: {:ok, state}
  defp websocket_reply([], state), do: {:ok, state}
  defp websocket_reply([frame], state), do: {:push, {:binary, frame}, state}
  defp websocket_reply(frames, state), do: {:push, binary_frames(frames), state}

  defp binary_frames(frames), do: Enum.map(frames, &{:binary, &1})

  defp send_event_then_stop(type, payload, reason, state) do
    case encode_event(type, payload, <<>>, state) do
      {:ok, frames, state} ->
        {:stop, reason, {4003, "pairing #{reason}"}, binary_frames(frames), state}

      {:error, _encode_reason, state} ->
        {:stop, reason, {4003, "pairing #{reason}"}, state}
    end
  end

  defp application_error(reason, state, client_msg_id \\ nil) do
    case encode_event("error", error_payload(reason, client_msg_id), <<>>, state) do
      {:ok, frames, state} -> websocket_reply(frames, state)
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
        {:stop, reason, {1002, "mobile protocol error"}, binary_frames(frames), state}

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

  defp record_pair_failure(%{pair_failure_recorded?: true} = state), do: state

  defp record_pair_failure(%{pairing_session_id: session_id, pair_manager: manager} = state)
       when is_binary(session_id) do
    case state.record_pair_failure.(manager, session_id) do
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
  # QR's. A failed enumeration must not undo an approved pairing, so it ships
  # none and says so where the operator reads.
  defp current_candidates(state) do
    case state.discover.() do
      {:ok, candidates} ->
        encode_candidates(candidates)

      {:error, reason} ->
        Logger.warning("mobile candidate discovery failed: #{inspect(reason)}")
        []
    end
  end

  # Discovery orders candidates best first, so the cap keeps the likeliest routes.
  defp encode_candidates(candidates) do
    candidates
    |> Enum.take(@max_candidates)
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

  defp gateway_keypair(%{gateway_keypair: keypair}) when not is_nil(keypair), do: {:ok, keypair}

  defp gateway_keypair(state) do
    case state.load_gateway_keypair.(state.identity_root) do
      {:ok, %{private: private, public: public} = keypair}
      when byte_size(private) == 32 and byte_size(public) == 32 ->
        {:ok, keypair}

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
        {:ok, %{private: identity.gateway_private_key, public: identity.gateway_public_key}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
