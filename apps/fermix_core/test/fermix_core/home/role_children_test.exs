defmodule FermixCore.Home.RoleChildrenTest do
  # async: false: the core child list reads application environment that other
  # suites set (the daemon socket, open loops, memory), and the gated-children
  # case below sets two of those keys itself.
  use ExUnit.Case, async: false

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Home.Role
  alias FermixCore.Net.Egress

  # Started in every boot, so present in this environment's list too.
  @primary_only_here [
    FermixCore.Jobs.RunnerSupervisor,
    FermixCore.Jobs.Scheduler,
    FermixCore.Temporal.Scheduler,
    FermixCore.Temporal.DeliverySupervisor,
    FermixCore.Harness.Supervisor,
    FermixCore.Meetings.Supervisor,
    FermixCore.Auth.TokenSupervisor,
    FermixCore.Home.Snapshot.Scheduler,
    FermixCore.Plugins.Dist.Reinstall
  ]

  @kept_here [
    FermixCore.CommandHost.Supervisor,
    Finch,
    FermixCore.Trace,
    FermixCore.Browser.Supervisor,
    FermixCore.Capabilities.Registry,
    FermixCore.Capabilities.MCP.Supervisor,
    FermixCore.Memory.Repo,
    FermixCore.Memory.ConversationStore,
    FermixCore.Memory.Store,
    FermixCore.Setup.BootReport,
    FermixCore.Setup.RestartState,
    FermixCore.Sandbox.EnvHealth,
    FermixCore.Agents.AgentSupervisor,
    FermixCore.Agents.MainAgent
  ]

  # Present only in a daemon boot or behind a switch, so named by module.
  @kept_elsewhere [
    FermixCore.Management.Lifecycle,
    FermixCore.Management.Doctor,
    FermixCore.Management.Jobs,
    FermixCore.Management.Plugins.Discovery,
    FermixCore.Management.McpServers.DraftValues,
    Fermix.CLI.Daemon,
    FermixCore.NativeHost.Supervisor,
    FermixCore.ComputerUse.Supervisor,
    FermixCore.ComputerHistory.Supervisor
  ]

  defp modules(children), do: Enum.map(children, &module/1)

  defp module(%{start: {module, _function, _args}}), do: module
  defp module({module, _arg}), do: module
  defp module(module) when is_atom(module), do: module

  defp tree(role), do: CoreApplication.supervision_children(Egress.new([]), role)

  test "the primary starts the primary-only children this boot declares" do
    primary = modules(tree(:primary))

    for module <- @primary_only_here ++ @kept_here do
      assert module in primary, "the primary tree lost #{inspect(module)}"
    end
  end

  test "a device starts the same tree without one primary-only child, in the same order" do
    primary = tree(:primary)
    device = tree(:device)

    for module <- Role.primary_only() do
      refute module in modules(device), "a device tree starts #{inspect(module)}"
    end

    for module <- @kept_here do
      assert module in modules(device), "a device tree lost #{inspect(module)}"
    end

    assert device == Enum.reject(primary, &(module(&1) in Role.primary_only()))
  end

  test "every daemon-only and switched child a device keeps is kept" do
    assert Role.children(@kept_elsewhere, :device) == @kept_elsewhere
  end

  # M75 D5: the token file here is a retired copy and a realtime session calls a
  # provider with it, so a device starts neither.
  test "a device starts no realtime subtree and no token supervisor" do
    switched = [FermixCore.Realtime.Supervisor, FermixCore.Auth.TokenSupervisor]

    assert Role.children(switched, :primary) == switched
    assert Role.children(switched, :device) == []
  end

  describe "the children a switch gates" do
    setup do
      saved =
        for key <- [:open_loops, :memory, :skill_curation],
            do: {key, Application.fetch_env(:fermix_core, key)}

      on_exit(fn ->
        for {key, value} <- saved do
          case value do
            {:ok, value} -> Application.put_env(:fermix_core, key, value)
            :error -> Application.delete_env(:fermix_core, key)
          end
        end
      end)

      Application.put_env(:fermix_core, :open_loops, enabled: true)
      Application.put_env(:fermix_core, :memory, enabled: true)
      Application.put_env(:fermix_core, :skill_curation, enabled: true)
      :ok
    end

    test "are started for the primary and left out for a device" do
      gated =
        CoreApplication.maybe_open_loops_children(:prod) ++
          CoreApplication.maybe_skill_curation_scheduler(:prod) ++
          [FermixCore.Cues.Supervisor]

      assert modules(gated) == [
               FermixCore.OpenLoops.Scheduler,
               FermixCore.OpenLoops.CheckInSupervisor,
               FermixCore.SkillCuration.Scheduler,
               FermixCore.Cues.Supervisor
             ]

      assert Role.children(gated, :primary) == gated
      assert Role.children(gated, :device) == []
    end
  end
end
