defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixCore.Readiness

  require Logger

  @command_owner_channels [:telegram, :whatsapp, :discord, :slack, :signal]

  @impl true
  def start(_type, _args) do
    readiness = Readiness.report()
    warn_missing_command_owners(readiness)

    children =
      []
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
  @spec warn_missing_command_owners(Readiness.report()) :: :ok
  def warn_missing_command_owners(%{status: :ready}) do
    @command_owner_channels
    |> Enum.filter(&missing_command_owner?/1)
    |> Enum.each(&log_missing_command_owner/1)

    :ok
  end

  def warn_missing_command_owners(_readiness_report), do: :ok

  @doc false
  @spec polling_children(keyword(), Readiness.report()) :: [{FermixChannels.Telegram.Poller, []}]
  def polling_children(config, %{status: :ready}) when is_list(config) do
    if config[:enabled] != false do
      [{FermixChannels.Telegram.Poller, []}]
    else
      []
    end
  end

  def polling_children(config, _readiness_report) when is_list(config), do: []

  @doc false
  @spec gateway_children(keyword(), Readiness.report()) :: [{FermixChannels.Discord.Gateway, []}]
  def gateway_children(config, %{status: :ready}) when is_list(config) do
    if config[:mode] == :gateway and config[:enabled] == true do
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
    if config[:mode] == :subprocess and config[:enabled] == true do
      [{FermixChannels.Signal.Listener, []}]
    else
      []
    end
  end

  def subprocess_children(config, _readiness_report) when is_list(config), do: []

  defp missing_command_owner?(channel) do
    config = Application.get_env(:fermix_channels, channel, [])

    Keyword.get(config, :enabled, false) == true and
      is_nil(FermixCore.Config.channel_command_owner_user_id(channel))
  end

  defp log_missing_command_owner(channel) do
    Logger.warning(
      "#{channel} ingress is enabled but no command owner is configured; " <>
        "run /whoami from that channel and set fermix_channels.#{channel}.owner_user_id"
    )
  end
end
