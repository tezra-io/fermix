defmodule FermixTestSupport.CueDeliveryFixtures do
  @moduledoc """
  Rows for the cue read-side tests (`list_cues`, `cue_history`, task notes):
  a watcher with its task's job and memory source, cues, deliveries, the run
  that held one, its mandate calls and proposals. Every row goes in through the
  direct connection `FermixTestSupport.CueFixtures.start_repo/1` opens, with the
  times the test names, so nothing reads a real clock.
  """

  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.CueFixtures

  @doc """
  Inserts a watcher (see `CueFixtures.insert_watcher/2`) and returns its id, name,
  task job id and memory source id. `:task_notes` (default false) sets the switch.
  """
  @spec watcher(term(), map()) :: %{
          id: String.t(),
          name: String.t(),
          job_id: String.t(),
          source_id: String.t()
        }
  def watcher(conn, attrs) when is_map(attrs) do
    id = CueFixtures.insert_watcher(conn, Map.put_new(attrs, :filter, "llm"))
    notes = if Map.get(attrs, :task_notes, false), do: 1, else: 0
    CueFixtures.exec!(conn, "UPDATE cue_watchers SET task_notes = ? WHERE id = ?", [notes, id])

    [[name, job_id, source_id]] =
      CueFixtures.rows(
        conn,
        "SELECT w.name, j.id, j.memory_source_id FROM cue_watchers w " <>
          "JOIN scheduled_jobs j ON j.id = w.task_job_id WHERE w.id = ?",
        [id]
      )

    %{id: id, name: name, job_id: job_id, source_id: source_id}
  end

  @doc """
  Inserts a cue and returns its id. `attrs`: `:source_ref`, `:received_at`
  (required), `:type`, `:subject`, `:text` (the snapshot's text), `:routed`
  (routed_count, default 1), `:self_caused`.
  """
  @spec cue(term(), map()) :: pos_integer()
  def cue(conn, attrs) when is_map(attrs) do
    unique = System.unique_integer([:positive])
    at = stamp(Map.fetch!(attrs, :received_at))

    snapshot =
      Jason.encode!(%{
        type: Map.get(attrs, :type),
        subject: Map.get(attrs, :subject),
        text: Map.get(attrs, :text)
      })

    [[id]] =
      CueFixtures.rows(
        conn,
        """
        INSERT INTO cues (source_ref, item_id, type, subject, received_at, content_hash,
          snapshot, self_caused, routed_count, last_seen_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
        """,
        [
          Map.fetch!(attrs, :source_ref),
          "item-#{unique}",
          Map.get(attrs, :type),
          Map.get(attrs, :subject),
          at,
          "hash-#{unique}",
          snapshot,
          if(Map.get(attrs, :self_caused, false), do: 1, else: 0),
          Map.get(attrs, :routed, 1),
          at
        ]
      )

    id
  end

  @doc """
  Inserts a delivery of `cue_id` to a watcher and returns its id. `attrs`:
  `:watcher_id`, `:source_ref`, `:received_at` (required), `:subject`,
  `:state` (default `acked`), `:outcome`, `:reason`, `:hint`, `:run_id`.
  """
  @spec delivery(term(), pos_integer(), map()) :: pos_integer()
  def delivery(conn, cue_id, attrs) when is_integer(cue_id) and is_map(attrs) do
    at = Map.fetch!(attrs, :received_at)
    state = Map.get(attrs, :state, "acked")
    settled = if state in ~w(acked dropped exhausted expired), do: stamp(at), else: nil

    [[id]] =
      CueFixtures.rows(
        conn,
        """
        INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, subject, received_at, state,
          outcome, decision_reason, hint, ready_at, valid_until, claimed_run_id, settled_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
        """,
        [
          cue_id,
          Map.fetch!(attrs, :watcher_id),
          Map.fetch!(attrs, :source_ref),
          Map.get(attrs, :subject),
          stamp(at),
          state,
          Map.get(attrs, :outcome),
          Map.get(attrs, :reason),
          Map.get(attrs, :hint),
          stamp(at),
          stamp(DateTime.add(at, 7 * 86_400, :second)),
          Map.get(attrs, :run_id),
          settled
        ]
      )

    id
  end

  @doc "Inserts a finished cue run of `job_id` that held `delivery_id`; returns its id."
  @spec run(term(), String.t(), pos_integer(), String.t()) :: String.t()
  def run(conn, job_id, delivery_id, reply) when is_binary(job_id) and is_integer(delivery_id) do
    id = "run_test#{System.unique_integer([:positive])}"

    CueFixtures.exec!(
      conn,
      """
      INSERT INTO job_runs (id, job_id, session_id, trigger, status, final_response,
        cue_delivery_id)
      VALUES (?, ?, ?, 'cue', 'ok', ?, ?)
      """,
      [id, job_id, "cron_#{id}", reply, delivery_id]
    )

    CueFixtures.exec!(conn, "UPDATE cue_deliveries SET claimed_run_id = ? WHERE id = ?", [
      id,
      delivery_id
    ])

    id
  end

  @doc "Inserts a mandate call made for `delivery_id` by `run_id`; returns its id."
  @spec call(term(), map()) :: String.t()
  def call(conn, attrs) when is_map(attrs) do
    id = "cmc_test#{System.unique_integer([:positive])}"
    at = stamp(Map.fetch!(attrs, :at))

    CueFixtures.exec!(
      conn,
      """
      INSERT INTO cue_mandate_calls (id, run_id, job_id, mandate, tool, args_json,
        idempotency_key, delivery_id, decision, reason, validator, result_status, result_summary,
        created_at, decided_at, finished_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'none', ?, ?, ?, ?, ?)
      """,
      [
        id,
        Map.fetch!(attrs, :run_id),
        Map.fetch!(attrs, :job_id),
        Map.get(attrs, :mandate, "release-issues"),
        Map.get(attrs, :tool, "github_create_issue"),
        Map.fetch!(attrs, :args_json),
        "key-#{id}",
        Map.fetch!(attrs, :delivery_id),
        Map.get(attrs, :decision, "allow"),
        Map.get(attrs, :reason),
        Map.get(attrs, :result_status, "ok"),
        Map.get(attrs, :result_summary),
        at,
        at,
        at
      ]
    )

    id
  end

  @doc "Inserts a proposal for a mandate call; returns its id."
  @spec proposal(term(), map()) :: String.t()
  def proposal(conn, attrs) when is_map(attrs) do
    id = "cpr_test#{System.unique_integer([:positive])}"
    at = Map.fetch!(attrs, :at)

    CueFixtures.exec!(
      conn,
      """
      INSERT INTO cue_proposals (id, mandate_call_id, run_id, job_id, mandate, watcher_id,
        delivery_id, tool, args_json, idempotency_key, token_digest, state, created_at, expires_at)
      VALUES (?, ?, ?, ?, 'release-issues', ?, ?, 'github_create_issue', ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        Map.fetch!(attrs, :call_id),
        Map.fetch!(attrs, :run_id),
        Map.fetch!(attrs, :job_id),
        Map.fetch!(attrs, :watcher_id),
        Map.fetch!(attrs, :delivery_id),
        Map.fetch!(attrs, :args_json),
        "pkey-#{id}",
        "digest-#{id}",
        Map.get(attrs, :state, "waiting"),
        stamp(at),
        stamp(DateTime.add(at, 3_600, :second))
      ]
    )

    id
  end

  @doc "A time as the cue tables store it."
  @spec stamp(DateTime.t()) :: String.t()
  def stamp(%DateTime{} = at), do: CuesSql.stamp(at)
end
