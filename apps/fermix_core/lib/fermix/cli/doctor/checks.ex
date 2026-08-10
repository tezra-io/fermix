defmodule Fermix.CLI.Doctor.Checks do
  @moduledoc """
  The individual diagnostic checks `fermix doctor` runs.

  Every check returns a `result` map shaped
  `%{name: name, status: :ok | :warn | :fail, detail: string}`. The
  caller (`Fermix.CLI.Doctor`) renders these uniformly. Checks that
  hit the network are gated by the `:full` opt so the default
  invocation stays fast and offline.
  """

  alias Fermix.CLI.AcpCommand
  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Service
  alias Fermix.CLI.Upgrade.Manifest
  alias Fermix.CLI.VersionSkew
  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config, as: BrowserConfig
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Harness.Artifacts, as: HarnessArtifacts
  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Harness.Ledger, as: HarnessLedger
  alias FermixCore.Harness.Vendors, as: HarnessVendors
  alias FermixCore.Nostr.Key, as: NostrKey
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Plugins.Status, as: PluginStatus
  alias FermixCore.Prompt.TemplateRenderer
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Providers.Selection
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Resource.Registry, as: ResourceRegistry
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Mode, as: SandboxMode
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Doctor, as: ProviderProbe
  alias FermixCore.Setup.SecretMigration
  alias FermixCore.SkillCuration.Config, as: SkillCurationConfig
  alias FermixCore.SkillCuration.Delivery, as: SkillCurationDelivery

  @type status :: :ok | :warn | :fail
  @type result :: %{name: String.t(), status: status(), detail: String.t()}

  @sandbox_trace_days 7
  @sandbox_trace_limit 20

  # {vendor, run-tool name} pairs — the boot-registry vs current-PATH mismatch
  # (§7.3) compares each run tool's registration against its vendor's detection.
  @harness_run_tools [{"codex", "codex_run"}, {"claude", "claude_code_run"}]
  @bytes_per_gb 1_073_741_824

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

  @spec daemon_socket(keyword()) :: result()
  def daemon_socket(opts \\ []) do
    client = Keyword.get(opts, :client, &Client.status/0)

    case client.() do
      {:ok, %{"status" => "ok", "version" => version, "uptime_ms" => uptime_ms}} ->
        daemon_socket_result(version, uptime_ms)

      {:ok, other} ->
        warn("daemon socket", "unexpected reply: #{inspect(other)}")

      {:error, :not_running} ->
        warn("daemon socket", "not running (start with `fermix start`)")

      {:error, reason} ->
        fail("daemon socket", inspect(reason))
    end
  end

  # A daemon on a different version than this binary is the stale state a
  # package-manager upgrade leaves behind (brew swaps the binary on disk,
  # the service keeps running the old release) — warn, don't pass.
  defp daemon_socket_result(version, uptime_ms) do
    detail = "running, version #{version}, up #{format_uptime(uptime_ms)}"

    case VersionSkew.note(version) do
      nil -> ok("daemon socket", detail)
      note -> warn("daemon socket", "#{detail}; #{note}")
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

  # Predicates are injectable for the same reason `daemon_socket/1` injects its
  # client: the real ones answer from THIS host, so neither branch below is
  # reachable from a test otherwise.
  @spec service_unit(keyword()) :: result()
  def service_unit(opts \\ []) when is_list(opts) do
    installed? = Keyword.get(opts, :installed?, &installed_safe?/1)
    drifted? = Keyword.get(opts, :drifted?, &drifted_safe?/1)

    cond do
      installed?.(:user) -> unit_result(:user, drifted?)
      installed?.(:system) -> unit_result(:system, drifted?)
      true -> warn("service unit", "no unit installed (run `fermix service install`)")
    end
  end

  # "Installed" was the whole check, so a unit written by an older version read
  # green forever — including one whose daemon PATH predates a fix that only
  # takes effect once the unit is rewritten. Nothing else reports this: `upgrade`
  # never rewrites the unit (and refuses outright on a Homebrew install), and the
  # Homebrew caveats already say to re-run `fermix setup` "if the service unit
  # drifted" — an instruction no surface could answer until now.
  defp unit_result(scope, drifted?) do
    if drifted?.(scope) do
      warn(
        "service unit",
        "#{scope}-scope unit is stale — it no longer matches what this version of fermix " <>
          "writes, so the daemon may be running with outdated settings (e.g. an older PATH, " <>
          "which is how coding-agent CLIs go undetected). Run `fermix setup` to rewrite and " <>
          "reload it."
      )
    else
      ok("service unit", "#{scope}-scope unit installed")
    end
  end

  defp installed_safe?(scope) do
    Service.installed?(scope)
  rescue
    _ -> false
  end

  # Same posture as `installed_safe?/1`, and the direction matters: `drifted?/2`
  # renders a fresh spec to compare against, which raises when the fermix binary
  # cannot be resolved. Unknown reports NOT stale, because a false "stale" would
  # send the operator to rewrite a unit that is fine.
  defp drifted_safe?(scope) do
    Service.drifted?(scope)
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
  `place_search` readiness (M31 §14.3): the shared Brave key, the active
  `web_search` backend, and whether the tool is advertised.

  Offline, always — this check takes no `full?` flag, so the default run cannot
  reach the network by any argument. The metered live probe is `place_probe/1`,
  which `Fermix.CLI.Doctor` calls only from its `--full` block. Having no Brave
  key is a normal configuration (the tool is optional and simply hidden), so it
  reports `:ok`, not a warning.
  """
  @spec place_search() :: result()
  def place_search do
    []
    |> ProviderProbe.place_search_report()
    |> format_place_search()
  end

  # Advertisement is the row's one fact: the tool answers it from the same
  # credential seam a `place_search` call would, so the row cannot claim a
  # readiness the runtime does not have. A missing key is a normal, optional
  # configuration, so it reads `:ok` and says how to enable the tool.
  defp format_place_search(%{advertised?: false} = report) do
    ok(
      "place search",
      "no Brave key — place_search hidden (optional; web backend #{report.backend}). " <>
        "Set [fermix_core.tools.web_search] brave_api_key in setup to enable it."
    )
  end

  defp format_place_search(report) do
    ok(
      "place search",
      "Brave key present, place_search advertised; web backend #{report.backend}. " <>
        "Web and place calls are metered separately."
    )
  end

  @doc """
  One metered live request to the place endpoint (M31 §14.3), for `--full` only.

  Fixed innocuous query, `count: 1`, result discarded, never anchored to the
  owner's saved location. Auth, rate-limit, schema, and transport failures each
  keep their own name, and a failure never switches provider — there is one
  adapter and no fallback. `opts` carries the `req_options`/`net_resolver`
  injection seam so tests stub the transport.
  """
  @spec place_probe(keyword()) :: result()
  def place_probe(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put(:full, true)
    |> ProviderProbe.place_search_report()
    |> format_place_probe()
  end

  defp format_place_probe(%{probe_result: :ok, result_count: count}) do
    ok(
      "place probe",
      "live place probe ok (#{count} result(s), discarded) — this probe is metered"
    )
  end

  defp format_place_probe(%{probe_error: reason}) do
    warn("place probe", "live place probe failed: #{reason} — this probe is metered")
  end

  defp format_place_probe(_report) do
    ok("place probe", "skipped — no Brave key configured, so no metered call was made")
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
  Transcription backend health: which speech-to-text backend is selected and
  whether its credential resolves. Offline only — never transcribes. Voice notes
  are optional, but the default backend is keyed (openai reuses the chat key), so
  a selected-backend-with-no-credential is a warning (the invisible-key-coupling
  the milestone exists to surface), not a hard failure.
  """
  @spec realtime() :: result()
  def realtime do
    config = RealtimeConfig.current()

    if config.enabled? do
      realtime_key_status(config)
    else
      ok("realtime voice", "disabled")
    end
  end

  # Realtime uses the plain `openai` provider key, not the Codex provider. A
  # Codex subscription / OAuth login configures `openai_codex` and does NOT
  # authorize the Realtime API, so an enabled companion with only Codex auth
  # fails at call time with no obvious cause. Surface it here.
  defp realtime_key_status(config) do
    case FermixCore.Config.provider_api_key(:openai) do
      {:ok, _key} ->
        ok("realtime voice", "enabled; OpenAI Realtime key present (model #{config.model})")

      {:error, _reason} ->
        warn(
          "realtime voice",
          "enabled but no OpenAI API key — the Realtime API needs an OpenAI Platform key (sk-...); " <>
            "a Codex subscription/OAuth login does not authorize it. Set the OpenAI provider key via `fermix setup`."
        )
    end
  end

  @doc """
  The ACP agent surface (M29 §9 item 5, §17.3): whether it is enabled, where its
  socket is, whether the listener is actually up, and which client identities the
  daemon is holding.

  Liveness is answered BY THE DAEMON over the control socket — `fermix doctor`
  runs in a tree-less VM where `Channels.Acp.Endpoint` never exists, so probing
  locally would report "down" on a perfectly healthy host. The socket path is
  resolved here because it is a pure `FERMIX_HOME` join (`Fermix.CLI.AcpCommand`
  owns it for the bridge verb), and its presence is a local file check.
  `:client` is injectable so each state is unit-testable.

  The identity list is read straight off disk, and **ahead of the `enabled`
  short-circuit**: identities are data, not a live surface. Turning ACP off is
  the most natural "disconnect" gesture an operator will reach for, and if the
  row went dark there, durable client credentials would sit under `FERMIX_HOME`
  with nothing showing them — the one place the consent-by-configuration story
  could leak. Disabling deletes nothing; `fermix acp forget` is the only
  deletion, and the row says so. Only the npub is ever printed.
  """
  @spec acp(keyword()) :: result()
  def acp(opts \\ []) when is_list(opts) do
    with_identities(acp_surface(opts), IdentityStore.list())
  end

  defp acp_surface(opts) do
    if Keyword.get(acp_config(), :enabled, true) == true do
      acp_enabled_result(Keyword.get(opts, :client, &Client.request/1))
    else
      ok("acp surface", "disabled")
    end
  end

  defp acp_config, do: Application.get_env(:fermix_channels, :acp, [])

  # A host that never connected a client reads exactly as it did before this
  # existed: no records, no extra words.
  defp with_identities(result, []), do: result

  defp with_identities(result, records) do
    {stored, failures} = Enum.split_with(records, &match?({:ok, _identity}, &1))

    %{
      result
      | detail: identity_detail(result.detail, stored, failures),
        status: escalate_identity_status(result.status, failures)
    }
  end

  defp identity_detail(detail, stored, failures) do
    [detail, connected_identities(stored), unusable_identities(failures)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  defp connected_identities([]), do: ""

  defp connected_identities(stored) do
    "#{length(stored)} connected (#{Enum.map_join(stored, ", ", &identity_summary/1)}) — " <>
      "disabling ACP deletes nothing, `fermix acp forget <npub>` (or `--all`) is the only deletion"
  end

  defp identity_summary({:ok, identity}) do
    "#{identity.kind} #{identity_npub(identity.id)}, " <>
      "last seen #{DateTime.to_iso8601(identity.last_seen)}"
  end

  # Every listed record is named by a validated public key — the store refuses
  # any other filename before it reaches this row — so the display form always
  # exists, and a missing one is a bug worth crashing on rather than a hex id
  # printed where the npub belongs.
  defp identity_npub(id) do
    {:ok, npub} = NostrKey.npub(id)
    npub
  end

  defp unusable_identities([]), do: ""

  defp unusable_identities(failures) do
    "unusable identity records: " <>
      Enum.map_join(failures, "; ", fn {:error, reason} ->
        AcpCommand.identity_error_message(reason)
      end)
  end

  # A record the daemon cannot read is a credential that will not work, which is
  # the `auth perms` treatment: fail the row and carry the fix line.
  defp escalate_identity_status(status, []), do: status
  defp escalate_identity_status(_status, _failures), do: :fail

  defp acp_enabled_result(client) do
    path = AcpCommand.socket_path()

    case client.("health") do
      {:ok, %{"status" => "ok", "health" => health}} ->
        acp_listener_result(acp_channel(health), path)

      {:error, :not_running} ->
        warn("acp surface", "enabled; daemon not running (start with `fermix start`); #{path}")

      {:error, reason} ->
        fail("acp surface", "could not ask the daemon: #{inspect(reason)}")

      {:ok, other} ->
        warn("acp surface", "unexpected reply: #{inspect(other)}")
    end
  end

  defp acp_channel(%{"channels" => channels}) when is_list(channels) do
    Enum.find(channels, &(Map.get(&1, "name") == "acp"))
  end

  defp acp_channel(_health), do: nil

  defp acp_listener_result(%{"process_alive" => true}, path) do
    if File.exists?(path) do
      ok("acp surface", "listening at #{path}")
    else
      warn("acp surface", "listener running but its socket is missing at #{path}")
    end
  end

  defp acp_listener_result(%{"process_alive" => false}, path) do
    fail(
      "acp surface",
      "enabled but its listener is not running — check daemon logs (socket: #{path})"
    )
  end

  defp acp_listener_result(other, _path) do
    warn("acp surface", "unexpected reply: #{inspect(other)}")
  end

  @spec transcription() :: result()
  def transcription do
    ProviderProbe.transcription_report()
    |> format_transcription()
  end

  defp format_transcription(%{status: :error, error: error}) do
    warn("transcription", error)
  end

  defp format_transcription(%{credential_present?: false} = report) do
    warn(
      "transcription",
      "backend #{report.backend} not configured — set a key in Transcription setup"
    )
  end

  defp format_transcription(%{backend: backend}) do
    ok("transcription", "backend #{backend} configured")
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

  @doc """
  Browser launch health on macOS: the disclaim exec shim must be present and
  able to resolve the private disclaim API, or every browser launch refuses
  (Chrome is never spawned undisclaimed — spawned directly it would inherit the
  daemon as TCC responsible process and raise App Management prompts keyed to
  the versioned install path). Elsewhere the shim is not used.
  """
  @spec browser_disclaim({atom(), atom()}) :: result()
  def browser_disclaim(os_type \\ :os.type())

  def browser_disclaim({:unix, :darwin}) do
    shim = Application.app_dir(:fermix_nif, "priv/disclaim")

    cond do
      not File.regular?(shim) ->
        fail("browser", "disclaim shim missing at #{shim} — rebuild fermix or reinstall")

      not disclaim_check_ok?(shim) ->
        fail("browser", "disclaim shim --check failed — browser launches will refuse until fixed")

      true ->
        browser_chrome_result()
    end
  end

  def browser_disclaim(_os_type), do: ok("browser", "disclaim shim not required on this OS")

  # `BrowserConfig.current/0` refuses an operator-authored `[fermix_core.browser]`
  # section that is out of range or names an unusable profile — the exact host
  # whose owner runs `fermix doctor` to find out why. Binding it with `{:ok, _}`
  # would kill the whole run with a MatchError and print nothing.
  defp browser_chrome_result do
    case BrowserConfig.current() do
      {:ok, config} -> browser_chrome_row(config)
      {:error, error} -> warn("browser", "disclaim shim ready; #{error.message}")
    end
  end

  defp browser_chrome_row(config) do
    case ChromeLauncher.find_executable(config, nil) do
      {:ok, path} -> ok("browser", "disclaim shim ready; Chrome at #{path}")
      {:error, _error} -> warn("browser", "disclaim shim ready; no Chrome/Chromium found")
    end
  end

  defp disclaim_check_ok?(shim) do
    match?({_output, 0}, System.cmd(shim, ["--check"], stderr_to_stdout: true))
  rescue
    # A present-but-unrunnable shim (e.g. lost exec bit) must surface as the
    # fail row above, not crash the doctor run.
    _error -> false
  end

  @doc """
  Coding-harness health (design §13): per-vendor binary + version + network-free
  auth state, boot-registry vs current-PATH mismatch (§7.3), run counts
  (active/pending/dead-letter), and artifact quota usage. Returns `nil` to skip
  when the harness is disabled AND no vendor CLI is present.

  Vendor detection, the capability registry, run counts, and the quota probe are
  all injectable (`:detections`, `:registry`, `:counts`, `:quota`,
  `:harness_enabled`) so the check unit-tests hermetically. Run counts and the
  registry lookup degrade to a skip when the memory repo / registry are
  unavailable (the tree-less CLI), never a crash.
  """
  @spec harness(keyword()) :: result() | nil
  def harness(opts \\ []) when is_list(opts) do
    enabled? = Keyword.get_lazy(opts, :harness_enabled, &HarnessConfig.enabled?/0)
    # `fermix doctor` is a tree-less CLI verb, so the vendor `--version` probe must
    # run unsupervised (a supervised host needs the daemon's CommandHost tree).
    detections = Keyword.get_lazy(opts, :detections, &harness_detect_all/0)

    cond do
      not enabled? and not any_vendor_available?(detections) -> nil
      enabled? -> enabled_harness_result(detections, opts)
      true -> disabled_harness_result(detections)
    end
  end

  @doc """
  Skill-curation delivery health (MILESTONE_26_SKILL_CURATION §6.6 rung 3):
  when the feature is on, name whether proposals have an owner-private
  delivery target — a CLI-only install would otherwise mine forever and
  deliver nothing, with the situation visible only here and in
  `/skills proposals`. Pure config reads, safe for the tree-less CLI. Returns
  `nil` to skip when curation is disabled.
  """
  @spec skill_curation(keyword()) :: result() | nil
  def skill_curation(opts \\ []) when is_list(opts) do
    enabled? = Keyword.get_lazy(opts, :skill_curation_enabled, &SkillCurationConfig.enabled?/0)
    memory? = Keyword.get_lazy(opts, :memory_enabled, &FermixCore.Memory.Config.enabled?/0)

    target =
      Keyword.get_lazy(opts, :delivery_target, fn ->
        SkillCurationDelivery.resolve_target()
      end)

    cond do
      not enabled? ->
        nil

      not memory? ->
        %{
          name: "skill curation",
          status: :warn,
          detail: "enabled but memory persistence is off — the curation clock will not run"
        }

      target == :no_delivery_target ->
        %{
          name: "skill curation",
          status: :warn,
          detail:
            "no owner-private delivery target; proposals will wait in /skills proposals — " <>
              "set owner_user_id on a channel or [fermix_core.jobs] default_delivery_target"
        }

      true ->
        {:ok, resolved} = target
        ok("skill curation", "proposals deliver to #{resolved.platform}:#{resolved.destination}")
    end
  end

  # `fermix doctor` is a tree-less CLI verb, so the default probe runs the vendor
  # `--version` unsupervised and reads `~/.codex`/`~/.claude`. `config/test.exs`
  # overrides `:harness_vendor_detector` with an inert stub so `mix test` never
  # spawns a real CLI or touches host auth (the SecretWriterStub precedent).
  defp harness_detect_all do
    case Application.get_env(:fermix_core, :harness_vendor_detector) do
      fun when is_function(fun, 0) -> fun.()
      _unset -> HarnessVendors.detect_all(supervised: false)
    end
  end

  defp any_vendor_available?(detections) do
    Enum.any?(detections, fn {_vendor, detection} -> detection.available? end)
  end

  # Enabled: the feature is on, so no CLI at all is a real fault (fail); an
  # installed-but-unauthenticated vendor, a boot/PATH mismatch, dead-lettered
  # deliveries, or a breached quota each warn; otherwise ok.
  defp enabled_harness_result(detections, opts) do
    counts = harness_counts(opts)
    quota = harness_quota(opts)
    mismatch = harness_mismatch(detections, opts)

    detail =
      [
        harness_vendor_detail(detections),
        harness_consent_detail(opts),
        harness_counts_detail(counts),
        harness_quota_detail(quota),
        mismatch
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("; ")

    %{
      name: "coding harness",
      status: harness_status(detections, counts, quota, mismatch),
      detail: detail
    }
  end

  # Disabled but a CLI is present (else `harness/1` skipped): a valid config, not
  # a fault — report the detected vendors and how to turn the feature on.
  defp disabled_harness_result(detections) do
    ok(
      "coding harness",
      "disabled in config; #{harness_vendor_detail(detections)} — enable [fermix_core.harness] to use"
    )
  end

  defp harness_status(detections, counts, quota, mismatch) do
    cond do
      harness_quota_fail?(quota) -> :fail
      harness_warn?(detections, counts, quota, mismatch) -> :warn
      true -> :ok
    end
  end

  # A breached artifact quota HARD-BLOCKS admission (no new run can start), so it
  # is the one harness fail. Everything else — no/absent CLI while enabled, a
  # boot/PATH mismatch, dead-letters, low free space — is operator-actionable but
  # not a hard block, so it warns (keeping `fermix doctor`'s exit code honest:
  # the on-by-default harness with no CLI installed must not fail the whole run).
  defp harness_quota_fail?({:error, {:artifact_quota, %{kind: :quota_exceeded}}}), do: true
  defp harness_quota_fail?(_other), do: false

  defp harness_warn?(detections, counts, quota, mismatch) do
    not any_vendor_available?(detections) or mismatch != nil or
      harness_quota_warn?(quota) or harness_dead_letter?(counts) or
      harness_unauthenticated?(detections)
  end

  defp harness_unauthenticated?(detections) do
    Enum.any?(detections, fn {_vendor, detection} ->
      detection.available? and detection.auth == :absent
    end)
  end

  defp harness_dead_letter?(:skipped), do: false
  defp harness_dead_letter?(%{dead_letter: dead_letter}), do: dead_letter > 0

  defp harness_quota_warn?(:ok), do: false

  defp harness_quota_warn?({:error, {:artifact_quota, %{kind: kind}}}),
    do: kind in [:below_min_free, :free_space_unknown]

  # First-use consent state (design §22): info-grade only — never a warn/fail by
  # itself, so it never enters `harness_status/4`. Injectable (`:harness_approved`)
  # so the check unit-tests without touching Application env.
  defp harness_consent_detail(opts) do
    approved? = Keyword.get_lazy(opts, :harness_approved, &HarnessConfig.approved?/0)
    if approved?, do: "consent: approved", else: "consent: not yet approved"
  end

  # Per-vendor one-liner: name + version (or "not installed") + auth word.
  defp harness_vendor_detail(detections) do
    detections
    |> Map.values()
    |> Enum.sort_by(& &1.vendor)
    |> Enum.map_join(", ", &harness_vendor_line/1)
  end

  defp harness_vendor_line(%{vendor: vendor, available?: false}), do: "#{vendor} not installed"

  defp harness_vendor_line(%{vendor: vendor, version: version, auth: auth}) do
    "#{vendor} #{version || "installed"} (#{harness_auth_word(auth)})"
  end

  defp harness_auth_word(:authenticated), do: "authenticated"
  defp harness_auth_word(:unverified), do: "auth unverified"
  defp harness_auth_word(:absent), do: "not authenticated"

  # Boot registry (which run tools seeded at boot) vs current-PATH detection: a
  # disagreement means a CLI was installed/removed since boot and a restart syncs
  # the advertised tools. Skipped (nil) when the registry is unavailable.
  defp harness_mismatch(detections, opts) do
    registry = Keyword.get(opts, :registry, CapabilityRegistry)

    case harness_registry_snapshot(registry) do
      :unavailable -> nil
      registered -> mismatch_from_snapshot(detections, registered)
    end
  end

  defp harness_registry_snapshot(registry) do
    Map.new(@harness_run_tools, fn {_vendor, tool} ->
      {tool, match?({:ok, _capability}, CapabilityRegistry.find(registry, tool))}
    end)
  rescue
    ArgumentError -> :unavailable
  end

  defp mismatch_from_snapshot(detections, registered) do
    mismatched =
      @harness_run_tools
      |> Enum.filter(fn {vendor, tool} ->
        Map.fetch!(registered, tool) != vendor_available?(detections, vendor)
      end)
      |> Enum.map(fn {vendor, _tool} -> vendor end)

    case mismatched do
      [] ->
        nil

      vendors ->
        "restart to sync #{Enum.join(vendors, ", ")} (boot registry differs from current PATH)"
    end
  end

  defp vendor_available?(detections, vendor) do
    case Map.get(detections, vendor) do
      %{available?: available?} -> available?
      _absent -> false
    end
  end

  # Run counts via the ledger; the memory repo may be unavailable in this VM
  # (the tree-less CLI / bootstrap_template_drift pattern), so guard the exit and
  # skip honestly.
  defp harness_counts(opts) do
    case Keyword.fetch(opts, :counts) do
      {:ok, counts} -> counts
      :error -> fetch_harness_counts()
    end
  end

  defp fetch_harness_counts do
    with {:ok, active} <- HarnessLedger.active_runs(),
         {:ok, pending} <- HarnessLedger.list(%{delivery_status: "pending"}, limit: 200),
         {:ok, dead} <- HarnessLedger.list(%{delivery_status: "dead_letter"}, limit: 200) do
      %{active: length(active), pending: length(pending), dead_letter: length(dead)}
    else
      _unavailable -> :skipped
    end
  catch
    :exit, _reason -> :skipped
  end

  defp harness_counts_detail(:skipped), do: "run counts skipped (memory repo unavailable)"

  defp harness_counts_detail(%{active: active, pending: pending, dead_letter: dead_letter}) do
    "#{active} active, #{pending} pending delivery, #{dead_letter} dead-letter"
  end

  # Same rule as the vendor probe above: a tree-less CLI verb cannot spawn under
  # the daemon's CommandHost. Omitting this raised out of the whole `doctor` run.
  defp harness_quota(opts) do
    case Keyword.fetch(opts, :quota) do
      {:ok, quota} -> quota
      :error -> HarnessArtifacts.admission_check(supervised: false)
    end
  end

  defp harness_quota_detail(:ok), do: "artifacts within quota"

  defp harness_quota_detail({:error, {:artifact_quota, detail}}), do: harness_quota_issue(detail)

  defp harness_quota_issue(%{kind: :quota_exceeded, used_bytes: used, quota_bytes: quota}) do
    "artifact quota exceeded (#{harness_gb(used)}/#{harness_gb(quota)} GB)"
  end

  defp harness_quota_issue(%{kind: :below_min_free, free_bytes: free}) do
    "low free space (#{harness_gb(free)} GB free)"
  end

  defp harness_quota_issue(%{kind: :free_space_unknown}), do: "free space unknown"

  defp harness_gb(bytes), do: Float.round(bytes / @bytes_per_gb, 1)

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

  @doc """
  Enabled plugins (M27 §7.8): per plugin, the install/compat state and the
  static `Plugins.Status` ladder, plus — for `remote_mcp` plugins — the live
  runtime status.

  Two facts shape this check:

    * **The runtime status table lives in the daemon**, keyed by the
      source-qualified `{:plugin, name}`. A one-shot CLI VM has no such table,
      so it is asked for over the control socket (`plugins_runtime_status`). A
      locally absent table is reported as unknown; it is NEVER read as `:ready`.
    * **`fermix doctor` is a tree-less CLI verb.** The static ladder probes an
      mcp-rail plugin's declared host runtime, which spawns a command — and
      `CommandRunner.resolve_supervisor!/1` RAISES without the daemon's
      `CommandHost.Supervisor`. The probe must therefore run unsupervised, the
      same threading `PluginsCommand.plugin_row/1` and `harness/1` do.

  `:client` and `:installed_root` are injectable so each state unit-tests
  hermetically.
  """
  @spec plugins(keyword()) :: result()
  def plugins(opts \\ []) when is_list(opts) do
    case Enum.sort(PluginConfig.enabled_plugins()) do
      [] -> ok("plugins", "none enabled")
      names -> enabled_plugins_result(names, opts)
    end
  end

  defp enabled_plugins_result(names, opts) do
    root_opts = Keyword.take(opts, [:installed_root])

    case PluginRegistry.list(root_opts) do
      {:ok, plugins} ->
        index = Map.new(plugins, &{&1.name, &1})
        entries = Enum.map(names, &plugin_entry(&1, index, root_opts))
        render_plugins(entries, plugin_runtime_statuses(entries, opts))

      {:error, reason} ->
        fail("plugins", "plugin catalog unreadable: #{inspect(reason)}")
    end
  end

  # An enabled name with no loadable manifest is statusable too: `Status` reads
  # the store and distinguishes `:not_installed` from `:incompatible`. Only a
  # `%Plugin{}` can declare the remote runtime.
  defp plugin_entry(name, index, root_opts) do
    status_opts = [probe: [supervised: false]] ++ root_opts

    case Map.fetch(index, name) do
      {:ok, plugin} ->
        %{
          name: name,
          status: PluginStatus.status(plugin, status_opts),
          remote?: McpSource.remote?(plugin)
        }

      :error ->
        %{name: name, status: PluginStatus.status(name, status_opts), remote?: false}
    end
  end

  # Only a remote source registers an owner in the daemon's status table, so a
  # host with no remote plugin never pays for the socket round trip — and an
  # empty table is the truthful answer there, since no entry will consult it.
  defp plugin_runtime_statuses(entries, opts) do
    if Enum.any?(entries, & &1.remote?) do
      fetch_runtime_statuses(Keyword.get(opts, :client, &Client.request/1))
    else
      {:ok, %{}}
    end
  end

  defp fetch_runtime_statuses(client) do
    case client.("plugins_runtime_status") do
      {:ok, %{"status" => "ok", "runtime_status" => rows}} when is_list(rows) ->
        index_runtime_rows(rows)

      {:error, :not_running} ->
        :daemon_down

      {:error, reason} ->
        {:error, inspect(reason)}

      {:ok, other} ->
        {:error, "unexpected reply: #{inspect(other)}"}
    end
  end

  # Both fields come from the daemon's own serializer, so a row missing either is
  # a broken or version-skewed build — reported as a failed query rather than
  # rendered as a plugin whose runtime state is blank.
  defp index_runtime_rows(rows) do
    if Enum.all?(rows, &valid_runtime_row?/1) do
      {:ok, Map.new(rows, &{&1["source"], &1["status"]})}
    else
      {:error, "malformed runtime_status rows"}
    end
  end

  defp valid_runtime_row?(%{"source" => source, "status" => status}),
    do: is_binary(source) and is_binary(status)

  defp valid_runtime_row?(_row), do: false

  defp render_plugins(entries, runtime) do
    details = Enum.map(entries, &plugin_detail(&1, runtime))

    %{
      name: "plugins",
      status: details |> Enum.map(& &1.status) |> worst_plugin_status(),
      detail: Enum.map_join(details, "; ", & &1.text)
    }
  end

  defp plugin_detail(%{remote?: false} = entry, _runtime) do
    %{status: static_plugin_status(entry.status), text: "#{entry.name}: #{entry.status}"}
  end

  defp plugin_detail(%{remote?: true} = entry, {:ok, live}) do
    case Map.fetch(live, "plugin:#{entry.name}") do
      {:ok, status} -> remote_live_detail(entry, status)
      :error -> remote_absent_detail(entry)
    end
  end

  # The design's exact wording (§7.8). The static ladder alone drives severity
  # here: a down daemon is the `daemon socket` check's finding, not this one's,
  # and repeating it once per remote plugin would bury the plugin's own state.
  defp plugin_detail(%{remote?: true} = entry, :daemon_down) do
    %{
      status: static_plugin_status(entry.status),
      text:
        "#{entry.name}: #{entry.status} (remote; runtime status unavailable — daemon not running)"
    }
  end

  # A reachable daemon that cannot answer is a real fault (version skew, or a
  # build without the op) — never silently treated as "no remote plugins".
  defp plugin_detail(%{remote?: true} = entry, {:error, message}) do
    %{
      status: :fail,
      text: "#{entry.name}: #{entry.status} (remote; runtime status query failed: #{message})"
    }
  end

  defp remote_live_detail(entry, status) do
    %{
      status: worst_plugin_status([static_plugin_status(entry.status), runtime_status(status)]),
      text: "#{entry.name}: #{entry.status} (remote; runtime #{status})"
    }
  end

  # The daemon is up and holds no owner for this source. When the plugin is not
  # startable the static ladder already says why; when it IS startable this is
  # the "enabled and credentialed but never connected" state — one reload or
  # restart away — which nothing else on the report would surface.
  defp remote_absent_detail(entry) do
    %{
      status: worst_plugin_status([static_plugin_status(entry.status), :warn]),
      text: "#{entry.name}: #{entry.status} (remote; no live client registered)"
    }
  end

  # Enabled but structurally unusable: the operator's config names a plugin this
  # build cannot run at all. Every other non-ready status is a setup step that
  # has not been finished yet.
  @plugin_broken_statuses [:not_installed, :incompatible, :error]

  defp static_plugin_status(:ready), do: :ok
  defp static_plugin_status(status) when status in @plugin_broken_statuses, do: :fail
  defp static_plugin_status(_status), do: :warn

  # The §7.8 terminal states that mean "do not call tools": a signed-contract,
  # collision, or endpoint-policy refusal is a defect, not a pending step.
  @remote_broken_statuses ~w(
    invalid_remote_config upstream_contract_mismatch capability_conflict
    remote_security_blocked remote_protocol_error
  )

  defp runtime_status("ready"), do: :ok
  defp runtime_status(status) when status in @remote_broken_statuses, do: :fail
  defp runtime_status(_status), do: :warn

  defp worst_plugin_status(statuses) do
    cond do
      :fail in statuses -> :fail
      :warn in statuses -> :warn
      true -> :ok
    end
  end

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

  @doc """
  Reports whether `FERMIX_HOME` itself is `0700`.

  The home holds `memory.db` — full conversation text — plus `config.toml` and
  every trace file; only `auth.json` carries its own `0600`. `ConfigStore`
  restricts the mode on every daemon boot, but deliberately only logs on
  failure, because returning an error there would take the supervision tree
  down. A home that could not be secured therefore has to surface here, which is
  the same division of labour `auth perms` already uses.
  """
  @spec home_permissions() :: result()
  def home_permissions do
    home = ConfigStore.fermix_home()

    case File.stat(home) do
      {:ok, %File.Stat{mode: mode}} ->
        home_permissions_result(home, Bitwise.band(mode, 0o777))

      {:error, reason} ->
        fail("home perms", "stat #{home}: #{inspect(reason)}")
    end
  end

  defp home_permissions_result(home, 0o700), do: ok("home perms", "#{home} is 0700")

  defp home_permissions_result(home, mode) do
    fail(
      "home perms",
      "#{home} is #{Integer.to_string(mode, 8)} — it holds memory.db, config.toml " <>
        "and traces. Fix with: chmod 700 #{home}"
    )
  end

  @doc """
  Reports whether `cosign` is on PATH.

  Two shipped features shell out to it and fail closed without it: `fermix
  upgrade` verifies the downloaded binary's keyless signature, and every plugin
  install verifies the plugin's. A Homebrew install pulls cosign in as a formula
  dependency; `curl | sh` does not, and Homebrew installs are the ones that
  never reach `fermix upgrade` anyway. So on the install path that actually uses
  the verifier, cosign is absent by default — and without this row the operator
  discovers that only when an upgrade or a plugin install refuses.
  """
  @spec cosign(keyword()) :: result()
  def cosign(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get_lazy(:cosign_path, fn -> System.find_executable("cosign") end)
    |> cosign_result()
  end

  defp cosign_result(nil) do
    warn(
      "cosign",
      "not on PATH — `fermix upgrade` and `fermix plugins install` both refuse " <>
        "without it. Install it from https://github.com/sigstore/cosign " <>
        "(`brew install cosign` on macOS)."
    )
  end

  defp cosign_result(path) when is_binary(path), do: ok("cosign", "present at #{path}")

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
