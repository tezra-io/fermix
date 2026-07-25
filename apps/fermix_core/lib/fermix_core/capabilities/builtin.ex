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
    "skill_create" => %{policy_class: :read_write, hidden_from_agent?: false},
    "skill_reload" => %{policy_class: :read_write, hidden_from_agent?: false},
    "skill_view" => %{policy_class: :exec, hidden_from_agent?: false},
    "skill_run" => %{policy_class: :exec, hidden_from_agent?: false},
    "skill_list" => %{policy_class: :read_only, hidden_from_agent?: false},
    "subagents" => %{policy_class: :external_api, hidden_from_agent?: false},
    # Owner-only, like subagents: `:external_api` is in the operator's default
    # policy but the guest deny-list, so a guest never gets this control tool in
    # their surface (the advertise?/execute gates are the hard barriers regardless).
    "request_directory_access" => %{policy_class: :external_api, hidden_from_agent?: false},
    "model_routing_config" => %{policy_class: :read_write, hidden_from_agent?: false},
    "tool_help" => %{policy_class: :read_only, hidden_from_agent?: false},
    "tool_search" => %{policy_class: :read_only, hidden_from_agent?: false},
    "tool_describe" => %{policy_class: :read_only, hidden_from_agent?: false},
    "tool_call" => %{policy_class: :read_only, hidden_from_agent?: false},
    "memory_recall" => %{policy_class: :read_only, hidden_from_agent?: false},
    "memory_store" => %{policy_class: :read_write, hidden_from_agent?: false},
    "schedule_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "update_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "list_jobs" => %{policy_class: :read_only, hidden_from_agent?: false},
    "pause_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "resume_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "remove_job" => %{policy_class: :read_write, hidden_from_agent?: false},
    "run_job_now" => %{policy_class: :read_write, hidden_from_agent?: false},
    "list_job_runs" => %{policy_class: :read_only, hidden_from_agent?: false},
    "get_job_run" => %{policy_class: :read_only, hidden_from_agent?: false},
    "memory_sources_list" => %{policy_class: :read_only, hidden_from_agent?: false},
    "browser" => %{policy_class: :network, hidden_from_agent?: false},
    "send_attachment" => %{policy_class: :read_only, hidden_from_agent?: false},
    "react" => %{policy_class: :read_only, hidden_from_agent?: false},
    "generate_image" => %{policy_class: :external_api, hidden_from_agent?: false},
    # Computer use. `:gui_control` buys ZERO sandbox enforcement (COMPUTER_USE.md
    # §7.1) — it labels the blast class and routes to the §7 action-boundary layer.
    # Operator-only (registry.ex), never delegated to subagents (subagents.ex). Only
    # seeded when `ComputerUse.ready?()` (BuiltinSeeder), so an unready/disabled
    # daemon never advertises it.
    "computer_use" => %{policy_class: :gui_control, hidden_from_agent?: false},
    # Coding harness (design §7.1). The run tools are `:exec` — dispatchable inside
    # an operator's `:exec` ceiling — but the execute-time `Harness.Authorization`
    # gate (attended operator or allowlisted cron) is the real barrier, not the
    # policy class. Only seeded when the harness is enabled AND the vendor CLI is
    # present (BuiltinSeeder), so a disabled daemon never advertises them.
    "codex_run" => %{policy_class: :exec, hidden_from_agent?: false},
    "claude_code_run" => %{policy_class: :exec, hidden_from_agent?: false},
    "codex_cloud_run" => %{policy_class: :exec, hidden_from_agent?: false},
    "list_coding_runs" => %{policy_class: :read_only, hidden_from_agent?: false},
    "get_coding_run" => %{policy_class: :read_only, hidden_from_agent?: false},
    "cancel_coding_run" => %{policy_class: :read_write, hidden_from_agent?: false},
    "stop_tracking_coding_run" => %{policy_class: :read_write, hidden_from_agent?: false}
  }

  @doc """
  Names with an explicit `policy_class` classification. A built-in NOT in this
  set silently defaults to `:read_only` (`from_tool_module/1`), which would let a
  forgotten write-capable tool join the read-only-derived subagent surface — so a
  test asserts every seeded built-in appears here. Exposed for that guard.
  """
  @spec classified_names() :: [String.t()]
  def classified_names, do: Map.keys(@policy_defaults)

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
