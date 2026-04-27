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
  alias FermixCore.Setup.ConfigStore

  @type status :: :ok | :warn | :fail
  @type result :: %{name: String.t(), status: status(), detail: String.t()}

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

  defp ok(name, detail), do: %{name: name, status: :ok, detail: detail}
  defp warn(name, detail), do: %{name: name, status: :warn, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
