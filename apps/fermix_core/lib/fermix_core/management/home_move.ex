defmodule FermixCore.Management.HomeMove do
  @moduledoc """
  Enrollment and the move in the `home.*` family (M75 §7, §14):
  `home.enroll.open`, `home.candidates.list`, `home.move.readiness`,
  `home.move.start`, and the `enrollment`, `candidates` and `move` places of
  `home.status`.

  - `home.enroll.open {kind?}` (primary only) opens the one enrollment
    window, a manual one of thirty minutes, replacing an open one, through the
    rail (`FermixCore.Home.Link.impl().open_enrollment/1`), and answers the
    code and when it expires; while a server Fermix created waits on its own
    24-hour window (M75 lean v1 L15), and while it is held as the candidate
    that window enrolled, it is refused with the rail's sentence. With `kind`
    `provisioned` it opens that 24-hour window instead, under the same
    one-window rules, and only for a request a desktop forwarded: the
    desktop replacing this server puts the code inside the new server it
    creates. The code is answered once and never logged or kept in a status.
  - `home.enroll.withdraw` (primary only) releases the 24-hour window when
    the server it was opened for was never created or is being deleted
    (`FermixCore.Home.Link.impl().withdraw_enrollment/1`), so a copied code
    can open again.
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
    now. That hands the home to the device role,
    and then restarts the engine through its deliberate self-restart
    (`Management.Lifecycle.restart_self/0`), which the service manager brings
    back (launchd's `KeepAlive` for the Mac app's
    agent, systemd's `Restart=always` for the Linux service). The passphrase
    lives only inside that check: it is never stored, logged or answered.
  - In `home.status`: `enrollment` is the window (`state` `open`, `used` or
    `expired`, `expires_at`, its `kind`, `manual` or `provisioned`, and the
    `candidate_id` that enrolled through it, null until one did) or null; `candidates` the held candidates on
    a primary, empty elsewhere; `move` the move's `phase`, `candidate` (its
    name, null on the candidate itself) and `sentence`, or null.

  Test seams in `opts`: those of `Management.Home` (its `:config` and
  `:save_recipient` reach the passphrase check), plus `:now` (a
  `DateTime`), `:open_enrollment` (a 1-arity stand-in for the rail's, given
  the kind), `:withdraw_enrollment` (a 1-arity stand-in for the rail's, given
  the kind), `:actor`
  (`{:desktop, device_id}` for a request a desktop forwarded), `:restart` (in
  place of the restart), `:boot_ending` (in place of `Move.boot_ending/0`),
  and the readiness report's `:free_bytes`, `:version`, `:host` and
  `:restarts_itself`.
  """

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Link
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recovery
  alias FermixCore.Management.Home
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @not_primary "Only the primary enrolls candidates and starts a move."
  @provisioned_here "A code that lives 24 hours opens only for a server Fermix creates from " <>
                      "your computer."
  @kind_sentence "A code is `manual`, or `provisioned` for a server Fermix creates."
  @kinds %{"manual" => :manual, "provisioned" => :provisioned}
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

  @doc "`home.enroll.open`, a window of `kind` (`\"manual\"` unless said)."
  @spec enroll_open(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_open(kind, opts \\ []) when is_list(opts) do
    open =
      Keyword.get(opts, :open_enrollment, fn kind -> Link.impl().open_enrollment(kind) end)

    with {:ok, kind} <- window_kind(kind, Keyword.get(opts, :actor)),
         :ok <- primary(role(opts)) do
      case open.(kind) do
        {:ok, %{code: code, expires_at: %DateTime{} = at}} ->
          {:ok, %{"code" => code, "expires_at" => DateTime.to_iso8601(at)}}

        {:error, {:unavailable, sentence}} when is_binary(sentence) ->
          {:error, {:unavailable, @capability, sentence}}
      end
    end
  end

  # The 24-hour code is the one a desktop puts inside the server it creates in
  # place of this one; nobody copies it.
  defp window_kind(nil, _actor), do: {:ok, :manual}
  defp window_kind("provisioned", {:desktop, _device_id}), do: {:ok, :provisioned}

  defp window_kind("provisioned", _actor),
    do: {:error, {:invalid_params, "kind", @provisioned_here}}

  defp window_kind(kind, _actor) do
    case Map.fetch(@kinds, kind) do
      {:ok, :manual} -> {:ok, :manual}
      _unknown -> {:error, {:invalid_params, "kind", @kind_sentence}}
    end
  end

  @doc "`home.enroll.withdraw`: releases the 24-hour window."
  @spec enroll_withdraw(keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_withdraw(opts \\ []) when is_list(opts) do
    withdraw =
      Keyword.get(opts, :withdraw_enrollment, fn kind -> Link.impl().withdraw_enrollment(kind) end)

    with :ok <- primary(role(opts)) do
      case withdraw.(:provisioned) do
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
               [now: now(opts), keep_as_desktop: Keyword.get(opts, :keep_as_desktop, true)] ++
                 reviewed ++ readiness_opts(opts)
             )
           ) do
      :ok = Keyword.get(opts, :restart, &Lifecycle.restart_self/0).()
      {:ok, started_view(started)}
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

  defp enrollment_view(%{state: state, expires_at: %DateTime{} = at, kind: kind} = window)
       when state in [:open, :used, :expired] and kind in [:manual, :provisioned],
       do: %{
         "state" => Atom.to_string(state),
         "expires_at" => DateTime.to_iso8601(at),
         "kind" => Atom.to_string(kind),
         "candidate_id" => window.candidate_id
       }

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
    do: Keyword.take(opts, [:free_bytes, :version, :host, :restarts_itself])

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
