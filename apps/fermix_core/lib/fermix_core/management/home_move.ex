defmodule FermixCore.Management.HomeMove do
  @moduledoc """
  Enrollment and the move in the `home.*` family (M75 §7, §14):
  `home.enroll.open`, `home.candidates.list`, `home.move.readiness`,
  `home.move.start`, and the `enrollment`, `candidates` and `move` places of
  `home.status`.

  - `home.enroll.open` (primary only) opens the one enrollment window, of
    thirty minutes, replacing an open one, through the rail
    (`FermixCore.Home.Link.impl().open_enrollment/1`), and answers the code
    and when it expires. A window a desktop asks for over the link is that
    desktop's move back (Always On's Move back), and the window names it
    (its device id), as does the candidate that enrolls through it. The code
    is answered once and never logged or kept in a status.
  - `home.enroll.open {purpose: "computer"}` (primary only, M97 §3.1) opens
    the window for a computer that joins the home instead (Add a computer):
    `Home.Link.impl().open_join/0`. A window of the other purpose that is
    open is not replaced: the code is refused by name.
  - `home.enroll.approve {sas}` and `home.enroll.deny` (primary only) are
    the owner's answer to the computer that waits on that window
    (`approve_join/1`, `deny_join/0`): approved with the six digits it
    shows, its row is written; digits that are not its own deny it, and the
    code is spent either way.
  - `home.enroll.withdraw` (primary only) releases the window
    (`FermixCore.Home.Link.impl().withdraw_enrollment/0`): the copied code a
    desktop opened to move back, when its owner cancels.
  - `home.candidates.list` answers the candidates the primary holds
    (`FermixCore.Home.Candidates`), never their keys.
  - `home.move.readiness {candidate_id}` (primary only) answers what the owner
    reviews before the move (`FermixCore.Home.MoveReadiness`): `ready`, and
    each item `ok`, `warn` or `block` with its sentence. The review is kept
    (`Move.put_review/4`) for the start that follows it.
  - `home.move.start {candidate_id, recovery_passphrase}` (primary only)
    first checks the recovery passphrase against the key this primary keeps,
    or sets it when none is kept (`FermixCore.Home.Snapshot.Recovery.verify_or_set/2`):
    one that is not the one set is refused on `recovery_passphrase`, and the
    move carries the kept key, never a second one. A start refused after
    that keeps the passphrase it set. It then writes the move's request
    (`FermixCore.Home.Move.start/5`), refused while
    the readiness report blocks: the ready review the owner was just shown
    (`Move.review/3`), so the keychain is not read again, else a report made
    now. That hands the home to the device role, removes the record of a
    move back that ended here (`FermixCore.Home.Return`), and then restarts
    the engine through its deliberate self-restart
    (`Management.Lifecycle.restart_self/0`), which the service manager brings
    back (launchd's `KeepAlive` for the Mac app's
    agent, systemd's `Restart=always` for the Linux service). The passphrase
    lives only inside that check: it is never stored, logged or answered.
  - In `home.status`: `enrollment` is the window (`state` `open`, `used` or
    `expired`, `expires_at`, and the `candidate_id` that enrolled through
    it, null until one did; a computer's window also says `purpose`
    `computer`, its `state` may be `awaiting_approval`, `approved` or
    `denied`, and it names the `joiner` that waits, `{name, platform}`, or
    null (never its digits, which the owner reads on the new computer and
    types), and the computer that joined through it, `joined {device_id,
    name}`, or null) or null; `candidates` the held candidates on
    a primary, empty elsewhere; `move` the move's `phase`, `candidate` (its
    name, null on the candidate itself) and `sentence`, or null.

  Test seams in `opts`: those of `Management.Home` (its `:config` and
  `:save_recipient` reach the passphrase check), plus `:now` (a
  `DateTime`), `:open_enrollment` (a 1-arity stand-in for the rail's, given
  the desktop it is opened for, or nil), `:withdraw_enrollment` (a 0-arity
  stand-in for the rail's), `:actor`
  (`{:desktop, device_id}` for a request a desktop forwarded), `:restart` (in
  place of the restart), `:boot_ending` (in place of `Move.boot_ending/0`),
  and the readiness report's `:free_bytes`, `:version`, `:host` and
  `:restarts_itself`.
  """

  alias FermixCore.Computers.Consent
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Link
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Return
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recovery
  alias FermixCore.Management.Home
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @not_primary "Only the primary enrolls candidates and starts a move."
  @sas_sentence "Type the six digits the new computer shows."
  @mismatch_sentence "Those digits are not the ones the new computer showed, so it was not " <>
                       "added. Open a new code to try again."
  @no_joiner_sentence "No computer is waiting to join your Fermix."
  @owner_sentence "Only the owner can set up Always On, move Fermix or set its recovery " <>
                    "passphrase: use the Fermix app, the setup page or your own terminal."

  @doc """
  The sentence `daemon.sock` answers when a process Fermix started (or one it
  cannot place) asks for an Always On step (`home.act`) or to set the
  recovery passphrase: the owner's decisions (M75, Always On setup §6). It
  names every place the owner acts from.
  """
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_sentence

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "The `enrollment`, `candidates` and `move` facts of `home.status`."
  @spec facts(Path.t(), Role.record(), map(), keyword()) :: %{
          enrollment: map() | nil,
          candidates: [map()],
          move: map() | nil
        }
  def facts(home, %{role: role}, link, opts) when is_binary(home) and is_map(link) do
    %{
      enrollment: enrollment_view(Map.get(link, :enrollment)),
      candidates: held(home, role, now(opts)),
      move: move_view(home, role, opts)
    }
  end

  @doc """
  `home.enroll.open`: the enrollment window; `opts[:purpose]` `:computer`
  opens one for a computer that joins the home (`:candidate` unless said).
  """
  @spec enroll_open(keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_open(opts \\ []) when is_list(opts) do
    with :ok <- primary(role(opts)) do
      case opener(Keyword.get(opts, :purpose, :candidate), opts).() do
        {:ok, %{code: code, expires_at: %DateTime{} = at}} ->
          {:ok, %{"code" => code, "expires_at" => DateTime.to_iso8601(at)}}

        {:error, {:unavailable, sentence}} when is_binary(sentence) ->
          {:error, {:unavailable, @capability, sentence}}
      end
    end
  end

  defp opener(:candidate, opts) do
    open =
      Keyword.get(opts, :open_enrollment, fn returning ->
        Link.impl().open_enrollment(returning)
      end)

    fn -> open.(returning(Keyword.get(opts, :actor))) end
  end

  defp opener(:computer, opts),
    do: Keyword.get(opts, :open_join, fn -> Link.impl().open_join() end)

  @doc """
  `home.enroll.approve`: the owner adds the computer waiting on the window,
  with the six digits it shows (`sas`).
  """
  @spec enroll_approve(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_approve(sas, opts \\ []) when is_list(opts) do
    approve = Keyword.get(opts, :approve_join, fn sas -> Link.impl().approve_join(sas) end)

    with {:ok, sas} <- sas_param(sas),
         :ok <- primary(role(opts)) do
      case approve.(sas) do
        {:ok, %{device_id: id, name: name}} ->
          {:ok, %{"device_id" => id, "name" => name}}

        {:error, :sas_mismatch} ->
          {:error, {:invalid_params, "sas", @mismatch_sentence}}

        {:error, :none} ->
          {:error, {:unavailable, @capability, @no_joiner_sentence}}

        {:error, {:unavailable, sentence}} when is_binary(sentence) ->
          {:error, {:unavailable, @capability, sentence}}
      end
    end
  end

  @doc "`home.enroll.deny`: the owner does not add the computer waiting on the window."
  @spec enroll_deny(keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_deny(opts \\ []) when is_list(opts) do
    deny = Keyword.get(opts, :deny_join, fn -> Link.impl().deny_join() end)

    with :ok <- primary(role(opts)) do
      case deny.() do
        :ok -> {:ok, %{"denied" => true}}
        {:error, {:unavailable, sentence}} -> {:error, {:unavailable, @capability, sentence}}
      end
    end
  end

  @doc "The six digits a computer shows, as the owner typed them: spaces dropped."
  @spec sas_param(term()) ::
          {:ok, String.t()} | {:error, {:invalid_params, String.t(), String.t()}}
  def sas_param(sas) when is_binary(sas) and byte_size(sas) <= 32 do
    digits = String.replace(sas, " ", "")

    if Regex.match?(~r/\A[0-9]{6}\z/, digits),
      do: {:ok, digits},
      else: {:error, {:invalid_params, "sas", @sas_sentence}}
  end

  def sas_param(_sas), do: {:error, {:invalid_params, "sas", @sas_sentence}}

  # The copied code a linked desktop asks its server for is the one it takes
  # the home back with: the window names that desktop.
  defp returning({:desktop, device_id}), do: device_id
  defp returning(_actor), do: nil

  @doc "`home.enroll.withdraw`: releases the enrollment window."
  @spec enroll_withdraw(keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_withdraw(opts \\ []) when is_list(opts) do
    withdraw =
      Keyword.get(opts, :withdraw_enrollment, fn -> Link.impl().withdraw_enrollment() end)

    with :ok <- primary(role(opts)) do
      case withdraw.() do
        :ok ->
          {:ok, %{"withdrawn" => true}}

        {:error, {:unavailable, sentence}} when is_binary(sentence) ->
          {:error, {:unavailable, @capability, sentence}}
      end
    end
  end

  @doc "`home.candidates.list`."
  @spec candidates_list(keyword()) :: {:ok, map()} | {:error, term()}
  def candidates_list(opts \\ []) when is_list(opts) do
    case Candidates.list(home(opts), now(opts)) do
      {:ok, records} ->
        {:ok, %{"candidates" => Enum.map(records, &Candidates.view/1)}}

      {:error, reason} ->
        Logger.error("home.candidates.list: the candidates could not be read: #{inspect(reason)}")

        {:error,
         {:unavailable, @capability, "The candidates could not be read. See the daemon log."}}
    end
  end

  @doc "`home.move.readiness`: what blocks or warns before a move to `candidate_id`."
  @spec move_readiness(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def move_readiness(candidate_id, opts \\ []) when is_list(opts) do
    with {:ok, candidate_id} <- candidate_id(candidate_id),
         :ok <- primary(role(opts)),
         {:ok, candidate} <- refused(Candidates.fetch(home(opts), candidate_id, now(opts))) do
      report = MoveReadiness.report(home(opts), candidate, readiness_opts(opts))

      case Move.put_review(home(opts), candidate_id, report, now(opts)) do
        :ok -> {:ok, MoveReadiness.view(report)}
        {:error, reason} -> review_not_kept(reason)
      end
    end
  end

  defp review_not_kept(reason) do
    Logger.error("home.move.readiness: the review could not be kept: #{inspect(reason)}")

    {:error,
     {:unavailable, @capability, "The review of the move could not be kept. See the daemon log."}}
  end

  @doc "`home.move.start`: write the request, then restart in the device role."
  @spec move_start(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def move_start(candidate_id, passphrase, opts \\ []) when is_list(opts) do
    with {:ok, candidate_id} <- candidate_id(candidate_id),
         :ok <- refused(primary_role(role(opts))),
         {:ok, recipient} <- Home.recovery_result(Recovery.verify_or_set(passphrase, opts)),
         {:ok, reviewed} <- refused(reviewed(home(opts), candidate_id, now(opts))),
         {:ok, started} <-
           refused(
             Move.start(
               home(opts),
               role(opts),
               candidate_id,
               recipient,
               [
                 now: now(opts),
                 keep_as_desktop: Keyword.get(opts, :keep_as_desktop, true),
                 keep_offers:
                   Keyword.get_lazy(opts, :keep_offers, fn -> Consent.default_keep(opts) end)
               ] ++ reviewed ++ readiness_opts(opts)
             )
           ) do
      :ok = forget_ended_return(home(opts))
      :ok = Keyword.get(opts, :restart, &Lifecycle.restart_self/0).()
      {:ok, started_view(started)}
    end
  end

  # A move away from this home starts a tenure elsewhere: the record of a
  # move back that ended here (`device/return.json`) describes nothing any
  # more, and read on it would draw the new move's progress, a later move
  # back's screen and its notice from that old one. It goes, which tells the
  # Always On watch; one that cannot go is said in the log, and the move,
  # already written, goes on.
  defp forget_ended_return(home) do
    case Return.remove(home) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("move: the ended move back's record stays: #{inspect(reason)}")
    end
  end

  # The review the owner was just shown, as `Move.start/5`'s option.
  defp reviewed(home, candidate_id, now) do
    case Move.review(home, candidate_id, now) do
      {:ok, report} -> {:ok, [readiness: report]}
      :none -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # The answer of a started move, as `home.move.start` gives it.
  defp started_view(%{candidate: candidate} = started) do
    %{
      "move_id" => started.move_id,
      "candidate" => Candidates.view(candidate),
      "recovery_recipient" => started.recovery_recipient,
      "key_id" => started.key_id,
      "keep_as_desktop" => Map.get(started, :keep_as_desktop, true),
      "sentence" => started_sentence(candidate.name, Map.get(started, :keep_as_desktop, true))
    }
  end

  defp started_sentence(name, true) do
    "Fermix restarts in the device role and moves this home to #{name}; keep the recovery " <>
      "passphrase somewhere safe."
  end

  defp started_sentence(name, false) do
    "Fermix restarts, moves this home to #{name} and then serves nothing here; keep the " <>
      "recovery passphrase somewhere safe."
  end

  @doc "The `move` place of `home.status` on a candidate, from its own state."
  @spec candidate_view(Path.t()) :: map() | nil
  def candidate_view(home) do
    case Candidate.read_state(home) do
      {:ok, state} ->
        %{"phase" => state["phase"], "candidate" => nil, "sentence" => candidate_sentence(state)}

      {:error, reason} ->
        Logger.error("home status: the candidate's state could not be read: #{inspect(reason)}")
        nil
    end
  end

  defp candidate_sentence(%{"sentence" => sentence}) when is_binary(sentence), do: sentence

  defp candidate_sentence(%{"phase" => phase, "primary" => %{"name" => name}} = state) do
    case phase do
      "enrolling" -> "Enrolling with #{name}."
      "enrolled" -> "Enrolled with #{name}; waiting for its move until #{state["listen_until"]}."
      "receiving" -> "Receiving the home from #{name}."
      "staged" -> "The home from #{name} is restored here, waiting for #{name} to commit."
      "activating" -> "Becoming the primary in place of #{name}."
      "expired" -> "No move came from #{name} within 24 hours; enroll again."
      "failed" -> "The enrollment with #{name} failed."
    end
  end

  # -- facts ------------------------------------------------------------------

  defp enrollment_view(nil), do: nil

  # A candidate's window as it always was; a computer's names its purpose,
  # the computer that waits and the one that joined.
  defp enrollment_view(%{state: state, expires_at: %DateTime{} = at} = window)
       when state in [:open, :used, :expired, :awaiting_approval, :approved, :denied] do
    view = %{
      "state" => Atom.to_string(state),
      "expires_at" => DateTime.to_iso8601(at),
      "candidate_id" => window.candidate_id
    }

    case Map.get(window, :purpose, :candidate) do
      :candidate ->
        view

      :computer ->
        Map.merge(view, %{
          "purpose" => "computer",
          "joiner" => joiner_view(Map.get(window, :joiner)),
          "joined" => joined_view(Map.get(window, :joined))
        })
    end
  end

  defp joiner_view(nil), do: nil

  defp joiner_view(%{name: name, platform: platform}),
    do: %{"name" => name, "platform" => platform}

  defp joined_view(nil), do: nil
  defp joined_view(%{device_id: id, name: name}), do: %{"device_id" => id, "name" => name}

  defp held(home, :primary, now) do
    case Candidates.list(home, now) do
      {:ok, records} ->
        Enum.map(records, &Candidates.view/1)

      {:error, reason} ->
        Logger.error("home status: the candidates could not be read: #{inspect(reason)}")
        []
    end
  end

  defp held(_home, _role, _now), do: []

  defp move_view(home, :candidate, _opts), do: candidate_view(home)

  defp move_view(home, role, opts),
    do: Move.view(home, role, Keyword.get_lazy(opts, :boot_ending, &Move.boot_ending/0))

  # -- move.start -------------------------------------------------------------

  defp candidate_id(id) when is_binary(id) and byte_size(id) in 1..128, do: {:ok, id}

  defp candidate_id(_id),
    do: {:error, {:invalid_params, "candidate_id", "Name the candidate by its id."}}

  # Before the passphrase is checked or set: only the primary keeps a
  # recovery key, and `Move.start/5` refuses any other role in these words.
  defp primary_role(%{role: :primary}), do: :ok
  defp primary_role(%{role: role}), do: {:error, {:not_primary, role}}

  defp refused(:ok), do: :ok
  defp refused({:ok, started}), do: {:ok, started}

  defp refused({:error, {:not_ready, _sentences} = reason}),
    do: {:error, {:unavailable, @capability, Move.error_sentence(reason)}}

  defp refused({:error, {:unknown_candidate, _id} = reason}),
    do: {:error, {:invalid_params, "candidate_id", Move.error_sentence(reason)}}

  defp refused({:error, {kind, _detail} = reason}) when kind in [:not_primary, :move_pending],
    do: {:error, {:unavailable, @capability, Move.error_sentence(reason)}}

  defp refused({:error, :epoch_absent}),
    do: {:error, {:unavailable, @capability, Move.error_sentence(:epoch_absent)}}

  defp refused({:error, reason}) do
    Logger.error("home.move.start: the move did not start: #{inspect(reason)}")
    {:error, {:unavailable, @capability, "The move did not start. See the daemon log."}}
  end

  defp primary(%{role: :primary}), do: :ok
  defp primary(_record), do: {:error, {:unavailable, @capability, @not_primary}}

  defp readiness_opts(opts),
    do: Keyword.take(opts, [:free_bytes, :version, :host, :restarts_itself, :meeting_holder])

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
