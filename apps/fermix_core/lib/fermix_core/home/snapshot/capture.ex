defmodule FermixCore.Home.Snapshot.Capture do
  @moduledoc """
  Takes a consistent copy of a home that may be running, for one snapshot
  (`FermixCore.Home.Snapshot.write/4`).

  The set of files is the archive's (`FermixCore.Home.Archive.collect/2`):
  everything under the home minus the device-local list, with no byte bound.
  Each file is copied once, while it is hashed, into a private staging
  directory under `<home>/snapshots/` (device-local, so a capture never
  captures itself), and the snapshot is then streamed from those copies: what
  the manifest describes is exactly what the stream carries, even when a file
  is replaced while the capture runs. The cost is one copy of the home on the
  same disk until the snapshot is written.

  `memory.db` is not copied. SQLite's `VACUUM INTO` writes a consistent copy of
  the database from one read transaction, which a running engine's writes
  neither block nor tear, and the live `-wal`, `-shm` and `-journal` files are
  left out: the copy already holds every committed row.

  A file that grows by more than #{div(67_108_864, 1_048_576)} MiB beyond its
  size when the home was walked is refused by name
  (`{:changed_during_capture, path}`) rather than chased.

  Before the first copy the disk must hold twice what the walk found plus a
  floor (`FermixCore.Home.Disk.capture_need/1`): the copies and the encrypted
  stream beside them. Short of it the capture is refused by number
  (`{:insufficient_space, need, free}`) with nothing copied.

  Files given in memory (`facts.extra`, path to bytes) are listed in the
  manifest in place of any captured file of the same path, mode `0600`, and
  never written here: the stream carries them from memory.
  """

  alias Exqlite.Sqlite3
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Archive.Manifest
  alias FermixCore.Home.Disk

  require Logger

  @database "memory.db"
  @live_sidecars ~w(memory.db-wal memory.db-shm memory.db-journal)
  @dir "snapshots"
  @dir_mode 0o700
  @read_bytes 1_048_576
  @growth_bytes 67_108_864
  @busy_timeout_ms 5_000

  @doc "Where snapshot state lives under `root`: device-local, mode `0700`."
  @spec dir(Path.t()) :: Path.t()
  def dir(root) when is_binary(root), do: Path.join(root, @dir)

  @doc "Creates a private, uniquely named staging directory under `dir/1`."
  @spec staging(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def staging(root, kind) when is_binary(root) and is_binary(kind) do
    base = dir(root)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    staging = Path.join(base, ".#{kind}-#{suffix}")

    with :ok <- private_dir(base),
         :ok <- file_op(File.mkdir(staging), staging),
         :ok <- file_op(File.chmod(staging, @dir_mode), staging) do
      {:ok, staging}
    end
  end

  @doc "Removes a staging directory this module made, logging what it could not."
  @spec discard(Path.t()) :: :ok
  def discard(staging) when is_binary(staging) do
    case File.rm_rf(staging) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.error("home snapshot: could not remove #{path}: #{inspect(reason)}")
    end
  end

  @doc """
  Copies the home at `root` into `staging` and answers the manifest of the
  copies: the stage-1 manifest (`Archive.Manifest`) with `header`'s epoch, the
  home's root and the host.
  """
  @spec stage(Path.t(), Path.t(), %{
          required(:epoch) => pos_integer(),
          required(:host) => String.t(),
          optional(:extra) => %{String.t() => binary()},
          optional(:free_bytes) => Disk.free_bytes()
        }) ::
          {:ok, Manifest.t()} | {:error, term()}
  def stage(root, staging, %{epoch: epoch, host: host} = facts) do
    extra = Map.get(facts, :extra, %{})
    free_bytes = Map.get(facts, :free_bytes, &Disk.free_bytes/1)

    with {:ok, found, links} <- Archive.collect(root, :infinity),
         found = Enum.reject(found, fn {rel, _stat} -> Map.has_key?(extra, rel) end),
         :ok <- room(root, found, extra, free_bytes),
         {:ok, entries} <- copy_all(root, staging, found) do
      entries = entries ++ Enum.map(extra, &memory_entry/1)
      {:ok, Manifest.new(%{primary_epoch: epoch, home_root: root, host: host}, entries, links)}
    end
  end

  defp room(root, found, extra, free_bytes) do
    home_bytes =
      Enum.reduce(found, 0, fn {_rel, stat}, sum -> sum + stat.size end) +
        Enum.reduce(extra, 0, fn {_path, bytes}, sum -> sum + byte_size(bytes) end)

    need = Disk.capture_need(home_bytes)

    case free_bytes.(root) do
      {:ok, free} when free >= need -> :ok
      {:ok, free} -> {:error, {:insufficient_space, need, free}}
      {:error, reason} -> {:error, {:free_space_unknown, reason}}
    end
  end

  defp memory_entry({path, bytes}) do
    sha256 = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    %{path: path, bytes: byte_size(bytes), sha256: sha256, mode: 0o600}
  end

  defp copy_all(root, staging, found) do
    found
    |> Enum.reject(fn {rel, _stat} -> rel in @live_sidecars end)
    |> Enum.reduce_while({:ok, []}, fn {rel, stat}, {:ok, acc} ->
      case capture(root, staging, rel, stat) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp capture(root, staging, rel, stat) do
    target = Path.join(staging, rel)

    with :ok <- File.mkdir_p(Path.dirname(target)) |> file_op(Path.dirname(target)),
         {:ok, bytes, sha256} <- copy(root, rel, stat, target) do
      {:ok, %{path: rel, bytes: bytes, sha256: sha256, mode: Bitwise.band(stat.mode, 0o777)}}
    end
  end

  defp copy(root, @database, _stat, target) do
    with :ok <- vacuum_into(Path.join(root, @database), target) do
      hash_file(target)
    end
  end

  defp copy(root, rel, stat, target),
    do: copy_hashing(Path.join(root, rel), target, stat.size + @growth_bytes, rel)

  @doc """
  Writes a consistent copy of the SQLite database at `source` to `target`
  with `VACUUM INTO`, on a connection of its own that waits up to
  #{@busy_timeout_ms} ms for a writer, and is closed on every path.
  """
  @spec vacuum_into(Path.t(), Path.t()) :: :ok | {:error, {:vacuum, term()}}
  def vacuum_into(source, target) when is_binary(source) and is_binary(target) do
    if File.regular?(source) do
      case Sqlite3.open(source, mode: :readwrite) do
        {:ok, conn} -> close_after(conn, vacuum(conn, target))
        {:error, reason} -> {:error, {:vacuum, reason}}
      end
    else
      {:error, {:vacuum, :no_database}}
    end
  end

  defp vacuum(conn, target) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=#{@busy_timeout_ms}"),
         {:ok, stmt} <- Sqlite3.prepare(conn, "VACUUM INTO ?1") do
      result = step_vacuum(conn, stmt, target)

      case {result, Sqlite3.release(conn, stmt)} do
        {:ok, :ok} -> :ok
        {{:error, _reason} = error, _released} -> error
        {:ok, {:error, reason}} -> {:error, reason}
      end
    end
    |> vacuum_error()
  end

  defp step_vacuum(conn, stmt, target) do
    with :ok <- Sqlite3.bind(stmt, [target]) do
      case Sqlite3.step(conn, stmt) do
        :done -> :ok
        :busy -> {:error, :busy}
        {:row, _row} -> {:error, :unexpected_row}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp vacuum_error(:ok), do: :ok
  defp vacuum_error({:error, {:vacuum, _reason}} = error), do: error
  defp vacuum_error({:error, reason}), do: {:error, {:vacuum, reason}}

  defp close_after(conn, result) do
    case {result, Sqlite3.close(conn)} do
      {result, :ok} -> result
      {:ok, {:error, reason}} -> {:error, {:vacuum, reason}}
      {error, {:error, _reason}} -> error
    end
  end

  @doc "The length and SHA-256 (hex) of the file at `path`, read a chunk at a time."
  @spec hash_file(Path.t()) :: {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def hash_file(path) when is_binary(path) do
    with_open(path, [:read, :binary], fn io ->
      fold_chunks(io, {0, :crypto.hash_init(:sha256)}, :infinity, path, fn data, {n, digest} ->
        {:ok, {n + byte_size(data), :crypto.hash_update(digest, data)}}
      end)
    end)
    |> finish_hash()
  end

  defp copy_hashing(source, target, max_bytes, rel) do
    with_open(source, [:read, :binary], fn input ->
      case File.open(target, [:write, :exclusive, :binary]) do
        {:ok, output} -> closed(output, target, copy_into(input, output, target, max_bytes, rel))
        {:error, reason} -> {:error, {:file, target, reason}}
      end
    end)
    |> finish_hash()
  end

  defp copy_into(input, output, target, max_bytes, rel) do
    fold_chunks(input, {0, :crypto.hash_init(:sha256)}, max_bytes, rel, fn data, {n, digest} ->
      case IO.binwrite(output, data) do
        :ok -> {:ok, {n + byte_size(data), :crypto.hash_update(digest, data)}}
        {:error, reason} -> {:error, {:file, target, reason}}
      end
    end)
  end

  # A written file's close can fail where its writes did not (a full disk), so
  # the close is part of the result.
  defp closed(io, path, result) do
    case {result, File.close(io)} do
      {result, :ok} -> result
      {{:ok, _acc}, {:error, reason}} -> {:error, {:file, path, reason}}
      {error, {:error, _reason}} -> error
    end
  end

  defp finish_hash({:ok, {bytes, digest}}),
    do: {:ok, bytes, digest |> :crypto.hash_final() |> Base.encode16(case: :lower)}

  defp finish_hash({:error, _reason} = error), do: error

  # Reads to the end, a chunk at a time, refusing past `max_bytes`: a file
  # growing faster than it is read is refused by name, never chased.
  defp fold_chunks(io, acc, max_bytes, rel, fun) do
    case IO.binread(io, @read_bytes) do
      :eof -> {:ok, acc}
      {:error, reason} -> {:error, {:file, rel, reason}}
      data -> fold_more(io, fun.(data, acc), max_bytes, rel, fun)
    end
  end

  defp fold_more(io, {:ok, {bytes, _digest} = acc}, max_bytes, rel, fun) do
    if max_bytes != :infinity and bytes > max_bytes,
      do: {:error, {:changed_during_capture, rel}},
      else: fold_chunks(io, acc, max_bytes, rel, fun)
  end

  defp fold_more(_io, {:error, _reason} = error, _max_bytes, _rel, _fun), do: error

  defp with_open(path, modes, fun) do
    case File.open(path, modes) do
      {:ok, io} ->
        try do
          fun.(io)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  defp private_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp reverse_ok({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_ok({:error, _reason} = error), do: error

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
