defmodule Fermix.CLI.Doctor.PluginsCheckTest do
  @moduledoc """
  `fermix doctor`'s plugin check (M27 §7.8).

  Two invariants live here:

    * the live remote runtime status comes from the DAEMON, and a locally
      absent status table is reported as unknown — never inferred as `:ready`;
    * the check runs in the tree-less CLI world, so its host-runtime probe must
      resolve inline. The last describe block reproduces that world for real
      instead of trusting `mix test`'s booted supervision tree.

  Fixtures are written to a tmp `dev_local` root and loaded through the real
  manifest decoder, so a plugin here is the same `%Plugin{}` production builds.
  """

  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.CommandHost
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Dist.RuntimeProbe
  alias FermixCore.Plugins.Status, as: PluginStatus

  setup do
    previous_plugins = Application.get_env(:fermix_core, :plugins)
    previous_secrets = Application.get_env(:fermix_core, :plugin_secrets)
    dev_local = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-plugins-dev")
    installed_root = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-plugins-store")

    on_exit(fn ->
      restore_env(:plugins, previous_plugins)
      restore_env(:plugin_secrets, previous_secrets)
      FermixTestSupport.SafeRm.rm_rf!(dev_local)
      FermixTestSupport.SafeRm.rm_rf!(installed_root)
    end)

    %{dev_local: dev_local, installed_root: installed_root}
  end

  describe "plugins/1 — the static ladder" do
    test "no enabled plugin is a quiet ok", ctx do
      enable!(ctx, [])

      result = Checks.plugins(installed_root: ctx.installed_root, client: &refuse_client/1)

      assert result.name == "plugins"
      assert result.status == :ok
      assert result.detail =~ "none enabled"
    end

    test "an enabled name with no installed manifest fails", ctx do
      enable!(ctx, ["ghost"])

      result = Checks.plugins(installed_root: ctx.installed_root, client: &refuse_client/1)

      assert result.status == :fail
      assert result.detail =~ "ghost: not_installed"
    end

    test "a local mcp plugin whose host runtime is missing warns", ctx do
      write_plugin!(ctx, "localmcp", local_mcp_manifest("localmcp"))
      enable!(ctx, ["localmcp"])

      result = Checks.plugins(installed_root: ctx.installed_root, client: &refuse_client/1)

      assert result.status == :warn
      assert result.detail =~ "localmcp: missing_host_runtime"
    end

    # Only a remote source registers an owner in the daemon's status table, so a
    # host with no remote plugin must not pay for the socket round trip.
    test "a host with no remote plugin never asks the daemon", ctx do
      write_plugin!(ctx, "localmcp", local_mcp_manifest("localmcp"))
      enable!(ctx, ["localmcp"])

      result = Checks.plugins(installed_root: ctx.installed_root, client: &record_client/1)

      assert result.status == :warn
      refute_received {:daemon_request, _method}
    end
  end

  describe "plugins/1 — remote runtime status" do
    setup ctx do
      write_plugin!(ctx, "eden", remote_manifest("eden"))
      select_workspace!(ctx, ["eden"], "eden")
      :ok
    end

    test "a remote plugin with a credential but no chosen workspace warns", ctx do
      # The rung between :needs_secret and :ready — a token alone does not make a
      # remote plugin callable, and the operator needs to see which step is left.
      enable!(ctx, ["eden"])
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result = Checks.plugins(installed_root: ctx.installed_root, client: &down_client/1)

      assert result.status == :warn
      assert result.detail =~ "eden: needs_workspace"
    end

    test "a startable remote plugin with no daemon reports the static ladder plus the note",
         ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result = Checks.plugins(installed_root: ctx.installed_root, client: &down_client/1)

      assert result.status == :ok
      assert result.detail =~ "eden: ready"
      assert result.detail =~ "runtime status unavailable — daemon not running"
      # The whole point of §7.8: a locally absent status table is unknown, not
      # a live `:ready`.
      refute result.detail =~ "runtime ready"
    end

    test "a remote plugin missing its token warns and claims no runtime state", ctx do
      result = Checks.plugins(installed_root: ctx.installed_root, client: &down_client/1)

      assert result.status == :warn
      assert result.detail =~ "eden: needs_secret"
      assert result.detail =~ "runtime status unavailable — daemon not running"
      refute result.detail =~ "runtime ready"
    end

    test "a live ready runtime status is ok", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result =
        Checks.plugins(
          installed_root: ctx.installed_root,
          client: runtime_client([row("plugin:eden", "eden", "ready")])
        )

      assert result.status == :ok
      assert result.detail =~ "eden: ready (remote; runtime ready)"
    end

    test "a signed-contract mismatch fails even though the plugin is startable", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result =
        Checks.plugins(
          installed_root: ctx.installed_root,
          client: runtime_client([row("plugin:eden", "eden", "upstream_contract_mismatch")])
        )

      assert result.status == :fail
      assert result.detail =~ "eden: ready (remote; runtime upstream_contract_mismatch)"
    end

    test "a transient remote failure warns rather than fails", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result =
        Checks.plugins(
          installed_root: ctx.installed_root,
          client: runtime_client([row("plugin:eden", "eden", "remote_unreachable")])
        )

      assert result.status == :warn
      assert result.detail =~ "runtime remote_unreachable"
    end

    # Enabled, credentialed, and startable, but the daemon holds no owner for it:
    # a reload/restart away, and nothing else on the report would say so.
    test "a startable remote plugin the daemon never started warns", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result =
        Checks.plugins(
          installed_root: ctx.installed_root,
          client: runtime_client([])
        )

      assert result.status == :warn
      assert result.detail =~ "eden: ready (remote; no live client registered)"
      refute result.detail =~ "runtime ready"
    end

    # A reachable daemon that cannot answer is version skew or a broken build —
    # never silently read as "no remote plugins are connected".
    test "a daemon that cannot answer the op fails loud", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      client = fn "plugins_runtime_status" ->
        {:ok, %{"status" => "error", "reason" => "unknown method"}}
      end

      result = Checks.plugins(installed_root: ctx.installed_root, client: client)

      assert result.status == :fail
      assert result.detail =~ "runtime status query failed"
    end

    test "a socket error other than a down daemon fails loud", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      client = fn "plugins_runtime_status" -> {:error, :emsgsize} end
      result = Checks.plugins(installed_root: ctx.installed_root, client: client)

      assert result.status == :fail
      assert result.detail =~ "emsgsize"
    end

    # A row the daemon's serializer could not have produced means a skewed
    # build; rendering it would show a plugin whose runtime state is blank.
    test "a malformed row fails loud instead of rendering a blank runtime state", ctx do
      put_secret!("eden", "eden_pat_0123456789abcdef")

      result =
        Checks.plugins(
          installed_root: ctx.installed_root,
          client: runtime_client([%{"source" => "plugin:eden"}])
        )

      assert result.status == :fail
      assert result.detail =~ "malformed runtime_status rows"
    end
  end

  # `mix test` boots the supervision tree, so a supervised probe always finds its
  # CommandHost here and the tree-LESS world every `fermix doctor` / `fermix
  # plugins` verb actually runs in is unreachable by default. Terminating the
  # global host supervisor reproduces it — and with the real host module in
  # place, because the deny-by-default `HostRuntimeStub` never reaches
  # `CommandRunner` at all and so cannot observe the raise either.
  describe "plugins/1 — the tree-less CLI world" do
    setup ctx do
      previous_host = Application.get_env(:fermix_core, :runtime_probe_host)
      :ok = Supervisor.terminate_child(FermixCore.Supervisor, CommandHost.Supervisor)
      Application.put_env(:fermix_core, :runtime_probe_host, RuntimeProbe.Host.System)

      on_exit(fn ->
        restore_env(:runtime_probe_host, previous_host)
        {:ok, _pid} = Supervisor.restart_child(FermixCore.Supervisor, CommandHost.Supervisor)
      end)

      write_plugin!(ctx, "localmcp", local_mcp_manifest("localmcp"))
      enable!(ctx, ["localmcp"])
      :ok
    end

    test "probes unsupervised instead of aborting the whole doctor verb", ctx do
      # Control: the daemon-shaped call is what raises, so the world really is
      # tree-less and the check's `supervised: false` threading is load-bearing.
      assert_raise RuntimeError, ~r/command host supervisor/, fn ->
        PluginStatus.status("localmcp", probe: [], installed_root: ctx.installed_root)
      end

      result = Checks.plugins(installed_root: ctx.installed_root, client: &refuse_client/1)

      assert result.name == "plugins"
      assert result.status in [:ok, :warn]
      assert result.detail =~ "localmcp:"
    end
  end

  # --- fixtures -----------------------------------------------------------

  defp enable!(ctx, names) do
    Application.put_env(:fermix_core, :plugins, enabled: names, dev_local: ctx.dev_local)
  end

  # A remote plugin with a credential but no chosen resource is `:needs_workspace`
  # (§7.8), so a fixture that means to exercise the READY path has to persist the
  # selection too — otherwise the check reports the earlier rung and the test is
  # asserting against a plugin that legitimately is not ready.
  defp select_workspace!(ctx, names, name) do
    Application.put_env(:fermix_core, :plugins,
      enabled: names,
      dev_local: ctx.dev_local,
      entries: %{
        name => [
          access_profile: "retrieval",
          workspace_id: "ws-fixture",
          workspace_label: "Fixture"
        ]
      }
    )
  end

  defp put_secret!(name, secret) do
    Application.put_env(:fermix_core, :plugin_secrets, %{name => secret})
  end

  defp write_plugin!(ctx, name, manifest) do
    dir = Path.join(ctx.dev_local, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest))
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  defp refuse_client(method) do
    flunk("the plugin check must not reach the daemon here, but asked for #{method}")
  end

  defp record_client(method) do
    send(self(), {:daemon_request, method})
    {:error, :not_running}
  end

  defp down_client("plugins_runtime_status"), do: {:error, :not_running}

  defp runtime_client(rows) do
    fn "plugins_runtime_status" -> {:ok, %{"status" => "ok", "runtime_status" => rows}} end
  end

  defp row(source, plugin, status) do
    %{
      "source" => source,
      "plugin" => plugin,
      "status" => status,
      "detail" => nil,
      "updated_at" => 1
    }
  end

  # A stdio mcp-rail plugin: `runtime.command` is a bare on-PATH executable, so
  # the tree-less block above reaches `CommandRunner` for its `--version` probe.
  # `echo --version` prints its argument and exits 0 on every supported host —
  # no host state is touched and the version never parses, so the probe verdict
  # is the same everywhere.
  defp local_mcp_manifest(name) do
    %{
      "schema_version" => 2,
      "plugin_api" => 2,
      "min_core_version" => "0.4.0",
      "name" => name,
      "display_name" => "Local MCP",
      "description" => "A local stdio mcp-rail plugin fixture.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{"type" => "none"},
      "runtime" => %{"kind" => "node", "command" => "echo", "min_version" => "20.0.0"},
      "tools" => [%{"name" => "#{name}_read", "description" => "Read.", "rail" => "mcp"}],
      "skills" => []
    }
  end

  defp remote_manifest(name) do
    %{
      "schema_version" => 2,
      "plugin_api" => 3,
      "min_core_version" => "0.4.0",
      "name" => name,
      "display_name" => "Eden",
      "description" => "A remote MCP plugin fixture.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{
        "type" => "api_key",
        "key_name" => "EDEN_PERSONAL_ACCESS_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste an Eden personal access token"
      },
      "runtime" => %{
        "kind" => "remote_mcp",
        "transport" => "streamable_http",
        "protocol_version" => "2025-06-18",
        "base_url" => "https://mcp.eden.so",
        "mcp_path" => "/mcp",
        "tool_name_mode" => "preserve"
      },
      "tool_profiles" => [
        %{
          "name" => "retrieval",
          "display_name" => "Retrieval only",
          "default" => true,
          "required_credential_scope" => "read",
          "scope_visibility" => "none",
          "tools" => ["eden_search"]
        }
      ],
      "setup_tools" => ["eden_list_workspaces"],
      "resource_scope" => %{
        "kind" => "single_workspace",
        "discovery_tool" => "eden_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      "budgets" => %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      "result_contract" => %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      "tools" => [workspaces_tool(), search_tool()],
      "skills" => []
    }
  end

  defp workspaces_tool do
    sign(%{
      "name" => "eden_list_workspaces",
      "description" => "List Eden workspaces available to the connected token.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => false,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{"type" => "object", "properties" => %{}},
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp search_tool do
    sign(%{
      "name" => "eden_search",
      "description" => "Search an Eden workspace.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => true,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "query" => %{"type" => "string"}
        },
        "required" => ["workspaceId", "query"]
      },
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  # Recompute `descriptor_sha256` exactly as the validator does, so the fixture
  # is self-consistent by construction.
  defp sign(tool) do
    {:ok, digest} =
      CanonicalJson.descriptor_digest(
        Map.fetch!(tool, "name"),
        Map.fetch!(tool, "parameters"),
        Map.get(tool, "output_schema"),
        Map.get(tool, "upstream_annotations")
      )

    Map.put(tool, "descriptor_sha256", digest)
  end
end
