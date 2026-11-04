defmodule FermixChannels.Mobile.Supervisor do
  @moduledoc """
  Composite lifecycle for the mobile transport.

  Durable and presence state starts before pairing and the listener. The
  listener itself may be dormant until the first pairing ceremony creates the
  gateway identity and asks it to activate. The media store and the link
  previews are the timeline's, shared with the Mac, so the channels
  application runs them whether or not this subtree does; a manifest the store
  cannot read still refuses this subtree, with its own word.

  The phone channel's switch is live (M51 §5.5, owner 2026-10-10). The
  channels application registers this subtree for the whole boot, on or off,
  with the boot's request epoch (`boot_child/1`); `start_link/1` reads the
  switch and starts nothing while it is off, and `switch/2` starts or stops the
  registered child when the switch changes. Restarting the registered child
  keeps the epoch, so a phone request running under this boot is never taken
  for one an earlier boot left behind.
  """

  use Supervisor

  require Logger

  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.MdnsAdvertiser
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Push.Config, as: PushConfig
  alias FermixChannels.Mobile.Push.PigeonDispatcher
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixChannels.Mobile.Session
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo, as: MemoryRepo

  @default_max_media_bytes 20 * 1_024 * 1_024
  @secret_sentinels FermixCore.Setup.SecretWriter.sentinels()
  @identity_faults [:identity_incomplete, :identity_unreadable, :invalid_identity_transaction]
  @manifest_faults [
    :insecure_attachment_manifest,
    :invalid_attachment_manifest,
    :invalid_attachment_manifest_target,
    :attachment_manifest_stat_failed
  ]

  @doc """
  Start the mobile subtree, or refuse it when its durable state is unusable.

  A structurally broken `devices.toml`, partial/unreadable identity material,
  or a broken attachment manifest is a mobile-only fault. Each is refused and
  never rebuilt, and refusing it must not take Telegram and every other channel
  down with it — a child's `init` `{:stop, ...}` would escalate through this
  supervisor into an application crash-loop under the service manager. So the
  subtree does not start, the reason is recorded for `health`/`doctor`, and
  the application keeps running. Memory turned off is refused the same way:
  the phone's whole timeline lives in `Memory.Repo`, which then refuses every
  call. Environmental faults (an address not up yet, a port another daemon
  holds, APNs unreachable) never refuse or stop anything: the listener and the
  push dispatcher stay up, degraded, and say why. Push settings that do not
  resolve never refuse it either: the subtree starts without the dispatcher.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    if switched_on?(opts), do: admit(opts), else: :ignore
  end

  defp admit(opts) do
    root = root(opts)
    store = names(opts).device_store

    case admission_check(opts, root) do
      :ok -> start_subtree(opts, store)
      {:error, reason} -> refuse(root, store, reason)
    end
  end

  # `:switch` reads the channel's switch at each start. The channels
  # application passes the running config's (`boot_child/1`); a subtree started
  # without one, as a test starts it, always starts.
  defp switched_on?(opts) do
    case Keyword.get(opts, :switch) do
      nil -> true
      switch when is_function(switch, 0) -> switch.() == true
      other -> raise ArgumentError, ":switch must be a zero-arity function, got #{inspect(other)}"
    end
  end

  @doc """
  The child the channels application registers for the whole boot: this
  subtree with the boot's request epoch, and the running config's switch.
  """
  @spec boot_child(String.t()) :: {module(), keyword()}
  def boot_child(boot_epoch) when is_binary(boot_epoch) and boot_epoch != "" do
    {__MODULE__, boot_epoch: boot_epoch, switch: &switch_on?/0}
  end

  @doc "Whether `[fermix_channels.mobile] enabled` is on in the running config."
  @spec switch_on?() :: boolean()
  def switch_on? do
    :fermix_channels |> Application.get_env(:mobile, []) |> Keyword.get(:enabled, false) == true
  end

  @doc """
  Starts or stops the registered subtree while the daemon runs.

  On: the registered child starts again with its boot arguments, so it reads
  the switch and keeps the boot's epoch. `:not_started` is a start that came
  back empty: the switch still reads off, or the admission check refused the
  subtree and recorded why (`refusal/1`). `{:error, :not_ready}` is a boot that
  registered no subtree, because setup was not ready. Off: the child stops and
  stays registered, and a refusal recorded for it is forgotten, because a
  channel turned off has nothing to refuse. `:parent` and `:device_store`
  replace the channels supervisor and the trust store in a test.
  """
  @spec switch(boolean(), keyword()) ::
          {:ok, :started | :not_started | :stopped} | {:error, :not_ready | term()}
  def switch(on?, opts \\ [])

  def switch(true, opts) when is_list(opts) do
    case Supervisor.restart_child(parent(opts), __MODULE__) do
      {:ok, pid} when is_pid(pid) -> {:ok, :started}
      {:ok, :undefined} -> {:ok, :not_started}
      {:error, :running} -> {:ok, :started}
      {:error, :not_found} -> {:error, :not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  def switch(false, opts) when is_list(opts) do
    case Supervisor.terminate_child(parent(opts), __MODULE__) do
      :ok -> forget_refusal(Keyword.get(opts, :device_store, DeviceStore))
      {:error, :not_found} -> :ok
    end

    {:ok, :stopped}
  end

  defp parent(opts), do: Keyword.get(opts, :parent, FermixChannels.Supervisor)

  @doc """
  Starts or stops remote reach (`Mobile.Iroh`) while the daemon runs, as
  `switch/2` does the whole subtree: on, the registered child starts again and
  reads its switch; off, it stops (helper shut down, every remote stream ended,
  no relay contact) and stays registered. `:not_started` is a start that came
  back empty because the switch still reads off; `{:error, :not_ready}` is a
  phone subtree that is not running, so there is no rail to switch. `:parent`
  replaces this supervisor in a test.
  """
  @spec switch_iroh(boolean(), keyword()) ::
          {:ok, :started | :not_started | :stopped} | {:error, :not_ready | term()}
  def switch_iroh(on?, opts \\ [])

  def switch_iroh(true, opts) when is_list(opts) do
    case safe_child_call(opts, &Supervisor.restart_child(&1, Iroh)) do
      {:ok, pid} when is_pid(pid) -> {:ok, :started}
      {:ok, :undefined} -> {:ok, :not_started}
      {:error, :running} -> {:ok, :started}
      {:error, :not_found} -> {:error, :not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  def switch_iroh(false, opts) when is_list(opts) do
    case safe_child_call(opts, &Supervisor.terminate_child(&1, Iroh)) do
      :ok -> {:ok, :stopped}
      {:error, :not_found} -> {:ok, :stopped}
      {:error, :not_ready} -> {:ok, :stopped}
      {:error, reason} -> {:error, reason}
    end
  end

  # The phone subtree may be switched off itself, and so absent.
  defp safe_child_call(opts, call) do
    supervisor = Keyword.get(opts, :parent, __MODULE__)
    if GenServer.whereis(supervisor), do: call.(supervisor), else: {:error, :not_ready}
  end

  defp admission_check(opts, root) do
    with {:ok, _devices} <- DeviceStore.list(root: root),
         :ok <- Identity.admissible(root: root),
         :ok <- MediaStore.manifest_admissible(media_opts(opts, root, nil)) do
      memory_available(opts)
    end
  end

  # The phone's timeline lives in the running memory Repo, which answers
  # `{:error, :disabled}` to every call when memory is off. The Repo's own
  # answer is the one the timeline gets, so it is asked rather than config.
  defp memory_available(opts) do
    enabled? = Keyword.get(opts, :memory_enabled?, &memory_repo_enabled?/0)
    if enabled?.(), do: :ok, else: {:error, :memory_disabled}
  end

  defp memory_repo_enabled? do
    not is_nil(MemoryRepo.enabled_server(MemoryConfig.repo_server()))
  end

  @doc "The word `mobile.status` publishes for the class of a boot refusal."
  @spec refusal_word(term()) :: :memory_disabled | :identity | :attachment_manifest | :trust_store
  def refusal_word(:memory_disabled), do: :memory_disabled

  def refusal_word(reason) when is_tuple(reason) and elem(reason, 0) in @identity_faults,
    do: :identity

  def refusal_word(reason) when is_tuple(reason) and elem(reason, 0) in @manifest_faults,
    do: :attachment_manifest

  def refusal_word(_reason), do: :trust_store

  @doc """
  Whether the phone subtree runs: this supervisor's registered name is alive.
  A refused boot starts nothing, and every child runs under this supervisor,
  so no child's name stands in for the subtree. Looking the name up sends no
  message; `whereis` replaces the lookup in a test.
  """
  @spec running?((GenServer.name() -> pid() | nil)) :: boolean()
  def running?(whereis \\ &GenServer.whereis/1) when is_function(whereis, 1),
    do: is_pid(whereis.(__MODULE__))

  @doc "Reason the mobile surface refused to start for a trust store, if it did."
  @spec refusal(atom()) :: {:error, term()} | :none
  def refusal(store \\ DeviceStore) when is_atom(store) do
    case :persistent_term.get(refusal_key(store), :none) do
      :none -> :none
      reason -> {:error, reason}
    end
  end

  @doc "Clear a recorded refusal, as a healthy boot of the same trust store does."
  @spec forget_refusal(atom()) :: :ok
  def forget_refusal(store) when is_atom(store) do
    _erased? = :persistent_term.erase(refusal_key(store))
    :ok
  end

  defp start_subtree(opts, store) do
    :ok = forget_refusal(store)

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  defp refuse(root, store, reason) do
    :persistent_term.put(refusal_key(store), reason)

    Logger.error(
      "mobile surface refused this boot: #{refusal_detail(root, reason)} " <>
        "No mobile child started; other channels are unaffected."
    )

    :ignore
  end

  # The remedy differs per fault class, and copy that names the wrong file
  # sends the operator repairing the wrong thing.
  defp refusal_detail(_root, :memory_disabled) do
    "memory is turned off, and the phone's conversation lives in the memory store. " <>
      "Turn memory back on, then restart."
  end

  defp refusal_detail(root, reason)
       when elem(reason, 0) in @identity_faults do
    "the mobile identity material under #{root} is unusable (#{inspect(reason)}). " <>
      "Fermix never regenerates partial identity material — restore the missing files, " <>
      "or remove the whole identity directory to re-pair every device, then restart."
  end

  defp refusal_detail(_root, reason)
       when elem(reason, 0) in @manifest_faults do
    "the mobile attachment manifest is unusable (#{inspect(reason)}). " <>
      "Repair or remove the file, then restart."
  end

  defp refusal_detail(root, reason) do
    "#{DeviceStore.store_path(root)} is unusable (#{inspect(reason)}). " <>
      "Fermix never regenerates a trust store — repair or remove the file, then restart."
  end

  defp refusal_key(store), do: {__MODULE__, :refused_trust_store, store}

  @impl true
  def init(opts) do
    root = root(opts)
    names = names(opts)
    boot_epoch = boot_epoch(opts)
    config = Keyword.get(opts, :config, Application.get_env(:fermix_channels, :mobile, []))
    opts = Keyword.put(opts, :config, config)

    base_children = [
      {DeviceStore, root: root, name: names.device_store},
      {DeviceRegistry,
       name: names.device_registry,
       device_store: names.device_store,
       relays_changed: fn -> Iroh.Helper.relays_acknowledged(names.iroh_helper) end},
      {PairManager,
       root: root,
       name: names.pair_manager,
       device_store: names.device_store,
       listener: names.listener,
       rail: names.iroh_helper}
    ]

    push_children = push_children(config, names)
    opts = Keyword.put(opts, :push_services, push_services(push_children))

    children =
      base_children ++
        push_children ++
        [
          Supervisor.child_spec(
            {RequestCoordinator,
             name: names.request_coordinator,
             boot_epoch: boot_epoch,
             store_opts: Keyword.put(Keyword.get(opts, :store_opts, []), :transport, "mobile"),
             recovery_limit: Keyword.get(opts, :recovery_limit, 200),
             device_store: names.device_store},
            id: names.request_coordinator
          ),
          # Before the carriers: a desktop's session starts its peer here.
          {DesktopSupervisor,
           name: names.desktop,
           registry: names.desktop_peers,
           peer_supervisor: names.desktop_peer_supervisor},
          {Discovery, name: names.discovery, bind: listener_bind(opts)},
          {Listener, listener_opts(opts, root, names)},
          {MdnsAdvertiser, mdns_opts(opts, names)},
          # Last, so its restart, and its live switch, touch nothing else.
          {Iroh, iroh_opts(opts, root, names)}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp root(opts) do
    Keyword.get(opts, :root) ||
      System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end

  defp boot_epoch(opts) do
    case Keyword.fetch(opts, :boot_epoch) do
      :error ->
        random_boot_epoch()

      {:ok, epoch} when is_binary(epoch) and epoch != "" ->
        epoch

      {:ok, invalid} ->
        raise ArgumentError, "boot_epoch must be a non-empty string, got #{inspect(invalid)}"
    end
  end

  defp random_boot_epoch do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp names(opts) do
    defaults = %{
      device_store: DeviceStore,
      device_registry: DeviceRegistry,
      pair_manager: PairManager,
      media_store: MediaStore,
      discovery: Discovery,
      listener: Listener,
      mdns_advertiser: MdnsAdvertiser,
      push_dispatcher: PigeonDispatcher,
      request_coordinator: RequestCoordinator,
      iroh_helper: Iroh.Helper,
      bridge: Iroh.Bridge,
      bridge_connections: FermixChannels.Mobile.Iroh.Connections,
      desktop: DesktopSupervisor,
      desktop_peers: FermixChannels.Desktop.Peers,
      desktop_peer_supervisor: FermixChannels.Desktop.PeerSupervisor
    }

    Map.merge(defaults, Keyword.get(opts, :names, %{}))
  end

  # Push settings that do not resolve never refuse this subtree (M51 §10): in
  # a release the channels application is permanent, and a raise here took
  # every channel down with it. Chat, pairing and the rail start without the
  # dispatcher, the log says why with the typed reason, and
  # `Management.status/1` reads APNs credentials missing, which `fermix
  # doctor` names.
  defp push_children(config, names) do
    push = Keyword.get(config, :push, [])

    case Keyword.get(push, :enabled, false) do
      false -> []
      true -> enabled_push_child(push, names.push_dispatcher)
      value -> without_push({:invalid_push_enabled, value})
    end
  end

  # A locked or unreachable OS keychain leaves the `@keyring` sentinel sitting at
  # the push key: `SecretStore.resolve_sentinels/2` deliberately warns and boots
  # through rather than taking the node down. That is an UNRESOLVED credential,
  # not a malformed config, and raising on it would crash-loop the whole daemon
  # under KeepAlive over a keychain the operator can simply unlock. Mirror the
  # secret store's posture: start the mobile surface without the dispatcher, say
  # so loudly, and let `Management.status/1` report APNs credentials missing so
  # `fermix doctor` names it.
  defp enabled_push_child(push, name) do
    key = Keyword.get(push, :key)

    if key in @secret_sentinels do
      Logger.error(
        "mobile push is enabled but its APNs key is still the #{key} sentinel — " <>
          "its secret store could not be read this boot. Mobile started WITHOUT push; " <>
          "unlock the keychain and restart, or run `fermix doctor` to confirm."
      )

      []
    else
      validated_push_child(push, name)
    end
  end

  defp validated_push_child(push, name) do
    case PushConfig.new(push) do
      {:ok, %PushConfig{enabled: true} = config} ->
        [{PigeonDispatcher, name: name, config: config}]

      {:error, reason} ->
        without_push(reason)
    end
  end

  defp without_push(reason) do
    Logger.error(
      "mobile push settings do not resolve (#{inspect(reason)}). " <>
        "Mobile started WITHOUT push; fix [fermix_channels.mobile.push] and restart, " <>
        "or run `fermix doctor` to confirm."
    )

    []
  end

  # The services a phone is told this daemon pushes through: those whose
  # dispatcher starts, so a phone never registers for one that cannot send.
  defp push_services(push_children) do
    Enum.map(push_children, fn {PigeonDispatcher, _opts} -> "apns" end)
  end

  defp media_opts(opts, root, name),
    do: MediaStore.configured(root, Keyword.get(opts, :config, []), name)

  defp listener_opts(opts, root, names) do
    config = Keyword.get(opts, :config, [])
    explicit = Keyword.get(opts, :listener, [])

    [
      root: root,
      name: names.listener,
      bind: listener_bind(opts),
      port: Keyword.get(explicit, :port, Keyword.get(config, :port, 4_031)),
      start_listener?: Keyword.get(opts, :start_listener?, true),
      router_opts: session_opts(config, names, Keyword.fetch!(opts, :push_services))
    ]
  end

  # What every carrier's sessions are started with: the WebSocket's through the
  # router, the bridge's directly.
  defp session_opts(config, names, push_services) do
    [
      device_store: names.device_store,
      device_registry: names.device_registry,
      pair_manager: names.pair_manager,
      media_store: names.media_store,
      request_coordinator: names.request_coordinator,
      discovery: names.discovery,
      iroh_helper: names.iroh_helper,
      desktop_peers: names.desktop_peers,
      desktop_peer_supervisor: names.desktop_peer_supervisor,
      max_media_bytes: Keyword.get(config, :max_media_bytes, @default_max_media_bytes),
      push_environment: config |> Keyword.get(:push, []) |> Keyword.get(:environment),
      push_services: push_services
    ]
  end

  defp iroh_opts(opts, root, names) do
    config = Keyword.get(opts, :config, [])
    session = session_opts(config, names, Keyword.fetch!(opts, :push_services))
    max_media_bytes = Keyword.fetch!(session, :max_media_bytes)

    [
      root: root,
      names: names,
      switch: Keyword.get(opts, :iroh_switch, &Iroh.switch_on?/0),
      helper_opts: Keyword.get(opts, :iroh_helper_opts, []),
      # The listener gives its sessions the identity's home the same way.
      session_opts:
        Keyword.merge(session,
          identity_root: root,
          authenticated_max_heap_size: Session.authenticated_heap_cap(max_media_bytes)
        )
    ]
  end

  # One answer for the listener and for discovery, so the addresses a phone is
  # given are the ones the listener answers on (M51 §5.5).
  defp listener_bind(opts) do
    config = Keyword.get(opts, :config, [])
    explicit = Keyword.get(opts, :listener, [])
    Keyword.get(explicit, :bind, Keyword.get(config, :bind, "0.0.0.0"))
  end

  defp mdns_opts(opts, names) do
    config = Keyword.get(opts, :config, [])

    [
      name: names.mdns_advertiser,
      enabled: Keyword.get(config, :advertise_mdns, false),
      port: Keyword.get(config, :port, 4_031)
    ]
  end
end
