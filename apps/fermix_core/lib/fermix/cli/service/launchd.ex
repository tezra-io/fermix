defmodule Fermix.CLI.Service.Launchd do
  @moduledoc """
  launchd backend for `Fermix.CLI.Service`.

  Wraps `launchctl bootstrap | bootout | kickstart | kill` against the
  user (`gui/<uid>`) or system (`system`) domain. Each call shells
  out and returns `{:error, {:launchctl_failed, code, output}}` on
  non-zero exit so the caller can surface the failure verbatim.
  """

  @spec install(map()) :: :ok | {:error, term()}
  def install(%{scope: scope, unit_path: path}) do
    with :ok <- bootout_if_loaded(scope, path) do
      launchctl(["bootstrap", domain(scope), path])
    end
  end

  @spec uninstall(map()) :: :ok | {:error, term()}
  def uninstall(%{scope: scope, unit_path: path}) do
    bootout_if_loaded(scope, path)
  end

  # Plain `kickstart` (no `-k`): `-k` SIGKILLs the running instance, which under
  # `fermix restart`/`upgrade` killed the daemon mid-drain (launchctl last-exit
  # -9) and, with KeepAlive=true, produced a relaunch loop. Without `-k`,
  # `start` is idempotent (no-op if already running); graceful restart comes
  # from `stop` (SIGTERM) + KeepAlive relaunch. A drifted-unit reconcile still
  # swaps the plist via install's bootout+bootstrap, not via start.
  @spec start(map()) :: :ok | {:error, term()}
  def start(%{scope: scope, label: label}) do
    launchctl(["kickstart", "#{domain(scope)}/#{label}"])
  end

  @spec stop(map()) :: :ok | {:error, term()}
  def stop(%{scope: scope, label: label}) do
    launchctl(["kill", "TERM", "#{domain(scope)}/#{label}"])
  end

  defp bootout_if_loaded(scope, path) do
    case launchctl(["bootout", domain(scope), path], expect_existing: false) do
      :ok -> :ok
      {:error, {:launchctl_failed, _, _}} -> :ok
    end
  end

  defp domain(:user), do: "gui/#{user_uid()}"
  defp domain(:system), do: "system"

  defp user_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> raise RuntimeError, "id -u failed (#{code}): #{out}"
    end
  end

  defp launchctl(args, _opts \\ []) do
    case launchctl_runner().("launchctl", Enum.map(args, &to_string/1)) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:launchctl_failed, code, String.trim(out)}}
    end
  end

  # Injectable for tests (mirrors the `:secret_writer` seam); defaults to the
  # real `launchctl` shell-out. The runner takes (command, args) → {output, code}.
  defp launchctl_runner do
    Application.get_env(:fermix_core, :launchctl_runner, &default_launchctl/2)
  end

  defp default_launchctl(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  end
end
