defmodule FermixCore.Tools.GitCommand do
  @moduledoc false

  alias FermixCore.CommandRunner

  # Audit F-01 follow-up (shared boundary): even when the resolved repo path
  # is sandbox-checked, git accepts flags that escape the `cd: repo` boundary.
  # `--upload-pack`/`--receive-pack` run an arbitrary program for the transport
  # (argument-injection -> command execution); `--git-dir`/`--work-tree`/
  # `--exec-path`/`--output`/`--no-index` redirect git's view of the repo or
  # its I/O sink. Every git tool runs through this one chokepoint, so the
  # denylist lives here rather than in each caller — keeping git_read and
  # git_write from drifting apart (the asymmetry that left git_write exposed).
  #
  # git honors unambiguous *prefix abbreviations* of long options (verified:
  # `git pull --upload-pac=<cmd>` runs <cmd>), so matching is prefix-based on
  # the option token (the part before `=`), which also covers the exact and
  # `--flag=value` forms.
  @dangerous_flags ~w(
    --no-index
    --git-dir
    --work-tree
    --exec-path
    --output
    --output-directory
    --upload-pack
    --receive-pack
    --man-path
    --info-path
  )

  # Flags that make git READ A FILE OF THE CALLER'S CHOOSING and fold its bytes
  # into the repository. Only the *repo path* is sandbox-authorized — never the
  # args — so `git commit -F ~/.fermix/auth.json` writes a daemon-readable file
  # into the commit message, which `git_read log` then reads straight back: an
  # arbitrary-file read that never meets the sandbox at all.
  # `--pathspec-from-file` is the same primitive with a narrower echo.
  #
  # Matching is the prefix rule `@dangerous_flags` uses, because git honors
  # unambiguous abbreviations (`--fil=<path>` was verified to work).
  #
  # `-t`/`--template` is deliberately NOT here. It only prefills an editor, and
  # the daemon spawns git with no editor, so it cannot deliver a file's contents
  # (verified: `git commit -t <file>` aborts). Denying it would cost
  # `git checkout -t <remote>/<branch>`, where `-t` means `--track`.
  @file_reading_flags ~w(--file --pathspec-from-file)

  # Short flags bundle (`-aF <path>`) and glue their value (`-F<path>`), so the
  # `-F` check walks the cluster rather than matching the whole token. It stops
  # at the first flag that consumes the REMAINDER AS A VALUE — without that,
  # `git commit -mFixed the bug` would parse as `-F` here and a legitimate
  # commit would be refused. `commit` is the only whitelisted command with a
  # file-reading short flag, so the value-taking set is `git commit`'s own.
  @commit_value_short ~c"FmcCtSu"

  # git's smart-transport helper `ext::<program>` executes an arbitrary program
  # for the transport before any handshake — argument-injection-to-RCE that never
  # reaches the command classifier. Modern git already refuses `ext` by default,
  # but the sandbox must not depend on the ambient git config: a permissive host
  # `protocol.ext.allow = user` re-enables it. GIT_ALLOW_PROTOCOL pins the
  # transports git may use to the ones `pull`/`fetch` legitimately need and
  # overrides any host `protocol.*.allow`, so ext/fd/file transports are refused
  # regardless of config. This is an allowlist, not a flag denylist — it cannot
  # be bypassed by quoting, abbreviation, or a transport we forgot to enumerate.
  @allowed_protocols "https:ssh:git"

  # Fixed wall-clock ceiling for any single git command. `pull` is the only
  # network-reaching command in either whitelist; a first pull on a slow link
  # exceeding this fails loud (accepted). Not a config knob — the timeout is a
  # containment invariant, not an operator setting.
  @timeout_ms 120_000

  @spec run(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(repo, command, args, opts \\ [])
      when is_binary(repo) and is_binary(command) and is_list(args) and is_list(opts) do
    with :ok <- validate_repo(repo),
         :ok <- validate_args(args),
         :ok <- validate_flags(command, args),
         {:ok, git} <- resolve_executable(opts) do
      git
      |> CommandRunner.run([command | args],
        cwd: repo,
        env: [{"GIT_ALLOW_PROTOCOL", @allowed_protocols}],
        timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
      )
      |> translate(command)
    end
  end

  @doc false
  @spec executable() :: {:ok, String.t()} | {:error, String.t()}
  def executable, do: resolve_executable([])

  # The executable-path seam: production resolves `git` on PATH once; tests pass
  # an `:executable` stub. Resolution stays inside this chokepoint so git_read,
  # git_write, and the git_root preflight cannot drift.
  defp resolve_executable(opts) do
    case Keyword.get(opts, :executable) || System.find_executable("git") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, "git executable not found"}
    end
  end

  defp translate({:ok, %{exit: 0, stdout: output}}, _command), do: {:ok, output}

  defp translate({:ok, %{exit: exit_code, stdout: output}}, command) do
    {:error, "git #{command} failed (exit #{exit_code}):\n#{output}"}
  end

  defp translate({:error, {:timeout, _ms}}, command) do
    {:error, "git #{command} timed out after #{div(@timeout_ms, 1000)}s"}
  end

  defp translate({:error, reason}, command) do
    {:error, "git #{command} failed: #{inspect(reason)}"}
  end

  defp validate_repo(repo) do
    cond do
      String.contains?(repo, "\0") -> {:error, "repo contains null bytes"}
      not File.dir?(repo) -> {:error, "repo does not exist: #{repo}"}
      true -> :ok
    end
  end

  defp validate_args(args) do
    if Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, "\0"))) do
      :ok
    else
      {:error, "git args must be strings without null bytes"}
    end
  end

  defp validate_flags(command, args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      case classify_flag(command, arg) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp classify_flag(command, arg) do
    cond do
      denied_flag?(arg) ->
        {:error, "git arg #{inspect(arg)} is rejected; it can escape sandbox containment"}

      file_reading_flag?(command, arg) ->
        {:error,
         "git arg #{inspect(arg)} is rejected; it reads a file outside the authorized " <>
           "repository. Pass the message inline with -m."}

      true ->
        :ok
    end
  end

  # Long options only. The token is the part before `=`; reject it when it is a
  # prefix of any dangerous flag (catches abbreviations, exact, and `=value`).
  # `--` (end-of-options) and short/positional args are never dangerous here.
  defp denied_flag?("--" <> rest = arg) when byte_size(rest) > 0 do
    token = arg |> String.split("=", parts: 2) |> hd()
    Enum.any?(@dangerous_flags, &String.starts_with?(&1, token))
  end

  defp denied_flag?(_arg), do: false

  defp file_reading_flag?(_command, "--" <> rest = arg) when byte_size(rest) > 0 do
    token = arg |> String.split("=", parts: 2) |> hd()
    Enum.any?(@file_reading_flags, &String.starts_with?(&1, token))
  end

  defp file_reading_flag?("commit", "-" <> cluster) when byte_size(cluster) > 0,
    do: short_cluster_reads_file?(cluster)

  defp file_reading_flag?(_command, _arg), do: false

  # Byte-level so an arg that is not valid UTF-8 classifies instead of raising;
  # every flag letter git defines is ASCII.
  defp short_cluster_reads_file?(cluster) do
    cluster
    |> :binary.bin_to_list()
    |> Enum.reduce_while(false, fn
      ?F, _acc -> {:halt, true}
      letter, acc -> if letter in @commit_value_short, do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
