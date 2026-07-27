defmodule FermixCore.Harness.Identity do
  @moduledoc """
  The operator context a wiped child has to be given back: **who** it runs as
  (`USER`) and **where** its vendor keeps its credentials (`CLAUDE_CONFIG_DIR` /
  `CODEX_HOME`). `env -i` removes both, and a vendor CLI that gets either one
  wrong does not fail loudly — it reads an empty credential store and reports
  itself logged out, which is unreadable as a Fermix problem.

  ## Who it runs as

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

  ## Where its credentials live

  Both vendors relocate their whole credential store by environment variable, and
  Claude Code goes further: `CLAUDE_CONFIG_DIR` also re-keys the macOS Keychain
  *service* name to `Claude Code-credentials-<sha256(dir)[0..8]>`. So the child has
  to run under the same config-dir context the operator logged in under, and
  getting it wrong breaks **symmetrically**:

    * the operator logged in normally but Fermix has a config dir set — the child
      looks under a service name nothing ever wrote; or
    * the operator lives with `CLAUDE_CONFIG_DIR` exported and logged in that way
      while Fermix's key is unset — the child looks under the plain name instead.

  The second is the dangerous one, because it is the *default* for that operator:
  nothing prompts them to mirror the variable into Fermix's config. We cannot know
  which they are, so the dir is resolved rather than assumed — the explicit Fermix
  key first (an operator who set it meant it), then the daemon's own environment
  (which it inherited from the operator), then nothing, leaving the vendor its own
  default. Detection reads the same resolver, so `Vendors` can never report on a
  different store than a run will actually use.
  """

  require Logger

  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Config

  @id_binary "id"
  @timeout_ms 2_000

  # The vendor's own "my state lives here" variable. Claude Code additionally
  # derives its Keychain service name from this value; codex only relocates files.
  @vendor_config_env %{"claude" => "CLAUDE_CONFIG_DIR", "codex" => "CODEX_HOME"}

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

  @doc """
  The config dir `vendor` keeps its credentials in, or `nil` for the vendor's own
  default. Fermix's explicit key wins; otherwise the daemon's own environment,
  which is the context the operator logged in under.
  """
  @spec vendor_config_dir(String.t()) :: String.t() | nil
  def vendor_config_dir(vendor) when is_binary(vendor) do
    with name when is_binary(name) <- Map.get(@vendor_config_env, vendor),
         nil <- present(configured_dir(vendor)) do
      present(System.get_env(name))
    else
      nil -> nil
      dir when is_binary(dir) -> dir
    end
  end

  @doc """
  `vendor_config_dir/1` as the `%{name => value}` overlay `Harness.Env` takes, or
  `%{}` when the vendor should use its own default.
  """
  @spec vendor_config_env(String.t()) :: %{optional(String.t()) => String.t()}
  def vendor_config_env(vendor) when is_binary(vendor) do
    with name when is_binary(name) <- Map.get(@vendor_config_env, vendor),
         dir when is_binary(dir) <- vendor_config_dir(vendor) do
      %{name => dir}
    else
      _none -> %{}
    end
  end

  defp configured_dir("claude"), do: Config.claude_config_dir()
  defp configured_dir("codex"), do: Config.codex_home()
  defp configured_dir(_other), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_absent_or_empty), do: nil

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
