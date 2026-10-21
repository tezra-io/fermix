defmodule FermixCore.Setup.ConfigStoreMcpTest do
  # Every settings save re-renders `config.toml`, and the `[mcp.*]` blocks an
  # owner writes by hand are read by their own parsers, not by the settings
  # snapshot. These tests hold the save to keeping them (M74 E1).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SecretWriterStub

  @settings ~S"""
  [fermix_core.personalization]
  user_name = "Ada"
  """

  # Written the way the renderer writes it (keys and blocks in order, arrays and
  # inline tables on one line), so every byte must survive a save. The values
  # are the awkward ones: spaces in paths, a quote inside a value, a backslash
  # the MCP reader keeps as written, and keys the reader ignores today.
  @mcp ~S"""
  [mcp.servers.files]
  args = ["--root", "/Users/owner/My Documents", "--label", "say \"hi\""]
  command = "/Users/owner/Library/Application Support/mcp files/bin/server"
  cwd = "/Users/owner/Work Folder"
  enabled = true
  timeout = 30

  [mcp.servers.github]
  args = ["-y", "@modelcontextprotocol/server-github"]
  command = "npx"
  env = { GITHUB_API_URL = "https://api.github.com", TOOLS_DIR = "C:\\tools" }
  pass_env = ["GITHUB_TOKEN"]
  url = "https://api.githubcopilot.com/mcp/"

  [mcp.servers.github.tools.create_issue]
  hidden_from_agent = true
  policy_class = "external_api"

  [mcp.servers.github.tools.search_code]
  policy_class = "read_only"
  """

  # The retired inbound server's section, as an owner may still have it (M73).
  @retired_inbound ~S"""
  [mcp.inbound]
  enabled = false
  transport = "stdio"

  [mcp.inbound.tools.shell]
  exposed = false
  """

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("config-store-mcp")
    previous_home = System.get_env("FERMIX_HOME")
    apps = [:fermix_core, :fermix_channels, :fermix_web]
    previous_env = Enum.map(apps, &{&1, Application.get_all_env(&1)})

    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      Enum.each(previous_env, fn {app, env} -> restore_app_env(app, env) end)
      SecretWriterStub.reset()
      restore_home(previous_home)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{config_path: Path.join(home, "config.toml")}
  end

  test "a save from live settings keeps every [mcp.*] block", %{config_path: config_path} do
    original = @settings <> "\n" <> @mcp
    File.write!(config_path, original)
    assert :ok = ConfigStore.bootstrap_runtime_config()

    snapshot = ConfigStore.current_snapshot()
    assert :ok = ConfigStore.save_snapshot(renamed(snapshot))

    assert_mcp_kept(File.read!(config_path), original)
  end

  test "a save from the file keeps every [mcp.*] block", %{config_path: config_path} do
    original = @settings <> "\n" <> @mcp
    File.write!(config_path, original)

    assert {:ok, snapshot} = ConfigStore.load_runtime_config()
    assert :ok = ConfigStore.save_snapshot(renamed(snapshot))

    assert_mcp_kept(File.read!(config_path), original)
  end

  # Servers by name, each followed by its tool blocks, whatever order the owner
  # wrote them in, and a second save writes the same bytes as the first. The
  # reader keeps a bare value as written, so one ending in a quote stays bare.
  test "the [mcp.*] blocks are written in one order and read back the same",
       %{config_path: config_path} do
    original = ~S"""
    [mcp.servers.zeta]
    command = "uvx"
    args = ["mcp-server-fetch","--ignore-robots-txt"]
    transport = stdio
    note = say "hi"
    startup_seconds = 1.50

    [mcp.servers.alpha]
    pass_env = [ "API_KEY" ]
    command = "node"
    env = {LEVEL="debug",MODE="fast"}

    [mcp.servers.zeta.tools.fetch]
    policy_class = "network"

    [mcp.servers.alpha.tools.run]
    hidden_from_agent = false
    """

    File.write!(config_path, original)

    assert {:ok, snapshot} = ConfigStore.load_runtime_config()
    assert :ok = ConfigStore.save_snapshot(snapshot)
    first = File.read!(config_path)

    assert McpConfig.from_toml(first) == McpConfig.from_toml(original)
    assert [%{name: "alpha"}, %{name: "zeta"}] = McpConfig.from_toml(first)
    assert first =~ ~s(transport = "stdio")
    assert first =~ ~s(note = say "hi"\n)
    assert first =~ "startup_seconds = 1.5\n"

    headers =
      ~r/^\[mcp\.[^\]]+\]$/m
      |> Regex.scan(first)
      |> List.flatten()

    assert headers == [
             "[mcp.servers.alpha]",
             "[mcp.servers.alpha.tools.run]",
             "[mcp.servers.zeta]",
             "[mcp.servers.zeta.tools.fetch]"
           ]

    assert {:ok, again} = ConfigStore.load_runtime_config()
    assert :ok = ConfigStore.save_snapshot(again)
    assert File.read!(config_path) == first
  end

  # The inbound server was retired before it ever ran. A file that still has its
  # section boots with the servers it names, says once that the section is
  # ignored, and the next save writes the file without it, the way a retired
  # provider key goes.
  test "a retired [mcp.inbound] block boots with one warning and the next save drops it",
       %{config_path: config_path} do
    File.write!(config_path, @settings <> "\n" <> @mcp <> "\n" <> @retired_inbound)

    log = capture_log(fn -> assert :ok = ConfigStore.bootstrap_runtime_config() end)

    assert [%{name: "files"}, %{name: "github"}] =
             Application.get_env(:fermix_core, :mcp_servers)

    assert length(String.split(log, "[mcp.inbound] is retired")) == 2
    assert log =~ "the next settings save writes the file without it"

    assert :ok = ConfigStore.save_snapshot(renamed(ConfigStore.current_snapshot()))

    saved = File.read!(config_path)
    refute saved =~ "[mcp.inbound"
    assert_mcp_kept(saved, @settings <> "\n" <> @mcp)
  end

  defp renamed(snapshot),
    do: put_in(snapshot, [:fermix_core, :personalization, :user_name], "Grace")

  defp assert_mcp_kept(saved, original) do
    assert saved =~ ~s(user_name = "Grace")

    assert [%{name: "files"}, %{name: "github"}] = McpConfig.from_toml(saved)
    assert McpConfig.from_toml(saved) == McpConfig.from_toml(original)

    assert String.ends_with?(saved, "\n\n" <> @mcp),
           "the [mcp.*] blocks did not survive the save byte for byte:\n\n" <> saved
  end

  defp restore_app_env(app, previous) do
    for {key, _value} <- Application.get_all_env(app), not Keyword.has_key?(previous, key) do
      Application.delete_env(app, key)
    end

    Enum.each(previous, fn {key, value} -> Application.put_env(app, key, value) end)
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)
end
