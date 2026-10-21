defmodule FermixCore.Management.McpServers.InterchangeTest do
  @moduledoc """
  The one translator from what an owner pastes into MCP servers (M74 §3, E8):
  every shape it reads, the values it carries and the names it gives, and
  every refusal. Every input is a string here; nothing reads a file.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.McpServers.CommandLine
  alias FermixCore.Management.McpServers.Interchange
  alias FermixCore.Management.McpServers.Row

  @home "/Users/owner"
  @paste_sentence "Paste a server's address, the command that starts it, or the settings " <>
                    "a README or another app gives for it."

  defp translate(text), do: Interchange.translate(text, @home)

  defp one(text) do
    assert {:ok, [server]} = translate(text)
    server
  end

  defp refusal(text) do
    assert {:error, {:invalid_params, "text", sentence}} = translate(text)
    sentence
  end

  defp values(server), do: server.values.values

  describe "a URL" do
    test "is one remote server that signs in by itself, named by its host" do
      server = one("https://mcp.linear.app/mcp\n")

      assert server.name == "linear"

      assert server.attrs == %{
               "transport" => "http",
               "url" => "https://mcp.linear.app/mcp",
               "auth" => "auto"
             }

      assert %{transport: :http, auth: :auto, header_secrets: []} = server.server
      assert values(server) == %{}
    end

    test "may be http only to this Mac" do
      assert one("http://localhost:3000/mcp").name == "localhost"
      assert refusal("http://example.com/mcp") == Row.url_sentence()
    end
  end

  describe "a command line" do
    test "is one local server, split as the add form splits it" do
      server = one("npx -y @modelcontextprotocol/server-filesystem ~/Documents 'my notes'")

      assert server.name == "filesystem"

      assert server.attrs == %{
               "command" => "npx",
               "args" => [
                 "-y",
                 "@modelcontextprotocol/server-filesystem",
                 "/Users/owner/Documents",
                 "my notes"
               ]
             }

      assert values(server) == %{}
    end

    test "a line a shell would join is one line" do
      assert one("npx -y \\\n  @upstash/context7-mcp").attrs["args"] == [
               "-y",
               "@upstash/context7-mcp"
             ]
    end

    test "is refused where the add form refuses it" do
      line = "npx server | tee log"
      {:error, {:invalid_params, "command_line", sentence}} = CommandLine.split(line, @home)

      assert refusal(line) == sentence
      assert refusal("npx '~bob/x") == "A quotation mark is not closed."
    end
  end

  describe "names" do
    # The plan's examples, and the rules each one follows.
    test "a URL is named by its host, a command by its package" do
      names = %{
        "https://mcp.linear.app/mcp" => "linear",
        "https://mcp.sentry.dev/mcp" => "sentry",
        "https://api.githubcopilot.com/mcp/" => "githubcopilot",
        "https://mcp.context7.com/mcp" => "context7",
        "https://mcp.example.co.uk/mcp" => "example",
        "https://eu.mcp.sentry.io/mcp" => "sentry",
        "https://remote.mcp.example.com.au/sse" => "example",
        "http://localhost:3000/mcp" => "localhost",
        "http://127.0.0.1:8080/mcp" => "server",
        "npx -y @modelcontextprotocol/server-filesystem" => "filesystem",
        "uvx mcp-server-fetch" => "fetch",
        "npx -y @brave/brave-search-mcp-server" => "brave-search",
        "npx -y @upstash/context7-mcp@latest" => "context7",
        "npx @playwright/mcp@latest" => "playwright",
        "bunx some-tool-server" => "some-tool",
        "pipx run mcp-server-time --local-timezone UTC" => "time",
        "/opt/tools/Notes_Server --port 3" => "notes_server",
        "node build/index.js" => "node"
      }

      for {text, name} <- names, do: assert(one(text).name == name, text)
    end

    test "a source's own name is kept where a new server may take it, and derived where not" do
      text = ~s({"mcpServers": {"my_files": {"command": "npx", "args": ["-y", "@x/files-mcp"]},
                 "Linear Server": {"serverUrl": "https://mcp.linear.app/sse"}}})

      assert {:ok, [files, linear]} = translate(text)
      assert {files.name, linear.name} == {"my_files", "linear"}
    end
  end

  describe "JSON" do
    test "an mcpServers map keeps its order, and a value the text gives is carried" do
      text = ~S"""
      {
        "mcpServers": {
          "sentry": {"type": "http", "url": "https://mcp.sentry.dev/mcp"},
          "brave-search": {
            "command": "npx",
            "args": ["-y", "@brave/brave-search-mcp-server"],
            "env": {"BRAVE_API_KEY": "bsa-123", "LOG_LEVEL": "debug", "PORT": 8080}
          }
        },
        "globalShortcut": ""
      }
      """

      assert {:ok, [sentry, brave]} = translate(text)
      assert {sentry.name, sentry.attrs["auth"]} == {"sentry", "auto"}
      assert brave.attrs["env_secrets"] == ["BRAVE_API_KEY", "LOG_LEVEL", "PORT"]

      assert values(brave) == %{
               {:env, "BRAVE_API_KEY"} => "bsa-123",
               {:env, "LOG_LEVEL"} => "debug",
               {:env, "PORT"} => "8080"
             }
    end

    test "a servers map, a bare map and one server object" do
      vscode =
        ~s({"servers": {"fetch": {"type": "stdio", "command": "uvx", "args": ["mcp-server-fetch"]}}, "inputs": []})

      bare = ~s({"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}})
      object = ~s({"command": "uvx", "args": ["mcp-server-fetch"], "cwd": "~/code"})

      for text <- [vscode, bare, object] do
        assert %{name: "fetch", attrs: %{"command" => "uvx", "args" => ["mcp-server-fetch"]}} =
                 one(text)
      end

      assert one(object).attrs["cwd"] == "/Users/owner/code"
    end

    test "every transport the shapes name" do
      for {type, url} <- [
            {"http", "https://a.dev/mcp"},
            {"streamable-http", "https://a.dev/mcp"},
            {"sse", "https://a.dev/sse"}
          ] do
        server = one(~s({"a": {"type": "#{type}", "url": "#{url}"}}))
        assert {server.server.transport, server.attrs["url"]} == {:http, url}
      end

      assert one(~s({"a": {"transport": "stdio", "command": "sh"}})).server.transport == :stdio

      assert refusal(~s({"a": {"type": "websocket", "url": "wss://a.dev"}})) ==
               "Fermix does not know the transport websocket."
    end

    test "a placeholder declares a name and carries no value" do
      text = ~S"""
      {"servers": {"github": {
        "type": "http",
        "url": "https://api.githubcopilot.com/mcp/",
        "headers": {"Authorization": "Bearer ${input:github_token}", "X-Org": "${env:ORG}",
                    "X-Team": "${TEAM}", "X-Region": "${REGION:-us}", "X-Empty": ""}
      }}}
      """

      server = one(text)

      assert server.attrs["header_secrets"] == ~w(Authorization X-Org X-Team X-Region X-Empty)
      assert {server.attrs["auth"], server.attrs["key_header"]} == {"header", "Authorization"}
      assert values(server) == %{}
    end

    test "unreadable JSON and JSON that is no server" do
      assert refusal(~s({"mcpServers": {)) == "Fermix cannot read this JSON."
      assert refusal(~s({"theme": "dark"})) == @paste_sentence
      assert refusal(~s({"mcpServers": {}})) == @paste_sentence

      assert refusal(~s({"mcpServers": {"a": {"type": "stdio"}}})) ==
               "This server has no command."

      assert refusal(~s({"mcpServers": {"a": {"type": "http"}}})) == "This server has no address."

      assert refusal(~s({"a": {"command": "sh", "args": [{"x": 1}]}})) ==
               "Fermix cannot read this server."
    end
  end

  describe "headers and keys" do
    test "a bearer token in Authorization is the key, stored without its scheme" do
      server =
        one(
          ~s({"a": {"url": "https://a.dev/mcp", "headers": {"X-Org": "acme", "Authorization": "Bearer tok-1"}}})
        )

      assert {server.attrs["auth"], server.attrs["key_header"]} == {"header", "Authorization"}
      assert server.attrs["header_secrets"] == ["X-Org", "Authorization"]

      assert values(server) == %{
               {:header, "X-Org"} => "acme",
               {:header, "Authorization"} => "tok-1"
             }
    end

    test "without Authorization, the first header is the key" do
      server =
        one(
          ~s({"a": {"url": "https://a.dev/mcp", "headers": {"X-Api-Key": "k-1", "X-Org": "acme"}}})
        )

      assert {server.attrs["auth"], server.attrs["key_header"]} == {"header", "X-Api-Key"}
      assert server.attrs["header_secrets"] == ["X-Api-Key", "X-Org"]
    end

    test "an Authorization header with another scheme cannot be sent" do
      assert refusal(
               ~s({"a": {"url": "https://a.dev/mcp", "headers": {"Authorization": "Basic YTpi"}}})
             ) ==
               "Fermix sends an authorization header only with a bearer token, " <>
                 "and this one holds another kind of key."
    end

    test "a value the secret store cannot hold refuses the paste" do
      long = String.duplicate("k", 8_193)

      assert refusal(~s({"a": {"command": "sh", "env": {"KEY": "#{long}"}}})) ==
               "A value in this paste is longer than 8192 bytes."

      assert refusal(~s({"a": {"command": "sh", "env": {"KEY": "one\\ntwo"}}})) ==
               "A value in this paste is more than one line."
    end

    test "a name the server could not declare refuses the paste" do
      assert refusal(~s({"a": {"command": "sh", "env": {"MY-VAR": "x"}}})) =~ "A variable name is"

      assert refusal(~s({"a": {"url": "https://a.dev/mcp", "headers": {"X Key": "x"}}})) =~
               "A header name is"
    end
  end

  describe "a claude mcp add line" do
    test "a remote server with a header after its URL" do
      server =
        one(
          ~s(claude mcp add --transport http context7 https://mcp.context7.com/mcp --header "CONTEXT7_API_KEY: ctx7sk-1")
        )

      assert server.name == "context7"

      assert server.attrs == %{
               "transport" => "http",
               "url" => "https://mcp.context7.com/mcp",
               "auth" => "header",
               "key_header" => "CONTEXT7_API_KEY",
               "header_secrets" => ["CONTEXT7_API_KEY"]
             }

      assert values(server) == %{{:header, "CONTEXT7_API_KEY"} => "ctx7sk-1"}
    end

    test "a bearer header, an sse transport and a URL without --transport" do
      github =
        one(
          ~s(claude mcp add -t http -s user github https://api.githubcopilot.com/mcp -H "Authorization: Bearer ghp_1")
        )

      assert values(github) == %{{:header, "Authorization"} => "ghp_1"}

      assert one("claude mcp add --transport sse asana https://mcp.asana.com/sse").attrs["url"] ==
               "https://mcp.asana.com/sse"

      assert one("claude mcp add --transport=http notion https://mcp.notion.com/mcp").name ==
               "notion"

      assert one("claude mcp add linear https://mcp.linear.app/mcp").server.transport == :http
    end

    test "a local server after --, with its variables" do
      server =
        one(
          "claude mcp add --env AIRTABLE_API_KEY=pat-1 -e LEVEL= airtable -- npx -y airtable-mcp-server"
        )

      assert server.attrs == %{
               "command" => "npx",
               "args" => ["-y", "airtable-mcp-server"],
               "env_secrets" => ["AIRTABLE_API_KEY", "LEVEL"]
             }

      assert values(server) == %{{:env, "AIRTABLE_API_KEY"} => "pat-1"}
      assert one("claude mcp add notes node index.js").attrs["args"] == ["index.js"]
    end

    test "an add-json line is one server object under its name" do
      server =
        one(
          ~s(claude mcp add-json weather '{"type":"stdio","command":"weather-cli","env":{"CACHE_DIR":"/tmp"}}')
        )

      assert {server.name, server.attrs["command"]} == {"weather", "weather-cli"}
      assert values(server) == %{{:env, "CACHE_DIR"} => "/tmp"}
    end

    # README lines are written for a shell: a value it would fill in from a
    # variable is a placeholder, so the server waits for it.
    test "a value from a shell variable is a name with no value" do
      github =
        one(
          ~s(claude mcp add --transport http github https://api.githubcopilot.com/mcp ) <>
            ~s(-H "Authorization: Bearer $GITHUB_PAT" -H 'X-Toolsets: $TOOLSETS')
        )

      assert {github.attrs["key_header"], github.attrs["header_secrets"]} ==
               {"Authorization", ["Authorization", "X-Toolsets"]}

      assert values(github) == %{}

      files =
        one(
          ~s|claude mcp add -e API_KEY=$API_KEY -e "TOKEN=${TOKEN}" -e "SECRET=$(pass api)" | <>
            ~s(-e LEVEL=debug ) <>
            ~s(-e 'PASS=pa$$1' files -- npx -y files-mcp '$literal')
        )

      assert files.attrs["env_secrets"] == ~w(API_KEY TOKEN SECRET LEVEL PASS)
      assert files.attrs["args"] == ["-y", "files-mcp", "$literal"]
      assert values(files) == %{{:env, "LEVEL"} => "debug", {:env, "PASS"} => "pa$$1"}
    end

    test "add-json takes a shell variable in a value as a placeholder too" do
      single =
        ~s(claude mcp add-json gh '{"url": "https://a.dev/mcp", "headers": {"Authorization": "Bearer $PAT"}}')

      double =
        ~S(claude mcp add-json gh "{\"url\": \"https://a.dev/mcp\", \"headers\": {\"X-Key\": \"k-$SUFFIX\"}}")

      assert values(one(single)) == %{}
      assert one(single).attrs["key_header"] == "Authorization"
      assert values(one(double)) == %{}
      assert one(double).attrs["header_secrets"] == ["X-Key"]
    end

    # Anywhere else a shell's variable would change what runs or where.
    test "a shell variable in the name, the address or the command is refused" do
      lines = [
        "claude mcp add files -- npx -y files-mcp $HOME/notes",
        ~s(claude mcp add files -- sh "$SCRIPT"),
        "claude mcp add notes node $ENTRY",
        "claude mcp add $NAME https://a.dev/mcp",
        "claude mcp add a https://a.dev/$TEAM/mcp",
        "claude mcp add --transport $T a https://a.dev/mcp",
        ~s(claude mcp add-json $NAME '{"command": "sh"}')
      ]

      for line <- lines, do: assert(refusal(line) == CommandLine.shell_sentence(), line)
    end

    test "what it cannot read" do
      assert refusal("claude mcp add --client-id abc linear https://mcp.linear.app/mcp") ==
               "Fermix does not know the option --client-id."

      assert refusal("claude mcp add --transport ws a wss://a.dev") ==
               "Fermix does not know the transport ws."

      assert refusal("claude mcp add linear") ==
               "This line needs the server's name and its address or command."

      assert refusal("claude mcp add -e TOKEN a -- sh") ==
               "Fermix cannot read the variable TOKEN."

      assert refusal("claude mcp add a https://a.dev/mcp -H Bad") ==
               "Fermix cannot read the header Bad."

      assert refusal("claude mcp add a https://a.dev/mcp --header") ==
               "The option --header needs a value."

      assert refusal(~s(claude mcp add-json -e K=v a '{"command": "sh"}')) ==
               "Fermix does not know the option -e."
    end
  end

  describe "a Codex block" do
    test "every table is a server, by name, with its values and its key" do
      text = ~S"""
      model = "gpt-5"

      [mcp_servers.figma]
      url = "https://mcp.figma.com/mcp"
      bearer_token_env_var = "FIGMA_OAUTH_TOKEN"
      http_headers = { "X-Region" = "us-east-1" }
      env_http_headers = { "X-Org" = "FIGMA_ORG" }

      [mcp_servers.context7]
      command = "npx"
      args = ["-y", "@upstash/context7-mcp"]
      cwd = "/tmp"
      env = { "CONTEXT7_API_KEY" = "ctx7sk-1" }
      """

      assert {:ok, [context7, figma]} = translate(text)

      assert context7.attrs == %{
               "command" => "npx",
               "args" => ["-y", "@upstash/context7-mcp"],
               "cwd" => "/tmp",
               "env_secrets" => ["CONTEXT7_API_KEY"]
             }

      assert values(context7) == %{{:env, "CONTEXT7_API_KEY"} => "ctx7sk-1"}

      assert figma.attrs == %{
               "transport" => "http",
               "url" => "https://mcp.figma.com/mcp",
               "auth" => "header",
               "key_header" => "Authorization",
               "header_secrets" => ["Authorization", "X-Region", "X-Org"]
             }

      assert values(figma) == %{{:header, "X-Region"} => "us-east-1"}
    end

    test "settings it cannot read, and settings with no server" do
      assert refusal("[mcp_servers.a\ncommand = 1") == "Fermix cannot read these settings."

      assert refusal("[mcp_servers.a]\nenabled = true") ==
               "This server has no command or address."
    end
  end

  describe "placeholders Fermix would have to fill in" do
    test "in the command, the folder or the address, they refuse the paste" do
      assert refusal(~s({"command": "npx", "args": ["-y", "pkg", "${workspaceFolder}"]})) ==
               "Fermix cannot fill in ${workspaceFolder} inside the command. Put the value in a variable."

      assert refusal(~s({"command": "sh", "cwd": "${input:dir}"})) ==
               "Fermix cannot fill in ${input:dir} inside the working folder. Write the full path."

      assert refusal(~s({"url": "https://a.dev/${env:TEAM}/mcp"})) ==
               "Fermix cannot fill in ${env:TEAM} inside the address. Write the full address."
    end

    # One refusal refuses the paste, and in a paste of several it names its server.
    test "in a paste of several, the refusal names its server and refuses them all" do
      text = ~s({"mcpServers": {"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]},
                 "files": {"command": "npx", "args": ["${workspaceFolder}"]}}})

      assert refusal(text) ==
               "files: Fermix cannot fill in ${workspaceFolder} inside the command. Put the value in a variable."
    end
  end

  describe "bounds" do
    test "the text, the servers in it, and text that is no shape" do
      assert refusal(String.duplicate("a", 65_537)) == "This is text of at most 65536 bytes."

      many = Enum.map_join(1..33, ", ", &~s("s#{&1}": {"command": "sh"}))
      assert refusal("{#{many}}") == "Fermix reads at most 32 servers at once."

      assert refusal("   \n") == @paste_sentence
      assert refusal("first line\nsecond line") == @paste_sentence
    end
  end

  test "the package a runner starts" do
    assert Interchange.package("npx", ["-y", "@x/y", "--flag"]) == "@x/y"

    assert Interchange.package("/opt/homebrew/bin/uvx", ["mcp-server-fetch"]) ==
             "mcp-server-fetch"

    assert Interchange.package("pipx", ["run", "--spec", "x"]) == "x"
    assert Interchange.package("node", ["index.js"]) == nil
  end
end
