defmodule FermixCore.Harness.Identity do
  @moduledoc """
  Resolves the account name the vendor CLIs run as — the `USER` half of the
  identity `Harness.Env` reconstructs.

  A vendor CLI may key its credential lookup on the account name rather than on
  `HOME`. Claude Code reads its macOS Keychain item under the account
  `process.env.USER`, falling back to the OS-reported user name and then to a
  literal placeholder, so a child spawned without `USER` silently reads a
  *different* account and reports itself logged out. That is why `Harness.Env`
  treats `USER` as reserved identity and requires it.

  `$USER` answers whenever the daemon has it, which covers every shipped install
  (a macOS LaunchAgent and a user-scope systemd unit both carry it). Where it is
  absent — a container, or a system-scope unit with no `User=` — the account name
  is still a determinable fact about the running process, so it is read from the
  passwd database via `id -un` (`getpwuid(geteuid())`) instead of being guessed.

  `LOGNAME` and `Path.basename(home)` are deliberately **not** consulted. Both can
  name a different account than the process actually runs as, and a wrong account
  is precisely the silent-wrong-credentials failure this module exists to prevent:
  it would spawn a healthy CLI that reads an empty credential store and reports
  "not logged in", which is unreadable as a Fermix problem. When neither source
  answers, this returns `nil` and the caller refuses the run before spawning —
  a placeholder is never invented.
  """

  require Logger

  alias FermixCore.CommandRunner

  @id_binary "id"
  @timeout_ms 2_000

  @type opt :: {:resolver, (-> String.t() | nil)}

  @doc """
  The account name for a spawned vendor CLI, or `nil` when it cannot be determined.

  `:resolver` replaces the passwd lookup so tests can exercise both outcomes
  without depending on the host (the `$USER` path needs no seam — callers pass an
  explicit value through `Harness.Env`'s `:user` opt).
  """
  @spec username([opt()]) :: String.t() | nil
  def username(opts \\ []) when is_list(opts) do
    case System.get_env("USER") do
      name when is_binary(name) and name != "" -> name
      _absent_or_empty -> passwd_name(opts)
    end
  end

  defp passwd_name(opts) do
    resolver = Keyword.get(opts, :resolver, &passwd_lookup/0)

    case resolver.() do
      name when is_binary(name) and name != "" -> name
      _unresolved -> nil
    end
  end

  # Distinct causes stay distinct in the log: a missing `id` is a stripped image,
  # a non-zero exit is a broken passwd database, and either leaves the operator
  # with a run refused for a reason they need to act on.
  defp passwd_lookup do
    case System.find_executable(@id_binary) do
      nil ->
        Logger.warning("harness identity: no USER in the daemon environment and no `id` on PATH")
        nil

      binary ->
        run_id_lookup(binary)
    end
  end

  defp run_id_lookup(binary) do
    case CommandRunner.run(binary, ["-un"], supervised: false, timeout_ms: @timeout_ms) do
      {:ok, %{exit: 0, stdout: out}} ->
        String.trim(out)

      other ->
        Logger.warning(
          "harness identity: no USER in the daemon environment and `id -un` failed: " <>
            inspect(other)
        )

        nil
    end
  end
end
