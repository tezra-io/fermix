defmodule FermixCore.Tools.ClaudeCodeRun do
  @moduledoc """
  Delegate repo coding work to a local Claude Code run
  (`claude -p --output-format stream-json`).

  The tool authorizes the caller (attended operator or an allowlisted scheduled
  job), sandbox-checks `cwd`, resolves where the terminal message must go, and
  admits the run through `Harness.Manager`. Runs are background-only (design
  §23.1): the tool returns the run id immediately and the outcome comes back on
  its own — into this conversation for a chat origin, as durable delivery for a
  scheduled one.

  Posture is the operator's, not the model's. Omitting `permission_mode` emits no
  flag at all, so the run inherits `~/.claude/settings.json` — that is the
  default and the reason harness runs are autonomous without the model asking for
  anything. The model may still trade friction *within* the sandbox
  (`acceptEdits`, `auto`, …), but the values that delete the sandbox are refused
  at the tool boundary; see `HarnessSupport.@boundary_removing`.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Adapters.ClaudeHeadless
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Vendors
  alias FermixCore.Tools.HarnessRun

  @vendor "claude"

  # Fixed string → atom table (spec C1: no `String.to_atom` on model input).
  @param_keys %{
    "model" => :model,
    "effort" => :effort,
    "permission_mode" => :permission_mode,
    "allowed_tools" => :allowed_tools,
    "disallowed_tools" => :disallowed_tools,
    "append_system_prompt" => :append_system_prompt,
    "append_system_prompt_file" => :append_system_prompt_file,
    "add_dirs" => :add_dirs,
    "max_turns" => :max_turns,
    "json_schema" => :json_schema,
    "resume" => :resume,
    "continue" => :continue,
    "bare" => :bare
  }

  @spec spec() :: HarnessRun.spec()
  def spec, do: %{name: name(), vendor: @vendor, adapter: ClaudeHeadless, key_table: @param_keys}

  @impl true
  @spec name() :: String.t()
  def name, do: "claude_code_run"

  @impl true
  @spec description() :: String.t()
  def description do
    "Run a Claude Code coding task inside a repository (claude -p). Runs in the " <>
      "background; the outcome comes back on its own when it finishes."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["prompt", "cwd"],
      properties: %{
        prompt: %{type: "string", description: "The coding task for Claude Code to carry out."},
        cwd: %{type: "string", description: "Absolute path of the repository/working directory."},
        model: %{type: "string", description: "Optional Claude model override."},
        effort: %{
          type: "string",
          enum: ["low", "medium", "high", "xhigh", "max"],
          description: "Optional reasoning effort."
        },
        permission_mode: %{
          type: "string",
          enum: ["acceptEdits", "auto", "manual", "dontAsk", "plan"],
          description:
            "Claude Code permission mode. Omit to use the operator's configured " <>
              "posture. `auto` runs with the least friction while keeping the sandbox."
        },
        allowed_tools: %{
          type: "array",
          items: %{type: "string"},
          description: "Tool names to allow (comma-joined for the CLI)."
        },
        disallowed_tools: %{
          type: "array",
          items: %{type: "string"},
          description: "Tool names to disallow."
        },
        append_system_prompt: %{
          type: "string",
          description: "Extra system-prompt text to append."
        },
        append_system_prompt_file: %{
          type: "string",
          description: "Path to a file whose contents append to the system prompt."
        },
        add_dirs: %{
          type: "array",
          items: %{type: "string"},
          description: "Extra writable directories (each --add-dir; also locked)."
        },
        max_turns: %{type: "integer", description: "Maximum agent turns."},
        json_schema: %{type: "string", description: "JSON schema for structured output."},
        resume: %{type: "string", description: "Resume a prior Claude session id."},
        continue: %{type: "boolean", description: "Continue the most recent session."},
        bare: %{
          type: "boolean",
          description: "Bare mode: skip OAuth/keychain and read ANTHROPIC_API_KEY only."
        },
        timeout_minutes: %{
          type: "integer",
          description: "Run wall-clock timeout in minutes (cap 240)."
        },
        progress: %{
          type: "string",
          enum: ["quiet", "milestones"],
          description: "Whether to send throttled progress notices."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "For repository work — reviewing a PR or recent changes, diagnosing and fixing " <>
      "a bug at its root cause, implementing or refactoring a feature, working " <>
      "through a repository — delegate to a Claude Code run instead of editing " <>
      "files yourself. Reserve your own tools for the genuinely incidental (a " <>
      "quick calculation, reading one file, scratch work outside any project)."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "prompt" => "Add pagination to the users endpoint",
          "cwd" => "/Users/me/repos/api"
        },
        note: "background run in a repo"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_authorized", description: "not an attended operator or allowlisted job"},
      %{
        tag: "consent_required",
        description: "the owner has not yet approved coding-agent launches on this machine"
      },
      %{tag: "cwd_denied", description: "the working directory is outside the sandbox roots"},
      %{tag: "cli_unavailable", description: "the claude CLI is not installed or not on PATH"},
      %{tag: "max_active", description: "the concurrent-run limit is reached"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @doc """
  Advertise only when the harness is enabled, the owner has approved coding agents
  on this machine, this vendor is the selected one (or the sole installed option,
  or no default is set), and the authorization gate would pass. `approved` joins
  the gate per design §23.4 — an unusable harness advertises nothing and Fermix
  does the coding itself; `default_vendor` gates visibility so the setup selection
  routes. The un-advertised vendor's tool stays dispatchable by name.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Config.enabled?() and Config.approved?() and
      Authorization.authorize(name(), context) == :ok and
      Vendors.advertise_vendor?(@vendor)
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    HarnessRun.dispatch(spec(), args, context)
  end
end
