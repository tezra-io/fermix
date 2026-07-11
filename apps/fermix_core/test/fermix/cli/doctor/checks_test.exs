defmodule Fermix.CLI.Doctor.ChecksTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.Auth.Store

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

  describe "service_unit/0" do
    test "warns when no unit is installed (test environment has none)" do
      result = Checks.service_unit()
      assert result.name == "service unit"
      assert result.status in [:ok, :warn]
    end
  end

  describe "daemon_socket/0" do
    test "warns when nothing is listening" do
      result = Checks.daemon_socket()
      assert result.name == "daemon socket"
      assert result.status in [:ok, :warn, :fail]
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
      tmp = make_tmp_binary("not the real binary content")

      result =
        Checks.binary_integrity(
          binary_path: tmp,
          target: {:linux, :x86_64},
          req_options: [plug: &__MODULE__.bad_sha_manifest_plug/1]
        )

      assert result.status == :fail
      assert result.detail =~ "sha mismatch"
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
      assert result.detail =~ "matches"
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
              "url" => "https://example.com/bin",
              "sha256" => sha,
              "sig_url" => "https://example.com/bin.sig",
              "cert_url" => "https://example.com/bin.pem"
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
end
