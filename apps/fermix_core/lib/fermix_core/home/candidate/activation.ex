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
  secret the source had.

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
  """

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Status

  @config "config.toml"
  @file_mode 0o600

  @doc """
  Restores the stream at `incoming` into the staging directory with `pair`
  and settles its settings for `home`. `facts`: `"destination"` (the
  candidate's `destination.json`) and `"recovery_recipient"` (or nil).
  `opts` go to `Snapshot.restore/4`. Answers the staged epoch.
  """
  @spec stage(Path.t(), Path.t(), Recipient.pair(), map(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def stage(home, incoming, pair, facts, opts \\ []) when is_map(facts) and is_list(opts) do
    staging = Candidate.staging_path(home)

    with :ok <- remove_tree(staging),
         {:ok, restored} <- Snapshot.restore(incoming, pair, staging, opts),
         :ok <- settle_config(home, staging, facts) do
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

  defp settle_config(home, staging, facts) do
    file = Path.join(staging, @config)

    with {:ok, text} <- read_config(file),
         {:ok, text} <- rebase(text, staging, home),
         {:ok, text, _adopted} <- MoveSecrets.adopt(text, staging) do
      text
      |> ConfigText.put("fermix_core.engine", "role", ~s("primary"))
      |> put_destination(Map.get(facts, "destination", %{}))
      |> put_recipient(Map.get(facts, "recovery_recipient"))
      |> then(&Candidate.write_private(file, &1))
    end
  end

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
