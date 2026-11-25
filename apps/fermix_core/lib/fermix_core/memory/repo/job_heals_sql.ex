defmodule FermixCore.Memory.Repo.JobHealsSql do
  @moduledoc """
  The store's half of a heal (M106 §5.4): what Fermix keeps about a failure
  it took from a job's run, and the one message that tells the owner.

  `job_heals` holds one heal per subject that is not closed (a job, the
  provider the failure lies with, or the plugin whose tool never worked), and
  `job_heal_runs` the runs it took, which "how often" and "which jobs" are
  counted from. Both are new tables read by column name, never `SELECT *`;
  `job_runs`, `scheduled_jobs` and the facts and retry tables are left as
  they were (`Home.Readable`).

  A heal is opened, joined or closed only inside a run's settle
  (`settle/5`, in `Memory.Repo`'s transaction), so a run's final row and what
  became of its failure land together or not at all. The Scheduler claims a
  heal whose message is due under a lease (`{:claim, now, lease_until}`), and
  every write the heal run makes after it holds that lease
  (`{:error, :lease_lost}` otherwise). The delivery fields are the harness
  ledger's outbox (`delivery_status`, attempts, `next_delivery_at`,
  `last_delivery_error`, `delivered_at`).

  Times are stored fixed-width (`CuesSql.stamp/1`), so a stored time and a
  pass's `now` compare as text.

  A job's heal of a kind a model could help with is diagnosed (M106 §5.5,
  stage S3): its heal run records, under the lease, the `decision` code
  carried out (`rerun`, `raise_limit`, `pause`, `propose`, `tell`, or `none`
  when the run gave none), the run's `note`, whether it `read_outside`
  content, and the exact `change` (`update_job`'s field names, each with its
  `from` and `to`) applied or proposed, with the job's version it was drawn
  for. The heal run's concluding write (`delivered` or `dead_letter`) takes
  the heal where the decision says: `watching` after a rerun or a raised
  limit (the rerun's ask is stamped `rerun_at` in the same write, and what
  came of it, `rerun_outcome`, once the Scheduler answered or did not; a
  refused rerun leaves the heal `waiting`), `waiting` otherwise. A failure
  that joins a `watching` heal concludes it a second time (`conclusion`
  `verdict`, §5.9): the heal is open again with its outbox
  reset, its failure the new one, and its concluding write closes it
  `still_failing`. A heal watching seven days closes `expired`, as a waiting
  one does.

  A run that ended ok without working (M106 §6, stage S5) is taken at its
  settle as a failure that is not retried is: a tool it called never once
  succeeded in it, as in each of the job's two runs before it, read from the
  runs' tool tallies (`Jobs.Degraded`). The heal's kind is
  `tool_never_succeeded`, its words the tool's last error, and its `tool` (a
  column migration 73 adds) the tool's name, its plugin and its failed calls
  in each of the three runs. A plugin's tool makes the plugin the subject, so
  every job one plugin refuses joins one heal. What an ok run proves: any
  closes its provider's heal, since the model worked; one that does not trip
  closes its job's heal, unless that heal is about a tool, which only that
  tool succeeding closes; and any closes a plugin's heal whose own tool
  succeeded in it. A run that never calls the tool proves nothing of such a
  heal, which then ends by the seven-day expiry.

  A stored tally or tool this engine cannot read (`Jobs.Degraded.readable_tally/1`)
  reads as none and is logged by its row's id, never by its content: the
  store, whose process runs the settle, never raises on one.
  """

  require Logger

  alias FermixCore.Jobs.Degraded
  alias FermixCore.Jobs.Failure
  alias FermixCore.Memory.Repo.CuesSql

  # A failure of the same subject and kind as a heal closed still failing,
  # skipped or expired within these days opens no heal: the owner heard of it.
  @quiet_days 7
  @quiet_outcomes ["still_failing", "skipped", "expired"]
  # A heal waiting this long on the owner closes as expired.
  @waiting_days 7
  @expire_limit 50
  @failure_text_max 1_000
  @failure_words_max 500
  @delivery_error_max 500
  @recent_runs 8
  @named_jobs 5

  @note_max 500
  @decisions ~w(rerun raise_limit pause propose tell none)
  # What came of a rerun's "run now" (M106 §5.5, `Jobs.HealRun.rerun_outcome/2`):
  # a run started, one was already running, it was refused (no run will
  # come), or it gave no clear answer (a run may still come).
  @rerun_outcomes ~w(started running refused unanswered)
  # The kind of a heal about one tool that never worked (M106 §6), which only
  # that tool succeeding in an ok run closes.
  @degraded "tool_never_succeeded"

  # The columns 71 made, the ones 72 adds for the diagnosis (M106 §5.5), and
  # the one 73 adds for a run that ended ok without working (§6).
  @columns_71 ~w(id subject_kind subject_id job_id failure_kind failure_text failure_words state
                 outcome run_count last_run_id last_failed_at opened_at updated_at waiting_since
                 closed_at lease_token lease_until message inbox_platform inbox_destination
                 inbox_thread_scope delivery_status delivery_attempts next_delivery_at
                 last_delivery_error delivered_at)
  @diagnosis_columns ~w(conclusion decision note read_outside change_json change_job_version
                        rerun_at rerun_outcome)
  @tool_columns ~w(tool_json)
  @columns @columns_71 ++ @diagnosis_columns ++ @tool_columns
  @fields Enum.map(@columns, &String.to_atom/1)
  @select "SELECT #{Enum.join(@columns, ", ")} FROM job_heals"
  @stamped ~w(last_failed_at opened_at updated_at waiting_since closed_at lease_until
              next_delivery_at delivered_at change_job_version rerun_at)a

  @diagnosis_sql """
  ALTER TABLE job_heals ADD COLUMN conclusion TEXT NOT NULL DEFAULT 'first'
    CHECK (conclusion IN ('first', 'verdict'));
  ALTER TABLE job_heals ADD COLUMN decision TEXT
    CHECK (decision IN ('rerun', 'raise_limit', 'pause', 'propose', 'tell', 'none'));
  ALTER TABLE job_heals ADD COLUMN note TEXT;
  ALTER TABLE job_heals ADD COLUMN read_outside INTEGER CHECK (read_outside IN (0, 1));
  ALTER TABLE job_heals ADD COLUMN change_json TEXT;
  ALTER TABLE job_heals ADD COLUMN change_job_version TEXT;
  ALTER TABLE job_heals ADD COLUMN rerun_at TEXT;
  ALTER TABLE job_heals ADD COLUMN rerun_outcome TEXT
    CHECK (rerun_outcome IN ('started', 'running', 'refused', 'unanswered'));
  CREATE INDEX IF NOT EXISTS job_heals_watching
    ON job_heals(waiting_since) WHERE state = 'watching';
  """

  @schema_sql """
  CREATE TABLE IF NOT EXISTS job_heals (
    id TEXT PRIMARY KEY,
    subject_kind TEXT NOT NULL CHECK (subject_kind IN ('job', 'provider', 'plugin')),
    subject_id TEXT NOT NULL,
    job_id TEXT REFERENCES scheduled_jobs(id) ON DELETE CASCADE,
    failure_kind TEXT NOT NULL,
    failure_text TEXT NOT NULL,
    failure_words TEXT,
    state TEXT NOT NULL
      CHECK (state IN ('open', 'diagnosing', 'waiting', 'watching', 'closed')),
    outcome TEXT
      CHECK (outcome IN ('healed', 'still_failing', 'skipped', 'expired', 'superseded')),
    run_count INTEGER NOT NULL DEFAULT 1,
    last_run_id TEXT,
    last_failed_at TEXT,
    opened_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    waiting_since TEXT,
    closed_at TEXT,
    lease_token TEXT,
    lease_until TEXT,
    message TEXT,
    inbox_platform TEXT,
    inbox_destination TEXT,
    inbox_thread_scope TEXT,
    delivery_status TEXT NOT NULL DEFAULT 'pending'
      CHECK (delivery_status IN ('pending', 'delivered', 'dead_letter')),
    delivery_attempts INTEGER NOT NULL DEFAULT 0,
    next_delivery_at TEXT,
    last_delivery_error TEXT,
    delivered_at TEXT,
    CHECK ((state = 'closed') = (outcome IS NOT NULL)),
    CHECK ((subject_kind = 'job') = (job_id IS NOT NULL AND job_id = subject_id))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS job_heals_one_per_subject
    ON job_heals(subject_kind, subject_id) WHERE state <> 'closed';
  CREATE INDEX IF NOT EXISTS job_heals_claim
    ON job_heals(state, opened_at) WHERE state IN ('open', 'diagnosing');
  CREATE INDEX IF NOT EXISTS job_heals_quiet
    ON job_heals(subject_kind, subject_id, failure_kind, closed_at) WHERE state = 'closed';
  CREATE INDEX IF NOT EXISTS job_heals_waiting
    ON job_heals(waiting_since) WHERE state = 'waiting';
  CREATE TABLE IF NOT EXISTS job_heal_runs (
    run_id TEXT PRIMARY KEY REFERENCES job_runs(id) ON DELETE CASCADE,
    heal_id TEXT NOT NULL REFERENCES job_heals(id) ON DELETE CASCADE,
    job_id TEXT NOT NULL REFERENCES scheduled_jobs(id) ON DELETE CASCADE
  );
  CREATE INDEX IF NOT EXISTS job_heal_runs_heal ON job_heal_runs(heal_id, job_id);
  CREATE INDEX IF NOT EXISTS job_heal_runs_job ON job_heal_runs(job_id);
  """

  @type conn :: CuesSql.conn()

  @typedoc """
  What became of a run's failure: retried (`:none`, the retry has it), taken
  by a heal it opened or joined, concluding a watching heal a second time
  (`:verdict`, M106 §5.9), kept quiet by one that closed lately, or out of the
  heal's scope (a guest's job), which keeps its own failure line.
  """
  @type disposition ::
          :none
          | :out_of_scope
          | :quiet
          | {:opened, String.t()}
          | {:joined, String.t()}
          | {:verdict, String.t()}

  @type heal :: %{required(atom()) => term()}

  @typedoc """
  What a heal run decided, as code carries it out (M106 §5.5): the
  `decision`, the run's `note`, whether the run `read_outside` content, the
  exact `change` (each of `update_job`'s fields it touches, with its `from`
  and `to`) and the job's version it was drawn for.
  """
  @type plan :: %{
          required(:decision) => String.t(),
          required(:note) => String.t() | nil,
          required(:read_outside) => boolean() | nil,
          required(:change) => map() | nil,
          optional(:change_job_version) => DateTime.t() | nil
        }

  @doc "The two tables and their indexes, for their migration."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc """
  The column migration 73 adds to `job_heals` for the tool a heal of a run
  that ended ok without working is about (M106 §6), as `diagnosis_columns/0`
  adds 72's: added while the table holds 72's columns, nothing while it holds
  them and it, refused for any other set.
  """
  @spec tool_columns() :: %{before: [String.t()], after: [String.t()], sql: String.t()}
  def tool_columns,
    do: %{
      before: @columns_71 ++ @diagnosis_columns,
      after: @columns,
      sql: "ALTER TABLE job_heals ADD COLUMN tool_json TEXT;"
    }

  @doc """
  The columns migration 72 adds to `job_heals` for the diagnosis (M106 §5.5,
  §5.9), as `Memory.Repo` adds columns: added while the table holds 71's
  columns, nothing while it holds both or what 73 made of them, refused for
  any other set.
  """
  @spec diagnosis_columns() :: %{
          before: [String.t()],
          after: [String.t()],
          later: [[String.t()]],
          sql: String.t()
        }
  def diagnosis_columns,
    do: %{
      before: @columns_71,
      after: @columns_71 ++ @diagnosis_columns,
      later: [@columns],
      sql: @diagnosis_sql
    }

  @doc """
  What `run`'s settle does to the heals, after its retry was decided, on the
  settle's connection and inside its transaction. An ok run of an operator's
  job is first read for the trigger of a run that ended ok without working
  (`Jobs.Degraded`, M106 §6). One that does not trip it closes as healed its
  job's heal, the heal of the provider it ran on (`facts.provider`) and the
  heal of each plugin a tool of which succeeded in it. One that trips it
  closes the provider's heal only, and is taken as a failed run that is not
  retried is: it opens a heal for its subject, joins the one not closed,
  concludes a watching one, or is quiet. A guest's job is out of scope.
  Returns the settlement with `heal` and `healed` (the ids an ok run closed)
  added, and for a failure taken its `failure_kind`, `subject_kind` and
  `subject_id`.
  """
  @spec settle(conn(), map(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def settle(conn, job, %{status: "ok"} = run, settlement, facts) do
    with {:ok, trip} <- degraded(conn, job, run) do
      settle_ok(conn, job, run, settlement, Map.get(facts, :provider), trip)
    end
  end

  def settle(_conn, _job, _run, %{disposition: :retry} = settlement, _facts),
    do: {:ok, Map.merge(settlement, %{heal: :none, healed: []})}

  def settle(_conn, %{created_by_trust: trust}, _run, settlement, _facts)
      when trust != "operator",
      do: {:ok, Map.merge(settlement, %{heal: :out_of_scope, healed: []})}

  def settle(conn, job, run, settlement, facts) do
    subject = subject(run.failure_kind, Map.get(facts, :provider), job.id)

    failure = %{
      kind: run.failure_kind,
      text: facts.failure_text,
      words: Map.get(facts, :failure_words),
      tool: nil
    }

    with {:ok, heal} <- take_failure(conn, subject, job, run, failure) do
      {:ok, Map.merge(settlement, taken(heal, [], failure, subject))}
    end
  end

  @doc """
  A run's stored tool tally as the store reads it (M106 §6): the tally, or
  nil for none or for one this engine cannot read
  (`Jobs.Degraded.readable_tally/1`), which is logged by the run's id and
  never by its content, and breaks the trigger's streak.
  """
  @spec run_tally(String.t(), String.t() | nil) :: [Degraded.entry()] | nil
  def run_tally(run_id, json) when is_binary(run_id) do
    case Degraded.readable_tally(json) do
      {:ok, tally} ->
        tally

      :unreadable ->
        Logger.warning(
          "Job run #{run_id}: its tool tally could not be read, so it counts as none"
        )

        nil
    end
  end

  @doc "Serves one request about the heals (`Memory.Repo.job_heals_call/2`)."
  @spec handle(conn(), term()) :: term()
  def handle(conn, {:get, id}) when is_binary(id), do: get(conn, id)
  def handle(conn, {:runs, id}) when is_binary(id), do: runs(conn, id)
  def handle(conn, :open_heals), do: open_heals(conn)
  def handle(conn, :open_by_job), do: open_by_job(conn)
  def handle(conn, {:message_facts, id}) when is_binary(id), do: message_facts(conn, id)

  def handle(conn, {:claim, %DateTime{} = now, %DateTime{} = lease_until}),
    do: CuesSql.with_immediate_transaction(conn, fn -> claim(conn, now, lease_until) end)

  def handle(conn, {:put_inbox, id, token, inbox, %DateTime{} = now}) do
    assignments = [
      {"inbox_platform", inbox.platform},
      {"inbox_destination", inbox.destination},
      {"inbox_thread_scope", inbox.thread_scope}
    ]

    held_write(conn, id, token, assignments, now)
  end

  def handle(conn, {:put_message, id, token, text, %DateTime{} = now}) when is_binary(text),
    do: held_write(conn, id, token, [{"message", text}], now)

  # The fence a heal run takes right before it writes the job: the lease
  # still its own (M106 §5.5).
  def handle(conn, {:hold, id, token, %DateTime{} = now}),
    do: held_write(conn, id, token, [], now)

  def handle(conn, {:decided, id, token, %{decision: decision} = plan, %DateTime{} = now})
      when decision in @decisions,
      do: held_write(conn, id, token, decided_assignments(plan), now)

  # What came of the rerun, written once after the concluding write released
  # the lease. A refusal takes a heal still watching on its first conclusion
  # to waiting: no run is coming. A heal the job's own run moved meanwhile
  # stays where it is.
  def handle(conn, {:rerun_outcome, id, outcome, %DateTime{} = now})
      when is_binary(id) and outcome in @rerun_outcomes,
      do: rerun_outcome(conn, id, outcome, now)

  def handle(conn, {:delivered, id, token, %DateTime{} = now}) do
    assignments = [
      {"delivery_status", "delivered"},
      {"delivered_at", CuesSql.stamp(now)},
      {"next_delivery_at", nil}
    ]

    conclude(conn, id, token, assignments, now)
  end

  def handle(conn, {:delivery_failed, id, token, failure, %DateTime{} = now}) do
    %{attempts: attempts, next_delivery_at: %DateTime{} = next, error: error} = failure

    assignments = [
      {"state", "open"},
      {"delivery_attempts", attempts},
      {"next_delivery_at", CuesSql.stamp(next)},
      {"last_delivery_error", bounded(error, @delivery_error_max)}
    ]

    held_release(conn, id, token, assignments, now)
  end

  def handle(
        conn,
        {:dead_letter, id, token, %{attempts: attempts, error: error}, %DateTime{} = now}
      ) do
    assignments = [
      {"delivery_status", "dead_letter"},
      {"delivery_attempts", attempts},
      {"next_delivery_at", nil},
      {"last_delivery_error", bounded(error, @delivery_error_max)}
    ]

    conclude(conn, id, token, assignments, now)
  end

  def handle(conn, {:expire_waiting, %DateTime{} = now}),
    do: CuesSql.with_immediate_transaction(conn, fn -> expire_waiting(conn, now) end)

  # --- the settle ------------------------------------------------------------

  # A guest's job is out of the heal's scope: its ok run is never read for the
  # trigger, and closes heals as any ok run that does not trip it does.
  defp degraded(_conn, %{created_by_trust: trust}, _run) when trust != "operator",
    do: {:ok, :none}

  defp degraded(conn, job, run) do
    with {:ok, earlier} <- earlier_tallies(conn, job.id, run.id) do
      {:ok, Degraded.decide([run.tool_tally | earlier])}
    end
  end

  # The tallies of the job's runs settled before this one, newest first, as
  # many as the trigger reads with this one: any trigger and any final status,
  # a cue run never (§13). A run with no facts row, or one written before
  # tallies were kept, reads as nil, which breaks the streak.
  defp earlier_tallies(conn, job_id, run_id) do
    sql = """
    SELECT r.id, f.tool_tally_json
    FROM job_runs r LEFT JOIN job_run_facts f ON f.run_id = r.id
    WHERE r.job_id = ? AND r.id <> ? AND r.trigger <> 'cue'
      AND r.status IN ('ok', 'error', 'timeout')
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT ?
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [job_id, run_id, Degraded.runs() - 1]) do
      {:ok, Enum.map(rows, fn [id, json] -> run_tally(id, json) end)}
    end
  end

  # A run that does not trip the trigger may prove its job's heal.
  defp settle_ok(conn, job, run, settlement, provider, :none) do
    with {:ok, healed} <- close_proven(conn, job.id, provider, run) do
      {:ok, Map.merge(settlement, %{heal: :none, healed: healed})}
    end
  end

  # One that trips it never proves its job's, and its tool's failure is taken.
  defp settle_ok(conn, job, run, settlement, provider, {:tool, tool}) do
    subject = tool_subject(tool, job.id)
    failure = tool_failure(tool)

    with {:ok, healed} <- close_proven(conn, nil, provider, run),
         {:ok, heal} <- take_failure(conn, subject, job, run, failure) do
      {:ok, Map.merge(settlement, taken(heal, healed, failure, subject))}
    end
  end

  # The heals not closed that an ok run proves, closed as healed: its
  # provider's; its job's (when it may prove it), but one about a tool only if
  # that tool worked in it; each plugin's whose own tool worked in it.
  defp close_proven(conn, job_id, provider, run) do
    subjects = [{"job", job_id}, {"provider", provider}] ++ plugins_worked(run.tool_tally)

    with {:ok, heals} <- open_for(conn, subjects) do
      proven = for heal <- heals, proves?(heal, run.tool_tally), do: heal.id
      close_ids(conn, proven, run.completed_at)
    end
  end

  # The plugins a tool of which worked in the run: only their heals can be
  # about a tool that did.
  defp plugins_worked(nil), do: []

  defp plugins_worked(tally) when is_list(tally) do
    for %{"plugin" => plugin, "ok" => ok} <- tally,
        is_binary(plugin) and ok > 0,
        uniq: true,
        do: {"plugin", plugin}
  end

  defp proves?(%{subject_kind: "provider"}, _tally), do: true

  defp proves?(%{subject_kind: "job", failure_kind: kind}, _tally) when kind != @degraded,
    do: true

  defp proves?(%{tool: %{"name" => name}}, tally), do: Degraded.worked?(tally, name)
  defp proves?(_heal_with_no_readable_tool, _tally), do: false

  # A plugin's tool makes the plugin the subject (§5.4); any other, the job.
  defp tool_subject(%{plugin: plugin}, _job_id) when is_binary(plugin) and plugin != "",
    do: {"plugin", plugin, nil}

  defp tool_subject(_tool, job_id), do: {"job", job_id, job_id}

  # Fermix's sentence for the kind, the tool's own last words, and the tool:
  # its name, its plugin and its failed calls in each run, newest first.
  defp tool_failure(tool) do
    fact = %{"name" => tool.name, "failed_calls" => tool.failed_calls}
    fact = if tool.plugin, do: Map.put(fact, "plugin", tool.plugin), else: fact

    %{
      kind: Failure.stored(:tool_never_succeeded),
      text: Failure.sentence(:tool_never_succeeded),
      words: tool.last_error,
      tool: fact
    }
  end

  defp taken(heal, healed, failure, {subject_kind, subject_id, _job_id}) do
    %{
      heal: heal,
      healed: healed,
      failure_kind: failure.kind,
      subject_kind: subject_kind,
      subject_id: subject_id
    }
  end

  # A failure no model run can help with is its provider's, when one is named;
  # every other failure, and a provider's with no provider to name, is its job's.
  defp subject(kind, provider, job_id) when is_binary(kind) do
    if Failure.model_cannot_help?(kind) and is_binary(provider) and provider != "",
      do: {"provider", provider, nil},
      else: {"job", job_id, job_id}
  end

  # A failure that finds its subject's heal watching a move Fermix made
  # concludes it a second time (§5.9); any other not closed takes it in.
  defp take_failure(conn, {kind, id, _job_id} = subject, job, run, failure) do
    case not_closed(conn, kind, id) do
      {:ok, nil} -> open_or_quiet(conn, subject, job, run, failure)
      {:ok, {heal_id, "watching"}} -> verdict(conn, heal_id, job, run, failure)
      {:ok, {heal_id, _state}} -> join(conn, heal_id, job, run)
      {:error, reason} -> {:error, reason}
    end
  end

  defp not_closed(conn, kind, id) do
    sql =
      "SELECT id, state FROM job_heals " <>
        "WHERE subject_kind = ? AND subject_id = ? AND state <> 'closed'"

    case CuesSql.query_all(conn, sql, [kind, id]) do
      {:ok, [[heal_id, state]]} -> {:ok, {heal_id, state}}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # The fix did not hold: the heal is open again on its second conclusion,
  # its failure the one that just happened and its outbox as new, so the
  # same claim, lease and send tell the owner once more. The inbox it chose
  # stays.
  defp verdict(conn, heal_id, job, run, failure) do
    sql = """
    UPDATE job_heals
    SET state = 'open', conclusion = 'verdict', failure_kind = ?, failure_text = ?,
        failure_words = ?, tool_json = ?, run_count = run_count + 1, last_run_id = ?,
        last_failed_at = ?, updated_at = ?, waiting_since = NULL, message = NULL,
        delivery_status = 'pending', delivery_attempts = 0, next_delivery_at = NULL,
        last_delivery_error = NULL, delivered_at = NULL
    WHERE id = ? AND state = 'watching'
    """

    stamp = CuesSql.stamp(run.completed_at)

    params = [
      failure.kind,
      bounded(failure.text, @failure_text_max),
      bounded(failure.words, @failure_words_max),
      encode_json(failure.tool),
      run.id,
      stamp,
      stamp,
      heal_id
    ]

    with :ok <- CuesSql.execute(conn, sql, params),
         :ok <- link_run(conn, heal_id, job, run) do
      {:ok, {:verdict, heal_id}}
    end
  end

  defp join(conn, heal_id, job, run) do
    sql = """
    UPDATE job_heals
    SET run_count = run_count + 1, last_run_id = ?, last_failed_at = ?, updated_at = ?
    WHERE id = ?
    """

    stamp = CuesSql.stamp(run.completed_at)

    with :ok <- CuesSql.execute(conn, sql, [run.id, stamp, stamp, heal_id]),
         :ok <- link_run(conn, heal_id, job, run) do
      {:ok, {:joined, heal_id}}
    end
  end

  defp open_or_quiet(conn, {kind, id, _job_id} = subject, job, run, failure) do
    case quiet?(conn, kind, id, failure.kind, run.completed_at) do
      {:ok, true} -> {:ok, :quiet}
      {:ok, false} -> open(conn, subject, job, run, failure)
      {:error, reason} -> {:error, reason}
    end
  end

  defp quiet?(conn, kind, id, failure_kind, %DateTime{} = failed_at) do
    since = DateTime.add(failed_at, -@quiet_days * 86_400, :second)

    sql = """
    SELECT 1 FROM job_heals
    WHERE subject_kind = ? AND subject_id = ? AND failure_kind = ? AND state = 'closed'
      AND outcome IN (#{placeholders(@quiet_outcomes)}) AND closed_at >= ?
    LIMIT 1
    """

    params = [kind, id, failure_kind] ++ @quiet_outcomes ++ [CuesSql.stamp(since)]

    with {:ok, rows} <- CuesSql.query_all(conn, sql, params), do: {:ok, rows != []}
  end

  defp open(conn, {kind, id, job_id}, job, run, failure) do
    heal_id = "jhl_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    stamp = CuesSql.stamp(run.completed_at)

    sql = """
    INSERT INTO job_heals (
      id, subject_kind, subject_id, job_id, failure_kind, failure_text, failure_words,
      tool_json, state, run_count, last_run_id, last_failed_at, opened_at, updated_at,
      delivery_status, delivery_attempts
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', 1, ?, ?, ?, ?, 'pending', 0)
    """

    params = [
      heal_id,
      kind,
      id,
      job_id,
      failure.kind,
      bounded(failure.text, @failure_text_max),
      bounded(failure.words, @failure_words_max),
      encode_json(failure.tool),
      run.id,
      stamp,
      stamp,
      stamp
    ]

    with :ok <- CuesSql.execute(conn, sql, params),
         :ok <- link_run(conn, heal_id, job, run) do
      {:ok, {:opened, heal_id}}
    end
  end

  defp link_run(conn, heal_id, job, run) do
    sql = "INSERT INTO job_heal_runs (run_id, heal_id, job_id) VALUES (?, ?, ?)"
    CuesSql.execute(conn, sql, [run.id, heal_id, job.id])
  end

  # The heals not closed of these subjects, with their kind and tool. A
  # subject with no id (a run that named no provider) has none.
  defp open_for(conn, subjects) do
    case for({kind, id} <- subjects, is_binary(id) and id != "", do: {kind, id}) do
      [] -> {:ok, []}
      named -> query_open_for(conn, named)
    end
  end

  defp query_open_for(conn, subjects) do
    any =
      Enum.map_join(subjects, " OR ", fn _subject -> "(subject_kind = ? AND subject_id = ?)" end)

    sql =
      "SELECT id, subject_kind, failure_kind, tool_json FROM job_heals " <>
        "WHERE state <> 'closed' AND (#{any})"

    params = Enum.flat_map(subjects, fn {kind, id} -> [kind, id] end)

    with {:ok, rows} <- CuesSql.query_all(conn, sql, params) do
      {:ok,
       Enum.map(rows, fn [id, kind, failure_kind, tool_json] ->
         %{
           id: id,
           subject_kind: kind,
           failure_kind: failure_kind,
           tool: decode_tool(id, tool_json)
         }
       end)}
    end
  end

  defp close_ids(_conn, [], _at), do: {:ok, []}

  defp close_ids(conn, ids, %DateTime{} = at) do
    where = "state <> 'closed' AND id IN (#{placeholders(ids)})"
    with :ok <- close_rows(conn, where, ids, "healed", at, ids), do: {:ok, ids}
  end

  defp close_rows(_conn, _where, _params, _outcome, _at, []), do: :ok

  defp close_rows(conn, where, params, outcome, at, _rows) do
    sql = """
    UPDATE job_heals
    SET state = 'closed', outcome = ?, closed_at = ?, updated_at = ?, lease_token = NULL,
        lease_until = NULL
    WHERE #{where}
    """

    CuesSql.execute(conn, sql, [outcome, CuesSql.stamp(at), CuesSql.stamp(at)] ++ params)
  end

  # --- the claim and the heal run's writes -------------------------------------

  defp claim(conn, now, lease_until) do
    stamp = CuesSql.stamp(now)

    sql = """
    #{@select}
    WHERE (state = 'open' AND (next_delivery_at IS NULL OR next_delivery_at <= ?))
       OR (state = 'diagnosing' AND lease_until <= ?)
    ORDER BY opened_at, id
    LIMIT 1
    """

    case CuesSql.query_all(conn, sql, [stamp, stamp]) do
      {:ok, [row]} -> take_lease(conn, heal_row(row), now, lease_until)
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp take_lease(conn, heal, now, lease_until) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    sql = """
    UPDATE job_heals
    SET state = 'diagnosing', lease_token = ?, lease_until = ?, updated_at = ?
    WHERE id = ?
    """

    params = [token, CuesSql.stamp(lease_until), CuesSql.stamp(now), heal.id]
    with :ok <- CuesSql.execute(conn, sql, params), do: get(conn, heal.id)
  end

  # A write of the heal run that holds the lease and keeps it.
  defp held_write(conn, id, token, assignments, now) when is_binary(id) and is_binary(token),
    do: write_if_held(conn, id, token, assignments ++ [{"updated_at", CuesSql.stamp(now)}])

  # The heal run's last write: what became of the send, and the lease let go.
  defp held_release(conn, id, token, assignments, now) when is_binary(id) and is_binary(token) do
    released = [{"lease_token", nil}, {"lease_until", nil}, {"updated_at", CuesSql.stamp(now)}]
    write_if_held(conn, id, token, assignments ++ released)
  end

  # The concluding write (a send delivered or dead-lettered) takes the heal
  # where its conclusion and its decision say, read in the same transaction.
  defp conclude(conn, id, token, assignments, now) when is_binary(id) and is_binary(token) do
    result =
      CuesSql.with_immediate_transaction(conn, fn ->
        with {:ok, heal} <- get(conn, id),
             :ok <- held_release(conn, id, token, assignments ++ next(heal, now), now),
             do: {:ok, :concluded}
      end)

    with {:ok, :concluded} <- result, do: :ok
  end

  # A verdict closes the heal still failing (§5.9); a move Fermix made has it
  # watch the job's next run, a rerun's start stamped once; anything else
  # waits on the owner. Both waits start now, for the seven-day bound.
  defp next(%{conclusion: "verdict"}, now) do
    stamp = CuesSql.stamp(now)
    [{"state", "closed"}, {"outcome", "still_failing"}, {"closed_at", stamp}]
  end

  defp next(%{decision: "rerun"} = heal, now) do
    [
      {"state", "watching"},
      {"waiting_since", CuesSql.stamp(now)},
      {"rerun_at", CuesSql.stamp(heal.rerun_at || now)}
    ]
  end

  defp next(%{decision: "raise_limit"}, now),
    do: [{"state", "watching"}, {"waiting_since", CuesSql.stamp(now)}]

  defp next(_heal, now), do: [{"state", "waiting"}, {"waiting_since", CuesSql.stamp(now)}]

  defp rerun_outcome(conn, id, outcome, now) do
    stamp = CuesSql.stamp(now)
    refused = outcome == "refused"

    sql = """
    UPDATE job_heals
    SET rerun_outcome = ?, updated_at = ?,
        state = CASE WHEN ? AND state = 'watching' AND conclusion = 'first'
                     THEN 'waiting' ELSE state END,
        waiting_since = CASE WHEN ? AND state = 'watching' AND conclusion = 'first'
                             THEN ? ELSE waiting_since END
    WHERE id = ? AND decision = 'rerun' AND rerun_outcome IS NULL
    """

    params = [outcome, stamp, flag(refused), flag(refused), stamp, id]

    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      if changed == 1, do: :ok, else: {:error, :not_recorded}
    end
  end

  defp decided_assignments(plan) do
    [
      {"decision", plan.decision},
      {"note", bounded(plan.note, @note_max)},
      {"read_outside", flag(plan.read_outside)},
      {"change_json", change_json(plan.change)},
      {"change_job_version", optional_stamp(Map.get(plan, :change_job_version))}
    ]
  end

  defp flag(nil), do: nil
  defp flag(true), do: 1
  defp flag(false), do: 0

  defp change_json(nil), do: nil
  defp change_json(change) when is_map(change) and map_size(change) > 0, do: Jason.encode!(change)

  defp optional_stamp(nil), do: nil
  defp optional_stamp(%DateTime{} = at), do: CuesSql.stamp(at)

  defp write_if_held(conn, id, token, assignments) do
    {columns, values} = Enum.unzip(assignments)
    set_sql = Enum.map_join(columns, ", ", &"#{&1} = ?")

    sql =
      "UPDATE job_heals SET #{set_sql} WHERE id = ? AND lease_token = ? AND state = 'diagnosing'"

    with :ok <- CuesSql.execute(conn, sql, values ++ [id, token]),
         {:ok, changed} <- CuesSql.changes(conn) do
      if changed == 1, do: :ok, else: {:error, :lease_lost}
    end
  end

  # A heal waiting on the owner, or watching a job that never runs again (a
  # job paused meanwhile), closes after the same seven days.
  defp expire_waiting(conn, now) do
    cutoff = CuesSql.stamp(DateTime.add(now, -@waiting_days * 86_400, :second))

    sql = """
    #{@select}
    WHERE state IN ('waiting', 'watching') AND waiting_since <= ?
    ORDER BY waiting_since, id
    LIMIT #{@expire_limit}
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [cutoff]),
         heals = Enum.map(rows, &heal_row/1),
         :ok <- expire_rows(conn, heals, now) do
      {:ok, heals}
    end
  end

  defp expire_rows(_conn, [], _now), do: :ok

  defp expire_rows(conn, heals, now) do
    ids = Enum.map(heals, & &1.id)
    where = "state IN ('waiting', 'watching') AND id IN (#{placeholders(ids)})"
    close_rows(conn, where, ids, "expired", now, ids)
  end

  # --- reads -------------------------------------------------------------------

  defp get(conn, id) do
    case CuesSql.query_all(conn, "#{@select} WHERE id = ?", [id]) do
      {:ok, [row]} -> {:ok, heal_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runs(conn, id) do
    sql = "SELECT run_id FROM job_heal_runs WHERE heal_id = ? ORDER BY run_id"
    with {:ok, rows} <- CuesSql.query_all(conn, sql, [id]), do: {:ok, List.flatten(rows)}
  end

  defp open_heals(conn) do
    sql = "#{@select} WHERE state <> 'closed' ORDER BY opened_at, id"
    with {:ok, rows} <- CuesSql.query_all(conn, sql, []), do: {:ok, Enum.map(rows, &heal_row/1)}
  end

  # Each job's heal that is not closed, the latest opened when two hold its
  # runs (its own and its provider's), keyed by job id.
  defp open_by_job(conn) do
    sql = """
    SELECT DISTINCT r.job_id, h.id, h.state, h.subject_kind, h.subject_id, h.failure_kind,
           h.opened_at, h.run_count, h.delivery_status, h.decision, h.note, h.change_json,
           h.rerun_outcome, h.tool_json
    FROM job_heals h JOIN job_heal_runs r ON r.heal_id = h.id
    WHERE h.state <> 'closed'
    ORDER BY h.opened_at DESC, h.id
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, []) do
      {:ok, Enum.reduce(rows, %{}, &put_job_heal/2)}
    end
  end

  defp put_job_heal([job_id | row], acc) do
    [id, state, kind, subject, failure, opened, count, delivery | diagnosis] = row
    [decision, note, change, rerun, tool] = diagnosis

    summary = %{
      id: id,
      state: state,
      subject_kind: kind,
      subject_id: subject,
      failure_kind: failure,
      opened_at: CuesSql.parse_stamp(opened),
      run_count: count,
      delivery_status: delivery,
      decision: decision,
      note: note,
      change: decode_change(change),
      rerun_outcome: rerun,
      tool: decode_tool(id, tool)
    }

    Map.put_new(acc, job_id, summary)
  end

  # Fermix's own facts about a heal, for `Jobs.HealMessage`: no tool's output,
  # and of what a model wrote only the heal run's note, which the message
  # shows as Fermix's reading under the facts (§5.8, §9).
  defp message_facts(conn, id) do
    with {:ok, heal} <- get(conn, id),
         {:ok, job} <- message_job(conn, heal.job_id),
         {:ok, recent} <- recent(conn, heal),
         {:ok, jobs, job_count} <- heal_jobs(conn, heal) do
      {:ok,
       %{
         subject_kind: heal.subject_kind,
         subject_id: heal.subject_id,
         failure_kind: heal.failure_kind,
         failure_text: heal.failure_text,
         failure_words: heal.failure_words,
         opened_at: heal.opened_at,
         failed_at: heal.last_failed_at,
         run_count: heal.run_count,
         job: job,
         recent: recent,
         jobs: jobs,
         job_count: job_count,
         conclusion: heal.conclusion,
         decision: heal.decision,
         note: heal.note,
         change: heal.change,
         tool: heal.tool
       }}
    end
  end

  defp message_job(_conn, nil), do: {:ok, nil}

  defp message_job(conn, job_id) do
    sql = "SELECT name, enabled, state, next_run_at FROM scheduled_jobs WHERE id = ?"

    case CuesSql.query_all(conn, sql, [job_id]) do
      {:ok, [[name, enabled, state, next_run_at]]} ->
        {:ok,
         %{name: name, enabled?: enabled == 1, state: state, next_run_at: parse_time(next_run_at)}}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # How many of the job's last runs ended as the heal's did. A run that ended
  # ok without working has no kind on its row, so it is never counted here.
  defp recent(_conn, %{job_id: nil}), do: {:ok, nil}

  defp recent(conn, heal) do
    sql = """
    SELECT f.failure_kind
    FROM job_runs r LEFT JOIN job_run_facts f ON f.run_id = r.id
    WHERE r.job_id = ? AND r.status IN ('ok', 'error', 'timeout')
    ORDER BY r.completed_at DESC, r.id
    LIMIT #{@recent_runs}
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [heal.job_id]) do
      kinds = List.flatten(rows)
      {:ok, %{same: Enum.count(kinds, &(&1 == heal.failure_kind)), of: length(kinds)}}
    end
  end

  # The jobs whose runs a provider's or a plugin's heal took, most runs first,
  # and how many jobs that is in all.
  defp heal_jobs(_conn, %{subject_kind: "job"}), do: {:ok, [], 1}

  defp heal_jobs(conn, heal) do
    sql = """
    SELECT j.name, count(*) AS runs
    FROM job_heal_runs r JOIN scheduled_jobs j ON j.id = r.job_id
    WHERE r.heal_id = ?
    GROUP BY r.job_id
    ORDER BY runs DESC, j.name
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [heal.id]) do
      jobs =
        rows
        |> Enum.take(@named_jobs)
        |> Enum.map(fn [name, runs] -> %{name: name, runs: runs} end)

      {:ok, jobs, length(rows)}
    end
  end

  # --- rows --------------------------------------------------------------------

  # The stored change and tool are read back decoded, as `change` and `tool`,
  # and what the run read as a boolean (nil before any diagnosis).
  defp heal_row(row) do
    heal =
      @fields
      |> Enum.zip(row)
      |> Map.new(fn
        {field, value} when field in @stamped -> {field, CuesSql.parse_stamp(value)}
        {field, value} -> {field, value}
      end)

    {change_json, heal} = Map.pop(heal, :change_json)
    {tool_json, heal} = Map.pop(heal, :tool_json)

    heal
    |> Map.put(:change, decode_change(change_json))
    |> Map.put(:tool, decode_tool(heal.id, tool_json))
    |> Map.update!(:read_outside, &read_flag/1)
  end

  defp decode_change(nil), do: nil
  defp decode_change(json) when is_binary(json), do: Jason.decode!(json)

  # The tool a heal is about, as `tool_failure/1` wrote it: its name, its
  # failed calls per run and any plugin. One this engine cannot read (a later
  # engine's shape, a damaged row) reads as none, logged by the heal's id.
  defp decode_tool(_heal_id, nil), do: nil

  defp decode_tool(heal_id, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"name" => name, "failed_calls" => calls} = tool}
      when is_binary(name) and is_list(calls) ->
        tool

      _unreadable ->
        Logger.warning("Job heal #{heal_id}: its tool could not be read, so it names none")
        nil
    end
  end

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_map(value), do: Jason.encode!(value)

  defp read_flag(nil), do: nil
  defp read_flag(1), do: true
  defp read_flag(0), do: false

  # `scheduled_jobs` keeps its times as ISO 8601 of any width.
  defp parse_time(nil), do: nil

  defp parse_time(text) when is_binary(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end

  defp bounded(nil, _max), do: nil
  defp bounded(text, max) when is_binary(text), do: String.slice(text, 0, max)
  defp bounded(other, max), do: other |> inspect() |> String.slice(0, max)

  defp placeholders(values), do: Enum.map_join(values, ", ", fn _value -> "?" end)
end
