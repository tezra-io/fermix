defmodule FermixCore.Capabilities.BuiltinSeeder do
  @moduledoc """
  Synchronous one-shot seeder that registers Fermix's built-in tools as
  `kind: :builtin` capabilities.

  Listed in the supervision tree between `CapabilityRegistry` and
  `SkillRegistry` so built-ins land first. SkillRegistry's `sync_capabilities/3`
  refuses to evict an existing built-in, which combined with the boot order
  guarantees an operator skill named "shell" can never silently shadow the
  built-in shell tool.

  `start_link/1` returns `:ignore` so the supervisor records no child pid —
  the work happens before `start_link` returns.
  """

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  require Logger

  @builtin_tool_modules [
    FermixCore.Tools.Shell,
    FermixCore.Tools.FileRead,
    FermixCore.Tools.FileWrite,
    FermixCore.Tools.MemoryStore,
    FermixCore.Tools.MemoryRecall,
    FermixCore.Tools.ScheduleJob,
    FermixCore.Tools.ListJobs,
    FermixCore.Tools.PauseJob,
    FermixCore.Tools.ResumeJob,
    FermixCore.Tools.RemoveJob,
    FermixCore.Tools.MemorySourcesList,
    FermixCore.Tools.Browser
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

  defp builtin_modules(opts) do
    Keyword.get(opts, :tool_modules, @builtin_tool_modules)
  end
end
