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

  @spec start(map()) :: :ok | {:error, term()}
  def start(%{scope: scope, label: label}) do
    launchctl(["kickstart", "-k", "#{domain(scope)}/#{label}"])
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
    case System.cmd("launchctl", Enum.map(args, &to_string/1), stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:launchctl_failed, code, String.trim(out)}}
    end
  end
end
