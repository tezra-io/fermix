defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixCore.Readiness

  require Logger

  @command_owner_channels [:telegram, :whatsapp, :discord, :slack, :signal]

  @impl true
  def start(_type, _args) do
    readiness = Readiness.report()
    log_missing_ingress_authorization(readiness)

    children =
      [
        FermixChannels.Commands.Sandbox.Confirmations,
        FermixChannels.Idempotency
      ]
      |> Kernel.++(
        polling_children(Application.get_env(:fermix_channels, :telegram, []), readiness)
      )
      |> Kernel.++(
        gateway_children(Application.get_env(:fermix_channels, :discord, []), readiness)
      )
      |> Kernel.++(
        subprocess_children(Application.get_env(:fermix_channels, :signal, []), readiness)
      )

    opts = [strategy: :one_for_one, name: FermixChannels.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  @spec log_missing_ingress_authorization(Readiness.report()) :: :ok
  def log_missing_ingress_authorization(%{status: :ready}) do
    @command_owner_channels
    |> Enum.filter(&missing_ingress_authorization?/1)
    |> Enum.each(&log_channel_refusal/1)

    :ok
  end

  def log_missing_ingress_authorization(_readiness_report), do: :ok

  @doc false
  @spec polling_children(keyword(), Readiness.report()) :: [{FermixChannels.Telegram.Poller, []}]
  def polling_children(config, %{status: :ready}) when is_list(config) do
    if enabled?(config) and ingress_authorized?(:telegram) do
      [{FermixChannels.Telegram.Poller, []}]
    else
      []
    end
  end

  def polling_children(config, _readiness_report) when is_list(config), do: []

  @doc false
  @spec gateway_children(keyword(), Readiness.report()) :: [{FermixChannels.Discord.Gateway, []}]
  def gateway_children(config, %{status: :ready}) when is_list(config) do
    if config[:mode] == :gateway and enabled?(config) and ingress_authorized?(:discord) do
      [{FermixChannels.Discord.Gateway, []}]
    else
      []
    end
  end

  def gateway_children(config, _readiness_report) when is_list(config), do: []

  @doc false
  @spec subprocess_children(keyword(), Readiness.report()) :: [
          {FermixChannels.Signal.Listener, []}
        ]
  def subprocess_children(config, %{status: :ready}) when is_list(config) do
    if config[:mode] == :subprocess and enabled?(config) and ingress_authorized?(:signal) do
      [{FermixChannels.Signal.Listener, []}]
    else
      []
    end
  end

  def subprocess_children(config, _readiness_report) when is_list(config), do: []

  defp enabled?(config), do: Keyword.get(config, :enabled, false) == true

  defp ingress_authorized?(channel) do
    FermixCore.Config.channel_ingress_user_ids(channel) != []
  end

  defp missing_ingress_authorization?(channel) do
    config = Application.get_env(:fermix_channels, channel, [])

    enabled?(config) and not ingress_authorized?(channel)
  end

  defp log_channel_refusal(channel) do
    Logger.error(
      "#{channel} ingress is enabled but no owner_user_id or allowed_*_ids list is set. " <>
        "Refusing to start the #{channel} adapter. Run /whoami from that channel and set " <>
        "fermix_channels.#{channel}.owner_user_id, then restart the daemon."
    )
  end
end
