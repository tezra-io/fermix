defmodule FermixCore.Management.McpServers.ImportSourcesTest do
  @moduledoc """
  The reader of other apps' settings files for the MCP import (M74 E8): each
  source's fixed file under a fixture home, its servers map taken out of the
  whole file, and one sentence for a file that cannot be read. Nothing here
  reads the real home.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.McpServers.ImportSources
  alias FermixTestSupport.SafeRm
  alias Jason.OrderedObject

  setup do
    home = SafeRm.make_tmp_dir!("mcp-import-sources")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp source(id) do
    {:ok, source} = ImportSources.fetch(id)
    source
  end

  defp write!(home, id, contents) do
    path = Path.join(home, source(id).path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp keys({:ok, entries}), do: Enum.map(entries, &elem(&1, 0))

  test "the six sources, by the closed ids the wire names them" do
    assert ImportSources.ids() ==
             ~w(claude_desktop claude_code cursor vscode windsurf codex)

    assert Enum.map(ImportSources.all(), & &1.label) ==
             ["Claude Desktop", "Claude Code", "Cursor", "VS Code", "Windsurf", "Codex"]

    assert source("vscode").path == "Library/Application Support/Code/User/mcp.json"
    assert ImportSources.fetch("zed") == :error
  end

  test "each JSON source's servers map, in the file's order", %{home: home} do
    servers = ~s({"b": {"command": "sh"}, "a": {"url": "https://a.dev/mcp"}})

    for id <- ~w(claude_desktop cursor windsurf) do
      write!(home, id, ~s({"globalShortcut": "", "mcpServers": #{servers}}))
      assert keys(ImportSources.servers(source(id), home)) == ["b", "a"], id
    end

    write!(home, "vscode", ~s({"inputs": [], "servers": #{servers}}))

    assert {:ok, [{"b", %OrderedObject{}}, {"a", _a}]} =
             ImportSources.servers(source("vscode"), home)
  end

  # Claude Code keeps every project's history in the same file, often far past
  # what a paste may hold, and a project's own servers are not the user's.
  test "Claude Code's user servers out of a large file, and no project's", %{home: home} do
    history = String.duplicate("x", 2 * 1024 * 1024)

    write!(home, "claude_code", """
    {"projects": {"/Users/owner/app": {"history": ["#{history}"],
                                       "mcpServers": {"project-only": {"command": "sh"}}}},
     "mcpServers": {"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}}}
    """)

    assert keys(ImportSources.servers(source("claude_code"), home)) == ["fetch"]
  end

  # VS Code reads its mcp.json as JSON with comments; the others read theirs
  # as JSON, so a comment there is a file they do not read either.
  test "VS Code's file may hold comments and trailing commas, and only VS Code's", %{home: home} do
    commented = ~S"""
    {
      // the servers this editor starts
      "servers": {
        "fetch": {"command": "uvx", "args": ["mcp-server-fetch"],}, /* by uv */
      },
    }
    """

    write!(home, "vscode", commented)
    assert keys(ImportSources.servers(source("vscode"), home)) == ["fetch"]

    write!(home, "cursor", String.replace(commented, ~s("servers"), ~s("mcpServers")))

    assert ImportSources.servers(source("cursor"), home) ==
             {:error, "Cursor's settings file is not valid JSON."}

    write!(home, "vscode", ~s({"servers": {}} /* never closed))

    assert ImportSources.servers(source("vscode"), home) ==
             {:error, "VS Code's settings file is not valid JSON."}
  end

  test "Codex's tables, by name, and nothing else of its settings", %{home: home} do
    write!(home, "codex", """
    model = "gpt-5"

    [mcp_servers.zeta]
    command = "sh"

    [mcp_servers.alpha]
    url = "https://alpha.dev/mcp"

    [profiles.fast]
    model = "gpt-5-mini"
    """)

    assert {:ok, [{"alpha", %{"url" => _url}}, {"zeta", %{"command" => "sh"}}]} =
             ImportSources.servers(source("codex"), home)
  end

  test "a missing file, an empty one, and one without servers hold none", %{home: home} do
    assert ImportSources.servers(source("cursor"), home) == {:ok, []}

    write!(home, "cursor", "  \n")
    assert ImportSources.servers(source("cursor"), home) == {:ok, []}

    write!(home, "claude_desktop", ~s({"globalShortcut": "Cmd+Space"}))
    assert ImportSources.servers(source("claude_desktop"), home) == {:ok, []}

    write!(home, "codex", ~s(model = "gpt-5"\n))
    assert ImportSources.servers(source("codex"), home) == {:ok, []}
  end

  # A file may hold keys, so a sentence never quotes it.
  test "a file that cannot be read says so in one sentence, and quotes none of it", %{home: home} do
    write!(home, "cursor", ~s({"mcpServers": {"a": {"env": {"KEY": "sk-live-secret"}},}))

    assert ImportSources.servers(source("cursor"), home) ==
             {:error, "Cursor's settings file is not valid JSON."}

    write!(home, "codex", "[mcp_servers.a\ncommand = 'sk-live-secret'")

    assert ImportSources.servers(source("codex"), home) ==
             {:error, "Codex's settings file is not valid TOML."}

    write!(home, "windsurf", ~s({"mcpServers": ["sk-live-secret"]}))

    assert ImportSources.servers(source("windsurf"), home) ==
             {:error,
              "Windsurf's settings file holds its MCP servers in a shape Fermix does not know."}

    write!(home, "vscode", ~s(["sk-live-secret"]))

    assert ImportSources.servers(source("vscode"), home) ==
             {:error,
              "VS Code's settings file holds its MCP servers in a shape Fermix does not know."}

    File.mkdir_p!(Path.join(home, source("claude_code").path))

    assert ImportSources.servers(source("claude_code"), home) ==
             {:error, "Fermix cannot open Claude Code's settings file."}
  end

  test "a file past the limit is refused without reading it whole", %{home: home} do
    write!(home, "claude_desktop", String.duplicate(" ", ImportSources.max_file_bytes() + 1))

    assert ImportSources.servers(source("claude_desktop"), home) ==
             {:error, "Claude Desktop's settings file is larger than Fermix reads."}

    write!(home, "claude_desktop", String.duplicate(" ", ImportSources.max_file_bytes()))
    assert ImportSources.servers(source("claude_desktop"), home) == {:ok, []}
  end
end
