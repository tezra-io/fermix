defmodule FermixCore.Capabilities.MCP.SupervisorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Sandbox.Config, as: SandboxConfig

  defmodule StubCaller do
    @behaviour FermixCore.Capabilities.MCP.Caller

    @impl true
    def call_tool(_source_id, _tool, _args, _context), do: {:ok, "stub-response"}
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
    def child_specs_for(server, _config) do
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

  # Answers the three supervisor calls `stop_server/3` makes, and reports a
  # child that never dies — the case a stop must refuse to call proven.
  defmodule WedgedSupervisor do
    @moduledoc false
    use GenServer

    def start_link(child_pid), do: GenServer.start_link(__MODULE__, child_pid)

    @impl true
    def init(child_pid), do: {:ok, child_pid}

    @impl true
    def handle_call(:which_children, _from, child_pid) do
      children = [{{:mcp_server_supervisor, {:plugin, "eden"}, 1}, child_pid, :supervisor, []}]
      {:reply, children, child_pid}
    end

    def handle_call({:terminate_child, _id}, _from, child_pid), do: {:reply, :ok, child_pid}
    def handle_call({:delete_child, _id}, _from, child_pid), do: {:reply, :ok, child_pid}
  end

  # One remote server, end to end, with the transport replaced by canned
  # responses: no socket, no TLS chain, no DNS answer, no subprocess.
  defmodule RemoteFixture do
    @moduledoc false

    alias FermixCore.Plugins.CanonicalJson

    defmodule Transport do
      @moduledoc false

      def open(endpoint, opts),
        do: {:ok, %{agent: Keyword.fetch!(opts, :agent), endpoint: endpoint}}

      def request(conn, _method, _headers, _body, _timeout_ms) do
        conn.agent
        |> Agent.get_and_update(fn
          [next | rest] -> {next, rest}
          [] -> {{:ok, %{status: 200, headers: [], body: {:empty, ""}}}, []}
        end)
        |> case do
          {:ok, response} -> {:ok, conn, response}
          {:error, reason} -> {:error, conn, reason}
        end
      end

      def close(_conn), do: :ok
    end

    defmodule Starter do
      @moduledoc false
      @behaviour FermixCore.Capabilities.MCP.AnubisStarter

      alias FermixCore.Capabilities.MCP.Remote.Owner, as: RemoteOwner

      @impl true
      def child_specs_for(%{transport: :streamable_http} = server, config) do
        name = RemoteOwner.name_for(server.source_id)

        spec =
          Supervisor.child_spec(
            {RemoteOwner,
             [
               name: name,
               spec: server,
               runtime_status: Map.get(config, :runtime_status),
               transport: FermixCore.Capabilities.MCP.SupervisorTest.RemoteFixture.Transport,
               connect_opts: [agent: Map.fetch!(server, :agent)],
               resolver: fn "eden" -> "eden_pat_canary_do_not_leak" end
             ]},
            id: {:remote_owner, server.source_id},
            restart: :transient,
            significant: true
          )

        %{children: [spec], client_name: name}
      end

      def child_specs_for(_server, _config), do: %{children: [], client_name: nil}
    end

    def start_agent(mode \\ :ok) do
      {:ok, agent} = Agent.start(fn -> responses(mode) end)
      agent
    end

    def spec(agent) do
      %{
        source_id: {:plugin, "eden"},
        name: "eden",
        transport: :streamable_http,
        protocol_version: "2025-06-18",
        base_url: "https://mcp.eden.so",
        mcp_path: "/mcp",
        auth_ref: %{type: :plugin_secret, plugin: "eden"},
        name_mode: :preserve,
        selected_profile: "retrieval",
        resource_scope: %{kind: :single_workspace, argument: "workspaceId", id: "ws_opaque"},
        allowed_tools: %{
          "eden_search" => tool_facts("eden_search"),
          "eden_get_note" => tool_facts("eden_get_note")
        },
        budgets: %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
        result_contract: %{
          "kind" => "json_boolean",
          "success_field" => "ok",
          "status_field" => "status",
          "message_field" => "message"
        },
        tools_overrides: %{},
        capability_metadata: %{plugin_owned?: true, plugin: "eden", category: :plugin},
        agent: agent
      }
    end

    # The signed descriptor facts for the two tools the fixture serves. The
    # digest is computed from the same `inputSchema` the fixture returns, so the
    # contract check passes for exactly this fixture and no other.
    defp tool_facts(name) do
      {:ok, digest} = CanonicalJson.descriptor_digest(name, %{}, nil, nil)

      %{
        read_only: true,
        replay_safe: true,
        required_credential_scope: "read",
        descriptor_sha256: digest,
        collection_policy: nil,
        argument_guards: []
      }
    end

    defp responses(:unauthorized), do: [json(401, %{})]

    defp responses(:ok) do
      [
        json(200, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
        }),
        {:ok, %{status: 202, headers: [], body: {:empty, ""}}},
        json(200, %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "result" => %{
            "tools" => [
              %{"name" => "eden_search", "description" => "Search", "inputSchema" => %{}},
              %{"name" => "eden_get_note", "description" => "Read", "inputSchema" => %{}}
            ]
          }
        })
      ]
    end

    defp json(status, body) do
      {:ok,
       %{
         status: status,
         headers: [{"content-type", "application/json"}],
         body: {:json, Jason.encode!(body)}
       }}
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

  describe "source-qualified identity" do
    test "a plugin server and an operator server of the same name are distinct children", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_source_#{suffix}",
             mcp_registry: :"mcp_sup_source_reg_#{suffix}",
             capability_registry: cap_registry,
             servers: [
               %{name: "eden", discoverer: HappyDiscoverer, caller: StubCaller},
               %{
                 source_id: {:plugin, "eden"},
                 name: "eden",
                 discoverer: HappyDiscoverer,
                 caller: StubCaller
               }
             ]
           ]},
          id: :mcp_supervisor_source_test
        )

      operator = server_child_pid(sup, :operator, "eden")
      plugin = server_child_pid(sup, :plugin, "eden")

      assert is_pid(operator)
      assert is_pid(plugin)
      refute operator == plugin
    end

    test "stopping the plugin source leaves the operator server of the same name running", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_stop_#{suffix}",
             mcp_registry: :"mcp_sup_stop_reg_#{suffix}",
             capability_registry: cap_registry,
             servers: [
               %{name: "eden", discoverer: HappyDiscoverer, caller: StubCaller},
               %{
                 source_id: {:plugin, "eden"},
                 name: "eden",
                 discoverer: HappyDiscoverer,
                 caller: StubCaller
               }
             ]
           ]},
          id: :mcp_supervisor_stop_test
        )

      plugin = server_child_pid(sup, :plugin, "eden")

      assert :ok = McpSupervisor.stop_server(sup, {:plugin, "eden"})

      refute Process.alive?(plugin)
      assert server_child_pid(sup, :plugin, "eden") == nil
      assert is_pid(server_child_pid(sup, :operator, "eden"))
    end

    test "stopping a source that is not running is already proven", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_stop_absent_#{suffix}",
             mcp_registry: :"mcp_sup_stop_absent_reg_#{suffix}",
             capability_registry: cap_registry,
             servers: []
           ]},
          id: :mcp_supervisor_stop_absent_test
        )

      assert :ok = McpSupervisor.stop_server(sup, {:plugin, "eden"})
    end

    test "restart_server proves the old child died before starting the new one", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      reg_name = :"mcp_sup_restart_reg_#{suffix}"
      spec = %{source_id: {:plugin, "eden"}, name: "eden", discoverer: HappyDiscoverer}

      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_restart_#{suffix}",
             mcp_registry: reg_name,
             capability_registry: cap_registry,
             servers: [spec]
           ]},
          id: :mcp_supervisor_restart_test
        )

      old = server_child_pid(sup, :plugin, "eden")

      assert {:ok, new} =
               McpSupervisor.restart_server(sup, {:plugin, "eden"}, spec,
                 capability_registry: cap_registry,
                 mcp_registry: reg_name
               )

      refute Process.alive?(old)
      assert is_pid(new)
      assert server_child_pid(sup, :plugin, "eden") == new
    end

    # The safety property credential rotation depends on: a stop that cannot
    # prove death must not report success, or the caller commits a new PAT
    # while the old in-memory bearer is still alive.
    test "a stop that cannot prove death returns an error" do
      wedged = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(wedged), do: Process.exit(wedged, :kill) end)

      {:ok, fake} = WedgedSupervisor.start_link(wedged)

      assert {:error, {:stop_not_proven, {:plugin, "eden"}}} =
               McpSupervisor.stop_server(fake, {:plugin, "eden"})
    end
  end

  describe "remote specs" do
    test "a remote spec that declares process env is refused", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      assert_raise ArgumentError, ~r/must not declare/, fn ->
        McpSupervisor.init(
          name: :"mcp_sup_remote_env_#{suffix}",
          mcp_registry: :"mcp_sup_remote_env_reg_#{suffix}",
          capability_registry: cap_registry,
          servers: [
            %{
              source_id: {:plugin, "eden"},
              name: "eden",
              transport: :streamable_http,
              env: %{"EDEN_TOKEN" => "leak"}
            }
          ]
        )
      end
    end

    test "connect → initialize → discover → ready, with no subprocess", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      status = start_supervised!({RuntimeStatus, name: :"mcp_sup_rs_#{suffix}"})
      agent = RemoteFixture.start_agent()

      sup =
        start_supervised!(
          {McpSupervisor,
           [
             name: :"mcp_sup_remote_#{suffix}",
             mcp_registry: :"mcp_sup_remote_reg_#{suffix}",
             capability_registry: cap_registry,
             runtime_status: status,
             anubis_starter: RemoteFixture.Starter,
             servers: [RemoteFixture.spec(agent)]
           ]},
          id: :mcp_supervisor_remote_test
        )

      assert eventually(fn ->
               match?({:ok, %{status: :ready}}, RuntimeStatus.fetch(status, {:plugin, "eden"}))
             end)

      # Two signed tools become two capabilities under their EXACT upstream
      # names — `name_mode: :preserve` never produces `eden_eden_*` (§7.7).
      assert Enum.sort(cap_names(cap_registry)) == ["eden_get_note", "eden_search"]
      assert is_pid(server_child_pid(sup, :plugin, "eden"))
    end

    test "an owner that refuses leaves a visible terminal status", %{
      cap_registry: cap_registry,
      suffix: suffix
    } do
      status = start_supervised!({RuntimeStatus, name: :"mcp_sup_rs_bad_#{suffix}"})
      agent = RemoteFixture.start_agent(:unauthorized)

      start_supervised!(
        {McpSupervisor,
         [
           name: :"mcp_sup_remote_bad_#{suffix}",
           mcp_registry: :"mcp_sup_remote_bad_reg_#{suffix}",
           capability_registry: cap_registry,
           runtime_status: status,
           anubis_starter: RemoteFixture.Starter,
           servers: [RemoteFixture.spec(agent)]
         ]},
        id: :mcp_supervisor_remote_bad_test
      )

      assert eventually(fn ->
               match?(
                 {:ok, %{status: :reauthorization_required}},
                 RuntimeStatus.fetch(status, {:plugin, "eden"})
               )
             end)

      assert cap_names(cap_registry) == []
    end
  end

  defp cap_names(cap_registry) do
    cap_registry
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.map(& &1.name)
  end

  defp server_child_pid(sup, name), do: server_child_pid(sup, :operator, name)

  defp server_child_pid(sup, kind, name) do
    source_id = {kind, name}

    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{:mcp_server_supervisor, ^source_id, _hash}, pid, _type, _modules} -> pid
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
