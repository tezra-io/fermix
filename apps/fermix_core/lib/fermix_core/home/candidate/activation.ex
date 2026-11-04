defmodule FermixCore.Home.Candidate.Activation do
  @moduledoc """
  How a candidate becomes the primary (M75 §7.2 steps 3 and 5): the move's
  stream is restored into `<home>/candidate/staging` (`stage/5`), and only
  once the source sent `move_commit` is that staged home renamed into place
  (`activate/1`).

  **Staging.** `Snapshot.restore/4` makes the staged home the next primary
  (its epoch is the source's plus one). The restored `config.toml` then gets
  what the new host needs: its paths moved from the staging directory to the
  home itself, `[fermix_core.engine] role = "primary"` (the source wrote
  `device` before it captured), the destination facts in
  `[fermix_core.snapshots]` (the bucket and its region when one was named,
  and the recovery recipient the move carried). On a host that is not a Mac
  the restore itself has already turned iMessage off
  (`FermixCore.Home.Archive.RestoredConfig`), as it does
  for `fermix home import`: a settings file that turns iMessage on refuses to
  load anywhere else, and the new primary must boot. The keychain's secrets
  the source carried in the stream are in the staged file store by then, and
  each `@keyring` reference whose file arrived becomes `@file`
  (`FermixCore.Home.MoveSecrets.adopt/2`), so the new primary resolves every
  secret the source had. The plugins the stream brought from another system
  or architecture (the restore's `plugins_to_reinstall`) are named in the
  staged plugin store (`FermixCore.Plugins.Dist.Reinstall.request/2`), and
  the new primary's first boot installs them again for this computer.

  **Activation** renames each staged entry into the home (an entry of the
  candidate's own engine already there, such as a log, is moved aside into
  `candidate/replaced/` first), `config.toml` last: that rename is the commit
  point, since the next boot reads the role from it. Then `candidate/` is
  removed. Every step is idempotent, so a crash part-way is finished by the
  next boot: before `config.toml` moved it is still a candidate and its
  process runs `activate/1` again (its phase is `activating`); after, the
  primary's boot removes what is left (`finish_activation/1`). Before the
  settings go in, the snapshot status asks the new primary's first boot for a
  snapshot at once (`run_at_boot`), so a verified copy of the moved home
  exists as soon as it can.

  **A return** (Always On's move back, a candidate of kind `return` or
  `local`) stages the server's copy on the computer the home left, beside its
  retired copy, and settles it for that computer again
  (`FermixCore.Home.Candidate.Return`, `stage/6`). Its activation
  (`activate/2`) replaces the retired copy in place while keeping this
  computer's own paths at any depth (`FermixCore.Home.DeviceLocal`'s
  `kept_through_return?/1`), the device engine running and no database open
  (a device opens none). The staged entries are recorded once, before any
  rename (`record_entries/1`), and every step is idempotent over them, in
  this order:

    a. every top-level path of the home that is no recorded entry (nor its
       `-wal` or `-shm`), nor `candidate`, `config.toml` or `moved.json`, is
       pruned in place: a kept path stays where it is, and everything else is
       set aside into `candidate/replaced/` (a path already there is removed
       first), so a file the server no longer has never survives;
    b. for each recorded entry still staged: the kept paths under this
       computer's copy of it move into the staged one, its copy is set aside
       with its `-wal` and `-shm`, and the staged entry is renamed into
       place; a kept path already moved by an earlier run wins over one a
       boot in between made again;
    c. the ended tenure's desktop link and key are removed from `device/`;
    d. the snapshot status asks for a snapshot at the first boot;
    e. the moved marker is removed (`FermixCore.Home.Moved.remove/1`): the
       server carries its own by now, since it sent `move_commit` after
       writing it, and this home's settings still say device;
    f. the staged `config.toml` is renamed into place, the commit point;
    g. `candidate/` is removed.

  A stop before f is finished by the next device boot's candidate running
  `activate/2` again, one after it by the primary's boot
  (`finish_activation/1`).
  """

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Return
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Moved
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Plugins.Dist.Reinstall

  @config "config.toml"
  @file_mode 0o600
  @return_kinds ~w(return local)
  @return_opts [:impl, :supervised, :drop_desktop_row]

  @doc """
  Restores the stream at `incoming` into the staging directory with `pair`
  and settles its settings for `home`. `facts`: `"destination"` (the
  candidate's `destination.json`) and `"recovery_recipient"` (or nil).
  `opts` go to `Snapshot.restore/4`. Answers the staged epoch.
  """
  @spec stage(Path.t(), Path.t(), Recipient.pair(), map(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def stage(home, incoming, pair, facts, opts \\ []) when is_map(facts) and is_list(opts),
    do: stage_as(:move, home, incoming, pair, facts, opts)

  @doc """
  `stage/5` for a return: the server's copy at `incoming` is staged on the
  computer the home left and settled for it again
  (`FermixCore.Home.Candidate.Return.settle/4`, whose seams `opts` also take).
  """
  @spec stage(Path.t(), Path.t(), Recipient.pair(), map(), :return, keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def stage(home, incoming, pair, facts, :return, opts) when is_map(facts) and is_list(opts),
    do: stage_as(:return, home, incoming, pair, facts, opts)

  defp stage_as(mode, home, incoming, pair, facts, opts) do
    staging = Candidate.staging_path(home)
    {settle_opts, restore_opts} = Keyword.split(opts, @return_opts)

    with :ok <- remove_tree(staging),
         {:ok, restored} <- Snapshot.restore(incoming, pair, staging, restore_opts),
         :ok <- settle_config(home, staging, facts, {mode, settle_opts}),
         :ok <- Reinstall.request(Path.join(staging, "plugins"), restored.plugins_to_reinstall) do
      {:ok, restored.epoch}
    else
      {:error, _reason} = error ->
        _ = remove_tree(staging)
        error
    end
  end

  @doc "Renames the staged home into place and removes the candidate's directory."
  @spec activate(Path.t()) :: :ok | {:error, term()}
  def activate(home) when is_binary(home) do
    staging = Candidate.staging_path(home)

    with {:ok, entries} <- staged_entries(staging),
         :ok <- place_all(home, staging, entries),
         :ok <- Status.write(home, %{Status.empty() | run_at_boot: true}),
         :ok <- place_config(home, staging) do
      remove_tree(Candidate.dir(home))
    end
  end

  @doc """
  Records the top-level entries of the staged home a return's activation
  places, once, before any rename: in `candidate/entries.json` (`0600`), which
  nothing rewrites, so a later run never lists a staging some of whose entries
  are in place already. A record that exists is read back. Refused unless the
  candidate is a return's and its staged settings are there.
  """
  @spec record_entries(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def record_entries(home) when is_binary(home) do
    with {:ok, state} <- Candidate.read_state(home),
         :ok <- return_kind(state) do
      case read_entries(home) do
        {:error, :entries_unrecorded} -> write_entries(home)
        read -> read
      end
    end
  end

  defp write_entries(home) do
    staging = Candidate.staging_path(home)

    with :ok <- staged_config(staging),
         {:ok, entries} <- staged_entries(staging),
         :ok <- Candidate.write_private(entries_path(home), Jason.encode!(entries)) do
      {:ok, entries}
    end
  end

  defp read_entries(home) do
    file = entries_path(home)

    case File.read(file) do
      {:ok, contents} -> decode_entries(contents, file)
      {:error, :enoent} -> {:error, :entries_unrecorded}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp decode_entries(contents, file) do
    case Jason.decode(contents) do
      {:ok, entries} when is_list(entries) -> valid_entries(entries, file)
      _other -> {:error, {:invalid_state, file}}
    end
  end

  defp valid_entries(entries, file) do
    if Enum.all?(entries, &plain_name?/1),
      do: {:ok, entries},
      else: {:error, {:invalid_state, file}}
  end

  defp plain_name?(name),
    do: is_binary(name) and name not in ["", ".", "..", @config] and not (name =~ "/")

  defp entries_path(home), do: Candidate.path(home, "entries.json")

  defp return_kind(%{"kind" => kind}) when kind in @return_kinds, do: :ok
  defp return_kind(_state), do: {:error, :not_a_return}

  defp staged_config(staging) do
    if File.regular?(Path.join(staging, @config)), do: :ok, else: {:error, :nothing_staged}
  end

  @doc """
  A return's activation, once its move committed (`state.json` in phase
  `activating`): the steps a to g of the moduledoc, over the entries
  `record_entries/1` recorded (refused as `:entries_unrecorded` without them).
  `opts`: `:after_step`, a 1-arity function called with each step's name once
  it is done (a test seam that stops it part-way).
  """
  @spec activate(Path.t(), :return, keyword()) :: :ok | {:error, term()}
  def activate(home, :return, opts \\ []) when is_binary(home) and is_list(opts) do
    after_step = Keyword.get(opts, :after_step, fn _step -> :ok end)
    staging = Candidate.staging_path(home)

    with :ok <- committed_return(home),
         {:ok, entries} <- read_entries(home),
         :ok <- prune_retired(home, entries, after_step),
         :ok <- place_returned(home, staging, entries, after_step),
         :ok <- step(end_tenure(home), :c, after_step),
         :ok <- step(Status.write(home, %{Status.empty() | run_at_boot: true}), :d, after_step),
         :ok <- step(Moved.remove(home), :e, after_step),
         :ok <- step(place_return_config(home, staging), :f, after_step) do
      remove_tree(Candidate.dir(home))
    end
  end

  defp committed_return(home) do
    with {:ok, state} <- Candidate.read_state(home),
         :ok <- return_kind(state) do
      if state["phase"] == "activating",
        do: :ok,
        else: {:error, {:not_activating, state["phase"]}}
    end
  end

  defp step(:ok, name, after_step), do: done(after_step, name)
  defp step({:error, _reason} = error, _name, _after_step), do: error

  # What the seam answers is not the step's result.
  defp done(after_step, name) do
    _ = after_step.(name)
    :ok
  end

  @doc """
  At a primary's boot: removes a candidate directory an activation left
  behind once its settings were in place. Anything else is left as it is.
  """
  @spec finish_activation(Path.t()) :: :ok | {:error, term()}
  def finish_activation(home) when is_binary(home) do
    staged_config = Path.join(Candidate.staging_path(home), @config)

    case Candidate.read_state(home) do
      {:ok, %{"phase" => "activating"}} -> finish_if_placed(home, File.exists?(staged_config))
      {:ok, _other_phase} -> :ok
      {:error, {:file, _path, :enoent}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp finish_if_placed(home, false), do: remove_tree(Candidate.dir(home))
  defp finish_if_placed(_home, true), do: {:error, :activation_unfinished}

  # -- staging ----------------------------------------------------------------

  defp settle_config(home, staging, facts, mode) do
    file = Path.join(staging, @config)

    with {:ok, text} <- read_config(file),
         {:ok, text} <- rebase(text, staging, home),
         {:ok, text, _adopted} <- MoveSecrets.adopt(text, staging),
         {:ok, text} <- settle_for(mode, moved_settings(text, facts), home, staging) do
      Candidate.write_private(file, text)
    end
  end

  defp moved_settings(text, facts) do
    text
    |> ConfigText.put("fermix_core.engine", "role", ~s("primary"))
    |> put_destination(Map.get(facts, "destination", %{}))
    |> put_recipient(Map.get(facts, "recovery_recipient"))
  end

  defp settle_for({:move, _opts}, text, _home, _staging), do: {:ok, text}

  defp settle_for({:return, opts}, text, home, staging),
    do: Return.settle(text, home, staging, opts)

  defp read_config(file) do
    case File.read(file) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp rebase(text, staging, home) do
    case ConfigText.rebase(text, staging, home) do
      {:ok, text, _keys} -> {:ok, text}
      {:error, reason} -> {:error, {:config_not_rewritable, reason}}
    end
  end

  defp put_destination(text, %{"s3_bucket" => bucket, "s3_region" => region}) do
    text
    |> ConfigText.put("fermix_core.snapshots", "s3_bucket", toml_string(bucket))
    |> ConfigText.put("fermix_core.snapshots", "s3_region", toml_string(region))
  end

  defp put_destination(text, %{}), do: text

  defp put_recipient(text, nil), do: text

  defp put_recipient(text, recipient) when is_binary(recipient),
    do: ConfigText.put(text, "fermix_core.snapshots", "recipient", toml_string(recipient))

  # A JSON string of printable text is a TOML basic string.
  defp toml_string(value) when is_binary(value), do: Jason.encode!(value)

  # -- activation -------------------------------------------------------------

  defp staged_entries(staging) do
    case File.ls(staging) do
      {:ok, entries} -> {:ok, entries |> List.delete(@config) |> Enum.sort()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:file, staging, reason}}
    end
  end

  defp place_all(home, staging, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case place(home, staging, entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp place(home, staging, entry) do
    target = Path.join(home, entry)

    with :ok <- set_aside(home, target, entry) do
      rename(Path.join(staging, entry), target)
    end
  end

  # What the candidate's own engine wrote under the same name (a log, a trace)
  # is kept aside, and goes with the candidate's directory.
  defp set_aside(home, target, entry) do
    case File.lstat(target) do
      {:ok, _stat} ->
        replaced = Candidate.path(home, "replaced")

        with :ok <- mkdir(replaced), do: rename(target, Path.join(replaced, entry))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:file, target, reason}}
    end
  end

  defp place_config(home, staging) do
    staged = Path.join(staging, @config)
    target = Path.join(home, @config)

    with :ok <- rename(staged, target), do: file_op(File.chmod(target, @file_mode), target)
  end

  # -- a return's activation --------------------------------------------------

  # Step a: what is spared here is placed by b (an entry with its database
  # files), kept by the candidate's own steps, or removed by e.
  defp prune_retired(home, entries, after_step) do
    spared =
      ["candidate", @config, "moved.json"] ++
        entries ++ Enum.flat_map(entries, &[&1 <> "-wal", &1 <> "-shm"])

    with {:ok, names} <- list_dir(home) do
      names
      |> Enum.sort()
      |> Enum.reject(&(&1 in spared))
      |> each_ok(&prune(home, &1, after_step))
    end
  end

  # A path the return keeps stays where it is, whole. A directory that may
  # hold a kept path keeps only what is kept beneath it, and goes once nothing
  # is; any other path is set aside, whole.
  defp prune(home, rel, after_step) do
    cond do
      DeviceLocal.kept_through_return?(rel) ->
        {:ok, :kept}

      may_hold_kept?(home, rel) ->
        prune_dir(home, rel, after_step)

      true ->
        with :ok <- set_aside_path(home, rel),
             :ok <- done(after_step, {:a, rel}),
             do: {:ok, :gone}
    end
  end

  defp prune_dir(home, rel, after_step) do
    with {:ok, names} <- list_dir(Path.join(home, rel)),
         {:ok, results} <- map_ok(Enum.sort(names), &prune(home, Path.join(rel, &1), after_step)) do
      if :kept in results, do: {:ok, :kept}, else: remove_empty(Path.join(home, rel))
    end
  end

  # Step b, one recorded entry.
  defp place_returned(home, staging, entries, after_step),
    do: each_ok(entries, &place_returned_entry(home, staging, &1, after_step))

  defp place_returned_entry(home, staging, entry, after_step) do
    staged = Path.join(staging, entry)

    case File.lstat(staged) do
      {:ok, _stat} -> place_staged(home, staging, entry, after_step)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, staged, reason}}
    end
  end

  defp place_staged(home, staging, entry, after_step) do
    with {:ok, units} <- kept_beneath(home, entry),
         :ok <- each_ok(units, &keep_into_staging(home, staging, entry, &1, after_step)),
         :ok <- each_ok([entry, entry <> "-wal", entry <> "-shm"], &set_aside_path(home, &1)),
         :ok <- done(after_step, {:b, entry, :aside}),
         :ok <- rename(Path.join(staging, entry), Path.join(home, entry)) do
      done(after_step, {:b, entry, :placed})
    end
  end

  # The maximal kept paths beneath `rel`, which is not kept itself.
  defp kept_beneath(home, rel) do
    with true <- may_hold_kept?(home, rel),
         {:ok, names} <- list_dir(Path.join(home, rel)) do
      names |> Enum.sort() |> flat_map_ok(&kept_or_beneath(home, Path.join(rel, &1)))
    else
      false -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  defp kept_or_beneath(home, rel) do
    if DeviceLocal.kept_through_return?(rel), do: {:ok, [rel]}, else: kept_beneath(home, rel)
  end

  # The stream never carries a kept path, so one already staged was moved by
  # an earlier run, and the one here was made again by a boot in between.
  defp keep_into_staging(home, staging, entry, unit, after_step) do
    to = Path.join(staging, unit)

    with :ok <- mkdir_p(Path.dirname(to)),
         :ok <- keep_unit(home, unit, to, File.lstat(to)) do
      done(after_step, {:b, entry, {:kept, unit}})
    end
  end

  defp keep_unit(home, unit, to, {:error, :enoent}), do: rename(Path.join(home, unit), to)
  defp keep_unit(home, unit, _to, {:ok, _stat}), do: set_aside_path(home, unit)
  defp keep_unit(_home, _unit, to, {:error, reason}), do: {:error, {:file, to, reason}}

  # Step c: the files of the ended tenure inside a directory a return keeps.
  defp end_tenure(home),
    do: each_ok([DesktopLink.path(home), DesktopLink.key_path(home)], &remove_file/1)

  # Step f: done already when an earlier run renamed it.
  defp place_return_config(home, staging) do
    target = Path.join(home, @config)

    if File.exists?(Path.join(staging, @config)),
      do: place_config(home, staging),
      else: file_op(File.chmod(target, @file_mode), target)
  end

  defp set_aside_path(home, rel) do
    from = Path.join(home, rel)
    to = Path.join(Candidate.path(home, "replaced"), rel)

    case File.lstat(from) do
      {:ok, _stat} ->
        with :ok <- mkdir_p(Path.dirname(to)), :ok <- remove_tree(to), do: rename(from, to)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:file, from, reason}}
    end
  end

  # Only a directory shallower than the deepest kept pattern can hold a kept
  # path below it (`DeviceLocal.return_depth/0`), which bounds every walk.
  defp may_hold_kept?(home, rel),
    do:
      length(Path.split(rel)) < DeviceLocal.return_depth() and
        match?({:ok, %{type: :directory}}, File.lstat(Path.join(home, rel)))

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp remove_empty(dir) do
    case File.rmdir(dir) do
      :ok -> {:ok, :gone}
      {:error, :enoent} -> {:ok, :gone}
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp remove_file(file) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:ok, _result} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp flat_map_ok(items, fun) do
    with {:ok, lists} <- map_ok(items, fun), do: {:ok, Enum.concat(lists)}
  end

  defp mkdir(dir) do
    case File.mkdir(dir) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp rename(from, to), do: file_op(File.rename(from, to), to)

  defp remove_tree(dir) do
    case File.rm_rf(dir) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {:file, path, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
