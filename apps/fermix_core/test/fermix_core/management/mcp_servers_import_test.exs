defmodule FermixCore.Management.McpServersImportTest do
  @moduledoc """
  `mcp.servers.import.scan` and `mcp.servers.import` (M74 E8, D3): the MCP
  servers other apps' settings hold, read from a fixture home only when asked,
  offered by name, and added through the add path with their values in the
  stub secret store. Nothing reads the real home's files or the Keychain, and
  no case starts a program: the MCP tree is `ImportTree`, whose start installs
  an owner in this case's status table and tells the test.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Management.McpServers
  alias FermixCore.Management.McpServers.ImportSources
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @status :mcp_import_test_status
  @listener :mcp_import_test_starts
  @successes Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")
  # Where the goldens say a program was found; a case's own folder stands in.
  @golden_bin "/opt/homebrew/bin"
  @secrets ~w(ghp_imported_secret fetch-imported-secret)

  defmodule ImportTree do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.RuntimeStatus

    @status :mcp_import_test_status
    @listener :mcp_import_test_starts

    def reload, do: {:ok, %{started: [], stopped: [], unchanged: [], failed: []}}

    def subtree_alive?(source_id),
      do: match?({:ok, _owner, _generation}, RuntimeStatus.owner(@status, source_id))

    def restart_server({:operator, name} = source_id, _server) do
      send(@listener, {:started, name})
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, _generation} = RuntimeStatus.register_owner(@status, source_id, owner)
      {:ok, owner}
    end
  end

  # The settings the goldens illustrate: two remote servers and three local
  # ones across five apps, VS Code's with its comments and trailing commas, a
  # placeholder, a server that cannot be added as written, a name already here,
  # and a Windsurf file a trailing comma makes unreadable, as Windsurf reads it.
  @claude_desktop ~S"""
  {"globalShortcut": "",
   "mcpServers": {
     "github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/",
                "headers": {"Authorization": "Bearer ghp_imported_secret"}},
     "filesystem": {"command": "npx",
                    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/owner/Documents"]}}}
  """
  @claude_code ~S"""
  {"numStartups": 41,
   "projects": {"/Users/owner/app": {"mcpServers": {"project-only": {"command": "sh"}}}},
   "mcpServers": {"linear": {"type": "http", "url": "https://mcp.linear.app/mcp"}}}
  """
  @cursor ~S"""
  {"mcpServers": {
     "brave-search": {"command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"],
                      "env": {"BRAVE_API_KEY": "${env:BRAVE_API_KEY}"}},
     "notes": {"command": "node", "args": ["${workspaceFolder}/index.js"]}}}
  """
  @vscode ~S"""
  {
    // the servers this editor starts
    "servers": {
      "memory": {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-memory"], /* keeps notes */
      },
    },
    "inputs": [],
  }
  """
  @windsurf ~S"""
  {"mcpServers": {"deepwiki": {"serverUrl": "https://mcp.deepwiki.com/mcp"},}}
  """
  @codex ~S"""
  model = "gpt-5"

  [mcp_servers.fetch]
  command = "uvx"
  args = ["mcp-server-fetch"]
  env = { "FETCH_TOKEN" = "fetch-imported-secret" }
  """

  setup do
    fermix_home = SafeRm.make_tmp_dir!("mcp-import-fermix")
    import_home = SafeRm.make_tmp_dir!("mcp-import-home")
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = Application.get_all_env(:fermix_core)

    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    System.put_env("FERMIX_HOME", fermix_home)

    write_config!(
      fermix_home,
      ~s([mcp.servers.linear]\ntransport = "http"\nurl = "https://mcp.linear.app/mcp"\n)
    )

    start_supervised!({RuntimeStatus, name: @status})
    Process.register(self(), @listener)

    bin = Path.join(import_home, "bin")
    File.mkdir_p!(bin)

    for program <- ~w(npx uvx) do
      File.write!(Path.join(bin, program), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, program), 0o755)
    end

    login_path = :"mcp_import_test_login_path_#{System.unique_integer([:positive])}"
    start_supervised!({LoginPath, name: login_path, read: fn -> {:ok, bin} end})

    on_exit(fn ->
      restore_core_env(previous_env)
      SecretWriterStub.reset()
      restore_home(previous_home)
      SafeRm.rm_rf!(fermix_home)
      SafeRm.rm_rf!(import_home)
      :ok = RestartState.record_persisted_baseline()
    end)

    opts = [
      mcp_supervisor: ImportTree,
      runtime_status: @status,
      login_path: login_path,
      home: "/Users/owner",
      import_home: import_home
    ]

    %{opts: opts, import_home: import_home, fermix_home: fermix_home, bin: bin}
  end

  describe "scan" do
    test "offers every server it can add, from every app, names only", ctx do
      write_sources!(ctx.import_home)

      assert {:ok, %{"candidates" => candidates, "skipped" => skipped}} =
               McpServers.import_scan(ctx.opts)

      assert Enum.map(candidates, &{&1["source"], &1["name"]}) == [
               {"claude_desktop", "github"},
               {"claude_desktop", "filesystem"},
               {"claude_code", "linear"},
               {"cursor", "brave-search"},
               {"vscode", "memory"},
               {"codex", "fetch"}
             ]

      by_name = Map.new(candidates, &{&1["name"], &1})

      assert %{"source_label" => "Claude Desktop", "secret_names" => ["Authorization"]} =
               by_name["github"]

      assert by_name["brave-search"]["secret_names"] == ["BRAVE_API_KEY"]
      assert by_name["fetch"]["secret_names"] == ["FETCH_TOKEN"]
      assert by_name["fetch"]["resolved_command"] == Path.join(ctx.bin, "uvx")
      assert {by_name["linear"]["conflict"], by_name["github"]["conflict"]} == {true, false}

      assert Enum.map(skipped, &{&1["source"], &1["name"]}) == [
               {"cursor", "notes"},
               {"windsurf", nil}
             ]

      refute_secrets(candidates)
      refute_received {:started, _name}
    end

    test "is the golden, written by the scan itself", ctx do
      write_sources!(ctx.import_home)

      assert {:ok, result} = McpServers.import_scan(ctx.opts)

      assert normalized(result, ctx.bin) == golden("mcp_servers_import_scan")
    end

    # Nothing is read before a scan asks, and nothing a scan read is kept: each
    # scan reads the files as they are then.
    test "reads the files when asked, and keeps nothing it read", ctx do
      assert McpServers.import_scan(ctx.opts) == {:ok, %{"candidates" => [], "skipped" => []}}

      write_source!(
        ctx.import_home,
        "windsurf",
        ~s({"mcpServers": {"deepwiki": {"serverUrl": "https://mcp.deepwiki.com/mcp"}}})
      )

      assert {:ok, %{"candidates" => [%{"name" => "deepwiki", "transport" => "http"}]}} =
               McpServers.import_scan(ctx.opts)

      SafeRm.rm!(Path.join(ctx.import_home, source("windsurf").path))
      assert McpServers.import_scan(ctx.opts) == {:ok, %{"candidates" => [], "skipped" => []}}
    end

    test "a huge Claude Code file still yields its servers, and one past the limit is skipped",
         ctx do
      history = String.duplicate("h", 3 * 1024 * 1024)

      write_source!(
        ctx.import_home,
        "claude_code",
        ~s({"projects": {"/x": {"history": ["#{history}"]}}, "mcpServers": {"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}}})
      )

      assert {:ok, %{"candidates" => [%{"name" => "fetch"}], "skipped" => []}} =
               McpServers.import_scan(ctx.opts)

      write_source!(
        ctx.import_home,
        "claude_code",
        String.duplicate(" ", ImportSources.max_file_bytes() + 1)
      )

      assert {:ok, %{"candidates" => [], "skipped" => [skipped]}} =
               McpServers.import_scan(ctx.opts)

      assert skipped == %{
               "source" => "claude_code",
               "source_label" => "Claude Code",
               "name" => nil,
               "sentence" => "Claude Code's settings file is larger than Fermix reads."
             }
    end

    # What the page lists is what an import adds: a server the add form would
    # refuse as written is skipped with the form's own sentence.
    test "a server the add form would refuse is skipped with its sentence", ctx do
      long = String.duplicate("a", 4_100)

      write_source!(
        ctx.import_home,
        "cursor",
        ~s({"mcpServers": {"long": {"command": "/bin/sh", "args": ["#{long}"]}}})
      )

      assert {:ok, %{"candidates" => [], "skipped" => [skipped]}} =
               McpServers.import_scan(ctx.opts)

      assert {skipped["name"], skipped["sentence"]} ==
               {"long", "This is text of at most 4096 bytes."}
    end

    test "reads at most 32 servers from one file, and says so", ctx do
      servers = Enum.map_join(1..33, ", ", &~s("s#{&1}": {"command": "/bin/sh"}))
      write_source!(ctx.import_home, "cursor", ~s({"mcpServers": {#{servers}}}))

      assert {:ok, %{"candidates" => candidates, "skipped" => [over]}} =
               McpServers.import_scan(ctx.opts)

      assert length(candidates) == 32
      assert over["sentence"] == "Fermix lists the first 32 servers in Cursor's settings."
    end
  end

  describe "import" do
    # Each server is read again, added through the add path with the values
    # its file held stored under its name, and started once; the other app's
    # file is never written.
    test "adds two servers with their values, and refuses a name already here", ctx do
      write_sources!(ctx.import_home)
      desktop_before = File.read!(Path.join(ctx.import_home, source("claude_desktop").path))

      {result, log} =
        with_log(fn ->
          McpServers.import_servers(
            [
              %{"source" => "claude_desktop", "name" => "github"},
              %{"source" => "codex", "name" => "fetch"},
              %{"source" => "claude_code", "name" => "linear"}
            ],
            ctx.opts
          )
        end)

      assert {:ok, %{"servers" => [github, fetch], "refused" => [linear]}} = result

      assert normalized(elem(result, 1), ctx.bin) == golden("mcp_servers_import")

      assert %{"origin" => "imported:claude_desktop", "auth" => %{"state" => "signed_in"}} =
               github

      assert %{
               "origin" => "imported:codex",
               "env" => [%{"name" => "FETCH_TOKEN", "present" => true}]
             } = fetch

      assert linear == %{
               "source" => "claude_code",
               "name" => "linear",
               "sentence" => "An MCP server by this name is already here. Choose another."
             }

      assert {:ok, "ghp_imported_secret"} = McpSecrets.fetch("github", {:header, "Authorization"})
      assert {:ok, "fetch-imported-secret"} = McpSecrets.fetch("fetch", {:env, "FETCH_TOKEN"})

      config = File.read!(Path.join(ctx.fermix_home, "config.toml"))
      assert config =~ ~s(origin = "imported:codex")
      refute_secrets(config)
      refute_secrets(result)
      refute_secrets(log)

      assert File.read!(Path.join(ctx.import_home, source("claude_desktop").path)) ==
               desktop_before

      assert_received {:started, "github"}
      assert_received {:started, "fetch"}
      refute_received {:started, _again}
    end

    test "a placeholder is a name that waits, and nothing starts without it", ctx do
      write_sources!(ctx.import_home)

      assert {:ok, %{"servers" => [brave], "refused" => []}} =
               McpServers.import_servers(
                 [%{"source" => "cursor", "name" => "brave-search"}],
                 ctx.opts
               )

      assert %{
               "status" => "needs_secret",
               "status_sentence" => "Waiting for BRAVE_API_KEY.",
               "origin" => "imported:cursor"
             } = brave

      assert {:error, _absent} = McpSecrets.fetch("brave-search", {:env, "BRAVE_API_KEY"})
      refute_received {:started, _name}
    end

    # The import reads the file again: what it adds is what the file holds now.
    test "reads the source again, so a server gone from it is refused and a changed value is the new one",
         ctx do
      write_sources!(ctx.import_home)
      {:ok, _scan} = McpServers.import_scan(ctx.opts)

      write_source!(
        ctx.import_home,
        "codex",
        String.replace(@codex, "fetch-imported-secret", "rotated-value")
      )

      write_source!(ctx.import_home, "claude_desktop", ~s({"mcpServers": {}}))

      assert {:ok, %{"servers" => [_fetch], "refused" => [gone, notes]}} =
               McpServers.import_servers(
                 [
                   %{"source" => "codex", "name" => "fetch"},
                   %{"source" => "claude_desktop", "name" => "github"},
                   %{"source" => "cursor", "name" => "notes"}
                 ],
                 ctx.opts
               )

      assert {:ok, "rotated-value"} = McpSecrets.fetch("fetch", {:env, "FETCH_TOKEN"})
      assert gone["sentence"] == "This server is no longer in Claude Desktop's settings."

      assert notes["sentence"] ==
               "Fermix cannot fill in ${workspaceFolder} inside the command. Put the value in a variable."
    end

    test "an unreadable source refuses each server named from it, and the rest are added", ctx do
      write_sources!(ctx.import_home)

      assert {:ok, %{"servers" => [%{"name" => "fetch"}], "refused" => [refused]}} =
               McpServers.import_servers(
                 [
                   %{"source" => "windsurf", "name" => "deepwiki"},
                   %{"source" => "codex", "name" => "fetch"}
                 ],
                 ctx.opts
               )

      assert refused == %{
               "source" => "windsurf",
               "name" => "deepwiki",
               "sentence" => "Windsurf's settings file is not valid JSON."
             }
    end

    test "a list that is not one is refused at servers, and nothing is read", ctx do
      sentence = "This is a list of at most 32 servers, each with its source and name."
      many = for n <- 1..33, do: %{"source" => "cursor", "name" => "s#{n}"}

      for servers <- [
            nil,
            [],
            many,
            [%{"source" => "zed", "name" => "a"}],
            [%{"source" => "cursor"}],
            [%{"source" => "cursor", "name" => "a", "extra" => 1}]
          ] do
        assert McpServers.import_servers(servers, ctx.opts) ==
                 {:error, {:invalid_params, "servers", sentence}},
               inspect(servers)
      end
    end

    test "a settings file changed outside Fermix refuses the whole import", ctx do
      write_sources!(ctx.import_home)

      File.write!(
        Path.join(ctx.fermix_home, "config.toml"),
        "\n[fermix_core.personalization]\nuser_name = \"Ada\"\n",
        [:append]
      )

      assert {:error, {:external_change, _sections}} =
               McpServers.import_servers([%{"source" => "codex", "name" => "fetch"}], ctx.opts)

      assert McpConfig.configured() |> Enum.map(& &1.name) == ["linear"]
      assert {:error, _absent} = McpSecrets.fetch("fetch", {:env, "FETCH_TOKEN"})
    end
  end

  defp write_sources!(home) do
    write_source!(home, "claude_desktop", @claude_desktop)
    write_source!(home, "claude_code", @claude_code)
    write_source!(home, "cursor", @cursor)
    write_source!(home, "vscode", @vscode)
    write_source!(home, "windsurf", @windsurf)
    write_source!(home, "codex", @codex)
  end

  defp write_source!(home, id, contents) do
    path = Path.join(home, source(id).path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp source(id) do
    {:ok, source} = ImportSources.fetch(id)
    source
  end

  defp write_config!(fermix_home, contents) do
    File.write!(Path.join(fermix_home, "config.toml"), contents)
    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()
  end

  # The answer as the goldens hold it: through JSON, with this case's own
  # program folder written as the goldens' one.
  defp normalized(result, bin) do
    result
    |> Jason.encode!()
    |> String.replace(bin, @golden_bin)
    |> Jason.decode!()
  end

  defp refute_secrets(term) do
    text =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    for secret <- @secrets,
        do: refute(text =~ secret, "#{secret} is in #{String.slice(text, 0, 200)}")
  end

  defp golden(name) do
    @successes
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == name))
    |> get_in(["response", "result"])
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
