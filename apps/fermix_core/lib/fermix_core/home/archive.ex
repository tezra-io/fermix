defmodule FermixCore.Home.Archive do
  @moduledoc """
  The home archive (M75 step 8): one encrypted file holding everything that
  makes a home the primary engine, for a move to another host or a restore after
  one is lost.

  **Contents.** Every regular file under the home except the device-local list
  (`FermixCore.Home.DeviceLocal`): configuration, the database and its WAL and
  shared-memory files, the token file and the file secret store, the identity
  bundle with `mobile/primary_epoch`, prompt files, skills, journals and
  installed plugins. The database is copied as files and never opened, which is
  why `create/3` refuses while the engine that owns the home is running: a live
  engine can be mid-write.

  **Format.** A tar whose first entry is `manifest.json`
  (`FermixCore.Home.Archive.Manifest`), then each file as `home/<path>`, sealed
  as one blob under the owner's passphrase (`FermixCore.Home.Archive.Seal`).
  The tar is built beside the destination, mode `0600`, and removed on every
  path; the sealed file is renamed into place, mode `0600`.

  **Memory.** OTP's AES-GCM is one-shot, so the whole archive is held in memory:
  about twice its size while exporting and up to three times while restoring
  (sealed, opened and extracted), bounded by the manifest's 1 GiB of file
  content. The scheduled snapshot (`FermixCore.Home.Snapshot`) is the chunked
  format with no such bound, and restores through the same `install/5`.

  **Restore is a new primary.** `restore/4` writes into an empty root, checks
  every file against the manifest before writing any of them, writes each with
  its recorded mode under `0700` directories, and then writes `primary_epoch`
  as the manifest's epoch plus one (M75 D14). It never writes `moved.json`:
  retiring the old home is a separate, explicit step. A failure part-way removes
  exactly the files and directories it wrote.

  **A new path.** The manifest records the archived home's absolute root. A
  restore into another root rewrites the `config.toml` string values that
  began with the old root so they begin with the new one, line by line with
  comments and every other byte kept (`FermixCore.Home.Archive.ConfigText`),
  and answers the dotted key of each value it moved. Paths recorded inside
  `memory.db` are never touched.

  **Keyring secrets.** Secrets kept in the OS keyring are not in the home; the
  archive carries only their `@keyring` references. Both directions answer how
  many there are, so the owner knows how many to enter again on the new host.

  **A newer engine's home is refused.** The manifest names the engine that
  wrote it; a restore by an older engine refuses it by name
  (`{:newer_engine, theirs, ours}`) before it writes anything, since the home
  may hold settings and data this engine cannot read.

  **What does not travel as consent or history.** A restore withdraws
  coding-harness consent, moves a keyring-mode home to the file store on a host
  without a usable keyring (`FermixCore.Home.Archive.RestoredConfig`), deletes
  screen history from the restored database
  (`FermixCore.Home.Archive.ScreenHistory`), and names the installed plugins
  built for another OS or architecture (the manifest's `host`). Sandbox grants
  are device-local and never in the archive.
  """

  alias Fermix.CLI.Upgrade.Manifest, as: HostTarget
  alias FermixCore.BuildInfo
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Archive.Manifest
  alias FermixCore.Home.Archive.RestoredConfig
  alias FermixCore.Home.Archive.ScreenHistory
  alias FermixCore.Home.Archive.Seal
  alias FermixCore.Home.DaemonProbe
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Setup.SecretWriter

  require Logger

  @manifest_entry "manifest.json"
  @config "config.toml"
  @database "memory.db"
  @database_sidecars ~w(memory.db-wal memory.db-shm memory.db-journal)
  @plugin_lockfile "plugins/installed.json"
  @home_prefix "home/"
  @max_depth 64
  @dir_mode 0o700
  @archive_mode 0o600

  @type created :: %{
          path: Path.t(),
          bytes: non_neg_integer(),
          files: non_neg_integer(),
          epoch: pos_integer(),
          keyring_secrets: non_neg_integer()
        }
  @type source :: {:memory, %{String.t() => binary()}} | {:staged, Path.t()}
  @type restored :: %{
          files: non_neg_integer(),
          epoch: pos_integer(),
          rewritten: [String.t()],
          kept_paths: [String.t()],
          harness_consent_reset: boolean(),
          secret_store_switched: boolean(),
          imessage_disabled: boolean(),
          keyring_secrets: non_neg_integer(),
          screen_history_removed: non_neg_integer(),
          source_host: String.t(),
          host: String.t(),
          plugins_to_reinstall: [String.t()]
        }

  @doc """
  Writes the archive of the home at `root` to `opts[:to]`, sealed under
  `passphrase`.

  Refuses, by name: a passphrase under twelve bytes, a destination that exists
  or lies inside the home, a home that is not a directory, a home that carries
  the moved marker (`{:home_moved, marker}`, or `{:moved_marker_unreadable,
  reason}` for a marker that cannot be read), checked before anything in the
  home is read: a retired copy restored elsewhere would mint the live
  primary's own epoch under the same identity, a running engine
  (`:daemon_running`, read through the control socket's `hello`, the probe
  `fermix status` uses; `opts[:hello]` replaces it in tests), a probe that
  cannot tell (`{:daemon_probe_failed, reason}`), a home with no primary epoch
  (`:epoch_absent`), and a home beyond the manifest's bounds.
  """
  @spec create(Path.t(), binary(), keyword()) :: {:ok, created()} | {:error, term()}
  def create(root, passphrase, opts)
      when is_binary(root) and root != "" and is_binary(passphrase) and is_list(opts) do
    root = Path.expand(root)

    with {:ok, to} <- destination(opts, root),
         :ok <- passphrase_length(passphrase),
         :ok <- home_directory(root),
         :ok <- not_moved(root),
         :ok <- daemon_stopped(opts, root),
         {:ok, epoch} <- primary_epoch(root),
         {:ok, found, links} <- collect(root, Manifest.max_total_bytes()),
         {:ok, entries} <- describe(root, found),
         {:ok, keyring_secrets} <- keyring_references(root, entries),
         {:ok, host} <- host(opts),
         header = %{primary_epoch: epoch, home_root: root, host: host},
         manifest = Manifest.new(header, entries, links),
         {:ok, bytes} <- write_archive(root, manifest, passphrase, to) do
      {:ok,
       %{
         path: to,
         bytes: bytes,
         files: length(entries),
         epoch: epoch,
         keyring_secrets: keyring_secrets
       }}
    end
  end

  @doc """
  Restores the archive at `archive_path` into `root`, which must be empty or
  absent, and makes it the next primary: `primary_epoch` is the manifest's plus
  one.

  `opts` replace this host's facts in tests: `:host` (the plugin installer's
  target name, such as `linux-x86_64`), `:keyring_usable?` (a 0-arity
  function) and `:now_ms` (the screen-history clear's bound).

  Refuses, by name: a passphrase under twelve bytes, a root that is not empty
  (`:root_not_empty`), an archive that does not open (`:archive_rejected`), a
  manifest that is malformed, out of bounds or names a path outside the root, a
  tar entry the manifest does not list, and a file whose bytes do not match its
  manifest entry (`{:corrupt_entry, path}`). Nothing is written until every
  check has passed.
  """
  @spec restore(Path.t(), binary(), Path.t(), keyword()) :: {:ok, restored()} | {:error, term()}
  def restore(archive_path, passphrase, root, opts \\ [])
      when is_binary(archive_path) and archive_path != "" and is_binary(passphrase) and
             is_binary(root) and root != "" and is_list(opts) do
    root = Path.expand(root)

    with :ok <- passphrase_length(passphrase),
         {:ok, _host} <- host(opts),
         {:ok, root_state} <- root_state(root),
         {:ok, sealed} <- read_archive(Path.expand(archive_path)),
         {:ok, tar} <- Seal.open(sealed, passphrase),
         {:ok, manifest, contents} <- unpack(tar) do
      install(manifest, {:memory, contents}, root, root_state, opts)
    end
  end

  @doc """
  Makes `root` the next primary from a verified `manifest` and its files, the
  one restore path an archive and a snapshot (`FermixCore.Home.Snapshot`)
  share: `primary_epoch` the manifest's plus one, `config.toml` settled for
  this host and path (`RestoredConfig`), screen history cleared, the plugins
  built for another host named, each file written with its recorded mode under
  `0700` directories, and every link recreated. A failure part-way removes
  exactly what it wrote.

  `source` holds the files the manifest lists, each already checked against
  its entry: `{:memory, contents}` (path to bytes) or `{:staged, dir}` (the
  files under a private directory on the root's own filesystem, each renamed
  into place). `root_state` is `root_state/1`'s answer for `root`. `opts` as
  `restore/4`.
  """
  @spec install(Manifest.t(), source(), Path.t(), :absent | :empty, keyword()) ::
          {:ok, restored()} | {:error, term()}
  def install(manifest, source, root, root_state, opts)
      when is_map(manifest) and is_binary(root) and root_state in [:absent, :empty] and
             is_list(opts) do
    with {:ok, host} <- host(opts),
         :ok <- not_newer(manifest.engine_version),
         {:ok, epoch} <- next_epoch(manifest.primary_epoch),
         {:ok, source, settled} <- settle_config(source, manifest, root, host, opts),
         {:ok, reinstall} <- plugins_to_reinstall(source, manifest, host),
         {:ok, removed} <- write_home(root, root_state, manifest, source, epoch, now_ms(opts)) do
      {:ok,
       Map.merge(settled, %{
         files: length(manifest.files),
         epoch: epoch,
         screen_history_removed: removed,
         source_host: manifest.host,
         host: host,
         plugins_to_reinstall: reinstall
       })}
    end
  end

  @doc """
  The plugin installer's own name for this host's target (`macos-aarch64`), or
  `opts[:host]` in its place (tests).
  """
  @spec host(keyword()) :: {:ok, String.t()} | {:error, {:host_unsupported, term()}}
  def host(opts) when is_list(opts) do
    case Keyword.fetch(opts, :host) do
      {:ok, host} when is_binary(host) -> {:ok, host}
      :error -> host_target(HostTarget.target_for_host())
    end
  end

  defp host_target({:ok, {os, arch}}), do: {:ok, "#{os}-#{arch}"}
  defp host_target({:error, reason}), do: {:error, {:host_unsupported, reason}}

  defp now_ms(opts), do: Keyword.get_lazy(opts, :now_ms, fn -> System.os_time(:millisecond) end)

  # -- create -----------------------------------------------------------------

  defp destination(opts, root) do
    case Keyword.get(opts, :to) do
      to when is_binary(to) and to != "" -> free_destination(Path.expand(to), root)
      other -> {:error, {:invalid_destination, other}}
    end
  end

  defp free_destination(to, root) do
    cond do
      String.starts_with?(to, root <> "/") -> {:error, {:destination_inside_home, to}}
      match?({:ok, _stat}, File.lstat(to)) -> {:error, {:destination_exists, to}}
      true -> {:ok, to}
    end
  end

  defp passphrase_length(passphrase) do
    if byte_size(passphrase) >= Seal.min_passphrase_bytes(),
      do: :ok,
      else: {:error, :passphrase_too_short}
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

  defp daemon_stopped(opts, root), do: DaemonProbe.stopped(root, Keyword.take(opts, [:hello]))

  defp primary_epoch(root) do
    case Epoch.read(root) do
      {:ok, epoch} -> {:ok, epoch}
      :absent -> {:error, :epoch_absent}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Every regular file and symbolic link under `root` that is not device-local,
  sorted, each file with its `File.Stat`, bounded by the manifest's entry
  count, by `max_total_bytes` of content (`Manifest.check_bounds/3`) and by
  depth. A link whose target could leave the home, and any special file, is
  refused by name rather than skipped. Shared by the archive and the snapshot
  capture, so both carry the same set.
  """
  @spec collect(Path.t(), Manifest.max_bytes()) ::
          {:ok, [{String.t(), File.Stat.t()}], [Manifest.link()]} | {:error, term()}
  def collect(root, max_total_bytes) when is_binary(root) do
    acc = %{files: [], links: [], count: 0, bytes: 0, max: max_total_bytes}

    case walk(root, "", 0, acc) do
      {:ok, acc} -> {:ok, Enum.reverse(acc.files), Enum.reverse(acc.links)}
      {:error, _reason} = error -> error
    end
  end

  defp walk(_root, rel_dir, depth, _acc) when depth > @max_depth,
    do: {:error, {:too_deep, rel_dir}}

  defp walk(root, rel_dir, depth, acc) do
    dir = Path.join(root, rel_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, acc}, &visit(root, join(rel_dir, &1), depth, &2))

      {:error, reason} ->
        {:error, {:file, dir, reason}}
    end
  end

  defp visit(root, rel, depth, {:ok, acc}) do
    if DeviceLocal.excluded?(rel),
      do: {:cont, {:ok, acc}},
      else: halt_on_error(visit_entry(root, rel, depth, acc))
  end

  defp visit_entry(root, rel, depth, acc) do
    path = Path.join(root, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(root, rel, depth + 1, acc)
      {:ok, %File.Stat{type: :regular} = stat} -> add_found(acc, rel, stat)
      {:ok, %File.Stat{type: :symlink}} -> add_link(acc, rel, File.read_link(path))
      {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_entry, rel, type}}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp add_found(acc, rel, stat) do
    with :ok <- name_encodable(rel),
         :ok <- Manifest.check_bounds(acc.count + 1, acc.bytes + stat.size, acc.max) do
      {:ok,
       %{
         acc
         | files: [{rel, stat} | acc.files],
           count: acc.count + 1,
           bytes: acc.bytes + stat.size
       }}
    end
  end

  defp add_link(acc, rel, {:ok, target}) do
    with :ok <- link_inside(rel, target),
         :ok <- Manifest.check_bounds(acc.count + 1, acc.bytes, acc.max) do
      {:ok, %{acc | links: [%{path: rel, target: target} | acc.links], count: acc.count + 1}}
    end
  end

  defp add_link(_acc, rel, {:error, reason}), do: {:error, {:file, rel, reason}}

  defp link_inside(rel, target) do
    if Manifest.safe_link?(rel, target),
      do: :ok,
      else: {:error, {:unsupported_link, rel, target}}
  end

  defp name_encodable(rel) do
    if Manifest.safe_path?(rel), do: :ok, else: {:error, {:unsupported_name, rel}}
  end

  defp halt_on_error({:ok, _acc} = ok), do: {:cont, ok}
  defp halt_on_error({:error, _reason} = error), do: {:halt, error}

  defp join("", name), do: name
  defp join(dir, name), do: dir <> "/" <> name

  defp describe(root, found) do
    Enum.reduce_while(found, {:ok, []}, fn {rel, stat}, {:ok, acc} ->
      case File.read(Path.join(root, rel)) do
        {:ok, content} -> {:cont, {:ok, [entry(rel, content, stat) | acc]}}
        {:error, reason} -> {:halt, {:error, {:file, Path.join(root, rel), reason}}}
      end
    end)
    |> reverse_ok()
  end

  defp entry(rel, content, stat) do
    %{
      path: rel,
      bytes: byte_size(content),
      sha256: sha256(content),
      mode: Bitwise.band(stat.mode, 0o777)
    }
  end

  defp keyring_references(root, entries) do
    case Enum.any?(entries, &(&1.path == @config)) do
      true -> root |> Path.join(@config) |> read_file() |> counted()
      false -> {:ok, 0}
    end
  end

  defp counted({:ok, text}), do: {:ok, ConfigText.keyring_references(text)}
  defp counted({:error, _reason} = error), do: error

  defp reverse_ok({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_ok({:error, _reason} = error), do: error

  defp sha256(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  # The plaintext tar holds every secret in the home, so it is created `0600`
  # before a byte lands and removed on every path once created, success
  # included. A partial file this export did not create is never removed: one
  # an interrupted export left behind is refused by name.
  defp write_archive(root, manifest, passphrase, to) do
    tar_path = partial(to, "tar")

    with :ok <- create_private(tar_path, "") do
      seal_tar(tar_path, root, manifest, passphrase, to)
    end
  end

  defp seal_tar(tar_path, root, manifest, passphrase, to) do
    with :ok <- write_tar(tar_path, root, manifest),
         {:ok, tar} <- read_file(tar_path),
         {:ok, sealed} <- Seal.seal(tar, passphrase),
         :ok <- place(sealed, to) do
      {:ok, IO.iodata_length(sealed)}
    end
  after
    remove_partial(tar_path)
  end

  # Sealed beside the destination and renamed into place, so a reader never
  # sees half an archive under the final name.
  defp place(sealed, to) do
    sealed_path = partial(to, "sealed")

    with :ok <- create_private(sealed_path, sealed) do
      case File.rename(sealed_path, to) do
        :ok -> :ok
        {:error, reason} -> removed(sealed_path, {:error, {:file, to, reason}})
      end
    end
  end

  defp partial(to, kind), do: "#{to}.#{kind}.partial"

  defp create_private(path, iodata) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = close_after(io, path, chmod_then_write(io, path, @archive_mode, iodata))
        if result == :ok, do: :ok, else: removed(path, result)

      {:error, :eexist} ->
        {:error, {:stale_partial, path}}

      {:error, reason} ->
        {:error, {:file, path, reason}}
    end
  end

  defp removed(path, result) do
    remove_partial(path)
    result
  end

  defp chmod_then_write(io, path, mode, iodata) do
    with :ok <- File.chmod(path, mode), do: IO.binwrite(io, iodata)
  end

  defp close_after(io, path, result) do
    case {result, File.close(io)} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _closed} -> {:error, {:file, path, reason}}
      {:ok, {:error, reason}} -> {:error, {:file, path, reason}}
    end
  end

  defp write_tar(tar_path, root, manifest) do
    case :erl_tar.open(String.to_charlist(tar_path), [:write]) do
      {:ok, tar} -> close_tar(tar, tar_path, add_entries(tar, root, manifest))
      {:error, reason} -> {:error, {:tar, tar_path, reason}}
    end
  end

  defp close_tar(tar, tar_path, added) do
    case {added, :erl_tar.close(tar)} do
      {:ok, :ok} -> :ok
      {{:error, _reason} = error, _closed} -> error
      {:ok, {:error, reason}} -> {:error, {:tar, tar_path, reason}}
    end
  end

  defp add_entries(tar, root, manifest) do
    with :ok <- tar_add(tar, Manifest.encode(manifest), @manifest_entry) do
      Enum.reduce_while(manifest.files, :ok, fn entry, :ok ->
        tar |> add_file(root, entry) |> continue_on_ok()
      end)
    end
  end

  defp continue_on_ok(:ok), do: {:cont, :ok}
  defp continue_on_ok({:error, _reason} = error), do: {:halt, error}

  # Read again rather than streamed from disk by the tar writer, so a file that
  # changed since it was hashed is refused here instead of at restore.
  defp add_file(tar, root, entry) do
    path = Path.join(root, entry.path)

    with {:ok, content} <- read_file(path),
         :ok <- unchanged(content, entry) do
      tar_add(tar, content, @home_prefix <> entry.path)
    end
  end

  defp unchanged(content, entry) do
    if sha256(content) == entry.sha256,
      do: :ok,
      else: {:error, {:changed_during_export, entry.path}}
  end

  defp tar_add(tar, content, name) do
    case :erl_tar.add(tar, content, String.to_charlist(name), []) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, name, reason}}
    end
  end

  defp remove_partial(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("home archive: could not remove #{path}: #{inspect(reason)}")
    end
  end

  # -- restore ----------------------------------------------------------------

  @doc """
  Whether `root` can receive a restore: `:absent`, `:empty`, or refused as
  `:root_not_empty` or `{:root_not_directory, root}`.
  """
  @spec root_state(Path.t()) :: {:ok, :absent | :empty} | {:error, term()}
  def root_state(root) when is_binary(root) do
    case File.stat(root) do
      {:error, :enoent} -> {:ok, :absent}
      {:ok, %File.Stat{type: :directory}} -> empty_root(root)
      {:ok, %File.Stat{}} -> {:error, {:root_not_directory, root}}
      {:error, reason} -> {:error, {:file, root, reason}}
    end
  end

  defp empty_root(root) do
    case File.ls(root) do
      {:ok, []} -> {:ok, :empty}
      {:ok, _names} -> {:error, :root_not_empty}
      {:error, reason} -> {:error, {:file, root, reason}}
    end
  end

  defp read_archive(path) do
    max = Seal.max_sealed_bytes()

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max -> read_file(path)
      {:ok, %File.Stat{type: :regular, size: size}} -> {:error, {:archive_too_large, size, max}}
      {:ok, %File.Stat{type: type}} -> {:error, {:file, path, {:not_a_file, type}}}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp unpack(tar) do
    with {:ok, entries} <- extract(tar),
         {:ok, json, rest} <- manifest_first(entries),
         {:ok, manifest} <- Manifest.decode(json),
         {:ok, contents} <- match_entries(manifest.files, rest) do
      {:ok, manifest, contents}
    end
  end

  defp extract(tar) do
    case :erl_tar.extract({:binary, tar}, [:memory]) do
      {:ok, entries} ->
        {:ok, Enum.map(entries, fn {name, bin} -> {List.to_string(name), bin} end)}

      {:error, reason} ->
        {:error, {:invalid_tar, reason}}
    end
  end

  defp manifest_first([{@manifest_entry, json} | rest]), do: {:ok, json, rest}
  defp manifest_first(_entries), do: {:error, {:invalid_manifest, :not_first}}

  defp match_entries(files, rest) do
    listed = MapSet.new(files, &(@home_prefix <> &1.path))
    contents = Map.new(rest)

    with :ok <- no_duplicates(rest, contents),
         :ok <- all_listed(rest, listed) do
      verify_all(files, contents)
    end
  end

  defp no_duplicates(rest, contents) do
    if map_size(contents) == length(rest),
      do: :ok,
      else: {:error, {:invalid_tar, :duplicate_entry}}
  end

  defp all_listed(rest, listed) do
    case Enum.find(rest, fn {name, _bin} -> not MapSet.member?(listed, name) end) do
      nil -> :ok
      {name, _bin} -> {:error, {:unlisted_entry, name}}
    end
  end

  defp verify_all(files, contents) do
    Enum.reduce_while(files, {:ok, %{}}, fn entry, {:ok, acc} ->
      case verify(entry, Map.fetch(contents, @home_prefix <> entry.path)) do
        {:ok, content} -> {:cont, {:ok, Map.put(acc, entry.path, content)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify(entry, {:ok, content}) do
    if byte_size(content) == entry.bytes and sha256(content) == entry.sha256,
      do: {:ok, content},
      else: {:error, {:corrupt_entry, entry.path}}
  end

  defp verify(entry, :error), do: {:error, {:missing_entry, entry.path}}

  # Only `config.toml` is changed; the source was verified against the bytes
  # as they were, before this.
  defp settle_config(source, manifest, root, host, opts) do
    facts = %{
      old_root: manifest.home_root,
      new_root: root,
      macos?: String.starts_with?(host, "macos-"),
      keyring_usable?: Keyword.get(opts, :keyring_usable?, &keyring_usable?/0)
    }

    case source_read(source, manifest, @config) do
      {:ok, text} -> settled(source, RestoredConfig.settle(text, facts))
      :absent -> {:ok, source, RestoredConfig.none()}
      {:error, _reason} = error -> error
    end
  end

  defp settled(source, {:ok, text, settled}) do
    with {:ok, source} <- source_put(source, @config, text), do: {:ok, source, settled}
  end

  defp settled(_source, {:error, _reason} = error), do: error

  # A listed file's bytes from either source, `:absent` when the manifest does
  # not list it.
  defp source_read({:memory, contents}, _manifest, path) do
    case Map.fetch(contents, path) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :absent
    end
  end

  defp source_read({:staged, dir}, manifest, path) do
    if Enum.any?(manifest.files, &(&1.path == path)),
      do: read_file(Path.join(dir, path)),
      else: :absent
  end

  # The settled `config.toml` replaces the verified one in the source; a
  # staged file is rewritten in place, inside the private staging directory.
  defp source_put({:memory, contents}, path, bytes),
    do: {:ok, {:memory, Map.put(contents, path, bytes)}}

  defp source_put({:staged, dir} = source, path, bytes) do
    staged = Path.join(dir, path)

    case File.write(staged, bytes) do
      :ok -> {:ok, source}
      {:error, reason} -> {:error, {:file, staged, reason}}
    end
  end

  defp keyring_usable?, do: SecretWriter.usable?(SecretWriter.probe(store: :keyring))

  # A plugin installed on another OS or architecture carries a build for that
  # one; the restore names them and installs nothing.
  defp plugins_to_reinstall(_source, %{host: host}, host), do: {:ok, []}

  defp plugins_to_reinstall(source, manifest, _host) do
    case source_read(source, manifest, @plugin_lockfile) do
      :absent -> {:ok, []}
      {:ok, json} -> installed_names(Jason.decode(json))
      {:error, _reason} = error -> error
    end
  end

  defp installed_names({:ok, %{} = installed}), do: {:ok, installed |> Map.keys() |> Enum.sort()}
  defp installed_names(other), do: {:error, {:plugin_lockfile, other}}

  # A home a newer engine wrote may carry settings and data this engine does
  # not know, so it is refused by name rather than run half-understood; an
  # engine version that does not parse is refused the same way.
  defp not_newer(version) do
    ours = BuildInfo.product_version()

    case Version.parse(version) do
      {:ok, theirs} ->
        if Version.compare(theirs, Version.parse!(ours)) == :gt,
          do: {:error, {:newer_engine, version, ours}},
          else: :ok

      :error ->
        {:error, {:newer_engine, version, ours}}
    end
  end

  defp next_epoch(epoch) do
    if epoch + 1 <= Epoch.max_epoch(), do: {:ok, epoch + 1}, else: {:error, :epoch_overflow}
  end

  defp write_home(root, root_state, manifest, source, epoch, now_ms) do
    with :ok <- prepare_root(root, root_state) do
      case write_entries(root, manifest, source) do
        {:ok, written} -> finish_home(root, root_state, manifest, written, epoch, now_ms)
        {:error, reason, touched} -> roll_back(root, root_state, touched, reason)
      end
    end
  end

  # SQLite may leave its own sidecars beside the database it just changed, so a
  # roll-back after the clear removes those too.
  defp finish_home(root, root_state, manifest, written, epoch, now_ms) do
    touched = @database_sidecars ++ written

    with {:ok, removed} <- clear_screen_history(root, root_state, manifest, touched, now_ms),
         :ok <- write_epoch(root, root_state, touched, epoch) do
      {:ok, removed}
    end
  end

  defp clear_screen_history(root, root_state, manifest, touched, now_ms) do
    if Enum.any?(manifest.files, &(&1.path == @database)) do
      case ScreenHistory.clear(Path.join(root, @database), now_ms) do
        {:ok, removed} -> {:ok, removed}
        {:error, reason} -> roll_back(root, root_state, touched, reason)
      end
    else
      {:ok, 0}
    end
  end

  defp prepare_root(root, :absent) do
    with :ok <- file_op(File.mkdir(root), root), do: file_op(File.chmod(root, @dir_mode), root)
  end

  defp prepare_root(root, :empty), do: file_op(File.chmod(root, @dir_mode), root)

  # Files first, then links: the manifest puts nothing beneath a link, so no
  # file is ever written through one.
  defp write_entries(root, manifest, source) do
    files = Enum.map(manifest.files, &{&1.path, fn -> write_entry(root, &1, source) end})
    links = Enum.map(manifest.links, &{&1.path, fn -> write_link(root, &1) end})

    Enum.reduce_while(files ++ links, {:ok, []}, fn {path, write}, {:ok, written} ->
      case write.() do
        :ok -> {:cont, {:ok, [path | written]}}
        {:error, reason} -> {:halt, {:error, reason, [path | written]}}
      end
    end)
  end

  defp write_entry(root, entry, source) do
    path = Path.join(root, entry.path)

    with :ok <- ensure_parents(root, Path.dirname(entry.path)) do
      place(source, entry, path)
    end
  end

  defp place({:memory, contents}, entry, path) do
    content = Map.fetch!(contents, entry.path)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} -> close_after(io, path, chmod_then_write(io, path, entry.mode, content))
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  # A staged file is given its mode and moved into place, never copied and
  # never over another file.
  defp place({:staged, dir}, entry, path) do
    staged = Path.join(dir, entry.path)

    with :ok <- nothing_at(path),
         :ok <- file_op(File.chmod(staged, entry.mode), staged) do
      file_op(File.rename(staged, path), path)
    end
  end

  defp nothing_at(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:file, path, :eexist}}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp write_link(root, link) do
    path = Path.join(root, link.path)

    with :ok <- ensure_parents(root, Path.dirname(link.path)) do
      file_op(File.ln_s(link.target, path), path)
    end
  end

  # Every directory under the root is created here, so each is made `0700`:
  # the archive records file modes only, and `mobile/` must be `0700` for the
  # phone channel's trust store to read it.
  defp ensure_parents(_root, "."), do: :ok

  defp ensure_parents(root, rel_dir) do
    rel_dir
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn rel, :ok ->
      case make_dir(Path.join(root, rel)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp make_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp write_epoch(root, root_state, written, epoch) do
    case Epoch.write(root, epoch) do
      :ok -> :ok
      {:error, reason} -> roll_back(root, root_state, [epoch_tmp(root) | written], reason)
    end
  end

  # `Epoch.write/2` renames a sibling temp file into place; one a failed write
  # left behind is this restore's to remove.
  defp epoch_tmp(root), do: Path.relative_to(Epoch.path(root), root) <> ".tmp"

  # Removes exactly what this restore wrote: the files, then the directories
  # above them deepest first, then the root when this restore created it. A
  # removal that fails is logged by path; the restore's own error is returned.
  defp roll_back(root, root_state, touched, reason) do
    Enum.each(touched, &remove(:file, Path.join(root, &1)))

    touched
    |> Enum.flat_map(&parent_dirs/1)
    |> Enum.uniq()
    |> Enum.sort_by(&length(Path.split(&1)), :desc)
    |> Enum.each(&remove(:dir, Path.join(root, &1)))

    if root_state == :absent, do: remove(:dir, root)
    {:error, reason}
  end

  defp parent_dirs(rel) do
    case Path.dirname(rel) do
      "." -> []
      dir -> dir |> Path.split() |> Enum.scan(&Path.join(&2, &1))
    end
  end

  defp remove(kind, path) do
    case remove_op(kind, path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("home restore: could not remove #{path}: #{inspect(reason)}")
    end
  end

  defp remove_op(:file, path), do: File.rm(path)
  defp remove_op(:dir, path), do: File.rmdir(path)

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
