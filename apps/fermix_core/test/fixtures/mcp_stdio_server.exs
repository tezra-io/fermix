# A minimal MCP server over stdio for the tests of the real stdio MCP client
# (`AnubisStdioTest`, `StdioTransportTest`): the real Anubis client talks to it
# through a real OS process, so a library upgrade or a transport change is
# proven on the wire instead of through stubs.
#
#   elixir mcp_stdio_server.exs [PROTOCOL_VERSION] [MODE]
#
# It answers `initialize` with PROTOCOL_VERSION (default 2025-11-25), so a test
# can stand in for an older server. Two tools: `echo` returns its text, and
# `refuse` answers with `isError: true` the way a child reports a failed call.
# MODE:
#
#   * `serve` (default): as above.
#   * `probe`: also `environment`, the variables it was started with as JSON,
#     and `cwd`, the folder it runs in.
#   * `crash`: writes 30 numbered lines to stderr and exits with status 3
#     before it reads anything.
#   * `silent`: reads its input and never answers.
#
# Standard library only; it exits when stdin closes.

defmodule McpStdioFixture do
  @tools [
    %{
      "name" => "echo",
      "description" => "Returns the text it was given.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    },
    %{
      "name" => "refuse",
      "description" => "Always reports a failed call.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @probe_tools [
    %{
      "name" => "environment",
      "description" => "Returns the variables the server was started with.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "cwd",
      "description" => "Returns the folder the server runs in.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  def run(_protocol_version, "crash") do
    Enum.each(1..30, &IO.puts(:stderr, "fixture stderr line #{&1}"))
    System.halt(3)
  end

  def run(_protocol_version, "silent") do
    :stdio |> IO.stream(:line) |> Stream.run()
  end

  def run(protocol_version, mode) do
    tools = if mode == "probe", do: @tools ++ @probe_tools, else: @tools

    :stdio
    |> IO.stream(:line)
    |> Enum.each(&handle_line(&1, protocol_version, tools))
  end

  defp handle_line(line, protocol_version, tools) do
    case line |> String.trim() |> decode() do
      %{"id" => id, "method" => method} = message ->
        reply(id, answer(method, Map.get(message, "params", %{}), protocol_version, tools))

      _notification_or_blank ->
        :ok
    end
  end

  defp decode(""), do: nil
  defp decode(text), do: JSON.decode!(text)

  defp answer("initialize", _params, protocol_version, _tools) do
    {:result,
     %{
       "protocolVersion" => protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "fermix-stdio-fixture", "version" => "1.0.0"}
     }}
  end

  defp answer("ping", _params, _protocol_version, _tools), do: {:result, %{}}
  defp answer("tools/list", _params, _protocol_version, tools), do: {:result, %{"tools" => tools}}

  defp answer("tools/call", %{"name" => "echo", "arguments" => %{"text" => text}}, _version, _) do
    text_result("echo: " <> text)
  end

  defp answer("tools/call", %{"name" => "refuse"}, _protocol_version, _tools) do
    {:result,
     %{"isError" => true, "content" => [%{"type" => "text", "text" => "the fixture refused"}]}}
  end

  defp answer("tools/call", %{"name" => "environment"}, _protocol_version, _tools) do
    text_result(JSON.encode!(System.get_env()))
  end

  defp answer("tools/call", %{"name" => "cwd"}, _protocol_version, _tools) do
    text_result(File.cwd!())
  end

  defp answer(method, _params, _protocol_version, _tools) do
    {:error, %{"code" => -32_601, "message" => "Method not found: " <> method}}
  end

  defp text_result(text), do: {:result, %{"content" => [%{"type" => "text", "text" => text}]}}

  defp reply(id, {kind, body}) do
    IO.puts(JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, Atom.to_string(kind) => body}))
  end
end

case System.argv() do
  [] -> McpStdioFixture.run("2025-11-25", "serve")
  [protocol_version] -> McpStdioFixture.run(protocol_version, "serve")
  [protocol_version, mode | _rest] -> McpStdioFixture.run(protocol_version, mode)
end
