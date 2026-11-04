defmodule FermixCore.Home.LocalReturn do
  @moduledoc """
  Restore here (Always On's move back design §8): the computer a home left
  takes it back from its own copy of the server's snapshots, when the server
  cannot answer and the owner confirmed they deleted or stopped it.
  `Management.AlwaysOn` runs it as `restore_here`, in a job of its own
  (`home_restore`).

  **The copy** (`choose/2`). A desktop keeps the server's newest snapshots
  under `snapshots/` (`<UTC>-e<epoch>.fxsnap`, written by its snapshot store),
  each encrypted to the owner's recovery key; a snapshot's clear header
  carries the salt and the key's id, so the passphrase alone opens one, and
  no bucket is read. The newest copy whose key id the passphrase derives
  (with that copy's salt) is the one restored; a passphrase that opens none
  is refused as the wrong one before a byte is decrypted, and a copy whose
  header cannot be read is passed over, logged. The derived key lives in the
  caller's memory for the restore's length and is never written.

  **The restore** (`restore/3`), in order: a return's candidate of kind
  `local` beside the moved home (`Candidate.prepare_return/3`, `state.json`
  alone, refused as it refuses), the copy staged as a return's
  (`Candidate.Activation.stage/6`: this computer's device settings, secret
  store and keychain items, and without its own desktop row), the entries
  recorded and the staged home put in place of the retired copy
  (`Activation.activate/2`), then the engine's restart, from which it boots
  as the primary. A copy that does not stage leaves the candidate `failed`
  with its sentence, and no restart; an activation that stops part-way is
  finished by the next start, as any activation is, so the engine restarts.
  It is never resumed by itself: a stop before the activation leaves a
  `local` candidate the device's next start discards, and Restore here is
  offered again.

  Telemetry: the move's own bookends (`Home.MoveTelemetry`, side
  `:candidate`), the move id `local-<unix time>`.

  `opts`: `:now`; `Candidate.prepare_return/3`'s `:role` and
  `:restarts_itself?`; `:restore_opts` (the staging's, `Snapshot.restore/4`'s
  and the return's settling seams); `:secret_names` (a 0-arity reader of the
  settings' secret names); `:restart` (in place of
  `Management.Lifecycle.restart_self/0`).
  """

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.Candidate.Return
  alias FermixCore.Home.MoveTelemetry
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Settings

  require Logger

  @name ~r/\A(\d{8}T\d{6}Z)-e\d{1,12}\.fxsnap\z/
  @failed_sentence "The backup on this computer could not be restored here; Fermix's log " <>
                     "says why."

  @typedoc "A copy chosen to restore, with the key that opens it (never written)."
  @type copy :: %{
          path: Path.t(),
          name: String.t(),
          at: DateTime.t(),
          pair: Recipient.pair()
        }

  @doc """
  The newest copy under `home` that `passphrase` opens (see the moduledoc),
  or why none: `:no_copy`, `:wrong_passphrase`, `:passphrase_too_short` or
  `:passphrase_not_text`.
  """
  @spec choose(Path.t(), term()) ::
          {:ok, copy()}
          | {:error, :no_copy | :wrong_passphrase | :passphrase_too_short | :passphrase_not_text}
  def choose(home, passphrase) when is_binary(home) and home != "" do
    cond do
      not is_binary(passphrase) -> {:error, :passphrase_not_text}
      byte_size(passphrase) < Recipient.min_passphrase_bytes() -> {:error, :passphrase_too_short}
      true -> opened(copies(home), passphrase)
    end
  end

  @doc """
  Restores `copy` (`choose/2`'s, with `:from`, the server's name) into
  `home` and restarts the engine (see the moduledoc). Answers the job's
  result, `{:ok, %{"restored" => true, "epoch" => epoch}}`, or
  `{:error, {:refused, sentence}}`.
  """
  @spec restore(Path.t(), map(), keyword()) ::
          {:ok, map()} | {:error, {:refused, String.t()}}
  def restore(home, %{path: path, pair: %{secret_key: _secret}, from: from} = copy, opts)
      when is_binary(home) and is_binary(path) and is_binary(from) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    move_id = "local-" <> Integer.to_string(DateTime.to_unix(now))
    started = MoveTelemetry.started(:candidate, move_id, nil)
    result = restored(home, copy, move_id, now, opts)
    MoveTelemetry.finished(:candidate, move_id, epoch(result), outcome(result), started)
    answer(result)
  end

  # -- the copy ---------------------------------------------------------------

  defp copies(home) do
    home
    |> Capture.dir()
    |> Path.join("*.fxsnap")
    |> Path.wildcard()
    |> Enum.flat_map(&named/1)
    |> Enum.sort_by(& &1.name, :desc)
  end

  defp named(path) do
    name = Path.basename(path)

    with [_all, stamp] <- Regex.run(@name, name),
         {:ok, at} <- stamp_time(stamp) do
      [%{path: path, name: name, at: at}]
    else
      _not_a_copy -> []
    end
  end

  defp stamp_time(stamp) do
    <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      stamp

    case DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z") do
      {:ok, at, 0} -> {:ok, at}
      {:error, _reason} = error -> error
    end
  end

  # One derivation per salt, newest copy first; at most every copy is read.
  defp opened([], _passphrase), do: {:error, :no_copy}

  defp opened(copies, passphrase) do
    found =
      Enum.reduce_while(copies, %{}, fn copy, derived ->
        case match(copy, passphrase, derived) do
          {:ok, chosen} -> {:halt, {:ok, chosen}}
          {:next, derived} -> {:cont, derived}
        end
      end)

    case found do
      {:ok, chosen} -> {:ok, chosen}
      _derived -> {:error, :wrong_passphrase}
    end
  end

  defp match(copy, passphrase, derived) do
    case Format.peek_header(copy.path) do
      {:ok, %{salt: salt, key_id: key_id}} ->
        pair = Map.get_lazy(derived, salt, fn -> derive(passphrase, salt) end)

        if Recipient.key_id(pair.public_key) == key_id,
          do: {:ok, Map.put(copy, :pair, pair)},
          else: {:next, Map.put(derived, salt, pair)}

      {:error, reason} ->
        Logger.warning("restore here: #{copy.name} is passed over: #{inspect(reason)}")
        {:next, derived}
    end
  end

  defp derive(passphrase, salt) do
    {:ok, pair} = Recipient.derive(passphrase, salt)
    pair
  end

  # -- the restore ------------------------------------------------------------

  defp restored(home, copy, move_id, now, opts) do
    prepare = Keyword.take(opts, [:now, :role, :restarts_itself?])

    case Candidate.prepare_return(home, {:local, copy.from}, prepare) do
      {:ok, state} -> staged(home, copy, state, {move_id, now}, opts)
      {:error, reason} -> {:refused, reason, Candidate.error_sentence(reason)}
    end
  end

  defp staged(home, copy, state, {move_id, now}, opts) do
    facts = %{"destination" => %{}, "recovery_recipient" => nil}
    restore_opts = Keyword.get(opts, :restore_opts, [])

    case Activation.stage(home, copy.path, copy.pair, facts, :return, restore_opts) do
      {:ok, epoch} ->
        activating =
          Map.merge(state, %{
            "phase" => "activating",
            "move" => %{"move_id" => move_id, "epoch" => epoch}
          })

        placed(home, epoch, Candidate.put_state(home, activating, now), opts)

      {:error, reason} ->
        failed(home, state, reason, now, opts)
    end
  end

  defp placed(home, epoch, :ok, opts) do
    with {:ok, _entries} <- Activation.record_entries(home),
         :ok <- Activation.activate(home, :return) do
      restart(opts)
      {:done, epoch}
    else
      {:error, reason} ->
        # The next start finishes it, as it finishes any activation.
        Logger.error("restore here: the copy was not put in place yet: #{inspect(reason)}")
        restart(opts)
        {:unplaced, reason}
    end
  end

  defp placed(_home, _epoch, {:error, reason}, _opts),
    do: {:refused, reason, @failed_sentence}

  defp failed(home, state, reason, now, opts) do
    Logger.error("restore here: the copy could not be restored: #{inspect(reason)}")
    sentence = failed_sentence(reason, opts)
    stopped = Map.merge(state, %{"phase" => "failed", "sentence" => sentence})

    case Candidate.put_state(home, stopped, now) do
      :ok -> :ok
      {:error, why} -> Logger.error("restore here: its failure was not kept: #{inspect(why)}")
    end

    {:refused, reason, sentence}
  end

  # A keychain that refused the secrets is the owner's to unlock, so each is
  # named as its settings row names it.
  defp failed_sentence({:keychain_refused, [_ | _]} = refused, opts) do
    names = Keyword.get(opts, :secret_names, &Settings.secret_names/0)
    Return.error_sentence(refused, names.())
  end

  defp failed_sentence(_reason, _opts), do: @failed_sentence

  defp restart(opts), do: :ok = Keyword.get(opts, :restart, &Lifecycle.restart_self/0).()

  defp epoch({:done, epoch}), do: epoch
  defp epoch(_result), do: nil

  defp outcome({:done, _epoch}), do: :done
  defp outcome({:unplaced, reason}), do: {:failed, reason}
  defp outcome({:refused, reason, _sentence}), do: {:failed, reason}

  defp answer({:done, epoch}), do: {:ok, %{"restored" => true, "epoch" => epoch}}

  defp answer({:unplaced, _reason}),
    do: {:error, {:refused, "Fermix finishes putting its backup in place as it starts again."}}

  defp answer({:refused, _reason, sentence}), do: {:error, {:refused, sentence}}
end
