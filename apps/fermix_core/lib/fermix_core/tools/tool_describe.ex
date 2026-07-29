defmodule FermixCore.Tools.ToolDescribe do
  @moduledoc """
  Bridge tool (M10 §3.1): load a deferred tool's full schema on demand.

  Thin wrapper over `FermixCore.Tools.ToolHelp.render/2` — one shared
  renderer, two agent-facing names. `tool_describe` is the bridge-shaped
  contract for deferred plugin/MCP tools; resolution happens against the
  live registry at execution time.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.Support
  alias FermixCore.Tools.ToolHelp

  @impl true
  def name, do: "tool_describe"

  @impl true
  def description do
    "Load a deferred tool's full parameter schema and docs by exact tool name."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name"],
      properties: %{
        name: %{
          type: "string",
          description: "Exact tool name (from the Plugins list or a tool_search result)."
        }
      }
    }
  end

  @impl true
  def when_to_use,
    do:
      "Before calling a deferred tool whose parameters are unknown; skip when the skill already documents them."

  @impl true
  def examples,
    do: [%{args: %{"name" => "x_search_posts"}, note: "load the X search tool's schema"}]

  @impl true
  def failure_modes do
    [
      %{
        tag: "unknown_capability",
        description: "tool name is not registered — check tool_search"
      },
      %{tag: "missing_name", description: "name is absent or blank"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, cap_name} <- Support.required_string(args, "name"),
         registry = Map.get(context, :capability_registry, Registry),
         {:ok, rendered} <- ToolHelp.render(registry, cap_name, context) do
      {:ok, Tool.success(rendered)}
    else
      {:error, reason} -> Support.error(reason)
    end
  end
end
