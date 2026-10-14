defmodule FermixChannels.Mobile.Supervisor do
  @moduledoc """
  Composite lifecycle for the mobile transport.

  Durable and presence state starts before pairing, media, and the listener.
  The listener itself may be dormant until the first pairing ceremony creates
  the gateway identity and asks it to activate.

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

  alias FermixChannels.Channels.Mobile, as: MobileChannel
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.MdnsAdvertiser
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Push.Config, as: PushConfig
  alias FermixChannels.Mobile.Push.PigeonDispatcher
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo, as: MemoryRepo

  @default_max_media_bytes 20 * 1_024 * 1_024
  @default_max_store_bytes 2 * 1_024 * 1_024 * 1_024
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
  push dispatcher stay up, degraded, and say why.
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
      {DeviceRegistry, name: names.device_registry, device_store: names.device_store},
      {PairManager,
       root: root,
       name: names.pair_manager,
       device_store: names.device_store,
       listener: names.listener},
      {MediaStore, media_opts(opts, root, names.media_store)},
      MobileChannel.unfurl_supervisor_spec(
        names.unfurl_supervisor,
        MobileChannel.max_concurrent_unfurls()
      )
    ]

    with {:ok, push_children} <- push_children(config, names) do
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
            {Discovery, name: names.discovery, bind: listener_bind(opts)},
            {Listener, listener_opts(opts, root, names)},
            {MdnsAdvertiser, mdns_opts(opts, names)}
          ]

      Supervisor.init(children, strategy: :rest_for_one)
    else
      # `{:stop, reason}` is a GenServer init return, not a Supervisor one:
      # OTP matches only `{:ok, {flags, children}}` or `:ignore` and wraps
      # anything else as `{:bad_return, {__MODULE__, :init, ...}}`, which buries
      # the actual reason. Push was explicitly enabled with credentials that do
      # not resolve, so raise the reason the way `boot_epoch/1` below already
      # does rather than degrading to a mobile surface with push silently off.
      {:error, reason} ->
        raise ArgumentError, "invalid mobile push config: #{inspect(reason)}"
    end
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
      unfurl_supervisor: FermixChannels.Mobile.UnfurlSupervisor,
      discovery: Discovery,
      listener: Listener,
      mdns_advertiser: MdnsAdvertiser,
      push_dispatcher: PigeonDispatcher,
      request_coordinator: RequestCoordinator
    }

    Map.merge(defaults, Keyword.get(opts, :names, %{}))
  end

  defp push_children(config, names) do
    push = Keyword.get(config, :push, [])

    case Keyword.get(push, :enabled, false) do
      false -> {:ok, []}
      true -> enabled_push_child(push, names.push_dispatcher)
      value -> {:error, {:invalid_push_enabled, value}}
    end
  end

  # A locked or unreachable OS keychain leaves the `@keyring` sentinel sitting at
  # the push key: `SecretStore.resolve_sentinels/2` deliberately warns and boots
  # through rather than taking the node down. That is an UNRESOLVED credential,
  # not a malformed config, and raising on it would crash-loop the whole daemon
  # under KeepAlive over a keychain the operator can simply unlock. Mirror the
  # secret store's posture: start the mobile surface without the dispatcher, say
  # so loudly, and let `Management.status/1` report APNs credentials missing so
  # `fermix doctor` names it. Every other push-config fault still raises.
  defp enabled_push_child(push, name) do
    key = Keyword.get(push, :key)

    if key in @secret_sentinels do
      Logger.error(
        "mobile push is enabled but its APNs key is still the #{key} sentinel — " <>
          "its secret store could not be read this boot. Mobile started WITHOUT push; " <>
          "unlock the keychain and restart, or run `fermix doctor` to confirm."
      )

      {:ok, []}
    else
      validated_push_child(push, name)
    end
  end

  defp validated_push_child(push, name) do
    case PushConfig.new(push) do
      {:ok, %PushConfig{enabled: true} = config} ->
        {:ok, [{PigeonDispatcher, name: name, config: config}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp media_opts(opts, root, name) do
    config = Keyword.get(opts, :config, [])

    [
      root: Path.join(root, "mobile"),
      name: name,
      max_media_bytes: Keyword.get(config, :max_media_bytes, @default_max_media_bytes),
      max_store_bytes: Keyword.get(config, :media_store_max_bytes, @default_max_store_bytes)
    ]
  end

  defp listener_opts(opts, root, names) do
    config = Keyword.get(opts, :config, [])
    explicit = Keyword.get(opts, :listener, [])

    [
      root: root,
      name: names.listener,
      bind: listener_bind(opts),
      port: Keyword.get(explicit, :port, Keyword.get(config, :port, 4_031)),
      start_listener?: Keyword.get(opts, :start_listener?, true),
      router_opts: [
        device_store: names.device_store,
        device_registry: names.device_registry,
        pair_manager: names.pair_manager,
        media_store: names.media_store,
        request_coordinator: names.request_coordinator,
        discovery: names.discovery,
        max_media_bytes: Keyword.get(config, :max_media_bytes, @default_max_media_bytes),
        push_environment: config |> Keyword.get(:push, []) |> Keyword.get(:environment)
      ]
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
