defmodule Fermix.CLI.Upgrade do
  @moduledoc """
  Self-update orchestration for unmanaged installs.

  `check/1` fetches the release manifest and reports whether a newer
  version is available. `run/1` performs the full
  fetch → verify → snapshot → rename → restart → health-check
  sequence and rolls back from `~/.fermix/.previous` if the post-swap
  health check fails within `@health_check_timeout_ms`.

  Package-manager installs (Homebrew, dpkg) are detected up front
  and we refuse to mutate them; instead we print the right
  `brew upgrade` / `apt upgrade` command and exit non-zero so the
  operator knows to use their package manager.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Service
  alias Fermix.CLI.Upgrade.InstallMethod
  alias Fermix.CLI.Upgrade.Manifest
  alias Fermix.CLI.Upgrade.Swapper

  @health_check_timeout_ms 10_000
  @health_check_poll_ms 500
  @audit_filename "upgrades.jsonl"

  @type check_result :: %{
          current: String.t(),
          latest: String.t(),
          available: boolean(),
          install_method: InstallMethod.method()
        }

  @spec check(keyword()) :: {:ok, check_result()} | {:error, term()}
  def check(opts \\ []) do
    current = current_version()

    with {:ok, manifest} <- Manifest.fetch(opts) do
      {:ok,
       %{
         current: current,
         latest: manifest.latest,
         available: Manifest.compare_versions(current, manifest.latest) == :lt,
         install_method: InstallMethod.detect(Keyword.get(opts, :binary_path))
       }}
    end
  end

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    binary_path = Keyword.get(opts, :binary_path)

    case InstallMethod.detect(binary_path) do
      {:managed, name, hint} -> {:error, {:managed_install, name, hint}}
      {:error, reason} -> {:error, reason}
      {:unmanaged, installed_path} -> do_upgrade(installed_path, opts)
    end
  end

  defp do_upgrade(installed_path, opts) do
    current = current_version()

    with {:ok, manifest} <- Manifest.fetch(opts),
         :ok <- assert_newer(current, manifest.latest),
         {:ok, release} <- Manifest.latest_release(manifest),
         {:ok, target} <- Manifest.target_for_host(),
         {:ok, artifact} <- Manifest.select_artifact(release, target),
         {:ok, staged} <- Swapper.stage_artifact(artifact, opts),
         :ok <- Swapper.verify(staged, Keyword.put(opts, :version, manifest.latest)) do
      finalize(staged, artifact, current, manifest.latest, installed_path, opts)
    else
      {:error, _reason} = err ->
        record_audit(:error, current, "?", "?", opts)
        err
    end
  end

  # Pre-swap failures (download, sha, cosign verify) leave the current
  # binary untouched, so we must NOT trigger rollback from them — that
  # would overwrite the running binary with a stale ~/.fermix/.previous
  # from an earlier upgrade. Only the post-swap path may rollback.
  defp finalize(staged, artifact, current, latest, installed_path, opts) do
    case Swapper.swap(staged, installed_path, opts) do
      {:ok, _swap_info} ->
        case restart_and_health_check(opts) do
          :ok ->
            record_audit(:ok, current, latest, artifact.sha256, opts)
            :ok

          {:error, _reason} = err ->
            record_audit(:error, current, latest, artifact.sha256, opts)
            rollback(installed_path, opts)
            err
        end

      {:error, _reason} = err ->
        record_audit(:error, current, latest, artifact.sha256, opts)
        err
    end
  end

  defp assert_newer(current, latest) do
    case Manifest.compare_versions(current, latest) do
      :lt -> :ok
      :eq -> {:error, {:already_latest, latest}}
      :gt -> {:error, {:current_newer_than_latest, current, latest}}
      {:error, _} = err -> err
    end
  end

  defp restart_and_health_check(opts) do
    scope = Keyword.get(opts, :scope, :user)
    skip_restart? = Keyword.get(opts, :skip_restart, false)

    if skip_restart? do
      :ok
    else
      with :ok <- Service.restart(scope),
           :ok <- wait_for_health(opts) do
        :ok
      end
    end
  end

  defp wait_for_health(opts) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :health_timeout_ms, @health_check_timeout_ms)

    do_wait(deadline, opts)
  end

  defp do_wait(deadline, opts) do
    case Client.status(socket_path: Keyword.get(opts, :socket_path) || default_socket_path()) do
      {:ok, %{"status" => "ok"}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :health_check_timeout}
        else
          Process.sleep(@health_check_poll_ms)
          do_wait(deadline, opts)
        end
    end
  end

  defp rollback(installed_path, opts) do
    previous = Keyword.get(opts, :previous_path, Swapper.default_previous_path())

    case Swapper.rollback(previous, installed_path) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp record_audit(status, from, to, sha256, opts) do
    audit_path = Keyword.get(opts, :audit_path, default_audit_path())
    File.mkdir_p!(Path.dirname(audit_path))

    entry = %{
      from: from,
      to: to,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      sha256: sha256,
      status: to_string(status)
    }

    line = Jason.encode!(entry) <> "\n"
    File.write!(audit_path, line, [:append])
  end

  defp current_version do
    Application.spec(:fermix_core, :vsn)
    |> case do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp default_socket_path do
    Path.join(default_fermix_home(), "daemon.sock")
  end

  defp default_audit_path do
    Path.join(default_fermix_home(), @audit_filename)
  end

  defp default_fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end
end
