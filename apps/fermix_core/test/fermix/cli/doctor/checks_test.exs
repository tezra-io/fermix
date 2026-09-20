defmodule Fermix.CLI.Doctor.ChecksTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.Acp.Identity
  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Setup.ConfigStore

  # Published NIP-19 vector (derived in nostr/key_test.exs). The nsec is here so
  # the doctor assertions can prove key material never reaches an operator row.
  @identity_nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @identity_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
  @identity_npub "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

  # The origin `Fermix.CLI.Upgrade.Manifest` pins artifact URLs to — the exact
  # base `scripts/release/build_releases_json.sh` emits. An off-origin fixture is
  # refused at parse time, which downgrades every integrity verdict below to a
  # "could not fetch manifest" warn: the checks would go green on a manifest
  # nobody parsed instead of on the sha comparison they exist to make.
  @release_base "https://github.com/tezra-io/fermix/releases/download/v1.0.0"

  defmodule AppBuildInfo do
    def app_engine?, do: true
    def linux_package?, do: false
  end

  defmodule PackagedBuildInfo do
    def app_engine?, do: false
    def linux_package?, do: true

    def public_identity do
      %{
        "engine_id" => "fermix-core",
        "product_version" => "1.2.3",
        "build_id" => "release-9",
        "source_commit" => String.duplicate("a", 40),
        "distribution_identity" => "linux_package",
        "artifact_target" => "linux_x86_64",
        "architecture" => "x86_64"
      }
    end
  end

  defmodule StandaloneBuildInfo do
    def app_engine?, do: false
    def linux_package?, do: false

    def public_identity do
      %{
        "engine_id" => "fermix-core",
        "product_version" => "0.5.7",
        "build_id" => nil,
        "source_commit" => nil,
        "distribution_identity" => "standalone",
        "artifact_target" => nil,
        "architecture" => "arm64"
      }
    end
  end

  # `Checks.service_unit/1` calls `service.status/1`; these two stand in for
  # `Fermix.CLI.Service` so every packaged state is reachable without a host
  # service manager.
  defmodule AnsweringService do
    def status(_opts), do: {:ok, Process.get(:fake_service_status)}
  end

  defmodule RefusingService do
    def status(_opts), do: {:error, :user_manager_unreachable}
  end

  defmodule HealthyChannel do
    def health_check(_opts), do: {:ok, %{detail: "healthy ok", latency_ms: 1}}
  end

  defmodule BrokenChannel do
    def health_check(_opts), do: {:error, {:auth_failed, "bad credential"}}
  end

  describe "workspace_layout/0" do
    test "ok when FERMIX_HOME directories exist" do
      result = Checks.workspace_layout()
      assert result.name == "workspace"
      assert result.status in [:ok, :warn]
      assert is_binary(result.detail)
    end
  end

  describe "browser_disclaim/1" do
    test "not required off macOS" do
      result = Checks.browser_disclaim({:unix, :linux})
      assert result.name == "browser"
      assert result.status == :ok
      assert result.detail =~ "not required"
    end

    if match?({:unix, :darwin}, :os.type()) do
      test "reports the built shim on macOS" do
        result = Checks.browser_disclaim()
        assert result.name == "browser"
        # :warn only when the host has no Chrome/Chromium; never :fail with a
        # correctly built shim.
        assert result.status in [:ok, :warn]
        assert result.detail =~ "disclaim shim ready"
      end

      # An operator-authored `[fermix_core.browser]` section can be refused by
      # `Browser.Config.current/0`, and doctor is the command that explains such
      # an install: it must report the row, never die with a MatchError and print
      # nothing (AGENTS.md, the `df`/tree-less-CLI pitfall).
      test "an invalid browser config is a row, not a crashed doctor run" do
        previous = Application.get_env(:fermix_core, :browser)
        on_exit(fn -> restore_env(:fermix_core, :browser, previous) end)

        Application.put_env(:fermix_core, :browser,
          snapshot_default_depth: 12,
          snapshot_max_depth: 4
        )

        result = Checks.browser_disclaim()

        assert result.name == "browser"
        assert result.status == :warn
        assert result.detail =~ "snapshot_default_depth"
      end

      # The same path for a LIST-valued key. `allowed_hosts` was validated
      # nowhere until the canonical-host rule landed, so this is the first key
      # whose refusal is not an integer-range message — doctor must render it
      # with the offending entry, since that entry is the whole fix.
      test "an uncanonical allowed_hosts entry is a row naming the entry" do
        previous = Application.get_env(:fermix_core, :browser)
        on_exit(fn -> restore_env(:fermix_core, :browser, previous) end)

        Application.put_env(:fermix_core, :browser, allowed_hosts: ["münchen.de"])

        result = Checks.browser_disclaim()

        assert result.name == "browser"
        assert result.status == :warn
        assert result.detail =~ "allowed_hosts"
        assert result.detail =~ "münchen.de"
      end
    end

    # `fermix doctor` is the command that explains a broken install, so a shim
    # that RAN AND REFUSED and a shim that could not be run at all must not
    # collapse into one "check failed" line — they have different fixes, and
    # folding distinct failure kinds together is what sends an operator chasing
    # a phantom. Both run on any OS: the shim path is injected.
    @tag :tmp_dir
    test "a refusing shim reports its exit status and its own words", %{tmp_dir: tmp_dir} do
      shim = Path.join(tmp_dir, "disclaim")
      File.write!(shim, "#!/bin/sh\necho 'disclaim api unavailable' >&2\nexit 3\n")
      File.chmod!(shim, 0o755)

      result = Checks.browser_disclaim({:unix, :darwin}, shim)

      assert result.name == "browser"
      assert result.status == :fail
      assert result.detail =~ "exited 3"
      assert result.detail =~ "disclaim api unavailable"
    end

    @tag :tmp_dir
    test "a shim that cannot be run says so, not that it refused", %{tmp_dir: tmp_dir} do
      shim = Path.join(tmp_dir, "disclaim")
      File.write!(shim, "#!/bin/sh\nexit 0\n")
      File.chmod!(shim, 0o644)

      result = Checks.browser_disclaim({:unix, :darwin}, shim)

      assert result.status == :fail
      assert result.detail =~ "could not run"
      refute result.detail =~ "exited"
    end
  end

  describe "computer_use_permissions/1" do
    test "disabled is a quiet ok" do
      result = Checks.computer_use_permissions({:ok, %{state: :disabled}})
      assert result.name == "computer use"
      assert result.status == :ok
      assert result.detail =~ "disabled"
    end

    # The not-installed row branches on the sidecar target, and the default
    # target is the real host's: compux refuses linux-aarch64 and macos-x86_64,
    # both first-class engine targets and both CI legs. A test of the install
    # offer therefore establishes a supported target instead of reading the
    # machine it happens to run on.
    test "enabled but no sidecar warns to install" do
      result =
        Checks.computer_use_permissions(
          {:ok, %{state: :not_installed}},
          sidecar_target: {:ok, "macos-aarch64"}
        )

      assert result.status == :warn
      assert result.detail =~ "install"
    end

    test "both grants present is ok" do
      probe = probed(screen_capture: true, input_control: true)
      result = Checks.computer_use_permissions({:ok, probe})
      assert result.status == :ok
      assert result.detail =~ "granted"
    end

    test "a probed result surfaces the running compux sidecar version" do
      version = to_string(Application.spec(:compux, :vsn))
      assert version != ""
      probe = probed(screen_capture: true, input_control: true)
      result = Checks.computer_use_permissions({:ok, probe})
      assert result.detail =~ "sidecar compux v#{version}"
    end

    test "the not-installed warning names the version that would install" do
      version = to_string(Application.spec(:compux, :vsn))

      result =
        Checks.computer_use_permissions(
          {:ok, %{state: :not_installed}},
          sidecar_target: {:ok, "macos-aarch64"}
        )

      assert result.detail =~ "installs compux v#{version}"
    end

    test "macOS screen-ok input-denied names the Accessibility pane (the silent-drop case)" do
      probe = probed(screen_capture: true, input_control: false)
      result = Checks.computer_use_permissions({:ok, probe})
      assert result.status == :warn
      assert result.detail =~ "Accessibility"
      assert result.detail =~ "silently dropped"
    end

    test "macOS capture denied names Screen Recording" do
      probe = probed(screen_capture: false, input_control: false)
      result = Checks.computer_use_permissions({:ok, probe})
      assert result.status == :warn
      assert result.detail =~ "Screen Recording"
    end

    # M38 §8.2. The shipped string told every Wayland user to "use an X11
    # session" on desktops that no longer offer one, which is worse than naming
    # no remedy at all. Each replacement says what is refused, why, and what
    # remains true — and never instructs an impossible action.
    test "wayland capture names the portal it needs and hedges the X11 advice" do
      probe = probed(platform: "linux", display_server: "wayland", screen_capture: false)
      result = Checks.computer_use_permissions({:ok, probe})

      assert result.status == :warn
      assert result.detail =~ "screen capture unavailable on this Wayland session"
      assert result.detail =~ "ScreenCast portal"
      assert result.detail =~ "GNOME 50 and later do not"
      refute result.detail =~ "Wayland is unsupported"
    end

    test "wayland input names libei and the RemoteDesktop portal" do
      probe =
        probed(
          platform: "linux",
          display_server: "wayland",
          screen_capture: true,
          input_control: false
        )

      result = Checks.computer_use_permissions({:ok, probe})

      assert result.status == :warn
      assert result.detail =~ "input control unavailable on this Wayland session"
      assert result.detail =~ "RemoteDesktop portal"
      assert result.detail =~ "libei"
      refute result.detail =~ "global input injection is blocked"
    end

    # An install button whose only outcome is `{:error, {:unsupported_target,
    # ...}}` is a lie told with a control: `linux_aarch64` is a first-class
    # engine target and the sidecar publishes no arm64 Linux build.
    test "arm64 Linux states the architecture refusal instead of offering an install" do
      result =
        Checks.computer_use_permissions(
          {:ok, %{state: :not_installed}},
          sidecar_target: {:error, {:unsupported_target, "linux", "aarch64"}}
        )

      assert result.status == :warn
      assert result.detail =~ "computer use is unavailable on this architecture"
      assert result.detail =~ "no arm64 Linux build"
      assert result.detail =~ "Fermix itself is fully supported here"
      refute result.detail =~ "install it from setup"
    end

    # compux refuses Intel macOS too, and `macos_x86_64` is a first-class engine
    # target, so the refusal names the platform it refused. A fixed arm64 Linux
    # sentence told every Intel Mac it was a Linux machine.
    test "Intel macOS states its own architecture refusal, not arm64 Linux's" do
      result =
        Checks.computer_use_permissions(
          {:ok, %{state: :not_installed}},
          sidecar_target: {:error, {:unsupported_target, "macos", "x86_64"}}
        )

      assert result.status == :warn
      assert result.detail =~ "computer use is unavailable on this architecture"
      assert result.detail =~ "no Intel macOS build"
      assert result.detail =~ "Fermix itself is fully supported here"
      refute result.detail =~ "Linux"
      refute result.detail =~ "install it from setup"
    end

    test "a probe that refuses Intel macOS names Intel macOS" do
      result =
        Checks.computer_use_permissions({:error, {:unsupported_target, "macos", "x86_64"}})

      assert result.status == :warn
      assert result.detail =~ "no Intel macOS build"
      refute result.detail =~ "Linux"
    end

    # compux refuses exactly two pairs today, arm64 Linux and Intel macOS.
    # Doctor is the command that explains a broken install, so a pair it has no
    # name for still renders a row naming the refused target instead of
    # crashing the whole run.
    test "a refused pair with no plain name is named by its target" do
      result =
        Checks.computer_use_permissions(
          {:ok, %{state: :not_installed}},
          sidecar_target: {:error, {:unsupported_target, "linux", "riscv64"}}
        )

      assert result.status == :warn
      assert result.detail =~ "publishes no linux-riscv64 build"
    end

    test "a probe that refuses the target answers the same way" do
      result =
        Checks.computer_use_permissions({:error, {:unsupported_target, "linux", "aarch64"}})

      assert result.status == :warn
      assert result.detail =~ "computer use is unavailable on this architecture"
    end

    test "a supported target still offers the install" do
      result =
        Checks.computer_use_permissions(
          {:ok, %{state: :not_installed}},
          sidecar_target: {:ok, "linux-x86_64"}
        )

      assert result.status == :warn
      assert result.detail =~ "install it from setup"
    end

    test "probe error fails the check" do
      result = Checks.computer_use_permissions({:error, :sidecar_unavailable})
      assert result.status == :fail
      assert result.detail =~ "could not probe"
    end

    defp probed(overrides) do
      %{
        state: :probed,
        platform: "macos",
        display_server: "quartz",
        screen_capture: false,
        input_control: false
      }
      |> Map.merge(Map.new(overrides))
    end
  end

  describe "computer_use_background/1" do
    alias FermixCore.ComputerUse.Capabilities

    test "computer use off says there is nothing to bind" do
      result = Checks.computer_use_background({:ok, %{state: :disabled}})

      assert result.name == "window binding"
      assert result.status == :ok
      assert result.detail =~ "computer use is off"
    end

    test "the flag off is reported as off and experimental, not as a fault" do
      result = Checks.computer_use_background({:ok, %{state: :off}})

      assert result.status == :ok
      assert result.detail =~ "off (experimental"
    end

    test "the flag on with no helper installed is a warning that names the install" do
      result = Checks.computer_use_background({:ok, %{state: :not_installed}})

      assert result.status == :warn
      assert result.detail =~ "isn't installed"
    end

    test "a capable helper reports the indicator and the methods it really has" do
      result =
        Checks.computer_use_background(
          read(%{
            "targets" => true,
            "indicator" => "present",
            "capture_methods" => ["display", "window"],
            "input_methods" => ["foreground_hid", "ax"]
          })
        )

      assert result.status == :ok
      assert result.detail =~ "on-screen indicator is present"
      assert result.detail =~ "capture display+window"
      assert result.detail =~ "input foreground_hid+ax"
    end

    test "a helper that cannot bind a window says so rather than staying silent" do
      result = Checks.computer_use_background(read(%{"indicator" => "present"}))

      assert result.status == :warn
      assert result.detail =~ "cannot bind a window"
    end

    test "a helper with no on-screen indicator says which half is missing" do
      result =
        Checks.computer_use_background(read(%{"targets" => true, "indicator" => "missing"}))

      assert result.status == :warn
      assert result.detail =~ "no on-screen indicator"
    end

    test "a helper that does not mention an indicator is not read as having one" do
      result = Checks.computer_use_background(read(%{"targets" => true}))

      assert result.status == :warn
      assert result.detail =~ "does not report an on-screen indicator"
    end

    test "a helper that could not be read fails loudly" do
      result = Checks.computer_use_background({:error, :sidecar_unavailable})

      assert result.status == :fail
      assert result.detail =~ "could not read what the helper supports"
    end

    defp read(capabilities) do
      {:ok,
       %{
         state: :read,
         capabilities: Capabilities.from_identity(%{"capabilities" => capabilities})
       }}
    end
  end

  describe "bootstrap_template_drift/1" do
    alias FermixCore.Memory.Repo, as: MemoryRepo
    alias FermixCore.Prompt.Defaults
    alias FermixCore.Resource.Registry, as: ResourceRegistry

    @drift_types [:fermix_md, :soul_md, :realtime_md, :live_md]

    setup do
      unique = System.unique_integer([:positive])
      root = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-drift-#{unique}")
      bootstrap_dir = Path.join(root, "bootstrap")
      agent_dir = Path.join(bootstrap_dir, "main")
      repo_name = :"drift_repo_#{unique}"

      File.mkdir_p!(agent_dir)

      start_supervised!(
        {MemoryRepo, name: repo_name, enabled: true, database_path: Path.join(root, "memory.db")}
      )

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

      %{
        agent_dir: agent_dir,
        opts: [repo: repo_name, bootstrap_dir: bootstrap_dir, agent_id: "main"],
        repo: repo_name
      }
    end

    defp drift_file(:fermix_md), do: "FERMIX.md"
    defp drift_file(:soul_md), do: "SOUL.md"
    defp drift_file(:realtime_md), do: "REALTIME.md"
    defp drift_file(:live_md), do: "LIVE.md"

    defp drift_default(:fermix_md), do: Defaults.fermix_md()
    defp drift_default(:soul_md), do: Defaults.soul_md()
    defp drift_default(:realtime_md), do: Defaults.realtime_md()
    defp drift_default(:live_md), do: Defaults.live_md()

    # The classifier reads the file AND the revision history, so a fixture that
    # only commits a revision describes a home that cannot exist.
    defp install(ctx, type, content) do
      path = Path.join(ctx.agent_dir, drift_file(type))
      File.write!(path, content)
      path
    end

    defp seed(ctx, type, content) do
      path = install(ctx, type, content)

      {:ok, _revision} =
        ResourceRegistry.commit("main", type, "global", content,
          mutation_source: :seed,
          resource_path: path,
          repo: ctx.opts[:repo]
        )

      :ok
    end

    defp seed_current(ctx) do
      Enum.each(@drift_types, &seed(ctx, &1, drift_default(&1)))
    end

    test "ok when every installed file matches the current shipped templates", ctx do
      seed_current(ctx)

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.name == "bootstrap templates"
      assert result.status == :ok
      assert result.detail =~ "match the shipped templates"
    end

    test "warns that an untouched default will be adopted on the next daemon start", ctx do
      seed_current(ctx)
      seed(ctx, :fermix_md, "an older fermix template render")

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :warn
      assert result.detail =~ "FERMIX.md"
      assert result.detail =~ "untouched defaults"
      assert result.detail =~ "adopt them on the next daemon start"
      refute result.detail =~ "SOUL.md"
    end

    test "warns that a customized file's shipped template moved", ctx do
      seed_current(ctx)
      seed(ctx, :live_md, "an older live template render")
      install(ctx, :live_md, "my own live instructions")

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :warn
      assert result.detail =~ "LIVE.md"
      assert result.detail =~ "local edits"
      assert result.detail =~ "diff them against the current template"
      refute result.detail =~ "/soul reset"
    end

    test "offers /soul reset only when SOUL.md is the customized file", ctx do
      seed_current(ctx)
      seed(ctx, :soul_md, "an older soul template render")
      install(ctx, :soul_md, "my own persona")

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :warn
      assert result.detail =~ "SOUL.md"
      assert result.detail =~ "/soul reset"
    end

    test "names both a pending adoption and a customized file in one warning", ctx do
      seed_current(ctx)
      seed(ctx, :fermix_md, "an older fermix template render")
      seed(ctx, :live_md, "an older live template render")
      install(ctx, :live_md, "my own live instructions")

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :warn
      assert result.detail =~ "untouched defaults: FERMIX.md"
      assert result.detail =~ "local edits: LIVE.md"
    end

    test "a customized file whose shipped template never moved is not drift", ctx do
      seed_current(ctx)
      install(ctx, :soul_md, "my own persona")

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :ok
      assert result.detail =~ "match the shipped templates"
    end

    test "reports unknown for installs with no seed record", ctx do
      @drift_types
      |> Enum.reject(&(&1 == :fermix_md))
      |> Enum.each(&seed(ctx, &1, drift_default(&1)))

      install(ctx, :fermix_md, "content of unknown origin")

      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :ok
      assert result.detail =~ "no seed record"
      assert result.detail =~ "FERMIX.md"
    end

    test "ok when no bootstrap file is installed yet", ctx do
      result = Checks.bootstrap_template_drift(ctx.opts)
      assert result.status == :ok
      assert result.detail =~ "no bootstrap files installed yet"
    end

    test "ok and skipped when the resource registry is switched off", ctx do
      seed_current(ctx)
      disabled = :"drift_disabled_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({MemoryRepo, name: disabled, enabled: false}, id: disabled)
      )

      result = Checks.bootstrap_template_drift(Keyword.put(ctx.opts, :repo, disabled))
      assert result.status == :ok
      assert result.detail =~ "skipped (memory repo unavailable)"
    end
  end

  describe "routing_overrides/0" do
    setup do
      original = Application.get_env(:fermix_core, :routing, [])
      on_exit(fn -> Application.put_env(:fermix_core, :routing, original) end)
    end

    test "ok when nothing is configured (inherit)" do
      Application.put_env(:fermix_core, :routing, [])
      result = Checks.routing_overrides()
      assert result.status == :ok
      assert result.detail =~ "subagent: inherits main"
      assert result.detail =~ "cron: inherits main"
      assert result.detail =~ "meeting: inherits main"
    end

    test "fails on a meeting_model unknown to every provider (M21 Phase 3)" do
      Application.put_env(:fermix_core, :routing, meeting_model: "claude-opus-4-7")
      result = Checks.routing_overrides()
      assert result.status == :fail
      assert result.detail =~ "meeting_model"
      assert result.detail =~ "not a known model for any provider"
    end

    test "summarizes a valid meeting override (M21 Phase 3)" do
      Application.put_env(:fermix_core, :routing,
        meeting_provider: "anthropic",
        meeting_model: "claude-haiku-4-5"
      )

      result = Checks.routing_overrides()
      assert result.status == :ok
      assert result.detail =~ "meeting: provider=anthropic, model=claude-haiku-4-5"
    end

    test "ok and summarizes valid subagent/cron overrides" do
      Application.put_env(:fermix_core, :routing,
        subagent_model: "gpt-5.4-mini",
        cron_provider: "anthropic",
        cron_reasoning_effort: "low"
      )

      result = Checks.routing_overrides()
      assert result.status == :ok
      assert result.detail =~ "model=gpt-5.4-mini"
      assert result.detail =~ "provider=anthropic"
      assert result.detail =~ "effort=low"
    end

    test "fails on a typo'd cron provider" do
      Application.put_env(:fermix_core, :routing, cron_provider: "anthropi")
      result = Checks.routing_overrides()
      assert result.status == :fail
      assert result.detail =~ "cron_provider"
    end

    test "fails on an invalid subagent effort" do
      Application.put_env(:fermix_core, :routing, subagent_reasoning_effort: "turbo")
      result = Checks.routing_overrides()
      assert result.status == :fail
      assert result.detail =~ "subagent_reasoning_effort"
    end

    test "fails on a subagent_model unknown to every provider (typo/removed)" do
      Application.put_env(:fermix_core, :routing, subagent_model: "claude-opus-4-7")
      result = Checks.routing_overrides()
      assert result.status == :fail
      assert result.detail =~ "subagent_model"
      assert result.detail =~ "not a known model for any provider"
    end

    test "fails when an explicit provider does not offer the pinned model" do
      Application.put_env(:fermix_core, :routing,
        cron_provider: "openai",
        cron_model: "claude-haiku-4-5"
      )

      result = Checks.routing_overrides()
      assert result.status == :fail
      assert result.detail =~ "cron_model"
      # The pinned model is named, and the mismatch with the openai provider is
      # reported (now raised by the RoutingOverrides pairing guard and surfaced
      # through the check's ArgumentError rescue).
      assert result.detail =~ "claude-haiku-4-5"
      assert result.detail =~ "openai"
    end
  end

  describe "web_search/1" do
    setup do
      original = Application.get_env(:fermix_core, :tools, [])
      on_exit(fn -> Application.put_env(:fermix_core, :tools, original) end)
      :ok
    end

    test "offline reports the active backend and credential state" do
      Application.put_env(:fermix_core, :tools, web_search: [])

      result = Checks.web_search(false)

      assert result.name == "web search"
      assert result.status == :ok
      assert result.detail =~ "duckduckgo"
    end

    test "warns when a keyed backend has no credential configured" do
      Application.put_env(:fermix_core, :tools, web_search: [backend: :tavily])

      result = Checks.web_search(false)

      assert result.status == :warn
      assert result.detail =~ "tavily"
    end
  end

  describe "place_search/0 (M31 §14.3)" do
    setup do
      original = Application.get_env(:fermix_core, :tools, [])
      on_exit(fn -> Application.put_env(:fermix_core, :tools, original) end)
      :ok
    end

    test "reports the key, the active web backend, and the advertised tool" do
      Application.put_env(:fermix_core, :tools,
        web_search: [backend: :duckduckgo, brave_api_key: "brave-secret"]
      )

      result = Checks.place_search()

      assert result.name == "place search"
      assert result.status == :ok
      assert result.detail =~ "advertised"
      assert result.detail =~ "duckduckgo"
      assert result.detail =~ "metered"
      refute result.detail =~ "brave-secret"
    end

    test "reports a missing key as hidden and optional, not a warning" do
      Application.put_env(:fermix_core, :tools, web_search: [backend: :duckduckgo])

      result = Checks.place_search()

      assert result.status == :ok
      assert result.detail =~ "hidden"
      assert result.detail =~ "brave_api_key"
    end

    test "the default check reports no probe outcome" do
      Application.put_env(:fermix_core, :tools, web_search: [brave_api_key: "brave-secret"])

      result = Checks.place_search()

      refute result.detail =~ "probe"
    end
  end

  describe "place_probe/1 (M31 §14.3)" do
    setup do
      original = Application.get_env(:fermix_core, :tools, [])
      on_exit(fn -> Application.put_env(:fermix_core, :tools, original) end)
      :ok
    end

    test "reports one metered live probe as ok" do
      Application.put_env(:fermix_core, :tools, web_search: [brave_api_key: "brave-secret"])

      result = Checks.place_probe(place_probe_opts(place_ok_plug(self())))

      assert result.name == "place probe"
      assert result.status == :ok
      assert result.detail =~ "metered"
      assert_received {:place_probe_request, query}
      assert query["count"] == "1"
    end

    test "warns with the named failure kind and never switches provider" do
      Application.put_env(:fermix_core, :tools, web_search: [brave_api_key: "brave-secret"])

      result = Checks.place_probe(place_probe_opts(place_status_plug(401)))

      assert result.status == :warn
      assert result.detail =~ "auth_failed"
      assert result.detail =~ "metered"
    end

    test "skips the probe with no Brave key and makes no call" do
      Application.put_env(:fermix_core, :tools, web_search: [backend: :duckduckgo])

      result = Checks.place_probe(place_probe_opts(place_ok_plug(self())))

      assert result.status == :ok
      assert result.detail =~ "skipped"
      refute_received {:place_probe_request, _query}
    end
  end

  describe "image_generation/0 (M15)" do
    setup do
      original = Application.get_env(:fermix_core, :tools, [])
      on_exit(fn -> Application.put_env(:fermix_core, :tools, original) end)
      :ok
    end

    test "reports an unconfigured generate_image as :ok (optional capability)" do
      Application.put_env(:fermix_core, :tools, [])

      result = Checks.image_generation()

      assert result.name == "image generation"
      assert result.status == :ok
      assert result.detail =~ "not configured"
    end

    test "reports a configured backend with a present credential as :ok" do
      Application.put_env(:fermix_core, :tools,
        generate_image: [backend: "google", google_api_key: "gm-secret"]
      )

      result = Checks.image_generation()

      assert result.status == :ok
      assert result.detail =~ "google_image"
    end

    test "warns when the selected backend has no credential configured" do
      Application.put_env(:fermix_core, :tools, generate_image: [backend: "google"])

      result = Checks.image_generation()

      assert result.status == :warn
      assert result.detail =~ "google_image"
    end

    test "warns when the configured backend is unknown" do
      Application.put_env(:fermix_core, :tools, generate_image: [backend: "midjourney"])

      result = Checks.image_generation()

      assert result.status == :warn
      assert result.detail =~ "Unknown"
    end
  end

  describe "realtime/0" do
    setup do
      realtime = Application.get_env(:fermix_core, :realtime, [])
      providers = Application.get_env(:fermix_core, :providers, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :realtime, realtime)
        Application.put_env(:fermix_core, :providers, providers)
      end)

      Application.put_env(:fermix_core, :providers, [])
      :ok
    end

    test "reports :ok when enabled with an OpenAI key present" do
      Application.put_env(:fermix_core, :realtime, enabled: true)
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])

      result = Checks.realtime()

      assert result.name == "realtime voice"
      assert result.status == :ok
      assert result.detail =~ "key present"
      assert result.detail =~ "engine openai_realtime"
      assert result.detail =~ "model gpt-realtime-2"
    end

    # Both engines authenticate with the same OpenAI Platform key, so the line
    # that says the key is present has to say which wire it is present for:
    # without it a Live install and a Realtime install read identically.
    test "names the Live engine and its model when Live is selected" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1"
      )

      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])

      result = Checks.realtime()

      assert result.status == :ok
      assert result.detail =~ "engine openai_live"
      assert result.detail =~ "model gpt-live-1"
    end

    test "warns when enabled but the OpenAI key is missing" do
      Application.put_env(:fermix_core, :realtime, enabled: true)
      Application.put_env(:fermix_core, :providers, [])

      result = Checks.realtime()

      assert result.status == :warn
      assert result.detail =~ "sk-"
      assert result.detail =~ "Codex"
    end

    test "reports :ok and disabled when realtime is off" do
      Application.put_env(:fermix_core, :realtime, enabled: false)

      result = Checks.realtime()

      assert result.status == :ok
      assert result.detail =~ "disabled"
    end
  end

  describe "transcription/0 (M21)" do
    setup do
      transcription = Application.get_env(:fermix_core, :transcription, [])
      providers = Application.get_env(:fermix_core, :providers, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :transcription, transcription)
        Application.put_env(:fermix_core, :providers, providers)
      end)

      Application.put_env(:fermix_core, :providers, [])
      :ok
    end

    test "reports a configured backend with a present credential as :ok" do
      Application.put_env(:fermix_core, :transcription,
        backend: "deepgram",
        deepgram_api_key: "dg-secret"
      )

      result = Checks.transcription()

      assert result.name == "transcription"
      assert result.status == :ok
      assert result.detail =~ "deepgram"
    end

    test "warns when the selected backend has no credential configured" do
      Application.put_env(:fermix_core, :transcription, backend: "deepgram")

      result = Checks.transcription()

      assert result.status == :warn
      assert result.detail =~ "deepgram"
      assert result.detail =~ "not configured"
    end

    test "warns when the configured backend is unknown" do
      Application.put_env(:fermix_core, :transcription, backend: "vosk")

      result = Checks.transcription()

      assert result.status == :warn
      assert result.detail =~ "Unknown"
    end
  end

  describe "transcription/0 on-device backend (M21 Phase 2b)" do
    setup do
      transcription = Application.get_env(:fermix_core, :transcription, [])
      plugins = Application.get_env(:fermix_core, :plugins, [])
      fermix_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("checks-local-stt")

      System.put_env("FERMIX_HOME", home)
      Application.put_env(:fermix_core, :plugins, [])
      Application.put_env(:fermix_core, :transcription, backend: "local")

      on_exit(fn ->
        Application.put_env(:fermix_core, :transcription, transcription)
        Application.put_env(:fermix_core, :plugins, plugins)
        restore_fermix_home(fermix_home)
        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    # The row must not say "set a key": the on-device backend has none, and an
    # operator sent looking for one never finds it.
    test "names the missing sidecar and carries the installer's own fix line" do
      result = Checks.transcription()

      assert result.status == :warn
      assert result.detail =~ "backend local needs its sidecar"
      # The remedy wording is host-dependent (a pinned target — macos-aarch64 —
      # names the setup card; an unpinned one names dev_local), and both remedy
      # sentences are covered host-independently by the doctor/installer seam
      # tests. Here the row must only carry a fix and never say "set a key".
      refute result.detail =~ "set a key"
    end

    test "names the missing model once the sidecar is present", ctx do
      install_fake_stt_sidecar(ctx.home)

      result = Checks.transcription()

      assert result.status == :warn
      assert result.detail =~ "backend local needs its speech model"
    end
  end

  describe "meetings/0 (M21 Phase 3)" do
    setup do
      meetings = Application.get_env(:fermix_core, :meetings, [])
      plugins = Application.get_env(:fermix_core, :plugins, [])
      fermix_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("checks-meetings")

      System.put_env("FERMIX_HOME", home)
      Application.put_env(:fermix_core, :plugins, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :meetings, meetings)
        Application.put_env(:fermix_core, :plugins, plugins)
        restore_fermix_home(fermix_home)
        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    test "reports the subsystem as disabled" do
      Application.put_env(:fermix_core, :meetings, enabled: false)

      result = Checks.meetings()

      assert result.name == "meetings"
      assert result.status == :ok
      assert result.detail =~ "disabled"
    end

    test "warns when it is enabled with no usable lane" do
      Application.put_env(:fermix_core, :meetings, enabled: true)

      result = Checks.meetings()

      assert result.status == :warn
      assert result.detail =~ "no lane is usable"
      # A release is pinned now (host-independently — `pinned_tag/0` is a build
      # constant), so the remedy names the setup card rather than a dev_local build.
      assert result.detail =~ "fermix setup"
    end

    test "reports the usable lanes and the profile custody note", ctx do
      Application.put_env(:fermix_core, :meetings,
        enabled: true,
        zoom_account_id: "acct",
        zoom_client_id: "client",
        zoom_client_secret: "secret",
        zoom_ws_subscription_id: "sub"
      )

      install_fake_meetbot_sidecar(ctx.home)
      :ok = FermixCore.Meetings.SidecarInstaller.mark_browser_installed()

      result = Checks.meetings()

      assert result.status == :ok
      assert result.detail =~ "meet sidecar installed"
      assert result.detail =~ "zoom rtms configured"
      # The custody note for a bot that never signed in. Assert the stable core
      # plus the CURRENT surface (the card's Configure modal on the Plugins
      # page) — the old "profile: absent" rendering and the Meetings tab it
      # pointed at are both gone (7ec3a33), and this assertion rotted with them.
      assert result.detail =~ "bot not signed in"
      assert result.detail =~ "Meeting Notetaker → Configure"
    end

    # `browser_note` was computed and discarded, so the operator's only warning
    # surface said the Meet lane was fine while a join would die when the
    # sidecar could not launch Chromium.
    test "warns when the Meet sidecar has no browser even though Zoom works", ctx do
      Application.put_env(:fermix_core, :meetings,
        enabled: true,
        zoom_account_id: "acct",
        zoom_client_id: "client",
        zoom_client_secret: "secret",
        zoom_ws_subscription_id: "sub"
      )

      install_fake_meetbot_sidecar(ctx.home)

      result = Checks.meetings()

      assert result.status == :warn
      assert result.detail =~ "browser not installed"
      assert result.detail =~ "zoom rtms configured"
    end

    test "warns with the browser remedy when the Meet lane is the only lane", ctx do
      Application.put_env(:fermix_core, :meetings, enabled: true)
      install_fake_meetbot_sidecar(ctx.home)

      result = Checks.meetings()

      assert result.status == :warn
      assert result.detail =~ "browser not installed"
    end
  end

  defp install_fake_stt_sidecar(home) do
    {:ok, target} = FermixCore.Transcription.Local.SidecarInstaller.target()
    write_dev_local_binary!(home, "stt_sidecar", target, "fermix-stt")
  end

  defp install_fake_meetbot_sidecar(home) do
    {:ok, target} = FermixCore.Meetings.SidecarInstaller.target()
    write_dev_local_binary!(home, "meetbot_sidecar", target, "fermix-meetbot")
  end

  # Presence, not content: the doctor rows never run a sidecar, so an empty
  # executable file is a faithful stand-in for an installed one.
  defp write_dev_local_binary!(home, plugin, target, command) do
    dev_local = Path.join(home, "dev-local")
    binary = Path.join([dev_local, plugin, "bin", target, command])

    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "")
    File.chmod!(binary, 0o755)
    Application.put_env(:fermix_core, :plugins, dev_local: dev_local)
  end

  defp restore_fermix_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_fermix_home(value), do: System.put_env("FERMIX_HOME", value)

  describe "channel_health/1" do
    setup do
      original_registry = Application.get_env(:fermix_channels, :channel_registry)
      healthy = Application.get_env(:fermix_channels, :doctor_healthy_channel)
      broken = Application.get_env(:fermix_channels, :doctor_broken_channel)

      on_exit(fn ->
        restore_env(:fermix_channels, :channel_registry, original_registry)
        restore_env(:fermix_channels, :doctor_healthy_channel, healthy)
        restore_env(:fermix_channels, :doctor_broken_channel, broken)
      end)

      :ok
    end

    test "fails when an enabled channel health probe fails" do
      Application.put_env(:fermix_channels, :channel_registry, [
        %{
          name: "healthy",
          config_key: :doctor_healthy_channel,
          adapter: HealthyChannel,
          remote?: true,
          transport: :webhook,
          child: nil
        },
        %{
          name: "broken",
          config_key: :doctor_broken_channel,
          adapter: BrokenChannel,
          remote?: true,
          transport: :webhook,
          child: nil
        }
      ])

      Application.put_env(:fermix_channels, :doctor_healthy_channel, enabled: true)
      Application.put_env(:fermix_channels, :doctor_broken_channel, enabled: true)

      result = Checks.channel_health()

      assert result.name == "channel health"
      assert result.status == :fail
      assert result.detail =~ "healthy=ok"
      assert result.detail =~ "broken=error"
      assert result.detail =~ "auth failed: bad credential"
    end
  end

  describe "service_unit/1" do
    test "warns when no unit is installed (test environment has none)" do
      result = Checks.service_unit()
      assert result.name == "service unit"
      assert result.status in [:ok, :warn]
    end

    test "an installed, current unit is ok" do
      result = Checks.service_unit(installed?: &(&1 == :user), drifted?: fn _scope -> false end)

      assert result.status == :ok
      assert result.detail =~ "user-scope unit installed"
    end

    # "Installed" alone read green on a unit written by an older version — the
    # exact state that leaves a daemon running an outdated PATH, which is how
    # coding-agent CLIs go undetected. Nothing else reports it: `upgrade` never
    # rewrites the unit and refuses outright on a Homebrew install, so this check
    # is the only thing that can send the operator to `fermix setup`.
    test "a stale unit warns and names the verb that rewrites it" do
      result = Checks.service_unit(installed?: &(&1 == :user), drifted?: fn _scope -> true end)

      assert result.status == :warn
      assert result.detail =~ "stale"
      assert result.detail =~ "fermix setup"
    end

    test "drift is reported for a system-scope unit too" do
      result = Checks.service_unit(installed?: &(&1 == :system), drifted?: fn _scope -> true end)

      assert result.status == :warn
      assert result.detail =~ "system-scope"
    end
  end

  describe "daemon_socket/1" do
    test "warns when nothing is listening" do
      result = Checks.daemon_socket()
      assert result.name == "daemon socket"
      assert result.status in [:ok, :warn, :fail]
    end

    test "ok when the daemon version matches this binary" do
      vsn = to_string(Application.spec(:fermix_core, :vsn))
      client = fn -> {:ok, hello(vsn)} end

      result = Checks.daemon_socket(client: client)

      assert result.status == :ok
      assert result.detail =~ "running, version #{vsn}"
    end

    # The skew verdict moved to its own row (M38 §11.3): this row answers "is
    # something answering", and one fact per row is what keeps the two from
    # disagreeing.
    test "reports liveness and leaves the engine comparison to its own row" do
      client = fn -> {:ok, hello("0.0.1")} end

      result = Checks.daemon_socket(client: client)

      assert result.status == :ok
      assert result.detail =~ "running, version 0.0.1"
      refute result.detail =~ "`fermix restart`"
    end

    # A daemon that answers something other than management v1 is a failure with
    # a next step, not an inspected term the reader has to decode.
    test "fails with the daemon's own words when the reply is not management v1" do
      client = fn -> {:error, :invalid_management_response} end

      result = Checks.daemon_socket(client: client)

      assert result.status == :fail
      assert result.detail =~ "management protocol v1"
      assert result.detail =~ "`fermix restart`"
    end

    defp hello(version) do
      %{
        "protocol" => %{"current_version" => 1, "minimum_version" => 1, "maximum_version" => 1},
        "engine" => %{"product_version" => version, "pid" => "1"}
      }
    end
  end

  describe "opik_readiness/1" do
    test "ok and off when the daemon reports disabled" do
      client = fn "observability" ->
        {:ok, %{"status" => "ok", "observability" => %{"status" => "disabled"}}}
      end

      result = Checks.opik_readiness(client: client)

      assert result.name == "opik export"
      assert result.status == :ok
      assert result.detail =~ "off"
    end

    test "ok with endpoint and project when enabled and ready" do
      client = fn "observability" ->
        {:ok,
         %{
           "status" => "ok",
           "observability" => %{
             "status" => "enabled_ready",
             "base_url" => "http://localhost:5173/api",
             "project" => "fermix"
           }
         }}
      end

      result = Checks.opik_readiness(client: client)

      assert result.status == :ok
      assert result.detail =~ "http://localhost:5173/api"
      assert result.detail =~ "fermix"
    end

    test "fails when enabled but the exporter is missing from the build" do
      client = fn "observability" ->
        {:ok, %{"status" => "ok", "observability" => %{"status" => "enabled_missing_app"}}}
      end

      result = Checks.opik_readiness(client: client)

      assert result.status == :fail
      assert result.detail =~ "not loaded"
    end

    test "warns when enabled and loaded but the reporter is not attached" do
      client = fn "observability" ->
        {:ok, %{"status" => "ok", "observability" => %{"status" => "enabled_not_attached"}}}
      end

      result = Checks.opik_readiness(client: client)

      assert result.status == :warn
      assert result.detail =~ "not attached"
    end

    test "warns when the daemon is not running" do
      client = fn "observability" -> {:error, :not_running} end

      result = Checks.opik_readiness(client: client)

      assert result.status == :warn
      assert result.detail =~ "not running"
    end
  end

  describe "acp/1" do
    setup do
      acp = Application.get_env(:fermix_channels, :acp)
      fermix_home = System.get_env("FERMIX_HOME")

      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-checks-acp-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)
      System.put_env("FERMIX_HOME", tmp_home)

      on_exit(fn ->
        case acp do
          nil -> Application.delete_env(:fermix_channels, :acp)
          value -> Application.put_env(:fermix_channels, :acp, value)
        end

        case fermix_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      end)

      %{home: tmp_home}
    end

    test "disabled is a quiet ok and never asks the daemon" do
      Application.put_env(:fermix_channels, :acp, enabled: false)
      client = fn _method -> flunk("the daemon must not be queried when acp is disabled") end

      result = Checks.acp(client: client)

      assert result.name == "acp surface"
      assert result.status == :ok
      assert result.detail =~ "disabled"
    end

    test "reports the listening socket when the daemon says the listener is up", %{home: home} do
      Application.put_env(:fermix_channels, :acp, enabled: true)
      socket = Path.join(home, "acp.sock")
      File.write!(socket, "")

      result = Checks.acp(client: health_client(%{"process_alive" => true}))

      assert result.status == :ok
      assert result.detail =~ socket
    end

    test "warns when the listener is up but the socket file is missing" do
      Application.put_env(:fermix_channels, :acp, enabled: true)

      result = Checks.acp(client: health_client(%{"process_alive" => true}))

      assert result.status == :warn
      assert result.detail =~ "missing"
    end

    test "fails when the daemon runs but the listener is absent" do
      Application.put_env(:fermix_channels, :acp, enabled: true)

      result = Checks.acp(client: health_client(%{"process_alive" => false}))

      assert result.status == :fail
      assert result.detail =~ "listener"
    end

    test "warns with the socket path when the daemon is not running" do
      Application.put_env(:fermix_channels, :acp, enabled: true)
      client = fn "health" -> {:error, :not_running} end

      result = Checks.acp(client: client)

      assert result.status == :warn
      assert result.detail =~ "daemon not running"
      assert result.detail =~ "acp.sock"
    end

    test "warns when the health reply carries no acp channel" do
      Application.put_env(:fermix_channels, :acp, enabled: true)
      client = fn "health" -> {:ok, %{"status" => "ok", "health" => %{"channels" => []}}} end

      result = Checks.acp(client: client)

      assert result.status == :warn
      assert result.detail =~ "unexpected reply"
    end

    # M29 §17.3 "Visibility": the identity list is data on disk, so it renders
    # from the same row whatever the surface is doing.
    test "lists a connected identity beside the live surface, npub only", %{home: home} do
      Application.put_env(:fermix_channels, :acp, enabled: true)
      File.write!(Path.join(home, "acp.sock"), "")
      connect_identity(home)

      result = Checks.acp(client: health_client(%{"process_alive" => true}))

      assert result.status == :ok
      assert result.detail =~ "1 connected"
      assert result.detail =~ "buzz"
      assert result.detail =~ @identity_npub
      refute result.detail =~ @identity_nsec
      refute result.detail =~ @identity_hex
    end

    test "renders the identity list with the surface DISABLED, and says so", %{home: home} do
      Application.put_env(:fermix_channels, :acp, enabled: false)
      connect_identity(home)
      client = fn _method -> flunk("the daemon must not be queried when acp is disabled") end

      result = Checks.acp(client: client)

      assert result.detail =~ "disabled"
      assert result.detail =~ @identity_npub
      # The one place the consent-by-configuration story could leak: an operator
      # who turns the surface off must be told the record is still there.
      assert result.detail =~ "deletes nothing"
      assert result.detail =~ "fermix acp forget"
      refute result.detail =~ @identity_nsec
    end

    test "lists identities with the daemon DOWN — they are disk state, not liveness", %{
      home: home
    } do
      Application.put_env(:fermix_channels, :acp, enabled: true)
      connect_identity(home)

      result = Checks.acp(client: fn "health" -> {:error, :not_running} end)

      assert result.status == :warn
      assert result.detail =~ "daemon not running"
      assert result.detail =~ @identity_npub
      refute result.detail =~ @identity_nsec
    end

    test "a store with no records leaves the row exactly as it was" do
      Application.put_env(:fermix_channels, :acp, enabled: false)

      result = Checks.acp(client: fn _method -> flunk("no daemon call") end)

      assert result.detail == "disabled"
    end

    test "a record the store refuses fails the row with its own fix line", %{home: home} do
      Application.put_env(:fermix_channels, :acp, enabled: true)
      File.write!(Path.join(home, "acp.sock"), "")
      path = connect_identity(home)
      File.chmod!(path, 0o644)

      result = Checks.acp(client: health_client(%{"process_alive" => true}))

      assert result.status == :fail
      assert result.detail =~ path
      assert result.detail =~ "chmod 600"
      refute result.detail =~ @identity_nsec
    end

    defp health_client(acp_channel) do
      channel = Map.merge(%{"name" => "acp", "enabled" => true}, acp_channel)

      fn "health" ->
        {:ok, %{"status" => "ok", "health" => %{"channels" => [channel]}}}
      end
    end

    # Persist one identity exactly as a client hello does, and hand back its
    # record path.
    defp connect_identity(home) do
      dir = Path.join(home, "acp_identities")

      identity =
        Identity.new(%{
          "BUZZ_PRIVATE_KEY" => @identity_nsec,
          "BUZZ_RELAY_URL" => "wss://relay.example.test",
          "PATH" => "/opt/buzz/bin:/usr/bin"
        })

      {:ok, :created} = IdentityStore.upsert(identity, dir)
      Path.join(dir, "#{@identity_hex}.json")
    end
  end

  describe "recent_log_activity/0" do
    test "returns a result map regardless of log presence" do
      result = Checks.recent_log_activity()
      assert result.name == "log activity"
      assert result.status in [:ok, :warn, :fail]
    end
  end

  describe "binary_integrity/1" do
    test "is not applicable to an app-managed engine, before any probe" do
      result =
        Checks.binary_integrity(
          build_info: AppBuildInfo,
          binary_path: "/Applications/Fermix.app/Contents/Resources/Engine/bin/fermix",
          req_options: [plug: &__MODULE__.raising_manifest_plug/1]
        )

      assert result.name == "binary integrity"
      assert result.status == :not_applicable
      assert result.detail =~ "Fermix.app"
    end

    test "warns when fermix is not on PATH and no path is supplied" do
      result =
        Checks.binary_integrity(
          binary_path: "/definitely/does/not/exist/fermix",
          target: {:linux, :x86_64}
        )

      assert result.name == "binary integrity"
      assert result.status == :fail
      assert result.detail =~ "missing"
    end

    test "fails on sha mismatch against the manifest" do
      blob = "not the real binary content"
      actual = :sha256 |> :crypto.hash(blob) |> Base.encode16(case: :lower)
      tmp = make_tmp_binary(blob)

      result =
        Checks.binary_integrity(
          binary_path: tmp,
          target: {:linux, :x86_64},
          req_options: [plug: &__MODULE__.bad_sha_manifest_plug/1]
        )

      assert result.status == :fail
      # The manifest version and BOTH digests are proof the mismatch branch ran:
      # a manifest that never parsed reports a warn carrying none of them, so
      # this cannot pass by failing to read the manifest at all.
      assert result.detail =~ "sha mismatch vs manifest 1.0.0"
      assert result.detail =~ String.slice(actual, 0, 12)
      assert result.detail =~ "000000000000"
      FermixTestSupport.SafeRm.rm(tmp)
    end

    test "ok on sha match" do
      blob = "exact-binary-content"
      sha = :sha256 |> :crypto.hash(blob) |> Base.encode16(case: :lower)
      tmp = make_tmp_binary(blob)

      Process.put({__MODULE__, :sha}, sha)

      result =
        Checks.binary_integrity(
          binary_path: tmp,
          target: {:linux, :x86_64},
          req_options: [plug: &__MODULE__.matching_sha_manifest_plug/1]
        )

      assert result.status == :ok
      assert result.detail =~ "matches releases.json (v1.0.0)"
      FermixTestSupport.SafeRm.rm(tmp)
    end
  end

  describe "upgrade_available?/1" do
    test "warns when a newer version exists" do
      result =
        Checks.upgrade_available?(req_options: [plug: &__MODULE__.future_manifest_plug/1])

      assert result.name == "upgrade"
      assert result.status == :warn
      assert result.detail =~ "available"
    end

    test "is not applicable to an app-managed engine, before any probe" do
      result =
        Checks.upgrade_available?(
          build_info: AppBuildInfo,
          req_options: [plug: &__MODULE__.raising_manifest_plug/1]
        )

      assert result.name == "upgrade"
      assert result.status == :not_applicable
      assert result.detail =~ "Fermix.app"
    end
  end

  describe "streaming_config/1" do
    test "ok when no channel opted in" do
      result = Checks.streaming_config([])

      assert result.name == "channel streaming"
      assert result.status == :ok
      assert result.detail =~ "off"
    end

    test "ok when an opted-in channel can edit drafts" do
      report = [
        %{channel: :telegram, name: "telegram", streaming: "draft", capability: :draft_edit},
        %{channel: :signal, name: "signal", streaming: "off", capability: :none}
      ]

      result = Checks.streaming_config(report)

      assert result.status == :ok
      assert result.detail =~ "streaming on: telegram=draft"
    end

    test "a capability-derived default reports as the mode it resolved to" do
      # No channel opted in explicitly; these are the defaults the gateway and
      # the report agree on (draft where the channel can edit, block otherwise).
      report = [
        %{
          channel: :telegram,
          name: "telegram",
          streaming: "draft",
          derived: "draft",
          explicit?: false,
          capability: :draft_edit
        },
        %{
          channel: :whatsapp,
          name: "whatsapp",
          streaming: "block",
          derived: "block",
          explicit?: false,
          capability: :none
        }
      ]

      result = Checks.streaming_config(report)

      assert result.status == :ok
      assert result.detail =~ "telegram=draft"
      assert result.detail =~ "whatsapp=block"
      refute result.detail =~ "explicit"
    end

    test "an explicit value shadowing a different derived default carries the hint" do
      # The upgrade-path case: a hand-written streaming = "block" from before
      # the capability-derived default keeps winning silently — doctor is
      # where the shadowing becomes visible.
      report = [
        %{
          channel: :telegram,
          name: "telegram",
          streaming: "block",
          derived: "draft",
          explicit?: true,
          capability: :draft_edit
        }
      ]

      result = Checks.streaming_config(report)

      assert result.status == :ok
      assert result.detail =~ "telegram=block (explicit; unset derives draft)"
    end

    test "an explicit value equal to the derived default carries no hint" do
      report = [
        %{
          channel: :whatsapp,
          name: "whatsapp",
          streaming: "block",
          derived: "block",
          explicit?: true,
          capability: :none
        }
      ]

      result = Checks.streaming_config(report)

      assert result.status == :ok
      assert result.detail =~ "whatsapp=block"
      refute result.detail =~ "explicit"
    end

    test "block mode is ok on any channel — no edit capability required" do
      report = [
        %{channel: :whatsapp, name: "whatsapp", streaming: "block", capability: :none}
      ]

      result = Checks.streaming_config(report)

      assert result.status == :ok
      assert result.detail =~ "whatsapp=block"
    end

    test "warns loudly when streaming is configured on a channel without the capability" do
      report = [
        %{channel: :whatsapp, name: "whatsapp", streaming: "draft", capability: :none}
      ]

      result = Checks.streaming_config(report)

      assert result.status == :warn
      assert result.detail =~ "cannot edit drafts"
      assert result.detail =~ "whatsapp"
    end
  end

  describe "compaction_config/0" do
    setup do
      original_providers = Application.get_env(:fermix_core, :providers, [])
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_compaction = Application.get_env(:fermix_core, :compaction, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :providers, original_providers)
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :compaction, original_compaction)
      end)

      :ok
    end

    test "reports the active route and threshold trigger point" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [default_model: "claude-haiku-4-5"]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :anthropic)
      Application.put_env(:fermix_core, :compaction, enabled: true, threshold: 0.8)

      result = Checks.compaction_config()

      assert result.name == "compaction"
      assert result.status == :ok
      assert result.detail =~ "enabled"
      assert result.detail =~ "anthropic/claude-haiku-4-5"
      assert result.detail =~ "context window 200000"
      assert result.detail =~ "compact at 160000"
    end
  end

  describe "command_owner_config/0" do
    setup do
      original_channels =
        for channel <- [:telegram, :whatsapp, :discord, :slack, :signal, :mobile], into: %{} do
          {channel, Application.get_env(:fermix_channels, channel, [])}
        end

      on_exit(fn ->
        Enum.each(original_channels, fn {channel, config} ->
          Application.put_env(:fermix_channels, channel, config)
        end)
      end)

      :ok
    end

    test "warns when an enabled channel has no owner user id" do
      Application.put_env(:fermix_channels, :telegram, enabled: true)
      Application.put_env(:fermix_channels, :signal, enabled: true, owner_user_id: "+15550001111")

      result = Checks.command_owner_config()

      assert result.name == "command owners"
      assert result.status == :warn
      assert result.detail =~ "telegram"
      assert result.detail =~ "signal=owner set"
    end

    test "treats paired-device mobile ingress as its own command authority" do
      for channel <- [:telegram, :whatsapp, :discord, :slack, :signal] do
        Application.put_env(:fermix_channels, channel, enabled: false)
      end

      Application.put_env(:fermix_channels, :mobile, enabled: true)

      result = Checks.command_owner_config()

      assert result.status == :ok
      assert result.detail =~ "mobile=paired-device authority"
      refute result.detail =~ "missing command owner for enabled channels: mobile"
    end
  end

  describe "sandbox_config/0" do
    test "reports current sandbox posture" do
      result = Checks.sandbox_config()

      assert result.name == "sandbox"
      assert result.status == :ok
      assert result.detail =~ "mode"
    end
  end

  describe "sandbox_trace_suggestions/0" do
    setup do
      previous_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-sandbox-traces")
      System.put_env("FERMIX_HOME", home)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    test "suggests parent directory for denied file writes", %{home: home} do
      target = Path.join([home, "Workspace", "app", "lib", "file.ex"])
      write_sandbox_event(home, capability: "file_write", resource: target)

      result = Checks.sandbox_trace_suggestions()

      assert result.name == "sandbox traces"
      assert result.status == :warn
      assert result.detail =~ "fermix grant path #{Path.dirname(target)}"
    end

    test "suggests shell cwd itself for denied shell commands", %{home: home} do
      cwd = Path.join([home, "Workspace", "app"])
      write_sandbox_event(home, capability: "shell", resource: cwd)

      result = Checks.sandbox_trace_suggestions()

      assert result.status == :warn
      assert result.detail =~ "fermix grant path #{cwd}"
      refute result.detail =~ "fermix grant path #{Path.dirname(cwd)};"
    end

    test "passes when no sandbox trace roadblocks exist" do
      result = Checks.sandbox_trace_suggestions()

      assert result.name == "sandbox traces"
      assert result.status == :ok
    end
  end

  describe "auth_file_permissions/0" do
    setup do
      previous_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-auth")
      System.put_env("FERMIX_HOME", home)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    test "passes when auth.json is absent" do
      result = Checks.auth_file_permissions()

      assert result.name == "auth perms"
      assert result.status == :ok
      assert result.detail =~ "no auth.json"
    end

    test "fails when auth.json is wider than 0600", %{home: home} do
      path = Path.join(home, "auth.json")
      File.write!(path, "{}")
      File.chmod!(path, 0o644)

      result = Checks.auth_file_permissions()

      assert result.name == "auth perms"
      assert result.status == :fail
      assert result.detail =~ "0o600"
      assert result.detail =~ "chmod 600"
    end
  end

  describe "plaintext_secrets/0" do
    setup do
      previous_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-secrets")
      System.put_env("FERMIX_HOME", home)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    test "warns when setup secrets are still plaintext", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.providers.openai]
      api_key = "sk-plain"
      """)

      result = Checks.plaintext_secrets()

      assert result.name == "setup secrets"
      assert result.status == :warn
      assert result.detail =~ "OPENAI_API_KEY"
      assert result.detail =~ Path.join(home, "config.toml")
      assert result.detail =~ "fermix setup --migrate-secrets"
    end

    test "passes when no plaintext setup secrets are present", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.providers.openai]
      api_key = "@keyring"
      """)

      result = Checks.plaintext_secrets()

      assert result.name == "setup secrets"
      assert result.status == :ok
    end

    # The one command that should explain a refused boot must not die with a
    # raw stacktrace on the same config that refused it (the tree-less-doctor
    # pitfall class).
    #
    # Scope, stated honestly: this exercises runtime_config_snapshot/0 in
    # isolation. In the shipped binary the release config provider
    # (config/runtime.exs) evaluates the SAME load_runtime_config at boot and
    # raises there, before Fermix.CLI dispatches — so an operator whose
    # config.toml is refused sees the provider's boot error, not this row.
    # Making that row reachable means letting the config provider tolerate a
    # refused config for tree-less CLI verbs, which is a boot-behaviour design
    # decision, not a check-level fix. Until that is decided these assertions
    # pin the function, not the operator's experience.
    test "a config.toml the loader refuses renders a failed check, not a crash", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.browser]
      allow_private_network = true
      """)

      result = Checks.plaintext_secrets()

      assert result.name == "setup secrets"
      assert result.status == :fail
      assert result.detail =~ "config.toml"
      assert result.detail =~ "allow_private_network"
    end

    # Not every refusal on that path is an ArgumentError: the legacy
    # provider-layout refusal is a bare `raise`, i.e. a RuntimeError. A rescue
    # that names only one of them still dies on the other.
    test "a legacy provider layout is a failed check too, not a crash", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.providers.openai]
      provider = "openai"
      """)

      result = Checks.plaintext_secrets()

      assert result.name == "setup secrets"
      assert result.status == :fail
      assert result.detail =~ "config.toml"
      assert result.detail =~ "[fermix_core.agent]"
    end
  end

  describe "auth_probe/1" do
    setup do
      original_providers = Application.get_env(:fermix_core, :providers, [])
      original_agent = Application.get_env(:fermix_core, :agent, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :providers, original_providers)
        Application.put_env(:fermix_core, :agent, original_agent)
      end)

      :ok
    end

    test "ok on probe pass" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-test", default_model: "gpt-5.5"]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end
      result = Checks.auth_probe(req_options: [plug: plug])

      assert result.name == "auth probe"
      assert result.status == :ok
      assert result.detail =~ "openai/gpt-5.5"
    end

    test "fail on auth_scope_mismatch" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-bad"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end
      result = Checks.auth_probe(req_options: [plug: plug])

      assert result.status == :fail
      assert result.detail =~ "api.openai.com"
    end

    test "warn on misconfigured provider" do
      Application.put_env(:fermix_core, :providers, openai: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      result = Checks.auth_probe()
      assert result.status == :warn
      assert result.detail =~ "api_key"
    end

    test "warn on transient 5xx" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "service unavailable") end
      result = Checks.auth_probe(req_options: [plug: plug])

      assert result.status == :warn
      assert result.detail =~ "503"
    end
  end

  # Under `macos_app` the release feed is not this engine's update source, so a
  # reachable feed would be a wrong answer, not merely a slow one.
  def raising_manifest_plug(_conn), do: raise("release manifest fetch must not run")

  def bad_sha_manifest_plug(conn) do
    body = manifest_with_sha("0000000000000000000000000000000000000000000000000000000000000000")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  def matching_sha_manifest_plug(conn) do
    sha = Process.get({__MODULE__, :sha})
    body = manifest_with_sha(sha)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  def future_manifest_plug(conn) do
    body = %{
      "schema_version" => 1,
      "latest" => "99.0.0",
      "releases" => [
        %{
          "version" => "99.0.0",
          "published_at" => "2099-01-01T00:00:00Z",
          "artifacts" => []
        }
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp manifest_with_sha(sha) do
    %{
      "schema_version" => 1,
      "latest" => "1.0.0",
      "releases" => [
        %{
          "version" => "1.0.0",
          "published_at" => "2026-01-01T00:00:00Z",
          "artifacts" => [
            %{
              "target" => "linux-x86_64",
              "url" => "#{@release_base}/fermix_linux_x86_64",
              "sha256" => sha,
              "sig_url" => "#{@release_base}/fermix_linux_x86_64.sig",
              "cert_url" => "#{@release_base}/fermix_linux_x86_64.pem"
            }
          ]
        }
      ]
    }
  end

  defp make_tmp_binary(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-doctor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(path, content)
    path
  end

  defp write_sandbox_event(home, fields) do
    dir = Path.join([home, "traces", Date.utc_today() |> Date.to_iso8601()])
    File.mkdir_p!(dir)

    row =
      %{
        type: "sandbox_event",
        decision: "deny",
        reason_tag: "outside_root",
        resource: Keyword.fetch!(fields, :resource),
        capability: Keyword.fetch!(fields, :capability)
      }
      |> Jason.encode!()

    File.write!(Path.join(dir, "sandbox_event.jsonl"), row <> "\n", [:append])
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "auth_token_expiry/0" do
    setup do
      previous_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-auth-expiry")
      System.put_env("FERMIX_HOME", home)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      :ok
    end

    test "ok when there is no auth file" do
      assert %{name: "auth tokens", status: :ok} = Checks.auth_token_expiry()
    end

    test "ok when no token is stale" do
      :ok = Store.write(:openai_codex, token_entry(3600))

      assert %{status: :ok} = Checks.auth_token_expiry()
    end

    test "warns and names only the stale profiles" do
      :ok = Store.write(:openai_codex, token_entry(-7200))
      :ok = Store.write("gmail:primary", token_entry(3600))

      assert %{status: :warn, detail: detail} = Checks.auth_token_expiry()
      assert detail =~ "openai_codex"
      refute detail =~ "gmail:primary"
    end
  end

  defp token_entry(expires_in_seconds) do
    %{
      auth_mode: "oauth2",
      provider: "google",
      tokens: %{access_token: "at", refresh_token: "rt"},
      expires_at: DateTime.add(DateTime.utc_now(), expires_in_seconds, :second),
      last_refresh: nil,
      status: "ready"
    }
  end

  # NOTE: every test here injects `quota:`, so none exercises the real
  # `Artifacts.admission_check/1`. That is deliberate (hermetic), but it is also
  # why the tree-less abort that killed the whole `doctor` verb was invisible
  # here — and it cannot be fixed at this level: `mix test` boots the supervision
  # tree, so a supervised probe always succeeds in this process no matter what
  # the call site passes. The mechanism is pinned one level down, in
  # `Harness.ArtifactsTest`, where a dead supervisor name reproduces the CLI's
  # world for real.
  describe "computer_history/1" do
    test "non-macOS host reports macOS-only" do
      result = Checks.computer_history(macos?: false)
      assert result.name == "computer history"
      assert result.status == :ok
      assert result.detail =~ "macOS only"
    end

    test "macOS + disabled config reports off" do
      result = Checks.computer_history(macos?: true, config: [enabled: false])
      assert result.status == :ok
      assert result.detail =~ "off"
    end

    test "macOS + enabled local summarizer reports on-device + the app allowlist size" do
      # The chain is injected because the row now reports the chain posture too:
      # without it this case would read whatever provider config ran before it.
      result =
        Checks.computer_history(
          macos?: true,
          config: [enabled: true, apps: ["com.apple.Safari"], summarizer: :local],
          routes: {:ok, [loopback_route()]}
        )

      assert result.status == :ok
      assert result.detail =~ "on"
      assert result.detail =~ "on-device"
      assert result.detail =~ "1 app(s) allowlisted"
      # M32.1 §2.1: there is no per-site filter to count any more.
      refute result.detail =~ "site"
    end

    test "macOS + Tier-3 summarizer flags the remote egress" do
      result =
        Checks.computer_history(
          macos?: true,
          config: [enabled: true, summarizer: :anthropic],
          routes: {:ok, [route(:anthropic)]}
        )

      assert result.detail =~ "anthropic (remote"
    end

    # §9.4: "enabled but unsurfaceable" was designed and never surfaced anywhere.
    # This row is one of the three places that now says it.
    test "an enabled rail names the pinned chain and the failover it turns off" do
      result =
        Checks.computer_history(
          macos?: true,
          config: [enabled: true, summarizer: :local, remote_summaries: [:openai]],
          routes: {:ok, [route(:openai), route(:anthropic)]}
        )

      assert result.status == :ok
      assert result.detail =~ "history turns run on openai"
      assert result.detail =~ "failover to anthropic is off while history is on"
    end

    test "an ungranted primary is a WARN naming the grant that would surface it" do
      result =
        Checks.computer_history(
          macos?: true,
          config: [enabled: true, summarizer: :local],
          routes: {:ok, [route(:anthropic)]}
        )

      assert result.status == :warn
      assert result.detail =~ "history cannot surface"
      assert result.detail =~ ~s(remote_summaries = ["anthropic"])
    end

    test "a chain that could not be built is reported, never raised" do
      result =
        Checks.computer_history(
          macos?: true,
          config: [enabled: true, summarizer: :local],
          routes: {:error, :multiple_primary}
        )

      assert result.status == :ok
      assert result.detail =~ "provider chain could not be built"
    end

    defp route(provider),
      do: {%{provider: provider, base_url: "https://api.#{provider}.example/v1"}, []}

    defp loopback_route, do: {%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}
  end

  describe "skill_curation/1" do
    test "skips when curation is disabled" do
      assert Checks.skill_curation(skill_curation_enabled: false) == nil
    end

    test "warns when memory persistence is off" do
      result =
        Checks.skill_curation(
          skill_curation_enabled: true,
          memory_enabled: false,
          delivery_target: :no_delivery_target
        )

      assert result.name == "skill curation"
      assert result.status == :warn
      assert result.detail =~ "memory persistence is off"
    end

    test "warns with the fix when no owner-private delivery target resolves" do
      result =
        Checks.skill_curation(
          skill_curation_enabled: true,
          memory_enabled: true,
          delivery_target: :no_delivery_target
        )

      assert result.status == :warn
      assert result.detail =~ "/skills proposals"
      assert result.detail =~ "owner_user_id"
    end

    test "reports the resolved target when delivery works" do
      result =
        Checks.skill_curation(
          skill_curation_enabled: true,
          memory_enabled: true,
          delivery_target: {:ok, %{platform: "telegram", destination: "owner-1"}}
        )

      assert result.status == :ok
      assert result.detail =~ "telegram:owner-1"
    end
  end

  describe "harness/1" do
    test "skips (nil) when disabled and no vendor CLI is present" do
      assert Checks.harness(
               harness_enabled: false,
               detections: both_absent(),
               counts: %{active: 0, pending: 0, dead_letter: 0},
               quota: :ok
             ) == nil
    end

    test "disabled but a CLI present is a quiet ok naming how to enable" do
      result =
        Checks.harness(
          harness_enabled: false,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", false, nil, :absent)
          },
          counts: :skipped,
          quota: :ok
        )

      assert result.name == "coding harness"
      assert result.status == :ok
      assert result.detail =~ "disabled in config"
      assert result.detail =~ "enable [fermix_core.harness]"
    end

    test "enabled with an authenticated vendor and a synced registry is ok" do
      registry = registry_with([FermixCore.Tools.CodexRun, FermixCore.Tools.ClaudeCodeRun])

      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", true, "claude 2.0.0", :authenticated)
          },
          registry: registry,
          counts: %{active: 1, pending: 0, dead_letter: 0},
          quota: :ok
        )

      assert result.status == :ok
      assert result.detail =~ "codex codex 1.0.0 (authenticated)"
      assert result.detail =~ "1 active, 0 pending delivery, 0 dead-letter"
      assert result.detail =~ "artifacts within quota"
    end

    test "reports first-use consent state as an info-grade detail, never changing status" do
      registry = registry_with([FermixCore.Tools.CodexRun])

      base = [
        harness_enabled: true,
        detections: %{
          "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
          "claude" => detection("claude", false, nil, :absent)
        },
        registry: registry,
        counts: %{active: 0, pending: 0, dead_letter: 0},
        quota: :ok
      ]

      not_yet = Checks.harness(Keyword.put(base, :harness_approved, false))
      assert not_yet.detail =~ "consent: not yet approved"
      assert not_yet.status == :ok

      approved = Checks.harness(Keyword.put(base, :harness_approved, true))
      assert approved.detail =~ "consent: approved"
      assert approved.status == :ok
    end

    test "enabled with no vendor CLI at all warns (the feature can't run, but doesn't hard-fail)" do
      result =
        Checks.harness(
          harness_enabled: true,
          detections: both_absent(),
          registry: empty_registry(),
          counts: :skipped,
          quota: :ok
        )

      assert result.status == :warn
      assert result.detail =~ "codex not installed"
      assert result.detail =~ "claude not installed"
    end

    test "installed but unauthenticated vendor warns" do
      registry = registry_with([FermixCore.Tools.CodexRun])

      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :absent),
            "claude" => detection("claude", false, nil, :absent)
          },
          registry: registry,
          counts: %{active: 0, pending: 0, dead_letter: 0},
          quota: :ok
        )

      assert result.status == :warn
      assert result.detail =~ "codex codex 1.0.0 (not authenticated)"
    end

    test "dead-letter deliveries warn with the count surfaced" do
      registry = registry_with([FermixCore.Tools.CodexRun])

      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", false, nil, :absent)
          },
          registry: registry,
          counts: %{active: 0, pending: 1, dead_letter: 2},
          quota: :ok
        )

      assert result.status == :warn
      assert result.detail =~ "2 dead-letter"
    end

    test "a boot-registry vs current-PATH disagreement warns to restart" do
      # codex is on PATH now but was NOT registered at boot (empty registry) —
      # a restart would sync the advertised tools.
      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", false, nil, :absent)
          },
          registry: empty_registry(),
          counts: %{active: 0, pending: 0, dead_letter: 0},
          quota: :ok
        )

      assert result.status == :warn
      assert result.detail =~ "restart to sync codex"
    end

    test "a breached artifact quota fails (admission is hard-blocked)" do
      registry = registry_with([FermixCore.Tools.CodexRun])

      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", false, nil, :absent)
          },
          registry: registry,
          counts: %{active: 0, pending: 0, dead_letter: 0},
          quota:
            {:error,
             {:artifact_quota,
              %{
                kind: :quota_exceeded,
                used_bytes: 6 * 1_073_741_824,
                quota_bytes: 5 * 1_073_741_824
              }}}
        )

      assert result.status == :fail
      assert result.detail =~ "artifact quota exceeded"
    end

    test "low free space warns without hard-failing" do
      registry = registry_with([FermixCore.Tools.CodexRun])

      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", false, nil, :absent)
          },
          registry: registry,
          counts: %{active: 0, pending: 0, dead_letter: 0},
          quota:
            {:error,
             {:artifact_quota,
              %{
                kind: :below_min_free,
                free_bytes: 1_073_741_824,
                min_free_bytes: 2 * 1_073_741_824
              }}}
        )

      assert result.status == :warn
      assert result.detail =~ "low free space"
    end

    test "unavailable run counts skip honestly instead of crashing" do
      registry = registry_with([FermixCore.Tools.CodexRun])

      result =
        Checks.harness(
          harness_enabled: true,
          detections: %{
            "codex" => detection("codex", true, "codex 1.0.0", :authenticated),
            "claude" => detection("claude", false, nil, :absent)
          },
          registry: registry,
          counts: :skipped,
          quota: :ok
        )

      assert result.status == :ok
      assert result.detail =~ "run counts skipped"
    end
  end

  defp both_absent do
    %{
      "codex" => detection("codex", false, nil, :absent),
      "claude" => detection("claude", false, nil, :absent)
    }
  end

  defp detection(vendor, available?, version, auth) do
    %{
      vendor: vendor,
      binary: if(available?, do: "/usr/bin/#{vendor}"),
      available?: available?,
      version: version,
      auth: auth
    }
  end

  defp registry_with(tool_modules) do
    name = :"harness_doctor_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name})

    Enum.each(tool_modules, fn module ->
      :ok = CapabilityRegistry.register(name, Builtin.from_tool_module(module))
    end)

    name
  end

  defp empty_registry do
    name = :"harness_doctor_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name})
    name
  end

  defp place_probe_opts(id) do
    [
      req_options: [plug: {Req.Test, id}],
      net_resolver: fn "api.search.brave.com" -> {:ok, [{93, 184, 216, 34}]} end
    ]
  end

  defp place_ok_plug(test_pid) do
    id = :"checks_place_probe_#{System.unique_integer([:positive])}"

    Req.Test.stub(id, fn conn ->
      send(test_pid, {:place_probe_request, URI.decode_query(conn.query_string)})

      place_probe_json(conn, 200, %{
        "results" => [%{"title" => "Eiffel Tower", "url" => "https://toureiffel.example/visit"}]
      })
    end)

    id
  end

  defp place_status_plug(status) do
    id = :"checks_place_status_#{System.unique_integer([:positive])}"

    Req.Test.stub(id, fn conn -> place_probe_json(conn, status, %{"error" => "nope"}) end)

    id
  end

  defp place_probe_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "home_permissions/0" do
    setup do
      previous = System.get_env("FERMIX_HOME")

      tmp_home =
        Path.join(System.tmp_dir!(), "fermix-checks-home-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)
      System.put_env("FERMIX_HOME", tmp_home)

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      end)

      %{home: tmp_home}
    end

    test "ok when the home is 0700", %{home: home} do
      File.chmod!(home, 0o700)

      result = Checks.home_permissions()

      assert result.name == "home perms"
      assert result.status == :ok
      assert result.detail =~ "0700"
    end

    test "fails with the octal mode and a literal fix when world-readable", %{home: home} do
      File.chmod!(home, 0o755)

      result = Checks.home_permissions()

      assert result.status == :fail
      assert result.detail =~ "755"
      assert result.detail =~ "chmod 700 #{home}"
    end

    # The self-heal is the whole point: an install created before the mode was
    # enforced must be repaired by an ordinary boot, not by the operator.
    test "ensure_workspace/0 repairs a world-readable home", %{home: home} do
      File.chmod!(home, 0o755)

      assert :ok = ConfigStore.ensure_workspace()

      assert Checks.home_permissions().status == :ok
    end
  end

  describe "cosign/1" do
    test "ok when cosign resolves" do
      result = Checks.cosign(cosign_path: "/opt/homebrew/bin/cosign")

      assert result.name == "cosign"
      assert result.status == :ok
      assert result.detail =~ "/opt/homebrew/bin/cosign"
    end

    # M38 §11.3: the row reports the executable this host actually resolved. On a
    # packaged install that can be the distribution's own cosign or the bundled
    # one, and which answered is the fact the operator needs.
    test "names the resolved bundled executable on a packaged host" do
      result =
        Checks.cosign(cosign_path: "/usr/lib/fermix/cosign", build_info: PackagedBuildInfo)

      assert result.status == :ok
      assert result.detail =~ "/usr/lib/fermix/cosign"
    end

    # Both features fail closed without it, and the `curl | sh` install path
    # never supplies it — so the message has to name both, or the operator
    # learns about it from an unrelated-looking refusal much later.
    test "warns naming both features that refuse without it" do
      result = Checks.cosign(cosign_path: nil)

      assert result.status == :warn
      assert result.detail =~ "fermix upgrade"
      assert result.detail =~ "fermix plugins install"
    end

    test "the macOS remedy stays Homebrew's" do
      result = Checks.cosign(cosign_path: nil, build_info: StandaloneBuildInfo, linux?: false)

      assert result.detail =~ "brew install cosign"
      refute result.detail =~ "apt"
    end

    # A packaged host has no Homebrew, and telling its operator to run `brew` is
    # the same class of defect as telling a Wayland user to switch to X11.
    test "a packaged host is told its own families and the bundled fallback" do
      result = Checks.cosign(cosign_path: nil, build_info: PackagedBuildInfo)

      assert result.detail =~ "sudo apt install cosign"
      assert result.detail =~ "sudo dnf install cosign"
      assert result.detail =~ "sudo zypper install cosign"
      assert result.detail =~ "/usr/lib/fermix/cosign"
      refute result.detail =~ "brew"
    end

    test "a standalone Linux host is pointed at the upstream project" do
      result = Checks.cosign(cosign_path: nil, build_info: StandaloneBuildInfo, linux?: true)

      assert result.detail =~ "github.com/sigstore/cosign"
      refute result.detail =~ "brew"
    end
  end

  # M38 §9.2/§11.3. The verdict is `VersionSkew.compare/2`'s, so this row can
  # never disagree with `fermix status` or `fermix service status --json`.
  describe "engine_alignment/1" do
    test "the installed engine answering is a pass" do
      result =
        Checks.engine_alignment(
          build_info: PackagedBuildInfo,
          client: fn -> {:ok, engine_hello(PackagedBuildInfo.public_identity())} end
        )

      assert result.name == "engine alignment"
      assert result.status == :ok
      assert result.detail =~ "1.2.3"
    end

    test "a different build id warns and names the restart" do
      running = %{PackagedBuildInfo.public_identity() | "build_id" => "release-8"}

      result =
        Checks.engine_alignment(
          build_info: PackagedBuildInfo,
          client: fn -> {:ok, engine_hello(running)} end
        )

      assert result.status == :warn
      assert result.detail =~ "Run `fermix restart` to load the installed engine."
    end

    # §9.2: an identity Fermix cannot establish is not evidence of skew, and
    # warning on it would send an operator to restart a current daemon.
    test "an absent build id stays a note rather than a warning" do
      running = %{PackagedBuildInfo.public_identity() | "build_id" => nil}

      result =
        Checks.engine_alignment(
          build_info: PackagedBuildInfo,
          client: fn -> {:ok, engine_hello(running)} end
        )

      assert result.status == :not_applicable
      assert result.detail =~ "no build id"
      refute result.detail =~ "fermix restart"
    end

    test "a daemon of another distribution is a failure, not a restart" do
      running = %{PackagedBuildInfo.public_identity() | "distribution_identity" => "standalone"}

      result =
        Checks.engine_alignment(
          build_info: PackagedBuildInfo,
          client: fn -> {:ok, engine_hello(running)} end
        )

      assert result.status == :fail
      assert result.detail =~ "different Fermix build"
      refute result.detail =~ "fermix restart"
    end

    test "nothing answering is not a comparison" do
      result =
        Checks.engine_alignment(
          build_info: PackagedBuildInfo,
          client: fn -> {:error, :not_running} end
        )

      assert result.status == :not_applicable
      assert result.detail =~ "no daemon is answering"
    end

    # The brew-upgrade state on a standalone install: no build id on either
    # side, so the product version is the generation and the row must still fire.
    test "a standalone install compares product versions" do
      running = %{StandaloneBuildInfo.public_identity() | "product_version" => "0.5.6"}

      result =
        Checks.engine_alignment(
          build_info: StandaloneBuildInfo,
          client: fn -> {:ok, engine_hello(running)} end
        )

      assert result.status == :warn
      assert result.detail =~ "fermix restart"
    end

    defp engine_hello(engine) do
      %{
        "protocol" => %{"current_version" => 1, "minimum_version" => 1, "maximum_version" => 1},
        "engine" => Map.put(engine, "pid", "1")
      }
    end
  end

  # M38 §9.3, §11.3: one answer to package ownership, shared with `fermix
  # upgrade`, so the row and the refusal can never name different managers.
  describe "package_origin/1" do
    test "a packaged engine is named before any filesystem query" do
      result =
        Checks.package_origin(
          build_info: PackagedBuildInfo,
          resolve_self: fn -> raise "the path must not be resolved" end,
          cmd: fn _executable, _args -> raise "no ownership tool may be run" end
        )

      assert result.name == "package origin"
      assert result.status == :ok
      assert result.detail =~ "this machine's package manager"
      assert result.detail =~ "sudo apt update"
      refute result.detail =~ "linux_package"
    end

    test "a host package database that owns the binary is reported with its command" do
      result =
        Checks.package_origin(
          build_info: StandaloneBuildInfo,
          binary_path: "/usr/bin/fermix",
          find_executable: fn
            "dpkg" -> "/usr/bin/dpkg"
            _other -> nil
          end,
          cmd: fn "/usr/bin/dpkg", ["-S", "/usr/bin/fermix"] -> {"fermix: /usr/bin/fermix", 0} end
        )

      assert result.status == :ok
      assert result.detail =~ "dpkg"
      assert result.detail =~ "sudo apt update"
    end

    test "a binary nothing owns says the updater handles it" do
      result =
        Checks.package_origin(
          build_info: StandaloneBuildInfo,
          binary_path: "/opt/fermix/bin/fermix",
          find_executable: fn _tool -> nil end
        )

      assert result.status == :ok
      assert result.detail =~ "/opt/fermix/bin/fermix"
      assert result.detail =~ "fermix upgrade"
    end

    test "a fermix that is not on PATH is a warning, not an invented owner" do
      result =
        Checks.package_origin(
          build_info: StandaloneBuildInfo,
          resolve_self: fn -> nil end,
          find_executable: fn _tool -> nil end
        )

      assert result.status == :warn
      assert result.detail =~ "not on PATH"
    end
  end

  # M38 §4.3, §11.3. Every state goes through the shared inspector, so the row
  # and `fermix service install` can never report different linger.
  describe "linger/1" do
    test "not applicable off Linux" do
      assert Checks.linger(linux?: false, build_info: StandaloneBuildInfo) == nil
    end

    test "a packaged install is always in scope, unit probe or not" do
      result =
        Checks.linger(
          linux?: true,
          build_info: PackagedBuildInfo,
          find_executable: fn _name -> "/usr/bin/loginctl" end,
          username: fn _opts -> "ada" end,
          cmd: fn "loginctl", _args -> {"yes\n", 0} end
        )

      assert result.name == "linger"
      assert result.status == :ok
      assert result.detail =~ "survives logout"
    end

    test "disabled fails with the one command that fixes it" do
      result =
        Checks.linger(
          linux?: true,
          build_info: PackagedBuildInfo,
          find_executable: fn _name -> "/usr/bin/loginctl" end,
          username: fn _opts -> "ada" end,
          cmd: fn "loginctl", _args -> {"no\n", 0} end
        )

      assert result.status == :fail
      assert result.detail =~ "sudo loginctl enable-linger ada"
    end

    # An absent login manager is a different outcome with NO command: there is
    # nothing for the operator to run until systemd's login manager exists.
    test "an absent loginctl warns and names no command" do
      result =
        Checks.linger(
          linux?: true,
          build_info: PackagedBuildInfo,
          find_executable: fn _name -> nil end
        )

      assert result.status == :warn
      assert result.detail =~ "Install systemd's login manager on this host."
      refute result.detail =~ "enable-linger"
    end

    test "an account Fermix cannot determine is its own warning" do
      result =
        Checks.linger(
          linux?: true,
          build_info: PackagedBuildInfo,
          find_executable: fn _name -> "/usr/bin/loginctl" end,
          username: fn _opts -> nil end
        )

      assert result.status == :warn
      assert result.detail =~ "which account"
    end

    test "a loginctl that will not answer quotes it rather than assuming off" do
      result =
        Checks.linger(
          linux?: true,
          build_info: PackagedBuildInfo,
          find_executable: fn _name -> "/usr/bin/loginctl" end,
          username: fn _opts -> "ada" end,
          cmd: fn "loginctl", _args -> {"Failed to look up user", 1} end
        )

      assert result.status == :warn
      assert result.detail =~ "Failed to look up user"
    end
  end

  # M38 §4.5, §11.3. A packaged install owns no unit of its own, so the question
  # is whether the package's unit is effective and a home is bound to it.
  describe "service_unit/1 on a packaged install" do
    test "the vendor unit with a bound home passes" do
      result = packaged_unit_row(packaged_status())

      assert result.status == :ok
      assert result.detail =~ "/home/ada/.fermix"
    end

    test "a legacy generated unit warns with the adoption verb" do
      status =
        put_in(packaged_status(), ["unit"], %{
          "effective_path" => "/home/ada/.config/systemd/user/fermix.service",
          "vendor" => false,
          "legacy_generated" => true,
          "foreign" => false,
          "need_daemon_reload" => false
        })

      result = packaged_unit_row(status)

      assert result.status == :warn
      assert result.detail =~ "Run `fermix service install` to adopt this service."
      assert result.detail =~ "/home/ada/.config/systemd/user/fermix.service"
    end

    # A file Fermix did not write is named and left alone, never rewritten as
    # drift: the standalone row's whole job is the opposite and must not leak.
    test "a foreign unit fails naming its path" do
      status =
        put_in(packaged_status(), ["unit"], %{
          "effective_path" => "/etc/systemd/user/fermix.service",
          "vendor" => false,
          "legacy_generated" => false,
          "foreign" => true,
          "need_daemon_reload" => false
        })

      result = packaged_unit_row(status)

      assert result.status == :fail
      assert result.detail =~ "/etc/systemd/user/fermix.service"
      refute result.detail =~ "stale"
    end

    test "an unbound home warns rather than reporting a working service" do
      status =
        put_in(packaged_status(), ["binding"], %{
          "state" => "unbound",
          "home" => nil,
          "reason" => nil
        })

      result = packaged_unit_row(status)

      assert result.status == :warn
      assert result.detail =~ "no home is bound"
    end

    test "a malformed binding fails with the reason the reader can act on" do
      status =
        put_in(packaged_status(), ["binding"], %{
          "state" => "invalid",
          "home" => nil,
          "reason" => "the recorded home is not an absolute path"
        })

      result = packaged_unit_row(status)

      assert result.status == :fail
      assert result.detail =~ "not an absolute path"
    end

    test "a pending reload warns" do
      status = put_in(packaged_status(), ["unit", "need_daemon_reload"], true)
      result = packaged_unit_row(status)

      assert result.status == :warn
      assert result.detail =~ "reload"
    end

    # An unreachable user manager is not a broken unit: it is a session with no
    # service manager, and it keeps the sentence the CLI already publishes.
    test "an unreachable user manager warns with the published sentence" do
      result = Checks.service_unit(build_info: PackagedBuildInfo, service: RefusingService)

      assert result.status == :warn
      assert result.detail =~ "no user service manager"
    end

    defp packaged_unit_row(status) do
      Process.put(:fake_service_status, status)

      Checks.service_unit(build_info: PackagedBuildInfo, service: AnsweringService)
    end

    defp packaged_status do
      %{
        "binding" => %{"state" => "bound", "home" => "/home/ada/.fermix", "reason" => nil},
        "unit" => %{
          "effective_path" => "/usr/lib/systemd/user/fermix.service",
          "vendor" => true,
          "legacy_generated" => false,
          "foreign" => false,
          "need_daemon_reload" => false
        }
      }
    end
  end
end
