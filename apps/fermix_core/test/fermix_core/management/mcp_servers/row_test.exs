defmodule FermixCore.Management.McpServers.RowTest do
  @moduledoc """
  `mcpServerRow` (M74 §5) from a server's configuration and the facts the
  daemon holds about it. The builder is pure, so every status, sentence and
  action is driven here from facts rather than from a running server.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Management.McpServers.Row

  @local ~S"""
  [mcp.servers.files]
  command = "npx"
  args = ["-y", "@modelcontextprotocol/server-filesystem", "/Users/owner/My Documents"]
  env_secrets = ["GITHUB_TOKEN", "API_KEY"]

  [mcp.servers.files.tools.write_file]
  hidden_from_agent = true
  """

  @remote ~S"""
  [mcp.servers.linear]
  transport = "http"
  url = "https://mcp.linear.app/mcp"
  auth = "header"
  key_header = "Authorization"
  header_secrets = ["X-Workspace", "Authorization"]
  oauth_client_id = "fermix"
  """

  @no_values %{env: [], headers: [], client_secret: false}

  describe "status, in the order it is derived" do
    test "off wins over a missing value, and leads with enable" do
      server = %{server(@local) | enabled?: false}

      assert %{"status" => "off", "status_sentence" => "Turned off."} = row = build(server)
      assert %{"primary_action" => "enable", "actions" => ["enable"]} = row
    end

    test "a missing value names what the server waits for" do
      presence = %{
        env: [{"GITHUB_TOKEN", true}],
        headers: [{"X-Workspace", false}, {"Authorization", false}],
        client_secret: false
      }

      assert %{"status" => "needs_secret", "status_sentence" => sentence} =
               build(server(@remote), presence: presence)

      assert sentence == "Waiting for X-Workspace, the key and the client secret."

      local = %{
        env: [{"GITHUB_TOKEN", false}, {"API_KEY", true}],
        headers: [],
        client_secret: false
      }

      assert %{"status_sentence" => "Waiting for GITHUB_TOKEN.", "actions" => ["disable"]} =
               build(server(@local), presence: local)
    end

    test "an auto server the server asked to sign in needs a sign-in, a keyed one fails" do
      auto = %{server(@remote) | auth: :auto, key_header: nil, oauth_client_id: nil}
      entry = entry(:reauthorization_required, :sign_in_required)

      assert %{"status" => "needs_sign_in", "primary_action" => nil, "actions" => ["disable"]} =
               build(auto, presence: stored(auto), entry: entry)

      keyed = server(@remote)
      refused = entry(:reauthorization_required, :key_refused)

      assert %{"status" => "failed", "status_sentence" => "The server refused the key."} =
               build(keyed, presence: stored(keyed), entry: refused)
    end

    test "no status yet and connecting are both starting" do
      server = server(@local)

      for entry <- [nil, entry(:connecting, nil)] do
        assert %{"status" => "starting", "status_sentence" => "Starting.", "last_error" => nil} =
                 row = build(server, presence: stored(server), entry: entry)

        assert %{"primary_action" => nil, "actions" => ["disable"]} = row
      end
    end

    test "connected counts what the server listed" do
      server = server(@local)

      assert %{"status" => "connected", "status_sentence" => "Connected. 1 tool."} =
               build(server, presence: stored(server), entry: ready(1))

      assert %{"status_sentence" => "Connected. 23 tools.", "actions" => ["check", "disable"]} =
               build(server, presence: stored(server), entry: ready(23))
    end

    test "a failure is retrying while the subtree runs and failed once it is gone" do
      server = server(@local)
      exited = %{entry(:remote_unreachable, :exited) | stderr_tail: ["warming up", "fatal: no"]}

      assert %{"status" => "retrying", "status_sentence" => "Trying again."} =
               retrying = build(server, presence: stored(server), entry: exited, alive?: true)

      assert retrying["last_error"] == "It stopped. The last thing it said: fatal: no"
      assert retrying["primary_action"] == nil

      assert %{"status" => "failed", "primary_action" => "check"} =
               failed = build(server, presence: stored(server), entry: exited)

      assert failed["status_sentence"] ==
               "Stopped after three failed starts. The last thing it said: fatal: no"

      assert failed["last_error"] == failed["status_sentence"]
    end
  end

  describe "failure sentences" do
    test "a program that is not found says how to get it" do
      cases = [
        {"npx", "Fermix could not find npx on this Mac. Install Node.js or use the full path."},
        {"uvx", "Fermix could not find uvx on this Mac. Install uv or use the full path."},
        {"deno", "Fermix could not find deno on this Mac. Use the full path."},
        {"/opt/tools/server", "Fermix could not find /opt/tools/server on this Mac."}
      ]

      for {command, sentence} <- cases do
        server = %{server(@local) | command: command}
        entry = entry(:invalid_remote_config, :command_not_found)

        assert build(server, presence: stored(server), entry: entry)["status_sentence"] ==
                 sentence
      end
    end

    test "every class an operator server can end in has its own sentence" do
      local = %{server(@local) | cwd: "/Users/owner/mcp"}
      remote = server(@remote)

      cases = [
        {local, :invalid_remote_config, :cwd_not_found,
         "Fermix could not find the working folder /Users/owner/mcp on this Mac."},
        {local, :invalid_remote_config, :env_unavailable,
         "Fermix could not read one of its stored variables."},
        {remote, :invalid_remote_config, :header_unavailable,
         "Fermix could not read one of its stored headers."},
        {remote, :invalid_remote_config, :reserved_header,
         "One of its headers is one Fermix sets itself. Remove it."},
        {remote, :invalid_remote_config, :invalid_url, Row.url_sentence()},
        {remote, :remote_protocol_error, :legacy_sse_transport,
         "This server uses the older SSE transport, which Fermix does not support."},
        {remote, :remote_unreachable, :econnrefused, "Fermix could not reach mcp.linear.app."},
        {local, :remote_unreachable, :retries_exhausted,
         "It started but did not answer within a minute."},
        {local, :remote_unreachable, :spawn_failed, "Fermix could not start the program."}
      ]

      for {server, status, detail, sentence} <- cases do
        row = build(server, presence: stored(server), entry: entry(status, detail))

        assert {row["status"], row["status_sentence"], row["last_error"]} ==
                 {"failed", sentence, sentence},
               "#{status}/#{detail}"
      end
    end
  end

  describe "fields" do
    test "a local server says it runs here, with its command as written" do
      server = server(@local)
      program = {:ok, "/opt/homebrew/bin/npx"}

      assert %{
               "transport" => "stdio",
               "consent_sentence" => "Runs on this Mac as a separate program, with your access.",
               "location" =>
                 "npx -y @modelcontextprotocol/server-filesystem '/Users/owner/My Documents'",
               "url" => nil,
               "resolved_command" => "/opt/homebrew/bin/npx",
               "headers" => [],
               "auth" => %{"mode" => "none", "state" => "not_needed", "key_header" => nil},
               "oauth_client" => %{"client_id" => nil, "secret_present" => false}
             } = build(server, presence: stored(server), resolution: program)
    end

    test "a remote server names its host, its key apart from its other headers" do
      server = server(@remote)

      presence = %{
        env: [],
        headers: [{"X-Workspace", true}, {"Authorization", true}],
        client_secret: true
      }

      assert %{
               "consent_sentence" =>
                 "Runs on mcp.linear.app. What you ask its tools is sent there.",
               "location" => "mcp.linear.app",
               "url" => "https://mcp.linear.app/mcp",
               "resolved_command" => nil,
               "headers" => [%{"name" => "X-Workspace", "present" => true}],
               "auth" => %{
                 "mode" => "header",
                 "state" => "signed_in",
                 "key_header" => "Authorization"
               },
               "oauth_client" => %{"client_id" => "fermix", "secret_present" => true}
             } = build(server, presence: presence)

      auto = %{server | auth: :auto, key_header: nil}
      assert %{"auth" => %{"mode" => "auto", "state" => "signed_out"}} = build(auto)
    end

    test "tools ride only when asked for, with the owner's switches and the server's hints" do
      server = server(@local)

      tools = [
        %{
          name: "read_file",
          title: "Read file",
          description: "Reads.",
          read_only: true,
          destructive: false
        },
        %{name: "write_file", title: nil, description: nil, read_only: false, destructive: true}
      ]

      entry = %{ready(40) | discovery: %{tool_count: 40, server_info: nil, tools: tools}}
      facts = [presence: stored(server), entry: entry]

      refute Map.has_key?(build(server, facts), "tools")

      assert %{"tool_count" => 40, "tools_on" => 39, "tools" => [read, write]} =
               build(server, facts, tools?: true)

      assert read == %{
               "name" => "read_file",
               "title" => "Read file",
               "description" => "Reads.",
               "read_only" => true,
               "destructive" => false,
               "enabled" => true
             }

      assert %{"destructive" => true, "enabled" => false, "title" => nil} = write
    end

    test "what the server last said stays while it is off" do
      server = %{server(@local) | enabled?: false}
      info = %{name: "secure-filesystem-server", title: nil, version: "0.6.2"}
      entry = %{entry(:remote_unreachable, :shutdown) | discovery: discovery(11, info)}

      assert %{
               "status" => "off",
               "last_error" => nil,
               "server_info" => %{"name" => "secure-filesystem-server", "title" => nil},
               "tool_count" => 11,
               "tools_on" => 11
             } = build(server, entry: entry)
    end

    test "every row carries the same fields" do
      rows = [
        build(server(@local)),
        build(server(@remote)),
        build(%{server(@local) | enabled?: false})
      ]

      keys = rows |> Enum.map(&(&1 |> Map.keys() |> Enum.sort())) |> Enum.uniq()

      assert [_one_shape] = keys
    end
  end

  defp server(toml) do
    [server] = McpConfig.from_toml(toml)
    server
  end

  defp build(server, facts \\ [], opts \\ []) do
    facts =
      Map.merge(
        %{presence: @no_values, entry: nil, alive?: false, resolution: nil},
        Map.new(facts)
      )

    Row.build(server, facts, opts)
  end

  # Every value the server declares, stored.
  defp stored(server) do
    %{
      env: Enum.map(Map.get(server, :env_secrets, []), &{&1, true}),
      headers: Enum.map(Map.get(server, :header_secrets, []), &{&1, true}),
      client_secret: is_binary(Map.get(server, :oauth_client_id))
    }
  end

  defp entry(status, detail),
    do: %{status: status, detail: detail, subject: nil, discovery: nil, stderr_tail: []}

  defp ready(count), do: %{entry(:ready, nil) | discovery: discovery(count, nil)}

  defp discovery(count, info), do: %{tool_count: count, server_info: info, tools: []}
end
