defmodule FermixCore.Capabilities.MCP.StdioTransportTest do
  @moduledoc """
  The Fermix stdio transport of an operator MCP server (M74 E3), driven by the
  real Anubis client against the real stdio fixture
  (`test/fixtures/mcp_stdio_server.exs`): what the program's environment holds,
  that no secret value prints, that its stderr reaches its exit status, that it
  runs in its folder, its status from start to exit, and that an operator
  server and a plugin of one name no longer collide.

  Each case runs the starter's children under a subtree of its own, as
  `MCP.Supervisor` does, but with no restart budget, so a program's exit is
  the end of the case. Its status table and PATH owner are its own too; the
  secret store is the stub.
  """

  # `async: false`: secret values live in the stub store and the sandbox
  # settings in the application env, both global, and two cases capture logs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.AnubisStarter
  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Capabilities.MCP.StdioTransport
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.ProcessGroup
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @fixture Path.expand("../../../fixtures/mcp_stdio_server.exs", __DIR__)

  # A fresh `elixir` process booting and answering `initialize`, on the slowest
  # CI leg under load (the bound `AnubisStdioTest` uses).
  @bound_ms 20_000

  @secret "fixture-secret-7f3a9c41"

  # What starts the fixture sets for itself: the shell the transport starts the
  # program with (`PWD`, `SHLVL`), the `elixir` launcher script, and macOS for
  # every process. None is the daemon's.
  @launcher_env ~w(BINDIR EMU PROGNAME ROOTDIR PWD SHLVL __CF_USER_TEXT_ENCODING)

  setup do
    core =
      Map.new([:secret_writer, :profile, :sandbox], &{&1, Application.get_env(:fermix_core, &1)})

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    suffix = System.unique_integer([:positive])
    login_path_value = System.get_env("PATH")
    login_path = :"stdio_transport_login_path_#{suffix}"
    start_supervised!({LoginPath, name: login_path, read: fn -> {:ok, login_path_value} end})
    status = start_supervised!({RuntimeStatus, name: :"stdio_transport_status_#{suffix}"})

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"stdio_transport_cap_reg_#{suffix}"},
        id: :"stdio_transport_cap_reg_child_#{suffix}"
      )

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(key, value) end)
      SecretWriterStub.reset()
      Enum.each(~w(FERMIX_STDIO_PASSED FERMIX_STDIO_LEAK), &System.delete_env/1)
    end)

    %{
      elixir: System.find_executable("elixir") || raise("no `elixir` executable on PATH"),
      suffix: suffix,
      login_path: login_path,
      login_path_value: login_path_value,
      status: status,
      cap_registry: cap_registry
    }
  end

  describe "the program's environment" do
    test "holds the base, the login shell's PATH and what the server declares, no more", ctx do
      name = "env#{ctx.suffix}"
      System.put_env("FERMIX_STDIO_PASSED", "passed-value")
      System.put_env("FERMIX_STDIO_LEAK", "the-daemon-keeps-this")

      Application.put_env(
        :fermix_core,
        :sandbox,
        SandboxConfig.normalize(env: [allow: ["FERMIX_STDIO_PASSED"]])
      )

      :ok = McpSecrets.put(name, {:env, "API_TOKEN"}, @secret)

      spec =
        spec(ctx, name, "probe", %{
          env: %{"LITERAL" => "literal-value"},
          env_secrets: ["API_TOKEN"],
          pass_env: ["FERMIX_STDIO_PASSED"]
        })

      %{client: client} = start_server(ctx, spec)
      env = ctx |> call_tool(client, "environment") |> JSON.decode!()

      declared = %{
        "LITERAL" => "literal-value",
        "API_TOKEN" => @secret,
        "FERMIX_STDIO_PASSED" => "passed-value"
      }

      base = Map.take(System.get_env(), ~w(HOME LOGNAME SHELL TERM USER))
      expected = Map.merge(base, declared)

      assert Map.take(env, Map.keys(expected)) == expected
      assert String.ends_with?(env["PATH"], ctx.login_path_value)
      assert Map.keys(env) -- (Map.keys(expected) ++ ["PATH" | @launcher_env]) == []
      refute Map.has_key?(env, "FERMIX_STDIO_LEAK")
      refute Map.has_key?(env, "MIX_ENV")
    end

    test "runs in the server's folder", ctx do
      folder = SafeRm.make_tmp_dir!("stdio_transport_cwd")
      on_exit(fn -> SafeRm.rm_rf!(folder) end)

      %{client: client} =
        start_server(ctx, spec(ctx, "cwd#{ctx.suffix}", "probe", %{cwd: folder}))

      # The program sees the folder's physical path (`/private/var/…` for a
      # temporary folder on macOS); the name of the folder is unique.
      assert String.ends_with?(call_tool(ctx, client, "cwd"), Path.relative_to(folder, "/"))
    end
  end

  describe "secret values" do
    test "are in neither the transport's printed state nor its crash report", ctx do
      name = "redact#{ctx.suffix}"
      :ok = McpSecrets.put(name, {:env, "API_TOKEN"}, @secret)
      spec = spec(ctx, name, "probe", %{env_secrets: ["API_TOKEN"]})
      %{client: client, subtree: subtree} = start_server(ctx, spec)
      transport = Module.concat(client, "Transport")

      # The value did reach the program.
      assert ctx |> call_tool(client, "environment") |> JSON.decode!() |> Map.get("API_TOKEN") ==
               @secret

      printed = inspect(:sys.get_status(transport), limit: :infinity, printable_limit: :infinity)
      refute printed =~ @secret

      log =
        capture_log(fn ->
          transport_ref = Process.monitor(transport)
          subtree_ref = Process.monitor(subtree)
          :ok = ProcessGroup.signal(:sys.get_state(transport).os_pid, :sigkill)

          assert_receive {:DOWN, ^transport_ref, :process, _pid, {:mcp_server_exited, _status}},
                         @bound_ms

          assert_receive {:DOWN, ^subtree_ref, :process, _pid, _reason}, @bound_ms
        end)

      assert log =~ "mcp_server_exited"
      refute log =~ @secret
    end
  end

  describe "stderr" do
    test "the program's last lines reach its exit status, bounded", ctx do
      name = "crash#{ctx.suffix}"

      capture_log(fn ->
        %{client: client} = start_server(ctx, spec(ctx, name, "crash"), await: false)
        transport_ref = Process.monitor(Module.concat(client, "Transport"))

        assert_receive {:DOWN, ^transport_ref, :process, _pid, {:mcp_server_exited, 3}},
                       @bound_ms
      end)

      assert {:ok, entry} = RuntimeStatus.fetch(ctx.status, {:operator, name})
      assert {entry.status, entry.detail} == {:remote_unreachable, :exited}
      assert entry.stderr_tail == Enum.map(11..30, &"fixture stderr line #{&1}")
    end

    test "only the end of a long stderr is read, and invalid UTF-8 is replaced" do
      dir = SafeRm.make_tmp_dir!("stdio_transport_tail")
      on_exit(fn -> SafeRm.rm_rf!(dir) end)
      path = Path.join(dir, "operator-long.stderr")

      long = for n <- 1..10, do: String.duplicate("#{rem(n, 10)}", 999) <> "\n"
      File.write!(path, [long, "bad byte ", <<0xFF>>, "\n"])
      lines = StdioTransport.tail(path)

      assert byte_size(Enum.join(lines)) <= 4_096
      assert List.last(lines) == "bad byte �"
      assert Enum.all?(Enum.drop(lines, -1), &(byte_size(&1) == 999))

      File.write!(path, Enum.map(1..30, &"line #{&1}\n"))
      assert StdioTransport.tail(path) == Enum.map(11..30, &"line #{&1}")
    end

    # A server that talks for days must not fill the disk: past its cap the
    # file's last lines are carried and the file emptied, and the exit sentence
    # reads the carry and then what the file holds.
    test "the file is held under its cap, and the last lines still reach the exit", ctx do
      name = "chatty#{ctx.suffix}"
      cap = 2_048
      bound = [stderr_cap_bytes: cap, stderr_check_ms: 20]
      %{client: client} = start_server(ctx, spec(ctx, name, "chatty"), transport: bound)
      transport = Module.concat(client, "Transport")

      # The 400 lines are written before the fixture answers `initialize`, but
      # a check may land while they are being written; the one that matters
      # carries the last of them.
      assert eventually(fn ->
               List.last(:sys.get_state(transport).stderr_carry) == "fixture chatty line 400"
             end)

      %{stderr_file: file, stderr_carry: carry} = :sys.get_state(transport)
      assert File.stat!(file).size <= cap
      assert carry == Enum.map(381..400, &"fixture chatty line #{&1}")

      capture_log(fn ->
        ref = Process.monitor(transport)
        # The call never gets its answer: the program exits instead.
        _caller = spawn(fn -> Anubis.Client.call_tool(client, "finish", %{}) end)
        assert_receive {:DOWN, ^ref, :process, _pid, {:mcp_server_exited, 4}}, @bound_ms
      end)

      assert {:ok, %{detail: :exited, stderr_tail: tail}} = fetch(ctx, {:operator, name})

      assert tail ==
               Enum.map(384..400, &"fixture chatty line #{&1}") ++
                 Enum.map(1..3, &"fixture last words #{&1}")
    end
  end

  describe "status" do
    test "connecting, then ready with the tool count, then the program's exit", ctx do
      name = "status#{ctx.suffix}"
      source = {:operator, name}

      %{client: client} =
        start_server(ctx, spec(ctx, name, "serve"), await: false, discovery: true)

      transport = Module.concat(client, "Transport")

      assert {:ok, %{status: status, owner: owner}} = RuntimeStatus.fetch(ctx.status, source)
      assert status in [:connecting, :ready]
      assert owner == Process.whereis(transport)

      assert eventually(fn -> match?({:ok, %{status: :ready}}, fetch(ctx, source)) end)
      assert {:ok, %{tool_count: 2}} = fetch(ctx, source)

      capture_log(fn ->
        ref = Process.monitor(transport)
        :ok = ProcessGroup.signal(:sys.get_state(transport).os_pid, :sigkill)
        assert_receive {:DOWN, ^ref, :process, _pid, {:mcp_server_exited, _status}}, @bound_ms
      end)

      assert {:ok, %{status: :remote_unreachable, detail: :exited, tool_count: nil}} =
               fetch(ctx, source)
    end

    test "a program that never answers is connecting, then out of retries", ctx do
      name = "silent#{ctx.suffix}"
      source = {:operator, name}
      spec = spec(ctx, name, "silent")

      capture_log(fn ->
        %{subtree: subtree} =
          start_server(ctx, spec, await: false, discovery: true, first_connection_ms: 300)

        ref = Process.monitor(subtree)
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, @bound_ms
      end)

      assert {:ok, %{status: :remote_unreachable, detail: :retries_exhausted}} =
               fetch(ctx, source)
    end

    test "a program it cannot find, or a folder that is not there, is not started", ctx do
      for {name, extra, detail} <- [
            {"absent#{ctx.suffix}", %{command: "fermix-no-such-mcp-server"}, :command_not_found},
            {"nofolder#{ctx.suffix}", %{cwd: "/nonexistent/fermix/folder"}, :cwd_not_found}
          ] do
        capture_log(fn ->
          %{subtree: subtree} = start_server(ctx, spec(ctx, name, "serve", extra), await: false)
          ref = Process.monitor(subtree)
          assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, @bound_ms
        end)

        assert {:ok, %{status: :invalid_remote_config, detail: ^detail}} =
                 fetch(ctx, {:operator, name})
      end
    end
  end

  # Before M74 both clients were registered as `Client.<name>` and introduced
  # themselves as `fermix-<name>`: the second start was refused, and two
  # clients of one `client_info` name crash on the second `tools/list` reply.
  test "an operator server and a plugin of the same name run side by side", ctx do
    name = "dup#{ctx.suffix}"
    %{client: operator} = start_server(ctx, spec(ctx, name, "serve"))

    plugin_spec = %{
      name: name,
      source_id: {:plugin, name},
      command: ctx.elixir,
      args: [@fixture]
    }

    %{children: [plugin_child], client_name: plugin} =
      AnubisStarter.Default.child_specs_for(plugin_spec, %{})

    start_supervised!(plugin_child)
    assert :ok = Anubis.Client.await_ready(plugin, timeout: @bound_ms)

    refute operator == plugin
    assert {:ok, %{result: %{"tools" => [_ | _]}}} = Anubis.Client.list_tools(operator)
    assert {:ok, %{result: %{"tools" => [_ | _]}}} = Anubis.Client.list_tools(plugin)
  end

  # --- helpers ----------------------------------------------------------------

  defp spec(ctx, name, mode, extra \\ %{}) do
    Map.merge(
      %{
        name: name,
        source_id: {:operator, name},
        transport: :stdio,
        command: ctx.elixir,
        args: [@fixture, "2025-11-25", mode],
        cwd: nil,
        env: %{},
        env_secrets: [],
        pass_env: []
      },
      extra
    )
  end

  # The starter's children, plus `MCP.Server` when the case watches discovery,
  # under one subtree with the production shape and no restart budget.
  defp start_server(ctx, spec, opts \\ []) do
    config = %{runtime_status: ctx.status, login_path: ctx.login_path}

    %{children: children, client_name: client} =
      AnubisStarter.Default.child_specs_for(spec, config)

    transport_opts = Keyword.get(opts, :transport, [])
    children = Enum.map(children, &with_transport_opts(&1, transport_opts))
    children = children ++ discovery(ctx, spec, client, opts)

    subtree =
      start_supervised!(%{
        id: {:stdio_subtree, spec.name},
        start:
          {Supervisor, :start_link,
           [
             children,
             [strategy: :one_for_all, max_restarts: 0, auto_shutdown: :any_significant]
           ]},
        type: :supervisor,
        restart: :temporary
      })

    if Keyword.get(opts, :await, true),
      do: assert(:ok = Anubis.Client.await_ready(client, timeout: @bound_ms))

    %{client: client, subtree: subtree}
  end

  # The stderr bound's seams, put into the transport's own start options.
  defp with_transport_opts(%{id: {:stdio_transport, _source}} = child, extra) do
    update_in(child.start, fn {module, fun, [opts]} -> {module, fun, [opts ++ extra]} end)
  end

  defp with_transport_opts(child, _extra), do: child

  defp discovery(ctx, spec, client, opts) do
    if Keyword.get(opts, :discovery, false) do
      on_exit(fn -> Enum.each(~w(echo refuse), &Naming.unregister("mcp_#{spec.name}_#{&1}")) end)

      server_opts =
        [
          server_name: spec.name,
          source_id: spec.source_id,
          client: client,
          capability_registry: ctx.cap_registry,
          runtime_status: ctx.status,
          main_agent: nil,
          realtime_supervisor: nil,
          retry_base_ms: 200
        ] ++ Keyword.take(opts, [:first_connection_ms])

      [
        Supervisor.child_spec({McpServer, server_opts},
          id: {:mcp_server, spec.name},
          restart: :transient,
          significant: true
        )
      ]
    else
      []
    end
  end

  defp call_tool(_ctx, client, tool) do
    assert {:ok, %{result: %{"content" => [%{"text" => text}]}}} =
             Anubis.Client.call_tool(client, tool, %{})

    text
  end

  defp fetch(ctx, source), do: RuntimeStatus.fetch(ctx.status, source)

  # Discovery retries on its own schedule; this waits for what it reaches.
  defp eventually(fun, bound_ms \\ 30_000) do
    poll(fun, System.monotonic_time(:millisecond) + bound_ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> poll_again(fun, deadline)
    end
  end

  defp poll_again(fun, deadline) do
    Process.sleep(50)
    poll(fun, deadline)
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
