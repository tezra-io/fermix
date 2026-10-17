# A minimal MCP server over stdio for `AnubisStdioTest`: the real Anubis client
# talks to it through a real OS process, so a library upgrade is proven on the
# wire instead of through stubs.
#
#   elixir mcp_stdio_server.exs [PROTOCOL_VERSION]
#
# It answers `initialize` with PROTOCOL_VERSION (default 2025-11-25), so a test
# can stand in for an older server. Two tools: `echo` returns its text, and
# `refuse` answers with `isError: true` the way a child reports a failed call.
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

  def run(protocol_version) do
    :stdio
    |> IO.stream(:line)
    |> Enum.each(&handle_line(&1, protocol_version))
  end

  defp handle_line(line, protocol_version) do
    case line |> String.trim() |> decode() do
      %{"id" => id, "method" => method} = message ->
        reply(id, answer(method, Map.get(message, "params", %{}), protocol_version))

      _notification_or_blank ->
        :ok
    end
  end

  defp decode(""), do: nil
  defp decode(text), do: JSON.decode!(text)

  defp answer("initialize", _params, protocol_version) do
    {:result,
     %{
       "protocolVersion" => protocol_version,
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "fermix-stdio-fixture", "version" => "1.0.0"}
     }}
  end

  defp answer("ping", _params, _protocol_version), do: {:result, %{}}
  defp answer("tools/list", _params, _protocol_version), do: {:result, %{"tools" => @tools}}

  defp answer("tools/call", %{"name" => "echo", "arguments" => %{"text" => text}}, _version) do
    {:result, %{"content" => [%{"type" => "text", "text" => "echo: " <> text}]}}
  end

  defp answer("tools/call", %{"name" => "refuse"}, _protocol_version) do
    {:result,
     %{"isError" => true, "content" => [%{"type" => "text", "text" => "the fixture refused"}]}}
  end

  defp answer(method, _params, _protocol_version) do
    {:error, %{"code" => -32_601, "message" => "Method not found: " <> method}}
  end

  defp reply(id, {kind, body}) do
    IO.puts(JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, Atom.to_string(kind) => body}))
  end
end

McpStdioFixture.run(List.first(System.argv(), "2025-11-25"))
