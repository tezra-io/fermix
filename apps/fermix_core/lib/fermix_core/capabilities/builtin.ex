defmodule FermixCore.Capabilities.Builtin do
  @moduledoc """
  Wraps a `FermixCore.Capabilities.Builtin.Tool` module as a `%Capability{}`
  with `kind: :builtin` and `executor: {ToolModule, :execute, []}`.

  Policy class defaults are pinned per built-in so the §4.6 sub-agent gate
  has stable metadata to filter against. Built-ins not listed here default
  to `:read_only` — fail closed.
  """

  alias FermixCore.Capabilities.Capability

  @policy_defaults %{
    "shell" => %{policy_class: :exec, requires_approval?: false},
    "file_read" => %{policy_class: :read_only, requires_approval?: false},
    "file_write" => %{policy_class: :read_write, requires_approval?: false},
    "memory_recall" => %{policy_class: :read_only, requires_approval?: false},
    "memory_store" => %{policy_class: :read_write, requires_approval?: false},
    "browser" => %{policy_class: :network, requires_approval?: false}
  }

  @spec from_tool_module(module()) :: Capability.t()
  def from_tool_module(tool_module) when is_atom(tool_module) do
    name = tool_module.name()
    defaults = Map.get(@policy_defaults, name, %{policy_class: :read_only})

    Capability.new(%{
      name: name,
      description: tool_module.description(),
      parameters: tool_module.parameters(),
      kind: :builtin,
      executor: {tool_module, :execute, []},
      policy_class: defaults.policy_class,
      requires_approval?: Map.get(defaults, :requires_approval?, false),
      metadata: %{tool_module: tool_module}
    })
  end
end
