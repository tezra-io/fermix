defmodule FermixWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias FermixCore.Home.Role

  @impl true
  def start(_type, _args) do
    children = [
      FermixWebWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:fermix_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FermixWeb.PubSub},
      # Start a worker by calling: FermixWeb.Worker.start_link(arg)
      # {FermixWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      FermixWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FermixWeb.Supervisor]
    Supervisor.start_link(role_children(children), opts)
  end

  # Through the role's one filter (`Role.children/2`): a
  # candidate primary (M75 §2) serves no web address, so its endpoint is left
  # out; the primary and a device start the list as it is. A process whose
  # engine recorded no role starts no web application at all.
  defp role_children(children) do
    case Role.booted() do
      %{role: role} -> Role.children(children, role)
      nil -> children
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FermixWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
