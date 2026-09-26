defmodule FermixChannels.Mobile.Management do
  @moduledoc """
  Daemon-facing management facade for mobile pairing and paired devices.

  The core daemon resolves this module at runtime, keeping `fermix_core` free
  of a compile-time dependency on channel internals. Pairing secrets appear
  only inside the pairing URI: the v0 verbs render it as a terminal QR, and
  `pair_start/1` returns it once beside the session for a client to render.

  Two families share the builders below. The v0 verbs (`begin_pairing/1`,
  `await_pairing/3`, `decide_pairing/3`, `cancel_pairing/2`, `list_devices/1`,
  `revoke_device/2`, `health/1`) serve the legacy control socket for one more
  release. The v1 provider functions (`pair_start/1`, `pair_get/2`,
  `pair_decide/3`, `pair_cancel/2`, `devices_list/1`, `devices_revoke/2`,
  `status/1`) answer atom-keyed facts; `FermixCore.Management.Mobile` turns
  them into wire JSON and owns every sentence.
  """

  require Logger

  alias Fermix.CLI.TerminalQR
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.MdnsAdvertiser
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Push.Config, as: PushConfig
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor

  @max_wait_ms 120_000
  @max_listed_devices 64
  @v0_device_fields [:device_id, :name, :created_at, :last_seen]
  @open_states [:awaiting_scan, :awaiting_decision]

  @type session_state ::
          :awaiting_scan
          | :awaiting_decision
          | :approved
          | :denied
          | :expired
          | :cancelled
          | :failed
  @type request_view :: %{
          device_name: String.t(),
          model: String.t(),
          platform: nil,
          app_version: String.t(),
          sas: String.t(),
          build_role: nil,
          boot_state: nil,
          attestation: :unavailable
        }
  @type session :: %{
          session_id: String.t(),
          state: session_state(),
          ttl_ms: non_neg_integer() | nil,
          request: request_view() | nil,
          outcome: nil | %{device_id: String.t()} | %{reason: :denied | :timeout | :cancelled},
          failure: nil | %{reason: :rate_limited | :device_disconnected}
        }
  @type device_row :: %{
          device_id: String.t(),
          name: String.t(),
          model: String.t(),
          platform: nil,
          signer_role: nil,
          boot_state: nil,
          push_registered: boolean(),
          created_at: String.t(),
          last_seen: String.t() | nil
        }
  @type status :: %{
          enabled: boolean(),
          started: boolean(),
          refused: boolean(),
          listener: %{
            status: :ready | :down,
            port: :inet.port_number(),
            bind: String.t(),
            candidates: [String.t()]
          },
          mdns: :advertising | :disabled | :down,
          tailnet: %{detected: boolean(), candidates: [String.t()]},
          identity: %{present: boolean(), fingerprint: String.t() | nil},
          apns: %{enabled: boolean(), credentials: :ready | :missing},
          paired_devices: non_neg_integer(),
          protocol_version: pos_integer(),
          pairing: nil | %{session_id: String.t(), state: session_state()}
        }
  @type refusal :: :mobile_disabled | :mobile_surface_refused | :mobile_not_started
  @type start_error ::
          refusal()
          | :pairing_active
          | :identity_unavailable
          | :device_store_unavailable
          | :listener_unavailable
          | term()

  @spec begin_pairing() :: {:ok, map()} | {:error, term()}
  def begin_pairing, do: begin_pairing([])

  @doc false
  @spec begin_pairing(keyword()) :: {:ok, map()} | {:error, term()}
  def begin_pairing(opts) when is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         {:ok, window} <- invoke(opts, :open_pair, &PairManager.open/1, [manager]) do
      finish_pairing_setup(window, manager, opts)
    end
  end

  defp finish_pairing_setup(window, manager, opts) do
    listener = Keyword.get(opts, :listener, Listener)

    result =
      with {:ok, {_bind, port}} <-
             invoke(opts, :listener_info, &Listener.listener_info/1, [listener]),
           {:ok, candidates} <- discover(opts),
           {:ok, uri} <- pairing_uri(window, candidates, port, opts),
           {:ok, qr} <- TerminalQR.render(uri) do
        {:ok,
         %{
           session_id: window.session_id,
           uri: uri,
           qr: qr,
           expires_in_s: expires_in_seconds(window)
         }}
      end

    cleanup_failed_setup(result, window.session_id, manager, opts)
  end

  defp cleanup_failed_setup({:ok, _result} = result, _session_id, _manager, _opts), do: result

  defp cleanup_failed_setup({:error, reason}, session_id, manager, opts) do
    case invoke(opts, :cancel_pair, &PairManager.cancel/2, [manager, session_id]) do
      :ok -> {:error, reason}
      {:error, cleanup} -> {:error, {:pairing_setup_cleanup_failed, reason, cleanup}}
      other -> {:error, {:invalid_pairing_cleanup_reply, reason, other}}
    end
  end

  @spec await_pairing(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def await_pairing(session_id, timeout_ms), do: await_pairing(session_id, timeout_ms, [])

  @doc false
  @spec await_pairing(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_pairing(session_id, timeout_ms, opts)
      when is_binary(session_id) and session_id != "" and
             is_integer(timeout_ms) and timeout_ms in 1..@max_wait_ms and is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         {:ok, request} <-
           invoke(opts, :await_request, &PairManager.await_request/3, [
             manager,
             session_id,
             timeout_ms
           ]) do
      {:ok, Map.take(request, [:name, :model, :sas])}
    end
  end

  @spec decide_pairing(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def decide_pairing(session_id, approved?), do: decide_pairing(session_id, approved?, [])

  @doc false
  @spec decide_pairing(String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide_pairing(session_id, true, opts)
      when is_binary(session_id) and session_id != "" and is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         {:ok, device} <-
           invoke(opts, :approve_pair, &PairManager.approve/2, [manager, session_id]) do
      {:ok,
       %{
         approved: true,
         device_id: value(device, :device_id),
         name: value(device, :name)
       }}
    end
  end

  def decide_pairing(session_id, false, opts)
      when is_binary(session_id) and session_id != "" and is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         :ok <- invoke(opts, :deny_pair, &PairManager.deny/2, [manager, session_id]) do
      {:ok, %{approved: false}}
    end
  end

  @spec cancel_pairing(String.t()) :: {:ok, %{cancelled: true}} | {:error, term()}
  def cancel_pairing(session_id), do: cancel_pairing(session_id, [])

  @doc false
  @spec cancel_pairing(String.t(), keyword()) ::
          {:ok, %{cancelled: true}} | {:error, term()}
  def cancel_pairing(session_id, opts)
      when is_binary(session_id) and session_id != "" and is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         :ok <- invoke(opts, :cancel_pair, &PairManager.cancel/2, [manager, session_id]) do
      {:ok, %{cancelled: true}}
    end
  end

  @spec list_devices() :: {:ok, %{devices: [map()]}} | {:error, term()}
  def list_devices, do: list_devices([])

  @doc false
  @spec list_devices(keyword()) :: {:ok, %{devices: [map()]}} | {:error, term()}
  def list_devices(opts) when is_list(opts) do
    store = Keyword.get(opts, :device_store, DeviceStore)

    with :ok <- require_enabled_config(opts),
         {:ok, devices} <- invoke(opts, :list_devices, &DeviceStore.list/1, [store]) do
      {:ok, %{devices: Enum.map(devices, &public_device/1)}}
    end
  end

  @spec revoke_device(String.t()) :: {:ok, %{device_id: String.t()}} | {:error, term()}
  def revoke_device(device_id), do: revoke_device(device_id, [])

  @doc false
  @spec revoke_device(String.t(), keyword()) ::
          {:ok, %{device_id: String.t()}} | {:error, term()}
  def revoke_device(device_id, opts)
      when is_binary(device_id) and device_id != "" and is_list(opts) do
    with :ok <- require_enabled_config(opts) do
      revoke(device_id, opts)
    end
  end

  @doc "Open one pairing window and return its session with the one-time pairing URI."
  @spec pair_start() :: {:ok, %{session: session(), uri: String.t()}} | {:error, start_error()}
  def pair_start, do: pair_start([])

  @doc false
  @spec pair_start(keyword()) ::
          {:ok, %{session: session(), uri: String.t()}} | {:error, start_error()}
  def pair_start(opts) when is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         :ok <- require_serving(opts),
         {:ok, window} <- open_window(manager, opts),
         {:ok, uri} <- start_uri(window, manager, opts),
         {:ok, record} <- read_session(manager, window.session_id, opts) do
      {:ok, %{session: session_view(record), uri: uri}}
    end
  end

  @doc "The pairing session as it stands, open or retained after it finished."
  @spec pair_get(String.t()) :: {:ok, session()} | {:error, refusal() | term()}
  def pair_get(session_id), do: pair_get(session_id, [])

  @doc false
  @spec pair_get(String.t(), keyword()) :: {:ok, session()} | {:error, refusal() | term()}
  def pair_get(session_id, opts)
      when is_binary(session_id) and session_id != "" and is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         :ok <- require_serving(opts),
         {:ok, record} <- read_session(manager, session_id, opts) do
      {:ok, session_view(record)}
    end
  end

  @doc """
  Approve or deny the phone waiting on this session and return the session.

  A session that already finished answers unchanged: the decision came too
  late, and the view says how the ceremony ended instead.
  """
  @spec pair_decide(String.t(), boolean()) :: {:ok, session()} | {:error, refusal() | term()}
  def pair_decide(session_id, approved?), do: pair_decide(session_id, approved?, [])

  @doc false
  @spec pair_decide(String.t(), boolean(), keyword()) ::
          {:ok, session()} | {:error, refusal() | term()}
  def pair_decide(session_id, approved?, opts)
      when is_binary(session_id) and session_id != "" and is_boolean(approved?) and
             is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         :ok <- require_serving(opts),
         {:ok, record} <- read_session(manager, session_id, opts) do
      decide_record(record, approved?, manager, opts)
    end
  end

  @doc "Close an open session as cancelled; a finished one answers unchanged."
  @spec pair_cancel(String.t()) :: {:ok, session()} | {:error, refusal() | term()}
  def pair_cancel(session_id), do: pair_cancel(session_id, [])

  @doc false
  @spec pair_cancel(String.t(), keyword()) :: {:ok, session()} | {:error, refusal() | term()}
  def pair_cancel(session_id, opts)
      when is_binary(session_id) and session_id != "" and is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    with :ok <- require_enabled_config(opts),
         :ok <- require_serving(opts),
         {:ok, record} <- read_session(manager, session_id, opts) do
      cancel_record(record, manager, opts)
    end
  end

  @doc "Paired devices, oldest first. Empty while the channel is not running."
  @spec devices_list() :: {:ok, [device_row()]} | {:error, term()}
  def devices_list, do: devices_list([])

  @doc false
  @spec devices_list(keyword()) :: {:ok, [device_row()]} | {:error, term()}
  def devices_list(opts) when is_list(opts) do
    if running?(mobile_config(opts), opts), do: listed_rows(opts), else: {:ok, []}
  end

  @doc "Revoke one paired device and close its live socket."
  @spec devices_revoke(String.t()) ::
          {:ok, %{device_id: String.t()}} | {:error, refusal() | :device_not_found | term()}
  def devices_revoke(device_id), do: devices_revoke(device_id, [])

  @doc false
  @spec devices_revoke(String.t(), keyword()) ::
          {:ok, %{device_id: String.t()}} | {:error, refusal() | :device_not_found | term()}
  def devices_revoke(device_id, opts)
      when is_binary(device_id) and device_id != "" and is_list(opts) do
    with :ok <- require_enabled_config(opts),
         :ok <- require_serving(opts) do
      revoke(device_id, opts)
    end
  end

  @doc """
  The mobile channel's facts. With the channel off, the surface refused this
  boot, or the subtree not started yet, it always answers, from configuration,
  the recorded boot refusal and the identity files alone, with no process
  call. While the channel runs, a read that fails is an error rather than an
  empty fact.
  """
  @spec status() :: {:ok, status()} | {:error, term()}
  def status, do: status([])

  @doc false
  @spec status(keyword()) :: {:ok, status()} | {:error, term()}
  def status(opts) when is_list(opts) do
    config = mobile_config(opts)
    refused? = surface_refusal(opts) != :none
    started? = enabled?(config) and serving?(refused?, opts)

    with {:ok, runtime} <- runtime_facts(started?, config, opts) do
      {:ok,
       Map.merge(runtime, %{
         enabled: enabled?(config),
         started: started?,
         refused: refused?,
         identity: identity_fact(opts),
         apns: apns_status(Keyword.get(config, :push, enabled: false)),
         protocol_version: Protocol.protocol_version()
       })}
    end
  end

  @doc "Fail-closed health for the runtime mobile channel adapter."
  @spec health() :: {:ok, map()} | {:error, term()}
  def health, do: health([])

  @doc false
  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(opts) when is_list(opts) do
    config = mobile_config(opts)

    with :ok <- require_enabled(config),
         :ok <- require_started(opts),
         :ok <- require_listener(opts),
         :ok <- require_identity(opts),
         {:ok, count} <- paired_device_count(opts) do
      {:ok, %{listener: :ready, identity: :ready, paired_devices: count}}
    end
  end

  # A refused trust store keeps the whole mobile subtree from starting, so every
  # probe below would report processes that were never meant to run. Name the
  # boot refusal instead of the `:noproc` it causes.
  defp require_started(opts) do
    case surface_refusal(opts) do
      :none -> :ok
      {:error, reason} -> {:error, {:mobile_surface_refused, reason}}
    end
  end

  # The v1 verbs' gate after the flag: a surface refused this boot, then a
  # subtree that has not started yet, each named before any process call.
  defp require_serving(opts) do
    cond do
      surface_refusal(opts) != :none -> {:error, :mobile_surface_refused}
      not subtree_started?(opts) -> {:error, :mobile_not_started}
      true -> :ok
    end
  end

  defp surface_refusal(opts) do
    store = Keyword.get(opts, :device_store, DeviceStore)
    Keyword.get(opts, :refusal, &MobileSupervisor.refusal/1).(store)
  end

  defp running?(config, opts) do
    enabled?(config) and serving?(surface_refusal(opts) != :none, opts)
  end

  defp serving?(true = _refused?, _opts), do: false
  defp serving?(false = _refused?, opts), do: subtree_started?(opts)

  # Settings writes reach the application env at once, but the mobile subtree
  # starts only at boot: an enabled flag is not a running channel. A registered
  # pair manager is, and looking the name up sends no message.
  defp subtree_started?(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)
    opts |> Keyword.get(:whereis, &GenServer.whereis/1) |> apply([manager]) |> is_pid()
  end

  # The identity guard reads the trust store to tell a first pairing from a
  # lost identity, so a store it cannot read is named for the store, not for
  # an identity that may well be intact.
  defp open_window(manager, opts) do
    case invoke(opts, :open_pair, &PairManager.open/1, [manager]) do
      {:ok, window} ->
        {:ok, window}

      {:error, {:identity, {:device_store_unavailable, reason}}} ->
        logged_refusal(:device_store_unavailable, reason)

      {:error, {:identity, reason}} ->
        logged_refusal(:identity_unavailable, reason)

      {:error, {:listener, reason}} ->
        logged_refusal(:listener_unavailable, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The client's sentence says "see the daemon log", so the specific reason
  # is written there before it collapses into the word the client switches on.
  defp logged_refusal(kind, reason) do
    Logger.error("mobile pairing could not start (#{kind}): #{inspect(reason)}")
    {:error, kind}
  end

  defp start_uri(window, manager, opts) do
    result =
      with {:ok, port} <- served_port(opts),
           {:ok, candidates} <- discover(opts) do
        pairing_uri(window, candidates, port, opts)
      end

    cleanup_failed_setup(result, window.session_id, manager, opts)
  end

  defp served_port(opts) do
    listener = Keyword.get(opts, :listener, Listener)

    case invoke(opts, :listener_info, &Listener.listener_info/1, [listener]) do
      {:ok, {_bind, port}} -> {:ok, port}
      {:error, reason} -> logged_refusal(:listener_unavailable, reason)
    end
  end

  defp read_session(manager, session_id, opts) do
    case invoke(opts, :pair_session, &PairManager.session/2, [manager, session_id]) do
      {:ok, record} -> {:ok, record}
      :unknown -> {:error, :unknown_pairing_session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_view_after(manager, session_id, opts) do
    with {:ok, record} <- read_session(manager, session_id, opts) do
      {:ok, session_view(record)}
    end
  end

  defp decide_record(%{status: :awaiting_scan}, _approved?, _manager, _opts),
    do: {:error, :request_missing}

  defp decide_record(%{status: :awaiting_decision} = record, approved?, manager, opts) do
    case decision_call(record.session_id, approved?, manager, opts) do
      :ok -> session_view_after(manager, record.session_id, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decide_record(record, _approved?, _manager, _opts), do: {:ok, session_view(record)}

  # A window that closed between the read and the decision (its time ran out,
  # or the phone was gone at approval) is not an error here: the retained
  # session read next says how the ceremony ended.
  defp decision_call(session_id, true, manager, opts) do
    case invoke(opts, :approve_pair, &PairManager.approve/2, [manager, session_id]) do
      {:ok, _device} -> :ok
      {:error, :device_disconnected} -> :ok
      {:error, :session_not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp decision_call(session_id, false, manager, opts) do
    case invoke(opts, :deny_pair, &PairManager.deny/2, [manager, session_id]) do
      :ok -> :ok
      {:error, :session_not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_record(%{status: status} = record, manager, opts) when status in @open_states do
    case invoke(opts, :cancel_pair, &PairManager.cancel/2, [manager, record.session_id]) do
      :ok -> session_view_after(manager, record.session_id, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_record(record, _manager, _opts), do: {:ok, session_view(record)}

  defp session_view(record) do
    %{
      session_id: record.session_id,
      state: session_state(record.status),
      ttl_ms: record.remaining_ms,
      request: request_view(record.request),
      outcome: session_outcome(record),
      failure: session_failure(record.status)
    }
  end

  defp session_state(status) when status in [:rate_limited, :device_disconnected], do: :failed
  defp session_state(status), do: status

  defp session_outcome(%{status: :approved, device_id: device_id}), do: %{device_id: device_id}
  defp session_outcome(%{status: :denied}), do: %{reason: :denied}
  defp session_outcome(%{status: :expired}), do: %{reason: :timeout}
  defp session_outcome(%{status: :cancelled}), do: %{reason: :cancelled}
  defp session_outcome(_record), do: nil

  defp session_failure(status) when status in [:rate_limited, :device_disconnected],
    do: %{reason: status}

  defp session_failure(_status), do: nil

  # Attestation arrives with the Android daemon work; until then every field
  # it fills is present and empty, so the view already has its final shape.
  defp request_view(nil), do: nil

  defp request_view(request) do
    %{
      device_name: request.name,
      model: request.model,
      platform: nil,
      app_version: request.app_version,
      sas: request.sas,
      build_role: nil,
      boot_state: nil,
      attestation: :unavailable
    }
  end

  defp listed_rows(opts) do
    store = Keyword.get(opts, :device_store, DeviceStore)

    case invoke(opts, :list_devices, &DeviceStore.list/1, [store]) do
      {:ok, devices} -> {:ok, oldest_rows(devices)}
      {:error, reason} -> {:error, reason}
    end
  end

  # `DeviceStore.list/1` orders by id; the sort is stable, so devices paired in
  # the same second keep that order.
  defp oldest_rows(devices) do
    devices
    |> Enum.sort_by(&value(&1, :created_at), DateTime)
    |> Enum.take(@max_listed_devices)
    |> Enum.map(&device_row/1)
  end

  defp revoke(device_id, opts) do
    registry = Keyword.get(opts, :device_registry, DeviceRegistry)

    case invoke(opts, :revoke_device, &DeviceRegistry.revoke/2, [registry, device_id]) do
      :ok -> {:ok, %{device_id: device_id}}
      # The facade's wire vocabulary: the registry's tuple would reach the CLI
      # as an inspect() dump, and the id is already in the caller's hands.
      {:error, {:device_not_found, _id}} -> {:error, :device_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp runtime_facts(false, config, _opts) do
    {:ok,
     %{
       listener: listener_fact(:down, configured_bind(config), configured_port(config), []),
       mdns: idle_mdns(config),
       tailnet: %{detected: false, candidates: []},
       paired_devices: 0,
       pairing: nil
     }}
  end

  defp runtime_facts(true, config, opts) do
    with {:ok, candidates} <- discover(opts),
         {:ok, count} <- paired_device_count(opts),
         {:ok, pairing} <- pairing_fact(opts) do
      addresses = Enum.map(candidates, & &1.address)
      tailnet = for %{scope: :tailnet, address: address} <- candidates, do: address

      {:ok,
       %{
         listener: listener_status(opts, config, addresses),
         mdns: mdns_status(opts, config),
         tailnet: %{detected: tailnet != [], candidates: tailnet},
         paired_devices: count,
         pairing: pairing
       }}
    end
  end

  defp idle_mdns(config) do
    if enabled?(config) and Keyword.get(config, :advertise_mdns, true),
      do: :down,
      else: :disabled
  end

  defp pairing_fact(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    case invoke(opts, :latest_pair, &PairManager.latest/1, [manager]) do
      {:ok, record} ->
        {:ok, %{session_id: record.session_id, state: session_state(record.status)}}

      :none ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Status is a fact sheet, not a gate: an identity that is missing, partial or
  # unreadable is simply not present. Its faults are reported where they
  # refuse something: the boot refusal log, `pair_start/1`, and doctor.
  defp identity_fact(opts) do
    case invoke(opts, :load_identity, &Identity.load/1, [Keyword.take(opts, [:root])]) do
      {:ok, identity} when is_map(identity) ->
        present_identity(value(identity, :gateway_public_key))

      {:error, _reason} ->
        %{present: false, fingerprint: nil}
    end
  end

  defp present_identity(<<_::256>> = public_key),
    do: %{present: true, fingerprint: fingerprint(public_key)}

  defp present_identity(_incomplete), do: %{present: false, fingerprint: nil}

  defp fingerprint(public_key) do
    hex = :sha256 |> :crypto.hash(public_key) |> Base.encode16(case: :lower)
    Enum.join(for(<<group::binary-size(4) <- hex>>, do: group), " ")
  end

  defp pairing_uri(window, candidates, port, opts) do
    identity = window.identity

    with {:ok, gateway_public} <- binary_field(identity, :gateway_public_key, 32),
         {:ok, fingerprint} <- binary_field(identity, :tls_fingerprint, 32),
         {:ok, secret} <- binary_field(window, :secret, 32),
         {:ok, name} <- host_label(opts) do
      query =
        URI.encode_query([
          {"v", "1"},
          {"candidates", Jason.encode!(Enum.map(candidates, & &1.address))},
          {"port", Integer.to_string(port)},
          {"tls_fp", Base.encode16(fingerprint, case: :lower)},
          {"gateway_pk", Base.encode64(gateway_public)},
          {"secret", Base.encode64(secret)},
          {"name", name}
        ])

      {:ok, "fermix://pair?" <> query}
    end
  end

  defp discover(opts), do: invoke(opts, :discover, &Discovery.discover/0, [])

  defp host_label(opts) do
    case Keyword.get(opts, :host_label, &:inet.gethostname/0).() do
      {:ok, host} -> {:ok, to_string(host)}
      host when is_binary(host) and host != "" -> {:ok, host}
      {:error, reason} -> {:error, {:hostname_unavailable, reason}}
      other -> {:error, {:invalid_hostname, other}}
    end
  end

  defp expires_in_seconds(window) do
    remaining = max(window.expires_at_ms - window.opened_at_ms, 1)
    min(div(remaining + 999, 1_000), 120)
  end

  defp public_device(device), do: device |> device_row() |> Map.take(@v0_device_fields)

  # Platform, signer role and boot state come from Android attestation, which
  # the ceremony does not produce yet; the row carries them empty.
  defp device_row(device) do
    %{
      device_id: value(device, :device_id),
      name: value(device, :name),
      model: value(device, :model),
      platform: nil,
      signer_role: nil,
      boot_state: nil,
      push_registered: push_registered?(value(device, :push_token)),
      created_at: iso8601(value(device, :created_at)),
      last_seen: iso8601(value(device, :last_seen))
    }
  end

  defp push_registered?(token), do: is_binary(token) and token != ""

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value

  defp listener_status(opts, config, addresses) do
    server = Keyword.get(opts, :listener, Listener)
    bind = configured_bind(config)
    configured_port = configured_port(config)

    case process_query(opts, :listener_status, &Listener.status/1, [server]) do
      {:listening, {address, port}} -> listener_fact(:ready, address, port, addresses)
      :dormant -> listener_fact(:down, bind, configured_port, addresses)
      {:error, _reason} -> listener_fact(:down, bind, configured_port, addresses)
    end
  end

  defp listener_fact(status, bind, port, addresses) do
    %{
      status: status,
      port: port,
      bind: bind_text(bind),
      candidates: endpoint_candidates(addresses, port)
    }
  end

  defp bind_text(bind) when is_binary(bind), do: bind
  defp bind_text(bind) when is_tuple(bind), do: bind |> :inet.ntoa() |> to_string()

  defp configured_port(config), do: Keyword.get(config, :port, 4_031)
  defp configured_bind(config), do: Keyword.get(config, :bind, "0.0.0.0")

  defp mdns_status(opts, config) do
    if Keyword.get(config, :advertise_mdns, true) do
      server = Keyword.get(opts, :mdns_advertiser, MdnsAdvertiser)

      case process_query(opts, :mdns_status, &MdnsAdvertiser.status/1, [server]) do
        :advertising -> :advertising
        :disabled -> :disabled
        {:error, _reason} -> :down
      end
    else
      :disabled
    end
  end

  defp endpoint_candidates(addresses, port) do
    Enum.map(addresses, &"wss://#{&1}:#{port}/ws")
  end

  defp apns_status(push) do
    case PushConfig.new(push) do
      {:ok, %PushConfig{enabled: true}} -> %{enabled: true, credentials: :ready}
      {:ok, %PushConfig{enabled: false}} -> %{enabled: false, credentials: :missing}
      {:error, _reason} -> %{enabled: Keyword.get(push, :enabled, false), credentials: :missing}
    end
  end

  defp mobile_config(opts),
    do: Keyword.get(opts, :config, Application.get_env(:fermix_channels, :mobile, []))

  defp enabled?(config), do: require_enabled(config) == :ok

  defp require_enabled(config) do
    if Keyword.get(config, :enabled, false), do: :ok, else: {:error, :mobile_disabled}
  end

  # The flag gate every daemon-facing entry point shares. With the channel off
  # the mobile subtree is not running at all, so a process call from here would
  # surface as a raw `{:dependency_exit, _, {:noproc, _}}` tuple instead of the
  # actionable refusal the CLI renders for "mobile_disabled".
  defp require_enabled_config(opts), do: opts |> mobile_config() |> require_enabled()

  defp require_listener(opts) do
    server = Keyword.get(opts, :listener, Listener)

    case process_query(opts, :listener_status, &Listener.status/1, [server]) do
      {:listening, {_bind, port}} when is_integer(port) and port > 0 -> :ok
      :dormant -> {:error, :listener_down}
      {:error, reason} -> {:error, {:listener_unavailable, reason}}
      other -> {:error, {:invalid_listener_status, other}}
    end
  end

  defp require_identity(opts) do
    identity_opts = Keyword.take(opts, [:root])

    case invoke(opts, :load_identity, &Identity.load/1, [identity_opts]) do
      {:ok, _identity} -> :ok
      {:error, reason} -> {:error, {:identity_unavailable, reason}}
      other -> {:error, {:invalid_identity_reply, other}}
    end
  end

  defp paired_device_count(opts) do
    store = Keyword.get(opts, :device_store, DeviceStore)

    case invoke(opts, :list_devices, &DeviceStore.list/1, [store]) do
      {:ok, devices} when is_list(devices) -> {:ok, length(devices)}
      {:error, reason} -> {:error, {:device_store_unavailable, reason}}
      other -> {:error, {:invalid_device_store_reply, other}}
    end
  end

  defp binary_field(map, key, bytes) do
    case value(map, key) do
      binary when is_binary(binary) and byte_size(binary) == bytes -> {:ok, binary}
      other -> {:error, {:invalid_pairing_material, key, other}}
    end
  end

  defp process_query(opts, key, default, args) do
    invoke(opts, key, default, args)
  catch
    :exit, reason -> {:error, {:process_unavailable, reason}}
  end

  defp invoke(opts, key, default, args) do
    fun = Keyword.get(opts, key, default)
    apply(fun, args)
  catch
    :exit, reason -> {:error, {:dependency_exit, key, reason}}
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
