defmodule FermixCore.Plugins.Dist.McpSourceTest do
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Dist.McpSource

  defp probe_ok do
    [
      find_executable: fn _cmd -> "/usr/bin/node" end,
      version_fetch: fn _cmd -> {:ok, "v20.11.1\n"} end
    ]
  end

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("mcp-source-home")
    checkout = FermixTestSupport.SafeRm.make_tmp_dir!("mcp-source-checkout")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])

    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      FermixTestSupport.SafeRm.rm_rf!(home)
      FermixTestSupport.SafeRm.rm_rf!(checkout)
    end)

    %{checkout: checkout, store: Path.join(home, "plugins")}
  end

  defp write_plugin(checkout, name, manifest_extra) do
    dir = Path.join(checkout, name)
    File.mkdir_p!(dir)

    manifest =
      Map.merge(
        %{
          "schema_version" => 2,
          "name" => name,
          "display_name" => name,
          "description" => "#{name} test plugin",
          "category" => "productivity",
          "version" => "1.0.0",
          "plugin_api" => 2,
          "auth" => %{"type" => "none"},
          "tools" => []
        },
        manifest_extra
      )

    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest))
    dir
  end

  defp obsidian_manifest do
    %{
      "runtime" => %{
        "kind" => "node",
        "min_version" => "20",
        "command" => "node",
        "args" => ["src/index.js"],
        "vendored" => false
      },
      "config" => [
        %{"key" => "OBSIDIAN_VAULT_PATH", "prompt" => "Path to your vault", "required" => true}
      ],
      "tools" => [
        %{
          "name" => "obsidian_search_notes",
          "description" => "Full-text search across the vault",
          "rail" => "mcp",
          "read_only" => true
        }
      ]
    }
  end

  defp enable(name, entry) do
    Application.put_env(:fermix_core, :plugins,
      enabled: [name],
      entries: %{name => entry}
    )
  end

  defp source_opts(ctx, probe \\ nil) do
    [registry: [dev_local: ctx.checkout, installed_root: ctx.store], probe: probe || probe_ok()]
  end

  test "materializes an enabled mcp plugin into a server spec", ctx do
    dir = write_plugin(ctx.checkout, "obsidian", obsidian_manifest())
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/index.js"), "// server")
    enable("obsidian", [{"OBSIDIAN_VAULT_PATH", "/tmp/vault"}])

    assert {:ok, [spec]} = McpSource.server_specs(source_opts(ctx))
    assert spec.name == "obsidian"
    assert spec.prefix == "obsidian_"
    assert spec.command == "node"
    assert spec.args == [Path.join(dir, "src/index.js")]
    assert spec.env == %{"OBSIDIAN_VAULT_PATH" => "/tmp/vault"}
    assert spec.pass_env == []
    assert spec.tools_overrides == %{}
    assert spec.cwd == dir
    assert spec.capability_metadata.plugin_owned? == true
    assert spec.capability_metadata.plugin == "obsidian"
    assert spec.capability_metadata.category == :plugin
  end

  test "non-path args and absolute args pass through unresolved", ctx do
    manifest =
      obsidian_manifest()
      |> put_in(["runtime", "args"], ["src/index.js", "--verbose", "/abs/path"])

    dir = write_plugin(ctx.checkout, "obsidian", manifest)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/index.js"), "// server")
    enable("obsidian", [{"OBSIDIAN_VAULT_PATH", "/tmp/vault"}])

    assert {:ok, [spec]} = McpSource.server_specs(source_opts(ctx))
    assert spec.args == [Path.join(dir, "src/index.js"), "--verbose", "/abs/path"]
  end

  test "vendored runtime resolves the command under bin/<target>/", ctx do
    manifest =
      obsidian_manifest()
      |> Map.delete("config")
      |> Map.put("runtime", %{"kind" => "binary", "command" => "vaultd", "vendored" => true})
      |> Map.put("tools", [
        %{"name" => "obsidian_read_note", "description" => "Read a note", "rail" => "mcp"}
      ])

    dir = write_plugin(ctx.checkout, "obsidian", manifest)
    vendored = Path.join([dir, "bin", "linux-x86_64", "vaultd"])
    File.mkdir_p!(Path.dirname(vendored))
    File.write!(vendored, "#!/bin/sh\n")
    File.chmod!(vendored, 0o755)
    enable("obsidian", [])

    assert {:ok, [spec]} = McpSource.server_specs(source_opts(ctx, target: "linux-x86_64"))
    assert spec.command == vendored
  end

  test "a disabled plugin yields no spec", ctx do
    write_plugin(ctx.checkout, "obsidian", obsidian_manifest())
    Application.put_env(:fermix_core, :plugins, enabled: [])

    assert {:ok, []} = McpSource.server_specs(source_opts(ctx))
  end

  test "an http-only plugin yields no spec", ctx do
    write_plugin(ctx.checkout, "notes", %{
      "tools" => [
        %{
          "name" => "notes_search",
          "description" => "Search notes",
          "rail" => "http",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "request" => %{"method" => "GET", "url" => "https://example.com/search"}
        }
      ]
    })

    enable("notes", [])

    assert {:ok, []} = McpSource.server_specs(source_opts(ctx))
  end

  test "a plugin whose host runtime probe fails yields no spec", ctx do
    dir = write_plugin(ctx.checkout, "obsidian", obsidian_manifest())
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/index.js"), "// server")
    enable("obsidian", [{"OBSIDIAN_VAULT_PATH", "/tmp/vault"}])

    probe = [
      find_executable: fn _cmd -> nil end,
      version_fetch: fn _cmd -> flunk("must not version-check a missing binary") end
    ]

    assert {:ok, []} = McpSource.server_specs(source_opts(ctx, probe))
  end

  test "a plugin missing a required config key yields no spec", ctx do
    dir = write_plugin(ctx.checkout, "obsidian", obsidian_manifest())
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/index.js"), "// server")
    enable("obsidian", [])

    assert {:ok, []} = McpSource.server_specs(source_opts(ctx))
  end
end
