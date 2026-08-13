defmodule FermixChannels.Mobile.Management do
  @moduledoc """
  Daemon-facing management facade for mobile pairing and paired devices.

  The core daemon resolves this module at runtime, keeping `fermix_core` free
  of a compile-time dependency on channel internals. Pairing secrets appear
  only inside the QR URI returned for local terminal rendering.
  """

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.MdnsAdvertiser
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Push.Config, as: PushConfig

  @max_wait_ms 120_000

  @spec begin_pairing() :: {:ok, map()} | {:error, term()}
  def begin_pairing, do: begin_pairing([])

  @doc false
  @spec begin_pairing(keyword()) :: {:ok, map()} | {:error, term()}
  def begin_pairing(opts) when is_list(opts) do
    manager = Keyword.get(opts, :pair_manager, PairManager)

    case invoke(opts, :open_pair, &PairManager.open/1, [manager]) do
      {:ok, window} -> finish_pairing_setup(window, manager, opts)
      {:error, _reason} = error -> error
    end
  end

  defp finish_pairing_setup(window, manager, opts) do
    listener = Keyword.get(opts, :listener, Listener)

    result =
      with {:ok, {_bind, port}} <-
             invoke(opts, :listener_info, &Listener.listener_info/1, [listener]),
           {:ok, candidates} <- discover(opts),
           {:ok, uri} <- pairing_uri(window, candidates, port, opts),
           {:ok, qr} <- terminal_qr(uri) do
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

    with {:ok, request} <-
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

    with {:ok, device} <-
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

    with :ok <- invoke(opts, :deny_pair, &PairManager.deny/2, [manager, session_id]) do
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

    with :ok <- invoke(opts, :cancel_pair, &PairManager.cancel/2, [manager, session_id]) do
      {:ok, %{cancelled: true}}
    end
  end

  @spec list_devices() :: {:ok, %{devices: [map()]}} | {:error, term()}
  def list_devices, do: list_devices([])

  @doc false
  @spec list_devices(keyword()) :: {:ok, %{devices: [map()]}} | {:error, term()}
  def list_devices(opts) when is_list(opts) do
    store = Keyword.get(opts, :device_store, DeviceStore)

    with {:ok, devices} <- invoke(opts, :list_devices, &DeviceStore.list/1, [store]) do
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
    registry = Keyword.get(opts, :device_registry, DeviceRegistry)

    with :ok <- invoke(opts, :revoke_device, &DeviceRegistry.revoke/2, [registry, device_id]) do
      {:ok, %{device_id: device_id}}
    end
  end

  @spec status() :: {:ok, map()} | {:error, term()}
  def status, do: status([])

  @doc false
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts) when is_list(opts) do
    config = Keyword.get(opts, :config, Application.get_env(:fermix_channels, :mobile, []))
    store = Keyword.get(opts, :device_store, DeviceStore)

    with {:ok, candidates} <- discover(opts),
         {:ok, devices} <- invoke(opts, :list_devices, &DeviceStore.list/1, [store]) do
      port = Keyword.get(config, :port, 4_031)
      addresses = Enum.map(candidates, & &1.address)
      tailnet = candidates |> Enum.filter(&(&1.scope == :tailnet)) |> Enum.map(& &1.address)

      {:ok,
       %{
         enabled: Keyword.get(config, :enabled, false),
         listener: listener_status(opts, addresses, port),
         mdns: mdns_status(opts, config),
         tailnet: %{detected: tailnet != [], candidates: tailnet},
         apns: apns_status(Keyword.get(config, :push, enabled: false)),
         paired_devices: length(devices)
       }}
    end
  end

  @doc "Fail-closed health for the runtime mobile channel adapter."
  @spec health() :: {:ok, map()} | {:error, term()}
  def health, do: health([])

  @doc false
  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(opts) when is_list(opts) do
    config = Keyword.get(opts, :config, Application.get_env(:fermix_channels, :mobile, []))

    with :ok <- require_enabled(config),
         :ok <- require_listener(opts),
         :ok <- require_identity(opts),
         {:ok, count} <- paired_device_count(opts) do
      {:ok, %{listener: :ready, identity: :ready, paired_devices: count}}
    end
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

  defp terminal_qr(uri) do
    case QRCode.create(uri, :medium) do
      {:ok, %{matrix: matrix}} -> {:ok, render_matrix(matrix)}
      {:error, reason} -> {:error, {:qr_generation_failed, reason}}
    end
  end

  defp render_matrix(matrix) do
    quiet = List.duplicate(0, length(matrix) + 4)

    rows =
      [quiet, quiet] ++
        Enum.map(matrix, fn row -> [0, 0] ++ row ++ [0, 0] end) ++ [quiet, quiet]

    Enum.map_join(rows, "\n", &render_row/1)
  end

  defp render_row(row), do: Enum.map_join(row, &render_module/1)
  defp render_module(1), do: "██"
  defp render_module(_value), do: "  "

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

  defp public_device(device) do
    %{
      device_id: value(device, :device_id),
      name: value(device, :name),
      created_at: iso8601(value(device, :created_at)),
      last_seen: iso8601(value(device, :last_seen))
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value

  defp listener_status(opts, addresses, configured_port) do
    server = Keyword.get(opts, :listener, Listener)

    case process_query(opts, :listener_status, &Listener.status/1, [server]) do
      {:listening, {_bind, port}} ->
        %{status: :ready, candidates: endpoint_candidates(addresses, port)}

      :dormant ->
        %{status: :down, candidates: endpoint_candidates(addresses, configured_port)}

      {:error, _reason} ->
        %{status: :down, candidates: endpoint_candidates(addresses, configured_port)}
    end
  end

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

  defp require_enabled(config) do
    if Keyword.get(config, :enabled, false), do: :ok, else: {:error, :mobile_disabled}
  end

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
