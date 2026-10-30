defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixChannels.BrowserHost
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Companion
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.LinkPreviews
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Readiness

  require Logger

  @compiled_env Mix.env()
  @held_key {__MODULE__, :held_at_boot}

  @impl true
  def start(_type, _args) do
    readiness = Readiness.report()
    log_missing_ingress_authorization(readiness)
    log_missing_helpers(readiness)

    # Fail fast on a misconfigured command list: a duplicate name/alias would
    # silently shadow a command via the registry's first-match lookup.
    FermixChannels.Gateway.Commands.Registry.validate!()

    # The gateway owns the turn queue; core introspection reads its status
    # through this runtime-registered provider (no compile-time core→channels
    # dependency). Registered here so the provider is present iff the queue runs.
    Application.put_env(:fermix_core, :queue_status_provider, FermixChannels.Gateway.Queue)

    # Core's daemon control socket must not compile-depend on channels. Register
    # the mobile management facade only while this application is running; CLI
    # pair/devices requests resolve it dynamically through the daemon.
    Application.put_env(
      :fermix_core,
      :mobile_management_provider,
      FermixChannels.Mobile.Management
    )

    # `/health` reports the Telegram poller's degraded posture. Core must not
    # compile-depend on channels, so the poller registers itself here; the
    # provider is present iff this application runs.
    Application.put_env(
      :fermix_core,
      :telegram_poll_health_provider,
      FermixChannels.Channels.Telegram.Poller
    )

    # Slack's Socket Mode connection reports its posture the same way (M75).
    Application.put_env(
      :fermix_core,
      :slack_socket_health_provider,
      FermixChannels.Channels.Slack.SocketMode
    )

    # The Live voice engine delegates every task back to a Core turn through
    # this bridge (M41 §6). Core owns the behaviour and resolves an
    # implementation; it must not compile-depend on channels, so the bridge
    # registers itself here and is present iff this application runs.
    Application.put_env(:fermix_core, :voice_bridge, FermixChannels.Voice.Bridge)

    # A mandate proposal (M60 §10.9) goes to the owner's DM through the
    # gateway's approval delivery. Core must not compile-depend on channels, so
    # the sender registers itself here and is present iff this application runs;
    # without it a proposal cannot reach the owner and is refused.
    Application.put_env(
      :fermix_core,
      :cue_proposal_sender,
      FermixChannels.Gateway.OwnerInboxApproval
    )

    # Every waiting proposal is offered to the Mac app's chat, and its end told
    # there (M60 app surface §3.7): core announces through this listener, which
    # registers itself here for the same reason.
    Application.put_env(
      :fermix_core,
      :cue_proposal_listener,
      FermixChannels.Companion.Proposals
    )

    # Core's restart state asks which transports wait for a restart: a boot
    # whose setup was not finished registers none, and finishing setup changes
    # no setting core could compare (`waiting_for_restart/1`). Registered here
    # for the same reason, so it is present iff this application runs.
    Application.put_env(:fermix_core, :transport_restart_provider, __MODULE__)

    request_boot_epoch = request_boot_epoch()

    # What this boot holds is decided here, once, and read from this record
    # rather than from the supervisor, which a read must never wait on.
    :persistent_term.put(@held_key, held_by(readiness, request_boot_epoch))

    children =
      [
        # The Queue and the Task.Supervisor its turns run under, :one_for_all.
        FermixChannels.Gateway.QueueSupervisor,
        # After the queue, deliberately: the bridge ingests through it, so a
        # delegation accepted before the queue is up has nowhere to run.
        FermixChannels.Voice.Supervisor
      ] ++
        timeline_media() ++
        [
          # The companion chat socket, after the queue for the same reason. Its
          # registry is always present, its turns' settlement runs on every real
          # boot (the phone's requests settle there too), and the socket runs
          # whenever the daemon does.
          {Companion.Supervisor,
           serve?: daemon_boot?(), settle?: settles?(), boot_epoch: request_boot_epoch},
          # The Fermix app's browser host socket; it runs whenever the daemon does.
          {BrowserHost.Supervisor, serve?: daemon_boot?()},
          FermixChannels.Gateway.BackgroundSupervisor,
          FermixChannels.Gateway.Commands.Sandbox.Confirmations,
          FermixChannels.Gateway.Commands.Soul.Confirmations,
          FermixChannels.Gateway.Idempotency
        ] ++
        album_buffers() ++
        transport_children(readiness, request_boot_epoch) ++ call_row_sweep(settles?())

    opts = [strategy: :one_for_one, name: FermixChannels.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The timeline's media store and the bounded supervisor its rows' link
  # previews resolve under (M72): the phone and the Mac share both, so they run
  # whether or not a phone is paired, before the companion socket that grants
  # the store's files and previews its replies. A test tree starts the ones it
  # needs under its own names.
  defp timeline_media do
    if @compiled_env == :test,
      do: [],
      else: [MediaStore.boot_child(), LinkPreviews.supervisor_spec()]
  end

  # The chat rows Live calls still owe after a restart (M56 §4.2), written
  # last, once the companion channel that writes them and the phones' channel
  # that hears them are up; a test tree runs the pass each test drives.
  defp call_row_sweep(true), do: [FermixChannels.Voice.CallRowSweep]
  defp call_row_sweep(false), do: []

  # One non-blocking album buffer per channel that delivers a multi-image album
  # as separate inbound messages (Telegram media groups across poll cycles;
  # WhatsApp per-image webhooks with no media_group_id). Coalesced into one turn.
  # Distinct child ids let two instances of the same module run side by side.
  defp album_buffers do
    [
      Supervisor.child_spec(
        {AlbumBuffer,
         channel: Telegram, config_key: :telegram, name: AlbumBuffer.name_for(Telegram)},
        id: {AlbumBuffer, Telegram}
      ),
      Supervisor.child_spec(
        {AlbumBuffer,
         channel: WhatsApp,
         config_key: :whatsapp,
         idempotency_key: :whatsapp,
         name: AlbumBuffer.name_for(WhatsApp)},
        id: {AlbumBuffer, WhatsApp}
      )
    ]
  end

  @doc """
  The transports a boot with this readiness holds, by child id: those a boot
  whose setup was finished registers and this one does not. Empty once setup is
  finished. This boot's answer is recorded at boot (`held_at_boot/0`).
  """
  @spec held_by(Readiness.report(), String.t()) :: [module()]
  def held_by(readiness, request_boot_epoch) when is_map(readiness),
    do:
      ids(transport_children(%{status: :ready}, request_boot_epoch)) --
        ids(transport_children(readiness, request_boot_epoch))

  @doc """
  The transports this boot held because setup was not finished, as recorded at
  boot. Empty where setup was finished at boot, and before this application
  starts.
  """
  @spec held_at_boot() :: [module()]
  def held_at_boot, do: :persistent_term.get(@held_key, [])

  @doc """
  The transports this boot held that the next boot would start: setup is
  finished now, each is still set to start, and the phone's switch is on (the
  phone's subtree is registered on or off, so a held phone that is off would
  start nothing). Read by core's restart state through
  `:transport_restart_provider`, so finishing setup asks for the restart that
  starts them. Readiness is read only when this boot held something.
  `:held`, `:readiness` and `:phone_switch` replace the three reads in a test.
  """
  @spec waiting_for_restart(keyword()) :: [module()]
  def waiting_for_restart(opts \\ []) when is_list(opts) do
    case Keyword.get_lazy(opts, :held, &held_at_boot/0) do
      [] -> []
      held -> Enum.filter(held, &starts_at_next_boot?(&1, next_boot_ids(opts), opts))
    end
  end

  # What a boot with readiness as it stands now would register. The phone's
  # id is the registry's here as at boot: a held list never names it in a test
  # tree, which registers no phone (`phone_child/1`).
  defp next_boot_ids(opts) do
    opts
    |> Keyword.get(:readiness, &Readiness.report/0)
    |> then(& &1.())
    |> ChannelRegistry.transport_children()
    |> ids()
  end

  defp starts_at_next_boot?(MobileSupervisor, next_ids, opts),
    do:
      MobileSupervisor in next_ids and
        Keyword.get(opts, :phone_switch, &MobileSupervisor.switch_on?/0).()

  defp starts_at_next_boot?(transport, next_ids, _opts), do: transport in next_ids

  defp ids(children), do: Enum.map(children, &Supervisor.child_spec(&1, []).id)

  defp transport_children(readiness, request_boot_epoch) do
    readiness
    |> ChannelRegistry.transport_children()
    |> Enum.flat_map(fn
      {FermixChannels.Mobile.Supervisor, []} -> phone_child(request_boot_epoch)
      child -> [child]
    end)
  end

  # Registered on or off, with the boot's epoch, so its switch is live. A test
  # tree never registers it, as it never registered it while the switch was
  # boot-bound and off there: a settings write in a test must not start a phone
  # listener or record a refusal under the operator's home.
  defp phone_child(request_boot_epoch) do
    if @compiled_env == :test,
      do: [],
      else: [FermixChannels.Mobile.Supervisor.boot_child(request_boot_epoch)]
  end

  # One epoch per boot for every transport's request coordinator: a request
  # running under it is this boot's and is never started twice, and one
  # running under any other epoch was left by an earlier boot.
  defp request_boot_epoch do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # A real daemon run (`fermix run`, `mix fermix.dev`, the app engine) turns
  # the daemon socket on before this application starts; a test tree never
  # serves a socket under the operator's home.
  defp daemon_boot? do
    @compiled_env != :test and Application.get_env(:fermix_core, :daemon_socket_enabled, false)
  end

  # Every real boot settles companion and phone turns, a `:source` boot that
  # serves no daemon socket included; a test tree starts the settlement each
  # test drives.
  defp settles?, do: @compiled_env != :test

  @doc false
  @spec log_missing_ingress_authorization(Readiness.report()) :: :ok
  def log_missing_ingress_authorization(%{status: :ready}) do
    Enum.each(ChannelRegistry.missing_ingress_authorizations(), &log_channel_refusal/1)
    :ok
  end

  def log_missing_ingress_authorization(_readiness_report), do: :ok

  defp log_channel_refusal(channel) do
    Logger.error(
      "#{channel} ingress is enabled but no owner_user_id or allowed_*_ids list is set. " <>
        "Refusing to start the #{channel} adapter. Run /whoami from that channel and set " <>
        "fermix_channels.#{channel}.owner_user_id, then restart the daemon."
    )
  end

  # An enabled channel whose helper is not on disk (MILESTONE_54 §14) boots
  # without its transport and says so; `macos?:` injects the host (tests).
  @doc false
  @spec log_missing_helpers(Readiness.report(), keyword()) :: :ok
  def log_missing_helpers(readiness, opts \\ [])

  def log_missing_helpers(%{status: :ready}, opts) when is_list(opts) do
    Enum.each(ChannelRegistry.missing_helpers(opts), &log_helper_refusal/1)
    :ok
  end

  def log_missing_helpers(_readiness_report, opts) when is_list(opts), do: :ok

  defp log_helper_refusal(channel) do
    Logger.warning(
      "#{channel} is enabled but the helper it needs is not installed. Not starting the " <>
        "#{channel} channel. Turn #{channel} on in Channels settings to install it, then restart."
    )
  end
end
