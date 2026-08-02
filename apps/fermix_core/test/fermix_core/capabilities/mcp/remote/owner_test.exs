defmodule FermixCore.Capabilities.MCP.Remote.OwnerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.Owner
  alias FermixCore.Capabilities.MCP.RuntimeStatus

  @credential "eden_pat_canary_do_not_leak"
  @source {:plugin, "eden"}

  # The same module double the session tests use: the whole connect →
  # initialize → discover → ready path runs with no socket, no TLS chain, no
  # DNS answer, and no subprocess.
  defmodule FakeTransport do
    def open(endpoint, opts) do
      case Keyword.get(opts, :open_error) do
        nil -> {:ok, %{agent: Keyword.fetch!(opts, :agent), endpoint: endpoint}}
        error -> {:error, error}
      end
    end

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

  setup do
    status = start_supervised!({RuntimeStatus, name: :"owner_status_#{unique()}"})
    %{status: status}
  end

  defp unique, do: System.unique_integer([:positive])

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        source_id: @source,
        name: "eden",
        transport: :streamable_http,
        protocol_version: "2025-06-18",
        base_url: "https://mcp.eden.so",
        mcp_path: "/mcp",
        auth_ref: %{type: :plugin_secret, plugin: "eden"},
        name_mode: :preserve,
        selected_profile: "retrieval",
        resource_scope: %{kind: :single_workspace, argument: "workspaceId", id: "ws_opaque_id"},
        allowed_tools: %{},
        capability_metadata: %{plugin_owned?: true, plugin: "eden", category: :plugin}
      },
      overrides
    )
  end

  # Unlinked on purpose: the owner's `terminate/2` runs its protocol teardown
  # during test cleanup, and a transport that vanished with the test process
  # would turn that orderly close into noise.
  defp start_agent(responses) do
    {:ok, agent} = Agent.start(fn -> %{responses: responses, requests: []} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    agent
  end

  defp requests(agent), do: Agent.get(agent, & &1.requests)

  defp json(status, body, headers \\ []) do
    {:ok,
     %{
       status: status,
       headers: [{"content-type", "application/json"}] ++ headers,
       body: {:json, Jason.encode!(body)}
     }}
  end

  defp accepted, do: {:ok, %{status: 202, headers: [], body: {:empty, ""}}}

  defp rpc_result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp initialize_ok do
    json(
      200,
      rpc_result(1, %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}),
      [{"mcp-session-id", "sess-owner-1"}]
    )
  end

  defp tools_page(id, tools, next_cursor \\ nil) do
    result = %{"tools" => tools}
    result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
    json(200, rpc_result(id, result))
  end

  defp tool(name), do: %{"name" => name, "description" => name, "inputSchema" => %{}}

  defp owner_opts(status, agent, overrides \\ %{}, connect_opts \\ []) do
    [
      spec: spec(overrides),
      runtime_status: status,
      transport: FakeTransport,
      connect_opts: [agent: agent] ++ connect_opts,
      resolver: fn "eden" -> @credential end
    ]
  end

  defp start_owner(opts) do
    start_supervised!(
      Supervisor.child_spec({Owner, opts}, id: :owner_under_test, restart: :temporary)
    )
  end

  describe "connect → initialize → discover" do
    test "a started owner is an initialized session that can list tools", %{status: status} do
      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          tools_page(2, [tool("eden_search"), tool("eden_get_note")])
        ])

      owner = start_owner(owner_opts(status, agent))

      assert {:ok, descriptors} = Owner.list_tools(owner)
      assert Enum.map(descriptors, & &1.name) == ["eden_search", "eden_get_note"]

      assert [initialize, initialized, list] = requests(agent)
      assert Jason.decode!(initialize.body)["method"] == "initialize"
      assert Jason.decode!(initialized.body)["method"] == "notifications/initialized"
      assert Jason.decode!(list.body)["method"] == "tools/list"
    end

    test "publishes :connecting for its own generation before discovery", %{status: status} do
      agent = start_agent([initialize_ok(), accepted()])
      owner = start_owner(owner_opts(status, agent))

      assert {:ok, entry} = RuntimeStatus.fetch(status, @source)
      assert entry.status == :connecting
      assert entry.owner == owner
      assert entry.plugin == "eden"
    end

    test "follows a bounded cursor across pages", %{status: status} do
      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          tools_page(2, [tool("eden_search")], "page-2"),
          tools_page(3, [tool("eden_get_note")])
        ])

      owner = start_owner(owner_opts(status, agent))

      assert {:ok, descriptors} = Owner.list_tools(owner)
      assert Enum.map(descriptors, & &1.name) == ["eden_search", "eden_get_note"]
      assert length(requests(agent)) == 4
    end

    test "refuses a repeated cursor rather than paging forever", %{status: status} do
      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          tools_page(2, [tool("eden_search")], "loop"),
          tools_page(3, [tool("eden_get_note")], "loop")
        ])

      owner = start_owner(owner_opts(status, agent))

      assert {:error, {:remote_protocol_error, :cursor_cycle}} = Owner.list_tools(owner)
    end

    test "refuses more pages than the bound rather than truncating", %{status: status} do
      pages =
        for page <- 1..(Limits.max_discovery_pages() + 1) do
          tools_page(page + 1, [tool("eden_tool_#{page}")], "page-#{page}")
        end

      agent = start_agent([initialize_ok(), accepted()] ++ pages)
      owner = start_owner(owner_opts(status, agent))

      assert {:error, {:remote_protocol_error, :discovery_page_limit}} = Owner.list_tools(owner)
    end

    test "refuses more tools than the bound rather than truncating", %{status: status} do
      tools = for i <- 1..(Limits.max_discovered_tools() + 1), do: tool("eden_tool_#{i}")
      agent = start_agent([initialize_ok(), accepted(), tools_page(2, tools)])
      owner = start_owner(owner_opts(status, agent))

      assert {:error, {:remote_protocol_error, :too_many_tools}} = Owner.list_tools(owner)
    end

    test "refuses an oversized cursor", %{status: status} do
      cursor = String.duplicate("c", Limits.max_cursor_bytes() + 1)

      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          tools_page(2, [tool("eden_search")], cursor)
        ])

      owner = start_owner(owner_opts(status, agent))

      assert {:error, {:remote_protocol_error, :cursor_too_large}} = Owner.list_tools(owner)
    end

    test "a malformed tools payload fails visibly", %{status: status} do
      agent =
        start_agent([initialize_ok(), accepted(), json(200, rpc_result(2, %{"tools" => "no"}))])

      owner = start_owner(owner_opts(status, agent))

      assert {:error, {:invalid_remote_result, :tools_not_a_list}} = Owner.list_tools(owner)
    end
  end

  describe "refusals" do
    test "a rejected credential is terminal and is never retried", %{status: status} do
      agent = start_agent([json(401, %{}), initialize_ok(), accepted()])

      {:ok, owner} = Owner.start_link(owner_opts(status, agent))
      ref = Process.monitor(owner)

      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 1_000

      assert {:ok, %{status: :reauthorization_required, owner: nil}} =
               RuntimeStatus.fetch(status, @source)

      # One initialize, not four: repeating a rejected PAT is how an account
      # gets locked.
      assert length(requests(agent)) == 1
    end

    test "unreachability is retried up to the bounded attempt cap", %{status: status} do
      agent = start_agent([])
      opts = owner_opts(status, agent, %{}, open_error: :nxdomain)

      {:ok, owner} = Owner.start_link(opts)
      ref = Process.monitor(owner)

      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 5_000
      assert {:ok, %{status: :remote_unreachable}} = RuntimeStatus.fetch(status, @source)
    end

    test "a spec that is not remote is refused before anything connects", %{status: status} do
      Process.flag(:trap_exit, true)
      agent = start_agent([])
      opts = owner_opts(status, agent, %{transport: :stdio})

      assert {:error, {:invalid_remote_config, _detail}} = Owner.start_link(opts)
      assert {:ok, %{status: :invalid_remote_config}} = RuntimeStatus.fetch(status, @source)
    end

    test "an unpinnable endpoint is refused before anything connects", %{status: status} do
      Process.flag(:trap_exit, true)
      agent = start_agent([])
      opts = owner_opts(status, agent, %{base_url: "http://mcp.eden.so"})

      assert {:error, {:invalid_remote_config, _detail}} = Owner.start_link(opts)
      assert {:ok, %{status: :invalid_remote_config}} = RuntimeStatus.fetch(status, @source)
    end

    test "an absent credential is :needs_secret, not a client that starts and 401s", %{
      status: status
    } do
      agent = start_agent([])

      opts =
        status
        |> owner_opts(agent)
        |> Keyword.put(:resolver, fn "eden" -> nil end)

      {:ok, owner} = Owner.start_link(opts)
      ref = Process.monitor(owner)

      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 1_000
      assert {:ok, %{status: :needs_secret}} = RuntimeStatus.fetch(status, @source)
    end

    test "an abrupt death leaves a visible terminal status", %{status: status} do
      agent = start_agent([initialize_ok(), accepted()])
      owner = start_owner(owner_opts(status, agent))

      Process.exit(owner, :kill)

      assert eventually(fn ->
               match?({:ok, %{status: :remote_unreachable}}, RuntimeStatus.fetch(status, @source))
             end)
    end
  end

  describe "teardown" do
    test "sends an authenticated DELETE and closes the session", %{status: status} do
      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          {:ok, %{status: 204, headers: [], body: {:empty, ""}}}
        ])

      owner = start_owner(owner_opts(status, agent))

      assert :ok = Owner.teardown(owner)

      delete = List.last(requests(agent))
      assert delete.method == "DELETE"
      assert {"mcp-session-id", "sess-owner-1"} in delete.headers
    end

    test "is idempotent once the session is closed", %{status: status} do
      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          {:ok, %{status: 204, headers: [], body: {:empty, ""}}}
        ])

      owner = start_owner(owner_opts(status, agent))

      assert :ok = Owner.teardown(owner)
      assert :ok = Owner.teardown(owner)
    end

    test "stopping the owner takes the session with it", %{status: status} do
      agent =
        start_agent([
          initialize_ok(),
          accepted(),
          {:ok, %{status: 204, headers: [], body: {:empty, ""}}}
        ])

      {:ok, owner} = Owner.start_link(owner_opts(status, agent))
      {:links, links} = Process.info(owner, :links)
      [session] = Enum.reject(links, &(&1 == self()))

      :ok = GenServer.stop(owner)

      refute Process.alive?(session)
    end
  end

  describe "credential containment" do
    test "no supervisor child spec or crash report can print the bearer" do
      child_spec = Owner.child_spec(spec: spec(), runtime_status: nil)

      rendered = inspect(child_spec, limit: :infinity)
      refute rendered =~ @credential
      assert rendered =~ "plugin_secret"
    end

    test "the redacted view names the endpoint but not the resource or the token" do
      redacted = Owner.redacted(spec())
      rendered = inspect(redacted, limit: :infinity)

      assert redacted.base_url == "https://mcp.eden.so"
      assert redacted.resource_scope_kind == :single_workspace
      refute rendered =~ @credential
      refute rendered =~ "ws_opaque_id"
    end

    test "a start failure reports the reason, not the configuration", %{status: status} do
      Process.flag(:trap_exit, true)
      agent = start_agent([])
      opts = owner_opts(status, agent, %{transport: :stdio})

      assert {:error, reason} = Owner.start_link(opts)
      refute inspect(reason, limit: :infinity) =~ @credential
    end
  end

  describe "telemetry" do
    test "emits the shared lifecycle event for each phase", %{status: status} do
      handler = :"owner_lifecycle_#{unique()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:fermix, :mcp_client, :lifecycle],
        fn _event, measurements, metadata, _config ->
          send(parent, {:lifecycle, metadata.phase, metadata, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      agent = start_agent([initialize_ok(), accepted(), tools_page(2, [tool("eden_search")])])
      owner = start_owner(owner_opts(status, agent))
      {:ok, _descriptors} = Owner.list_tools(owner)

      assert_receive {:lifecycle, :initialize, initialize_meta, _m}, 1_000
      assert initialize_meta.source_id == "plugin:eden"
      assert initialize_meta.plugin == "eden"
      assert initialize_meta.result == :ok
      assert initialize_meta.attempt == 1

      assert_receive {:lifecycle, :discover, discover_meta, _m2}, 1_000
      assert discover_meta.result == :ok
    end
  end

  defp eventually(fun, deadline_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end
end
