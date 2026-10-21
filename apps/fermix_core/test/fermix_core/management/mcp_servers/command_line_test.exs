defmodule FermixCore.Management.McpServers.CommandLineTest do
  @moduledoc """
  The command line an owner types for a local MCP server: split as a shell
  splits one simple command, with only a leading `~` expanded, and written
  back as a line that splits into the same words.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.McpServers.CommandLine

  # A home folder of this test's own: a split never reads the host's.
  @home "/Users/owner"

  describe "split/2" do
    test "reads a README's command line into the program and its arguments" do
      assert {:ok,
              {"npx", ["-y", "@modelcontextprotocol/server-filesystem", "/Users/owner/Documents"]}} =
               split("npx -y @modelcontextprotocol/server-filesystem ~/Documents")

      assert {:ok, {"uvx", ["mcp-server-fetch"]}} = split("  uvx\tmcp-server-fetch  ")
    end

    test "quotes and backslashes keep what they cover, and nothing else is expanded" do
      cases = [
        {~S(node "/Users/owner/My Server/index.js"), ["node", "/Users/owner/My Server/index.js"]},
        {~S(run 'it''s' x), ["run", "its", "x"]},
        {~S(run 'a "b"' c), ["run", ~S(a "b"), "c"]},
        {~S(run "a \"b\" \$c \\ d"), ["run", ~S(a "b" $c \ d)]},
        {~S(run a\ b ''), ["run", "a b", ""]},
        {~S(run --flag="on"), ["run", "--flag=on"]},
        {~S(run '$HOME' *), ["run", "$HOME", "*"]}
      ]

      for {line, words} <- cases do
        assert {:ok, {command, args}} = split(line), line
        assert [command | args] == words, line
      end
    end

    # A shell writes the home folder in for an unquoted `~` that starts a word,
    # alone or before a `/`, and nowhere else.
    test "a leading ~ is the home folder, as a shell reads it" do
      cases = [
        {"~/bin/server ~ ~/", ["/Users/owner/bin/server", "/Users/owner", "/Users/owner/"]},
        {~S(run ~/"My Docs" ~/a\ b), ["run", "/Users/owner/My Docs", "/Users/owner/a b"]},
        {~S(run '~/x' "~/x" \~/x ~"/x" ~\/x), ["run", "~/x", "~/x", "~/x", "~/x", "~/x"]},
        {"run a~/x --dir=~/x ''~", ["run", "a~/x", "--dir=~/x", "~"]}
      ]

      for {line, words} <- cases do
        assert {:ok, {command, args}} = split(line), line
        assert [command | args] == words, line
      end
    end

    test "another account's home is refused with the word written" do
      assert split("npx server ~alice/notes") ==
               {:error,
                {:invalid_params, "command_line", "Write the full path in place of ~alice."}}

      assert split("~+/server") ==
               {:error, {:invalid_params, "command_line", "Write the full path in place of ~+."}}

      long = String.duplicate("a", 100)

      assert {:error, {:invalid_params, "command_line", sentence}} = split("run ~#{long}")
      assert sentence == "Write the full path in place of ~#{String.duplicate("a", 63)}."
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
        assert {:error, {:invalid_params, "command_line", sentence}} = split(line), line

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
        assert {:error, {:invalid_params, "command_line", ^sentence}} = split(line)
      end
    end
  end

  # A line read but never run as one command, such as a pasted claude mcp add
  # line: a `$` a shell would expand is kept and its word marked, and every
  # other rule is split/2's.
  describe "tokens/2" do
    test "marks each word that holds a $ a shell would expand, and keeps it" do
      line =
        ~S(claude mcp add -e KEY=$KEY -H "Authorization: Bearer ${PAT}" ) <>
          ~S(-e 'LIT=$NOT' -e ESC=\$NOT x -- ~/bin/run "\$also")

      assert CommandLine.tokens(line, @home) ==
               {:ok,
                [
                  {"claude", false},
                  {"mcp", false},
                  {"add", false},
                  {"-e", false},
                  {"KEY=$KEY", true},
                  {"-H", false},
                  {"Authorization: Bearer ${PAT}", true},
                  {"-e", false},
                  {"LIT=$NOT", false},
                  {"-e", false},
                  {"ESC=$NOT", false},
                  {"x", false},
                  {"--", false},
                  {"/Users/owner/bin/run", false},
                  {"$also", false}
                ]}
    end

    test "still refuses what needs a shell beyond a variable" do
      for line <- ["a -e K=$(cat key)", "a `which b`", "a | b", "a 'open"] do
        assert {:error, {:invalid_params, "command_line", _sentence}} =
                 CommandLine.tokens(line, @home),
               line
      end

      assert {:error, {:invalid_params, "command_line", sentence}} = split("npx $SERVER")
      assert sentence == CommandLine.shell_sentence()
    end
  end

  describe "expand_home/3" do
    test "a working folder takes the same rule, refused under its own field" do
      assert CommandLine.expand_home("~/code", @home, "cwd") == {:ok, "/Users/owner/code"}
      assert CommandLine.expand_home("~", @home, "cwd") == {:ok, @home}
      assert CommandLine.expand_home("/tmp/~x", @home, "cwd") == {:ok, "/tmp/~x"}

      assert CommandLine.expand_home("~bob/code", @home, "cwd") ==
               {:error, {:invalid_params, "cwd", "Write the full path in place of ~bob."}}
    end
  end

  describe "join/1" do
    test "quotes only a word that needs it" do
      assert CommandLine.join(["npx", "-y", "@scope/pkg@1.2", "/Users/owner/Documents", "a=b"]) ==
               "npx -y @scope/pkg@1.2 /Users/owner/Documents a=b"

      # A word that starts with `~` is literal, so it is quoted to stay so.
      assert CommandLine.join(["run", "~/x", "a~b"]) == "run '~/x' a~b"

      assert CommandLine.join(["node", "My Server/index.js", "it's", ""]) ==
               ~S(node 'My Server/index.js' 'it'\''s' '')
    end

    test "the line it writes splits into the same words" do
      words = [
        ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        ["node", "My Server/index.js", "it's", "a\"b", "$HOME", "x|y", "", "tab\there"],
        ["uvx", "--from", "git+https://example.com/repo.git", "server"],
        ["run", "~", "~/x", "~alice"]
      ]

      for [command | args] = list <- words do
        assert split(CommandLine.join(list)) == {:ok, {command, args}}
      end
    end
  end

  defp split(line), do: CommandLine.split(line, @home)
end
