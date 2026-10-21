defmodule FermixCore.Capabilities.MCP.ConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Config

  describe "from_toml/1" do
    test "parses a single MCP server with command, args, and env" do
      toml = """
      [mcp.servers.github]
      command = "npx"
      args = ["-y", "@modelcontextprotocol/server-github"]
      env = { GITHUB_TOKEN = "ghp_static" }
      """

      assert [config] = Config.from_toml(toml)
      assert config.name == "github"
      assert config.command == "npx"
      assert config.args == ["-y", "@modelcontextprotocol/server-github"]
      assert config.env == %{"GITHUB_TOKEN" => "ghp_static"}
      assert config.pass_env == []
      assert config.tools_overrides == %{}
    end

    test "parses pass_env for Sandbox.Env-backed passthrough" do
      toml = """
      [mcp.servers.github]
      command = "npx"
      pass_env = ["GITHUB_TOKEN"]
      """

      assert [config] = Config.from_toml(toml)
      assert config.pass_env == ["GITHUB_TOKEN"]
    end

    test "raises on removed $env shorthand" do
      toml = """
      [mcp.servers.github]
      env = { GITHUB_TOKEN = "$env:GITHUB_TOKEN" }
      """

      assert_raise ArgumentError, ~r/removed \$env: shorthand/, fn ->
        Config.from_toml(toml)
      end
    end

    test "raises when pass_env and literal env declare the same name" do
      toml = """
      [mcp.servers.github]
      env = { GITHUB_TOKEN = "literal" }
      pass_env = ["GITHUB_TOKEN"]
      """

      assert_raise ArgumentError, ~r/GITHUB_TOKEN/, fn ->
        Config.from_toml(toml)
      end
    end

    test "parses multiple servers, sorted by name" do
      toml = """
      [mcp.servers.zulu]
      command = "z"

      [mcp.servers.alpha]
      command = "a"
      """

      assert [%{name: "alpha"}, %{name: "zulu"}] = Config.from_toml(toml)
    end

    test "parses [mcp.servers.<name>.tools.<tool>] override blocks" do
      toml = """
      [mcp.servers.filesystem]
      command = "npx"

      [mcp.servers.filesystem.tools.read_file]
      policy_class = "read_only"
      hidden_from_agent = true
      """

      assert [config] = Config.from_toml(toml)

      assert config.tools_overrides == %{
               "read_file" => %{policy_class: :read_only, hidden_from_agent?: true}
             }
    end

    test "raises when a server block carries the removed `approved` key" do
      toml = """
      [mcp.servers.filesystem]
      command = "npx"
      approved = true
      """

      assert_raise ArgumentError, ~r/approved was removed/, fn ->
        Config.from_toml(toml)
      end
    end

    test "raises when a per-tool block uses the renamed `requires_approval` key" do
      toml = """
      [mcp.servers.filesystem]
      command = "npx"

      [mcp.servers.filesystem.tools.read_file]
      requires_approval = true
      """

      assert_raise ArgumentError, ~r/requires_approval was renamed/, fn ->
        Config.from_toml(toml)
      end
    end

    test "raises on an unknown [mcp.*] section header" do
      toml = """
      [mcp.broken]
      command = "x"
      """

      assert_raise ArgumentError, ~r/Unknown MCP section header/, fn ->
        Config.from_toml(toml)
      end
    end

    test "skips the retired [mcp.inbound] sections instead of refusing the file" do
      toml = """
      [mcp.inbound]
      enabled = true

      [mcp.inbound.http]
      auth_token = "$env:FERMIX_TOKEN"

      [mcp.inbound.tools.shell]
      exposed = true
      """

      assert Config.from_toml(toml) == []
      assert Config.document(toml) == %{}

      assert Config.retired_sections(toml) ==
               ["[mcp.inbound]", "[mcp.inbound.http]", "[mcp.inbound.tools.shell]"]
    end

    test "names no retired section in a file without one" do
      toml = """
      [mcp.servers.github]
      command = "npx"
      """

      assert Config.retired_sections(toml) == []
    end

    test "raises on an invalid policy_class string" do
      toml = """
      [mcp.servers.x.tools.t]
      policy_class = "destroy"
      """

      assert_raise ArgumentError, ~r/Invalid policy_class/, fn ->
        Config.from_toml(toml)
      end
    end

    test "ignores blank lines and comments" do
      toml = """
      # leading comment
      [mcp.servers.github]
      # inline comment between keys
      command = "npx"

      args = []
      """

      assert [config] = Config.from_toml(toml)
      assert config.command == "npx"
      assert config.args == []
    end
  end

  # M74 §4: the keys an operator server is defined by, read for the transport
  # the block names, stdio when it names none.
  describe "the server object" do
    test "a block with no transport is an enabled stdio server, as every hand-written one is" do
      toml = """
      [mcp.servers.files]
      command = "/opt/homebrew/bin/npx"
      args = ["-y", "@modelcontextprotocol/server-filesystem"]
      cwd = "/Users/owner/Work Folder"
      env_secrets = ["GITHUB_TOKEN", "API_KEY"]
      origin = "added"
      """

      assert [server] = Config.from_toml(toml)
      assert server.transport == :stdio
      assert server.enabled? == true
      assert server.cwd == "/Users/owner/Work Folder"
      assert server.env_secrets == ["GITHUB_TOKEN", "API_KEY"]
      assert server.origin == "added"
      assert Config.startable?(server)
    end

    test "an http server reads its URL, auth, headers and sign-in client" do
      toml = """
      [mcp.servers.linear]
      transport = "http"
      url = "https://mcp.linear.app/mcp"
      auth = "header"
      header_secrets = ["Authorization", "X-Workspace"]
      key_header = "Authorization"
      oauth_client_id = "fermix-client"
      enabled = false
      """

      assert [server] = Config.from_toml(toml)
      assert server.transport == :http
      assert server.url == "https://mcp.linear.app/mcp"
      assert server.auth == :header
      assert server.header_secrets == ["Authorization", "X-Workspace"]
      assert server.key_header == "Authorization"
      assert server.oauth_client_id == "fermix-client"
      assert server.enabled? == false
      refute Map.has_key?(server, :command)
    end

    # A block that names nothing to start, which only a hand edit writes, is
    # not started either: there is no program and no address.
    test "a server without its command or URL is not started" do
      toml = """
      [mcp.servers.local]
      env_secrets = ["TOKEN"]

      [mcp.servers.remote]
      transport = "http"

      [mcp.servers.blank]
      command = ""
      """

      assert [blank, local, remote] = Config.from_toml(toml)
      refute Config.startable?(blank)
      refute Config.startable?(local)
      refute Config.startable?(remote)
    end

    test "an enabled server is started, stdio or http; a disabled one of either is not" do
      toml = """
      [mcp.servers.off]
      command = "npx"
      enabled = false

      [mcp.servers.on]
      command = "npx"

      [mcp.servers.remote]
      transport = "http"
      url = "https://mcp.example.com/mcp"

      [mcp.servers.remote_off]
      transport = "http"
      url = "https://mcp.example.com/mcp"
      enabled = false
      """

      assert [
               %{name: "off"} = off,
               %{name: "on"} = on,
               %{name: "remote"} = remote,
               %{name: "remote_off"} = remote_off
             ] = Config.from_toml(toml)

      refute Config.startable?(off)
      assert Config.startable?(on)
      assert Config.startable?(remote)
      refute Config.startable?(remote_off)
    end

    test "an auth mode outside auto, header and none is refused by key" do
      assert_raise ArgumentError, ~r/\[mcp\.servers\.remote\] auth is/, fn ->
        Config.from_toml(~s([mcp.servers.remote]\ntransport = "http"\nauth = "basic"\n))
      end
    end

    test "a transport other than stdio or http is refused" do
      assert_raise ArgumentError, ~r/transport is "stdio" or "http"/, fn ->
        Config.from_toml("[mcp.servers.old]\ntransport = \"sse\"\n")
      end
    end

    test "a key header is named only with auth = header, and is one of the headers" do
      base = ~s([mcp.servers.remote]\ntransport = "http"\nurl = "https://h.example/mcp"\n)

      assert_raise ArgumentError, ~r/names the header it goes in/, fn ->
        Config.from_toml(base <> "auth = \"header\"\n")
      end

      assert_raise ArgumentError, ~r/one of the server's headers/, fn ->
        Config.from_toml(base <> ~s(auth = "header"\nkey_header = "X-Key"\n))
      end

      assert_raise ArgumentError, ~r/Only a server that sends a key/, fn ->
        Config.from_toml(base <> ~s(header_secrets = ["X-Key"]\nkey_header = "X-Key"\n))
      end
    end

    # Authorization is where the key goes and where a sign-in's token will go,
    # so only a server that sends its key there declares it.
    test "Authorization is declared only as a header server's key, read or written" do
      base = ~s([mcp.servers.r]\ntransport = "http"\nurl = "https://mcp.example.com/mcp"\n)

      for extra <- [
            ~s(header_secrets = ["Authorization"]\n),
            ~s(auth = "none"\nheader_secrets = ["authorization"]\n),
            ~s(auth = "header"\nheader_secrets = ["Authorization", "X-Key"]\nkey_header = "X-Key"\n)
          ] do
        assert_raise ArgumentError,
                     ~r/The Authorization header holds only the server's key/,
                     fn ->
                       Config.from_toml(base <> extra)
                     end
      end

      assert [%{header_secrets: ["Authorization", "X-Org"], key_header: "Authorization"}] =
               Config.from_toml(
                 base <>
                   ~s(auth = "header"\nheader_secrets = ["Authorization", "X-Org"]\n) <>
                   ~s(key_header = "Authorization"\n)
               )

      attrs = %{
        "transport" => "http",
        "url" => "https://mcp.example.com/mcp",
        "auth" => "auto",
        "header_secrets" => ["Authorization"]
      }

      assert {:error, {:invalid_params, "header_secrets", sentence}} =
               Config.add_server(%{}, "remote", attrs, [])

      assert sentence ==
               "The Authorization header holds only the server's key. " <>
                 "Choose to send a key in that header."

      keyed = %{attrs | "auth" => "header"} |> Map.put("key_header", "Authorization")
      assert {:ok, _document} = Config.add_server(%{}, "remote", keyed, [])
    end

    test "secret names follow their grammar and are declared once" do
      assert_raise ArgumentError, ~r/A variable name is letters/, fn ->
        Config.from_toml("[mcp.servers.files]\nenv_secrets = [\"1BAD\"]\n")
      end

      assert_raise ArgumentError, ~r/A header name is letters/, fn ->
        Config.from_toml(
          ~s([mcp.servers.r]\ntransport = "http"\nheader_secrets = ["Bad Header"]\n)
        )
      end

      assert_raise ArgumentError, ~r/Each header is named once/, fn ->
        Config.from_toml(
          ~s([mcp.servers.r]\ntransport = "http"\nheader_secrets = ["X-Key", "x-key"]\n)
        )
      end
    end

    test "a variable declared as a secret and as a literal or passthrough is refused" do
      assert_raise ArgumentError,
                   ~r/The settings file already gives TOKEN a value, so Fermix cannot also/,
                   fn ->
                     Config.from_toml("""
                     [mcp.servers.files]
                     env = { TOKEN = "literal" }
                     env_secrets = ["TOKEN"]
                     """)
                   end

      assert_raise ArgumentError, ~r/declares TOKEN in both env and pass_env/, fn ->
        Config.from_toml("""
        [mcp.servers.files]
        env = { TOKEN = "literal" }
        pass_env = ["TOKEN"]
        """)
      end
    end
  end

  # A hand-written file must never stop the daemon over a name: the rules §4
  # adds (the pattern, at most 32 servers, one tool prefix per name) are named
  # at load and enforced only when a server is added. Only a dot, which the
  # reader has always refused, still refuses the file.
  describe "names at load" do
    test "a name outside the pattern loads, and is named with the rule it breaks" do
      long = String.duplicate("a", 40)

      toml = """
      [mcp.servers.GitHub]
      command = "npx"

      [mcp.servers.#{long}]
      command = "uvx"

      [mcp.servers.files]
      command = "node"
      """

      servers = Config.from_toml(toml)
      assert Enum.map(servers, & &1.name) == ["GitHub", long, "files"]
      assert Enum.all?(servers, &Config.startable?/1)

      assert Config.rule_breaks(servers) == [
               "[mcp.servers.GitHub] and [mcp.servers.#{long}]: a server name is lowercase " <>
                 "letters, digits, - and _, starts with a letter, and is at most 32 characters"
             ]
    end

    test "a dot in a name still refuses the file, as it always has" do
      assert_raise ArgumentError, ~r/Unknown MCP section header/, fn ->
        Config.from_toml("[mcp.servers.files.local]\ncommand = \"npx\"\n")
      end
    end

    test "two names that give their tools one prefix both load, and are named" do
      toml = """
      [mcp.servers.foo-bar]
      command = "a"

      [mcp.servers.foo_bar]
      command = "b"
      """

      servers = Config.from_toml(toml)
      assert [%{name: "foo-bar"}, %{name: "foo_bar"}] = servers

      assert Config.rule_breaks(servers) == [
               "[mcp.servers.foo-bar] and [mcp.servers.foo_bar]: their tools share the " <>
                 "names mcp_foo_bar_…"
             ]
    end

    test "more than 32 servers all load, and the count is named" do
      toml =
        Enum.map_join(1..33, "\n", fn n -> "[mcp.servers.s#{n}]\ncommand = \"npx\"\n" end)

      servers = Config.from_toml(toml)
      assert length(servers) == 33
      assert Config.rule_breaks(servers) == ["33 servers: Fermix holds at most 32"]
    end

    test "a file within the rules breaks none" do
      toml = "[mcp.servers.files]\ncommand = \"npx\"\n\n[mcp.servers.notes]\ncommand = \"node\"\n"
      assert Config.rule_breaks(Config.from_toml(toml)) == []
    end
  end

  # E2: a key the reader does not read is the owner's; it is named, never
  # refused, so a hand-written `timeout` or `headers` cannot stop the daemon.
  describe "unread keys" do
    test "keys outside §4 and the other transport's keys are named, and the file still reads" do
      toml = """
      [mcp.servers.files]
      command = "npx"
      timeout = 30
      url = "https://not.read.example"

      [mcp.servers.files.tools.read]
      hidden_from_agent = true
      note = "kept"

      [mcp.servers.remote]
      transport = "http"
      url = "https://mcp.example.com/mcp"
      headers = { X = "y" }
      command = "npx"
      """

      assert [%{name: "files"}, %{name: "remote"}] = Config.from_toml(toml)

      assert Config.unread_keys(toml) == [
               "[mcp.servers.files] timeout",
               "[mcp.servers.files] url",
               "[mcp.servers.files.tools.read] note",
               "[mcp.servers.remote] command",
               "[mcp.servers.remote] headers"
             ]
    end

    test "a file holding only §4 keys has none" do
      toml = """
      [mcp.servers.files]
      transport = "stdio"
      command = "npx"
      enabled = true
      origin = "added"

      [mcp.servers.files.tools.read]
      hidden_from_agent = true
      policy_class = "read_only"
      """

      assert Config.unread_keys(toml) == []
    end
  end

  describe "add_server/4 and put_server/3" do
    @stdio %{"command" => "/opt/homebrew/bin/npx", "args" => ["-y", "pkg"], "origin" => "added"}

    test "a new server takes its keys as its block" do
      assert {:ok, document} = Config.add_server(%{}, "files", @stdio, [])
      assert document == %{"files" => %{server: @stdio}}
    end

    # The check of a new name is the edit of the document it is written into,
    # so an add never merges into a server of the same name.
    test "an add refuses a name the file holds, and a change one it does not" do
      document = %{"files" => %{server: %{"command" => "npx"}}}

      assert Config.add_server(document, "files", @stdio, []) ==
               {:error,
                {:invalid_params, "name",
                 "An MCP server by this name is already here. Choose another."}}

      assert Config.put_server(%{}, "files", %{"enabled" => false}) ==
               {:error, {:invalid_params, "name", "There is no MCP server by that name."}}
    end

    test "an edit merges over the block, nil removes a key, and hand-written keys are carried" do
      document = %{
        "files" => %{
          server: %{"command" => "npx", "env" => %{"LEVEL" => "debug"}, "timeout" => 30},
          tools: %{"read" => %{"hidden_from_agent" => true}}
        }
      }

      assert {:ok, edited} =
               Config.put_server(document, "files", %{"enabled" => false, "cwd" => nil})

      assert edited["files"].server ==
               %{
                 "command" => "npx",
                 "env" => %{"LEVEL" => "debug"},
                 "timeout" => 30,
                 "enabled" => false
               }

      assert edited["files"].tools == document["files"].tools
    end

    test "refuses by field what the reader's dialect cannot hold" do
      for {attrs, field} <- [
            {%{@stdio | "command" => "npx\n[fermix_core]"}, "command"},
            {Map.put(@stdio, "cwd", "\"/Users/owner\""), "cwd"},
            {Map.put(@stdio, "cwd", "/Users/owner/say \"hi\""), "cwd"},
            {Map.put(@stdio, "env", %{"A" => "x,y"}), "env"},
            {Map.put(@stdio, "pass_env", ["A"]), "pass_env"},
            {Map.put(@stdio, "timeout", 30), "timeout"},
            {%{@stdio | "args" => ["-y", 3]}, "args"}
          ] do
        assert {:error, {:invalid_params, ^field, sentence}} =
                 Config.add_server(%{}, "files", attrs, [])

        assert is_binary(sentence) and sentence != ""
      end
    end

    test "refuses a name, a missing command or URL, and a changed transport" do
      assert {:error, {:invalid_params, "name", _}} = Config.add_server(%{}, "Files", @stdio, [])

      assert {:error, {:invalid_params, "command", _}} =
               Config.add_server(%{}, "files", Map.delete(@stdio, "command"), [])

      assert {:error, {:invalid_params, "url", _}} =
               Config.add_server(%{}, "remote", %{"transport" => "http"}, [])

      {:ok, document} = Config.add_server(%{}, "files", @stdio, [])

      assert {:error, {:invalid_params, "command", _}} =
               Config.put_server(document, "files", %{"command" => nil})

      assert {:error, {:invalid_params, "transport", _}} =
               Config.put_server(document, "files", %{
                 "transport" => "http",
                 "url" => "https://x.example/mcp"
               })
    end

    test "a new name may not share a tool prefix with a server or a plugin, or be the 33rd" do
      {:ok, document} = Config.add_server(%{}, "foo-bar", @stdio, [])

      assert {:error, {:invalid_params, "name", _}} =
               Config.add_server(document, "foo_bar", @stdio, [])

      assert {:error,
              {:invalid_params, "name", "A plugin already uses this name. Choose another."}} =
               Config.add_server(%{}, "gmail", @stdio, ["gmail"])

      full = Map.new(1..32, fn n -> {"s#{n}", %{server: @stdio}} end)

      assert {:error, {:invalid_params, "name", _}} =
               Config.add_server(full, "one-more", @stdio, [])

      assert {:ok, _} = Config.put_server(full, "s1", %{"enabled" => false})
    end
  end

  # The owner must be able to manage and remove what a file already holds, so
  # the name rules bind only a new name.
  describe "a server named before the rules" do
    @legacy %{"GitHub" => %{server: %{"command" => "npx", "env_secrets" => ["TOKEN"]}}}

    test "can be updated, switched and removed" do
      assert {:ok, updated} = Config.put_server(@legacy, "GitHub", %{"enabled" => false})
      assert updated["GitHub"].server["enabled"] == false

      assert {:ok, switched} = Config.put_tool(@legacy, "GitHub", "create_issue", false)
      assert switched["GitHub"].tools == %{"create_issue" => %{"hidden_from_agent" => true}}

      assert {:ok, %{}, %{name: "GitHub"}} = Config.delete_server(@legacy, "GitHub")
    end

    test "is not a name a new server may take" do
      assert {:error, {:invalid_params, "name", _}} =
               Config.add_server(@legacy, "GitLab", %{"command" => "npx"}, [])

      assert {:error, {:invalid_params, "name", _}} =
               Config.add_server(@legacy, "github", %{"command" => "npx"}, [])
    end
  end

  describe "put_tool/4 and delete_server/2" do
    @document %{"files" => %{server: %{"command" => "npx"}}}

    test "off writes hidden_from_agent, on removes it and the block it leaves empty" do
      assert {:ok, off} = Config.put_tool(@document, "files", "read_file", false)
      assert off["files"].tools == %{"read_file" => %{"hidden_from_agent" => true}}

      assert {:ok, on} = Config.put_tool(off, "files", "read_file", true)
      assert on == @document

      kept = put_in(off, ["files", :tools, "read_file", "policy_class"], "read_only")
      assert {:ok, on} = Config.put_tool(kept, "files", "read_file", true)
      assert on["files"].tools == %{"read_file" => %{"policy_class" => "read_only"}}
    end

    test "a tool the dialect cannot name, and a server that does not exist, are refused" do
      for tool <- ["files.read", " read", "read]", "a\nb", ""] do
        assert {:error, {:invalid_params, "tool", _}} =
                 Config.put_tool(@document, "files", tool, false)
      end

      assert {:error, {:invalid_params, "name", _}} =
               Config.put_tool(@document, "absent", "read", false)
    end

    test "delete answers the server it removed, for its declared values" do
      document = put_in(@document, ["files", :server, "env_secrets"], ["TOKEN"])

      assert {:ok, %{}, %{name: "files", env_secrets: ["TOKEN"]}} =
               Config.delete_server(document, "files")

      assert {:error, {:invalid_params, "name", _}} = Config.delete_server(%{}, "files")
    end
  end
end
