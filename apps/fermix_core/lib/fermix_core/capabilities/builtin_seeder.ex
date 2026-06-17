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
    FermixCore.Tools.SendAttachment
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

  @doc """
  The built-in tool modules seeded into the capability registry at boot.
  Exposed for the classification guard test that asserts every built-in has an
  explicit `policy_class` (see `FermixCore.Capabilities.Builtin`).
  """
  @spec builtin_tool_modules() :: [module()]
  def builtin_tool_modules, do: @builtin_tool_modules ++ @bridge_tool_modules

  defp builtin_modules(opts) do
    case Keyword.fetch(opts, :tool_modules) do
      {:ok, modules} -> modules
      :error -> @builtin_tool_modules ++ bridge_modules()
    end
  end

  defp bridge_modules do
    if Deferral.enabled?(), do: @bridge_tool_modules, else: []
  end
end
