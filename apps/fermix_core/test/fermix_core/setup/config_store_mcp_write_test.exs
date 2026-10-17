defmodule FermixCore.Setup.ConfigStoreMcpWriteTest do
  @moduledoc """
  The one write path for operator MCP servers (M74 E2): `put_mcp_server/3`,
  `delete_mcp_server/2` and `put_mcp_tool/4`. Each one asks the outside-edit
  guard, takes the config lock every writer of `config.toml` takes, renders
  through the settings renderer, records the baseline and applies the result.

  Every case runs against its own home and the stub secret store. The MCP
  supervisor is a recorder, or a tree of this case's own with stub discovery,
  so no case starts a program.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Dist.Lock
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  # Stands in for `McpSupervisor`: reports each reload to the writing process.
  defmodule RecordingReloader do
    @moduledoc false

    def reload do
      send(self(), :reloaded)
      {:ok, %{started: [], stopped: [], unchanged: [], failed: []}}
    end
  end

  # One stdio client per server, a process that only exists: the server's own
  # program, as far as a test can see it.
  defmodule FakeClient do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule FakeStarter do
    @moduledoc false
    @behaviour FermixCore.Capabilities.MCP.AnubisStarter

    @impl true
    def child_specs_for(server, _config) do
      name = :"config_store_mcp_client_#{server.name}"
      spec = Supervisor.child_spec({FakeClient, name: name}, id: {:fake_client, server.name})
      %{children: [spec], client_name: name}
    end
  end

  defmodule TwoTools do
    @moduledoc false
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @impl true
    def list_tools(_client) do
      {:ok,
       [
         %{name: "create_issue", description: "Create an issue.", input_schema: %{}},
         %{name: "list_issues", description: "List issues.", input_schema: %{}}
       ]}
    end
  end

  defmodule NoCalls do
    @moduledoc false
    @behaviour FermixCore.Capabilities.MCP.Caller

    @impl true
    def call_tool(_source_id, _tool, _args, _context), do: {:error, :not_in_this_test}
  end

  # Reloads this case's own MCP tree from the servers the write applied, the
  # way `McpSupervisor.reload/0` reloads the daemon's, with discovery stubbed.
  defmodule TreeReloader do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.Config, as: McpConfig
    alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
    alias FermixCore.Setup.ConfigStoreMcpWriteTest.{FakeStarter, NoCalls, TwoTools}

    def supervisor, do: :config_store_mcp_write_tree

    def collaborators,
      do: [
        capability_registry: :config_store_mcp_write_capabilities,
        mcp_registry: :config_store_mcp_write_registry,
        anubis_starter: FakeStarter
      ]

    def servers do
      McpConfig.configured()
      |> Enum.filter(&McpConfig.startable?/1)
      |> Enum.map(&Map.merge(&1, %{discoverer: TwoTools, caller: NoCalls}))
    end

    def reload, do: McpSupervisor.reload(supervisor(), [servers: servers()] ++ collaborators())
  end

  @recording [mcp_supervisor: RecordingReloader]
  @files %{"command" => "/opt/homebrew/bin/npx", "args" => ["-y", "server-filesystem"]}

  setup do
    home = SafeRm.make_tmp_dir!("config-store-mcp-write")
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = Application.get_all_env(:fermix_core)

    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    System.put_env("FERMIX_HOME", home)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      restore_core_env(previous_env)
      SecretWriterStub.reset()
      restore_home(previous_home)
      SafeRm.rm_rf!(home)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: home, path: Path.join(home, "config.toml")}
  end

  describe "put_mcp_server/3" do
    test "writes the block a hand edit would hold, applies it and reloads", %{path: path} do
      File.write!(path, ~s([fermix_core.personalization]\nuser_name = "Ada"\n))
      :ok = RestartState.record_persisted_baseline()

      attrs = Map.merge(@files, %{"env_secrets" => ["GITHUB_TOKEN"], "origin" => "added"})
      assert :ok = ConfigStore.put_mcp_server("files", attrs, @recording)
      assert_received :reloaded

      written = File.read!(path)
      assert written =~ ~s(user_name = "Ada")

      assert String.ends_with?(written, """

             [mcp.servers.files]
             args = ["-y", "server-filesystem"]
             command = "/opt/homebrew/bin/npx"
             env_secrets = ["GITHUB_TOKEN"]
             origin = "added"
             """)

      assert [%{name: "files", env_secrets: ["GITHUB_TOKEN"]}] = McpConfig.configured()
    end

    # The baseline is recorded with the write, so the next settings save does
    # not read this write as an edit made outside Fermix.
    test "a settings save after a server write goes through", %{path: path} do
      assert :ok = ConfigStore.put_mcp_server("files", @files, @recording)

      assert RestartState.writable() == :ok
      {:ok, snapshot} = ConfigStore.load_runtime_config()
      renamed = put_in(snapshot, [:fermix_core, :personalization, :user_name], "Grace")
      assert :ok = ConfigStore.save_snapshot(renamed)

      assert [%{name: "files"}] = McpConfig.from_toml(File.read!(path))
    end

    # The round trip the read-back check used to guard is held here, over the
    # values a writer accepts: spaces, quotes inside, backslashes, a comma in an
    # argument and text that looks like a number or a switch.
    test "awkward values read back exactly as they were written", %{path: path} do
      attrs = %{
        "command" => ~S(C:\Program Files\mcp\server.exe),
        "args" => [
          "--root",
          "/Users/owner/My Documents",
          ~S(--label=say "hi"),
          "a,b",
          "C:\\tools\\",
          "true",
          "42",
          ~S("quoted")
        ],
        "cwd" => ~S(/Users/owner/Work "Folder"\sub),
        "origin" => "imported:claude_desktop",
        "enabled" => false
      }

      assert :ok = ConfigStore.put_mcp_server("files", attrs, @recording)

      assert [server] = McpConfig.from_toml(File.read!(path))
      assert server.command == attrs["command"]
      assert server.args == attrs["args"]
      assert server.cwd == attrs["cwd"]
      assert server.origin == "imported:claude_desktop"
      assert server.enabled? == false

      first = File.read!(path)
      {:ok, snapshot} = ConfigStore.load_runtime_config()
      assert :ok = ConfigStore.save_snapshot(snapshot)
      assert File.read!(path) == first
    end

    test "an edit merges over the server and keeps what the owner wrote by hand", %{path: path} do
      File.write!(path, """
      [mcp.servers.files]
      command = "npx"
      env = { LEVEL = "debug" }
      timeout = 30

      [mcp.servers.files.tools.write_file]
      hidden_from_agent = true
      """)

      :ok = RestartState.record_persisted_baseline()

      assert :ok = ConfigStore.put_mcp_server("files", %{"enabled" => false}, @recording)

      assert McpConfig.document(File.read!(path)) == %{
               "files" => %{
                 server: %{
                   "command" => "npx",
                   "enabled" => false,
                   "env" => %{"LEVEL" => "debug"},
                   "timeout" => 30
                 },
                 tools: %{"write_file" => %{"hidden_from_agent" => true}}
               }
             }
    end

    test "a refusal names its field and changes nothing", %{path: path} do
      assert :ok = ConfigStore.put_mcp_server("files", @files, @recording)
      assert_received :reloaded
      before = File.read!(path)

      for {name, attrs, field} <- [
            {"files", %{"cwd" => "line one\nline two"}, "cwd"},
            {"files", %{"env" => %{"A" => "b"}}, "env"},
            {"Bad Name", @files, "name"},
            {"files_", %{"command" => "uvx"}, "name"},
            {"gmail", @files, "name"}
          ] do
        assert {:error, {:invalid_params, ^field, sentence}} =
                 ConfigStore.put_mcp_server(name, attrs, @recording)

        assert is_binary(sentence)
      end

      assert File.read!(path) == before
      refute_received :reloaded
    end

    test "an outside edit refuses the write before anything is written", %{path: path} do
      assert :ok = ConfigStore.put_mcp_server("files", @files, @recording)

      File.write!(
        path,
        File.read!(path) <> "\n[fermix_core.personalization]\nuser_name = \"Ada\"\n"
      )

      edited = File.read!(path)

      assert {:error, {:external_change, _sections}} =
               ConfigStore.put_mcp_server("files", %{"enabled" => false}, @recording)

      assert File.read!(path) == edited
    end

    test "a section the renderer would drop refuses the write", %{path: path} do
      File.write!(path, "[custom]\nkey = \"kept\"\n")
      :ok = RestartState.record_persisted_baseline()

      assert {:error, {:unrenderable_settings, sentence}} =
               ConfigStore.put_mcp_server("files", @files, @recording)

      assert sentence =~ "[custom]"
      assert File.read!(path) == "[custom]\nkey = \"kept\"\n"
    end
  end

  # A key the reader does not read is the owner's: the load names it and goes
  # on, rather than refusing a file that carries one.
  test "a key the reader does not read is named once at load, never refused", %{path: path} do
    File.write!(path, """
    [mcp.servers.files]
    command = "npx"
    timeout = 30
    """)

    log = capture_log(fn -> assert :ok = ConfigStore.apply_mcp_config() end)

    assert [%{name: "files"}] = McpConfig.configured()
    assert log =~ "MCP keys Fermix does not read, kept as written: [mcp.servers.files] timeout"
    assert length(String.split(log, "[mcp.servers.files] timeout")) == 2
  end

  describe "delete_mcp_server/2" do
    test "removes the server and every value it declares, and nothing else", %{path: path} do
      attrs = Map.put(@files, "env_secrets", ["GITHUB_TOKEN", "API_KEY"])
      assert :ok = ConfigStore.put_mcp_server("files", attrs, @recording)
      assert :ok = ConfigStore.put_mcp_server("notes", %{"command" => "node"}, @recording)
      assert :ok = McpSecrets.put("files", {:env, "GITHUB_TOKEN"}, "t")
      assert :ok = McpSecrets.put("files", {:env, "API_KEY"}, "k")
      assert :ok = McpSecrets.put("notes", {:env, "GITHUB_TOKEN"}, "kept")

      assert :ok = ConfigStore.delete_mcp_server("files", @recording)

      assert [%{name: "notes"}] = McpConfig.from_toml(File.read!(path))
      refute File.read!(path) =~ "[mcp.servers.files"
      assert McpSecrets.fetch("files", {:env, "GITHUB_TOKEN"}) == {:error, :missing_secret}
      assert McpSecrets.fetch("files", {:env, "API_KEY"}) == {:error, :missing_secret}
      assert McpSecrets.fetch("notes", {:env, "GITHUB_TOKEN"}) == {:ok, "kept"}
      assert [%{name: "notes"}] = McpConfig.configured()
    end

    test "a server that does not exist is refused by name" do
      assert {:error, {:invalid_params, "name", _}} =
               ConfigStore.delete_mcp_server("absent", @recording)
    end
  end

  describe "put_mcp_tool/4" do
    test "off and on write what a hand edit would hold", %{path: path} do
      assert :ok = ConfigStore.put_mcp_server("files", @files, @recording)

      assert :ok = ConfigStore.put_mcp_tool("files", "write_file", false, @recording)

      assert File.read!(path) =~
               "[mcp.servers.files.tools.write_file]\nhidden_from_agent = true\n"

      assert [%{tools_overrides: %{"write_file" => %{hidden_from_agent?: true}}}] =
               McpConfig.configured()

      assert :ok = ConfigStore.put_mcp_tool("files", "write_file", true, @recording)
      refute File.read!(path) =~ "tools.write_file"
      assert [%{tools_overrides: overrides}] = McpConfig.configured()
      assert overrides == %{}
    end

    # E2: a tool switch writes the file and applies it, and the server's own
    # program keeps running: the same client process, the same subtree.
    test "a switch leaves the server running and the tool leaves and rejoins the agent's tools" do
      start_supervised!({CapabilityRegistry, name: :config_store_mcp_write_capabilities})

      start_supervised!(
        {McpSupervisor,
         [name: TreeReloader.supervisor(), servers: []] ++ TreeReloader.collaborators()}
      )

      reload = [mcp_supervisor: TreeReloader]
      assert :ok = ConfigStore.put_mcp_server("files", @files, reload)

      both = ["mcp_files_create_issue", "mcp_files_list_issues"]
      assert await(fn -> agent_tools() == both end)
      subtree = subtree_pid()
      client = Process.whereis(:config_store_mcp_client_files)
      assert is_pid(subtree) and is_pid(client)

      assert :ok = ConfigStore.put_mcp_tool("files", "create_issue", false, reload)
      assert await(fn -> agent_tools() == ["mcp_files_list_issues"] end)
      assert subtree_pid() == subtree
      assert Process.whereis(:config_store_mcp_client_files) == client

      assert :ok = ConfigStore.put_mcp_tool("files", "create_issue", true, reload)
      assert await(fn -> agent_tools() == both end)
      assert subtree_pid() == subtree
      assert Process.whereis(:config_store_mcp_client_files) == client
    end
  end

  # Every writer of the file takes one lockfile, so a server write cannot land
  # inside a settings save from this VM or a CLI one. Held here, each writer
  # waits out its bounded acquisition and writes nothing.
  test "the MCP writers, a settings save and a port write all wait on one lock", %{
    home: home,
    path: path
  } do
    File.write!(path, ~s([fermix_core.personalization]\nuser_name = "Ada"\n))
    :ok = RestartState.record_persisted_baseline()
    {:ok, snapshot} = ConfigStore.load_runtime_config()

    writers = [
      fn -> ConfigStore.put_mcp_server("files", @files, @recording) end,
      fn -> ConfigStore.put_mcp_tool("files", "read_file", false, @recording) end,
      fn -> ConfigStore.save_snapshot(snapshot) end,
      fn -> ConfigStore.put_web_port(home, 4610) end
    ]

    results =
      Lock.with_lock(Path.join(home, "config.toml.lock"), fn ->
        writers
        |> Enum.map(&Task.async/1)
        |> Task.await_many(30_000)
      end)

    assert results == List.duplicate({:error, :lock_unavailable}, length(writers))
    assert File.read!(path) == ~s([fermix_core.personalization]\nuser_name = "Ada"\n)
  end

  defp agent_tools do
    :config_store_mcp_write_capabilities
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp subtree_pid do
    TreeReloader.supervisor()
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{:mcp_server_supervisor, {:operator, "files"}, _hash}, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end

  # A 30 s wall-clock bound: an arrival wait under a loaded suite.
  defp await(condition, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
    cond do
      condition.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> await_again(condition, deadline)
    end
  end

  defp await_again(condition, deadline) do
    # sleep: polls a registry the code under test fills asynchronously
    Process.sleep(20)
    await(condition, deadline)
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
