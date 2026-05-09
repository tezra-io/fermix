defmodule FermixCore.Tools.ToolHelp do
  @moduledoc """
  Render expanded docs for a registered capability.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.Support

  @impl true
  def name, do: "tool_help"

  @impl true
  def description, do: "Return full parameter, example, and failure-mode docs for one capability."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name"],
      properties: %{name: %{type: "string", description: "Capability name to document."}}
    }
  end

  @impl true
  def when_to_use, do: "Inspect full docs for one capability after choosing a likely tool."

  @impl true
  def examples, do: [%{args: %{"name" => "content_search"}, note: "expand content_search docs"}]

  @impl true
  def failure_modes do
    [
      %{tag: "unknown_capability", description: "capability name is not registered"},
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
         {:ok, capability} <- find_capability(registry, cap_name) do
      {:ok, Tool.success(format_capability(capability))}
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp find_capability(registry, cap_name) do
    case Registry.find(registry, cap_name) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, "Unknown capability: #{cap_name}"}
    end
  end

  defp format_capability(capability) do
    [
      "# #{capability.name}",
      "",
      capability.description,
      builtin_note(capability),
      "",
      "## Parameters",
      format_parameters(capability.parameters),
      "",
      "## Examples",
      format_examples(capability.metadata[:examples] || []),
      "",
      "## Failure modes",
      format_failure_modes(capability.metadata[:failure_modes] || [])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp builtin_note(%{kind: :builtin}) do
    "This is a Fermix built-in. Skills are configured separately under the Fermix skills directory."
  end

  defp builtin_note(_capability), do: ""

  defp format_parameters(parameters) do
    required = Map.get(parameters, :required) || Map.get(parameters, "required") || []
    properties = Map.get(parameters, :properties) || Map.get(parameters, "properties") || %{}

    if map_size(properties) == 0 do
      "- none"
    else
      properties
      |> Enum.map(fn {key, schema} -> format_parameter(key, schema, required) end)
      |> Enum.join("\n")
    end
  end

  defp format_parameter(key, schema, required) do
    name = to_string(key)
    type = Map.get(schema, :type) || Map.get(schema, "type") || "any"
    description = Map.get(schema, :description) || Map.get(schema, "description") || ""
    required_text = if name in required, do: "required", else: "optional"
    "- `#{name}` (#{type}, #{required_text}) — #{description}"
  end

  defp format_examples([]), do: "- none"

  defp format_examples(examples) do
    examples
    |> Enum.map(fn %{args: args, note: note} -> "- `#{Jason.encode!(args)}` — #{note}" end)
    |> Enum.join("\n")
  end

  defp format_failure_modes([]), do: "- none"

  defp format_failure_modes(modes) do
    modes
    |> Enum.map(fn %{tag: tag, description: description} -> "- `#{tag}` — #{description}" end)
    |> Enum.join("\n")
  end
end
