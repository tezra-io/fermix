defmodule FermixChannels.Mobile.Supervisor do
  @moduledoc """
  Composite lifecycle for the mobile transport.

  Durable and presence state starts before pairing, media, and the listener.
  The listener itself may be dormant until the first pairing ceremony creates
  the gateway identity and asks it to activate.
  """

  use Supervisor

  require Logger

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.MdnsAdvertiser
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Push.Config, as: PushConfig
  alias FermixChannels.Mobile.Push.PigeonDispatcher
  alias FermixChannels.Mobile.RequestCoordinator

  @default_max_media_bytes 20 * 1_024 * 1_024
  @default_max_store_bytes 2 * 1_024 * 1_024 * 1_024
  @keyring_sentinel FermixCore.Setup.SecretWriter.sentinel()

  @doc """
  Start the mobile subtree, or refuse it when its trust store is unusable.

  A structurally broken `devices.toml` is a mobile-only fault. It is refused and
  never rebuilt (design §0), and refusing it must not take Telegram and every
  other channel down with it — so the subtree does not start, the reason is
  recorded for `health`/`doctor`, and the application keeps running.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    root = root(opts)
    store = names(opts).device_store

    case DeviceStore.list(root: root) do
      {:ok, _devices} -> start_subtree(opts, store)
      {:error, reason} -> refuse(root, store, reason)
    end
  end

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
      "mobile surface refused this boot: #{DeviceStore.store_path(root)} is unusable " <>
        "(#{inspect(reason)}). No mobile child started; other channels are unaffected. " <>
        "Fermix never regenerates a trust store — repair or remove the file, then restart."
    )

    :ignore
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
      {MediaStore, media_opts(opts, root, names.media_store)}
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
               store_opts: Keyword.get(opts, :store_opts, []),
               recovery_limit: Keyword.get(opts, :recovery_limit, 200)},
              id: names.request_coordinator
            ),
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
    if Keyword.get(push, :key) == @keyring_sentinel do
      Logger.error(
        "mobile push is enabled but its APNs key is still the #{@keyring_sentinel} sentinel — " <>
          "the OS keychain could not be read this boot. Mobile started WITHOUT push; " <>
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
      bind: Keyword.get(explicit, :bind, Keyword.get(config, :bind, "0.0.0.0")),
      port: Keyword.get(explicit, :port, Keyword.get(config, :port, 4_031)),
      start_listener?: Keyword.get(opts, :start_listener?, true),
      router_opts: [
        device_store: names.device_store,
        device_registry: names.device_registry,
        pair_manager: names.pair_manager,
        media_store: names.media_store,
        request_coordinator: names.request_coordinator,
        max_media_bytes: Keyword.get(config, :max_media_bytes, @default_max_media_bytes),
        push_environment: config |> Keyword.get(:push, []) |> Keyword.get(:environment)
      ]
    ]
  end

  defp mdns_opts(opts, names) do
    config = Keyword.get(opts, :config, [])

    [
      name: names.mdns_advertiser,
      enabled: Keyword.get(config, :advertise_mdns, true),
      port: Keyword.get(config, :port, 4_031)
    ]
  end
end
