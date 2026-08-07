defmodule FermixCore.Plugins.Dist.McpSourceTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Remote.Contract
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Plugins.Plugin

  @pat "eden_pat_canary_do_not_leak"

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
    secrets = Application.get_env(:fermix_core, :plugin_secrets)

    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      restore_secrets(secrets)
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
    assert spec.source_id == {:plugin, "obsidian"}
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

  describe "remote_spec/1" do
    setup do
      connect(profile: "retrieval", workspace: "ws_opaque_id", secret: @pat)
      :ok
    end

    test "materializes the source-qualified remote shape" do
      assert {:ok, spec} = McpSource.remote_spec(eden())

      assert spec.source_id == {:plugin, "eden"}
      assert spec.transport == :streamable_http
      assert spec.protocol_version == "2025-06-18"
      assert spec.base_url == "https://mcp.eden.so"
      assert spec.mcp_path == "/mcp"
      assert spec.auth_ref == %{type: :plugin_secret, plugin: "eden"}
      assert spec.name_mode == :preserve
      assert spec.selected_profile == "retrieval"

      assert spec.resource_scope == %{
               kind: :single_workspace,
               argument: "workspaceId",
               id: "ws_opaque_id"
             }

      assert spec.capability_metadata == %{
               plugin_owned?: true,
               plugin: "eden",
               category: :plugin
             }
    end

    # THE SEAM THAT BROKE: `McpSource` builds the spec and `Remote.Contract`
    # compiles it at server start, in different modules written at different
    # times. A key missing from one and required by the other is invisible to
    # both unit suites — it surfaced as the daemon refusing to boot
    # (`{:mcp_invalid_contract, "eden", {:invalid_remote_config, :budgets}}`),
    # because a failed child start cascades to application start. Round-trip
    # the two so the next omission fails here instead.
    test "the materialized spec compiles into a contract" do
      assert {:ok, spec} = McpSource.remote_spec(eden())
      assert {:ok, contract} = Contract.compile(spec)

      assert contract.source_id == {:plugin, "eden"}
      assert contract.selected_profile == "retrieval"
      assert contract.budgets.turn_calls == 20
      assert contract.budgets.turn_paginated_calls == 5
      assert contract.result_contract.success_field == "ok"
    end

    # A remote spec is not a process spec. The whole point of the two mutually
    # exclusive shapes is that nothing downstream has to ask which one it got.
    test "carries no process-shaped fields" do
      assert {:ok, spec} = McpSource.remote_spec(eden())

      for field <- [:command, :args, :env, :pass_env, :cwd, :prefix] do
        refute Map.has_key?(spec, field), "remote spec must not carry #{field}"
      end
    end

    test "the credential is nowhere in the materialized spec" do
      assert {:ok, spec} = McpSource.remote_spec(eden())

      refute inspect(spec, limit: :infinity) =~ @pat
    end

    test "allowed_tools is the selected profile's signed allowlist" do
      assert {:ok, spec} = McpSource.remote_spec(eden())

      assert Map.keys(spec.allowed_tools) |> Enum.sort() == ["eden_get_note", "eden_search"]

      assert spec.allowed_tools["eden_search"] == %{
               read_only: true,
               replay_safe: false,
               required_credential_scope: "read",
               descriptor_sha256: digest_hex("sha-search")
             }
    end

    test "a setup-only tool never enters the agent-facing allowlist" do
      assert {:ok, spec} = McpSource.remote_spec(eden())

      refute Map.has_key?(spec.allowed_tools, "eden_list_workspaces")
    end

    test "selecting capture widens the allowlist to the capture profile" do
      connect(profile: "capture", workspace: "ws_opaque_id", secret: @pat)

      assert {:ok, spec} = McpSource.remote_spec(eden())
      assert spec.selected_profile == "capture"
      assert "eden_create_note" in Map.keys(spec.allowed_tools)
    end

    test "no selection resolves to the signed default profile" do
      connect(workspace: "ws_opaque_id", secret: @pat)

      assert {:ok, spec} = McpSource.remote_spec(eden())
      assert spec.selected_profile == "retrieval"
    end

    test "a profile the manifest does not declare is invalid configuration" do
      connect(profile: "everything", workspace: "ws_opaque_id", secret: @pat)

      assert {:error, {:invalid_remote_config, {:access_profile, "everything"}}} =
               McpSource.remote_spec(eden())
    end

    test "startable requires the credential to exist" do
      connect(profile: "retrieval", workspace: "ws_opaque_id", secret: nil)

      assert {:error, {:needs_secret, "eden"}} = McpSource.remote_spec(eden())
    end

    test "startable requires a selected workspace" do
      connect(profile: "retrieval", secret: @pat)

      assert {:error, {:needs_workspace, "eden"}} = McpSource.remote_spec(eden())
    end

    test "a workspace id that is not bounded visible ASCII is refused" do
      connect(profile: "retrieval", workspace: "ws with space", secret: @pat)

      assert {:error, {:invalid_remote_config, {:workspace_id, "eden"}}} =
               McpSource.remote_spec(eden())
    end

    test "a half-local/half-remote runtime is refused" do
      plugin = eden(runtime_extra: %{"command" => "node"})

      assert {:error, {:invalid_remote_config, {:local_field, "command"}}} =
               McpSource.remote_spec(plugin)
    end

    test "a runtime that declares pass_env is refused" do
      plugin = eden(runtime_extra: %{"pass_env" => ["EDEN_TOKEN"]})

      assert {:error, {:invalid_remote_config, {:local_field, "pass_env"}}} =
               McpSource.remote_spec(plugin)
    end

    test "an unpinned protocol version is refused" do
      plugin = eden(runtime_extra: %{"protocol_version" => "2025-11-25"})

      assert {:error, {:invalid_remote_config, :protocol_version}} =
               McpSource.remote_spec(plugin)
    end

    test "a non-HTTPS endpoint is refused" do
      plugin = eden(runtime_extra: %{"base_url" => "http://mcp.eden.so"})

      assert {:error, {:invalid_remote_config, {:invalid_base_url, :scheme_not_https}}} =
               McpSource.remote_spec(plugin)
    end

    test "an auth block that is not bearer api_key is refused" do
      plugin = eden(auth: %{type: :oauth2, header: "Authorization", scheme: "Bearer"})

      assert {:error, {:invalid_remote_config, {:invalid_remote_auth, _detail}}} =
               McpSource.remote_spec(plugin)
    end

    test "remote?/1 distinguishes the two rails" do
      assert McpSource.remote?(eden())

      refute McpSource.remote?(%Plugin{
               eden()
               | runtime: %{"kind" => "node", "command" => "node"}
             })
    end
  end

  defp connect(opts) do
    entry =
      [
        {"workspace_id", Keyword.get(opts, :workspace)},
        {"access_profile", Keyword.get(opts, :profile)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Application.put_env(:fermix_core, :plugins, enabled: ["eden"], entries: %{"eden" => entry})

    case Keyword.get(opts, :secret) do
      nil -> Application.put_env(:fermix_core, :plugin_secrets, %{})
      secret -> Application.put_env(:fermix_core, :plugin_secrets, %{"eden" => secret})
    end
  end

  defp restore_secrets(nil), do: Application.delete_env(:fermix_core, :plugin_secrets)
  defp restore_secrets(value), do: Application.put_env(:fermix_core, :plugin_secrets, value)

  # The shape `Registry.decode_manifest/2` produces for a validated
  # plugin-api-3 remote manifest.
  defp eden(overrides \\ []) do
    runtime =
      Map.merge(
        %{
          "kind" => "remote_mcp",
          "transport" => "streamable_http",
          "protocol_version" => "2025-06-18",
          "base_url" => "https://mcp.eden.so",
          "mcp_path" => "/mcp",
          "tool_name_mode" => "preserve"
        },
        Keyword.get(overrides, :runtime_extra, %{})
      )

    %Plugin{
      schema_version: 2,
      name: "eden",
      display_name: "Eden",
      description: "Eden second brain",
      category: "productivity",
      version: "1.0.0",
      plugin_api: 3,
      runtime: runtime,
      default_enabled?: false,
      auth: Keyword.get(overrides, :auth, eden_auth()),
      tools: eden_tools(),
      skills: [],
      tool_profiles: eden_profiles(),
      setup_tools: ["eden_list_workspaces"],
      resource_scope: %{
        "kind" => "single_workspace",
        "discovery_tool" => "eden_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      # Required of every remote plugin-api-3 manifest by the registry, and by
      # `Contract.compile/1` at server start. The fixture builds the struct
      # directly, so it has to carry them explicitly or it models a manifest
      # the decoder would have refused.
      budgets: %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      result_contract: %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      path: "/nonexistent/eden/plugin.json"
    }
  end

  defp eden_auth do
    %{
      type: :api_key,
      provider: nil,
      account_mode: nil,
      scopes: [],
      key_name: "EDEN_PERSONAL_ACCESS_TOKEN",
      header: "Authorization",
      scheme: "Bearer",
      prompt: nil,
      help_url: nil,
      validation: nil
    }
  end

  defp eden_tools do
    [
      remote_tool("eden_search", true, "read", "sha-search"),
      remote_tool("eden_get_note", true, "read", "sha-get"),
      remote_tool("eden_create_note", false, "write", "sha-create"),
      remote_tool("eden_list_workspaces", true, "read", "sha-workspaces")
    ]
  end

  defp remote_tool(name, read_only?, scope, digest) do
    %{
      "name" => name,
      "description" => name,
      "rail" => "mcp",
      "read_only" => read_only?,
      "replay_safe" => false,
      "required_credential_scope" => scope,
      "descriptor_sha256" => digest_hex(digest)
    }
  end

  # The signed contract requires a real 64-hex digest, so the fixture expands
  # its readable label into one deterministically rather than carrying a shape
  # `Contract.compile/1` would (correctly) refuse.
  defp digest_hex(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)

  defp eden_profiles do
    [
      %{
        "name" => "retrieval",
        "display_name" => "Retrieval only",
        "default" => true,
        "required_credential_scope" => "read",
        "scope_visibility" => "none",
        "tools" => ["eden_search", "eden_get_note"]
      },
      %{
        "name" => "capture",
        "display_name" => "Retrieval and capture",
        "default" => false,
        "required_credential_scope" => "write",
        "scope_visibility" => "none",
        "tools" => ["eden_search", "eden_get_note", "eden_create_note"]
      }
    ]
  end
end
