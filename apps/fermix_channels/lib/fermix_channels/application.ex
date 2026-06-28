defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixCore.Readiness

  require Logger

  @impl true
  def start(_type, _args) do
    readiness = Readiness.report()
    log_missing_ingress_authorization(readiness)

    # Fail fast on a misconfigured command list: a duplicate name/alias would
    # silently shadow a command via the registry's first-match lookup.
    FermixChannels.Gateway.Commands.Registry.validate!()

    # The gateway owns the turn queue; core introspection reads its status
    # through this runtime-registered provider (no compile-time core→channels
    # dependency). Registered here so the provider is present iff the queue runs.
    Application.put_env(:fermix_core, :queue_status_provider, FermixChannels.Gateway.Queue)

    children =
      [
        FermixChannels.Gateway.Queue,
        FermixChannels.Gateway.BackgroundSupervisor,
        FermixChannels.Gateway.Commands.Sandbox.Confirmations,
        FermixChannels.Gateway.Commands.Soul.Confirmations,
        FermixChannels.Gateway.Idempotency
      ] ++ album_buffers() ++ ChannelRegistry.transport_children(readiness)

    opts = [strategy: :one_for_one, name: FermixChannels.Supervisor]
    Supervisor.start_link(children, opts)
  end

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
end
