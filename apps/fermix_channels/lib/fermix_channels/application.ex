defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixCore.Readiness

  require Logger

  @impl true
  def start(_type, _args) do
    readiness = Readiness.report()
    log_missing_ingress_authorization(readiness)

    # The gateway owns the turn queue; core introspection reads its status
    # through this runtime-registered provider (no compile-time core→channels
    # dependency). Registered here so the provider is present iff the queue runs.
    Application.put_env(:fermix_core, :queue_status_provider, FermixChannels.Gateway.Queue)

    children =
      [
        FermixChannels.Gateway.Queue,
        FermixChannels.Gateway.Commands.Sandbox.Confirmations,
        FermixChannels.Gateway.Idempotency
      ] ++ ChannelRegistry.transport_children(readiness)

    opts = [strategy: :one_for_one, name: FermixChannels.Supervisor]
    Supervisor.start_link(children, opts)
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
