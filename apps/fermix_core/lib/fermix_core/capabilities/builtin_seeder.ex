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
  alias FermixCore.Watch

  require Logger

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
    FermixCore.Tools.GenerateImage
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

  # Watch mode: the `watch`/`stop_watch` tools are seeded only when
  # `Watch.enabled?()` (off by default) — same zero-residue property as
  # computer-use, re-evaluated each boot.
  @watch_tool_modules [FermixCore.Tools.Watch, FermixCore.Tools.StopWatch]

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
        @bridge_tool_modules ++ @computer_use_tool_modules ++ @watch_tool_modules

  defp builtin_modules(opts) do
    case Keyword.fetch(opts, :tool_modules) do
      {:ok, modules} ->
        modules

      :error ->
        @builtin_tool_modules ++ bridge_modules() ++ computer_use_modules() ++ watch_modules()
    end
  end

  defp bridge_modules do
    if Deferral.enabled?(), do: @bridge_tool_modules, else: []
  end

  defp computer_use_modules do
    if ComputerUse.ready?(), do: @computer_use_tool_modules, else: []
  end

  defp watch_modules do
    if Watch.enabled?(), do: @watch_tool_modules, else: []
  end
end
