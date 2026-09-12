defmodule FermixCore.Capabilities.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  defmodule StubCaller do
    @behaviour FermixCore.Capabilities.MCP.Caller

    @table :mcp_server_test_caller

    def init do
      cleanup()
      :ets.new(@table, [:named_table, :public, :set])
      :ok
    end

    def cleanup do
      case :ets.whereis(@table) do
        :undefined -> :ok
        tid -> :ets.delete(tid)
      end
    end

    def set_response(server, tool, response) do
      :ets.insert(@table, {{server, tool}, response})
      :ok
    end

    @impl true
    def call_tool(source_id, tool, _args, _context) do
      case :ets.lookup(@table, {source_id, tool}) do
        [{_, response}] -> response
        [] -> {:error, :no_stub_response}
      end
    end
  end

  defmodule StubDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @table :mcp_server_test_discoverer

    def set_tools(tools), do: :persistent_term.put({__MODULE__, :tools}, tools)
    def set_error(reason), do: :persistent_term.put({__MODULE__, :tools}, {:error, reason})

    # A per-call script, fixed BEFORE the server starts: attempt N gets entry N
    # and the last entry repeats. Swapping one answer for another mid-flight is
    # what hid a retry budget behind the test process being scheduled in time.
    #
    # A `{:gate, waiter, result}` entry announces the attempt to `waiter` and
    # blocks in the server until it replies `:discovery_release`, so the test
    # decides when that attempt lands instead of racing it.
    def script(entries) when is_list(entries) do
      cleanup()
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, [{:attempts, 0}, {:script, entries}])
      :ok
    end

    def cleanup do
      case :ets.whereis(@table) do
        :undefined -> :ok
        tid -> :ets.delete(tid)
      end
    end

    @impl true
    def list_tools(_client) do
      case next_scripted() do
        :unscripted -> unscripted_answer()
        {:gate, waiter, attempt, result} -> await_release(waiter, attempt, result)
        result -> result
      end
    end

    defp next_scripted do
      case :ets.whereis(@table) do
        :undefined ->
          :unscripted

        _tid ->
          attempt = :ets.update_counter(@table, :attempts, 1)
          [{:script, entries}] = :ets.lookup(@table, :script)
          entries |> Enum.at(min(attempt - 1, length(entries) - 1)) |> tag(attempt)
      end
    end

    defp tag({:gate, waiter, result}, attempt), do: {:gate, waiter, attempt, result}
    defp tag(result, _attempt), do: result

    defp await_release(waiter, attempt, result) do
      send(waiter, {:discovery_attempt, attempt, self()})

      receive do
        :discovery_release -> result
      after
        5_000 -> {:error, :discovery_release_timeout}
      end
    end

    defp unscripted_answer do
      case :persistent_term.get({__MODULE__, :tools}, []) do
        {:error, reason} -> {:error, reason}
        tools when is_list(tools) -> {:ok, tools}
      end
    end
  end

  setup do
    Naming.init()
    :ok = StubCaller.init()
    suffix = System.unique_integer([:positive])

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"mcp_server_cap_reg_#{suffix}"},
        id: :"mcp_server_cap_reg_child_#{suffix}"
      )

    mcp_registry =
      start_supervised!(
        {McpRegistry, name: :"mcp_server_mcp_reg_#{suffix}"},
        id: :"mcp_server_mcp_reg_child_#{suffix}"
      )

    on_exit(fn ->
      StubCaller.cleanup()
      StubDiscoverer.cleanup()

      try do
        :persistent_term.erase({StubDiscoverer, :tools})
      catch
        _, _ -> :ok
      end

      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    %{cap_registry: cap_registry, mcp_registry: mcp_registry}
  end

  describe "init" do
    test "rejects sanitized MCP names that collide with installed skills", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      suffix = System.unique_integer([:positive])
      skills_dir = FermixTestSupport.SafeRm.make_tmp_dir!("mcp-skill-collision-#{suffix}")
      write_skill(skills_dir, "mcp_github_create_issue")

      skill_registry =
        start_supervised!(
          {SkillRegistry,
           name: :"mcp_collision_skill_registry_#{suffix}",
           skills_dir: skills_dir,
           core_dir: nil,
           seed_defaults: false},
          id: :"mcp_collision_skill_registry_child_#{suffix}"
        )

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)

      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "Create issue.", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "github",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             skill_registry: skill_registry,
             fail_fast?: true
           ]},
          id: :"mcp_server_skill_collision_#{suffix}"
        )

      assert CapabilityRegistry.list(cap_registry, kind: :mcp) == []
    end

    test "registers each discovered tool as an MCP capability and exposes approved ones", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "Create issue.", input_schema: %{}},
        %{name: "list_issues", description: "List issues.", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "github",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             fail_fast?: true
           ]},
          id: :mcp_server_init_test
        )

      names =
        cap_registry
        |> CapabilityRegistry.list(kind: :mcp)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["mcp_github_create_issue", "mcp_github_list_issues"]

      [first | _] = CapabilityRegistry.list(cap_registry, kind: :mcp)
      refute first.hidden_from_agent?
    end

    test "per-tool hidden_from_agent? override hides that tool from the default list", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "x", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "github",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             tools_overrides: %{"create_issue" => %{hidden_from_agent?: true}},
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             fail_fast?: true
           ]},
          id: :mcp_server_hidden_override
        )

      assert CapabilityRegistry.list(cap_registry) == []

      assert [_only] = CapabilityRegistry.list(cap_registry, include_hidden?: true)
    end

    test "exits with a tagged reason when discovery fails (fail_fast?: true)", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_error(:transport_closed)

      Process.flag(:trap_exit, true)

      assert {:error, {:mcp_discovery_failed, "github", :transport_closed}} =
               McpServer.start_link(
                 server_name: "github",
                 discoverer: StubDiscoverer,
                 caller: StubCaller,
                 capability_registry: cap_registry,
                 mcp_registry: mcp_registry,
                 fail_fast?: true
               )
    end

    test "async discovery survives a transient transport error and registers on retry", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      # Both answers are fixed before the server starts: attempt 1 fails, attempt
      # 2 succeeds. Flipping the stub mid-flight put the success behind a ~300ms
      # retry budget, so a descheduled test process spent all five attempts on
      # the error and the server stopped. Attempt 2 also waits for this test's
      # release, which is what makes the empty-registry read below a fact about
      # a transient error rather than about when the flip landed.
      :ok =
        StubDiscoverer.script([
          {:error, :transport_closed},
          {:gate, self(), {:ok, [%{name: "create_issue", description: "x", input_schema: %{}}]}}
        ])

      {:ok, pid} =
        McpServer.start_link(
          server_name: "github",
          discoverer: StubDiscoverer,
          caller: StubCaller,
          capability_registry: cap_registry,
          mcp_registry: mcp_registry,
          retry_base_ms: 20,
          max_discovery_attempts: 5
        )

      # The second attempt being in the discoverer is the proof that the first
      # one failed and was retried; nothing has been registered yet because this
      # attempt cannot return until released.
      assert_receive {:discovery_attempt, 2, ^pid}, 5_000
      assert CapabilityRegistry.list(cap_registry, kind: :mcp) == []

      send(pid, :discovery_release)

      # `:sys.get_state/1` is queued behind the `:discover` continuation the
      # release unblocks, so it returns only once registration has finished: a
      # completion barrier rather than a poll against a retry budget. A
      # successful pass is also what resets the attempt counter.
      assert :sys.get_state(pid).discovery_attempts == 0

      assert [%{name: "mcp_github_create_issue"}] =
               CapabilityRegistry.list(cap_registry, kind: :mcp)

      # The server is linked (start_link); unlink before the kill or the
      # :shutdown exit signal propagates back and kills the test process —
      # a race that only loses when end-of-test work (e.g. capture_log
      # teardown) keeps the test alive long enough for the signal to land.
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end

    test "tool_overrides win for policy_class and hidden_from_agent?", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "read_file", description: "x", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "filesystem",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             tools_overrides: %{
               "read_file" => %{policy_class: :read_only, hidden_from_agent?: false}
             },
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             fail_fast?: true
           ]},
          id: :mcp_server_overrides
        )

      [cap] = CapabilityRegistry.list(cap_registry)
      assert cap.policy_class == :read_only
      assert cap.hidden_from_agent? == false
    end
  end

  describe "terminate" do
    test "unregisters this server's capabilities on shutdown but leaves others", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "x", input_schema: %{}}
      ])

      {:ok, pid} =
        McpServer.start_link(
          server_name: "github",
          discoverer: StubDiscoverer,
          caller: StubCaller,
          capability_registry: cap_registry,
          mcp_registry: mcp_registry,
          fail_fast?: true
        )

      assert [_cap] = CapabilityRegistry.list(cap_registry, kind: :mcp)

      ref = Process.monitor(pid)
      :ok = GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert CapabilityRegistry.list(cap_registry, kind: :mcp) == []
    end

    test "terminate tolerates registries that already died (shutdown race)" do
      Process.flag(:trap_exit, true)
      suffix = System.unique_integer([:positive])
      {:ok, cap_reg} = CapabilityRegistry.start_link(name: :"race_cap_#{suffix}")
      {:ok, mcp_reg} = McpRegistry.start_link(name: :"race_mcp_#{suffix}")

      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "x", input_schema: %{}}
      ])

      {:ok, pid} =
        McpServer.start_link(
          server_name: "github",
          # A pid client so `is_pid(state.client)` holds and terminate/2 exercises
          # BOTH wrapped unregister sites (capability + mcp registry).
          client: self(),
          discoverer: StubDiscoverer,
          caller: StubCaller,
          capability_registry: cap_reg,
          mcp_registry: mcp_reg,
          fail_fast?: true
        )

      # Both registries die BEFORE the server terminates — the shutdown race that
      # made terminate/2's unregister GenServer.call exit :noproc and crash,
      # leaking the capability into later tests.
      :ok = GenServer.stop(cap_reg, :normal)
      :ok = GenServer.stop(mcp_reg, :normal)

      # terminate must clean up without crashing, so the stop returns :ok and the
      # server honors the requested :normal exit rather than dying (`:noproc`) on
      # the dead registries. Without the fix, GenServer.stop/2 re-raises the
      # mismatched exit and this line fails.
      ref = Process.monitor(pid)
      assert :ok = GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  # The staleness window the hook exists to close: a config reload invalidates
  # BEFORE discovery finishes, so without this the agent caches a pre-discovery
  # tool list indefinitely. It lands at the shared registration-completion
  # point, so a local stdio server closes the same window as a remote one.
  describe "runtime-context refresh" do
    defmodule StubMainAgent do
      @moduledoc false
      use GenServer

      def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

      @impl true
      def init(parent), do: {:ok, parent}

      @impl true
      def handle_call({:invalidate_runtime_context, reason}, _from, parent) do
        send(parent, {:invalidated, reason})
        {:reply, :ok, parent}
      end
    end

    test "completing registration invalidates the agent's cached context", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      {:ok, main_agent} = StubMainAgent.start_link(self())

      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "Create issue.", input_schema: %{}}
      ])

      start_supervised!(
        {McpServer,
         [
           server_name: "github",
           discoverer: StubDiscoverer,
           caller: StubCaller,
           capability_registry: cap_registry,
           mcp_registry: mcp_registry,
           skill_registry: nil,
           main_agent: main_agent,
           realtime_supervisor: nil
         ]},
        id: :mcp_server_refresh_test
      )

      assert_receive {:invalidated, :plugins_changed}
    end

    test "unregistering on shutdown invalidates it again", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      {:ok, main_agent} = StubMainAgent.start_link(self())

      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "Create issue.", input_schema: %{}}
      ])

      {:ok, pid} =
        McpServer.start_link(
          server_name: "github",
          discoverer: StubDiscoverer,
          caller: StubCaller,
          capability_registry: cap_registry,
          mcp_registry: mcp_registry,
          skill_registry: nil,
          main_agent: main_agent,
          realtime_supervisor: nil
        )

      assert_receive {:invalidated, :plugins_changed}
      assert eventually(fn -> CapabilityRegistry.list(cap_registry, kind: :mcp) != [] end)

      :ok = GenServer.stop(pid, :normal)

      assert_receive {:invalidated, :plugins_changed}
    end
  end

  defp write_skill(skills_dir, name) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: Use #{name}.
      allowed_tools: []
      ---
      Body.
      """
    )
  end

  defp eventually(fun, deadline_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        poll(fun, deadline)
      end
    end
  end
end
