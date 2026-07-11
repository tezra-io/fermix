defmodule Fermix.CLI.Doctor.Checks do
  @moduledoc """
  The individual diagnostic checks `fermix doctor` runs.

  Every check returns a `result` map shaped
  `%{name: name, status: :ok | :warn | :fail, detail: string}`. The
  caller (`Fermix.CLI.Doctor`) renders these uniformly. Checks that
  hit the network are gated by the `:full` opt so the default
  invocation stays fast and offline.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Service
  alias Fermix.CLI.Upgrade.Manifest
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Prompt.TemplateRenderer
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Providers.Selection
  alias FermixCore.Resource.Registry, as: ResourceRegistry
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Mode, as: SandboxMode
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Doctor, as: ProviderProbe
  alias FermixCore.Setup.SecretMigration

  @type status :: :ok | :warn | :fail
  @type result :: %{name: String.t(), status: status(), detail: String.t()}

  @sandbox_trace_days 7
  @sandbox_trace_limit 20

  @spec readiness() :: result()
  def readiness do
    report = FermixCore.Readiness.report()

    case report.status do
      :ready ->
        ok("readiness", "all configured integrations are present")

      :setup_required ->
        actions = Enum.map_join(report.failures, "; ", & &1.action)
        fail("readiness", actions)
    end
  end

  @spec workspace_layout() :: result()
  def workspace_layout do
    fermix_home = ConfigStore.fermix_home()
    paths = ConfigStore.workspace_paths()

    missing =
      [fermix_home | Map.values(paths)]
      |> Enum.reject(&File.exists?/1)

    case missing do
      [] -> ok("workspace", "FERMIX_HOME at #{fermix_home}")
      _ -> warn("workspace", "missing dirs: #{Enum.join(missing, ", ")}")
    end
  end

  @spec daemon_socket() :: result()
  def daemon_socket do
    case Client.status() do
      {:ok, %{"status" => "ok", "version" => version, "uptime_ms" => uptime_ms}} ->
        ok("daemon socket", "running, version #{version}, up #{format_uptime(uptime_ms)}")

      {:ok, other} ->
        warn("daemon socket", "unexpected reply: #{inspect(other)}")

      {:error, :not_running} ->
        warn("daemon socket", "not running (start with `fermix start`)")

      {:error, reason} ->
        fail("daemon socket", inspect(reason))
    end
  end

  # Opik readiness is answered BY THE DAEMON over the control socket — the env
  # var, loaded exporter, and attached reporter are the daemon's process state,
  # not this CLI's. `:client` is injectable so each state is unit-testable.
  @spec opik_readiness(keyword()) :: result()
  def opik_readiness(opts \\ []) do
    client = Keyword.get(opts, :client, &Client.request/1)

    case client.("observability") do
      {:ok, %{"status" => "ok", "observability" => obs}} ->
        render_opik(obs)

      {:error, :not_running} ->
        warn("opik export", "daemon not running (start with `fermix start`)")

      {:error, reason} ->
        fail("opik export", inspect(reason))

      {:ok, other} ->
        warn("opik export", "unexpected reply: #{inspect(other)}")
    end
  end

  defp render_opik(%{"status" => "disabled"}),
    do: ok("opik export", "off — set FERMIX_OPIK_ENABLED in the daemon env to enable")

  defp render_opik(%{"status" => "enabled_ready"} = obs),
    do: ok("opik export", "on -> #{obs["base_url"]} (project #{obs["project"]})")

  defp render_opik(%{"status" => "enabled_missing_app"}),
    do:
      fail(
        "opik export",
        "FERMIX_OPIK_ENABLED set but fermix_opik is not loaded — unexpected in a dev/prod build (it is bundled in-umbrella); likely a stripped or non-standard build"
      )

  defp render_opik(%{"status" => "enabled_not_attached"}),
    do:
      warn(
        "opik export",
        "FERMIX_OPIK_ENABLED set and app loaded, but the reporter is not attached — check daemon logs"
      )

  defp render_opik(other),
    do: warn("opik export", "unexpected observability report: #{inspect(other)}")

  @spec service_unit() :: result()
  def service_unit do
    cond do
      installed_safe?(:user) -> ok("service unit", "user-scope unit installed")
      installed_safe?(:system) -> ok("service unit", "system-scope unit installed")
      true -> warn("service unit", "no unit installed (run `fermix service install`)")
    end
  end

  defp installed_safe?(scope) do
    Service.installed?(scope)
  rescue
    _ -> false
  end

  @spec linger() :: result() | nil
  def linger do
    cond do
      not linux?() ->
        nil

      not Service.installed?(:user) ->
        nil

      true ->
        check_linger_state()
    end
  end

  @spec recent_log_activity() :: result()
  def recent_log_activity do
    log_path = log_path()

    case File.stat(log_path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        seconds_ago = age_seconds(mtime)

        cond do
          size == 0 -> warn("log activity", "log file is empty: #{log_path}")
          seconds_ago > 86_400 -> warn("log activity", "no log writes in 24h+ (#{log_path})")
          true -> ok("log activity", "last write #{seconds_ago}s ago at #{log_path}")
        end

      {:error, :enoent} ->
        warn("log activity", "no log file at #{log_path}")

      {:error, reason} ->
        fail("log activity", "stat #{log_path}: #{inspect(reason)}")
    end
  end

  @spec binary_integrity(keyword()) :: result()
  def binary_integrity(opts \\ []) do
    binary_path = Keyword.get(opts, :binary_path) || System.find_executable("fermix")

    cond do
      is_nil(binary_path) ->
        warn("binary integrity", "fermix not on PATH; skipping")

      not File.exists?(binary_path) ->
        fail("binary integrity", "binary missing at #{binary_path}")

      true ->
        compare_against_manifest(binary_path, opts)
    end
  end

  @spec auth_probe(keyword()) :: result()
  def auth_probe(opts \\ []) do
    case ProviderProbe.probe_active(opts) do
      {:ok, %{provider: provider, model: model, latency_ms: ms}} ->
        ok("auth probe", "#{provider}/#{model} responded in #{ms}ms")

      {:error, {:misconfigured, message}} ->
        warn("auth probe", message)

      {:error, {:auth_scope_mismatch, surface, hint}} ->
        fail("auth probe", "auth rejected by #{surface}: #{hint}")

      {:error, {:server_error, status, _body}} ->
        warn("auth probe", "provider returned HTTP #{status} (transient?)")

      {:error, {:network, reason}} ->
        warn("auth probe", "network error: #{inspect(reason)}")
    end
  rescue
    # E.g. hand-edited config with multiple primary providers — report it
    # as a failed check instead of aborting the whole --full run.
    error in ArgumentError -> fail("auth probe", Exception.message(error))
  end

  # Fallback health (§8): configured non-primary providers are listed as
  # fallback availability, never as primary readiness blockers. Presence
  # only — the live probe stays on the primary.
  @spec fallback_providers() :: result()
  def fallback_providers do
    case Selection.fallback_providers() do
      {:ok, []} ->
        ok("provider fallbacks", "none configured — failover disabled")

      {:ok, fallbacks} ->
        ok("provider fallbacks", "configured: #{Enum.map_join(fallbacks, ", ", &to_string/1)}")

      {:error, reason} ->
        fail("provider fallbacks", "route selection failed: #{inspect(reason)}")
    end
  end

  @spec channel_health(keyword()) :: result()
  def channel_health(opts \\ []) do
    ProviderProbe.probe_channels(opts)
    |> format_channel_health()
  end

  @spec compaction_config() :: result()
  def compaction_config do
    report = ProviderProbe.compaction_report()

    state =
      if report.enabled do
        "enabled"
      else
        "disabled"
      end

    ok(
      "compaction",
      "#{state}, threshold #{format_threshold(report.threshold)}, route #{report.provider}/#{report.model}, " <>
        "context window #{report.context_window}, compact at #{report.compact_at_tokens} tokens; " <>
        "catalog #{length(report.catalog)} model windows"
    )
  rescue
    error in ArgumentError -> fail("compaction", Exception.message(error))
  end

  @doc """
  Bootstrap template drift (M10 P5): compares the CURRENT shipped template
  render against the content the `:seed` revision recorded at install time.
  A mismatch means the shipped template gained changes after this install
  was seeded — the operator's file may lag and deserves a manual diff.
  Variable-free templates only (fermix/soul/realtime); IDENTITY.md embeds
  the agent name, so a render comparison cannot distinguish template drift
  from a rename. Installs seeded before revision tracking report unknown.
  """
  @spec bootstrap_template_drift(keyword()) :: result()
  def bootstrap_template_drift(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "main")

    {drifted, unknown} =
      [fermix: :fermix_md, soul: :soul_md, realtime: :realtime_md]
      |> Enum.reduce({[], []}, fn {name, type}, {drifted, unknown} ->
        case template_drift_state(agent_id, name, type, opts) do
          :current -> {drifted, unknown}
          :drifted -> {[name | drifted], unknown}
          :unknown -> {drifted, [name | unknown]}
        end
      end)

    cond do
      drifted != [] ->
        warn(
          "bootstrap templates",
          "shipped template(s) changed since this install was seeded: " <>
            "#{drifted |> Enum.reverse() |> Enum.map_join(", ", &"#{&1}.md")} — " <>
            "diff your bootstrap file(s) against the current template for missed improvements"
        )

      unknown != [] ->
        ok(
          "bootstrap templates",
          "no seed record for #{unknown |> Enum.reverse() |> Enum.map_join(", ", &"#{&1}.md")} " <>
            "(seeded before revision tracking); others match the shipped templates"
        )

      true ->
        ok("bootstrap templates", "seeded from the current shipped templates")
    end
  catch
    # Doctor must not crash when the memory repo is unavailable in this VM;
    # report the honest skip instead.
    :exit, _reason -> ok("bootstrap templates", "skipped (memory repo unavailable)")
  end

  defp template_drift_state(agent_id, name, type, opts) do
    registry_opts = Keyword.take(opts, [:repo])

    with {:ok, revisions} <-
           ResourceRegistry.list_revisions(agent_id, type, "global", registry_opts),
         %{content: seeded} <- Enum.find(revisions, &(&1.mutation_source == "seed")),
         {:ok, current} <- TemplateRenderer.render(name, %{}) do
      if String.trim_trailing(seeded) == String.trim_trailing(current),
        do: :current,
        else: :drifted
    else
      _no_seed_record -> :unknown
    end
  end

  @spec web_search(boolean()) :: result()
  def web_search(full? \\ false) do
    [full: full?]
    |> ProviderProbe.web_search_report()
    |> format_web_search()
  end

  defp format_web_search(%{credential_present?: false} = report) do
    warn("web search", "backend #{report.backend} selected but no credential configured")
  end

  defp format_web_search(%{probe_result: :ok, result_count: count} = report) do
    ok("web search", "backend #{report.backend}, live probe ok (#{count} result(s))")
  end

  defp format_web_search(%{probe_result: tag} = report) do
    warn("web search", "backend #{report.backend}, live probe #{tag}")
  end

  defp format_web_search(report) do
    ok("web search", "backend #{report.backend} configured")
  end

  @doc """
  Image-generation backend health: which backend is selected and whether its
  credential is present. Offline only — never bills the operator with a live
  image call. Not configuring `generate_image` is normal (optional capability),
  so the absent case is `:ok`, not a warning.
  """
  @spec image_generation() :: result()
  def image_generation do
    ProviderProbe.image_report()
    |> format_image_generation()
  end

  defp format_image_generation(%{status: :unconfigured}) do
    ok("image generation", "not configured (optional)")
  end

  defp format_image_generation(%{status: :error, error: error}) do
    warn("image generation", error)
  end

  defp format_image_generation(%{credential_present?: false} = report) do
    warn("image generation", "backend #{report.backend} selected but no credential configured")
  end

  defp format_image_generation(%{backend: backend}) do
    ok("image generation", "backend #{backend} configured")
  end

  @doc """
  Computer-use OS-permission state (docs/design/COMPUTER_USE_V2.md, Phase A). The
  load-bearing case is macOS: a GRANTED screen capture but DENIED input control is
  the silent-dropped-click symptom — `CGEventPost` is discarded without Accessibility,
  so a click returns ok yet nothing moves. The check names the exact fix. Probes the
  sidecar only when the feature is enabled and installed (otherwise it stays cheap).
  """
  @spec computer_use_permissions({:ok, map()} | {:error, term()}) :: result()
  def computer_use_permissions(result \\ ProviderProbe.computer_use_permissions()) do
    case result do
      {:ok, %{state: :disabled}} ->
        ok("computer use", "disabled")

      {:ok, %{state: :not_installed}} ->
        warn(
          "computer use",
          "enabled but the helper isn't installed — install it from setup#{install_version_note()}"
        )

      {:ok, %{state: :probed} = probe} ->
        format_computer_use_probe(probe)

      {:error, reason} ->
        fail("computer use", "could not probe the helper: #{inspect(reason)}")
    end
  end

  defp format_computer_use_probe(%{screen_capture: true, input_control: true} = probe) do
    ok(
      "computer use",
      "screen capture and input control granted (#{probe.display_server})#{sidecar_version_suffix()}"
    )
  end

  defp format_computer_use_probe(%{screen_capture: true, input_control: false} = probe) do
    warn("computer use", computer_use_input_hint(probe) <> sidecar_version_suffix())
  end

  defp format_computer_use_probe(%{screen_capture: false} = probe) do
    warn("computer use", computer_use_capture_hint(probe) <> sidecar_version_suffix())
  end

  # The compux sidecar version the daemon resolves the helper by (same source the
  # web setup shows) — appended so `fermix doctor` reveals which computer-use build
  # is actually installed/running. Empty when compux isn't loaded, so the suffix
  # simply drops.
  defp sidecar_version_suffix do
    case compux_version() do
      "" -> ""
      v -> " · sidecar compux v#{v}"
    end
  end

  defp install_version_note do
    case compux_version() do
      "" -> ""
      v -> " (installs compux v#{v})"
    end
  end

  defp compux_version, do: to_string(Application.spec(:compux, :vsn))

  # Platform-specific remediation: name the exact pane (macOS) or the X11 requirement
  # (Linux/Wayland) so the fix is one step, not a hunt.
  defp computer_use_input_hint(%{platform: "macos"}) do
    "screen capture OK but input control is NOT granted — clicks and keystrokes are " <>
      "silently dropped. Grant Accessibility: System Settings → Privacy & Security → Accessibility."
  end

  defp computer_use_input_hint(%{display_server: "wayland"}) do
    "input control unavailable on Wayland — global input injection is blocked; use an X11 session."
  end

  defp computer_use_input_hint(probe) do
    "input control is not available (#{probe.platform}/#{probe.display_server})."
  end

  defp computer_use_capture_hint(%{platform: "macos"}) do
    "screen capture is NOT granted — captures return wallpaper only. Grant Screen " <>
      "Recording: System Settings → Privacy & Security → Screen Recording."
  end

  defp computer_use_capture_hint(%{display_server: "wayland"}) do
    "screen capture unavailable on Wayland — use an X11 session (Wayland is unsupported)."
  end

  defp computer_use_capture_hint(probe) do
    "screen capture is not available (#{probe.platform}/#{probe.display_server})."
  end

  defp format_channel_health([]), do: ok("channel health", "no enabled channels configured")

  defp format_channel_health(probes) do
    detail = Enum.map_join(probes, "; ", &format_channel_probe/1)

    cond do
      Enum.any?(probes, &(&1.status == :error)) -> fail("channel health", detail)
      Enum.any?(probes, &(&1.status == :warn)) -> warn("channel health", detail)
      true -> ok("channel health", detail)
    end
  end

  defp format_channel_probe(probe), do: "#{probe.name}=#{probe.status} (#{probe.detail})"

  @spec command_owner_config() :: result()
  def command_owner_config do
    report = ProviderProbe.command_owner_report()

    missing =
      report
      |> Enum.filter(&(&1.enabled and is_nil(&1.owner_user_id)))
      |> Enum.map(& &1.channel)

    detail = Enum.map_join(report, ", ", &format_command_owner/1)

    case missing do
      [] ->
        ok("command owners", detail)

      channels ->
        warn(
          "command owners",
          "missing command owner for enabled channels: #{Enum.join(channels, ", ")}; #{detail}"
        )
    end
  end

  @doc """
  Channel streaming configuration sanity (docs/design/CHANNEL_STREAMING.md §7):
  `streaming = "draft"` on a channel that cannot edit drafts is a silent no-op
  at runtime, so doctor is the loud boundary. `"block"` sends ordinary messages
  and works on every channel — nothing to validate. There is deliberately no
  provider-streaming check — env overrides and per-run profiles make a
  config-derived provider warning wrong in both directions; provider capability
  shows up in stream telemetry instead.
  """
  @spec streaming_config([FermixCore.Setup.Doctor.streaming_report()]) :: result()
  def streaming_config(report \\ ProviderProbe.streaming_config_report()) do
    misconfigured =
      Enum.filter(report, &(&1.streaming == "draft" and &1.capability != :draft_edit))

    enabled = Enum.filter(report, &(&1.streaming != "off"))

    cond do
      misconfigured != [] ->
        warn(
          "channel streaming",
          "streaming = \"draft\" on channels that cannot edit drafts (ignored at runtime): " <>
            Enum.map_join(misconfigured, ", ", & &1.name)
        )

      enabled == [] ->
        ok("channel streaming", "off (no channel opted in)")

      true ->
        ok(
          "channel streaming",
          "streaming on: " <>
            Enum.map_join(enabled, ", ", fn entry -> "#{entry.name}=#{entry.streaming}" end)
        )
    end
  end

  @spec sandbox_config() :: result()
  def sandbox_config do
    config = SandboxConfig.current()
    roots = SandboxMode.effective_roots(config)

    ok(
      "sandbox",
      "mode #{config.mode}, roots #{length(roots)}, env #{length(config.env.allow)}, " <>
        "presets #{length(config.commands.presets)}"
    )
  rescue
    error in ArgumentError -> fail("sandbox", Exception.message(error))
  end

  @spec sandbox_trace_suggestions() :: result()
  def sandbox_trace_suggestions do
    suggestions =
      ConfigStore.workspace_paths().traces
      |> recent_sandbox_events()
      |> Enum.flat_map(&grant_suggestion/1)
      |> Enum.uniq()

    case suggestions do
      [] -> ok("sandbox traces", "no recent sandbox roadblocks")
      targets -> warn("sandbox traces", format_grant_suggestions(targets))
    end
  end

  @doc """
  Offline token-expiry sweep: flags any OAuth profile in the auth store whose
  access token is stale (well past expiry — `TokenExpiry.stale?/1`), i.e. dormant
  and likely needing re-auth. The cheap, no-network counterpart to `auth_probe`
  (which lives behind `--full`): a token that lapsed from disuse fails silently
  until its provider is next selected. Used providers refresh on access, so this
  only fires for genuinely idle ones.
  """
  @spec auth_token_expiry() :: result()
  def auth_token_expiry do
    case ProviderProbe.stale_token_profiles() do
      {:ok, []} ->
        ok("auth tokens", "no stale OAuth tokens")

      {:ok, names} ->
        warn("auth tokens", "stale, re-auth may be needed: #{Enum.join(names, ", ")}")

      {:error, reason} ->
        fail("auth tokens", "could not read auth store: #{inspect(reason)}")
    end
  end

  @spec auth_file_permissions() :: result()
  def auth_file_permissions do
    path = AuthStore.path()

    case AuthStore.validate_permissions(path) do
      :ok ->
        auth_ok_result(path)

      {:error, {:insecure_permissions, ^path, mode}} ->
        fail("auth perms", AuthStore.permissions_message(path, mode))

      {:error, reason} ->
        fail("auth perms", "stat #{path}: #{inspect(reason)}")
    end
  end

  @spec plaintext_secrets() :: result()
  def plaintext_secrets do
    with {:ok, snapshot} <- ConfigStore.load_runtime_config(resolve_secrets: false) do
      case SecretMigration.plaintext_secrets(snapshot) do
        [] ->
          ok("setup secrets", "no plaintext setup secrets in config.toml")

        secrets ->
          names = Enum.map_join(secrets, ", ", & &1.env)

          warn(
            "setup secrets",
            "plaintext setup secrets found in #{ConfigStore.path()}: #{names}; run `fermix setup --migrate-secrets`"
          )
      end
    else
      {:error, reason} ->
        fail("setup secrets", "could not inspect config.toml: #{inspect(reason)}")
    end
  end

  defp recent_sandbox_events(trace_dir) do
    trace_dir
    |> recent_sandbox_trace_files()
    |> Enum.flat_map(&read_jsonl_file/1)
  end

  defp recent_sandbox_trace_files(trace_dir) do
    today = Date.utc_today()

    0..(@sandbox_trace_days - 1)
    |> Enum.map(fn days_ago ->
      date = today |> Date.add(-days_ago) |> Date.to_iso8601()
      Path.join([trace_dir, date, "sandbox_event.jsonl"])
    end)
    |> Enum.filter(&File.exists?/1)
  end

  defp read_jsonl_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_jsonl_line/1)

      {:error, _reason} ->
        []
    end
  end

  defp decode_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, row} when is_map(row) -> [row]
      _other -> []
    end
  end

  defp grant_suggestion(%{
         "decision" => "deny",
         "reason_tag" => tag,
         "resource" => resource,
         "capability" => capability
       })
       when tag in ["outside_root", "blocked_root"] and is_binary(resource) do
    grant_target(capability, resource)
  end

  defp grant_suggestion(_row), do: []

  defp grant_target("shell", path), do: [path]
  defp grant_target("git_write", path), do: [path]
  defp grant_target("file_write", path), do: [Path.dirname(path)]
  defp grant_target("file_edit", path), do: [Path.dirname(path)]
  defp grant_target(_capability, _path), do: []

  defp format_grant_suggestions(targets) do
    shown = Enum.take(targets, @sandbox_trace_limit)
    remaining = length(targets) - length(shown)

    commands =
      shown
      |> Enum.map_join("; ", &"fermix grant path #{&1}")

    if remaining > 0 do
      "recent sandbox roadblocks: #{commands}; +#{remaining} more"
    else
      "recent sandbox roadblocks: #{commands}"
    end
  end

  @spec upgrade_available?(keyword()) :: result()
  def upgrade_available?(opts \\ []) do
    case Manifest.fetch(opts) do
      {:ok, manifest} ->
        case Manifest.compare_versions(current_version(), manifest.latest) do
          :lt -> warn("upgrade", "#{current_version()} -> #{manifest.latest} available")
          :eq -> ok("upgrade", "on the latest version (#{manifest.latest})")
          :gt -> warn("upgrade", "current #{current_version()} > latest #{manifest.latest}")
          {:error, reason} -> fail("upgrade", inspect(reason))
        end

      {:error, reason} ->
        fail("upgrade", inspect(reason))
    end
  end

  defp compare_against_manifest(binary_path, opts) do
    actual = sha256_file(binary_path)

    case Manifest.fetch(opts) do
      {:ok, manifest} ->
        target_match = match_artifact_sha(manifest, actual, opts)
        format_integrity_result(binary_path, actual, target_match)

      {:error, reason} ->
        warn("binary integrity", "could not fetch manifest: #{inspect(reason)}")
    end
  end

  defp match_artifact_sha(manifest, actual_sha, opts) do
    target =
      case Keyword.get(opts, :target) do
        nil -> Manifest.target_for_host()
        explicit -> {:ok, explicit}
      end

    with {:ok, t} <- target,
         {:ok, release} <- Manifest.latest_release(manifest),
         {:ok, artifact} <- Manifest.select_artifact(release, t) do
      if String.downcase(artifact.sha256) == actual_sha,
        do: {:match, manifest.latest},
        else: {:mismatch, artifact.sha256, manifest.latest}
    end
  end

  defp format_integrity_result(binary_path, actual, {:match, version}) do
    ok("binary integrity", "sha256 matches manifest for #{version} (#{actual_short(actual)})")
    |> Map.put(:detail, "binary at #{binary_path} matches releases.json (v#{version})")
  end

  defp format_integrity_result(_binary_path, actual, {:mismatch, expected, version}) do
    fail(
      "binary integrity",
      "sha mismatch vs manifest #{version}: got #{actual_short(actual)}, expected #{actual_short(expected)}"
    )
  end

  defp format_integrity_result(_binary_path, _actual, {:error, reason}) do
    warn("binary integrity", "could not match against manifest: #{inspect(reason)}")
  end

  defp actual_short(hex), do: String.slice(hex, 0, 12)

  defp sha256_file(path) do
    path
    |> File.stream!([], 64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp check_linger_state do
    user = System.get_env("USER") || ""

    case System.cmd("loginctl", ["show-user", user, "--property=Linger"], stderr_to_stdout: true) do
      {out, 0} ->
        if String.contains?(out, "Linger=yes") do
          ok("linger", "Linger=yes (reboot survival on)")
        else
          fail("linger", "Linger=no — reboot survival off; run `loginctl enable-linger #{user}`")
        end

      {_out, _code} ->
        warn("linger", "loginctl unavailable; cannot verify linger state")
    end
  end

  defp linux? do
    case :os.type() do
      {:unix, :linux} -> true
      _ -> false
    end
  end

  defp log_path do
    log_config = Application.get_env(:fermix_core, :log, [])
    Keyword.get(log_config, :file, default_log_file())
  end

  defp default_log_file do
    Path.join(ConfigStore.workspace_paths().logs, "fermix.log")
  end

  defp current_version do
    case Application.spec(:fermix_core, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp age_seconds(mtime) when is_tuple(mtime) do
    case NaiveDateTime.from_erl(mtime) do
      {:ok, ndt} ->
        seconds = NaiveDateTime.diff(NaiveDateTime.utc_now(), ndt, :second)
        max(seconds, 0)

      _ ->
        0
    end
  end

  defp format_uptime(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m"
    end
  end

  defp format_uptime(other), do: inspect(other)

  defp format_threshold(value) when is_float(value) do
    :erlang.float_to_binary(value, [:short])
  end

  defp format_command_owner(%{
         channel: channel,
         enabled: enabled,
         owner_user_id: owner_user_id,
         command_allowlist: allowlist
       }) do
    owner_state =
      if is_nil(owner_user_id) do
        "owner missing"
      else
        "owner set"
      end

    "#{channel}=#{owner_state}, enabled=#{enabled}, allowlist=#{length(allowlist)}"
  end

  defp auth_ok_result(path) do
    if File.exists?(path) do
      ok("auth perms", "auth.json is 0600 at #{path}")
    else
      ok("auth perms", "no auth.json present")
    end
  end

  @doc """
  Validates the `[fermix_core.routing]` `subagent_*`/`cron_*` model-routing keys.
  A typo'd provider/effort — especially in the UI-less `cron_*` keys — is caught
  here at the operator's desk rather than at the next unattended job fire.
  (Whether a routing provider is actually authed is the `auth_probe` check's job.)
  """
  @spec routing_overrides() :: result()
  def routing_overrides do
    subagent = RoutingOverrides.subagent()
    cron = RoutingOverrides.cron()

    case validate_routing_models([{"subagent_model", subagent}, {"cron_model", cron}]) do
      :ok ->
        ok(
          "routing",
          "subagent: #{describe_override(subagent)}; cron: #{describe_override(cron)}"
        )

      {:error, message} ->
        fail("routing", message)
    end
  rescue
    error in ArgumentError -> fail("routing", Exception.message(error))
  end

  # Parsing only proves the provider/effort *atoms* are known. A model slug is
  # free-form, so a typo or a model removed from the catalog (or left pointing at
  # the wrong provider after a primary switch — design §9) passes parsing and
  # then fails at the next job/subagent spawn. Catch it here at the operator's
  # desk: an explicit provider must actually offer the model; an inferred one
  # must resolve to some catalog provider.
  defp validate_routing_models(entries) do
    Enum.reduce_while(entries, :ok, fn {label, override}, :ok ->
      case validate_routing_model(override) do
        :ok -> {:cont, :ok}
        {:error, detail} -> {:halt, {:error, "[fermix_core.routing] #{label} #{detail}"}}
      end
    end)
  end

  defp validate_routing_model(%{model: nil}), do: :ok

  defp validate_routing_model(%{provider: provider, model: model})
       when is_atom(provider) and not is_nil(provider) and is_binary(model) do
    if ModelCatalog.known_model?(provider, model) do
      :ok
    else
      {:error, "= #{inspect(model)} is not a model offered by provider #{inspect(provider)}"}
    end
  end

  defp validate_routing_model(%{provider: nil, model: model}) when is_binary(model) do
    if ModelCatalog.provider_for_model(model) do
      :ok
    else
      {:error,
       "= #{inspect(model)} is not a known model for any provider " <>
         "(stale or typo'd — e.g. left over after a primary switch)"}
    end
  end

  defp describe_override(%{provider: nil, model: nil, reasoning_effort: nil}), do: "inherits main"

  defp describe_override(override) do
    [
      override.provider && "provider=#{override.provider}",
      override.model && "model=#{override.model}",
      override.reasoning_effort && "effort=#{override.reasoning_effort}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp ok(name, detail), do: %{name: name, status: :ok, detail: detail}
  defp warn(name, detail), do: %{name: name, status: :warn, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
