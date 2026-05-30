defmodule FermixCore.MCP.Inbound.Supervisor do
  @moduledoc """
  Starts the inbound Anubis MCP server when inbound MCP is enabled.
  """

  use Supervisor
  require Logger

  alias FermixCore.MCP.Inbound.CapabilityPort
  alias FermixCore.MCP.Inbound.Config
  alias FermixCore.MCP.Inbound.Exposure
  alias FermixCore.MCP.Inbound.Server

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, Config.current())
    maybe_warn_mcp_reexposure(config)
    children = if config.enabled?, do: [anubis_child(config, opts)], else: []

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp anubis_child(%Config{} = config, opts) do
    server = Keyword.get(opts, :server, Server)
    server_supervisor = Keyword.get(opts, :server_supervisor, Anubis.Server.Supervisor)

    server_opts =
      opts
      |> Keyword.get(:server_opts, [])
      |> Keyword.put(:transport, transport(config))
      |> Keyword.put(:request_timeout, config.request_timeout_ms)

    %{
      id: :mcp_inbound_anubis_server,
      start: {server_supervisor, :start_link, [server, server_opts]},
      type: :supervisor
    }
  end

  defp transport(%Config{transport: :stdio}), do: :stdio
  defp transport(%Config{transport: :streamable_http}), do: {:streamable_http, []}

  defp maybe_warn_mcp_reexposure(%Config{enabled?: true, expose_kinds: kinds} = config) do
    if :mcp in kinds do
      config
      |> exposed_mcp_names()
      |> warn_mcp_reexposure()
    end
  end

  defp maybe_warn_mcp_reexposure(_config), do: :ok

  defp exposed_mcp_names(config) do
    case CapabilityPort.impl().list_capabilities() do
      {:ok, capabilities} ->
        capabilities
        |> Exposure.expose_for_inbound(config)
        |> Enum.filter(&(&1.kind == :mcp))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp warn_mcp_reexposure([]), do: :ok

  defp warn_mcp_reexposure(names) do
    Logger.warning(
      "MCP inbound: re-exposing outbound MCP capabilities: #{Enum.join(names, ", ")}. " <>
        "Consider whether the inbound client should talk to the upstream server directly."
    )
  end
end
