defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = polling_children()
    opts = [strategy: :one_for_one, name: FermixChannels.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp polling_children do
    config = Application.get_env(:fermix_channels, :telegram, [])

    if config[:mode] == :polling and config[:enabled] != false do
      [{FermixChannels.Telegram.Poller, []}]
    else
      []
    end
  end
end
