defmodule FermixCore.Management.Mobile do
  @moduledoc """
  The `mobile.*` methods: pairing a phone, the paired devices, and the phone
  channel's status (M51 management pairing).

  A stateless adapter. The pairing state has one owner, the phone channel's
  pairing manager, and it lives in the channels app, which this app does not
  compile against. So every call goes by function name to the provider that
  app registers at `:mobile_management_provider`, and this module turns the
  atom-keyed facts it answers with into the string-keyed wire and owns every
  sentence on it.

  Pairing is a polled session, not a job: `mobile.pair.start` opens the window
  and answers at once, and the pane reads `mobile.pair.get` until the session
  is terminal. A refusal that has something to tell the operator is a `failed`
  session view carrying the daemon's sentence; only a window already open is
  the `busy` envelope. A provider that is missing, or a call that exits,
  answers `unavailable` for the `mobile` capability, with the reason in the
  daemon log and never on the wire.
  """

  alias FermixCore.Auth.Redaction

  require Logger

  @capability "mobile"
  @operation "mobile.pair"
  # The two bounds the adapter asserts rather than trusts, both published: the
  # device list's row count and the pairing link's length.
  @max_devices 64
  @max_uri_bytes 2_048
  @states ~w(awaiting_scan awaiting_decision approved denied expired cancelled failed)a
  @outcome_reasons ~w(denied timeout cancelled)a
  @build_roles ~w(release development)a
  @listener_states ~w(ready down)a
  @mdns_states ~w(advertising disabled down)a
  @credential_states ~w(ready missing)a
  # The channel is off, it could not start this boot, or it was turned on
  # after boot and has not started yet. None is a defect of the call, so none
  # is logged here.
  @channel_down ~w(mobile_disabled mobile_surface_refused mobile_not_started)a

  @off_sentence "The mobile channel is turned off."
  @surface_sentence "The mobile channel could not start this boot. See the daemon log."
  @not_started_sentence "The mobile channel has not started yet. Restart Fermix to apply the change."
  @identity_sentence "The gateway identity files are incomplete; nothing was regenerated."
  @listener_sentence "The phone listener could not start. See the daemon log."
  @device_store_sentence "The paired-device list could not be read. See the daemon log."
  @start_sentence "The pairing window could not be opened. See the daemon log."
  @rate_limited_sentence "Too many failed connection attempts. Start pairing again."
  @disconnected_sentence "The phone disconnected before you decided. Start pairing again."
  @no_attestation_sentence "This phone sent no secure-hardware proof."
  @no_request_sentence "No phone is waiting for a decision."
  @unknown_device_sentence "No paired phone has that id."

  @type refusal ::
          {:busy, String.t()}
          | {:unavailable, String.t()}
          | {:invalid_params, String.t(), String.t()}
          | {:unknown_pairing_session, String.t()}
  @type result :: {:ok, map()} | {:error, refusal()}

  @doc "Every operator-facing sentence this module can put on the wire."
  @spec sentences() :: [String.t()]
  def sentences do
    [
      @off_sentence,
      @surface_sentence,
      @not_started_sentence,
      @identity_sentence,
      @listener_sentence,
      @device_store_sentence,
      @start_sentence,
      @rate_limited_sentence,
      @disconnected_sentence,
      @no_attestation_sentence,
      @no_request_sentence,
      @unknown_device_sentence
    ]
  end

  @doc """
  The sentence a start refused because the channel is off carries, so a client
  that can name the switch knows when to.
  """
  @spec off_sentence() :: String.t()
  def off_sentence, do: @off_sentence

  @doc "The phone channel as it stands. Answers with the channel off, too."
  @spec status(keyword()) :: result()
  def status(opts \\ []) when is_list(opts) do
    with {:ok, reply} <- call(opts, :status, []), do: status_reply(reply)
  end

  @doc """
  Opens the pairing window and answers with the session plus the pairing link,
  once. A refusal with a sentence is a `failed` view with no session behind it.
  """
  @spec pair_start(keyword()) :: result()
  def pair_start(opts \\ []) when is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_start, []), do: start_reply(reply)
  end

  @doc "One pairing session as it stands."
  @spec pair_get(String.t(), keyword()) :: result()
  def pair_get(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_get, [session_id]),
         do: session_reply(:pair_get, session_id, reply)
  end

  @doc "Approves or denies the phone waiting in one session."
  @spec pair_decide(String.t(), boolean(), keyword()) :: result()
  def pair_decide(session_id, approved, opts \\ [])
      when is_binary(session_id) and is_boolean(approved) and is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_decide, [session_id, approved]),
         do: session_reply(:pair_decide, session_id, reply)
  end

  @doc "Closes one pairing session. A finished session answers as it is."
  @spec pair_cancel(String.t(), keyword()) :: result()
  def pair_cancel(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_cancel, [session_id]),
         do: session_reply(:pair_cancel, session_id, reply)
  end

  @doc "Every paired phone, oldest first."
  @spec devices_list(keyword()) :: result()
  def devices_list(opts \\ []) when is_list(opts) do
    with {:ok, reply} <- call(opts, :devices_list, []), do: devices_reply(reply)
  end

  @doc "Forgets one paired phone."
  @spec devices_revoke(String.t(), keyword()) :: result()
  def devices_revoke(device_id, opts \\ []) when is_binary(device_id) and is_list(opts) do
    with {:ok, reply} <- call(opts, :devices_revoke, [device_id]), do: revoke_reply(reply)
  end

  # One call to the provider, by name, with the remaining options as the
  # provider's own seams. A provider nobody registered, or one without the
  # function, is the capability being absent rather than a crash.
  defp call(opts, function, args) do
    {provider, provider_opts} = Keyword.pop(opts, :provider, registered_provider())
    args = args ++ [provider_opts]

    if callable?(provider, function, length(args)) do
      invoke(provider, function, args)
    else
      Logger.warning("management mobile: no provider serves #{function}/#{length(args)}")
      {:error, {:unavailable, @capability}}
    end
  end

  defp registered_provider, do: Application.get_env(:fermix_core, :mobile_management_provider)

  defp callable?(provider, function, arity) when is_atom(provider) and not is_nil(provider),
    do: Code.ensure_loaded?(provider) and function_exported?(provider, function, arity)

  defp callable?(_provider, _function, _arity), do: false

  # The pairing manager is a process in another app, so a call into it can
  # exit. The reason names that app's internals and stays in the log.
  defp invoke(provider, function, args) do
    {:ok, apply(provider, function, args)}
  catch
    :exit, reason ->
      Logger.error("management mobile: #{function} exited: #{Redaction.format(reason)}")
      {:error, {:unavailable, @capability}}
  end

  defp status_reply({:ok, status}) when is_map(status), do: {:ok, status_view(status)}
  defp status_reply(reply), do: unexpected(:status, reply)

  defp start_reply({:ok, %{session: session, uri: uri}})
       when is_map(session) and is_binary(uri) and byte_size(uri) <= @max_uri_bytes,
       do: {:ok, Map.put(session_view(session), "uri", uri)}

  defp start_reply({:error, :pairing_active}), do: {:error, {:busy, @operation}}
  defp start_reply({:error, :mobile_disabled}), do: failed_start("unavailable", @off_sentence)

  defp start_reply({:error, :mobile_surface_refused}),
    do: failed_start("unavailable", @surface_sentence)

  defp start_reply({:error, :mobile_not_started}),
    do: failed_start("unavailable", @not_started_sentence)

  defp start_reply({:error, :identity_unavailable}),
    do: failed_start("refused", @identity_sentence)

  defp start_reply({:error, :listener_unavailable}),
    do: failed_start("internal_error", @listener_sentence)

  defp start_reply({:error, :device_store_unavailable}),
    do: failed_start("internal_error", @device_store_sentence)

  defp start_reply({:error, reason}) do
    Logger.error("management mobile: the pairing window refused: #{Redaction.format(reason)}")
    failed_start("internal_error", @start_sentence)
  end

  # A success reply carries the pairing link, which is never logged.
  defp start_reply(_reply) do
    Logger.error("management mobile: pair_start answered a shape this daemon does not publish")
    {:error, {:unavailable, @capability}}
  end

  defp session_reply(_function, _session_id, {:ok, session}) when is_map(session),
    do: {:ok, session_view(session)}

  defp session_reply(_function, session_id, {:error, :unknown_pairing_session}),
    do: {:error, {:unknown_pairing_session, session_id}}

  defp session_reply(_function, _session_id, {:error, :request_missing}),
    do: {:error, {:invalid_params, "session_id", @no_request_sentence}}

  defp session_reply(_function, _session_id, {:error, reason}) when reason in @channel_down,
    do: {:error, {:unavailable, @capability}}

  defp session_reply(function, _session_id, reply), do: unexpected(function, reply)

  defp devices_reply({:ok, devices}) when is_list(devices) and length(devices) <= @max_devices,
    do: {:ok, %{"devices" => Enum.map(devices, &device_view/1)}}

  defp devices_reply(reply), do: unexpected(:devices_list, reply)

  defp revoke_reply({:ok, %{device_id: device_id}}) when is_binary(device_id),
    do: {:ok, %{"device_id" => device_id, "revoked" => true}}

  defp revoke_reply({:error, :device_not_found}),
    do: {:error, {:invalid_params, "device_id", @unknown_device_sentence}}

  defp revoke_reply({:error, reason}) when reason in @channel_down,
    do: {:error, {:unavailable, @capability}}

  defp revoke_reply(reply), do: unexpected(:devices_revoke, reply)

  # A refusal the contract does not name is a defect between the two apps. The
  # reason is logged; a reply that is not a refusal can carry a device name or
  # a code, so only the fact that it was unexpected is.
  defp unexpected(function, {:error, reason}) do
    Logger.error("management mobile: #{function} refused: #{Redaction.format(reason)}")
    {:error, {:unavailable, @capability}}
  end

  defp unexpected(function, _reply) do
    Logger.error("management mobile: #{function} answered a shape this daemon does not publish")
    {:error, {:unavailable, @capability}}
  end

  # Nothing was opened, so there is no session to poll and no link to show.
  defp failed_start(code, sentence) do
    {:ok,
     %{
       "session_id" => nil,
       "state" => "failed",
       "ttl_ms" => nil,
       "request" => nil,
       "outcome" => nil,
       "failure" => failure(code, sentence),
       "uri" => nil
     }}
  end

  defp session_view(session) do
    %{
      "session_id" => session.session_id,
      "state" => state_word(session.state),
      "ttl_ms" => session.ttl_ms,
      "request" => request_view(session.request),
      "outcome" => outcome_view(session.outcome),
      "failure" => failure_view(session.failure)
    }
  end

  defp state_word(state) when state in @states, do: Atom.to_string(state)

  defp request_view(nil), do: nil

  defp request_view(request) when is_map(request) do
    %{
      "device_name" => request.device_name,
      "model" => request.model,
      "platform" => optional_string(request.platform),
      "app_version" => request.app_version,
      "sas" => request.sas,
      "build_role" => build_role(request.build_role),
      "boot_state" => boot_state(request.boot_state),
      "attestation" => attestation(request.attestation)
    }
  end

  defp attestation(:unavailable),
    do: %{"status" => "unavailable", "sentence" => @no_attestation_sentence}

  defp outcome_view(nil), do: nil

  defp outcome_view(%{device_id: device_id}) when is_binary(device_id),
    do: %{"device_id" => device_id, "reason" => nil}

  defp outcome_view(%{reason: reason}) when reason in @outcome_reasons,
    do: %{"device_id" => nil, "reason" => Atom.to_string(reason)}

  defp failure_view(nil), do: nil
  defp failure_view(%{reason: :rate_limited}), do: failure("refused", @rate_limited_sentence)

  defp failure_view(%{reason: :device_disconnected}),
    do: failure("refused", @disconnected_sentence)

  defp failure(code, sentence), do: %{"code" => code, "sentence" => sentence}

  defp status_view(status) do
    %{
      "enabled" => status.enabled,
      "started" => status.started,
      "refused" => status.refused,
      "listener" => listener_view(status.listener),
      "mdns" => mdns_word(status.mdns),
      "tailnet" => %{
        "detected" => status.tailnet.detected,
        "candidates" => status.tailnet.candidates
      },
      "identity" => %{
        "present" => status.identity.present,
        "fingerprint" => status.identity.fingerprint
      },
      "apns" => %{
        "enabled" => status.apns.enabled,
        "credentials" => credentials_word(status.apns.credentials)
      },
      "paired_devices" => status.paired_devices,
      "protocol_version" => status.protocol_version,
      "pairing" => pairing_view(status.pairing)
    }
  end

  defp listener_view(listener) do
    %{
      "status" => listener_word(listener.status),
      "port" => listener.port,
      "bind" => listener.bind,
      "candidates" => listener.candidates
    }
  end

  defp listener_word(status) when status in @listener_states, do: Atom.to_string(status)
  defp mdns_word(mdns) when mdns in @mdns_states, do: Atom.to_string(mdns)

  defp credentials_word(credentials) when credentials in @credential_states,
    do: Atom.to_string(credentials)

  defp pairing_view(nil), do: nil

  defp pairing_view(%{session_id: session_id, state: state}) when is_binary(session_id),
    do: %{"session_id" => session_id, "state" => state_word(state)}

  defp device_view(device) do
    %{
      "device_id" => device.device_id,
      "name" => device.name,
      "model" => device.model,
      "platform" => optional_string(device.platform),
      "signer_role" => build_role(device.signer_role),
      "boot_state" => boot_state(device.boot_state),
      "push_registered" => device.push_registered,
      "created_at" => device.created_at,
      "last_seen" => device.last_seen
    }
  end

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value

  defp build_role(nil), do: nil
  defp build_role(role) when role in @build_roles, do: Atom.to_string(role)

  defp boot_state(nil), do: nil

  defp boot_state(%{verified: verified, locked: locked})
       when is_boolean(verified) and is_boolean(locked),
       do: %{"verified" => verified, "locked" => locked}
end
