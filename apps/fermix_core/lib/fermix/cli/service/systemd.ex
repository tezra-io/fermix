defmodule Fermix.CLI.Service.Systemd do
  @moduledoc """
  systemd backend for `Fermix.CLI.Service`.

  Wraps `systemctl --user|<system>` and, for user-scope installs,
  `loginctl enable-linger`. The linger call is mandatory for reboot
  survival in user-scope; if it fails (sudo/polkit denied), the
  installer aborts with a non-zero exit code and the explicit
  command the operator must run before retrying.
  """

  @spec install(map()) :: :ok | {:error, term()}
  def install(%{scope: :user, linux_unit: unit}) do
    with :ok <- ensure_linger(),
         :ok <- systemctl(["--user", "daemon-reload"]),
         :ok <- systemctl(["--user", "enable", "--now", unit]) do
      :ok
    end
  end

  def install(%{scope: :system, linux_unit: unit}) do
    with :ok <- systemctl(["daemon-reload"]),
         :ok <- systemctl(["enable", "--now", unit]) do
      :ok
    end
  end

  @spec uninstall(map()) :: :ok | {:error, term()}
  def uninstall(%{scope: :user, linux_unit: unit}) do
    systemctl(["--user", "disable", "--now", unit])
  end

  def uninstall(%{scope: :system, linux_unit: unit}) do
    systemctl(["disable", "--now", unit])
  end

  @spec start(map()) :: :ok | {:error, term()}
  def start(%{scope: :user, linux_unit: unit}), do: systemctl(["--user", "start", unit])
  def start(%{scope: :system, linux_unit: unit}), do: systemctl(["start", unit])

  @spec stop(map()) :: :ok | {:error, term()}
  def stop(%{scope: :user, linux_unit: unit}), do: systemctl(["--user", "stop", unit])
  def stop(%{scope: :system, linux_unit: unit}), do: systemctl(["stop", unit])

  defp ensure_linger do
    user = System.get_env("USER") || raise ArgumentError, "USER env var unset"

    case System.cmd("loginctl", ["enable-linger", user], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        {:error,
         {:linger_failed, code,
          "loginctl enable-linger #{user} failed (exit #{code}): #{String.trim(out)}. " <>
            "Reboot survival requires linger; re-run after granting (e.g. via sudo)."}}
    end
  end

  defp systemctl(args) do
    case System.cmd("systemctl", Enum.map(args, &to_string/1), stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:systemctl_failed, code, String.trim(out)}}
    end
  end
end
