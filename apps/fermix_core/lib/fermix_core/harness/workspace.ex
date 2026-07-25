defmodule FermixCore.Harness.Workspace do
  @moduledoc """
  Resolves the canonical workspace lock root for a coding-harness run.

  The lock domain is the **git worktree root** so that sibling directories in
  one repo (`/repo/apps/core`, `/repo/apps/web`) contend on a single lock.
  There are two input classes, not a primary path with a fallback:

    * a directory inside a git worktree → `git rev-parse --show-toplevel`, whose
      output is git's own physical (symlink-resolved) path;
    * a directory outside any git worktree → the `Path.expand`-normalized cwd
      itself (`.`/`..`/`~` collapsed). This is NOT symlink-resolved, so two
      symlink aliases of one non-git directory (e.g. macOS `/tmp` vs
      `/private/tmp`) take distinct lock roots — the narrower guarantee accepted
      for the non-repo class, where the harness is not expected to run.

  A git spawn failure or timeout is never guessed around: it returns
  `{:error, {:git_failed, reason}}` and the caller fails loud.

  `lock_root/2` takes a `:supervised` option (default `true`, the daemon path
  through `FermixCore.CommandHost`); tests without a supervision tree pass
  `supervised: false` for the inline one-shot path.
  """

  alias FermixCore.CommandRunner
  alias FermixCore.Tools.GitCommand

  @rev_parse_timeout_ms 5_000

  @spec lock_root(String.t()) :: {:ok, String.t()} | {:error, term()}
  def lock_root(cwd) when is_binary(cwd), do: lock_root(cwd, [])

  @spec lock_root(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def lock_root(cwd, opts) when is_binary(cwd) and is_list(opts) do
    with {:ok, canonical} <- canonical_dir(cwd),
         {:ok, git} <- GitCommand.executable() do
      resolve_lock_root(git, canonical, opts)
    end
  end

  defp canonical_dir(cwd) do
    expanded = Path.expand(cwd)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, expanded}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_directory, type}}
      {:error, reason} -> {:error, {:cwd_unreachable, reason}}
    end
  end

  defp resolve_lock_root(git, canonical, opts) do
    git
    |> CommandRunner.run(["rev-parse", "--show-toplevel"],
      cwd: canonical,
      timeout_ms: @rev_parse_timeout_ms,
      supervised: Keyword.get(opts, :supervised, true)
    )
    |> interpret_root(canonical)
  end

  # Inside a git worktree: git prints the physical toplevel path and exits 0.
  defp interpret_root({:ok, %{exit: 0, stdout: stdout}}, _canonical) do
    {:ok, String.trim(stdout)}
  end

  # Outside any git worktree (exit 128 "not a git repository"): the canonical
  # cwd is itself the lock root. A distinct input class, not a recovery branch.
  defp interpret_root({:ok, %{exit: _nonzero}}, canonical) do
    {:ok, canonical}
  end

  defp interpret_root({:error, reason}, _canonical) do
    {:error, {:git_failed, reason}}
  end
end
