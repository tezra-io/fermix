defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  alias FermixCore.Readiness

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:fermix_channels, :telegram, [])
    children = polling_children(config, Readiness.report())
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
end
