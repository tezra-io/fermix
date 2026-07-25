defmodule FermixCore.Capabilities.BuiltinSeeder do
  @moduledoc """
  Synchronous one-shot seeder that registers Fermix's built-in tools as
  `kind: :builtin` capabilities.

  Listed in the supervision tree between `CapabilityRegistry` and
  `SkillRegistry` so built-ins land first. Skill discovery refuses names that
  collide with registered capabilities, which prevents an operator skill named
  "shell" from silently shadowing the built-in shell tool.

  `start_link/1` returns `:ignore` so the supervisor records no child pid —
  the work happens before `start_link` returns.
  """

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ComputerUse
  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Harness.Vendors

  require Logger

  @compiled_env Mix.env()

  @builtin_tool_modules [
    FermixCore.Tools.Shell,
    FermixCore.Tools.FileRead,
    FermixCore.Tools.FileWrite,
    FermixCore.Tools.FileEdit,
    FermixCore.Tools.GlobSearch,
    FermixCore.Tools.ContentSearch,
    FermixCore.Tools.GitRead,
    FermixCore.Tools.GitWrite,
    FermixCore.Tools.WebFetch,
    FermixCore.Tools.WebSearch,
    FermixCore.Tools.SkillCreate,
    FermixCore.Tools.SkillReload,
    FermixCore.Tools.SkillView,
    FermixCore.Tools.SkillRun,
    FermixCore.Tools.SkillList,
    FermixCore.Tools.Subagents,
    FermixCore.Tools.ModelRoutingConfig,
    FermixCore.Tools.ToolHelp,
    FermixCore.Tools.MemoryStore,
    FermixCore.Tools.MemoryRecall,
    FermixCore.Tools.ScheduleJob,
    FermixCore.Tools.UpdateJob,
    FermixCore.Tools.ListJobs,
    FermixCore.Tools.PauseJob,
    FermixCore.Tools.ResumeJob,
    FermixCore.Tools.RemoveJob,
    FermixCore.Tools.RunJobNow,
    FermixCore.Tools.ListJobRuns,
    FermixCore.Tools.GetJobRun,
    FermixCore.Tools.MemorySourcesList,
    FermixCore.Tools.Browser,
    FermixCore.Tools.SendAttachment,
    FermixCore.Tools.React,
    FermixCore.Tools.GenerateImage,
    FermixCore.Tools.RequestDirectoryAccess
  ]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    server = Keyword.get(opts, :capability_registry, CapabilityRegistry)

    Enum.each(builtin_modules(opts), fn tool_module ->
      capability = Builtin.from_tool_module(tool_module)

      case CapabilityRegistry.register(server, capability) do
        :ok ->
          :ok

        {:error, {:duplicate_name, name}} ->
          Logger.warning(
            "BuiltinSeeder: capability #{inspect(name)} already registered before " <>
              "built-in seed; leaving existing entry untouched."
          )
      end
    end)

    :ignore
  end

  # The M10 bridge tools: seeded only when tool-schema deferral is enabled
  # (off = zero residue — absent from registry, prompt, and wire).
  @bridge_tool_modules [
    FermixCore.Tools.ToolSearch,
    FermixCore.Tools.ToolDescribe,
    FermixCore.Tools.ToolCall
  ]

  # Computer use: the single tool is seeded only when `ComputerUse.ready?()`
  # (enabled + sidecar installed + OS permissions granted). Disabled-or-unready =
  # zero residue: the LLM never sees a tool it cannot run. Re-evaluated each boot,
  # which (with the save+restart enable flow) is the readiness-transition trigger.
  @computer_use_tool_modules [FermixCore.Tools.ComputerUse]

  # Coding harness: seeded only when the harness is enabled (config) AND the
  # relevant vendor CLI is detected at boot — the §7.3 boot snapshot. The two run
  # tools seed per-vendor (codex_run needs `codex`, claude_code_run needs
  # `claude`); the history/manage tools seed whenever EITHER CLI is present, since
  # they operate on run history. Availability is snapshotted here: installing a
  # CLI or changing config takes effect on the next daemon restart.
  @harness_local_run_modules [
    {"codex", FermixCore.Tools.CodexRun},
    {"claude", FermixCore.Tools.ClaudeCodeRun}
  ]
  # The cloud run + its stop-tracking manage tool ride the codex CLI (cloud is a
  # `codex cloud` subcommand + ChatGPT auth), so both seed with the `codex` vendor
  # — but ONLY when `[fermix_core.harness] cloud_enabled` is true. The cloud rail
  # is off by default this release: with it off these tools never seed, so they
  # never advertise or dispatch (the manager cloud lifecycle stays in-tree, simply
  # never entered). Flip the flag + restart to revive it.
  @harness_cloud_run_modules [
    {"codex", FermixCore.Tools.CodexCloudRun},
    {"codex", FermixCore.Tools.StopTrackingCodingRun}
  ]
  @harness_history_modules [
    FermixCore.Tools.ListCodingRuns,
    FermixCore.Tools.GetCodingRun,
    FermixCore.Tools.CancelCodingRun
  ]
  @harness_tool_modules [
    FermixCore.Tools.CodexRun,
    FermixCore.Tools.CodexCloudRun,
    FermixCore.Tools.ClaudeCodeRun,
    FermixCore.Tools.ListCodingRuns,
    FermixCore.Tools.GetCodingRun,
    FermixCore.Tools.CancelCodingRun,
    FermixCore.Tools.StopTrackingCodingRun
  ]

  @doc """
  Every built-in tool module that can be seeded into the capability registry —
  the unconditional ones plus the conditionally-seeded bridge and computer-use
  tools. Exposed for the classification guard test that asserts every built-in has
  an explicit `policy_class` (see `FermixCore.Capabilities.Builtin`); membership
  here is about classification coverage, not whether a tool is seeded on a given boot.
  """
  @spec builtin_tool_modules() :: [module()]
  def builtin_tool_modules,
    do:
      @builtin_tool_modules ++
        @bridge_tool_modules ++ @computer_use_tool_modules ++ @harness_tool_modules

  defp builtin_modules(opts) do
    case Keyword.fetch(opts, :tool_modules) do
      {:ok, modules} ->
        modules

      :error ->
        @builtin_tool_modules ++
          bridge_modules() ++ computer_use_modules() ++ auto_harness_modules()
    end
  end

  # `mix test` boots the app tree, and ConfigStore replaces `:harness` at boot
  # (defaulting `enabled: true`) while both vendor CLIs are typically on the
  # dev/CI PATH — so auto-seeding would pull the harness tools into the shared
  # test registry and perturb registry-wide tests. Suppress that on the
  # compile-time env (release-safe; the FermixOpik.enabled? pattern). Production
  # seeds normally, and `harness_modules/1` stays directly callable so the
  # gating logic is still exercised hermetically.
  defp auto_harness_modules do
    if @compiled_env == :test, do: [], else: harness_modules()
  end

  defp bridge_modules do
    if Deferral.enabled?(), do: @bridge_tool_modules, else: []
  end

  defp computer_use_modules do
    if ComputerUse.ready?(), do: @computer_use_tool_modules, else: []
  end

  @doc """
  The coding-harness tool modules that would be seeded given the current config
  and vendor detection — `[]` when the harness is disabled or no vendor CLI is
  present. The cloud run + stop-tracking tools are additionally gated on
  `cloud_enabled?` (off by default this release). Exposed (with injectable
  `:harness_enabled`/`:cloud_enabled`/`:vendor_available_fn` seams) so the
  seeding-gating test stays hermetic.
  """
  @spec harness_modules(keyword()) :: [module()]
  def harness_modules(opts \\ []) when is_list(opts) do
    if harness_enabled?(opts), do: detected_harness_modules(opts), else: []
  end

  defp harness_enabled?(opts) do
    Keyword.get_lazy(opts, :harness_enabled, &HarnessConfig.enabled?/0)
  end

  defp cloud_enabled?(opts) do
    Keyword.get_lazy(opts, :cloud_enabled, &HarnessConfig.cloud_enabled?/0)
  end

  defp detected_harness_modules(opts) do
    available? = Keyword.get(opts, :vendor_available_fn, &Vendors.available?/1)

    run_modules =
      opts
      |> run_module_specs()
      |> Enum.filter(fn {vendor, _module} -> available?.(vendor) end)
      |> Enum.map(fn {_vendor, module} -> module end)

    run_modules ++ history_modules(run_modules)
  end

  defp run_module_specs(opts) do
    if cloud_enabled?(opts) do
      @harness_local_run_modules ++ @harness_cloud_run_modules
    else
      @harness_local_run_modules
    end
  end

  defp history_modules([]), do: []
  defp history_modules(_run_modules), do: @harness_history_modules
end
