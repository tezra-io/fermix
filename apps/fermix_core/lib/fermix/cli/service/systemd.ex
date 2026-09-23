defmodule Fermix.CLI.Service.Systemd do
  @moduledoc """
  systemd backend for `Fermix.CLI.Service`, and the inspector behind
  `fermix service status` (M38 §4.4).

  Two jobs, one command surface. The legacy half installs and removes the
  standalone unit this binary writes for itself. The inspection half reads a
  user-scope unit the Linux package owns, and issues the lifecycle verbs the
  install transaction needs, without ever writing a unit file.

  Every `systemctl` and `loginctl` invocation goes through `opts[:cmd]`, a
  two-argument runner returning `{output, status}` — or `:absent`, when the
  command itself is not installed — so a test injects fixtures instead of
  reaching the host's service manager.

  **An unreachable user manager is not an inactive service.** `systemctl --user`
  on a host with no user bus (a container, an rpm image with no logind session)
  fails with "Failed to connect to bus", and reporting that as "inactive" sends
  an operator to restart a service that was never the problem. It is its own
  error on every verb.

  `loginctl enable-linger` is mandatory for reboot survival in user scope, and
  its failure is fatal before enablement: there is no degraded "works while
  logged in" half-state (M38 §4.3).
  """

  alias FermixCore.Harness.Identity

  # Requested as a set and read back by name. systemd answers `show` in its own
  # property order, not the order they were asked for, so a positional read files
  # a PID under a state — measured on systemd 257. Every one of these must come
  # back or the reply is refused; nothing here is defaulted.
  @show_properties ~w(
    LoadState UnitFileState ActiveState SubState MainPID ExecMainPID
    InvocationID NRestarts NeedDaemonReload FragmentPath DropInPaths
  )

  # `reset-failed` on a unit nothing has loaded yet exits non-zero saying so. A
  # unit with no state has no failed state to clear, which is this step's success
  # case: refusing there refuses every first install on a fresh account.
  @not_loaded_marker "not loaded"

  @unreachable_bus_markers [
    "Failed to connect to bus",
    "Failed to connect to user scope bus"
  ]

  @type failure ::
          :user_manager_unreachable
          | {:systemctl_failed, non_neg_integer(), String.t()}

  @spec install(map()) :: :ok | {:error, term()}
  def install(%{scope: :user, linux_unit: unit}) do
    with :ok <- linger_for_install(),
         :ok <- daemon_reload(),
         :ok <- enable_now(unit) do
      :ok
    end
  end

  def install(%{scope: :system, linux_unit: unit}) do
    with :ok <- systemctl(["daemon-reload"], []),
         :ok <- systemctl(["enable", "--now", unit], []) do
      :ok
    end
  end

  @spec uninstall(map()) :: :ok | {:error, term()}
  def uninstall(%{scope: :user, linux_unit: unit}), do: disable_now(unit)

  def uninstall(%{scope: :system, linux_unit: unit}) do
    systemctl(["disable", "--now", unit], [])
  end

  @spec start(map()) :: :ok | {:error, term()}
  def start(%{scope: :user, linux_unit: unit}), do: systemctl(["--user", "start", unit], [])
  def start(%{scope: :system, linux_unit: unit}), do: systemctl(["start", unit], [])

  @spec stop(map()) :: :ok | {:error, term()}
  def stop(%{scope: :user, linux_unit: unit}), do: systemctl(["--user", "stop", unit], [])
  def stop(%{scope: :system, linux_unit: unit}), do: systemctl(["stop", unit], [])

  @doc """
  The unit properties `service status` reports, read in one call.

  Returns a map keyed by the property names above, with systemd's own strings
  as values (`"inactive"`, `"0"`, `"no"`, `""`), so the caller decides what each
  one means rather than this module inventing a vocabulary.
  """
  @spec show(String.t(), keyword()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, failure() | {:missing_show_property, String.t()}}
  def show(unit, opts \\ []) when is_binary(unit) and is_list(opts) do
    args = ["--user", "show", unit, "-p", Enum.join(@show_properties, ",")]

    case run(args, opts) do
      :absent -> {:error, :user_manager_unreachable}
      {output, 0} -> parse_show(output)
      {output, status} -> {:error, failure(output, status)}
    end
  end

  @doc "Reloads unit definitions so an installed vendor-unit change takes effect."
  @spec daemon_reload(keyword()) :: :ok | {:error, failure()}
  def daemon_reload(opts \\ []) when is_list(opts) do
    systemctl(["--user", "daemon-reload"], opts)
  end

  @doc """
  Clears the unit's failure state and its start-limit budget.

  A unit the manager has never loaded answers non-zero with "Unit … not loaded."
  There is no failed state to clear on a unit with no state, which is exactly
  what this step wanted, so that one answer is success. Every other non-zero
  exit stays the refusal it is.
  """
  @spec reset_failed(String.t(), keyword()) :: :ok | {:error, failure()}
  def reset_failed(unit, opts \\ []) when is_binary(unit) and is_list(opts) do
    case run(["--user", "reset-failed", unit], opts) do
      :absent -> {:error, :user_manager_unreachable}
      {_output, 0} -> :ok
      {output, status} -> reset_failed_outcome(output, status)
    end
  end

  defp reset_failed_outcome(output, status) do
    if String.contains?(String.downcase(output), @not_loaded_marker),
      do: :ok,
      else: {:error, failure(output, status)}
  end

  @doc "Enables the unit for the next boot and starts it now."
  @spec enable_now(String.t(), keyword()) :: :ok | {:error, failure()}
  def enable_now(unit, opts \\ []) when is_binary(unit) and is_list(opts) do
    systemctl(["--user", "enable", "--now", unit], opts)
  end

  @doc "Disables the unit for the next boot and stops it now."
  @spec disable_now(String.t(), keyword()) :: :ok | {:error, failure()}
  def disable_now(unit, opts \\ []) when is_binary(unit) and is_list(opts) do
    systemctl(["--user", "disable", "--now", unit], opts)
  end

  @doc "Restarts the unit through its own service manager."
  @spec restart(String.t(), keyword()) :: :ok | {:error, failure()}
  def restart(unit, opts \\ []) when is_binary(unit) and is_list(opts) do
    systemctl(["--user", "restart", unit], opts)
  end

  @doc """
  Whether this account's user manager lingers.

  An unreadable property is `:linger_unknown`, never an assumed "off": refusing
  to enable a service is a different answer from being unable to tell.
  """
  @spec linger_state(keyword()) ::
          {:ok, boolean()}
          | {:error, :loginctl_absent | :no_identity | {:linger_unknown, String.t()}}
  def linger_state(opts \\ []) when is_list(opts) do
    with {:ok, user} <- linger_context(opts) do
      case run_loginctl(["show-user", user, "-p", "Linger", "--value"], opts) do
        :absent -> {:error, :loginctl_absent}
        {output, 0} -> {:ok, String.trim(output) == "yes"}
        {output, _status} -> {:error, {:linger_unknown, String.trim(output)}}
      end
    end
  end

  @doc """
  Makes this account's user manager linger, so the daemon survives logout and
  starts at boot with nobody logged in.

  Four outcomes, deliberately distinct (M38 §4.4.4): already lingering, enabled
  by this call, `loginctl` absent, the account undeterminable, and the
  authorization denied. Each one has a different remedy.
  """
  @spec ensure_linger(keyword()) ::
          :ok
          | :already_enabled
          | {:error,
             :loginctl_absent
             | :no_identity
             | {:linger_denied, String.t()}
             | {:linger_unknown, String.t()}}
  def ensure_linger(opts \\ []) when is_list(opts) do
    with {:ok, user} <- linger_context(opts),
         {:ok, false} <- linger_state(opts) do
      enable_linger(user, opts)
    else
      {:ok, true} -> :already_enabled
      {:error, reason} -> {:error, reason}
    end
  end

  defp enable_linger(user, opts) do
    case run_loginctl(["enable-linger", user], opts) do
      :absent -> {:error, :loginctl_absent}
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:linger_denied, String.trim(output)}}
    end
  end

  defp linger_context(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    username = Keyword.get(opts, :username, &Identity.username/1)

    cond do
      is_nil(find.("loginctl")) -> {:error, :loginctl_absent}
      user = username.([]) -> {:ok, user}
      true -> {:error, :no_identity}
    end
  end

  # The legacy standalone installer keeps one message per outcome so an operator
  # reading a failed `fermix service install` sees the command to run, not an atom.
  defp linger_for_install do
    case ensure_linger() do
      :ok -> :ok
      :already_enabled -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # One `Key=Value` per line, in whatever order this systemd chose. A value may
  # carry its own `=`, so only the first one separates. A line that is not an
  # assignment yields no property and the requested key it was carrying is then
  # reported missing, so nothing is dropped without a refusal.
  defp parse_show(output) do
    answered =
      output
      |> String.split("\n")
      |> Enum.flat_map(&assignment/1)
      |> Map.new()

    Enum.reduce_while(@show_properties, {:ok, %{}}, fn key, {:ok, properties} ->
      case Map.fetch(answered, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(properties, key, value)}}
        :error -> {:halt, {:error, {:missing_show_property, key}}}
      end
    end)
  end

  defp assignment(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> [{key, value}]
      [_not_an_assignment] -> []
    end
  end

  defp systemctl(args, opts) do
    case run(args, opts) do
      :absent -> {:error, :user_manager_unreachable}
      {_output, 0} -> :ok
      {output, status} -> {:error, failure(output, status)}
    end
  end

  defp failure(output, status) do
    trimmed = String.trim(output)

    if Enum.any?(@unreachable_bus_markers, &String.contains?(trimmed, &1)),
      do: :user_manager_unreachable,
      else: {:systemctl_failed, status, trimmed}
  end

  defp run(args, opts), do: runner(opts).("systemctl", Enum.map(args, &to_string/1))

  defp run_loginctl(args, opts), do: runner(opts).("loginctl", Enum.map(args, &to_string/1))

  defp runner(opts), do: Keyword.get(opts, :cmd, &default_cmd/2)

  # `System.cmd/3` raises when the executable is missing, and a host with no
  # `systemctl` at all — a container, a systemd-less distribution — is a session
  # with no user service manager: the same verdict as a user bus that refuses to
  # connect, reached one step earlier. Every caller answers `:absent` with its
  # own named refusal rather than a stack trace, which is what a packaged
  # `fermix service status` prints in a plain Debian container.
  defp default_cmd(executable, args) do
    case System.find_executable(executable) do
      nil -> :absent
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end
end
