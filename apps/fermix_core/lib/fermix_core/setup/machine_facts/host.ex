defmodule FermixCore.Setup.MachineFacts.Host do
  @moduledoc """
  Reads `MachineFacts` from the host.

  The time zone is the target of the `/etc/localtime` link, which macOS and
  Linux both point into a `zoneinfo` tree (`/var/db/timezone/zoneinfo/Europe/
  Zurich`, `/usr/share/zoneinfo/Europe/Zurich`), checked against the shipped
  IANA database the way `Temporal.Registry` checks a configured zone. A file
  that is not a link, a target outside a zoneinfo tree, or a name the database
  does not know is `:error`.

  The full name is `id -F` on macOS and the GECOS field of the account's
  `getent passwd` entry on Linux, resolved on PATH and run through
  `CommandRunner` the way `Harness.Identity` runs `id -un`. A binary that is
  not on PATH, a non-zero exit, a malformed entry or a blank answer is
  `:error`, each logged with its reason.
  """
  @behaviour FermixCore.Setup.MachineFacts

  alias FermixCore.CommandRunner

  require Logger

  @localtime "/etc/localtime"
  @timeout_ms 2_000

  @impl true
  def timezone, do: timezone([])

  @doc "The system time zone, read from the `localtime:` link (default `/etc/localtime`)."
  @spec timezone(keyword()) :: {:ok, String.t()} | :error
  def timezone(opts) when is_list(opts) do
    link = Keyword.get(opts, :localtime, @localtime)

    with {:ok, target} <- File.read_link(link),
         {:ok, zone} <- zone_in(target),
         {:ok, _shifted} <- DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, zone}
    else
      _not_a_known_zone -> :error
    end
  end

  # The zone is the path under the zoneinfo tree, whichever tree the OS keeps.
  defp zone_in(target) do
    case String.split(target, "zoneinfo/", parts: 2) do
      [_tree, zone] when zone != "" -> {:ok, zone}
      _outside_a_zoneinfo_tree -> :error
    end
  end

  @impl true
  def full_name, do: full_name([])

  @doc """
  The account's full name. `macos?:` picks the lookup, `run:` the command
  runner (`fn binary, args -> {:ok, stdout} | {:error, reason} end`) and
  `find_executable:` the PATH lookup the default runner resolves a binary
  with, each injectable for tests.
  """
  @spec full_name(keyword()) :: {:ok, String.t()} | :error
  def full_name(opts) when is_list(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    run = Keyword.get(opts, :run, command_runner(find))
    macos? = Keyword.get(opts, :macos?, :os.type() == {:unix, :darwin})

    lookup = if macos?, do: run.("id", ["-F"]), else: linux_full_name(run)

    case lookup do
      {:ok, name} ->
        present(name)

      {:error, reason} ->
        Logger.warning(
          "machine facts: the account's full name could not be read: #{inspect(reason)}"
        )

        :error
    end
  end

  # The GECOS field of the account's passwd entry, up to its first comma.
  defp linux_full_name(run) do
    with {:ok, user} <- run.("id", ["-un"]),
         {:ok, entry} <- run.("getent", ["passwd", String.trim(user)]) do
      case String.split(String.trim(entry), ":") do
        [_user, _password, _uid, _gid, gecos | _rest] -> {:ok, gecos |> String.split(",") |> hd()}
        _malformed -> {:error, {:malformed_passwd_entry, String.trim(entry)}}
      end
    end
  end

  defp present(name) do
    case String.trim(name) do
      "" ->
        Logger.warning("machine facts: the account has no full name")
        :error

      trimmed ->
        {:ok, trimmed}
    end
  end

  # The runner takes an absolute path and searches no PATH itself, so the
  # lookup lives here where the decision is visible, as `Harness.Identity`
  # keeps it. Supervised, because this runs inside the tree, where the command
  # host is the first child up.
  defp command_runner(find_executable) do
    fn binary, args ->
      case find_executable.(binary) do
        nil -> {:error, {:executable_not_found, binary}}
        path -> run_resolved(path, binary, args)
      end
    end
  end

  defp run_resolved(path, binary, args) do
    case CommandRunner.run(path, args, timeout_ms: @timeout_ms) do
      {:ok, %{exit: 0, stdout: out}} -> {:ok, out}
      {:ok, %{exit: code}} -> {:error, {:exit, binary, code}}
      {:error, reason} -> {:error, {binary, reason}}
    end
  end
end
