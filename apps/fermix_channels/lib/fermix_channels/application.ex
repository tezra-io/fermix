defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixCore.Readiness

  @impl true
  def start(_type, _args) do
    readiness = Readiness.report()

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
  @spec polling_children(keyword(), Readiness.report()) :: [{FermixChannels.Telegram.Poller, []}]
  def polling_children(config, %{status: :ready}) when is_list(config) do
    if config[:mode] == :polling and config[:enabled] != false do
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
end
