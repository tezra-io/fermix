defmodule FermixCore.Plugins.RuntimeTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Runtime

  defmodule MainAgentStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call({:invalidate_runtime_context, reason}, _from, parent) do
      send(parent, {:invalidated, reason})
      {:reply, :ok, parent}
    end

    def handle_call(:reload_skills, _from, parent) do
      send(parent, :skills_reloaded)
      {:reply, {:ok, %{skills: []}}, parent}
    end
  end

  # A MainAgent whose skill reload fails — to prove the agent-prompt invalidation
  # is decoupled from (and not skipped by) a downstream reload failure.
  defmodule FailingSkillsStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call({:invalidate_runtime_context, reason}, _from, parent) do
      send(parent, {:invalidated, reason})
      {:reply, :ok, parent}
    end

    def handle_call(:reload_skills, _from, parent) do
      send(parent, :skills_reloaded)
      {:reply, {:error, :boom}, parent}
    end
  end

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugins-runtime")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :plugins, enabled: [])

    registry = :"plugins_runtime_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{registry: registry}
  end

  test "reload invalidates the MainAgent runtime context after capability reload", %{
    registry: registry
  } do
    stub = start_supervised!({MainAgentStub, self()})

    assert {:ok, summary} =
             Runtime.reload(
               capability_registry: registry,
               skill_registry: nil,
               main_agent: stub,
               realtime_supervisor: nil
             )

    assert_received {:invalidated, :plugins_changed}
    assert_received :skills_reloaded
    assert summary.skills == :handled_by_main_agent
  end

  test "reload invalidates the agent and surfaces the failure even when skill reload errors",
       %{registry: registry} do
    stub = start_supervised!({FailingSkillsStub, self()})

    assert {:error, {:reload_incomplete, failures}} =
             Runtime.reload(
               capability_registry: registry,
               skill_registry: :no_such_skill_registry,
               main_agent: stub,
               realtime_supervisor: nil
             )

    # The agent's cached prompt is dropped regardless of the downstream failure,
    assert_received {:invalidated, :plugins_changed}
    # and the failure is surfaced (not silently swallowed).
    assert {:main_agent, :boom} in failures
  end

  test "reload still succeeds when no MainAgent is running", %{registry: registry} do
    assert {:ok, summary} =
             Runtime.reload(
               capability_registry: registry,
               skill_registry: nil,
               main_agent: :no_such_main_agent,
               realtime_supervisor: nil
             )

    assert summary.main_agent == :skipped
    refute_received {:invalidated, _reason}
  end

  test "reload skips the MCP supervisor when it is not running", %{registry: registry} do
    assert {:ok, summary} =
             Runtime.reload(
               capability_registry: registry,
               skill_registry: nil,
               main_agent: :no_such_main_agent,
               realtime_supervisor: nil,
               mcp_supervisor: :no_such_mcp_supervisor
             )

    assert summary.mcp == :skipped
  end

  test "reload diffs the MCP supervisor when it is running", %{registry: registry} do
    suffix = System.unique_integer([:positive])

    mcp_sup =
      start_supervised!(
        {FermixCore.Capabilities.MCP.Supervisor,
         [
           name: :"runtime_mcp_sup_#{suffix}",
           mcp_registry: :"runtime_mcp_reg_#{suffix}",
           capability_registry: registry,
           servers: []
         ]},
        id: :runtime_mcp_sup_test
      )

    assert {:ok, summary} =
             Runtime.reload(
               capability_registry: registry,
               skill_registry: nil,
               main_agent: :no_such_main_agent,
               realtime_supervisor: nil,
               mcp_supervisor: mcp_sup
             )

    assert %{started: [], stopped: [], unchanged: []} = summary.mcp
  end
end
