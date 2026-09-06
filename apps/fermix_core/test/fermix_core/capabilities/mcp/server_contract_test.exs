defmodule FermixCore.Capabilities.MCP.ServerContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.Proxy
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.CanonicalJson

  @source {:plugin, "eden"}

  @schema %{
    "type" => "object",
    "properties" => %{"noteId" => %{"type" => "string"}, "workspaceId" => %{"type" => "string"}}
  }

  defmodule StubDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    def set_tools(tools), do: :persistent_term.put({__MODULE__, :tools}, tools)

    @doc "The listener the registration owner armed, so a test can drive it."
    def listener, do: :persistent_term.get({__MODULE__, :listener}, nil)

    def clear do
      :persistent_term.erase({__MODULE__, :tools})
      :persistent_term.erase({__MODULE__, :listener})
    catch
      _kind, _reason -> :ok
    end

    @impl true
    def list_tools(_client) do
      case :persistent_term.get({__MODULE__, :tools}, []) do
        {:error, reason} -> {:error, reason}
        tools when is_list(tools) -> {:ok, tools}
      end
    end

    # The contract-bearing half of the behaviour. A signed registration is
    # exactly what a `tools/list_changed` invalidates, so a discoverer serving
    # one must be able to report the change back.
    @impl true
    def watch_tools(_client, listener) do
      :persistent_term.put({__MODULE__, :listener}, listener)
      :ok
    end
  end

  defmodule StubDispatch do
    @behaviour FermixCore.Capabilities.MCP.Remote.Proxy

    @impl true
    def call_tool(_target, _tool, _args, _timeout) do
      {:ok, %{"content" => [%{"type" => "text", "text" => ~s({"ok":true})}]}}
    end
  end

  defmodule FakeSkillRegistry do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Keyword.get(opts, :names, [])}

    @impl true
    def handle_call(:list, _from, names), do: {:reply, names, names}
  end

  defp digest(name, input) do
    {:ok, value} = CanonicalJson.descriptor_digest(name, input, nil, nil)
    value
  end

  defp facts(name, input) do
    %{
      read_only: true,
      replay_safe: true,
      required_credential_scope: "read",
      descriptor_sha256: digest(name, input),
      collection_policy: nil,
      argument_guards: []
    }
  end

  defp spec(overrides) do
    Map.merge(
      %{
        source_id: @source,
        name: "eden",
        transport: :streamable_http,
        name_mode: :preserve,
        selected_profile: "retrieval",
        resource_scope: %{kind: :single_workspace, argument: "workspaceId", id: "ws_1"},
        allowed_tools: %{
          "eden_get_note" => facts("eden_get_note", @schema),
          "eden_search" => facts("eden_search", @schema)
        },
        budgets: %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
        result_contract: %{
          "kind" => "json_boolean",
          "success_field" => "ok",
          "status_field" => "status",
          "message_field" => "message"
        }
      },
      overrides
    )
  end

  defp descriptor(name, input \\ @schema),
    do: %{name: name, description: "d", input_schema: input}

  setup do
    # A refused registration stops the server with a classified reason; the test
    # process is its starter, so it must not die with it.
    Process.flag(:trap_exit, true)
    Naming.init()
    suffix = System.unique_integer([:positive])

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"contract_cap_reg_#{suffix}"},
        id: :"contract_cap_reg_child_#{suffix}"
      )

    mcp_registry =
      start_supervised!(
        {McpRegistry, name: :"contract_mcp_reg_#{suffix}"},
        id: :"contract_mcp_reg_child_#{suffix}"
      )

    on_exit(fn ->
      StubDiscoverer.clear()

      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    %{cap_registry: cap_registry, mcp_registry: mcp_registry, suffix: suffix}
  end

  defp start_server(ctx, overrides \\ %{}, extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          server_name: "eden",
          source_id: @source,
          client: :fake_client,
          discoverer: StubDiscoverer,
          contract: spec(overrides),
          proxy_dispatch: StubDispatch,
          proxy_target: :fake,
          capability_registry: ctx.cap_registry,
          mcp_registry: ctx.mcp_registry,
          runtime_status: nil,
          main_agent: nil,
          realtime_supervisor: nil,
          skill_registry: nil,
          fail_fast?: true
        ],
        extra_opts
      )

    McpServer.start_link(opts)
  end

  # `fail_fast?: false` is the DAEMON's posture: discovery runs in
  # `handle_continue(:discover)` and a terminal reason stops the subtree rather
  # than failing the child start. The log line under test only exists on that
  # path, so a `fail_fast?: true` start (the default here) cannot exercise it.
  defp run_supervised_discovery(ctx) do
    {:ok, pid} = start_server(ctx, %{}, fail_fast?: false)
    assert_receive {:EXIT, ^pid, :normal}, 1_000
  end

  defp registered(ctx) do
    ctx.cap_registry |> CapabilityRegistry.list() |> Enum.map(& &1.name) |> Enum.sort()
  end

  describe "signed allowlist enforcement" do
    test "registers exactly the selected profile and never an extra tool", ctx do
      StubDiscoverer.set_tools([
        descriptor("eden_get_note"),
        descriptor("eden_search"),
        descriptor("eden_delete_workspace")
      ])

      {:ok, server} = start_server(ctx)
      assert registered(ctx) == ["eden_get_note", "eden_search"]
      assert Naming.lookup("eden_delete_workspace") == :error
      GenServer.stop(server)
    end

    test "preserve mode keeps the exact declared name", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])

      {:ok, server} = start_server(ctx)
      assert "eden_get_note" in registered(ctx)
      refute "eden_eden_get_note" in registered(ctx)
      GenServer.stop(server)
    end

    test "one changed descriptor registers ZERO capabilities", ctx do
      drifted = Map.put(@schema, "properties", %{"noteId" => %{"type" => "integer"}})
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search", drifted)])

      assert {:error, {:mcp_discovery_failed, "eden", reason}} = start_server(ctx)
      assert {:upstream_contract_mismatch, {:descriptor_changed, "eden_search"}} = reason
      assert registered(ctx) == []
      assert Naming.lookup("eden_get_note") == :error
    end

    test "one missing descriptor registers ZERO capabilities", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note")])

      assert {:error, {:mcp_discovery_failed, "eden", reason}} = start_server(ctx)
      assert {:upstream_contract_mismatch, {:missing_tool, "eden_search"}} = reason
      assert registered(ctx) == []
      assert Naming.lookup("eden_get_note") == :error
    end

    # The log line is the ONLY surface that can name which tool broke the
    # contract: `RuntimeStatus` stores an atom class by design (§11.1), so a name
    # dropped here is a name no operator can recover. A bare
    # `:upstream_contract_mismatch` sent one operator on a live-probe hunt for a
    # fact the daemon already held.
    test "the terminal log line names the tool that broke the contract", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note")])

      log = capture_log(fn -> run_supervised_discovery(ctx) end)

      assert log =~ "upstream_contract_mismatch"
      assert log =~ "missing_tool"
      assert log =~ "eden_search"
    end

    test "a name collision names the colliding capability in the terminal log", ctx do
      {:ok, _name} = Naming.reserve("other", "get_note", "eden_search")
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])

      log = capture_log(fn -> run_supervised_discovery(ctx) end)

      assert log =~ "capability_conflict"
      assert log =~ "eden_search"
    end
  end

  describe "transactional registration" do
    test "an already-taken name fails the whole registration with no partial set", ctx do
      # Another owner holds one of the preserved names.
      {:ok, _name} = Naming.reserve("other", "get_note", "eden_search")
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])

      assert {:error, {:mcp_discovery_failed, "eden", reason}} = start_server(ctx)
      assert {:capability_conflict, "eden_search"} = reason

      assert registered(ctx) == []
      # The foreign reservation survives; ours is not left behind.
      assert {:ok, {"other", "get_note"}} = Naming.lookup("eden_search")
      assert Naming.lookup("eden_get_note") == :error
    end

    test "a capability-registry duplicate rolls back every naming reservation", ctx do
      :ok =
        CapabilityRegistry.register(
          ctx.cap_registry,
          Capability.new(%{
            name: "eden_search",
            description: "squatter",
            parameters: %{"type" => "object"},
            kind: :builtin,
            executor: {Kernel, :inspect, []}
          })
        )

      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])

      assert {:error, {:mcp_discovery_failed, "eden", reason}} = start_server(ctx)
      assert {:capability_conflict, {:duplicate_name, "eden_search"}} = reason

      assert registered(ctx) == ["eden_search"]
      assert Naming.lookup("eden_get_note") == :error
      assert Naming.lookup("eden_search") == :error
    end

    test "a skill collision fails loudly with no partial set", ctx do
      skills =
        start_supervised!({__MODULE__.FakeSkillRegistry, names: ["eden_search"]},
          id: :fake_skills
        )

      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])

      assert {:error, {:mcp_discovery_failed, "eden", reason}} =
               start_server(ctx, %{}, skill_registry: skills)

      assert {:capability_conflict, {:skill_name_collision, "eden_search"}} = reason
      assert registered(ctx) == []
      assert Naming.lookup("eden_get_note") == :error
    end
  end

  describe "the private client and the published proxy" do
    test "only the proxy is reachable for a remote source", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])
      {:ok, server} = start_server(ctx)

      assert {:ok, proxy} = McpRegistry.lookup_proxy(ctx.mcp_registry, @source)
      assert {:error, :client_private} = McpRegistry.lookup_client(ctx.mcp_registry, @source)
      assert Proxy.state(proxy) == :ready

      GenServer.stop(server)
    end
  end

  describe "drift" do
    test "a tools-changed notification suspends and atomically restores", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])
      {:ok, server} = start_server(ctx)
      assert registered(ctx) == ["eden_get_note", "eden_search"]

      assert {:ok, proxy} = McpRegistry.lookup_proxy(ctx.mcp_registry, @source)
      :ok = McpServer.tools_changed(server)

      # `tools_changed/1` is a cast; a system message drains the mailbox in order,
      # so the suspension below is observed, never raced past.
      _ = :sys.get_state(server)
      assert Proxy.state(proxy) == :suspended
      assert registered(ctx) == []

      # The gate reopens only after the same profile re-registered atomically.
      assert eventually(fn -> Proxy.state(proxy) == :ready end)
      assert registered(ctx) == ["eden_get_note", "eden_search"]
      GenServer.stop(server)
    end

    test "a drifted contract stays unavailable and never serves the old tools", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])
      {:ok, server} = start_server(ctx)
      ref = Process.monitor(server)
      assert registered(ctx) == ["eden_get_note", "eden_search"]

      StubDiscoverer.set_tools([descriptor("eden_get_note")])
      :ok = McpServer.tools_changed(server)

      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 5_000
      assert registered(ctx) == []
      assert Naming.lookup("eden_get_note") == :error
    end

    # THE BUG THIS PINS: `tools_changed/1` was called only from tests. No
    # production code forwarded an incoming `notifications/tools/list_changed`,
    # so everything below — suspend, unregister, bounded rediscovery, atomic
    # re-registration — was unreachable from the wire. The watch is what closes
    # that gap, and it is armed on every discovery pass.
    test "the registration owner arms the upstream watch with itself", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])
      {:ok, server} = start_server(ctx)

      assert StubDiscoverer.listener() == server
      GenServer.stop(server)
    end

    # A stdio source carries no signed contract, so it has no registration for a
    # notification to invalidate and nothing to watch.
    test "a contract-less server arms no watch", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note")])
      {:ok, server} = start_server(ctx, %{}, contract: nil, client: nil)

      assert StubDiscoverer.listener() == nil
      GenServer.stop(server)
    end

    test "an owner-reported change drives the same drift as the cast", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])
      {:ok, server} = start_server(ctx)
      assert {:ok, proxy} = McpRegistry.lookup_proxy(ctx.mcp_registry, @source)
      assert registered(ctx) == ["eden_get_note", "eden_search"]

      send(server, {:mcp_owner, :tools_changed})

      # A system message drains the mailbox in order, so the suspension below is
      # observed, never raced past.
      _ = :sys.get_state(server)
      assert Proxy.state(proxy) == :suspended
      assert registered(ctx) == []

      assert eventually(fn -> Proxy.state(proxy) == :ready end)
      assert registered(ctx) == ["eden_get_note", "eden_search"]
      GenServer.stop(server)
    end

    test "a drift storm is capped per session and requires an explicit reconnect", ctx do
      StubDiscoverer.set_tools([descriptor("eden_get_note"), descriptor("eden_search")])
      {:ok, server} = start_server(ctx, %{}, rediscovery_interval_ms: 0)
      ref = Process.monitor(server)

      # One more than the cap; the last one must refuse rather than rediscover.
      for _i <- 1..(Limits.max_rediscoveries_per_session() + 1) do
        McpServer.tools_changed(server)
        Process.sleep(20)
      end

      assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 5_000
      assert registered(ctx) == []
    end
  end

  defp eventually(fun) do
    Enum.reduce_while(1..200, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
