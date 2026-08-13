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
  alias FermixCore.Mobile.Store

  @max_wire_bytes 65_535
  @default_max_media_bytes 20 * 1_024 * 1_024
  @rekey_after_frames 1_048_576
  @session_lifetime_ms 3_600_000
  @profile_id "main"

  @type state :: map()

  @impl true
  @spec init(keyword() | map()) ::
          {:ok, state()} | {:stop, {:invalid_profile_name, term()}, state()}
  def init(opts) when is_list(opts), do: init(Map.new(opts))

  def init(opts) when is_map(opts) do
    case profile_name(opts) do
      {:ok, profile_name} -> {:ok, build_state(opts, profile_name)}
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
    |> Map.put_new(:max_media_bytes, @default_max_media_bytes)
    |> Map.put_new(:push_environment, nil)
    |> Map.put_new(:profile_id, @profile_id)
    |> Map.put_new(:device_id, nil)
    |> Map.put_new(:authenticated_device, nil)
    |> Map.put_new(:client_seq, 0)
    |> Map.put_new(:server_seq, 0)
    |> Map.put_new(:negotiated_version, nil)
    |> Map.put_new(:uploads, MapSet.new())
    |> Map.put_new(:session_started_ms, nil)
    |> Map.put_new(:session_timer_ref, nil)
    |> Map.put_new(:session_timer_token, nil)
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

  def handle_in({_ciphertext, opcode: :binary}, %{phase: :await_pair_decision} = state) do
    protocol_error(:pairing_decision_pending, state)
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
      case encode_logical_event(event, state) do
        {:ok, frame, state} -> {:push, {:binary, frame}, state}
        {:error, reason, state} -> protocol_error(reason, state)
        {:error, reason} -> protocol_error(reason, state)
      end
    end
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

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    cancel_session_timer(state)
    detach_socket(state)
    cancel_uploads(state)
    record_abandoned_pair(state)
    :ok
  end

  defp put_default_dependencies(state) do
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
      Protocol.encode_server_frame(type, payload, seq, bytes, version: version)
    end)
    |> Map.put_new(:find_device, &DeviceStore.find_by_noise_pk/2)
    |> Map.put_new(:update_device, &DeviceStore.update/3)
    |> Map.put_new(:current_pair, &PairManager.current/1)
    |> Map.put_new(:submit_pair, &PairManager.submit_request/3)
    |> Map.put_new(:record_pair_failure, &PairManager.record_failure/2)
    |> Map.put_new(:attach_socket, &DeviceRegistry.attach/4)
    |> Map.put_new(:authorize_socket, &DeviceRegistry.authorized?/3)
    |> Map.put_new(:discover, &Discovery.discover/0)
    |> Map.put_new(:media_descriptor, &Store.media_descriptor/2)
    |> Map.put_new(:event_router, &EventRouter.route/3)
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
         {:ok, frame, state} <- hello_ack(state, event) do
      {:push, {:binary, frame}, state}
    else
      {:error, :identity_mismatch, state} -> identity_mismatch(state)
      {:error, reason, state} -> protocol_error(reason, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

  defp handle_pair_request(ciphertext, state) do
    with {:ok, event, state} <- decrypt_event(ciphertext, state),
         {:ok, state} <- consume_event(event, state) do
      case submit_pair_request(event, state) do
        :ok -> {:ok, %{state | phase: :await_pair_decision}}
        {:error, reason} -> pairing_error(reason, state)
      end
    else
      {:error, reason, state} -> pairing_error(reason, state)
      {:error, reason} -> protocol_error(reason, state)
    end
  end

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

      {:error, reason, state} -> protocol_error(reason, state)
      {:error, reason} -> protocol_error(reason, state)
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
    case :erlang.fun_info(state.decode_client, :arity) do
      {:arity, 1} -> state.decode_client.(plaintext)
      {:arity, 2} -> state.decode_client.(plaintext, max_media_bytes: state.max_media_bytes)
    end
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
        {:ok,
         Map.merge(state, %{
           phase: :ready,
           device_id: device_id
         })}

      {:error, reason} ->
        {:error, {:registry_attach_failed, reason}, state}
    end
  end

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
         {:ok, frame, state} <- encode_event("hello_ack", payload, <<>>, state) do
      {:ok, frame, state}
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

  defp handle_pair_decision(session_id, {:ok, device}, %{pairing_session_id: session_id} = state) do
    payload = %{
      "device_id" => value(device, :device_id),
      "candidates" => current_candidates(),
      "profiles" => profiles(state)
    }

    state = %{state | phase: :await_hello, authenticated_device: device}

    case encode_event("pair_approved", payload, <<>>, state) do
      {:ok, frame, state} -> {:push, {:binary, frame}, state}
      {:error, reason, state} -> protocol_error(reason, state)
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
    media_frames(payload["ref"], state)
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

  defp dispatch_event(event, state) do
    context = %{transport: :mobile, authenticated_device_id: state.device_id}

    event_sink = fn
      {:device, device_id}, logical ->
        DeviceRegistry.send_device_event(state.device_registry, device_id, logical)

      {:profile, profile_id}, logical ->
        DeviceRegistry.send_profile_event(state.device_registry, profile_id, logical)
        :ok
    end

    opts = [
      media_server: state.media_store,
      request_coordinator: state.request_coordinator,
      event_sink: event_sink
    ]

    case state.event_router.(event, context, opts) do
      :ok -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
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

    with {:ok, frame, state} <- encode_logical_event(logical, state) do
      {:ok, [frame], state}
    end
  end

  defp attach_end_reply(attach_id, state) do
    state = %{state | uploads: MapSet.delete(state.uploads, attach_id)}
    logical = %{"t" => "attach_status", "attach_id" => attach_id, "status" => "present"}

    with {:ok, frame, state} <- encode_logical_event(logical, state) do
      {:ok, [frame], state}
    end
  end

  defp media_frames(ref, state) do
    with {:ok, descriptor} <- state.media_descriptor.(state.profile_id, ref),
         {:ok, media} <- normalize_media_descriptor(descriptor, ref),
         {:ok, blob} <- MediaStore.fetch(state.media_store, ref),
         {:ok, bytes} <- File.read(blob.path),
         :ok <- validate_media_content(bytes, blob, media) do
      logical = media_events(ref, bytes, media)

      case encode_events(logical, state) do
        {:ok, frames, state} -> {:ok, frames, state}
        {:error, reason, state} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
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

  defp validate_media_content(bytes, blob, media) do
    actual_digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    actual_size = byte_size(bytes)

    if actual_digest == media.sha256 and actual_size == media.size_bytes and
         value(blob, :size_bytes) == media.size_bytes,
       do: :ok,
       else: {:error, :media_descriptor_mismatch}
  end

  defp media_events(ref, bytes, media) do
    begin_event =
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

    chunks =
      bytes
      |> chunk_binary(Protocol.max_raw_chunk_bytes(), [])
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        %{"t" => "media_chunk", "ref" => ref, "index" => index, "bytes" => chunk}
      end)

    [begin_event | chunks] ++ [%{"t" => "media_end", "ref" => ref, "sha256" => media.sha256}]
  end

  defp chunk_binary(<<>>, _size, acc), do: Enum.reverse(acc)

  defp chunk_binary(bytes, size, acc) when byte_size(bytes) <= size,
    do: Enum.reverse([bytes | acc])

  defp chunk_binary(bytes, size, acc) do
    <<chunk::binary-size(size), rest::binary>> = bytes
    chunk_binary(rest, size, [chunk | acc])
  end

  defp encode_events(events, state) do
    Enum.reduce_while(events, {:ok, [], state}, fn event, {:ok, frames, state} ->
      case encode_logical_event(event, state) do
        {:ok, frame, state} -> {:cont, {:ok, [frame | frames], state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
        {:error, reason} -> {:halt, {:error, reason, state}}
      end
    end)
    |> then(fn
      {:ok, frames, state} -> {:ok, Enum.reverse(frames), state}
      error -> error
    end)
  end

  defp encode_logical_event(event, state) do
    with {:ok, type, payload, bytes} <- normalize_logical_event(event) do
      encode_event(type, payload, bytes, state)
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

  defp encode_event(type, payload, bytes, state) do
    seq = state.server_seq + 1

    with {:ok, state} <- maybe_rekey(state, :send),
         {:ok, plaintext} <-
           call_encoder(
             state.encode_server,
             type,
             payload,
             seq,
             bytes,
             Map.get(state, :negotiated_version)
           ),
         {:ok, ciphertext, noise} <- state.encrypt.(state.noise, plaintext) do
      {:ok, ciphertext, %{state | noise: noise, server_seq: seq}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp call_encoder(encoder, type, payload, seq, bytes, version) do
    case :erlang.fun_info(encoder, :arity) do
      {:arity, 3} -> encoder.(type, payload, seq)
      {:arity, 4} -> encoder.(type, payload, seq, bytes)
      {:arity, 5} -> encoder.(type, payload, seq, bytes, version)
    end
  end

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
  defp websocket_reply(frames, state), do: {:push, Enum.map(frames, &{:binary, &1}), state}

  defp send_event_then_stop(type, payload, reason, state) do
    case encode_event(type, payload, <<>>, state) do
      {:ok, frame, state} ->
        {:stop, reason, {4003, "pairing #{reason}"}, [{:binary, frame}], state}

      {:error, _encode_reason, state} ->
        {:stop, reason, {4003, "pairing #{reason}"}, state}

      {:error, _encode_reason} ->
        {:stop, reason, {4003, "pairing #{reason}"}, state}
    end
  end

  defp application_error(reason, state) do
    payload = %{"code" => error_code(reason), "message" => inspect(reason)}

    case encode_event("error", payload, <<>>, state) do
      {:ok, frame, state} -> {:push, {:binary, frame}, state}
      {:error, _encode_reason, state} -> protocol_error(reason, state)
      {:error, _encode_reason} -> protocol_error(reason, state)
    end
  end

  defp pairing_error(reason, state) do
    state = record_pair_failure(state)
    protocol_error({:pairing_failed, reason}, state)
  end

  defp terminal_protocol_error(reason, state) do
    payload = %{"code" => terminal_error_code(reason), "message" => inspect(reason)}

    case encode_event("error", payload, <<>>, state) do
      {:ok, frame, state} ->
        {:stop, reason, {1002, "mobile protocol error"}, [{:binary, frame}], state}

      {:error, _encode_reason, failed_state} ->
        protocol_error(reason, failed_state)

      {:error, _encode_reason} ->
        protocol_error(reason, state)
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

  defp record_abandoned_pair(%{phase: :await_pair_decision} = state),
    do: record_pair_failure(state)

  defp record_abandoned_pair(_state), do: :ok

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
    do: apply(Store, :history_head, [profile])

  defp read_frontier(profile, %{read_frontier: fun}) when is_function(fun, 1), do: fun.(profile)

  defp read_frontier(profile, _state),
    do: apply(Store, :read_frontier, [profile])

  defp current_candidates do
    case Discovery.discover() do
      {:ok, candidates} -> encode_candidates(candidates)
      {:error, _reason} -> []
    end
  end

  defp encode_candidates(candidates) do
    Enum.map(candidates, fn candidate ->
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

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp error_code({:push_environment_mismatch, _configured, _received}),
    do: "push_environment_mismatch"

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
      {nil, state} -> Map.put_new(state, :load_gateway_keypair, &load_gateway_keypair/1)
      {keypair, state} -> Map.put_new(state, :load_gateway_keypair, fn _root -> {:ok, keypair} end)
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
