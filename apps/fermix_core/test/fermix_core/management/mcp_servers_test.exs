defmodule FermixCore.Management.McpServersTest do
  @moduledoc """
  The `mcp.servers.*` operations (M74 E7) against the one write path.

  Every case runs against its own home and the stub secret store, with a
  status table of its own. The MCP tree is `FakeTree`: a reload that starts
  nothing, and a restart that installs an owner in this case's table and
  writes the status a named server would reach, so no case starts a program.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.McpServers
  alias FermixCore.Management.McpServers.Row
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @status :mcp_servers_test_status
  @successes Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")
  # Polled every 10 ms: a job a double answers at once is terminal far sooner.
  @job_wait_attempts 1_000

  # Stands in for `McpSupervisor`. A restart installs an owner in this case's
  # table and writes what the server named reaches; nothing is ever running.
  defmodule FakeTree do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.Discoverer
    alias FermixCore.Capabilities.MCP.RuntimeStatus

    @status :mcp_servers_test_status

    def reload, do: {:ok, %{started: [], stopped: [], unchanged: [], failed: []}}
    def subtree_alive?(_source_id), do: false

    def restart_server({:operator, name} = source_id, _server) do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, generation} = RuntimeStatus.register_owner(@status, source_id, owner)
      :ok = settle(name, source_id, generation)
      {:ok, owner}
    end

    def list_tools(_source_id, _server), do: {:ok, tools()}

    def tools, do: [%{name: "fetch", title: "Fetch"}, %{name: "search", description: "Finds."}]

    defp settle("broken", source_id, generation),
      do:
        RuntimeStatus.put(@status, source_id, generation, :invalid_remote_config, :cwd_not_found)

    defp settle(_name, source_id, generation) do
      discovery = Discoverer.discovery(tools(), %{"name" => "fake", "version" => "1.0.0"})
      RuntimeStatus.put_ready(@status, source_id, generation, discovery)
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("management-mcp-servers")
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = Application.get_all_env(:fermix_core)

    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    System.put_env("FERMIX_HOME", home)
    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()

    start_supervised!({RuntimeStatus, name: @status})
    tasks = :"mcp_servers_test_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: tasks})
    jobs = start_supervised!({Jobs, name: :mcp_servers_test_jobs, task_supervisor: tasks})

    on_exit(fn ->
      restore_core_env(previous_env)
      SecretWriterStub.reset()
      restore_home(previous_home)
      SafeRm.rm_rf!(home)
      :ok = RestartState.record_persisted_baseline()
    end)

    opts = [mcp_supervisor: FakeTree, runtime_status: @status, jobs: [server: jobs]]
    %{home: home, path: Path.join(home, "config.toml"), opts: opts, jobs: [server: jobs]}
  end

  describe "list and get" do
    test "a server written by hand shows like one added here", %{path: path, opts: opts} do
      write_config!(path, """
      [mcp.servers.files]
      command = "sh"
      args = ["serve files"]
      env_secrets = ["GITHUB_TOKEN"]

      [mcp.servers.notes]
      command = "/bin/sh"
      enabled = false
      """)

      assert {:ok, %{"servers" => [files, notes], "limits" => limits, "can_add" => true}} =
               McpServers.list(opts)

      assert limits == %{"max_servers" => McpConfig.max_servers()}

      assert %{
               "status" => "needs_secret",
               "status_sentence" => "Waiting for GITHUB_TOKEN.",
               "location" => "sh 'serve files'",
               "resolved_command" => resolved,
               "env" => [%{"name" => "GITHUB_TOKEN", "present" => false}],
               "origin" => nil,
               "actions" => ["disable"]
             } = files

      assert resolved == System.find_executable("sh")
      refute Map.has_key?(files, "tools")

      assert %{"status" => "off", "primary_action" => "enable", "actions" => ["enable"]} = notes
    end

    test "get carries the tools the last discovery listed, with the owner's switches", %{
      path: path,
      opts: opts
    } do
      write_config!(path, """
      [mcp.servers.fetch]
      command = "/bin/sh"

      [mcp.servers.fetch.tools.search]
      hidden_from_agent = true
      """)

      {:ok, _owner} = FakeTree.restart_server({:operator, "fetch"}, %{})

      assert {:ok, %{"server" => server}} = McpServers.get("fetch", opts)

      assert %{
               "status" => "connected",
               "status_sentence" => "Connected. 2 tools.",
               "server_info" => %{"name" => "fake", "title" => nil, "version" => "1.0.0"},
               "tool_count" => 2,
               "tools_on" => 1,
               "tools" => [
                 %{"name" => "fetch", "title" => "Fetch", "enabled" => true},
                 %{"name" => "search", "description" => "Finds.", "enabled" => false}
               ]
             } = server
    end

    test "a name no server has is refused by field", %{opts: opts} do
      assert {:error, {:invalid_params, "name", "There is no MCP server by that name."}} =
               McpServers.get("nowhere", opts)
    end
  end

  describe "add" do
    test "a local server is written as a hand edit would hold it, and checked", ctx do
      params = %{"name" => "fetch", "transport" => "stdio", "command_line" => "sh 'mcp fetch' -v"}

      assert {:ok, %{"server" => server, "job_id" => job_id}} = McpServers.add(params, ctx.opts)

      assert block(ctx.path, "fetch") ==
               ~s(args = ["mcp fetch", "-v"]\ncommand = "sh"\norigin = "added")

      assert %{"status" => "starting", "origin" => "added", "location" => "sh 'mcp fetch' -v"} =
               server

      assert {:ok, %{"status" => "completed", "kind" => "mcp_check", "result" => result}} =
               eventually_terminal(ctx.jobs, job_id)

      assert %{"tool_count" => 2, "latency_ms" => latency} = result
      assert is_integer(latency) and latency >= 0
    end

    test "a remote server with a key waits for it, and no check starts", ctx do
      params = %{
        "name" => "linear",
        "transport" => "http",
        "url" => "https://mcp.linear.app/mcp",
        "auth" => "header",
        "key_header" => "Authorization",
        "header_names" => ["X-Workspace"]
      }

      assert {:ok, %{"server" => server, "job_id" => nil}} = McpServers.add(params, ctx.opts)

      assert {:ok, linear} = server_config("linear")
      assert linear.header_secrets == ["X-Workspace", "Authorization"]
      assert linear.key_header == "Authorization"

      assert %{
               "status" => "needs_secret",
               "status_sentence" => "Waiting for X-Workspace and the key.",
               "headers" => [%{"name" => "X-Workspace", "present" => false}],
               "auth" => %{"mode" => "header", "state" => "signed_out"},
               "consent_sentence" =>
                 "Runs on mcp.linear.app. What you ask its tools is sent there."
             } = server
    end

    test "each refusal names the field a form marks", %{opts: opts} do
      local = %{"name" => "fetch", "transport" => "stdio"}
      remote = %{"name" => "web", "transport" => "http"}

      refusals = [
        {Map.put(local, "command_line", "npx 'open"), "command_line"},
        {Map.put(local, "command_line", "npx server | tee log"), "command_line"},
        {local, "command_line"},
        {Map.merge(local, %{"command_line" => "sh", "env_names" => ["1BAD"]}), "env_names"},
        {Map.merge(local, %{"command_line" => "sh", "url" => "https://x.dev"}), "url"},
        {Map.put(remote, "url", "ftp://files.example.com/mcp"), "url"},
        {Map.merge(remote, %{"url" => "https://x.dev/mcp", "key_header" => "X-Key"}),
         "key_header"},
        {Map.merge(remote, %{"url" => "https://x.dev/mcp", "auth" => "basic"}), "auth"},
        {%{"name" => "GitHub", "transport" => "stdio", "command_line" => "sh"}, "name"},
        {%{"name" => "fetch", "command_line" => "sh"}, "transport"}
      ]

      for {params, field} <- refusals do
        assert {:error, {:invalid_params, ^field, sentence}} = McpServers.add(params, opts),
               "#{inspect(params)} was not refused at #{field}"

        assert is_binary(sentence) and sentence != ""
      end
    end

    test "a refused URL carries the rule's own sentence", %{opts: opts} do
      params = %{"name" => "web", "transport" => "http", "url" => "http://example.com/mcp"}

      assert {:error, {:invalid_params, "url", sentence}} = McpServers.add(params, opts)
      assert sentence == Row.url_sentence()
    end

    test "a name already here is refused rather than merged", %{path: path, opts: opts} do
      write_config!(path, ~s([mcp.servers.fetch]\ncommand = "sh"\n))

      params = %{"name" => "fetch", "transport" => "http", "url" => "https://x.dev/mcp"}

      assert {:error, {:invalid_params, "name", _sentence}} = McpServers.add(params, opts)
      assert {:ok, %{transport: :stdio}} = server_config("fetch")
    end
  end

  describe "update" do
    test "changes the fields given, and a value no longer declared is deleted", ctx do
      write_config!(ctx.path, """
      [mcp.servers.files]
      command = "sh"
      cwd = "/tmp"
      env_secrets = ["GITHUB_TOKEN", "OLD_KEY"]
      origin = "added"
      """)

      :ok = McpSecrets.put("files", {:env, "OLD_KEY"}, "old")
      :ok = McpSecrets.put("files", {:env, "GITHUB_TOKEN"}, "kept")

      params = %{
        "name" => "files",
        "command_line" => "sh run.sh",
        "env_names" => ["GITHUB_TOKEN"]
      }

      assert {:ok, %{"server" => server}} = McpServers.update(params, ctx.opts)

      assert {:ok, files} = server_config("files")
      assert {files.command, files.args, files.cwd} == {"sh", ["run.sh"], "/tmp"}
      assert files.env_secrets == ["GITHUB_TOKEN"]
      assert {:error, _absent} = McpSecrets.fetch("files", {:env, "OLD_KEY"})
      assert {:ok, "kept"} = McpSecrets.fetch("files", {:env, "GITHUB_TOKEN"})

      assert %{"env" => [%{"name" => "GITHUB_TOKEN", "present" => true}], "cwd" => "/tmp"} =
               server
    end

    test "a null clears a field and the key header follows the sign-in mode", ctx do
      write_config!(ctx.path, """
      [mcp.servers.linear]
      transport = "http"
      url = "https://mcp.linear.app/mcp"
      auth = "header"
      key_header = "Authorization"
      header_secrets = ["X-Workspace", "Authorization"]
      """)

      :ok = McpSecrets.put("linear", {:header, "Authorization"}, "secret")

      assert {:ok, %{"server" => %{"auth" => %{"mode" => "auto", "key_header" => nil}}}} =
               McpServers.update(%{"name" => "linear", "auth" => "auto"}, ctx.opts)

      assert {:ok, linear} = server_config("linear")
      assert linear.header_secrets == ["X-Workspace"]
      assert {:error, _absent} = McpSecrets.fetch("linear", {:header, "Authorization"})
    end

    test "the transport and the name stay", %{path: path, opts: opts} do
      write_config!(path, ~s([mcp.servers.files]\ncommand = "sh"\n))

      assert {:error, {:invalid_params, "transport", _sentence}} =
               McpServers.update(%{"name" => "files", "transport" => "http"}, opts)

      assert {:error, {:invalid_params, "name", _sentence}} =
               McpServers.update(%{"name" => "nowhere", "command_line" => "sh"}, opts)

      assert McpConfig.configured() |> Enum.map(& &1.name) == ["files"]
    end
  end

  describe "remove, enable, disable and tool switches" do
    test "remove forgets the block, its values and its live status", ctx do
      write_config!(ctx.path, ~s([mcp.servers.files]\ncommand = "sh"\nenv_secrets = ["KEY"]\n))
      :ok = McpSecrets.put("files", {:env, "KEY"}, "value")
      {:ok, _owner} = FakeTree.restart_server({:operator, "files"}, %{})

      assert {:ok, %{"name" => "files", "removed" => true}} = McpServers.remove("files", ctx.opts)

      refute File.read!(ctx.path) =~ "mcp.servers.files"
      assert {:error, _absent} = McpSecrets.fetch("files", {:env, "KEY"})
      assert :error = RuntimeStatus.fetch(@status, {:operator, "files"})

      assert {:error, {:invalid_params, "name", _sentence}} =
               McpServers.remove("files", ctx.opts)
    end

    test "disable writes the switch a hand edit would, and enable takes it out", ctx do
      write_config!(ctx.path, ~s([mcp.servers.files]\ncommand = "sh"\n))

      assert {:ok, %{"server" => %{"status" => "off", "primary_action" => "enable"}}} =
               McpServers.disable("files", ctx.opts)

      assert block(ctx.path, "files") == ~s(command = "sh"\nenabled = false)

      assert {:ok, %{"server" => %{"status" => "starting", "enabled" => true}}} =
               McpServers.enable("files", ctx.opts)

      assert block(ctx.path, "files") == ~s(command = "sh")

      assert {:error, {:invalid_params, "name", _sentence}} =
               McpServers.enable("nowhere", ctx.opts)
    end

    test "a tool switch is written in the tool's block and counted on the row", ctx do
      write_config!(ctx.path, ~s([mcp.servers.files]\ncommand = "sh"\n))
      {:ok, _owner} = FakeTree.restart_server({:operator, "files"}, %{})

      assert {:ok, %{"server" => %{"tools_on" => 1, "tool_count" => 2}}} =
               McpServers.tool_set("files", "search", false, ctx.opts)

      assert File.read!(ctx.path) =~ "[mcp.servers.files.tools.search]"

      assert {:ok, %{"server" => %{"tools_on" => 2}}} =
               McpServers.tool_set("files", "search", true, ctx.opts)
    end
  end

  describe "check" do
    test "a server that does not start is refused with its row's sentence", ctx do
      write_config!(ctx.path, """
      [mcp.servers.files]
      command = "sh"
      env_secrets = ["KEY"]

      [mcp.servers.notes]
      command = "sh"
      enabled = false
      """)

      assert {:error, {:invalid_params, "name", "Waiting for KEY."}} =
               McpServers.check_start("files", ctx.opts)

      assert {:error, {:invalid_params, "name", "Turned off."}} =
               McpServers.check_start("notes", ctx.opts)
    end

    test "a connection that fails ends the job with the row's sentence", ctx do
      write_config!(ctx.path, ~s([mcp.servers.broken]\ncommand = "sh"\ncwd = "/nowhere"\n))

      assert {:ok, %{"job_id" => job_id, "kind" => "mcp_check"}} =
               McpServers.check_start("broken", ctx.opts)

      assert {:ok, %{"status" => "failed", "phase" => "connecting", "failure" => failure}} =
               eventually_terminal(ctx.jobs, job_id)

      assert failure == %{
               "code" => "unavailable",
               "sentence" => "Fermix could not find the working folder /nowhere on this Mac."
             }
    end
  end

  # The write methods answer from a home, which the router-driven contract test
  # cannot give them, so their shapes are pinned to the goldens here.
  test "every write answers with its golden shape", ctx do
    write_config!(ctx.path, ~s([mcp.servers.files]\ncommand = "sh"\n))
    {:ok, _owner} = FakeTree.restart_server({:operator, "files"}, %{})

    add = %{"name" => "fetch", "transport" => "stdio", "command_line" => "sh"}
    remote = %{"name" => "web", "transport" => "http", "url" => "https://x.dev/mcp"}
    remote = Map.merge(remote, %{"auth" => "header", "key_header" => "X-Key"})

    answers = [
      {"mcp_servers_add", McpServers.add(add, ctx.opts)},
      {"mcp_servers_add_remote_key", McpServers.add(remote, ctx.opts)},
      {"mcp_servers_update", McpServers.update(%{"name" => "files", "cwd" => nil}, ctx.opts)},
      {"mcp_servers_tool_set", McpServers.tool_set("files", "search", true, ctx.opts)},
      {"mcp_servers_disable", McpServers.disable("files", ctx.opts)},
      {"mcp_servers_enable", McpServers.enable("files", ctx.opts)},
      {"mcp_servers_remove", McpServers.remove("web", ctx.opts)}
    ]

    for {golden, {:ok, answer}} <- answers do
      assert shape(answer) == shape(golden(golden)), "#{golden} no longer has its golden shape"
    end

    assert length(answers) == 7
  end

  defp write_config!(path, contents) do
    File.write!(path, contents)
    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()
  end

  # The keys of one server's block, as the file holds them.
  defp block(path, name) do
    [_before, rest] = String.split(File.read!(path), "[mcp.servers.#{name}]\n", parts: 2)
    rest |> String.split("\n[", parts: 2) |> hd() |> String.trim()
  end

  defp server_config(name) do
    case Enum.find(McpConfig.configured(), &(&1.name == name)) do
      nil -> :error
      server -> {:ok, server}
    end
  end

  defp golden(name) do
    @successes
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == name))
    |> get_in(["response", "result"])
  end

  # Keys and container kinds; a null and a value are both a scalar.
  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar

  defp eventually_terminal(jobs, job_id, attempts \\ @job_wait_attempts)
  defp eventually_terminal(_jobs, job_id, 0), do: {:error, {:never_terminal, job_id}}

  defp eventually_terminal(jobs, job_id, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      eventually_terminal(jobs, job_id, attempts - 1)
    else
      {:ok, view}
    end
  end

  defp restore_core_env(previous) do
    for {key, _value} <- Application.get_all_env(:fermix_core),
        not Keyword.has_key?(previous, key) do
      Application.delete_env(:fermix_core, key)
    end

    Enum.each(previous, fn {key, value} -> Application.put_env(:fermix_core, key, value) end)
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)
end
