defmodule FermixCore.Capabilities.MCP.ConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Config

  describe "from_toml/1" do
    test "parses a single MCP server with command, args, env, and approved" do
      toml = """
      [mcp.servers.github]
      command = "npx"
      args = ["-y", "@modelcontextprotocol/server-github"]
      env = { GITHUB_TOKEN = "ghp_static" }
      approved = true
      """

      assert [config] = Config.from_toml(toml)
      assert config.name == "github"
      assert config.command == "npx"
      assert config.args == ["-y", "@modelcontextprotocol/server-github"]
      assert config.env == %{"GITHUB_TOKEN" => "ghp_static"}
      assert config.approved? == true
      assert config.tools_overrides == %{}
    end

    test "$env: prefix resolves against the real environment at parse time" do
      System.put_env("FERMIX_MCP_TEST_TOKEN", "from-env")

      toml = """
      [mcp.servers.github]
      command = "npx"
      env = { GITHUB_TOKEN = "$env:FERMIX_MCP_TEST_TOKEN" }
      """

      assert [config] = Config.from_toml(toml)
      assert config.env == %{"GITHUB_TOKEN" => "from-env"}
    after
      System.delete_env("FERMIX_MCP_TEST_TOKEN")
    end

    test "missing $env: variable resolves to empty string, not crash" do
      System.delete_env("FERMIX_MCP_TEST_MISSING")

      toml = """
      [mcp.servers.github]
      env = { GITHUB_TOKEN = "$env:FERMIX_MCP_TEST_MISSING" }
      """

      assert [config] = Config.from_toml(toml)
      assert config.env == %{"GITHUB_TOKEN" => ""}
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
      approved = true

      [mcp.servers.filesystem.tools.read_file]
      policy_class = "read_only"
      requires_approval = false
      """

      assert [config] = Config.from_toml(toml)

      assert config.tools_overrides == %{
               "read_file" => %{policy_class: :read_only, requires_approval?: false}
             }
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
end
