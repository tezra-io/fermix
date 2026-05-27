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

  @spec reload(GenServer.server()) :: {:ok, %{registered: [String.t()]}} | {:error, term()}
  def reload(server \\ CapabilityRegistry) do
    with :ok <-
           CapabilityRegistry.unregister_kind(server, :builtin, metadata: %{plugin_owned?: true}),
         {:ok, plugins} <- Registry.list() do
      registered =
        plugins
        |> Enum.filter(&Status.ready?/1)
        |> Enum.flat_map(&register_plugin(server, &1))

      {:ok, %{registered: registered}}
    end
  end

  defp register_plugin(server, %Plugin{} = plugin) do
    granted = plugin |> Status.granted_scopes() |> MapSet.new()

    plugin.tools
    |> Enum.filter(&tool_granted?(granted, &1))
    |> Enum.flat_map(fn tool ->
      capability = capability(plugin, tool)

      case CapabilityRegistry.register(server, capability) do
        :ok -> [capability.name]
        {:error, {:duplicate_name, _name}} -> []
      end
    end)
  end

  defp tool_granted?(granted, tool) do
    tool
    |> Map.get("requires_scopes", [])
    |> MapSet.new()
    |> MapSet.subset?(granted)
  end

  defp capability(plugin, tool) do
    name = Map.fetch!(tool, "name")
    auth_profile = Config.auth_profile(plugin)

    Capability.new(%{
      name: name,
      description: plugin.display_name,
      parameters: ToolExecutor.parameters(name),
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
        when_to_use: plugin.display_name,
        examples: [],
        failure_modes: []
      }
    })
  end
end
