defmodule FermixCore.Management.HomeMove do
  @moduledoc """
  Enrollment and the move in the `home.*` family (M75 §7, §14):
  `home.enroll.open`, `home.candidates.list`, `home.move.readiness`,
  `home.move.start`, and the `enrollment`, `candidates` and `move` places of
  `home.status`.

  - `home.enroll.open` (primary only) opens the one enrollment window, a
    manual one of thirty minutes, replacing an open one, through the rail
    (`FermixCore.Home.Link.impl().open_enrollment/1`), and answers the code
    and when it expires; while a server Fermix created waits on its own
    24-hour window (M75 lean v1 L15), and while it is held as the candidate
    that window enrolled, it is refused with the rail's sentence. The code is answered once and never logged or kept in a
    status.
  - `home.candidates.list` answers the candidates the primary holds
    (`FermixCore.Home.Candidates`), never their keys.
  - `home.move.readiness {candidate_id}` (primary only) answers what the owner
    reviews before the move (`FermixCore.Home.MoveReadiness`): `ready`, and
    each item `ok`, `warn` or `block` with its sentence. The review is kept
    (`Move.put_review/4`) for the start that follows it.
  - `home.move.start {candidate_id, recovery_passphrase}` (primary only)
    writes the move's request (`FermixCore.Home.Move.start/5`), refused while
    the readiness report blocks: the ready review the owner was just shown
    (`Move.review/3`), so the keychain is not read again, else a report made
    now. That hands the home to the device role,
    and then restarts the engine through its deliberate self-restart
    (`Management.Lifecycle.restart_self/0`), which the service manager brings
    back (launchd's `KeepAlive` for the Mac app's
    agent, systemd's `Restart=always` for the Linux service). The passphrase
    derives the recovery recipient and is never stored, logged or answered.
  - In `home.status`: `enrollment` is the window (`state` `open`, `used` or
    `expired`, and `expires_at`) or null; `candidates` the held candidates on
    a primary, empty elsewhere; `move` the move's `phase`, `candidate` (its
    name, null on the candidate itself) and `sentence`, or null.

  Test seams in `opts`: those of `Management.Home`, plus `:now` (a
  `DateTime`), `:open_enrollment` (in place of the rail's), `:restart` (in
  place of the restart), `:boot_ending` (in place of `Move.boot_ending/0`),
  and the readiness report's `:free_bytes`, `:version` and `:host`.
  """

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Link
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Role
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @max_passphrase_bytes 1_024
  @not_primary "Only the primary enrolls candidates and starts a move."
  @owner_sentence "Only the owner can move Fermix or set its recovery passphrase: use the " <>
                    "Fermix app or your own terminal."

  @doc """
  The sentence `daemon.sock` answers when a process Fermix started (or one it
  cannot place) asks to open an enrollment code, start a move or set the
  recovery passphrase: the owner's decisions (M75).
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

  @doc "`home.enroll.open`."
  @spec enroll_open(keyword()) :: {:ok, map()} | {:error, term()}
  def enroll_open(opts \\ []) when is_list(opts) do
    open = Keyword.get(opts, :open_enrollment, fn -> Link.impl().open_enrollment(:manual) end)

    with :ok <- primary(role(opts)) do
      case open.() do
        {:ok, %{code: code, expires_at: %DateTime{} = at}} ->
          {:ok, %{"code" => code, "expires_at" => DateTime.to_iso8601(at)}}

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
         {:ok, passphrase} <- passphrase(passphrase),
         {:ok, reviewed} <- refused(reviewed(home(opts), candidate_id, now(opts))),
         {:ok, started} <-
           refused(
             Move.start(
               home(opts),
               role(opts),
               candidate_id,
               passphrase,
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

  @doc "The answer of a started move, as `home.move.start` and `fermix home move` give it."
  @spec started_view(map()) :: map()
  def started_view(%{candidate: candidate} = started) do
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

  defp enrollment_view(%{state: state, expires_at: %DateTime{} = at})
       when state in [:open, :used, :expired],
       do: %{"state" => Atom.to_string(state), "expires_at" => DateTime.to_iso8601(at)}

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

  defp passphrase(value)
       when is_binary(value) and byte_size(value) >= 12 and
              byte_size(value) <= @max_passphrase_bytes,
       do: {:ok, value}

  defp passphrase(value) when is_binary(value) and byte_size(value) < 12,
    do:
      {:error,
       {:invalid_params, "recovery_passphrase", Move.error_sentence(:passphrase_too_short)}}

  defp passphrase(_value),
    do:
      {:error,
       {:invalid_params, "recovery_passphrase",
        "The recovery passphrase is text of at most #{@max_passphrase_bytes} bytes."}}

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

  defp readiness_opts(opts), do: Keyword.take(opts, [:free_bytes, :version, :host])

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
