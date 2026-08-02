defmodule FermixCore.Plugins.RemoteSetupTest do
  @moduledoc """
  Setup-only resource discovery and the workspace selection reconnect
  (M27 §7.5 steps 6–7, §8.1).

  No socket is ever opened: the transport is the same module double
  `Remote.Session`'s own suite uses, so every assertion about which requests
  went out is made against a recorded list rather than a network.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.RemoteSetup

  @credential "eden_pat_canary_do_not_leak"
  @session_id "sess-setup-1"
  @manifest_path "/tmp/workspacedemo/plugin.json"

  # A module double at the transport boundary (the `:transport` seam
  # `Remote.Session` already exposes). It records every request so "only the
  # declared discovery tool was called" is assertable without a socket.
  defmodule FakeTransport do
    @moduledoc false

    def open(endpoint, opts),
      do: {:ok, %{agent: Keyword.fetch!(opts, :agent), endpoint: endpoint}}

    def request(conn, method, headers, body, timeout_ms) do
      recorded = %{method: method, headers: headers, body: body, timeout_ms: timeout_ms}

      conn.agent
      |> Agent.get_and_update(fn state ->
        {next, rest} = pop(state.responses)
        {next, %{state | responses: rest, requests: state.requests ++ [recorded]}}
      end)
      |> case do
        {:ok, response} -> {:ok, conn, response}
        {:error, reason} -> {:error, conn, reason}
      end
    end

    def close(_conn), do: :ok

    defp pop([next | rest]), do: {next, rest}
    defp pop([]), do: {{:error, :no_canned_response}, []}
  end

  # A stand-in for the source-qualified MCP supervisor: it records the stop and
  # the restart in the test's own mailbox (module doubles are called in-process),
  # and installs a live owner generation so the reconnect has something real to
  # wait on — the reconnect is only proven when THIS generation reaches :ready.
  defmodule FakeSupervisor do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.RuntimeStatus

    def stop_server(source_id) do
      send(self(), {:stopped, source_id})
      :ok
    end

    def restart_server(source_id, spec) do
      send(self(), {:restarted, source_id, spec})
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, generation} = RuntimeStatus.register_owner(RuntimeStatus, source_id, owner)
      :ok = RuntimeStatus.put(RuntimeStatus, source_id, generation, :ready, nil)
      {:ok, owner}
    end
  end

  # Stops, but the replacement never connects: the reconnect must NOT report
  # success just because a child process started.
  defmodule RefusingSupervisor do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.RuntimeStatus

    def stop_server(source_id) do
      send(self(), {:stopped, source_id})
      :ok
    end

    def restart_server(source_id, _spec) do
      send(self(), {:restarted, source_id})
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, generation} = RuntimeStatus.register_owner(RuntimeStatus, source_id, owner)

      :ok =
        RuntimeStatus.put(RuntimeStatus, source_id, generation, :reauthorization_required, nil)

      {:ok, owner}
    end
  end

  # Records the persisted config as it stood at stop time, so the stop→commit
  # ordering is observable rather than assumed.
  defmodule OrderingSupervisor do
    @moduledoc false

    alias FermixCore.Setup.ConfigStore

    def stop_server(_source_id) do
      send(self(), {:ordering, :stop, File.read(ConfigStore.path())})
      :ok
    end

    def restart_server(_source_id, _spec), do: {:error, :not_started_in_this_test}
  end

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("remote-setup-home")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    secrets = Application.get_env(:fermix_core, :plugin_secrets, %{})

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :plugin_secrets, %{"workspacedemo" => @credential})

    on_exit(fn ->
      RuntimeStatus.clear(RuntimeStatus, {:plugin, "workspacedemo"})

      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :plugin_secrets, secrets)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  describe "discover_workspaces/2" do
    test "projects the declared id and label fields, calling only the discovery tool" do
      {agent, opts} = discovery(workspaces_result())

      assert {:ok, workspaces} = RemoteSetup.discover_workspaces(plugin(), opts)

      assert workspaces == [
               %{id: "ws_alpha", label: "Alpha"},
               %{id: "ws_beta", label: "Beta"}
             ]

      assert methods(agent) == [
               "initialize",
               "notifications/initialized",
               "tools/list",
               "tools/call"
             ]

      assert [call] = calls(agent)
      assert call["params"]["name"] == "workspacedemo_list_workspaces"
      # No workspace argument exists yet — that is what is being discovered.
      assert call["params"]["arguments"] == %{}
    end

    test "the setup session is published to no registry and registers no capability" do
      {_agent, opts} = discovery(workspaces_result())

      assert {:ok, _workspaces} = RemoteSetup.discover_workspaces(plugin(), opts)

      # The whole point of the boundary: an agent that could see the discovery
      # tool could enumerate every workspace the credential reaches.
      assert McpRegistry.lookup_client(McpRegistry, {:plugin, "workspacedemo"}) ==
               {:error, :not_found}

      assert McpRegistry.lookup_proxy(McpRegistry, {:plugin, "workspacedemo"}) ==
               {:error, :not_found}

      assert RuntimeStatus.fetch(RuntimeStatus, {:plugin, "workspacedemo"}) == :error
      refute Enum.any?(CapabilityRegistry.list(), &(&1.name =~ "list_workspaces"))
    end

    test "closes the setup session on the success path" do
      {agent, opts} = discovery(workspaces_result())

      assert {:ok, _workspaces} = RemoteSetup.discover_workspaces(plugin(), opts)
      assert Enum.any?(requests(agent), &(&1.method == "DELETE"))
    end

    test "closes the setup session on the error path" do
      # The tool call fails; the authenticated session must still be torn down —
      # it is the only place a resolved bearer credential exists.
      {agent, opts} = discovery({:error, :econnreset})

      assert {:error, :econnreset} = RemoteSetup.discover_workspaces(plugin(), opts)
      assert Enum.any?(requests(agent), &(&1.method == "DELETE"))
    end

    test "refuses a discovery tool that is not a declared setup tool, before connecting" do
      manifest = put_in(remote_manifest(), ["setup_tools"], [])
      # The scope's discovery tool is now unreachable through setup_tools, which
      # the manifest validator itself refuses — so the refusal is proven at the
      # boundary the model would have to cross.
      assert {:error, {:invalid_resource_scope, "discovery_tool", _tool}} =
               Registry.decode_manifest(manifest, @manifest_path)

      # …and RemoteSetup refuses the same shape rather than trusting that check.
      {agent, opts} = discovery(workspaces_result())
      leaked = %{plugin() | setup_tools: []}

      assert {:error, {:invalid_remote_config, {:discovery_tool_not_setup_only, _name}}} =
               RemoteSetup.discover_workspaces(leaked, opts)

      assert requests(agent) == []
    end

    test "refuses a discovery descriptor whose signed hash no longer matches" do
      drifted = %{
        "name" => "workspacedemo_list_workspaces",
        "inputSchema" => %{"type" => "object", "properties" => %{"cursor" => %{}}}
      }

      {agent, opts} = discovery(workspaces_result(), tools: [drifted])

      assert {:error, {:upstream_contract_mismatch, {:descriptor_changed, _name}}} =
               RemoteSetup.discover_workspaces(plugin(), opts)

      # Refused BEFORE the tool was called.
      refute "tools/call" in methods(agent)
    end

    test "refuses a discovery tool the server no longer advertises" do
      {_agent, opts} = discovery(workspaces_result(), tools: [])

      assert {:error, {:upstream_contract_mismatch, {:missing_tool, _name}}} =
               RemoteSetup.discover_workspaces(plugin(), opts)
    end

    test "refuses an isError result with a redacted status class, never its message" do
      body = %{"ok" => false, "status" => "auth-expired", "message" => @credential}
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => encode(body)}]}

      {_agent, opts} = discovery(rpc(3, result))

      assert {:error, {:remote_tool_error, "auth-expired"}} =
               RemoteSetup.discover_workspaces(plugin(), opts)
    end

    test "refuses an ambiguous body instead of picking an array by key order" do
      body = %{"ok" => true, "workspaces" => [], "warnings" => []}
      result = %{"content" => [%{"type" => "text", "text" => encode(body)}]}

      {_agent, opts} = discovery(rpc(3, result))

      assert {:error, {:invalid_remote_result, :ambiguous_resource_list}} =
               RemoteSetup.discover_workspaces(plugin(), opts)
    end

    test "refuses an entry whose id would not survive persistence" do
      body = %{"workspaces" => [%{"id" => "has space", "name" => "Alpha"}]}
      result = %{"content" => [%{"type" => "text", "text" => encode(body)}]}

      {_agent, opts} = discovery(rpc(3, result))

      assert {:error, {:invalid_workspace_id, _bytes}} =
               RemoteSetup.discover_workspaces(plugin(), opts)
    end

    test "refuses inline media instead of best-effort text extraction" do
      result = %{"content" => [%{"type" => "image", "data" => "AAAA"}]}
      {_agent, opts} = discovery(rpc(3, result))

      assert {:error, {:invalid_remote_result, :unsupported_content}} =
               RemoteSetup.discover_workspaces(plugin(), opts)
    end
  end

  describe "select_workspace/2" do
    # Persistence goes through `Registry.find/1`, so the manifest has to be
    # discoverable — the dev_local checkout is the registry seam that needs no
    # install pipeline.
    setup %{home: home} do
      dir = Path.join([home, "dev-plugins", "workspacedemo"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "plugin.json"), Jason.encode!(remote_manifest()))
      Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
      :ok
    end

    test "stops the source before it commits, and reports ready only after reconnect" do
      assert :ok =
               RemoteSetup.select_workspace(plugin(),
                 workspace_id: "ws_alpha",
                 workspace_label: "  Alpha  ",
                 mcp_supervisor: FakeSupervisor
               )

      assert_received {:stopped, {:plugin, "workspacedemo"}}
      assert_received {:restarted, {:plugin, "workspacedemo"}, spec}

      # The restart ran against a spec that already carries the new selection.
      assert spec.resource_scope.id == "ws_alpha"
      assert spec.selected_profile == "retrieval"

      entry = plugin_entry()
      assert Keyword.get(entry, :workspace_id) == "ws_alpha"
      assert Keyword.get(entry, :workspace_label) == "Alpha"
      assert Keyword.get(entry, :access_profile) == "retrieval"
    end

    test "the stop is ordered before the commit" do
      # A commit that landed while the previous client was still connected would
      # leave an authenticated session scoped to the replaced workspace.
      RemoteSetup.select_workspace(plugin(),
        workspace_id: "ws_alpha",
        workspace_label: "Alpha",
        mcp_supervisor: OrderingSupervisor
      )

      assert_received {:ordering, :stop, persisted}

      case persisted do
        {:ok, contents} -> refute contents =~ "ws_alpha"
        {:error, :enoent} -> :ok
      end
    end

    test "a client that never reaches ready is not reported as connected" do
      assert {:error, {:reauthorization_required, nil}} =
               RemoteSetup.select_workspace(plugin(),
                 workspace_id: "ws_alpha",
                 workspace_label: "Alpha",
                 mcp_supervisor: RefusingSupervisor
               )
    end

    test "an undeclared access profile is invalid configuration, never defaulted" do
      assert {:error, {:invalid_access_profile, "workspacedemo", "captur"}} =
               RemoteSetup.select_workspace(plugin(),
                 access_profile: "captur",
                 workspace_id: "ws_alpha",
                 workspace_label: "Alpha",
                 mcp_supervisor: FakeSupervisor
               )

      assert plugin_entry() == []
    end

    test "an explicit non-default profile is honoured" do
      assert :ok =
               RemoteSetup.select_workspace(plugin(),
                 access_profile: "capture",
                 workspace_id: "ws_alpha",
                 workspace_label: "Alpha",
                 mcp_supervisor: FakeSupervisor
               )

      assert Keyword.get(plugin_entry(), :access_profile) == "capture"
      assert_received {:restarted, _source_id, spec}
      assert spec.selected_profile == "capture"
    end
  end

  # --- fixtures -----------------------------------------------------------

  defp plugin do
    {:ok, plugin} = Registry.decode_manifest(remote_manifest(), @manifest_path)
    plugin
  end

  defp plugin_entry do
    :fermix_core
    |> Application.get_env(:plugins, [])
    |> Keyword.get(:entries, %{})
    |> Map.get("workspacedemo", [])
  end

  # initialize → initialized → tools/list → tools/call → DELETE teardown.
  defp discovery(call_response, opts \\ []) do
    tools = Keyword.get(opts, :tools, [live_descriptor()])

    responses = [
      initialize_ok(),
      accepted(),
      rpc(2, %{"tools" => tools}),
      call_response,
      {:ok, %{status: 200, headers: [], body: {:empty, ""}}}
    ]

    {:ok, agent} = Agent.start_link(fn -> %{responses: responses, requests: []} end)

    {agent,
     [
       transport: FakeTransport,
       connect_opts: [agent: agent],
       resolver: fn "workspacedemo" -> @credential end
     ]}
  end

  defp workspaces_result do
    body = %{
      "ok" => true,
      "workspaces" => [
        %{"id" => "ws_alpha", "name" => "Alpha"},
        %{"id" => "ws_beta", "name" => "Beta"}
      ]
    }

    rpc(3, %{"content" => [%{"type" => "text", "text" => encode(body)}]})
  end

  defp live_descriptor do
    %{
      "name" => "workspacedemo_list_workspaces",
      "description" => "List workspaces.",
      "inputSchema" => workspaces_parameters()
    }
  end

  defp requests(agent), do: Agent.get(agent, & &1.requests)

  defp methods(agent) do
    agent
    |> requests()
    |> Enum.filter(&(&1.method == "POST"))
    |> Enum.map(&(&1.body |> Jason.decode!() |> Map.fetch!("method")))
  end

  defp calls(agent) do
    agent
    |> requests()
    |> Enum.filter(&(&1.method == "POST"))
    |> Enum.map(&Jason.decode!(&1.body))
    |> Enum.filter(&(Map.get(&1, "method") == "tools/call"))
  end

  defp encode(body), do: Jason.encode!(body)

  defp json(status, body, headers \\ []) do
    {:ok,
     %{
       status: status,
       headers: [{"content-type", "application/json"}] ++ headers,
       body: {:json, Jason.encode!(body)}
     }}
  end

  defp accepted, do: {:ok, %{status: 202, headers: [], body: {:empty, ""}}}

  defp rpc(id, result), do: json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp initialize_ok do
    json(
      200,
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
      },
      [{"mcp-session-id", @session_id}]
    )
  end

  defp workspaces_parameters, do: %{"type" => "object", "properties" => %{}}

  defp remote_manifest do
    %{
      "schema_version" => 2,
      "plugin_api" => 3,
      "min_core_version" => "0.1.0",
      "name" => "workspacedemo",
      "display_name" => "Workspace Demo",
      "description" => "A remote MCP plugin with a single-workspace resource scope.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{
        "type" => "api_key",
        "key_name" => "WORKSPACEDEMO_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste a token"
      },
      "runtime" => %{
        "kind" => "remote_mcp",
        "transport" => "streamable_http",
        "protocol_version" => "2025-06-18",
        "base_url" => "https://mcp.example.com",
        "mcp_path" => "/mcp",
        "tool_name_mode" => "preserve"
      },
      "tool_profiles" => [
        %{
          "name" => "retrieval",
          "display_name" => "Retrieval only",
          "default" => true,
          "required_credential_scope" => "read",
          "scope_visibility" => "none",
          "tools" => ["workspacedemo_search"]
        },
        %{
          "name" => "capture",
          "display_name" => "Retrieval and capture",
          "default" => false,
          "required_credential_scope" => "write",
          "scope_visibility" => "none",
          "tools" => ["workspacedemo_search", "workspacedemo_write"]
        }
      ],
      "setup_tools" => ["workspacedemo_list_workspaces"],
      "resource_scope" => %{
        "kind" => "single_workspace",
        "discovery_tool" => "workspacedemo_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      "budgets" => %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      "result_contract" => %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      "tools" => [workspaces_tool(), search_tool(), write_tool()],
      "skills" => []
    }
  end

  defp workspaces_tool do
    sign(%{
      "name" => "workspacedemo_list_workspaces",
      "description" => "List workspaces available to the connected token.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => false,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => workspaces_parameters(),
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp search_tool do
    sign(%{
      "name" => "workspacedemo_search",
      "description" => "Search a workspace.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => true,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "query" => %{"type" => "string"}
        },
        "required" => ["workspaceId", "query"]
      },
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp write_tool do
    sign(%{
      "name" => "workspacedemo_write",
      "description" => "Append to a note.",
      "policy_class" => "external_api",
      "read_only" => false,
      "replay_safe" => false,
      "required_credential_scope" => "write",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "text" => %{"type" => "string"}
        }
      },
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  # Sign the fixture with the same canonicalizer the validator uses, so a
  # fixture that mutates a schema without re-signing is supposed to fail.
  defp sign(tool) do
    {:ok, digest} =
      CanonicalJson.descriptor_digest(
        Map.fetch!(tool, "name"),
        Map.fetch!(tool, "parameters"),
        Map.get(tool, "output_schema"),
        Map.get(tool, "upstream_annotations")
      )

    Map.put(tool, "descriptor_sha256", digest)
  end
end
