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

  @spec auth_file_permissions() :: result()
  def auth_file_permissions do
    path = AuthStore.path()

    case AuthStore.validate_permissions(path) do
      :ok -> auth_ok_result(path)
      {:error, {:insecure_permissions, ^path, mode}} -> fail("auth perms", AuthStore.permissions_message(path, mode))
      {:error, reason} -> fail("auth perms", "stat #{path}: #{inspect(reason)}")
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
          warn("setup secrets", "plaintext setup secrets found: #{names}; run `fermix setup --migrate-secrets`")
      end
    else
      {:error, reason} -> fail("setup secrets", "could not inspect config.toml: #{inspect(reason)}")
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

  defp ok(name, detail), do: %{name: name, status: :ok, detail: detail}
  defp warn(name, detail), do: %{name: name, status: :warn, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
