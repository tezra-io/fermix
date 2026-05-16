defmodule FermixCore.MCP.Inbound.ConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.MCP.Inbound.Config

  describe "from_toml/1" do
    test "returns fail-closed defaults when inbound is absent" do
      config = Config.from_toml("")

      assert config.enabled? == false
      assert config.transport == :stdio
      assert config.expose_kinds == [:builtin]
      assert config.expose_policy_classes == [:read_only, :read_write]
      assert config.allowed_tools == []
      assert config.denied_tools == []
      assert config.tool_overrides == %{}
      assert config.http.path == "/mcp"
      assert config.http.auth_token == nil
    end

    test "parses inbound filters and per-tool overrides" do
      toml = """
      [mcp.inbound]
      enabled = true
      transport = "stdio"
      expose_kinds = ["builtin", "mcp"]
      expose_policy_classes = ["read_only", "external_api"]
      allowed_tools = ["file_read", "mcp_github_issue_get"]
      denied_tools = ["shell"]
      server_name = "fermix-dev"
      server_version = "9.9.9"
      request_timeout_ms = 60000

      [mcp.inbound.tools.shell]
      exposed = true
      description_override = "Run a command."

      [mcp.inbound.tools.file_write]
      exposed = false
      """

      config = Config.from_toml(toml)

      assert config.enabled? == true
      assert config.transport == :stdio
      assert config.expose_kinds == [:builtin, :mcp]
      assert config.expose_policy_classes == [:read_only, :external_api]
      assert config.allowed_tools == ["file_read", "mcp_github_issue_get"]
      assert config.denied_tools == ["shell"]
      assert config.server_name == "fermix-dev"
      assert config.server_version == "9.9.9"
      assert config.request_timeout_ms == 60_000

      assert config.tool_overrides == %{
               "file_write" => %{exposed: false},
               "shell" => %{exposed: true, description_override: "Run a command."}
             }
    end

    test "$env: auth_token resolves against the real environment" do
      System.put_env("FERMIX_INBOUND_TOKEN_TEST", "secret-token")

      toml = """
      [mcp.inbound]
      enabled = true
      transport = "streamable_http"

      [mcp.inbound.http]
      auth_token = "$env:FERMIX_INBOUND_TOKEN_TEST"
      """

      assert Config.from_toml(toml).http.auth_token == "secret-token"
    after
      System.delete_env("FERMIX_INBOUND_TOKEN_TEST")
    end

    test "raises when enabled streamable_http has no token" do
      toml = """
      [mcp.inbound]
      enabled = true
      transport = "streamable_http"
      """

      assert_raise ArgumentError, ~r/auth_token/, fn ->
        Config.from_toml(toml)
      end
    end

    test "raises on invalid kind or policy class" do
      assert_raise ArgumentError, ~r/Invalid inbound MCP kind/, fn ->
        Config.from_toml("""
        [mcp.inbound]
        expose_kinds = ["builtin", "bogus"]
        """)
      end

      assert_raise ArgumentError, ~r/Invalid inbound MCP policy_class/, fn ->
        Config.from_toml("""
        [mcp.inbound]
        expose_policy_classes = ["read_only", "danger"]
        """)
      end
    end

    test "raises when allowed and denied tools overlap" do
      toml = """
      [mcp.inbound]
      allowed_tools = ["file_read"]
      denied_tools = ["file_read"]
      """

      assert_raise ArgumentError, ~r/duplicate tool name/, fn ->
        Config.from_toml(toml)
      end
    end

    test "raises when request timeout is not a positive integer" do
      assert_raise ArgumentError, ~r/request_timeout_ms/, fn ->
        Config.from_toml("""
        [mcp.inbound]
        request_timeout_ms = 0
        """)
      end
    end

    test "raises when a per-tool override has no recognized keys" do
      assert_raise ArgumentError, ~r/no recognized keys/, fn ->
        Config.from_toml("""
        [mcp.inbound.tools.shell]
        """)
      end
    end
  end
end
