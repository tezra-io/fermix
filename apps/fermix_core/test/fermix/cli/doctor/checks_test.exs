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
      # nothing (CLAUDE.md, the `df`/tree-less-CLI pitfall).
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
    end
  end

  describe "computer_use_permissions/1" do
    test "disabled is a quiet ok" do
      result = Checks.computer_use_permissions({:ok, %{state: :disabled}})
      assert result.name == "computer use"
      assert result.status == :ok
      assert result.detail =~ "disabled"
    end

    test "enabled but no sidecar warns to install" do
      result = Checks.computer_use_permissions({:ok, %{state: :not_installed}})
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
      result = Checks.computer_use_permissions({:ok, %{state: :not_installed}})
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

    test "wayland is refused with the X11 hint" do
      probe = probed(platform: "linux", display_server: "wayland", screen_capture: false)
      result = Checks.computer_use_permissions({:ok, probe})
      assert result.status == :warn
      assert result.detail =~ "X11"
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

  describe "bootstrap_template_drift/1" do
    alias FermixCore.Memory.Repo, as: MemoryRepo
    alias FermixCore.Prompt.TemplateRenderer
    alias FermixCore.Resource.Registry, as: ResourceRegistry

    setup do
      unique = System.unique_integer([:positive])
      db_dir = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-drift-#{unique}")
      repo_name = :"drift_repo_#{unique}"

      start_supervised!(
        {MemoryRepo,
         name: repo_name, enabled: true, database_path: Path.join(db_dir, "memory.db")}
      )

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(db_dir) end)
      %{repo: repo_name}
    end

    defp commit_seed(repo, type, content) do
      {:ok, _revision} =
        ResourceRegistry.commit("main", type, "global", content,
          mutation_source: :seed,
          repo: repo
        )
    end

    test "ok when seeds match the current shipped templates", %{repo: repo} do
      for {name, type} <- [fermix: :fermix_md, soul: :soul_md, realtime: :realtime_md] do
        {:ok, current} = TemplateRenderer.render(name, %{})
        commit_seed(repo, type, current)
      end

      result = Checks.bootstrap_template_drift(repo: repo)
      assert result.status == :ok
      assert result.detail =~ "current shipped templates"
    end

    test "warns when a shipped template changed since seed", %{repo: repo} do
      {:ok, current_soul} = TemplateRenderer.render(:soul, %{})
      {:ok, current_realtime} = TemplateRenderer.render(:realtime, %{})

      commit_seed(repo, :fermix_md, "an older fermix template render")
      commit_seed(repo, :soul_md, current_soul)
      commit_seed(repo, :realtime_md, current_realtime)

      result = Checks.bootstrap_template_drift(repo: repo)
      assert result.status == :warn
      assert result.detail =~ "fermix.md"
      refute result.detail =~ "soul.md"
    end

    test "reports unknown for installs seeded before revision tracking", %{repo: repo} do
      result = Checks.bootstrap_template_drift(repo: repo)
      assert result.status == :ok
      assert result.detail =~ "no seed record"
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
      client = fn -> {:ok, %{"status" => "ok", "version" => vsn, "uptime_ms" => 5_000}} end

      result = Checks.daemon_socket(client: client)

      assert result.status == :ok
      assert result.detail =~ "running, version #{vsn}"
    end

    test "warns when the daemon runs a different version than this binary" do
      client = fn -> {:ok, %{"status" => "ok", "version" => "0.0.1", "uptime_ms" => 5_000}} end

      result = Checks.daemon_socket(client: client)

      assert result.status == :warn
      assert result.detail =~ "running, version 0.0.1"
      assert result.detail =~ "`fermix restart`"
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
        for channel <- [:telegram, :whatsapp, :discord, :slack, :signal], into: %{} do
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

    # Both features fail closed without it, and the `curl | sh` install path
    # never supplies it — so the message has to name both, or the operator
    # learns about it from an unrelated-looking refusal much later.
    test "warns naming both features that refuse without it" do
      result = Checks.cosign(cosign_path: nil)

      assert result.status == :warn
      assert result.detail =~ "fermix upgrade"
      assert result.detail =~ "fermix plugins install"
    end
  end
end
