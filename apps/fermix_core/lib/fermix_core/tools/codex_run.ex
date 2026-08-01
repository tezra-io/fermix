defmodule FermixCore.Tools.CodexRun do
  @moduledoc """
  Delegate repo coding work to a local Codex run (`codex exec --json`).

  The tool authorizes the caller (attended operator or an allowlisted scheduled
  job), sandbox-checks `cwd`, resolves where the terminal message must go, and
  admits the run through `Harness.Manager`. Runs are background-only (design
  §23.1): the tool returns the run id immediately and the outcome comes back on
  its own — into this conversation for a chat origin, as durable delivery for a
  scheduled one.

  Posture is the operator's, not the model's. Omitting `sandbox` emits no `-s` at
  all, so the run inherits `~/.codex/config.toml` — that is the default and the
  reason harness runs are autonomous without the model asking for anything. Note
  what that inherits when the operator has configured nothing: codex's own default
  for `exec` is `read-only` (verified against codex-cli 0.145.0 by reading the
  recorded `turn_context.sandbox_policy`), so an unconfigured host runs read-only
  unless the caller asks for `workspace-write`. The model may pick either
  confining level (`workspace-write` writes freely inside the admitted
  directories without prompting), but `danger-full-access` is
  refused at the tool boundary; see `HarnessSupport.@boundary_removing`.
  On a `resume` the level is honored too, via the config override the resume
  command accepts — and a resumed thread already inherits its own recorded policy,
  so passing `sandbox` there only matters to *change* posture mid-thread.
  `profile` remains selectable: it names a posture the operator authored in their
  own config, which is a different thing from the model inventing one.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Adapters.CodexExec
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Vendors
  alias FermixCore.Tools.HarnessRun
  alias FermixCore.Tools.HarnessSupport, as: Support

  @vendor "codex"

  # Fixed string → atom table (spec C1: no `String.to_atom` on model input).
  @param_keys %{
    "model" => :model,
    "effort" => :effort,
    "sandbox" => :sandbox,
    "add_dirs" => :add_dirs,
    "ephemeral" => :ephemeral,
    "profile" => :profile,
    "images" => :images,
    "output_schema" => :output_schema,
    "resume" => :resume
  }

  @spec spec() :: HarnessRun.spec()
  def spec, do: %{name: name(), vendor: @vendor, adapter: CodexExec, key_table: @param_keys}

  @impl true
  @spec name() :: String.t()
  def name, do: "codex_run"

  @impl true
  @spec description() :: String.t()
  def description do
    "Run a Codex coding task inside a repository (codex exec). Runs in the " <>
      "background; the outcome comes back on its own when it finishes."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["prompt", "cwd"],
      properties: %{
        prompt: %{type: "string", description: "The coding task for Codex to carry out."},
        cwd: %{type: "string", description: "Absolute path of the repository/working directory."},
        model: %{type: "string", description: "Optional Codex model override."},
        effort: %{
          type: "string",
          description: "Optional reasoning effort (model_reasoning_effort override)."
        },
        sandbox: %{
          type: "string",
          enum: ["read-only", "workspace-write"],
          description:
            "Codex sandbox mode. Omit to use the operator's configured posture. " <>
              "`workspace-write` writes freely inside the admitted directories " <>
              "without prompting."
        },
        add_dirs: %{
          type: "array",
          items: %{type: "string"},
          description: "Extra writable directories (each --add-dir; also locked)."
        },
        ephemeral: %{
          type: "boolean",
          description: "Write no session files (not resumable)."
        },
        profile: %{type: "string", description: "Named Codex profile."},
        images: %{
          type: "array",
          items: %{type: "string"},
          description: "Image file paths to attach (each -i)."
        },
        output_schema: %{type: "string", description: "Path to a JSON output-schema file."},
        resume: %{type: "string", description: "Resume a prior Codex thread id."},
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
      "through a repository — delegate to a Codex run instead of editing files " <>
      "yourself. Reserve your own tools for the genuinely incidental (a quick " <>
      "calculation, reading one file, scratch work outside any project)."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"prompt" => "Fix the failing auth test", "cwd" => "/Users/me/repos/app"},
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
      %{tag: "cli_unavailable", description: "the codex CLI is not installed or not on PATH"},
      %{tag: "max_active", description: "the concurrent-run limit is reached"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @doc """
  Advertise only when the harness is enabled, the owner has approved coding agents
  on this machine, the turn's channel can carry a coding run at all
  (`HarnessSupport.advertisable_channel?/1`), this vendor is the selected one (or
  the sole installed option, or no default is set), and the authorization gate
  would pass. `approved` joins
  the gate per design §23.4 — an unusable harness advertises nothing and Fermix
  does the coding itself; `default_vendor` gates visibility so the setup selection
  routes. The un-advertised vendor's tool stays dispatchable by name.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Config.enabled?() and Config.approved?() and
      Support.advertisable_channel?(context) and
      Authorization.authorize(name(), context) == :ok and
      Vendors.advertise_vendor?(@vendor)
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    HarnessRun.dispatch(spec(), args, context)
  end
end
