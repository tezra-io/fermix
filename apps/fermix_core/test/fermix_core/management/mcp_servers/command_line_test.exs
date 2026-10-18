defmodule FermixCore.Management.McpServers.CommandLineTest do
  @moduledoc """
  The command line an owner types for a local MCP server: split as a shell
  splits one simple command, with nothing expanded, and written back as a line
  that splits into the same words.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.McpServers.CommandLine

  describe "split/1" do
    test "reads a README's command line into the program and its arguments" do
      assert {:ok, {"npx", ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"]}} =
               CommandLine.split("npx -y @modelcontextprotocol/server-filesystem ~/Documents")

      assert {:ok, {"uvx", ["mcp-server-fetch"]}} = CommandLine.split("  uvx\tmcp-server-fetch  ")
    end

    test "quotes and backslashes keep what they cover, and nothing is expanded" do
      cases = [
        {~S(node "/Users/owner/My Server/index.js"), ["node", "/Users/owner/My Server/index.js"]},
        {~S(run 'it''s' x), ["run", "its", "x"]},
        {~S(run 'a "b"' c), ["run", ~S(a "b"), "c"]},
        {~S(run "a \"b\" \$c \\ d"), ["run", ~S(a "b" $c \ d)]},
        {~S(run a\ b ''), ["run", "a b", ""]},
        {~S(run --flag="on"), ["run", "--flag=on"]},
        {~S(run '$HOME' ~ *), ["run", "$HOME", "~", "*"]}
      ]

      for {line, words} <- cases do
        assert {:ok, {command, args}} = CommandLine.split(line), line
        assert [command | args] == words, line
      end
    end

    test "a line that needs a shell to mean what it says is refused" do
      lines = [
        "npx server | tee log",
        "npx server > out.log",
        "npx server; rm -rf /",
        "npx server && echo done",
        "npx $SERVER",
        ~S(npx "$SERVER"),
        "npx `which server`",
        "npx (server)"
      ]

      for line <- lines do
        assert {:error, {:invalid_params, "command_line", sentence}} = CommandLine.split(line),
               line

        assert sentence =~ "not through a shell"
      end
    end

    test "a line that cannot be split is refused by what is wrong with it" do
      cases = [
        {"npx 'open", "A quotation mark is not closed."},
        {~S(npx "open), "A quotation mark is not closed."},
        {"npx server\\", "A command cannot end with a backslash."},
        {"npx\nserver", "A command is one line."},
        {"   ", "A local server needs the command that starts it."},
        {"GITHUB_TOKEN=x npx server",
         "A variable goes in a row of its own, not in front of the command."},
        {Enum.join(List.duplicate("w", 129), " "), "A command has at most 128 words."}
      ]

      for {line, sentence} <- cases do
        assert {:error, {:invalid_params, "command_line", ^sentence}} = CommandLine.split(line)
      end
    end
  end

  describe "join/1" do
    test "quotes only a word that needs it" do
      assert CommandLine.join(["npx", "-y", "@scope/pkg@1.2", "~/Documents", "a=b"]) ==
               "npx -y @scope/pkg@1.2 ~/Documents a=b"

      assert CommandLine.join(["node", "My Server/index.js", "it's", ""]) ==
               ~S(node 'My Server/index.js' 'it'\''s' '')
    end

    test "the line it writes splits into the same words" do
      words = [
        ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        ["node", "My Server/index.js", "it's", "a\"b", "$HOME", "x|y", "", "tab\there"],
        ["uvx", "--from", "git+https://example.com/repo.git", "server"]
      ]

      for [command | args] = list <- words do
        assert CommandLine.split(CommandLine.join(list)) == {:ok, {command, args}}
      end
    end
  end
end
