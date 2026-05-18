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
    "shell" => %{policy_class: :exec, hidden_from_agent?: false},
    "file_read" => %{policy_class: :read_only, hidden_from_agent?: false},
    "file_write" => %{policy_class: :read_write, hidden_from_agent?: false},
    "file_edit" => %{policy_class: :read_write, hidden_from_agent?: false},
    "glob_search" => %{policy_class: :read_only, hidden_from_agent?: false},
    "content_search" => %{policy_class: :read_only, hidden_from_agent?: false},
    "git_read" => %{policy_class: :read_only, hidden_from_agent?: false},
    "git_write" => %{policy_class: :read_write, hidden_from_agent?: false},
    "web_fetch" => %{policy_class: :network, hidden_from_agent?: false},
    "web_search" => %{policy_class: :network, hidden_from_agent?: false},
    "delegate" => %{policy_class: :external_api, hidden_from_agent?: false},
    "skill_create" => %{policy_class: :read_write, hidden_from_agent?: false},
    "model_routing_config" => %{policy_class: :read_write, hidden_from_agent?: false},
    "tool_help" => %{policy_class: :read_only, hidden_from_agent?: false},
    "memory_recall" => %{policy_class: :read_only, hidden_from_agent?: false},
    "memory_store" => %{policy_class: :read_write, hidden_from_agent?: false},
    "schedule_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "list_jobs" => %{policy_class: :read_only, hidden_from_agent?: false},
    "pause_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "resume_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "remove_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "memory_sources_list" => %{policy_class: :read_only, hidden_from_agent?: false},
    "browser" => %{policy_class: :network, hidden_from_agent?: false}
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
      hidden_from_agent?: Map.get(defaults, :hidden_from_agent?, false),
      metadata: metadata(tool_module)
    })
  end

  defp metadata(tool_module) do
    %{
      tool_module: tool_module,
      when_to_use: callback_or(tool_module, :when_to_use, tool_module.description()),
      examples: callback_or(tool_module, :examples, []),
      failure_modes: callback_or(tool_module, :failure_modes, []),
      requires_setup: callback_or(tool_module, :requires_setup, nil),
      category: callback_or(tool_module, :category, :system)
    }
  end

  defp callback_or(module, function, default) do
    if function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      default
    end
  end
end
