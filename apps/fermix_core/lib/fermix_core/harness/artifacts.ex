defmodule FermixCore.Harness.Artifacts do
  @moduledoc """
  Permission-, quota-, and retention-governed run artifact store (design §6.5).

  Each run owns a directory under `<FERMIX_HOME>/harness/runs/<run_id>` created
  `0700`; every file inside (`prompt.md`, `events.jsonl` spool, `result.txt`,
  `brief.md`) is `0600`. The Repo is never a streaming sink — raw events go to
  the file spool here, SQLite receives only session id, throttled progress, and
  terminal state.

  Bounds:

    * `admission_check/1` refuses new runs when the store exceeds
      `artifact_quota_gb` or the filesystem free space falls below `min_free_gb`
      (fail loud — `{:error, {:artifact_quota, detail}}`).
    * `gc/2` sweeps run directories older than `artifact_retention_days` at boot
      and daily. It never follows symlinks and deletes ONLY strictly-under-root,
      no-`..`, deep-enough paths (a production SafeRm-style guard) — a computed
      path can never escape the runs root.

  Tests inject `:runs_root` (and the numeric bounds / a `:free_bytes` probe)
  explicitly so nothing touches the real `FERMIX_HOME` or spawns `df`.
  """

  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Config
  alias FermixCore.Setup.ConfigStore

  require Logger

  @dir_mode 0o700
  @file_mode 0o600
  @bytes_per_gb 1_073_741_824
  @max_walk_depth 64
  # A run dir sits at `<home>/harness/runs/<id>`; anything shallower than this
  # is root-ish and never a deletable run dir.
  @min_delete_segments 5
  @run_id_regex ~r/\A[A-Za-z0-9_-]+\z/
  @df_timeout_ms 5_000

  @type prepared :: %{dir: String.t()}
  @type quota_detail :: %{
          required(:kind) => :quota_exceeded | :below_min_free | :free_space_unknown,
          optional(atom()) => term()
        }

  @doc "Absolute runs root: `<runs_root_opt || FERMIX_HOME>/harness/runs`."
  @spec runs_root(keyword()) :: String.t()
  def runs_root(opts \\ []) when is_list(opts) do
    Keyword.get_lazy(opts, :runs_root, fn ->
      Path.join(ConfigStore.fermix_home(), "harness/runs")
    end)
  end

  @doc """
  Creates the run's `0700` artifact directory. `run_id` must be a safe basename
  (no path separators or `..`).
  """
  @spec prepare(String.t(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    with :ok <- validate_run_id(run_id) do
      dir = Path.join(runs_root(opts), run_id)
      ensure_dir(dir)
    end
  end

  @doc "The `result.txt` path under a run dir (codex `-o` target / claude harvest)."
  @spec result_path(String.t()) :: String.t()
  def result_path(dir) when is_binary(dir), do: Path.join(dir, "result.txt")

  @doc "Writes the prompt snapshot (`prompt.md`, `0600`)."
  @spec snapshot_prompt(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def snapshot_prompt(dir, prompt) when is_binary(dir) and is_binary(prompt) do
    write_file(Path.join(dir, "prompt.md"), prompt)
  end

  @doc "Writes the terminal result artifact (`result.txt`, `0600`)."
  @spec write_result(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_result(dir, text) when is_binary(dir) and is_binary(text) do
    write_file(result_path(dir), text)
  end

  @doc "Opens the `0600` event spool for append; caller owns close via `close_spool/1`."
  @spec open_spool(String.t()) :: {:ok, :file.io_device()} | {:error, term()}
  def open_spool(dir) when is_binary(dir) do
    path = Path.join(dir, "events.jsonl")

    case File.open(path, [:write, :binary]) do
      {:ok, io} -> chmod_or_close(path, io)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Appends one raw event line (a newline is added). Returns the spool error on ENOSPC."
  @spec append_spool(:file.io_device(), String.t()) :: :ok | {:error, term()}
  def append_spool(io, line) when is_binary(line) do
    IO.binwrite(io, [line, "\n"])
  end

  @doc "Closes the event spool."
  @spec close_spool(:file.io_device()) :: :ok
  def close_spool(io), do: File.close(io)

  @doc """
  Admission gate: refuses a new run when the store exceeds `artifact_quota_gb`
  or free space is below `min_free_gb`. Numeric bounds and the `:free_bytes`
  probe are injectable; production reads `Harness.Config` and probes with `df`.
  A `min_free_gb` of `0` disables the free-space floor (no probe runs).
  """
  @spec admission_check(keyword()) :: :ok | {:error, {:artifact_quota, quota_detail()}}
  def admission_check(opts \\ []) when is_list(opts) do
    root = runs_root(opts)
    quota_bytes = Keyword.get(opts, :quota_gb, Config.artifact_quota_gb()) * @bytes_per_gb
    used = dir_size(root, @max_walk_depth)

    if used >= quota_bytes do
      {:error,
       {:artifact_quota, %{kind: :quota_exceeded, used_bytes: used, quota_bytes: quota_bytes}}}
    else
      check_free_space(root, opts)
    end
  end

  @doc """
  Deletes run directories whose mtime predates `now - artifact_retention_days`.
  Bounded to the direct children of the runs root; symlinks and non-directories
  are skipped; deletes route through the strictly-under-root SafeRm-style guard.
  """
  @spec gc(DateTime.t(), keyword()) :: {:ok, %{removed: non_neg_integer()}}
  def gc(%DateTime{} = now, opts \\ []) when is_list(opts) do
    root = runs_root(opts)
    retention_days = Keyword.get(opts, :retention_days, Config.artifact_retention_days())
    cutoff = DateTime.to_unix(now) - retention_days * 86_400

    case File.ls(root) do
      {:ok, entries} -> {:ok, %{removed: sweep(entries, root, cutoff)}}
      {:error, _missing_root} -> {:ok, %{removed: 0}}
    end
  end

  defp sweep(entries, root, cutoff) do
    Enum.reduce(entries, 0, fn entry, removed ->
      path = Path.join(root, entry)

      if expired_run_dir?(path, cutoff) and delete_run_dir(path, root) == :ok do
        removed + 1
      else
        removed
      end
    end)
  end

  defp expired_run_dir?(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} -> mtime < cutoff
      _not_a_plain_dir -> false
    end
  end

  # The production SafeRm guard: strictly under root, no `..`, deep enough — so
  # the runs root itself, a parent, or a root-ish path is always rejected.
  defp delete_run_dir(path, root) do
    expanded = Path.expand(path)
    root_expanded = Path.expand(root)

    cond do
      String.contains?(path, "..") ->
        reject_delete(path, {:traversal, path})

      not String.starts_with?(expanded, root_expanded <> "/") ->
        reject_delete(path, {:outside_runs_root, expanded})

      length(Path.split(expanded)) < @min_delete_segments ->
        reject_delete(path, {:too_shallow, expanded})

      true ->
        remove(expanded)
    end
  end

  defp remove(expanded) do
    case File.rm_rf(expanded) do
      {:ok, _removed} -> :ok
      {:error, reason, failed} -> reject_delete(expanded, {reason, failed})
    end
  end

  defp reject_delete(path, reason) do
    Logger.warning("harness artifacts gc skipped #{inspect(path)}: #{inspect(reason)}")
    {:error, reason}
  end

  defp check_free_space(root, opts) do
    min_free_gb = Keyword.get(opts, :min_free_gb, Config.min_free_gb())

    if min_free_gb == 0 do
      :ok
    else
      free_bytes = Keyword.get(opts, :free_bytes, &df_free_bytes/1)
      evaluate_free_space(free_bytes.(root), min_free_gb * @bytes_per_gb)
    end
  end

  defp evaluate_free_space({:ok, free}, min_free_bytes) when free >= min_free_bytes, do: :ok

  defp evaluate_free_space({:ok, free}, min_free_bytes) do
    {:error,
     {:artifact_quota, %{kind: :below_min_free, free_bytes: free, min_free_bytes: min_free_bytes}}}
  end

  defp evaluate_free_space({:error, reason}, _min_free_bytes) do
    {:error, {:artifact_quota, %{kind: :free_space_unknown, reason: reason}}}
  end

  defp df_free_bytes(path) do
    case System.find_executable("df") do
      nil -> {:error, :df_unavailable}
      df -> run_df(df, existing_ancestor(path))
    end
  end

  # `df` requires a path that exists. The runs root is created by `prepare/2`,
  # which runs AFTER admission, so on a fresh FERMIX_HOME the root is absent: a
  # probe against it exits non-zero, `evaluate_free_space` fails closed, and every
  # run is refused — including the machine's first, which would never create the
  # root, deadlocking the harness permanently. Free space is a property of the
  # containing filesystem, so probe the nearest ancestor that exists. Bounded:
  # `Path.dirname/1` converges on the root, where parent == path.
  defp existing_ancestor(path) do
    parent = Path.dirname(path)

    cond do
      File.exists?(path) -> path
      parent == path -> path
      true -> existing_ancestor(parent)
    end
  end

  defp run_df(df, path) do
    case CommandRunner.run(df, ["-Pk", path], timeout_ms: @df_timeout_ms) do
      {:ok, %{exit: 0, stdout: out}} -> parse_df(out)
      {:ok, %{exit: code}} -> {:error, {:df_failed, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  # POSIX `df -Pk` prints a header then one line per filesystem; the 4th column
  # is Available in 1024-byte blocks.
  defp parse_df(out) do
    case String.split(out, "\n", trim: true) do
      [_header, data | _rest] -> parse_df_available(String.split(data))
      _too_short -> {:error, :df_unparseable}
    end
  end

  defp parse_df_available([_fs, _blocks, _used, available | _rest]) do
    case Integer.parse(available) do
      {kb, _remainder} -> {:ok, kb * 1024}
      :error -> {:error, :df_unparseable}
    end
  end

  defp parse_df_available(_fields), do: {:error, :df_unparseable}

  # Recursive apparent size, never following symlinks (lstat), bounded in depth.
  defp dir_size(_path, 0), do: 0

  defp dir_size(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> sum_children(path, depth)
      {:ok, %File.Stat{type: :regular, size: size}} -> size
      _symlink_or_missing -> 0
    end
  end

  defp sum_children(dir, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, acc ->
          acc + dir_size(Path.join(dir, entry), depth - 1)
        end)

      {:error, _unreadable} ->
        0
    end
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      {:ok, %{dir: dir}}
    end
  end

  defp write_file(path, content) do
    with :ok <- File.write(path, content),
         :ok <- File.chmod(path, @file_mode) do
      {:ok, path}
    end
  end

  defp chmod_or_close(path, io) do
    case File.chmod(path, @file_mode) do
      :ok ->
        {:ok, io}

      {:error, reason} ->
        File.close(io)
        {:error, reason}
    end
  end

  defp validate_run_id(run_id) do
    if Regex.match?(@run_id_regex, run_id) do
      :ok
    else
      {:error, {:invalid_run_id, run_id}}
    end
  end
end
