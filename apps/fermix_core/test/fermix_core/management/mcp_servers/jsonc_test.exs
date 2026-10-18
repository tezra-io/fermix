defmodule FermixCore.Management.McpServers.JsoncTest do
  @moduledoc """
  JSON with comments, as VS Code reads its `mcp.json`, turned into JSON for
  the import's parser: comments and trailing commas go, and nothing inside a
  string changes.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.McpServers.Jsonc

  defp decoded(text) do
    {:ok, json} = Jsonc.to_json(text)
    Jason.decode!(json)
  end

  test "line and block comments go, and the JSON around them stays" do
    text = ~S"""
    // the servers this editor starts
    {
      /* one remote, one local */
      "servers": { // by name
        "a": {"url": "https://a.dev/mcp"}, /* inline */ "b": {"command": "sh"}
      }
    }
    """

    assert decoded(text) == %{
             "servers" => %{"a" => %{"url" => "https://a.dev/mcp"}, "b" => %{"command" => "sh"}}
           }
  end

  test "a comment's marks inside a string are the string's" do
    text = ~S"""
    {"url": "https://mcp.example.com//double//slash", "note": "/* not a comment */",
     "quote": "say \"// still text\" here", "slash": "ends with a backslash \\", "after": 1}
    """

    assert decoded(text) == %{
             "url" => "https://mcp.example.com//double//slash",
             "note" => "/* not a comment */",
             "quote" => ~S(say "// still text" here),
             "slash" => "ends with a backslash \\",
             "after" => 1
           }
  end

  test "a trailing comma goes from an object and an array, even with comments before the close" do
    text = ~S"""
    {"servers": {"a": {"command": "sh", "args": ["-y", "pkg",],}, // the last one
                 /* none after it */ },
     "inputs": [],}
    """

    assert decoded(text) == %{
             "servers" => %{"a" => %{"command" => "sh", "args" => ["-y", "pkg"]}},
             "inputs" => []
           }
  end

  test "a comma between values stays, wherever space and comments put it" do
    assert decoded(~s({"a": 1 /* x */ , // y\n "b": [1 ,2]})) == %{"a" => 1, "b" => [1, 2]}
  end

  test "a block comment that never closes is refused, and plain JSON passes as it is" do
    assert Jsonc.to_json(~s({"servers": {} /* unclosed)) == {:error, :unclosed_comment}

    json = ~s({"servers": {"a": {"url": "https://a.dev/mcp"}}})
    assert Jsonc.to_json(json) == {:ok, json}
  end
end
