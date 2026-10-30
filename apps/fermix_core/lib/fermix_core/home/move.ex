defmodule FermixCore.Home.Move do
  @moduledoc """
  The source side of a move (M75 §7.2): `<home>/.move/`, device-local, `0700`.

  `start/5` (`home.move.start`, `fermix home move`) writes the request and
  hands the home to the device role:

    * `.move/request.json` (`0600`): the move id (ordered by when the move
      started), the candidate's record as the
      primary held it (`FermixCore.Home.Candidates`), and the recovery
      recipient derived from the owner's passphrase (`Snapshot.Recipient`);
      the passphrase itself is never stored or logged;
    * `.move/phase.json` (`0600`): where the move stands;
    * `[fermix_core.engine] role = "device"` in `config.toml`.

  The engine then restarts in the device role and the move worker
  (`FermixChannels.Home.MoveWorker`) carries the move out, recording each
  phase here so a restart resumes where it stopped:

    * `requested`: written by `start/4`;
    * `streaming`: the desktop row exists and a capture is on its way to the
      candidate (attempts are counted, at most #{3});
    * `committing`: `moved.json` and `device/desktop.json` are written and
      `move_commit` sent; from here the move is only ever resumed, never
      aborted;
    * `committed`: the candidate answered `move_done`, and this engine is
      restarting as its desktop;
    * `done`: recorded by the relaunched desktop's boot (`finish_at_boot/2`);
      this home is a linked desktop;
    * `aborting`: before `move_ready`, the move is being undone;
    * `undoing`: it was undone and the engine is restarting as the primary;
    * `aborted`: recorded by the relaunched primary's boot; nothing was
      retired.

  An ending (`done`, `aborted`) is published only by the engine that comes
  back after the restart, never by the one about to stop, so a reader never
  sees an ending from an engine about to vanish, and on a desktop the primary
  is already in `home.status` beside it.

  `start/5` refuses while the move's readiness report blocks
  (`FermixCore.Home.MoveReadiness`): `{:not_ready, sentences}`. The report is
  the one the owner was just shown when the caller passes it (`:readiness`):
  `home.move.readiness` keeps its review in `.move/readiness.json` (`0600`;
  the items' sentences, never a secret's value; `put_review/4`), and
  `home.move.start` takes it when it was ready, for the same candidate, at
  most 15 minutes ago (`review/3`), so the keychain is not read again before
  the move's capture reads it. A start with no such review makes the report
  itself. Writing the request replaces `.move/`, so a review serves one start.

  The worker starts while the phase is pending (`pending?/1`).
  """

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Setup.ConfigStore

  @dir ".move"
  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @max_attempts 3
  @review_s 15 * 60
  @boot_key {__MODULE__, :boot_ending}
  @pending ~w(requested streaming committing aborting)
  @running ~w(streaming committing)
  @phases @pending ++ ~w(committed undoing done aborted)

  @type phase :: String.t()

  @doc "The directory under `home`."
  @spec dir(Path.t()) :: Path.t()
  def dir(home) when is_binary(home) and home != "", do: Path.join(home, @dir)

  @doc "Where the captured snapshot of move `move_id` is written before it streams."
  @spec snapshot_path(Path.t(), String.t()) :: Path.t()
  def snapshot_path(home, move_id), do: Path.join(dir(home), "#{move_id}.fxsnap")

  @doc "The most capture-and-stream attempts one move makes before it aborts."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "Every phase, and the pending ones the worker carries on from."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc """
  Starts a move of the primary `home` to `candidate_id`: refuses a home that
  is not a primary (`{:not_primary, role}`, by `record`), a move already
  pending (`{:move_pending, phase}`), a home with no epoch (`:epoch_absent`),
  a candidate the home does not hold (`{:unknown_candidate, id}`), a
  passphrase under 12 bytes (`:passphrase_too_short`), and a move whose
  readiness report blocks (`{:not_ready, sentences}`). `opts`: `:now`,
  `:keep_as_desktop` (default true: this computer becomes a desktop of the new
  primary; false for a server being replaced, which then serves nothing),
  `:readiness` (the report the owner was just shown, from `review/3`, in
  place of making one), and `FermixCore.Home.MoveReadiness.report/3`'s.
  Writes the request and the role; a failure part-way removes `.move/`.
  """
  @spec start(Path.t(), map(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start(home, record, candidate_id, passphrase, opts \\ [])
      when is_binary(home) and is_map(record) and is_binary(candidate_id) and
             is_binary(passphrase) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    keep_as_desktop = Keyword.get(opts, :keep_as_desktop, true)
    true = is_boolean(keep_as_desktop)

    with :ok <- primary(record),
         :ok <- not_pending(home),
         {:ok, epoch} <- epoch(home),
         {:ok, candidate} <- Candidates.fetch(home, candidate_id, now),
         {:ok, pair} <- Recipient.from_passphrase(passphrase),
         :ok <- ready(home, candidate, opts) do
      recipient = Recipient.public(pair)
      move_id = move_id(now)

      request = %{
        "v" => @version,
        "move_id" => move_id,
        "candidate" => Candidates.encode(candidate),
        "recovery_recipient" => Recipient.encode(recipient),
        "source_epoch" => epoch,
        "requested_at" => iso(now),
        "keep_as_desktop" => keep_as_desktop
      }

      with :ok <- write_request(home, request, now) do
        {:ok,
         %{
           move_id: move_id,
           candidate: candidate,
           recovery_recipient: Recipient.encode(recipient),
           key_id: Base.encode16(Recipient.key_id(recipient.public_key), case: :lower),
           keep_as_desktop: keep_as_desktop
         }}
      end
    end
  end

  @doc "The request `start/5` wrote."
  @spec read_request(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_request(home) do
    file = Path.join(dir(home), "request.json")

    with {:ok, map} <- read_json(file),
         %{"move_id" => id, "candidate" => candidate, "source_epoch" => epoch} <- map,
         true <- is_binary(id) and is_integer(epoch),
         {:ok, record} <- Candidates.decode(candidate) do
      {:ok, Map.put(map, "candidate", record)}
    else
      {:error, {:file, _path, _reason}} = error -> error
      _invalid -> {:error, {:invalid_move_file, file}}
    end
  end

  @doc """
  Whether the move a request describes leaves this computer a desktop of the
  new primary: true unless the request says false (a request written before
  the choice existed keeps the desktop).
  """
  @spec keep_as_desktop?(map()) :: boolean()
  def keep_as_desktop?(%{} = request), do: Map.get(request, "keep_as_desktop") != false

  @doc "The recorded phase: `{:ok, state}`, or `:absent` when no move was ever started."
  @spec read_phase(Path.t()) :: {:ok, map()} | :absent | {:error, term()}
  def read_phase(home) do
    file = Path.join(dir(home), "phase.json")

    case read_json(file) do
      {:ok, %{"phase" => phase} = state} when phase in @phases -> {:ok, state}
      {:ok, _other} -> {:error, {:invalid_move_file, file}}
      {:error, {:file, _path, :enoent}} -> :absent
      {:error, _reason} = error -> error
    end
  end

  @doc "Records `phase` and `fields` (merged over what was recorded), with `updated_at`."
  @spec put_phase(Path.t(), phase(), map(), DateTime.t()) :: :ok | {:error, term()}
  def put_phase(home, phase, fields, %DateTime{} = now) when phase in @phases do
    previous =
      case read_phase(home) do
        {:ok, state} -> state
        _absent_or_bad -> %{}
      end

    state =
      previous
      |> Map.merge(fields)
      |> Map.merge(%{"v" => @version, "phase" => phase, "updated_at" => iso(now)})

    write_private(Path.join(dir(home), "phase.json"), Jason.encode!(state))
  end

  @doc """
  At a boot, before anything reads the home: the ending the engine before the
  restart left half-said is said. A device boot turns `committed` into `done`;
  a primary boot turns `undoing` (and an `aborting` that a crash cut short
  after the role was written) into `aborted`, keeping the recorded sentence.
  Anything else is left as it is.
  """
  @spec finish_at_boot(Path.t(), :primary | :device) :: :ok | {:error, term()}
  def finish_at_boot(home, role) when is_binary(home) and role in [:primary, :device] do
    case read_phase(home) do
      {:ok, state} -> finish_due(home, state, role)
      :absent -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp finish_due(home, state, role) do
    case ending(state["phase"], role) do
      nil -> :ok
      ending -> finish(home, ending)
    end
  end

  # The ending a boot in `role` says for the phase the engine before its
  # restart left half-said; nil when there is none to say.
  defp ending("committed", :device), do: "done"
  defp ending(phase, :primary) when phase in ~w(undoing aborting), do: "aborted"
  defp ending(_phase, _role), do: nil

  defp finish(home, phase), do: put_phase(home, phase, %{}, DateTime.utc_now())

  @doc """
  At boot, once `finish_at_boot/2` could not write the ending: records that
  this engine's boot left it unrecorded, for `view/3`. Written once, before
  any child starts, like the engine role (`FermixCore.Home.Role`).
  """
  @spec remember_unrecorded_ending() :: :ok
  def remember_unrecorded_ending, do: :persistent_term.put(@boot_key, :unrecorded)

  @doc """
  Whether this engine's boot left a move's ending unrecorded (`:unrecorded`),
  or said it or had none to say (`:recorded`, also in a process that booted
  no engine).
  """
  @spec boot_ending() :: :recorded | :unrecorded
  def boot_ending, do: :persistent_term.get(@boot_key, :recorded)

  @doc """
  The `move` of `home.status` on an engine running in `role`, whose boot
  left a move's ending `boot_ending` (`boot_ending/0`): `view/1`, once the
  ending that boot could not write is written. Only then does a read write:
  each tries the write once more, and while it fails, the phase is the one on
  disk and the sentence says the ending and why it is not recorded yet. An
  engine whose boot left nothing unsaid writes nothing, so the engine about
  to restart after recording `committed` never says `done` itself.
  """
  @spec view(Path.t(), :primary | :device, :recorded | :unrecorded) :: map() | nil
  def view(home, role, :recorded) when is_binary(home) and role in [:primary, :device],
    do: view(home)

  def view(home, role, :unrecorded) when is_binary(home) and role in [:primary, :device] do
    with {:ok, state} <- read_phase(home),
         ending when is_binary(ending) <- ending(state["phase"], role),
         {:error, reason} <- finish(home, ending) do
      unrecorded(state, ending, reason)
    else
      _said_or_nothing_to_say -> view(home)
    end
  end

  defp unrecorded(state, ending, reason) do
    said = state["sentence"] || retired_sentence(state) || sentence(ending, state["candidate"])

    %{
      "phase" => state["phase"],
      "candidate" => state["candidate"],
      "sentence" =>
        "#{said} Fermix could not record that here (#{failure(reason)}); it tries again " <>
          "each time this status is read."
    }
  end

  defp failure({:file, file, posix}) when is_atom(posix),
    do: "#{file}: #{:file.format_error(posix)}"

  defp failure(reason), do: inspect(reason)

  @doc """
  The candidate this home is moving to while a move is under way here, from
  `requested` until the engine that comes back after it says the ending
  (`committed` and `undoing` included): `{:ok, name}`, or `:none`. What a
  device-role engine's chat answers by: the message waits, as it would for an
  unreachable server.
  """
  @spec moving_to(Path.t()) :: {:ok, String.t()} | :none
  def moving_to(home) when is_binary(home) do
    case read_phase(home) do
      {:ok, %{"phase" => phase, "candidate" => name}}
      when phase in @pending or phase in ~w(committed undoing) ->
        {:ok, name}

      _ended_or_none ->
        :none
    end
  end

  @doc "Whether a move is pending under `home`: the worker's start condition."
  @spec pending?(Path.t()) :: boolean()
  def pending?(home) do
    case read_phase(home) do
      {:ok, %{"phase" => phase}} -> phase in @pending
      _absent_or_bad -> false
    end
  end

  @doc "Removes the request (an abort or a finished move keeps only the phase)."
  @spec remove_request(Path.t()) :: :ok | {:error, term()}
  def remove_request(home) do
    file = Path.join(dir(home), "request.json")

    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc """
  Keeps `report`, the review of a move to `candidate_id` the owner was just
  shown (`home.move.readiness`), in `.move/readiness.json` (`0600`): the
  items' statuses and sentences, never a secret's value.
  """
  @spec put_review(Path.t(), String.t(), MoveReadiness.report(), DateTime.t()) ::
          :ok | {:error, term()}
  def put_review(home, candidate_id, report, %DateTime{} = now)
      when is_binary(home) and is_binary(candidate_id) and is_map(report) do
    review = %{
      "v" => @version,
      "candidate_id" => candidate_id,
      "reviewed_at" => iso(now),
      "report" => MoveReadiness.view(report)
    }

    with :ok <- ensure_dir(dir(home)) do
      write_private(review_path(home), Jason.encode!(review))
    end
  end

  @doc """
  The review `put_review/4` kept, as the report `start/5` takes: only one
  for `candidate_id` that was ready and is at most #{div(@review_s, 60)}
  minutes old at `now`; `:none` for anything else. A file Fermix did not
  write is an error.
  """
  @spec review(Path.t(), String.t(), DateTime.t()) ::
          {:ok, MoveReadiness.report()} | :none | {:error, term()}
  def review(home, candidate_id, %DateTime{} = now)
      when is_binary(home) and is_binary(candidate_id) do
    case read_json(review_path(home)) do
      {:ok, review} -> taken_review(review, candidate_id, now, review_path(home))
      {:error, {:file, _path, :enoent}} -> :none
      {:error, _reason} = error -> error
    end
  end

  defp taken_review(
         %{
           "candidate_id" => candidate_id,
           "reviewed_at" => at,
           "report" => %{"ready" => ready, "items" => items}
         },
         candidate_id,
         now,
         file
       )
       when is_binary(at) and is_boolean(ready) and is_list(items) do
    with {:ok, reviewed_at, _offset} <- DateTime.from_iso8601(at),
         {:ok, report} <- MoveReadiness.from_view(%{"ready" => ready, "items" => items}) do
      age = DateTime.diff(now, reviewed_at, :second)
      if ready and age in 0..@review_s, do: {:ok, report}, else: :none
    else
      _invalid -> {:error, {:invalid_move_file, file}}
    end
  end

  defp taken_review(%{"candidate_id" => other}, _candidate_id, _now, _file)
       when is_binary(other),
       do: :none

  defp taken_review(_other, _candidate_id, _now, file), do: {:error, {:invalid_move_file, file}}

  defp review_path(home), do: Path.join(dir(home), "readiness.json")

  @doc """
  The `move` of `home.status`: the phase, the candidate's name and a
  sentence, or nil when this home never started a move.
  """
  @spec view(Path.t()) :: map() | nil
  def view(home) do
    case read_phase(home) do
      {:ok, state} ->
        %{
          "phase" => state["phase"],
          "candidate" => state["candidate"],
          "sentence" =>
            state["sentence"] || retired_sentence(state) ||
              sentence(state["phase"], state["candidate"])
        }

      _absent_or_bad ->
        nil
    end
  end

  # A source that was not kept as a desktop (a server replaced by another) ends
  # serving nothing.
  defp retired_sentence(%{"keep_as_desktop" => false, "phase" => phase, "candidate" => to})
       when phase in ["committed", "done"],
       do: "This home moved to #{to}; this computer no longer runs it."

  defp retired_sentence(_state), do: nil

  @doc "The sentence a phase is shown with when nothing more particular was recorded."
  @spec sentence(phase(), String.t() | nil) :: String.t()
  def sentence("requested", to), do: "The move to #{to} starts when Fermix restarts."
  def sentence("streaming", to), do: "This home is being sent to #{to}."
  def sentence("committing", to), do: "This home is retired; #{to} is taking over as the primary."

  def sentence("committed", to),
    do: "This home moved to #{to}; Fermix is restarting as a desktop of it."

  def sentence("done", to), do: "This home moved to #{to}; this computer is now a desktop of it."
  def sentence("aborting", to), do: "The move to #{to} is being undone."

  def sentence("undoing", to),
    do: "The move to #{to} was undone; Fermix is restarting as the primary."

  def sentence("aborted", to), do: "The move to #{to} was undone; this home is still the primary."

  @doc "The sentence for a refusal of `start/5`."
  @spec error_sentence(term()) :: String.t()
  def error_sentence({:not_primary, role}),
    do: "Only the primary can move its home, and this engine runs in the #{role} role."

  def error_sentence({:move_pending, phase}),
    do: "A move is already under way (#{phase})."

  def error_sentence(:epoch_absent),
    do: "This home has never started as the primary, so there is nothing to move yet."

  def error_sentence({:unknown_candidate, id}),
    do:
      "No server waiting for the move has the id #{id}. A server waits 24 hours after it " <>
        "enrolls; after that, get a new code and enroll it again."

  def error_sentence(:passphrase_too_short),
    do: "The recovery passphrase must be at least 12 bytes long."

  def error_sentence({:not_ready, sentences}) when is_list(sentences),
    do: "The move cannot start yet. " <> Enum.join(sentences, " ")

  def error_sentence({:file, file, reason}), do: "#{file}: #{:file.format_error(reason)}."
  def error_sentence(other), do: "The move could not start: #{inspect(other)}."

  # -- start ------------------------------------------------------------------

  # Ordered by when the move started (12 hex digits of Unix milliseconds,
  # then 8 random ones), so a candidate can tell a later move from an earlier
  # one's late offer (`FermixChannels.Home.Candidate`).
  defp move_id(%DateTime{} = now) do
    millis = now |> DateTime.to_unix(:millisecond) |> Integer.to_string(16) |> String.downcase()

    "mv-" <>
      String.pad_leading(millis, 12, "0") <>
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # The review the owner was just shown is the gate as it was shown, so the
  # keychain is not read again before the capture reads it.
  defp ready(home, candidate, opts) do
    report =
      Keyword.get_lazy(opts, :readiness, fn -> MoveReadiness.report(home, candidate, opts) end)

    case MoveReadiness.blocks(report) do
      [] -> :ok
      sentences -> {:error, {:not_ready, sentences}}
    end
  end

  defp primary(%{role: :primary}), do: :ok
  defp primary(%{role: role}), do: {:error, {:not_primary, role}}

  # Only a device runs a move (`streaming`, `committing`), and `start/5` runs
  # on the primary: a `requested` or `aborting` phase found here is one whose
  # hand-off to the device role never happened or whose undoing already put
  # the primary back, and a new request replaces it.
  defp not_pending(home) do
    case read_phase(home) do
      {:ok, %{"phase" => phase}} when phase in @running -> {:error, {:move_pending, phase}}
      _absent_stale_or_ended -> :ok
    end
  end

  defp epoch(home) do
    case Epoch.read(home) do
      {:ok, epoch} -> not_moved(home, epoch)
      :absent -> {:error, :epoch_absent}
      {:error, _reason} = error -> error
    end
  end

  defp not_moved(home, epoch) do
    case Moved.read(home) do
      :absent -> {:ok, epoch}
      {:ok, _marker} -> {:error, {:not_primary, :device}}
      {:error, _reason} = error -> error
    end
  end

  # The request and the phase, then the role. A failure removes `.move/`, so
  # nothing is left that would start a worker.
  defp write_request(home, request, now) do
    result =
      with :ok <- remove_tree(dir(home)),
           :ok <- mkdir(dir(home)),
           :ok <- write_private(Path.join(dir(home), "request.json"), Jason.encode!(request)),
           :ok <-
             put_phase(
               home,
               "requested",
               %{
                 "move_id" => request["move_id"],
                 "candidate" => request["candidate"]["name"],
                 "keep_as_desktop" => request["keep_as_desktop"]
               },
               now
             ) do
        ConfigStore.put_engine_role(home, :device)
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ = remove_tree(dir(home))
        error
    end
  end

  # -- files ------------------------------------------------------------------

  defp mkdir(dir) do
    with :ok <- file_op(File.mkdir(dir), dir), do: file_op(File.chmod(dir, @dir_mode), dir)
  end

  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp remove_tree(dir) do
    case File.rm_rf(dir) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {:file, path, reason}}
    end
  end

  defp write_private(file, contents) do
    tmp = file <> ".tmp"

    with :ok <- file_op(File.write(tmp, contents), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp),
         :ok <- file_op(File.rename(tmp, file), file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp read_json(file) do
    with {:ok, contents} <- read_file(file) do
      case Jason.decode(contents) do
        {:ok, %{} = map} -> {:ok, map}
        _other -> {:error, {:invalid_move_file, file}}
      end
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
