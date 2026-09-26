defmodule FermixCore.Harness.VendorConfig do
  @moduledoc """
  The repo-local vendor config a coding CLI runs on its own at launch,
  fingerprinted across every local coding-harness run (GAP3-1).

  Each vendor protects its own config from its own agent and not the other's: a
  Codex child in `workspace-write` can write `.claude/settings.local.json`, and a
  Claude child can write `.codex/config.toml`. The file then runs, unconfined, at
  the next launch of the other CLI in that repo, and at the owner's own
  interactive launch there. Fermix is what composes the two vendors in one
  worktree, so it watches the seam:

    * **Admission** fingerprints a fixed list of auto-executing files in each
      watched directory and persists it on the row before the child spawns. The
      watched directories are the run's lock roots and every directory from a
      lock root down to the run's cwd: Claude reads its project settings in its
      cwd, and Codex layers config from its cwd up to the git root.
    * **Terminalization** fingerprints the same directories again (`changes/2`). A
      change is recorded on the row and named in the run's own notice (`note/1`).
    * **The next admission** into a root with an unresolved change refuses
      (`unresolved/2`) until the owner acknowledges it once through the sandbox
      `/confirm` flow, or the file is reverted or committed.

  Whole files, never keys. A key-level allowlist would go stale with every
  vendor release, and harness runs are serialized per lock root, so a whole-file
  diff across one run window flags no more of the owner's own edits than a key
  diff would. A file planted deeper than the run's cwd, for a later run started
  further down the tree, is outside the watch.

  A fingerprint is `%{dir => %{relative_path => entry}}`, where an entry is a
  content hash for a regular file (a symlink is followed, as the CLI follows it)
  or a marker for anything else; an absent file has no entry. A directory with
  no vendor config maps to `%{}`, so the terminal pass still covers it.

  The names under `.agents` are the child's own choosing, and what is shown of a
  change reaches the agent outside the untrusted-content frame and the owner in
  an approval prompt. So a changed tree is shown as its directory and a count,
  never by the names inside it, and every shown path is one line of visible text.
  """

  require Logger

  alias FermixCore.CommandRunner
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.GitCommand

  # The files a coding CLI (or the editor it drives) executes or obeys on launch
  # with no prompt: Claude Code's project and local settings (hooks, permission
  # rules), the shared MCP server list, Codex's project config (sandbox mode, MCP
  # servers), the `.agents` tree Codex reads skills from, and VS Code's
  # auto-running tasks and settings.
  @files ~w(.claude/settings.json .claude/settings.local.json .mcp.json .codex/config.toml
            .vscode/tasks.json .vscode/settings.json)
  @trees ~w(.agents)

  # The `.agents` walk visits at most this many entries (files and directories)
  # at most this deep, in sorted order, so a huge or hostile tree costs admission
  # a bounded read. Entries past the cap are not fingerprinted.
  @tree_max_visits 512
  @tree_max_depth 8
  # Vendor config files are small; one past this is marked by size, not read.
  @file_max_bytes 262_144
  @git_timeout_ms 5_000

  @type fingerprint :: %{String.t() => %{String.t() => String.t()}}
  @type change :: %{String.t() => String.t() | boolean() | nil}
  @type changes :: %{String.t() => %{String.t() => change()}}
  @type unresolved :: %{run_id: String.t(), changes: changes()}

  @doc """
  Fingerprints the auto-executing vendor config a run in `cwd` could obey: in
  each lock root and in every directory from a lock root down to `cwd`. Reads
  files.
  """
  @spec fingerprint([String.t()], String.t()) :: fingerprint()
  def fingerprint(lock_roots, cwd) when is_list(lock_roots) and is_binary(cwd) do
    (lock_roots ++ cwd_chain(lock_roots, cwd))
    |> Enum.uniq()
    |> Map.new(fn dir -> {dir, dir_fingerprint(dir)} end)
  end

  @doc """
  Re-fingerprints the directories of `start` and returns what changed since, per
  directory and relative path:
  `%{"before" => entry, "after" => entry, "commit_clears" => bool}`.
  `commit_clears` records that git saw the file dirty when the run ended, so a
  later commit may clear it: a run that committed its own change must not get it
  cleared by a clean status later. Reads files and runs git; `opts[:supervised]`
  is the CommandRunner seam.
  """
  @spec changes(fingerprint(), keyword()) :: changes()
  def changes(start, opts \\ []) when is_map(start) and is_list(opts) do
    start
    |> Enum.map(fn {dir, before} -> {dir, changed_files(dir, before)} end)
    |> Enum.reject(fn {_dir, files} -> files == %{} end)
    |> Map.new(fn {dir, files} -> {dir, mark_commit_clears(dir, files, opts)} end)
  end

  @doc """
  The part of `changes` still unresolved, in the same shape: files not back to
  their pre-run content, and not committed since the run ended. Reads files and
  runs git; `opts[:supervised]` is the CommandRunner seam.
  """
  @spec unresolved(changes(), keyword()) :: changes()
  def unresolved(changes, opts \\ []) when is_map(changes) and is_list(opts) do
    changes
    |> Enum.map(fn {root, files} -> {root, unresolved_in(root, files, opts)} end)
    |> Enum.reject(fn {_root, files} -> files == %{} end)
    |> Map.new()
  end

  @doc "Whether any changed file lies under one of `roots`. Pure."
  @spec touches?(changes(), [String.t()]) :: boolean()
  def touches?(changes, roots) when is_map(changes) and is_list(roots) do
    Enum.any?(paths(changes), fn path -> Enum.any?(roots, &under?(path, &1)) end)
  end

  @doc """
  The line a run's own notice carries when it changed vendor config — `""`
  otherwise. Derived from the row, so a retried delivery says it too. Pure.
  """
  @spec note(map()) :: String.t()
  def note(%{vendor_config_changes: changes}) when is_map(changes) and map_size(changes) > 0 do
    "This run changed coding-agent config that runs on its own when a coding agent " <>
      "starts: #{Enum.map_join(shown(changes), ", ", &label/1)}. The next coding run there " <>
      "waits for the owner to acknowledge it once, unless it is reverted or committed first."
  end

  def note(_row), do: ""

  @doc """
  The refusal for a launch with no approval surface (a scheduled job, a
  client-owned surface): names the run, the files and each way to clear it. A
  bare `/confirm` has no token here, so it names the step that raises the
  prompt: a coding run asked for from a chat.
  """
  @spec guidance(unresolved()) :: String.t()
  def guidance(%{run_id: run_id, changes: changes}) when is_binary(run_id) and is_map(changes) do
    "Coding run #{run_id} changed coding-agent config that runs on its own when a " <>
      "coding agent starts: #{Enum.map_join(shown(changes), ", ", &label/1)}. No coding " <>
      "run starts there until the owner clears it: ask Fermix in a chat to start the " <>
      "coding run there and confirm the change when asked, or revert or commit the change."
  end

  @doc """
  The owner-facing approval prompt, ahead of its `/confirm` line. A path reached
  through a link, its own or a parent directory's, is shown with where it lands,
  since acknowledging it trusts whatever writes there later. Reads links.
  """
  @spec acknowledgment_prompt(unresolved()) :: String.t()
  def acknowledgment_prompt(%{run_id: run_id, changes: changes})
      when is_binary(run_id) and is_map(changes) do
    """
    Coding run #{run_id} changed config that coding agents run on their own when they start here:

    #{Enum.map_join(shown(changes), "\n", &prompt_line/1)}

    Check it is a change you expect before the next coding run starts.
    """
    |> String.trim()
  end

  # --- Display ------------------------------------------------------------

  # What is shown of `changes`, one `{{path, kind}, count}` per line, sorted by
  # path: a fixed-list file as itself, and a watched tree as its directory with
  # how many of its files changed, so no name inside a tree is ever shown.
  defp shown(changes) do
    changes
    |> Enum.flat_map(fn {dir, files} -> Enum.map(Map.keys(files), &shown_as(dir, &1)) end)
    |> Enum.frequencies()
    |> Enum.sort()
  end

  defp shown_as(dir, rel) do
    case Enum.find(@trees, &(rel == &1 or String.starts_with?(rel, &1 <> "/"))) do
      nil -> {Path.join(dir, rel), :file}
      tree -> {Path.join(dir, tree), :tree}
    end
  end

  defp label({{path, :file}, _one}), do: printable(path)
  defp label({{path, :tree}, 1}), do: printable(path) <> "/ (1 file)"
  defp label({{path, :tree}, count}), do: printable(path) <> "/ (#{count} files)"

  defp prompt_line({{path, _kind}, _count} = shown) do
    case PathPolicy.canonical_path(path) do
      ^path -> label(shown)
      target -> label(shown) <> " (a link to #{printable(target)})"
    end
  end

  # One line of visible text whoever chose the name (a link's target is its
  # maker's text): a byte that is not UTF-8 becomes U+FFFD, and a character that
  # could break a line, hide text or reorder it (a control or format character,
  # a line or paragraph separator) is written as its `\u{...}` escape.
  defp printable(path) do
    path
    |> String.replace_invalid()
    |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, &escape/1)
  end

  defp escape(<<codepoint::utf8>>), do: "\\u{" <> Integer.to_string(codepoint, 16) <> "}"

  # --- Fingerprints -------------------------------------------------------

  # The directories from a lock root down to `cwd`, spelled under that root. A
  # lock root is spelled physically (git's toplevel, a sandbox-resolved
  # `add_dirs` entry), so `cwd` is too before its ancestors are compared.
  defp cwd_chain(lock_roots, cwd) do
    cwd
    |> PathPolicy.canonical_path()
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.filter(fn dir -> Enum.any?(lock_roots, &(dir == &1 or under?(dir, &1))) end)
  end

  defp dir_fingerprint(dir) do
    (@files ++ Enum.flat_map(@trees, &tree_files(dir, &1)))
    |> Enum.map(fn rel -> {rel, entry(Path.join(dir, rel))} end)
    |> Enum.reject(fn {_rel, entry} -> is_nil(entry) end)
    |> Map.new()
  end

  # Breadth-first, sorted, never following a symlinked directory, bounded by
  # `@tree_max_visits` and `@tree_max_depth`.
  defp tree_files(root, tree), do: walk(root, [{tree, 0}], [], 0)

  defp walk(_root, [], files, _visits), do: Enum.reverse(files)
  defp walk(_root, _queue, files, visits) when visits >= @tree_max_visits, do: Enum.reverse(files)

  defp walk(root, [{rel, depth} | queue], files, visits) do
    case File.lstat(Path.join(root, rel)) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(root, queue ++ children(root, rel, depth), files, visits + 1)

      {:ok, _file_or_link} ->
        walk(root, queue, [rel | files], visits + 1)

      {:error, _absent} ->
        walk(root, queue, files, visits)
    end
  end

  defp children(_root, _rel, depth) when depth >= @tree_max_depth, do: []

  defp children(root, rel, depth) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} -> names |> Enum.sort() |> Enum.map(&{Path.join(rel, &1), depth + 1})
      {:error, _unreadable} -> []
    end
  end

  # Only a regular file is ever opened, so a FIFO planted in place of a settings
  # file cannot block admission.
  defp entry(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @file_max_bytes ->
        "oversize:#{size}"

      {:ok, %File.Stat{type: :regular}} ->
        content_entry(path)

      {:ok, %File.Stat{type: type}} ->
        "type:#{type}"

      {:error, reason} when reason in [:enoent, :enotdir] ->
        nil

      {:error, reason} ->
        "unreadable:#{reason}"
    end
  end

  # Bounded read: a file that grew past the cap since `stat` is marked, not hashed.
  defp content_entry(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @file_max_bytes + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > @file_max_bytes -> "oversize"
      {:ok, bytes} when is_binary(bytes) -> hash(bytes)
      {:ok, :eof} -> hash("")
      {:ok, {:error, reason}} -> "unreadable:#{reason}"
      {:error, reason} -> "unreadable:#{reason}"
    end
  end

  defp hash(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # --- Changes ------------------------------------------------------------

  defp changed_files(dir, before) do
    now = dir_fingerprint(dir)

    (Map.keys(before) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(before, &1) == Map.get(now, &1)))
    |> Map.new(&{&1, %{"before" => Map.get(before, &1), "after" => Map.get(now, &1)}})
  end

  # A git that cannot answer counts every file clean, the conservative reading:
  # a later commit then never clears it, only a revert or the owner.
  defp mark_commit_clears(dir, files, opts) do
    rels = Map.keys(files)
    clean = clean_paths(dir, rels, opts, MapSet.new(rels))

    Map.new(files, fn {rel, change} ->
      {rel, Map.put(change, "commit_clears", rel not in clean)}
    end)
  end

  # A git that cannot answer here proves nothing committed.
  defp unresolved_in(root, files, opts) do
    pending = Enum.reject(files, fn {rel, change} -> reverted?(root, rel, change) end)
    clean = clean_paths(root, committable(pending), opts, MapSet.new())

    for {rel, change} <- pending, rel not in clean, into: %{}, do: {rel, change}
  end

  defp reverted?(root, rel, change), do: entry(Path.join(root, rel)) == change["before"]

  # Only a file git saw dirty when its run ended can be cleared by a later commit.
  defp committable(pending), do: for({rel, %{"commit_clears" => true}} <- pending, do: rel)

  defp paths(changes) do
    changes
    |> Enum.flat_map(fn {root, files} -> Enum.map(Map.keys(files), &Path.join(root, &1)) end)
    |> Enum.sort()
  end

  defp under?(path, root), do: String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  # --- Git ----------------------------------------------------------------

  # The subset of `rels` git reports clean in `root`: tracked and unmodified, or
  # absent and untracked. `--ignored` lists a gitignored file, so an ignored
  # settings.local.json never passes for committed. A listed path is matched by
  # suffix because porcelain paths are relative to the repository root, which a
  # watched directory need not be, and stderr shares the stream; a stray match
  # only counts a file dirty. A git that cannot run, or answers non-zero (outside
  # any worktree, or unable to read one), proves nothing and answers `if_unknown`,
  # chosen by the caller as its conservative reading, and says so in the log.
  defp clean_paths(_root, [], _opts, _if_unknown), do: MapSet.new()

  defp clean_paths(root, rels, opts, if_unknown) do
    with {:ok, git} <- GitCommand.executable(),
         {:ok, %{exit: 0, stdout: out}} <- git_status(git, root, rels, opts) do
      listed = out |> String.split(<<0>>, trim: true) |> Enum.map(&porcelain_path/1)
      rels |> Enum.reject(&listed?(&1, listed)) |> MapSet.new()
    else
      {:ok, %{exit: code}} -> git_unavailable(root, {:exit, code}, if_unknown)
      {:error, reason} -> git_unavailable(root, reason, if_unknown)
    end
  end

  # `core.fsmonitor=false` and `--no-optional-locks`: the status runs in a tree a
  # vendor child just wrote to, so it must launch no configured monitor and take
  # no index lock the owner's own git could trip over.
  defp git_status(git, root, rels, opts) do
    args =
      ["-c", "core.fsmonitor=false", "--no-optional-locks", "status", "--porcelain=v1", "-z"] ++
        ["--ignored=matching", "--untracked-files=all", "--no-renames", "--" | rels]

    CommandRunner.run(git, args,
      cwd: root,
      timeout_ms: @git_timeout_ms,
      supervised: Keyword.get(opts, :supervised, true)
    )
  end

  defp porcelain_path(<<_xy::binary-size(3), path::binary>>), do: path
  defp porcelain_path(short), do: short

  defp listed?(rel, listed),
    do: Enum.any?(listed, &(&1 == rel or String.ends_with?(&1, "/" <> rel)))

  defp git_unavailable(root, reason, if_unknown) do
    Logger.warning(
      "vendor-config commit check got no answer from git in #{root}: #{inspect(reason)}; " <>
        "only a revert or the owner's acknowledgment resolves a change there"
    )

    if_unknown
  end
end
