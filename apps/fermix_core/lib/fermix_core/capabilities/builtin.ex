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
    "shell" => %{policy_class: :exec, hidden_from_agent?: false, owner_only?: false},
    "file_read" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "file_write" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "file_edit" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "glob_search" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "content_search" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "git_read" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "git_write" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "web_fetch" => %{policy_class: :network, hidden_from_agent?: false, owner_only?: false},
    "web_search" => %{policy_class: :network, hidden_from_agent?: false, owner_only?: false},
    # Provider place data, not owner data: the owner's saved default location is
    # only ever an outbound request parameter and never appears in the result
    # (MILESTONE_31 §13.2). Seeded always; `advertise?/1` hides it without a key.
    "place_search" => %{policy_class: :network, hidden_from_agent?: false, owner_only?: false},
    # Owner-only on-device activity recall (MILESTONE_32 §11.2); the Gate is the
    # real barrier, this pins the guest filter and classification.
    "recall_activity" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "skill_create" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "skill_reload" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "skill_view" => %{policy_class: :exec, hidden_from_agent?: false, owner_only?: false},
    "skill_run" => %{policy_class: :exec, hidden_from_agent?: false, owner_only?: false},
    "skill_list" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "subagents" => %{policy_class: :external_api, hidden_from_agent?: false, owner_only?: false},
    # Owner-only, like subagents: `:external_api` is in the operator's default
    # policy but the guest deny-list, so a guest never gets this control tool in
    # their surface (the advertise?/execute gates are the hard barriers regardless).
    "request_directory_access" => %{
      policy_class: :external_api,
      hidden_from_agent?: false,
      owner_only?: false
    },
    "model_routing_config" => %{
      policy_class: :read_write,
      hidden_from_agent?: false,
      owner_only?: false
    },
    "tool_help" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "tool_search" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "tool_describe" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "tool_call" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "memory_recall" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "memory_store" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "schedule_job" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "update_job" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "list_jobs" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "pause_job" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "resume_job" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "remove_job" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "run_job_now" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: false},
    "list_job_runs" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "get_job_run" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "memory_sources_list" => %{
      policy_class: :read_only,
      hidden_from_agent?: false,
      owner_only?: true
    },
    "browser" => %{policy_class: :network, hidden_from_agent?: false, owner_only?: false},
    "send_attachment" => %{
      policy_class: :read_only,
      hidden_from_agent?: false,
      owner_only?: false
    },
    "react" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "generate_image" => %{
      policy_class: :external_api,
      hidden_from_agent?: false,
      owner_only?: false
    },
    # Computer use. `:gui_control` buys ZERO sandbox enforcement (COMPUTER_USE.md
    # §7.1) — it labels the blast class and routes to the §7 action-boundary layer.
    # Operator-only (registry.ex), never delegated to subagents (subagents.ex). Only
    # seeded when `ComputerUse.ready?()` (BuiltinSeeder), so an unready/disabled
    # daemon never advertises it.
    "computer_use" => %{policy_class: :gui_control, hidden_from_agent?: false, owner_only?: false},
    # Coding harness (design §7.1). The run tools are `:exec` — dispatchable inside
    # an operator's `:exec` ceiling — but the execute-time `Harness.Authorization`
    # gate (attended operator or allowlisted cron) is the real barrier, not the
    # policy class. Only seeded when the harness is enabled AND the vendor CLI is
    # present (BuiltinSeeder), so a disabled daemon never advertises them.
    "codex_run" => %{policy_class: :exec, hidden_from_agent?: false, owner_only?: false},
    "claude_code_run" => %{policy_class: :exec, hidden_from_agent?: false, owner_only?: false},
    "codex_cloud_run" => %{policy_class: :exec, hidden_from_agent?: false, owner_only?: false},
    "list_coding_runs" => %{
      policy_class: :read_only,
      hidden_from_agent?: false,
      owner_only?: false
    },
    "get_coding_run" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: false},
    "cancel_coding_run" => %{
      policy_class: :read_write,
      hidden_from_agent?: false,
      owner_only?: false
    },
    "stop_tracking_coding_run" => %{
      policy_class: :read_write,
      hidden_from_agent?: false,
      owner_only?: false
    },
    # Temporal events (MILESTONE_30 §12.1). Owner-only because every row is the
    # owner's own calendar data; the attended-origin advertise?/execute gate in
    # `Temporal.Access` is the hard barrier, and these registry fields do not
    # replace it.
    "event_store" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: true},
    "event_list" => %{policy_class: :read_only, hidden_from_agent?: false, owner_only?: true},
    "event_update" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: true},
    "event_remove" => %{policy_class: :read_write, hidden_from_agent?: false, owner_only?: true},
    "reminder_snooze" => %{
      policy_class: :read_write,
      hidden_from_agent?: false,
      owner_only?: true
    },
    # Meetings notetaker (MILESTONE_21 C2 §14.1). `:external_api` sits in the
    # operator's default policy and the guest deny-list, and owner-only keeps
    # the owner's own meetings out of a guest's surface; the attended-operator
    # advertise?/execute gate these three share with the temporal family — and
    # `Meetings.join/2` repeats — is the hard barrier. Only seeded when
    # `Meetings.ready?()` (BuiltinSeeder), so a disabled or lane-less daemon
    # never advertises them.
    "join_meeting" => %{
      policy_class: :external_api,
      hidden_from_agent?: false,
      owner_only?: true
    },
    "leave_meeting" => %{
      policy_class: :external_api,
      hidden_from_agent?: false,
      owner_only?: true
    },
    "list_meetings" => %{
      policy_class: :external_api,
      hidden_from_agent?: false,
      owner_only?: true
    }
  }

  @doc """
  Names with an explicit `policy_class` classification. A built-in NOT in this
  set silently defaults to `:read_only` (`from_tool_module/1`), which would let a
  forgotten write-capable tool join the read-only-derived subagent surface — so a
  test asserts every seeded built-in appears here. Exposed for that guard.
  """
  @spec classified_names() :: [String.t()]
  def classified_names, do: Map.keys(@policy_defaults)

  @doc """
  Whether `name` states an explicit `owner_only?` decision.

  `owner_only?` marks a capability whose return value is the OWNER's own data
  (their workspace files, scheduled jobs, memory sources) so the registry can
  keep it out of a guest's surface — `:read_only` bounds what a caller may do,
  not whose data comes back. The default is `false`, which is fail-open on
  exactly the axis that matters, so a test asserts every seeded built-in makes
  the decision deliberately. Exposed for that guard.
  """
  @spec owner_only_declared?(String.t()) :: boolean()
  def owner_only_declared?(name) when is_binary(name) do
    case Map.fetch(@policy_defaults, name) do
      {:ok, defaults} -> Map.has_key?(defaults, :owner_only?)
      :error -> false
    end
  end

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
      owner_only?: Map.get(defaults, :owner_only?, false),
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
