defmodule FermixCore.Plugins.Capabilities do
  @moduledoc """
  Registers enabled first-party plugin tools as builtin capabilities.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status
  alias FermixCore.Plugins.ToolExecutor

  @spec reload(GenServer.server(), keyword()) ::
          {:ok, %{registered: [String.t()]}} | {:error, term()}
  def reload(server \\ CapabilityRegistry, opts \\ []) when is_list(opts) do
    status_opts = Keyword.get(opts, :status, [])

    with :ok <-
           CapabilityRegistry.unregister_kind(server, :builtin, metadata: %{plugin_owned?: true}),
         {:ok, plugins} <- Registry.list() do
      registered =
        plugins
        |> Enum.filter(&(Status.status(&1, status_opts) == :ready))
        |> Enum.flat_map(&register_plugin(server, &1))

      {:ok, %{registered: registered}}
    end
  end

  # Register every tool of a ready plugin regardless of granted scope. Per-tool
  # scope is enforced at call time (FermixCore.Plugins.ToolExecutor), so a tool
  # whose write scope wasn't granted surfaces a graceful "reauthorize" error
  # instead of silently vanishing from the agent's toolset.
  #
  # `mcp`-rail entries are previews — the authoritative tool set comes from
  # MCP discovery at child spawn (M8 §8.2), so they never register here.
  defp register_plugin(server, %Plugin{} = plugin) do
    plugin.tools
    |> Enum.reject(&(Map.get(&1, "rail") == "mcp"))
    |> Enum.flat_map(fn tool ->
      capability = capability(plugin, tool)

      case CapabilityRegistry.register(server, capability) do
        :ok -> [capability.name]
        {:error, {:duplicate_name, _name}} -> []
      end
    end)
  end

  defp capability(plugin, tool) do
    name = Map.fetch!(tool, "name")
    auth_profile = Config.auth_profile(plugin)

    Capability.new(%{
      name: name,
      description: tool_description(plugin, tool),
      parameters: tool_parameters(name, tool),
      kind: :builtin,
      executor: {ToolExecutor, :execute, [plugin.name, tool]},
      policy_class: :external_api,
      metadata: %{
        plugin_owned?: true,
        plugin: plugin.name,
        plugin_tool: name,
        auth_profile: auth_profile,
        read_only?: Map.get(tool, "read_only") == true,
        category: :plugin,
        when_to_use: tool_description(plugin, tool),
        examples: [],
        failure_modes: []
      }
    })
  end

  # A v2 declarative tool carries its JSON-Schema `parameters` in the manifest;
  # a v1/hardcoded tool sources them from `ToolExecutor.parameters/1`.
  defp tool_parameters(name, tool) do
    case Map.get(tool, "parameters") do
      schema when is_map(schema) -> schema
      _ -> ToolExecutor.parameters(name)
    end
  end

  defp tool_description(%Plugin{} = plugin, tool) do
    case Map.get(tool, "description") do
      description when is_binary(description) and description != "" -> description
      _missing -> plugin.display_name
    end
  end
end
