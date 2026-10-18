defmodule FermixCore.Capabilities.MCP.OperatorRemoteTest do
  @moduledoc """
  An operator `http` MCP server, from `config.toml` through `MCP.Supervisor`
  and the one remote rail to a real socket (M74 E4): an MCP server on a
  loopback port that this machine's `http` URL reaches. It does not start
  while its key is missing; `secret.set` of the key starts it through
  `restart_server/2`, with the key as a Bearer on every request and its tools
  registered; a tool call answers through its owner; a tool switch leaves the
  owner and its session running; a changed URL restarts it; and a URL Fermix
  refuses leaves a visible status, never a supervisor that cannot start.

  The home, the secret store (the stub), the status table and the registries
  are the case's own; the supervisor is a second `MCP.Supervisor` beside the
  application's, reached through `Restarter`, which stands where
  `Management.Secrets` and the `ConfigStore` writers name the daemon's.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Management.Secrets
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.LoopbackHttp
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @bound_ms 20_000
  @server "loopback"
  @source {:operator, @server}
  @key "loop_key_canary_3e81d0"
  @tools ["mcp_loopback_echo", "mcp_loopback_shout"]

  defmodule Restarter do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor

    def supervisor, do: :mcp_operator_remote_supervisor

    def opts do
      [
        mcp_registry: :mcp_operator_remote_registry,
        capability_registry: :mcp_operator_remote_capabilities,
        runtime_status: :mcp_operator_remote_status
      ]
    end

    def reload, do: McpSupervisor.reload(supervisor(), opts())

    def restart_server(source_id, spec),
      do: McpSupervisor.restart_server(supervisor(), source_id, spec, opts())

    def stop_server(source_id), do: McpSupervisor.stop_server(supervisor(), source_id, opts())
  end

  @supervisor Restarter.supervisor()
  @opts Restarter.opts()

  setup do
    home = System.get_env("FERMIX_HOME")

    core =
      Map.new(
        [:secret_writer, :profile, :mcp_servers],
        &{&1, Application.get_env(:fermix_core, &1)}
      )

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("mcp_operator_remote_home")
    System.put_env("FERMIX_HOME", tmp)

    mcp = start_supervised!({LoopbackHttp, &mcp_server/1})
    url = "http://127.0.0.1:#{LoopbackHttp.port(mcp)}/mcp"

    start_supervised!({RuntimeStatus, name: @opts[:runtime_status]})
    start_supervised!({CapabilityRegistry, name: @opts[:capability_registry]})

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(key, value) end)
      SecretWriterStub.reset()
      Enum.each(@tools, &Naming.unregister/1)
      restore_home(home)
      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp, mcp: mcp, url: url}
  end

  defp configure!(home, url) do
    File.write!(Path.join(home, "config.toml"), config(url))
    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()
    start_supervised!({McpSupervisor, [name: @supervisor, servers: []] ++ @opts})
  end

  defp config(url) do
    """
    [mcp.servers.#{@server}]
    transport = "http"
    url = "#{url}"
    auth = "header"
    header_secrets = ["Authorization"]
    key_header = "Authorization"
    """
  end

  test "missing its key it is not started; stored, it starts with the key and its tools answer",
       %{home: home, mcp: mcp, url: url} do
    configure!(home, url)

    assert {:ok, %{started: []}} = Restarter.reload()
    refute running?()
    assert LoopbackHttp.requests(mcp) == []

    log =
      capture_log(fn ->
        assert {:ok, %{"present" => true}} =
                 Secrets.set("mcp:#{@server}/header/Authorization", "Bearer " <> @key,
                   mcp_supervisor: Restarter
                 )

        assert await_ready() == {:ok, 2}
      end)

    assert Enum.sort(cap_names()) == @tools
    [initialize | after_initialize] = LoopbackHttp.requests(mcp)

    for request <- [initialize | after_initialize] do
      assert {"authorization", "Bearer " <> @key} in request.headers
    end

    refute List.keyfind(initialize.headers, "mcp-protocol-version", 0)

    for request <- after_initialize do
      assert {"mcp-protocol-version", "2025-11-25"} in request.headers
    end

    assert call_tool("mcp_loopback_echo", %{"text" => "hello"}) ==
             {:ok, %{success: true, output: "hello", error: nil}}

    assert {:ok, %{success: false, error: error}} = call_tool("mcp_loopback_shout", %{})
    assert error =~ "reported an error: too quiet"

    # The key is in no child spec, no printed state and no log line.
    {:ok, owner, _generation} = RuntimeStatus.owner(@opts[:runtime_status], @source)
    printed = inspect([child_specs(), :sys.get_status(owner)], limit: :infinity)
    refute printed =~ @key
    refute log =~ @key
  end

  test "a tool switch keeps its owner running; a changed URL restarts it",
       %{home: home, mcp: mcp, url: url} do
    configure!(home, url)
    :ok = McpSecrets.put(@server, {:header, "Authorization"}, @key)
    assert {:ok, %{started: [@server]}} = Restarter.reload()
    assert await_ready() == {:ok, 2}
    {:ok, owner, _generation} = RuntimeStatus.owner(@opts[:runtime_status], @source)
    requests = length(LoopbackHttp.requests(mcp))

    assert :ok = ConfigStore.put_mcp_tool(@server, "shout", false, mcp_supervisor: Restarter)

    assert eventually(fn -> hidden?("mcp_loopback_shout") end)
    refute hidden?("mcp_loopback_echo")
    assert {:ok, ^owner, _same} = RuntimeStatus.owner(@opts[:runtime_status], @source)

    # The switch re-listed the tools over the session it already had.
    assert [%{body: body}] = Enum.drop(LoopbackHttp.requests(mcp), requests)
    assert JSON.decode!(body)["method"] == "tools/list"

    moved = url <> "?v=2"
    assert :ok = ConfigStore.put_mcp_server(@server, %{"url" => moved}, mcp_supervisor: Restarter)

    assert await_ready() == {:ok, 2}
    assert {:ok, replacement, _new} = RuntimeStatus.owner(@opts[:runtime_status], @source)
    assert replacement != owner
    refute Process.alive?(owner)
    assert %{path: "/mcp?v=2"} = List.last(LoopbackHttp.requests(mcp))
    assert eventually(fn -> hidden?("mcp_loopback_shout") end)
  end

  # A hand-written URL Fermix refuses must never stop the daemon: the MCP
  # supervisor starts with it, and its row has the reason.
  test "a URL it refuses leaves a visible status and a running supervisor", %{home: home} do
    File.write!(Path.join(home, "config.toml"), config("http://mcp.example.com/mcp"))
    :ok = ConfigStore.apply_mcp_config()
    :ok = McpSecrets.put(@server, {:header, "Authorization"}, @key)

    capture_log(fn ->
      start_supervised!({McpSupervisor, [name: @supervisor] ++ @opts})

      assert eventually(fn ->
               match?(
                 {:ok, %{status: :invalid_remote_config, detail: :invalid_url}},
                 RuntimeStatus.fetch(@opts[:runtime_status], @source)
               )
             end)

      # The refusal ends its own subtree, and nothing else.
      assert eventually(fn -> not running?() end)
    end)

    assert Process.alive?(Process.whereis(@supervisor))
    assert cap_names() == []
  end

  # A deliberately small MCP server: a session id, two tools, and a call that
  # answers `isError`.
  defp mcp_server(%{method: "DELETE"}), do: {204, [], ""}

  defp mcp_server(%{method: "POST", body: body}) do
    case JSON.decode!(body) do
      %{"method" => "initialize", "id" => id} ->
        result = %{"protocolVersion" => "2025-11-25", "capabilities" => %{"tools" => %{}}}
        rpc(id, result, [{"mcp-session-id", "loop-session-1"}])

      %{"method" => "notifications/initialized"} ->
        {202, [], ""}

      %{"method" => "tools/list", "id" => id} ->
        rpc(id, %{"tools" => [tool("echo"), tool("shout")]})

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => "echo"} = params} ->
        rpc(id, %{"content" => [%{"type" => "text", "text" => params["arguments"]["text"]}]})

      %{"method" => "tools/call", "id" => id} ->
        rpc(id, %{"isError" => true, "content" => [%{"type" => "text", "text" => "too quiet"}]})
    end
  end

  defp rpc(id, result, headers \\ []) do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    {200, [{"content-type", "application/json"}] ++ headers, body}
  end

  defp tool(name) do
    %{
      "name" => name,
      "description" => "#{name} the text.",
      "inputSchema" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
    }
  end

  # The capability's own executor, through `Caller.OperatorRemote`, which
  # finds the owner in the daemon's `MCP.Registry`: the case publishes its owner
  # there for the call, as its `MCP.Server` did in the case's own registry.
  defp call_tool(name, args) do
    {:ok, owner, _generation} = RuntimeStatus.owner(@opts[:runtime_status], @source)
    :ok = McpRegistry.register(McpRegistry, @source, owner)

    try do
      {:ok, capability} = CapabilityRegistry.find(@opts[:capability_registry], name)
      {module, function, extra} = capability.executor
      apply(module, function, [args, %{session_id: "operator-remote-test"} | extra])
    after
      :ok = McpRegistry.unregister(McpRegistry, @source)
    end
  end

  # Ready with both tools, or the status it settled on instead.
  defp await_ready do
    ready? =
      eventually(fn ->
        match?(
          {:ok, %{status: :ready, discovery: %{tool_count: 2}}},
          RuntimeStatus.fetch(@opts[:runtime_status], @source)
        )
      end)

    if ready?, do: {:ok, 2}, else: RuntimeStatus.fetch(@opts[:runtime_status], @source)
  end

  defp running? do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.any?(&match?({{:mcp_server_supervisor, @source, _hash}, _pid, _type, _mods}, &1))
  end

  defp child_specs do
    for {{:mcp_server_supervisor, @source, _hash} = id, subtree, _type, _mods} <-
          Supervisor.which_children(@supervisor) do
      {:ok, spec} = :supervisor.get_childspec(@supervisor, id)
      children = for {child, _pid, _type, _m} <- Supervisor.which_children(subtree), do: child
      [spec | Enum.map(children, &elem(:supervisor.get_childspec(subtree, &1), 1))]
    end
  end

  defp cap_names do
    @opts[:capability_registry]
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.map(& &1.name)
  end

  defp hidden?(name) do
    case CapabilityRegistry.find(@opts[:capability_registry], name) do
      {:ok, capability} -> capability.hidden_from_agent?
      :error -> false
    end
  end

  defp eventually(fun) do
    deadline = System.monotonic_time(:millisecond) + @bound_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(home), do: System.put_env("FERMIX_HOME", home)

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
