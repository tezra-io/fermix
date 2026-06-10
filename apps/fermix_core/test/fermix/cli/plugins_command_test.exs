defmodule Fermix.CLI.PluginsCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.PluginsCommand
  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Runtime
  alias FermixTestSupport.DistFetcherStub
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.DistVerifierStub

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugins-command")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :oauth, %{})
    _ = Runtime.reload()

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)

      CapabilityRegistry.unregister_kind(CapabilityRegistry, :builtin,
        metadata: %{plugin_owned?: true}
      )

      _ = Runtime.reload()
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "catalog emits plugin metadata as json" do
    output =
      capture_io(fn ->
        assert PluginsCommand.run(["catalog", "--json"]) == 0
      end)

    assert %{"plugins" => plugins} = Jason.decode!(output)
    assert Enum.any?(plugins, &(&1["name"] == "google_calendar"))
    assert Enum.any?(plugins, &(&1["name"] == "gmail"))
    assert Enum.any?(plugins, &(&1["name"] == "google_drive"))
    refute Enum.any?(plugins, &(&1["name"] == "weather"))
  end

  test "enable and disable persist plugin config", %{home: home} do
    stderr =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            assert PluginsCommand.run(["enable", "google_drive"]) == 0
          end)

        assert output =~ "enabled google_drive"

        assert "google_drive" in Keyword.get(
                 Application.get_env(:fermix_core, :plugins),
                 :enabled
               )

        output =
          capture_io(fn ->
            assert PluginsCommand.run(["disable", "google_drive"]) == 0
          end)

        assert output =~ "disabled google_drive"
        assert Keyword.get(Application.get_env(:fermix_core, :plugins), :enabled) == []
      end)

    # No daemon is listening in tests — the CLI must say so out loud.
    assert stderr =~ "daemon not running — changes apply on next start"

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.plugins.google_drive]"
    assert contents =~ "enabled = false"
  end

  test "reload refreshes plugin-owned capabilities" do
    :ok =
      CapabilityRegistry.unregister_kind(CapabilityRegistry, :builtin,
        metadata: %{plugin_owned?: true}
      )

    Application.put_env(:fermix_core, :plugins,
      enabled: ["google_calendar"],
      entries: %{
        "google_calendar" => [auth_profile: "google_calendar:primary"]
      }
    )

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_id: "123.apps.googleusercontent.com", client_secret: "desktop-secret"]
    })

    :ok =
      Store.write("google_calendar:primary", %{
        auth_mode: "oauth2",
        provider: "google",
        account: %{email: "suj@example.com"},
        granted_scopes: [
          "openid",
          "email",
          "profile",
          "https://www.googleapis.com/auth/calendar.readonly"
        ],
        tokens: %{access_token: "AT", refresh_token: "RT"},
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        last_refresh: DateTime.utc_now(),
        status: "ready"
      })

    assert :error = CapabilityRegistry.find("google_calendar_search_events")

    output =
      capture_io(fn ->
        assert PluginsCommand.run(["reload"]) == 0
      end)

    assert output =~ "plugins reloaded"
    assert {:ok, capability} = CapabilityRegistry.find("google_calendar_search_events")
    assert capability.metadata[:plugin] == "google_calendar"
  end

  test "auth status reports missing local account" do
    output =
      capture_io(fn ->
        assert PluginsCommand.run(["auth", "status", "google_calendar"]) == 0
      end)

    assert output =~ "google_calendar"
    assert output =~ "missing"
  end

  describe "dist verbs" do
    setup %{home: home} do
      fixtures = Path.join(home, "fixtures")
      File.mkdir_p!(fixtures)
      DistFetcherStub.init()
      DistVerifierStub.init()
      previous = Application.get_env(:fermix_core, :plugins_dist_opts)

      seed = Path.join(fixtures, "index.json")

      Application.put_env(:fermix_core, :plugins_dist_opts,
        fetcher: DistFetcherStub,
        verifier: DistVerifierStub,
        core_version: "0.5.0",
        target: "any",
        index_opts: [seed_path: seed],
        lock_opts: [attempts: 20, delay_ms: 2]
      )

      on_exit(fn ->
        DistFetcherStub.cleanup()
        DistVerifierStub.cleanup()
        restore_dist_opts(previous)
      end)

      %{fixtures: fixtures, seed: seed, plugins_root: Path.join(home, "plugins")}
    end

    test "install resolves, installs, and activates from the index", ctx do
      wire_index(ctx, "github", "1.2.0")
      DistVerifierStub.allow("github", "1.2.0")

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["install", "github"]) == 0
        end)

      assert output =~ "installed github"
      assert DistStore.active_version(ctx.plugins_root, "github") == "1.2.0"
    end

    test "install NAME@VERSION fails loud on an unknown version", ctx do
      wire_index(ctx, "github", "1.2.0")

      stderr =
        capture_io(:stderr, fn ->
          assert PluginsCommand.run(["install", "github@9.9.9"]) == 1
        end)

      assert stderr =~ "version_not_found"
      refute DistStore.active_version(ctx.plugins_root, "github")
    end

    test "installed lists store entries as json", ctx do
      wire_index(ctx, "github", "1.2.0")
      DistVerifierStub.allow("github", "1.2.0")
      capture_io(fn -> assert PluginsCommand.run(["install", "github"]) == 0 end)

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["installed", "--json"]) == 0
        end)

      assert %{"installed" => [row]} = Jason.decode!(output)
      assert row["name"] == "github"
      assert row["version"] == "1.2.0"
      assert row["status"] == "ready"
    end

    test "enable auto-installs an uninstalled catalog plugin, loud about the daemon", ctx do
      wire_index(ctx, "github", "1.2.0")
      DistVerifierStub.allow("github", "1.2.0")

      stderr =
        capture_io(:stderr, fn ->
          output =
            capture_io(fn ->
              assert PluginsCommand.run(["enable", "github"]) == 0
            end)

          assert output =~ "enabled github"
        end)

      assert stderr =~ "daemon not running — changes apply on next start"
      assert DistStore.active_version(ctx.plugins_root, "github") == "1.2.0"
      assert "github" in Keyword.get(Application.get_env(:fermix_core, :plugins), :enabled)
    end

    test "uninstall disables an enabled plugin and clears the store", ctx do
      wire_index(ctx, "github", "1.2.0")
      DistVerifierStub.allow("github", "1.2.0")

      capture_io(:stderr, fn ->
        capture_io(fn -> assert PluginsCommand.run(["enable", "github"]) == 0 end)

        output =
          capture_io(fn ->
            assert PluginsCommand.run(["uninstall", "github"]) == 0
          end)

        assert output =~ "uninstalled github"
      end)

      refute DistStore.active_version(ctx.plugins_root, "github")
      assert DistStore.installed(ctx.plugins_root) == %{}
      refute "github" in Keyword.get(Application.get_env(:fermix_core, :plugins), :enabled, [])
    end

    test "uninstall refuses a bundled plugin and points at disable", ctx do
      _ = ctx

      stderr =
        capture_io(:stderr, fn ->
          assert PluginsCommand.run(["uninstall", "gmail"]) == 1
        end)

      assert stderr =~ "bundled"
      assert stderr =~ "disable"
    end

    test "upgrade moves to the index's latest and is idempotent", ctx do
      p1 = wire_index(ctx, "github", "1.2.0")
      DistVerifierStub.allow("github", "1.2.0")
      capture_io(fn -> assert PluginsCommand.run(["install", "github"]) == 0 end)

      {tgz2, sha2} = DistFixtures.build_tarball(ctx.fixtures, "github", "1.3.0")
      p2 = DistFixtures.wire(ctx.fixtures, "github", "1.3.0", tgz2, sha2, latest: "1.3.0")
      merged = %{p2 | "versions" => p2["versions"] ++ p1["versions"]}
      DistFixtures.write_index(ctx.seed, [merged])
      DistVerifierStub.allow("github", "1.3.0")

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["upgrade", "github"]) == 0
        end)

      assert output =~ "upgraded github"
      assert DistStore.active_version(ctx.plugins_root, "github") == "1.3.0"

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["upgrade", "github"]) == 0
        end)

      assert output =~ "github already up to date"
    end

    test "pin requires NAME@VERSION and activates the exact version", ctx do
      wire_index(ctx, "github", "1.2.0")
      DistVerifierStub.allow("github", "1.2.0")

      stderr =
        capture_io(:stderr, fn ->
          assert PluginsCommand.run(["pin", "github"]) == 1
        end)

      assert stderr =~ "NAME@VERSION"

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["pin", "github@1.2.0"]) == 0
        end)

      assert output =~ "pinned github at 1.2.0"
      assert DistStore.active_version(ctx.plugins_root, "github") == "1.2.0"
    end

    test "gc exits clean", ctx do
      _ = ctx

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["gc"]) == 0
        end)

      assert output =~ "gc complete"
    end

    test "config set persists a declared key and config prints it", ctx do
      install_config_plugin(ctx)

      stderr =
        capture_io(:stderr, fn ->
          output =
            capture_io(fn ->
              assert PluginsCommand.run([
                       "config",
                       "set",
                       "vaultdemo",
                       "DEMO_VAULT_PATH",
                       "/tmp/demo-vault"
                     ]) == 0
            end)

          assert output =~ "set vaultdemo DEMO_VAULT_PATH"
        end)

      assert stderr =~ "daemon not running — changes apply on next start"

      output =
        capture_io(fn ->
          assert PluginsCommand.run(["config", "vaultdemo", "--json"]) == 0
        end)

      assert %{"plugin" => "vaultdemo", "config" => [row]} = Jason.decode!(output)

      assert row == %{
               "key" => "DEMO_VAULT_PATH",
               "prompt" => "Path to your vault",
               "required" => true,
               "value" => "/tmp/demo-vault"
             }

      plain =
        capture_io(fn ->
          assert PluginsCommand.run(["config", "vaultdemo"]) == 0
        end)

      assert plain =~ "DEMO_VAULT_PATH"
      assert plain =~ "/tmp/demo-vault"
      assert plain =~ "required"
    end

    test "config set refuses an undeclared key and an unknown plugin", ctx do
      install_config_plugin(ctx)

      stderr =
        capture_io(:stderr, fn ->
          assert PluginsCommand.run(["config", "set", "vaultdemo", "NOT_DECLARED", "x"]) == 1
        end)

      assert stderr =~ "NOT_DECLARED"
      assert stderr =~ "does not declare"

      stderr =
        capture_io(:stderr, fn ->
          assert PluginsCommand.run(["config", "set", "ghost", "SOME_KEY", "x"]) == 1
        end)

      assert stderr =~ "ghost"
    end
  end

  # An mcp-ish plugin whose manifest declares a `config` block, installed
  # through the dist seam so `Registry.find` resolves it.
  defp install_config_plugin(ctx) do
    wire_index(ctx, "vaultdemo", "1.0.0",
      manifest_extra: %{
        "config" => [
          %{"key" => "DEMO_VAULT_PATH", "prompt" => "Path to your vault", "required" => true}
        ]
      }
    )

    DistVerifierStub.allow("vaultdemo", "1.0.0")
    capture_io(fn -> assert PluginsCommand.run(["install", "vaultdemo"]) == 0 end)
  end

  # Build + wire a one-plugin catalog into the seed file the CLI reads
  # through the :index_opts seam (seed-only — there is no cache).
  defp wire_index(ctx, name, version, opts \\ []) do
    {tgz, sha} = DistFixtures.build_tarball(ctx.fixtures, name, version, opts)
    plugin = DistFixtures.wire(ctx.fixtures, name, version, tgz, sha, opts)
    DistFixtures.write_index(ctx.seed, [plugin])
    plugin
  end

  defp restore_dist_opts(nil), do: Application.delete_env(:fermix_core, :plugins_dist_opts)

  defp restore_dist_opts(value),
    do: Application.put_env(:fermix_core, :plugins_dist_opts, value)
end
