defmodule FermixCore.Plugins.Dist.InstallerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Dist.Installer
  alias FermixCore.Plugins.Dist.Store
  alias FermixTestSupport.DistFetcherStub
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.DistVerifierStub

  @core "0.5.0"

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-dist-installer")
    fixtures = Path.join(root, "fixtures")
    File.mkdir_p!(fixtures)
    Store.ensure!(root)
    DistFetcherStub.init()
    DistVerifierStub.init()

    on_exit(fn ->
      DistFetcherStub.cleanup()
      DistVerifierStub.cleanup()
      FermixTestSupport.SafeRm.rm_rf(root)
    end)

    %{root: root, fixtures: fixtures}
  end

  # Thin wrappers over the shared fixtures (`FermixTestSupport.DistFixtures`):
  # `wire` writes the index into this suite's fixtures dir and returns its path.
  defp build_tarball(fixtures, name, version, opts \\ []),
    do: DistFixtures.build_tarball(fixtures, name, version, opts)

  defp wire(ctx, name, version, tgz, sha, opts \\ []) do
    plugin = DistFixtures.wire(ctx.fixtures, name, version, tgz, sha, opts)
    DistFixtures.write_index(Path.join(ctx.fixtures, "index.json"), [plugin])
  end

  defp install_opts(ctx, idx, extra \\ []) do
    Keyword.merge(
      [
        root: ctx.root,
        fetcher: DistFetcherStub,
        verifier: DistVerifierStub,
        index_opts: [seed_path: idx],
        core_version: @core,
        target: "any",
        lock_opts: [attempts: 20, delay_ms: 2]
      ],
      extra
    )
  end

  describe "run_install/2 happy path" do
    test "downloads, verifies, extracts, activates, and records the lockfile", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:ok, :installed} = Installer.run_install("github", install_opts(ctx, idx))

      assert Store.active_version(ctx.root, "github") == "1.2.0"

      assert File.exists?(
               Path.join(Store.version_dir(ctx.root, "github", "1.2.0"), "plugin.json")
             )

      entry = Map.fetch!(Store.installed(ctx.root), "github")
      assert entry["version"] == "1.2.0"
      assert entry["sha256"] == sha
      assert is_binary(entry["h1"]) and byte_size(entry["h1"]) == 64
      assert entry["plugin_api"] == 2
      assert entry["min_core_version"] == "0.1.0"
    end

    test "a second install of the same version is a no-op (already_installed)", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:ok, :installed} = Installer.run_install("github", install_opts(ctx, idx))
      assert {:ok, :already_installed} = Installer.run_install("github", install_opts(ctx, idx))
      assert Store.active_version(ctx.root, "github") == "1.2.0"
    end
  end

  describe "run_install/2 integrity gate (default-deny verifier is the payoff)" do
    test "refuses when the verifier denies (stub default-deny, no allow/2)", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      # NOTE: no DistVerifierStub.allow/2 — the gate must fail closed.

      assert {:error, {:verification_failed, {:verification_denied, {"github", "1.2.0"}}}} =
               Installer.run_install("github", install_opts(ctx, idx))

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "github"))
      assert Store.installed(ctx.root) == %{}
    end

    test "refuses on a sha256 mismatch before verifying", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha, index_sha: String.duplicate("0", 64))
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error, {:sha256_mismatch, _}} =
               Installer.run_install("github", install_opts(ctx, idx))

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "github"))
    end
  end

  describe "run_install/2 resolution + compat gates" do
    test "unknown plugin", ctx do
      idx =
        wire(ctx, "github", "1.2.0", elem(build_tarball(ctx.fixtures, "github", "1.2.0"), 0), "x")

      assert {:error, {:unknown_plugin, "nope"}} =
               Installer.run_install("nope", install_opts(ctx, idx))
    end

    test "version not found", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)

      assert {:error, {:version_not_found, "github", "9.9.9"}} =
               Installer.run_install("github", install_opts(ctx, idx, version: "9.9.9"))
    end

    test "yanked version", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha, yanked: ["1.2.0"])

      assert {:error, {:yanked, "github", "1.2.0"}} =
               Installer.run_install("github", install_opts(ctx, idx))
    end

    test "incompatible plugin_api refuses with a specific reason", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha, plugin_api: 3)

      assert {:error, {:incompatible, {:needs_newer_core, :plugin_api, 3}}} =
               Installer.run_install("github", install_opts(ctx, idx))
    end

    test "no build for the host target", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha, target: "linux-aarch64")
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error, {:no_build_for_target, "macos-x86_64"}} =
               Installer.run_install("github", install_opts(ctx, idx, target: "macos-x86_64"))
    end
  end

  describe "run_install/2 artifact validation" do
    test "refuses a content-boundary violation (foreign top-level dir)", ctx do
      {tgz, sha} =
        build_tarball(ctx.fixtures, "github", "1.2.0",
          extra_members: [{~c"apps/leak.ex", "pwned"}]
        )

      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error, {:content_boundary_violation, "apps"}} =
               Installer.run_install("github", install_opts(ctx, idx))

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "github"))
    end

    test "refuses a manifest whose name does not match the request", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0", manifest_name: "evil")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error, {:manifest_name_mismatch, "evil", "github"}} =
               Installer.run_install("github", install_opts(ctx, idx))
    end

    test "refuses a tool whose request template has an undeclared placeholder", ctx do
      tools = [
        %{
          "name" => "github_list",
          "description" => "List repositories",
          "rail" => "http",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"owner" => %{"type" => "string"}}
          },
          "request" => %{
            "method" => "GET",
            "url" => "https://api.github.com/{owner}/{undeclared}"
          }
        }
      ]

      {tgz, sha} =
        build_tarball(ctx.fixtures, "github", "1.2.0", manifest_extra: %{"tools" => tools})

      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error,
              {:invalid_tool_template, "github_list", {:undeclared_placeholder, "undeclared"}}} =
               Installer.run_install("github", install_opts(ctx, idx))

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "github"))
    end

    test "refuses a manifest the registry would reject at load time", ctx do
      # Single validation authority: a manifest missing a required field must
      # fail at install, never after activation (where it would brick
      # `Registry.list/1`).
      {tgz, sha} =
        build_tarball(ctx.fixtures, "github", "1.2.0", manifest_extra: %{"display_name" => ""})

      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error, {:invalid_manifest, _path, _message}} =
               Installer.run_install("github", install_opts(ctx, idx))

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "github"))
    end

    test "refuses when a declared interface asset is missing from the artifact", ctx do
      extra = %{"interface" => %{"logo" => "assets/logo.png"}}
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0", manifest_extra: extra)
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:error, {:missing_asset, missing_path}} =
               Installer.run_install("github", install_opts(ctx, idx))

      assert String.ends_with?(missing_path, "assets/logo.png")
    end
  end

  describe "run_install/2 host-runtime probe (mcp plugins)" do
    @mcp_manifest_extra %{
      "runtime" => %{
        "kind" => "node",
        "min_version" => "20",
        "command" => "node",
        "args" => ["src/index.js"],
        "vendored" => false
      },
      "tools" => [
        %{"name" => "vault_search", "description" => "Search the vault", "rail" => "mcp"}
      ]
    }

    test "refuses an mcp plugin whose host runtime probe fails", ctx do
      {tgz, sha} =
        build_tarball(ctx.fixtures, "vault", "1.0.0", manifest_extra: @mcp_manifest_extra)

      idx = wire(ctx, "vault", "1.0.0", tgz, sha)
      DistVerifierStub.allow("vault", "1.0.0")

      assert {:error, {:missing_host_runtime, "node", "20"}} =
               Installer.run_install(
                 "vault",
                 install_opts(ctx, idx, probe_opts: [find_executable: fn _cmd -> nil end])
               )

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "vault"))
      assert Store.installed(ctx.root) == %{}
    end

    test "installs an mcp plugin when the probe passes", ctx do
      {tgz, sha} =
        build_tarball(ctx.fixtures, "vault", "1.0.0", manifest_extra: @mcp_manifest_extra)

      idx = wire(ctx, "vault", "1.0.0", tgz, sha)
      DistVerifierStub.allow("vault", "1.0.0")

      probe_opts = [
        find_executable: fn "node" -> "/usr/bin/node" end,
        version_fetch: fn _cmd -> {:ok, "v20.11.1\n"} end
      ]

      assert {:ok, :installed} =
               Installer.run_install("vault", install_opts(ctx, idx, probe_opts: probe_opts))

      assert Store.active_version(ctx.root, "vault") == "1.0.0"
    end
  end

  describe "crash recovery" do
    test "re-install heals a partial state (version dir present, no current symlink)", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      # simulate a crash mid-install_tree: version dir exists, current missing, no lockfile entry
      File.mkdir_p!(Store.version_dir(ctx.root, "github", "1.2.0"))
      File.write!(Path.join(Store.version_dir(ctx.root, "github", "1.2.0"), "stale"), "x")
      refute Store.active_version(ctx.root, "github")

      assert {:ok, :installed} = Installer.run_install("github", install_opts(ctx, idx))
      assert Store.active_version(ctx.root, "github") == "1.2.0"

      assert File.exists?(
               Path.join(Store.version_dir(ctx.root, "github", "1.2.0"), "plugin.json")
             )

      refute File.exists?(Path.join(Store.version_dir(ctx.root, "github", "1.2.0"), "stale"))
    end

    test "re-install heals a missing version dir even when the lockfile entry persists", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      # simulate a force-reinstall crash: a prior install's lockfile entry
      # survives (version + sha match) but the version dir is gone.
      Store.record(ctx.root, "github", %{"version" => "1.2.0", "sha256" => sha})
      refute File.dir?(Store.version_dir(ctx.root, "github", "1.2.0"))

      # already_installed? must NOT short-circuit to activate (which would make
      # `current` a void symlink) — it re-runs the pipeline and heals.
      assert {:ok, :installed} = Installer.run_install("github", install_opts(ctx, idx))
      assert Store.active_version(ctx.root, "github") == "1.2.0"
      assert File.dir?(Store.version_dir(ctx.root, "github", "1.2.0"))
    end
  end

  describe "concurrency (cross-VM lock serializes)" do
    test "two concurrent installs settle to one :installed and one :already_installed", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")
      opts = install_opts(ctx, idx, lock_opts: [attempts: 200, delay_ms: 5])

      results =
        [
          Task.async(fn -> Installer.run_install("github", opts) end),
          Task.async(fn -> Installer.run_install("github", opts) end)
        ]
        |> Enum.map(&Task.await(&1, 5_000))
        |> Enum.sort()

      assert results == [ok: :already_installed, ok: :installed]
      assert Store.active_version(ctx.root, "github") == "1.2.0"
    end
  end

  describe "GenServer boot hygiene" do
    test "init sweeps staging leftovers and run tokens", ctx do
      staging_junk = Path.join(Store.paths(ctx.root).staging, "crashed-1.0.0")
      File.mkdir_p!(staging_junk)
      File.write!(Path.join(staging_junk, "artifact.tgz"), "junk")
      token = Path.join(Store.paths(ctx.root).run, "github.token")
      File.write!(token, "tok")

      start_supervised!({Installer, [root: ctx.root, name: :test_boot_installer]})

      refute File.exists?(staging_junk)
      refute File.exists?(token)
    end

    test "init skips the sweep when another VM holds the store lock", ctx do
      staging_junk = Path.join(Store.paths(ctx.root).staging, "live-install")
      File.mkdir_p!(staging_junk)
      File.write!(Store.paths(ctx.root).lock, "held\n")

      start_supervised!({Installer, [root: ctx.root, name: :test_busy_installer]})

      assert File.exists?(staging_junk)
      FermixTestSupport.SafeRm.rm!(Store.paths(ctx.root).lock)
    end
  end

  describe "bundled-name refusal" do
    test "refuses to install a name that ships bundled with this build", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)

      assert {:error, {:bundled_plugin, "gmail"}} =
               Installer.run_install("gmail", install_opts(ctx, idx))

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "gmail"))
    end
  end

  describe "telemetry ([:fermix, :plugin, :dist])" do
    setup do
      handler = "dist-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:fermix, :plugin, :dist],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:dist_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "install emits op/plugin/version/result with a duration", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")

      assert {:ok, :installed} = Installer.run_install("github", install_opts(ctx, idx))

      assert_receive {:dist_event, %{duration_ms: duration}, metadata}
      assert is_integer(duration) and duration >= 0
      assert %{op: :install, plugin: "github", version: "1.2.0", result: :installed} = metadata
    end

    test "a failed install emits result: :error with the reason", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      # no DistVerifierStub.allow/2 — verification fails

      assert {:error, _reason} = Installer.run_install("github", install_opts(ctx, idx))

      assert_receive {:dist_event, _measurements, metadata}
      assert %{op: :install, plugin: "github", result: :error} = metadata
      assert {:verification_failed, _} = metadata.reason
    end

    test "uninstall emits op: :uninstall", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")
      Installer.run_install("github", install_opts(ctx, idx))
      assert_receive {:dist_event, _, %{op: :install}}

      assert :ok =
               Installer.run_uninstall("github",
                 root: ctx.root,
                 lock_opts: [attempts: 20, delay_ms: 2]
               )

      assert_receive {:dist_event, _measurements, metadata}
      assert %{op: :uninstall, plugin: "github", result: :ok} = metadata
    end
  end

  describe "run_uninstall/2" do
    test "removes an installed plugin", ctx do
      {tgz, sha} = build_tarball(ctx.fixtures, "github", "1.2.0")
      idx = wire(ctx, "github", "1.2.0", tgz, sha)
      DistVerifierStub.allow("github", "1.2.0")
      Installer.run_install("github", install_opts(ctx, idx))

      assert :ok =
               Installer.run_uninstall("github",
                 root: ctx.root,
                 lock_opts: [attempts: 20, delay_ms: 2]
               )

      refute File.exists?(Path.join(Store.paths(ctx.root).installed, "github"))
      assert Store.installed(ctx.root) == %{}
    end
  end
end
