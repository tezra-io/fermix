defmodule FermixCore.Home.Snapshot do
  @moduledoc """
  Encrypted, consistent snapshots of a home (M75 §8, D19, B7, B8): what a
  primary writes on its cadence for recovery, and what the move streams to its
  candidate (§7.2).

  **Capture** (`write/4`) takes the home minus the device-local list while the
  engine may be running (`Snapshot.Capture`: one copy of each file, `memory.db`
  through `VACUUM INTO`, never the live WAL or shared-memory file), puts the
  stage-1 manifest first, and streams it through `Snapshot.Format` (`FXSNAP1`)
  encrypted to a recipient (`Snapshot.Recipient`), a chunk at a time, into a
  sink: a file, or a function that receives each piece of the encrypted
  stream (the move hands its rail session one). It answers the stream's
  SHA-256 and length, the epoch captured and the snapshot's name,
  `<UTC>-e<epoch>.fxsnap`.

  **Restore** (`restore/4`) decrypts with the recipient's private half into a
  private staging directory inside the empty root, checking every chunk and
  every file as it arrives, and only once the whole stream opened and every
  file matched its entry makes the root the next primary through the archive's
  own path (`FermixCore.Home.Archive.install/5`): epoch plus one, the settled
  `config.toml`, consent withdrawn, screen history deleted, plugins built for
  another host named. A failure on any path leaves the root as it found it:
  absent stays absent, empty stays empty.

  Both refuse by name rather than guess: `write/4` a home that moved
  (`{:home_moved, marker}`), one whose marker cannot be read, and one with no
  primary epoch (`:epoch_absent`); `restore/4` a root that is not empty, a
  stream that is not a snapshot, the wrong key, and any changed byte.
  """

  alias FermixCore.Home.Archive
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Disk
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Unpack

  require Logger

  @read_bytes 1_048_576
  @file_mode 0o600
  @dir_mode 0o700
  @extension ".fxsnap"

  @typedoc "Where the encrypted stream goes: a new file, or a function given each piece."
  @type sink :: Path.t() | (iodata() -> :ok | {:error, term()})
  @typedoc "Where an encrypted stream comes from: a file, or a `Format.read()` function."
  @type source :: Path.t() | Format.read()
  @type written :: %{
          sha256: String.t(),
          size: non_neg_integer(),
          epoch: pos_integer(),
          name: String.t(),
          created_at: DateTime.t()
        }

  @doc """
  Captures the home at `root` and streams it, encrypted to `recipient`
  (`Recipient.t()`, the public half), into `sink`.

  A path `sink` must not exist; it is written beside itself as
  `<path>.partial`, mode `0600`, and renamed into place, and removed on every
  failure. A function `sink` receives each piece in order and may stop the
  capture with `{:error, reason}`; what it already received is its own to
  discard.

  `opts`: `:now` (a 0-arity clock for `created_at` and the name), `:host`
  (the plugin installer's target name, as `Archive.host/1` reads it),
  `:free_bytes` (a 1-arity reader of a directory's free space, in place of
  `FermixCore.Home.Disk.free_bytes/1`), and `:extra_files`: `{path, bytes}`
  pairs, relative to the home, that ride inside the encrypted stream as files
  of the home (mode `0600`) without ever being written to its disk, each in
  place of a captured file of the same path. The move carries the values of
  the keychain's secrets this way (`FermixCore.Home.MoveSecrets`).

  Before anything is copied the disk must hold twice the home plus a floor
  (`Disk.capture_need/1`): a capture short of it is refused by number,
  `{:insufficient_space, need, free}`, and one whose free space cannot be read
  `{:free_space_unknown, reason}`.
  """
  @spec write(Path.t(), Recipient.t(), sink(), keyword()) ::
          {:ok, written()} | {:error, term()}
  def write(root, recipient, sink, opts \\ [])
      when is_binary(root) and root != "" and is_map(recipient) and is_list(opts) and
             (is_binary(sink) or is_function(sink, 1)) do
    root = Path.expand(root)
    created_at = opts |> Keyword.get(:now, &DateTime.utc_now/0) |> then(& &1.()) |> second()
    extra = extra_files(Keyword.get(opts, :extra_files, []))

    with :ok <- home_directory(root),
         :ok <- not_moved(root),
         {:ok, epoch} <- primary_epoch(root),
         {:ok, host} <- Archive.host(opts),
         {:ok, staging} <- Capture.staging(root, "capture") do
      try do
        capture(root, staging, recipient, sink, %{
          created_at: created_at,
          epoch: epoch,
          host: host,
          extra: extra,
          free_bytes: Keyword.get(opts, :free_bytes, &Disk.free_bytes/1)
        })
      after
        Capture.discard(staging)
      end
    end
  end

  @doc """
  Restores the snapshot `source` answers into `into_root`, which must be empty
  or absent, decrypting with `pair` (the recipient with its private half,
  `Recipient.derive/2` or `Recipient.generate/0`).

  `opts` as `Archive.restore/4`: `:host`, `:keyring_usable?`,
  `:probe_timeout_ms` and `:now_ms`.
  Answers what `Archive.restore/4` answers.
  """
  @spec restore(source(), Recipient.pair(), Path.t(), keyword()) ::
          {:ok, Archive.restored()} | {:error, term()}
  def restore(source, %{secret_key: _secret} = pair, into_root, opts \\ [])
      when (is_binary(source) or is_function(source, 1)) and is_binary(into_root) and
             into_root != "" and is_list(opts) do
    root = Path.expand(into_root)

    with {:ok, _host} <- Archive.host(opts),
         {:ok, root_state} <- Archive.root_state(root),
         :ok <- prepare_root(root, root_state),
         {:ok, staging} <- restore_staging(root, root_state) do
      result =
        with {:ok, manifest} <- unpack(source, pair, staging) do
          Archive.install(manifest, {:staged, staging}, root, :empty, opts)
        end

      settle_root(root, root_state, staging, result)
    end
  end

  @doc "A snapshot's name: `<UTC created_at>-e<epoch>.fxsnap`."
  @spec name(DateTime.t(), pos_integer()) :: String.t()
  def name(%DateTime{} = created_at, epoch) when is_integer(epoch) and epoch >= 1 do
    stamp = created_at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "#{stamp}-e#{epoch}#{@extension}"
  end

  # -- write ------------------------------------------------------------------

  defp capture(root, staging, recipient, sink, facts) do
    with {:ok, manifest} <- Capture.stage(root, staging, facts),
         {:ok, written} <- encrypt(manifest, staging, recipient, sink, facts) do
      {:ok,
       Map.merge(written, %{
         epoch: facts.epoch,
         created_at: facts.created_at,
         name: name(facts.created_at, facts.epoch)
       })}
    end
  end

  defp encrypt(manifest, staging, recipient, path, facts) when is_binary(path) do
    path = Path.expand(path)
    partial = path <> ".partial"

    with :ok <- free(path),
         {:ok, io} <- open_partial(partial) do
      emit = fn iodata -> IO.binwrite(io, iodata) end
      streamed = stream(manifest, staging, recipient, emit, facts)
      place_partial(io, partial, path, streamed)
    end
  end

  defp encrypt(manifest, staging, recipient, emit, facts) when is_function(emit, 1),
    do: stream(manifest, staging, recipient, emit, facts)

  defp stream(manifest, staging, recipient, emit, facts) do
    json = Archive.Manifest.encode(manifest)

    with {:ok, writer} <- Format.open_writer(recipient, facts, emit),
         {:ok, writer} <- Format.write(writer, [<<byte_size(json)::32>>, json]),
         {:ok, writer} <- stream_files(writer, staging, manifest.files, facts.extra) do
      Format.finish(writer)
    end
  end

  defp stream_files(writer, staging, files, extra) do
    Enum.reduce_while(files, {:ok, writer}, fn entry, {:ok, writer} ->
      streamed =
        case Map.fetch(extra, entry.path) do
          {:ok, bytes} -> Format.write(writer, bytes)
          :error -> stream_file(writer, Path.join(staging, entry.path), entry)
        end

      case streamed do
        {:ok, writer} -> {:cont, {:ok, writer}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # In-memory files: relative paths a restore may write, each once.
  defp extra_files(pairs) when is_list(pairs) do
    Map.new(pairs, fn
      {path, bytes} when is_binary(path) and is_binary(bytes) ->
        unless extra_path?(path),
          do: raise(ArgumentError, "an extra snapshot file must be a home path: #{inspect(path)}")

        {path, bytes}

      other ->
        raise ArgumentError, "an extra snapshot file is {path, bytes}, got: #{inspect(other)}"
    end)
  end

  defp extra_path?(path) do
    segments = String.split(path, "/")

    Path.type(path) == :relative and Enum.all?(segments, &(&1 not in ["", ".", ".."])) and
      not DeviceLocal.excluded?(path)
  end

  defp stream_file(writer, path, entry) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          stream_chunks(io, writer, entry, 0)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  # The staged copy is private to this capture, so a length other than its
  # entry's is a fault here, refused rather than streamed.
  defp stream_chunks(io, writer, entry, sent) do
    case IO.binread(io, @read_bytes) do
      :eof when sent == entry.bytes ->
        {:ok, writer}

      :eof ->
        {:error, {:changed_during_capture, entry.path}}

      {:error, reason} ->
        {:error, {:file, entry.path, reason}}

      data when sent + byte_size(data) > entry.bytes ->
        {:error, {:changed_during_capture, entry.path}}

      data ->
        continue_stream(io, Format.write(writer, data), entry, sent + byte_size(data))
    end
  end

  defp continue_stream(io, {:ok, writer}, entry, sent), do: stream_chunks(io, writer, entry, sent)
  defp continue_stream(_io, {:error, _reason} = error, _entry, _sent), do: error

  defp free(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:destination_exists, path}}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp open_partial(partial) do
    case File.open(partial, [:write, :exclusive, :binary]) do
      {:ok, io} -> chmod_partial(io, partial)
      {:error, :eexist} -> {:error, {:stale_partial, partial}}
      {:error, reason} -> {:error, {:file, partial, reason}}
    end
  end

  defp chmod_partial(io, partial) do
    case File.chmod(partial, @file_mode) do
      :ok -> {:ok, io}
      {:error, reason} -> discard_partial(io, partial, {:error, {:file, partial, reason}})
    end
  end

  defp place_partial(io, partial, path, {:ok, written}) do
    with :ok <- close_file(io, partial),
         :ok <- rename(partial, path) do
      {:ok, written}
    else
      {:error, _reason} = error -> discard_partial(nil, partial, error)
    end
  end

  defp place_partial(io, partial, _path, {:error, _reason} = error),
    do: discard_partial(io, partial, error)

  defp discard_partial(io, partial, error) do
    if io, do: File.close(io)
    remove_file(partial)
    error
  end

  defp close_file(io, path) do
    case File.close(io) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, to, reason}}
    end
  end

  defp home_directory(root) do
    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _other -> {:error, {:home_not_found, root}}
    end
  end

  defp not_moved(root) do
    case Moved.read(root) do
      :absent -> :ok
      {:ok, marker} -> {:error, {:home_moved, marker}}
      {:error, reason} -> {:error, {:moved_marker_unreadable, reason}}
    end
  end

  defp primary_epoch(root) do
    case Epoch.read(root) do
      {:ok, epoch} -> {:ok, epoch}
      :absent -> {:error, :epoch_absent}
      {:error, _reason} = error -> error
    end
  end

  defp second(%DateTime{} = at), do: DateTime.truncate(at, :second)

  # -- restore ----------------------------------------------------------------

  defp prepare_root(root, :absent), do: make_private_dir(root)
  defp prepare_root(_root, :empty), do: :ok

  # The staging directory lives inside the root, so every file reaches its
  # place by a rename on one filesystem.
  defp restore_staging(root, root_state) do
    staging =
      Path.join(
        root,
        ".fxsnap-restore-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    case make_private_dir(staging) do
      :ok -> {:ok, staging}
      {:error, _reason} = error -> settle_root(root, root_state, nil, error)
    end
  end

  defp unpack(path, pair, staging) when is_binary(path) do
    Format.with_file(Path.expand(path), &unpack(&1, pair, staging))
  end

  defp unpack(read, pair, staging) when is_function(read, 1) do
    with {:ok, header, state} <- Format.decrypt(read, pair, &Unpack.feed/2, Unpack.new(staging)),
         {:ok, manifest} <- Unpack.finish(state),
         :ok <- same_epoch(header, manifest) do
      {:ok, manifest}
    end
  end

  # The header's epoch is in clear and covered by every chunk's tag; the
  # manifest's is inside. A writer puts the same one in both.
  defp same_epoch(%{epoch: epoch}, %{primary_epoch: epoch}), do: :ok
  defp same_epoch(_header, _manifest), do: {:error, {:invalid_manifest, :epoch_mismatch}}

  # The staging directory goes on every path; a root this restore created goes
  # with it when the restore failed.
  defp settle_root(root, root_state, staging, result) do
    if staging, do: Capture.discard(staging)

    case {result, root_state} do
      {{:error, _reason}, :absent} -> remove_dir(root)
      _kept -> :ok
    end

    result
  end

  defp make_private_dir(dir) do
    with :ok <- dir_op(File.mkdir(dir), dir), do: dir_op(File.chmod(dir, @dir_mode), dir)
  end

  defp dir_op(:ok, _dir), do: :ok
  defp dir_op({:error, reason}, dir), do: {:error, {:file, dir, reason}}

  defp remove_dir(dir) do
    case File.rmdir(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("home snapshot restore: could not remove #{dir}: #{inspect(reason)}")
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("home snapshot: could not remove #{path}: #{inspect(reason)}")
    end
  end
end
