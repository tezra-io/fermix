defmodule FermixCore.Capabilities.MCP.SupervisorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Sandbox.Config, as: SandboxConfig

  defmodule StubCaller do
    @behaviour FermixCore.Capabilities.MCP.Caller

    @impl true
    def call_tool(_server, _tool, _args), do: {:ok, "stub-response"}
  end

  defmodule HappyDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @impl true
    def list_tools(_client) do
      {:ok,
       [
         %{name: "create_issue", description: "Create issue.", input_schema: %{}},
         %{name: "list_issues", description: "List issues.", input_schema: %{}}
       ]}
    end
  end

  defmodule SadDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @impl true
    def list_tools(_client), do: {:error, :transport_closed}
  end

  # Always fails, and reports each attempt to the pid passed as the client. Lets
  # a test count how many times discovery re-runs before the subtree quarantines.
  defmodule CountingSadDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @impl true
    def list_tools(reporter) when is_pid(reporter) do
      send(reporter, :broken_discovery_attempt)
      {:error, :transport_closed}
    end
  end

  defmodule FakeAnubis do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts) do
      send(opts[:reporter], {:fake_anubis_started, opts})
      {:ok, opts}
    end
  end

  defmodule RecordingAnubisStarter do
    @moduledoc false
    @behaviour FermixCore.Capabilities.MCP.AnubisStarter

    @impl true
    def child_specs_for(server) do
      reporter = Map.get(server, :reporter)

      case Map.get(server, :command) do
        cmd when is_binary(cmd) and cmd != "" and is_pid(reporter) ->
          send(reporter, {:anubis_starter_invoked, server})

          client_name = :"recording_anubis_client_#{server.name}"

          base_opts = [
            name: client_name,
            reporter: reporter,
            command: cmd,
            args: Map.get(server, :args, []),
            env: Map.get(server, :env, %{})
          ]

          spec =
            Supervisor.child_spec({FakeAnubis, base_opts},
              id: {:fake_anubis, server.name},
              restart: :permanent
            )

          %{children: [spec], client_name: client_name}

        _ ->
          %{children: [], client_name: nil}
      end
    end
  end

  setup do
    Naming.init()
    suffix = System.unique_integer([:positive])
    sandbox = Application.get_env(:fermix_core, :sandbox)
    pass_token = System.get_env("FERMIX_MCP_PASS_TOKEN")

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"mcp_sup_cap_reg_#{suffix}"},
        id: :"mcp_sup_cap_reg_child_#{suffix}"
      )

    on_exit(fn ->
      restore_sandbox(sandbox)
      restore_env("FERMIX_MCP_PASS_TOKEN", pass_token)

      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    %{cap_registry: cap_registry, suffix: suffix}
  end

  test "boots a healthy server and exposes its discovered tools as capabilities", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_happy_#{suffix}",
           mcp_registry: :"mcp_sup_happy_reg_#{suffix}",
           capability_registry: cap_registry,
           servers: [
             %{
               name: "github",
               discoverer: HappyDiscoverer,
               caller: StubCaller
             }
           ]
         ]},
        id: :mcp_supervisor_happy_test
      )

    assert eventually(fn ->
             names =
               cap_registry
               |> CapabilityRegistry.list(kind: :mcp)
               |> Enum.map(& &1.name)
               |> Enum.sort()

             names == ["mcp_github_create_issue", "mcp_github_list_issues"]
           end)
  end

  test "an unhealthy server's restart loop does not bring down healthy peers", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    Process.flag(:trap_exit, true)

    sup_name = :"mcp_sup_mixed_#{suffix}"

    {:ok, sup_pid} =
      McpSupervisor.start_link(
        name: sup_name,
        mcp_registry: :"mcp_sup_mixed_reg_#{suffix}",
        capability_registry: cap_registry,
        servers: [
          %{
            name: "github",
            discoverer: HappyDiscoverer,
            caller: StubCaller
          },
          %{
            name: "broken",
            discoverer: SadDiscoverer,
            caller: StubCaller
          }
        ]
      )

    on_exit(fn ->
      if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
    end)

    assert eventually(fn ->
             "mcp_github_create_issue" in cap_names(cap_registry)
           end)

    assert Process.alive?(sup_pid)
    refute Enum.any?(cap_names(cap_registry), &String.starts_with?(&1, "mcp_broken_"))
  end

  test "a server that gives up on discovery is quarantined after ONE cycle, not respawned", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    # Production incident: a permanently-unreachable MCP server (obsidian, whose
    # vault path did not exist) logged "giving up" but was a :permanent child, so
    # it respawned forever — ~20-40 node spawns/min feeding the machine load. The
    # give-up must be terminal for the boot: after the server exhausts its
    # discovery retries once, its whole subtree (client + discovery) is torn down
    # and NOT respawned until an explicit reload. `:permanent` re-ran discovery
    # ~4x (until the sub-supervisor's restart intensity tripped); the fix stops
    # it after the first cycle.
    Process.flag(:trap_exit, true)
    sup_name = :"mcp_sup_giveup_#{suffix}"
    reporter = self()

    {:ok, sup_pid} =
      McpSupervisor.start_link(
        name: sup_name,
        mcp_registry: :"mcp_sup_giveup_reg_#{suffix}",
        capability_registry: cap_registry,
        servers: [
          %{name: "github", discoverer: HappyDiscoverer, caller: StubCaller},
          %{
            name: "broken",
            discoverer: CountingSadDiscoverer,
            caller: StubCaller,
            client: reporter,
            max_discovery_attempts: 1,
            retry_base_ms: 1
          }
        ]
      )

    on_exit(fn -> if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown) end)

    # Exactly one discovery cycle runs, then silence — no respawn re-attempts.
    assert_receive :broken_discovery_attempt, 500
    refute_receive :broken_discovery_attempt, 300

    # The broken subtree is gone; the healthy peer and top supervisor are intact.
    assert server_child_pid(sup_name, "broken") == nil
    assert Process.alive?(sup_pid)
    assert eventually(fn -> "mcp_github_create_issue" in cap_names(cap_registry) end)
  end

  test "spawns the configured Anubis starter once per server with command/args/env", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_anubis_#{suffix}",
           mcp_registry: :"mcp_sup_anubis_reg_#{suffix}",
           capability_registry: cap_registry,
           anubis_starter: RecordingAnubisStarter,
           servers: [
             %{
               name: "github",
               discoverer: HappyDiscoverer,
               caller: StubCaller,
               command: "npx",
               args: ["-y", "@modelcontextprotocol/server-github"],
               env: %{"TOKEN" => "secret"},
               reporter: self()
             }
           ]
         ]},
        id: :mcp_supervisor_anubis_test
      )

    assert_receive {:anubis_starter_invoked, server}, 500
    assert server.command == "npx"
    assert server.args == ["-y", "@modelcontextprotocol/server-github"]
    assert server.env["TOKEN"] == "secret"

    assert_receive {:fake_anubis_started, opts}, 500
    assert opts[:command] == "npx"
    assert opts[:env]["TOKEN"] == "secret"
  end

  test "resolves pass_env through Sandbox.Env and preserves literal env precedence", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    System.put_env("FERMIX_MCP_PASS_TOKEN", "from-env")

    Application.put_env(
      :fermix_core,
      :sandbox,
      SandboxConfig.normalize(env: [allow: ["FERMIX_MCP_PASS_TOKEN"]])
    )

    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_pass_env_#{suffix}",
           mcp_registry: :"mcp_sup_pass_env_reg_#{suffix}",
           capability_registry: cap_registry,
           anubis_starter: RecordingAnubisStarter,
           servers: [
             %{
               name: "github",
               discoverer: HappyDiscoverer,
               caller: StubCaller,
               command: "npx",
               env: %{"PATH" => "/opt/custom/bin"},
               pass_env: ["FERMIX_MCP_PASS_TOKEN"],
               reporter: self()
             }
           ]
         ]},
        id: :mcp_supervisor_pass_env_test
      )

    assert_receive {:fake_anubis_started, opts}, 500
    assert opts[:env]["FERMIX_MCP_PASS_TOKEN"] == "from-env"
    assert opts[:env]["PATH"] == "/opt/custom/bin"
  end

  test "allows undeclared pass_env in all env mode", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    System.put_env("FERMIX_MCP_PASS_TOKEN", "from-env")
    Application.put_env(:fermix_core, :sandbox, SandboxConfig.normalize(env: [mode: :all]))

    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_pass_env_all_#{suffix}",
           mcp_registry: :"mcp_sup_pass_env_all_reg_#{suffix}",
           capability_registry: cap_registry,
           anubis_starter: RecordingAnubisStarter,
           servers: [
             %{
               name: "github",
               discoverer: HappyDiscoverer,
               caller: StubCaller,
               command: "npx",
               pass_env: ["FERMIX_MCP_PASS_TOKEN"],
               reporter: self()
             }
           ]
         ]},
        id: :mcp_supervisor_pass_env_all_test
      )

    assert_receive {:fake_anubis_started, opts}, 500
    assert opts[:env]["FERMIX_MCP_PASS_TOKEN"] == "from-env"
  end

  test "rejects selected-mode pass_env names that are not allowed", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    Application.put_env(:fermix_core, :sandbox, SandboxConfig.normalize(env: [allow: []]))

    assert_raise ArgumentError, ~r/FERMIX_MCP_PASS_TOKEN is not allowed/, fn ->
      McpSupervisor.init(
        name: :"mcp_sup_pass_env_denied_#{suffix}",
        mcp_registry: :"mcp_sup_pass_env_denied_reg_#{suffix}",
        capability_registry: cap_registry,
        anubis_starter: RecordingAnubisStarter,
        servers: [%{name: "github", command: "npx", pass_env: ["FERMIX_MCP_PASS_TOKEN"]}]
      )
    end
  end

  test "rejects denied pass_env names in all env mode", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    Application.put_env(
      :fermix_core,
      :sandbox,
      SandboxConfig.normalize(env: [mode: :all, deny: ["FERMIX_MCP_PASS_TOKEN"]])
    )

    assert_raise ArgumentError, ~r/FERMIX_MCP_PASS_TOKEN is denied/, fn ->
      McpSupervisor.init(
        name: :"mcp_sup_pass_env_all_denied_#{suffix}",
        mcp_registry: :"mcp_sup_pass_env_all_denied_reg_#{suffix}",
        capability_registry: cap_registry,
        anubis_starter: RecordingAnubisStarter,
        servers: [%{name: "github", command: "npx", pass_env: ["FERMIX_MCP_PASS_TOKEN"]}]
      )
    end
  end

  test "a plugin-owned server registers tools under its <plugin>_ prefix with merged metadata",
       %{cap_registry: cap_registry, suffix: suffix} do
    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_prefix_#{suffix}",
           mcp_registry: :"mcp_sup_prefix_reg_#{suffix}",
           capability_registry: cap_registry,
           servers: [
             %{
               name: "obsidian",
               prefix: "obsidian_",
               capability_metadata: %{
                 plugin_owned?: true,
                 plugin: "obsidian",
                 category: :plugin
               },
               discoverer: HappyDiscoverer,
               caller: StubCaller
             }
           ]
         ]},
        id: :mcp_supervisor_prefix_test
      )

    assert eventually(fn ->
             cap_names(cap_registry) |> Enum.sort() ==
               ["obsidian_create_issue", "obsidian_list_issues"]
           end)

    {:ok, cap} = CapabilityRegistry.find(cap_registry, "obsidian_create_issue")
    assert cap.metadata.plugin_owned? == true
    assert cap.metadata.plugin == "obsidian"
    assert cap.metadata.category == :plugin
    assert cap.metadata.mcp_server == "obsidian"
  end

  describe "reload/2" do
    test "starts added servers, stops removed ones, keeps unchanged children", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      reg_name = :"mcp_sup_reload_reg_#{suffix}"
      server_a = %{name: "alpha", discoverer: HappyDiscoverer, caller: StubCaller}
      server_b = %{name: "beta", discoverer: HappyDiscoverer, caller: StubCaller}

      reload_opts = [
        capability_registry: cap_registry,
        mcp_registry: reg_name
      ]

      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_reload_#{suffix}",
             mcp_registry: reg_name,
             capability_registry: cap_registry,
             servers: [server_a]
           ]},
          id: :mcp_supervisor_reload_test
        )

      pid_a = server_child_pid(sup, "alpha")
      assert is_pid(pid_a)

      assert {:ok, summary} =
               McpSupervisor.reload(sup, [{:servers, [server_a, server_b]} | reload_opts])

      assert summary.started == ["beta"]
      assert summary.stopped == []
      assert summary.unchanged == ["alpha"]
      assert server_child_pid(sup, "alpha") == pid_a
      assert is_pid(server_child_pid(sup, "beta"))

      assert {:ok, summary2} = McpSupervisor.reload(sup, [{:servers, [server_b]} | reload_opts])
      assert summary2.stopped == ["alpha"]
      assert summary2.started == []
      assert summary2.unchanged == ["beta"]
      assert server_child_pid(sup, "alpha") == nil
    end

    # The disable path (M8.1 §4.5 gap 3): a removed server's child is stopped
    # by the supervisor — an exit signal, not GenServer.stop/2 — and its
    # capabilities must be unregistered by terminate/2, which only runs if
    # the server traps exits.
    test "stopping a removed server unregisters its capabilities", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      reg_name = :"mcp_sup_reload_teardown_reg_#{suffix}"

      server = %{
        name: "obsidian",
        prefix: "obsidian_",
        discoverer: HappyDiscoverer,
        caller: StubCaller
      }

      reload_opts = [capability_registry: cap_registry, mcp_registry: reg_name]

      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_reload_teardown_#{suffix}",
             mcp_registry: reg_name,
             capability_registry: cap_registry,
             servers: [server]
           ]},
          id: :mcp_supervisor_reload_teardown_test
        )

      assert eventually(fn ->
               Enum.sort(cap_names(cap_registry)) ==
                 ["obsidian_create_issue", "obsidian_list_issues"]
             end)

      assert {:ok, %{stopped: ["obsidian"]}} =
               McpSupervisor.reload(sup, [{:servers, []} | reload_opts])

      assert eventually(fn -> cap_names(cap_registry) == [] end)
    end

    test "a changed spec restarts the server; an identical spec does not", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      reg_name = :"mcp_sup_reload_chg_reg_#{suffix}"
      server = %{name: "alpha", discoverer: HappyDiscoverer, caller: StubCaller}

      reload_opts = [capability_registry: cap_registry, mcp_registry: reg_name]

      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_reload_chg_#{suffix}",
             mcp_registry: reg_name,
             capability_registry: cap_registry,
             servers: [server]
           ]},
          id: :mcp_supervisor_reload_changed_test
        )

      pid = server_child_pid(sup, "alpha")

      assert {:ok, %{unchanged: ["alpha"]}} =
               McpSupervisor.reload(sup, [{:servers, [server]} | reload_opts])

      assert server_child_pid(sup, "alpha") == pid

      changed = Map.put(server, :env, %{"NEW" => "value"})

      assert {:ok, summary} = McpSupervisor.reload(sup, [{:servers, [changed]} | reload_opts])
      assert summary.stopped == ["alpha"]
      assert summary.started == ["alpha"]
      new_pid = server_child_pid(sup, "alpha")
      assert is_pid(new_pid) and new_pid != pid
    end
  end

  test "skips Anubis starter for servers without command (test/discoverer-only path)", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_no_anubis_#{suffix}",
           mcp_registry: :"mcp_sup_no_anubis_reg_#{suffix}",
           capability_registry: cap_registry,
           anubis_starter: RecordingAnubisStarter,
           servers: [
             %{
               name: "github",
               discoverer: HappyDiscoverer,
               caller: StubCaller,
               reporter: self()
             }
           ]
         ]},
        id: :mcp_supervisor_no_anubis_test
      )

    refute_receive {:anubis_starter_invoked, _server}, 100
    refute_receive {:fake_anubis_started, _opts}, 100
  end

  defp cap_names(cap_registry) do
    cap_registry
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.map(& &1.name)
  end

  defp server_child_pid(sup, name) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{:mcp_server_supervisor, ^name, _hash}, pid, _type, _modules} -> pid
      _other -> nil
    end)
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

  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(value), do: Application.put_env(:fermix_core, :sandbox, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
