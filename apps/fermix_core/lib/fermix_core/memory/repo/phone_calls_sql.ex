defmodule FermixCore.Memory.Repo.PhoneCallsSql do
  @moduledoc """
  The store's half of the phone-call ledger (M94 §09), served by
  `FermixCore.Memory.Repo.phone_calls_call/2`. Only `FermixCore.PhoneCalls.Ledger`
  calls it. Every function that takes a `conn` runs inside the Repo's
  `handle_call`, so the single writer is unchanged; values arrive already
  validated and encoded by the Ledger (in its caller's process), and rows go
  back as raw column values the Ledger decodes, so nothing here can raise on
  what it is handed.

  One row is one admitted call. The table's own CHECKs pin what the state
  vocabulary means: a row past `admitted` carries its dispatch claim, a row
  with a known provider session is the only one that can be `connecting` or
  later, a non-terminal row's outcome is `pending` and a terminal row's never
  is, and `dispatch_unknown` is always `unknown`.

  Every transition is one guarded UPDATE, read back by `changes()`: the
  dispatch claim only from `admitted`, a forward step only from a lower step,
  a terminal write only from a non-terminal row, and a slot release only on an
  uncertain row that still holds it. A guard that matched nothing answers
  what the row is now, so the caller can tell a race from a missing row.
  """

  alias FermixCore.Memory.Repo.KeptSql

  @non_terminal ~w(admitted dispatching connecting ringing active closing)
  @uncertain ~w(dispatch_unknown closure_unconfirmed)
  @terminal ~w(ended failed) ++ @uncertain
  @statuses @non_terminal ++ @terminal
  @outcomes ~w(pending confirmed unavailable options needs_owner unknown)
  @usage_states ~w(provisional voice_duration_confirmed incomplete)
  @report_statuses ~w(pending written delivery_unconfirmed)
  @counters ~w(core_turns dtmf_keys cleanup_attempts)a

  # The forward steps after the session is known, each with the column that
  # stamps when the row reached it. `connecting` is reached only through
  # `record_session` (it means the provider answered the create with a
  # session), so `advance` never targets it.
  @steps [{"ringing", "ringing_at"}, {"active", "answered_at"}, {"closing", "closing_at"}]
  @rank %{"connecting" => 0, "ringing" => 1, "active" => 2, "closing" => 3}

  @columns ~w(
    id request_id owner_id operation authorization access_intent
    origin_kind origin_conversation delivery_mode platform destination thread send_opts_json
    mandate_json mandate_hash model voice prompt_version carrier_profile
    status outcome usage_state report_status provider_session_id carrier_call_id
    created_at dispatch_claimed_at connecting_at ringing_at answered_at closing_at ended_at
    call_deadline_at ringing_deadline_at slot_expires_at cancel_requested_at
    core_turns dtmf_keys cleanup_attempts cleanup_error
    outcome_facts_json evidence_json evidence_pruned_at
    usage_json voice_seconds backend_usage_json failure_reason vendor_message
    slot_released_at slot_release_reason
    delivery_attempts next_delivery_at last_delivery_error delivered_at
  )a

  # What an admission inserts; every other column takes its default.
  @insert_columns ~w(
    id request_id owner_id operation authorization access_intent
    origin_kind origin_conversation delivery_mode platform destination thread send_opts_json
    mandate_json mandate_hash model voice prompt_version carrier_profile status created_at
  )a

  # What a terminal write may set beside `status`. Never the provider's or the
  # carrier's id: each is written once, by its own guarded step.
  @terminal_columns ~w(
    outcome usage_state ended_at
    outcome_facts_json evidence_json usage_json voice_seconds backend_usage_json
    failure_reason vendor_message next_delivery_at
  )a

  # What a report mark may set.
  @report_columns ~w(report_status delivery_attempts next_delivery_at last_delivery_error
                     delivered_at)a

  @select Enum.map_join(@columns, ", ", &Atom.to_string/1)
  @non_terminal_sql Enum.map_join(@non_terminal, ", ", &"'#{&1}'")
  @uncertain_sql Enum.map_join(@uncertain, ", ", &"'#{&1}'")
  @terminal_sql Enum.map_join(@terminal, ", ", &"'#{&1}'")
  @step_names Enum.map(@steps, &elem(&1, 0))

  # A row holds the one-call slot while it is not terminal, or while it is
  # uncertain, not released, and the provider's own bound on the call has not
  # passed since its dispatch claim (`slot_expires_at`).
  @holds_slot_sql """
  (status IN (#{@non_terminal_sql})
    OR (status IN (#{@uncertain_sql}) AND slot_released_at IS NULL AND slot_expires_at > ?))
  """

  @schema_sql """
  CREATE TABLE IF NOT EXISTS phone_calls (
    id TEXT PRIMARY KEY CHECK (
      length(id) = 15 AND id GLOB 'pc_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
    ),
    request_id TEXT NOT NULL CHECK (length(request_id) BETWEEN 1 AND 200),
    owner_id TEXT NOT NULL CHECK (length(owner_id) BETWEEN 1 AND 200),
    operation TEXT NOT NULL CHECK (operation = 'phone_call.start'),
    authorization TEXT NOT NULL CHECK (authorization IN ('direct', 'confirmed')),
    access_intent TEXT,
    origin_kind TEXT NOT NULL CHECK (origin_kind IN ('chat', 'voice')),
    origin_conversation TEXT CHECK (origin_conversation IS NULL OR json_valid(origin_conversation)),
    delivery_mode TEXT NOT NULL CHECK (delivery_mode IN ('origin', 'channel')),
    platform TEXT NOT NULL CHECK (length(platform) >= 1),
    destination TEXT NOT NULL CHECK (length(destination) >= 1),
    thread TEXT,
    send_opts_json TEXT CHECK (send_opts_json IS NULL OR json_valid(send_opts_json)),
    mandate_json TEXT NOT NULL CHECK (json_valid(mandate_json)),
    mandate_hash TEXT NOT NULL CHECK (length(mandate_hash) = 64),
    model TEXT NOT NULL CHECK (length(model) >= 1),
    voice TEXT NOT NULL CHECK (length(voice) >= 1),
    prompt_version TEXT NOT NULL CHECK (length(prompt_version) >= 1),
    carrier_profile TEXT NOT NULL CHECK (length(carrier_profile) >= 1),
    status TEXT NOT NULL CHECK (status IN (#{Enum.map_join(@statuses, ", ", &"'#{&1}'")})),
    outcome TEXT NOT NULL DEFAULT 'pending'
      CHECK (outcome IN (#{Enum.map_join(@outcomes, ", ", &"'#{&1}'")})),
    usage_state TEXT NOT NULL DEFAULT 'provisional'
      CHECK (usage_state IN (#{Enum.map_join(@usage_states, ", ", &"'#{&1}'")})),
    report_status TEXT NOT NULL DEFAULT 'pending'
      CHECK (report_status IN (#{Enum.map_join(@report_statuses, ", ", &"'#{&1}'")})),
    provider_session_id TEXT,
    carrier_call_id TEXT,
    created_at TEXT NOT NULL,
    dispatch_claimed_at TEXT,
    connecting_at TEXT,
    ringing_at TEXT,
    answered_at TEXT,
    closing_at TEXT,
    ended_at TEXT,
    call_deadline_at TEXT,
    ringing_deadline_at TEXT,
    slot_expires_at TEXT,
    cancel_requested_at TEXT,
    core_turns INTEGER NOT NULL DEFAULT 0 CHECK (core_turns >= 0),
    dtmf_keys INTEGER NOT NULL DEFAULT 0 CHECK (dtmf_keys >= 0),
    cleanup_attempts INTEGER NOT NULL DEFAULT 0 CHECK (cleanup_attempts >= 0),
    cleanup_error TEXT,
    outcome_facts_json TEXT CHECK (outcome_facts_json IS NULL OR json_valid(outcome_facts_json)),
    evidence_json TEXT CHECK (evidence_json IS NULL OR json_valid(evidence_json)),
    evidence_pruned_at TEXT,
    usage_json TEXT CHECK (usage_json IS NULL OR json_valid(usage_json)),
    voice_seconds INTEGER CHECK (voice_seconds IS NULL OR voice_seconds >= 0),
    backend_usage_json TEXT CHECK (backend_usage_json IS NULL OR json_valid(backend_usage_json)),
    failure_reason TEXT,
    vendor_message TEXT,
    slot_released_at TEXT,
    slot_release_reason TEXT
      CHECK (slot_release_reason IS NULL OR slot_release_reason = 'verified_termination'),
    delivery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0),
    next_delivery_at TEXT,
    last_delivery_error TEXT,
    delivered_at TEXT,
    CHECK (status IN ('admitted', 'ended', 'failed') OR dispatch_claimed_at IS NOT NULL),
    CHECK (status NOT IN ('connecting', 'ringing', 'active', 'closing')
      OR provider_session_id IS NOT NULL),
    CHECK ((status IN (#{@non_terminal_sql})) = (outcome = 'pending')),
    CHECK (status != 'dispatch_unknown' OR outcome = 'unknown'),
    CHECK (slot_released_at IS NULL OR status IN (#{@uncertain_sql}))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_phone_calls_request ON phone_calls(request_id);
  CREATE INDEX IF NOT EXISTS idx_phone_calls_owner ON phone_calls(owner_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_phone_calls_status ON phone_calls(status, created_at);
  CREATE INDEX IF NOT EXISTS idx_phone_calls_report ON phone_calls(report_status, next_delivery_at);
  """

  @doc "The table and its indexes, as migration 67 lays them down."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc "Every column a row is read back with, in order."
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc "The statuses a call holds while Fermix still owns its lifecycle."
  @spec non_terminal_statuses() :: [String.t()]
  def non_terminal_statuses, do: @non_terminal

  @doc "The terminal statuses whose remote end is not proven: they can hold the slot."
  @spec uncertain_statuses() :: [String.t()]
  def uncertain_statuses, do: @uncertain

  @doc "Every terminal status."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal

  @doc "The outcome words a terminal row may carry (every outcome but `pending`)."
  @spec terminal_outcomes() :: [String.t()]
  def terminal_outcomes, do: @outcomes -- ["pending"]

  @doc "The usage states."
  @spec usage_states() :: [String.t()]
  def usage_states, do: @usage_states

  @doc "The report states."
  @spec report_statuses() :: [String.t()]
  def report_statuses, do: @report_statuses

  @doc "The forward steps `advance` accepts."
  @spec steps() :: [String.t()]
  def steps, do: @step_names

  @doc "The consumed counters."
  @spec counters() :: [atom()]
  def counters, do: @counters

  # --- requests (single-writer process) ------------------------------------

  @spec handle(term(), tuple()) :: term()
  def handle(conn, {:admit, row, %{now: now, window_start: since, max_attempts: max}})
      when is_map(row) and is_binary(now) and is_binary(since) and is_integer(max),
      do: KeptSql.in_transaction(conn, fn -> admit(conn, row, now, since, max) end)

  def handle(conn, {:claim_dispatch, id, fields}) when is_binary(id) and is_map(fields),
    do: claim_dispatch(conn, id, fields)

  def handle(conn, {:record_session, id, session_id, stamp})
      when is_binary(id) and is_binary(session_id) and is_binary(stamp),
      do: record_session(conn, id, session_id, stamp)

  def handle(conn, {:record_carrier_call, id, carrier_call_id})
      when is_binary(id) and is_binary(carrier_call_id),
      do: record_carrier_call(conn, id, carrier_call_id)

  def handle(conn, {:advance, id, step, stamp})
      when is_binary(id) and step in @step_names and is_binary(stamp),
      do: advance(conn, id, step, stamp)

  def handle(conn, {:consume, id, counter, cap})
      when is_binary(id) and counter in @counters and is_integer(cap),
      do: consume(conn, id, counter, cap)

  def handle(conn, {:record_usage, id, usage_json, voice_seconds})
      when is_binary(id) and is_binary(usage_json),
      do: record_usage(conn, id, usage_json, voice_seconds)

  def handle(conn, {:mark_cancel_requested, id, stamp}) when is_binary(id) and is_binary(stamp),
    do: mark_cancel_requested(conn, id, stamp)

  def handle(conn, {:fail_undispatched, id, fields}) when is_binary(id) and is_map(fields),
    do: guarded_update(conn, id, "failed", fields, "status = 'admitted'")

  def handle(conn, {:terminalize, id, status, fields})
      when is_binary(id) and status in @terminal and is_map(fields),
      do: guarded_update(conn, id, status, fields, "status IN (#{@non_terminal_sql})")

  def handle(conn, {:record_cleanup_error, id, text}) when is_binary(id) and is_binary(text),
    do:
      update_returning(conn, "UPDATE phone_calls SET cleanup_error = ? WHERE id = ?", [text, id])

  def handle(conn, {:release_slot, id, reason, stamp})
      when is_binary(id) and reason == "verified_termination" and is_binary(stamp),
      do: release_slot(conn, id, reason, stamp)

  def handle(conn, {:mark_report, id, fields}) when is_binary(id) and is_map(fields),
    do: mark_report(conn, id, fields)

  def handle(conn, {:get, id}) when is_binary(id), do: fetch(conn, id)

  def handle(conn, {:get_for_owner, id, owner_id}) when is_binary(id) and is_binary(owner_id),
    do:
      one(conn, "SELECT #{@select} FROM phone_calls WHERE id = ? AND owner_id = ?", [id, owner_id])

  def handle(conn, {:list_recent, owner_id, limit})
      when is_binary(owner_id) and is_integer(limit) and limit > 0,
      do:
        many(
          conn,
          "SELECT #{@select} FROM phone_calls WHERE owner_id = ? " <>
            "ORDER BY created_at DESC, id DESC LIMIT ?",
          [owner_id, limit]
        )

  def handle(conn, {:outstanding, now}) when is_binary(now),
    do:
      many(
        conn,
        "SELECT #{@select} FROM phone_calls WHERE #{@holds_slot_sql} ORDER BY created_at, id",
        [now]
      )

  def handle(conn, {:unsettled}),
    do:
      many(
        conn,
        "SELECT #{@select} FROM phone_calls WHERE status IN (#{@non_terminal_sql}) " <>
          "ORDER BY created_at, id",
        []
      )

  def handle(conn, {:unresolved, now}) when is_binary(now),
    do:
      many(
        conn,
        "SELECT #{@select} FROM phone_calls WHERE status IN (#{@uncertain_sql}) " <>
          "AND slot_released_at IS NULL AND slot_expires_at > ? ORDER BY created_at, id",
        [now]
      )

  def handle(conn, {:pending_reports, now, limit})
      when is_binary(now) and is_integer(limit) and limit > 0,
      do:
        many(
          conn,
          "SELECT #{@select} FROM phone_calls WHERE report_status = 'pending' " <>
            "AND status IN (#{@terminal_sql}) " <>
            "AND (next_delivery_at IS NULL OR next_delivery_at <= ?) " <>
            "ORDER BY created_at, id LIMIT ?",
          [now, limit]
        )

  def handle(conn, {:prune, now, audit_cutoff, excerpt_cutoff})
      when is_binary(now) and is_binary(audit_cutoff) and is_binary(excerpt_cutoff),
      do: KeptSql.in_transaction(conn, fn -> prune(conn, now, audit_cutoff, excerpt_cutoff) end)

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- admission -------------------------------------------------------------

  # In one BEGIN IMMEDIATE: the request's own call first (a repeated call of
  # one request answers the call it already made, whatever holds the slot),
  # then the slot, then the day's attempts, then the insert. A refusal writes
  # nothing, so it consumes nothing.
  defp admit(conn, row, now, since, max) do
    case one(conn, "SELECT #{@select} FROM phone_calls WHERE request_id = ?", [row.request_id]) do
      {:ok, existing} -> {:ok, {:existing, existing}}
      {:error, :not_found} -> admit_new(conn, row, now, since, max)
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_new(conn, row, now, since, max) do
    with :ok <- slot_free(conn, now),
         :ok <- attempts_left(conn, since, max),
         :ok <- insert(conn, row),
         {:ok, inserted} <- fetch(conn, row.id) do
      {:ok, {:admitted, inserted}}
    end
  end

  defp slot_free(conn, now) do
    sql = "SELECT id FROM phone_calls WHERE #{@holds_slot_sql} ORDER BY created_at, id LIMIT 1"

    case KeptSql.query_all(conn, sql, [now]) do
      {:ok, []} -> :ok
      {:ok, [[holder]]} -> {:error, {:slot_held, holder}}
      {:error, reason} -> {:error, reason}
    end
  end

  # An attempt is consumed by the admission and given back only by a row that
  # is proven never to have dialed: terminal (`ended` or `failed`) with no
  # dispatch claim. Every other row admitted since `since` counts.
  defp attempts_left(conn, since, max) do
    sql = """
    SELECT COUNT(*) FROM phone_calls
    WHERE created_at >= ?
      AND (dispatch_claimed_at IS NOT NULL OR status NOT IN ('ended', 'failed'))
    """

    case KeptSql.query_all(conn, sql, [since]) do
      {:ok, [[count]]} when count < max -> :ok
      {:ok, [[count]]} -> {:error, {:daily_attempts_exhausted, count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert(conn, row) do
    names = Enum.map_join(@insert_columns, ", ", &Atom.to_string/1)
    marks = Enum.map_join(@insert_columns, ", ", fn _column -> "?" end)

    KeptSql.execute(
      conn,
      "INSERT INTO phone_calls (#{names}) VALUES (#{marks})",
      Enum.map(@insert_columns, &Map.fetch!(row, &1))
    )
  end

  # --- non-terminal transitions --------------------------------------------

  defp claim_dispatch(conn, id, fields) do
    sql = """
    UPDATE phone_calls SET status = 'dispatching', dispatch_claimed_at = ?, call_deadline_at = ?,
      ringing_deadline_at = ?, slot_expires_at = ?
    WHERE id = ? AND status = 'admitted'
    """

    params = [
      Map.fetch!(fields, :dispatch_claimed_at),
      Map.fetch!(fields, :call_deadline_at),
      Map.fetch!(fields, :ringing_deadline_at),
      Map.fetch!(fields, :slot_expires_at),
      id
    ]

    changed_or(conn, sql, params, id, fn row -> {:error, {:not_admitted, row.status}} end)
  end

  # The provider's session id is written once, exactly as the provider gave
  # it. The first one moves a dispatching row to `connecting`; the same id
  # again changes nothing; a different one is refused, never overwritten.
  defp record_session(conn, id, session_id, stamp) do
    sql = """
    UPDATE phone_calls SET provider_session_id = ?,
      status = CASE WHEN status = 'dispatching' THEN 'connecting' ELSE status END,
      connecting_at = CASE WHEN status = 'dispatching' THEN ? ELSE connecting_at END
    WHERE id = ? AND provider_session_id IS NULL AND status != 'admitted'
    """

    changed_or(conn, sql, [session_id, stamp, id], id, &session_refusal(&1, session_id))
  end

  defp session_refusal(%{provider_session_id: session_id} = row, session_id), do: {:ok, row}
  defp session_refusal(%{status: "admitted"}, _session_id), do: {:error, :not_dispatched}
  defp session_refusal(_row, _session_id), do: {:error, :session_mismatch}

  defp record_carrier_call(conn, id, carrier_call_id) do
    sql = "UPDATE phone_calls SET carrier_call_id = ? WHERE id = ? AND carrier_call_id IS NULL"

    changed_or(conn, sql, [carrier_call_id, id], id, fn
      %{carrier_call_id: ^carrier_call_id} = row -> {:ok, row}
      _other -> {:error, :carrier_call_mismatch}
    end)
  end

  # Forward only: a step is taken from a lower step, never from itself or a
  # higher one, so a delayed event answers the row as it stands. Ringing is
  # optional: `active` is reached from `connecting` as well.
  defp advance(conn, id, step, stamp) do
    {^step, column} = List.keyfind(@steps, step, 0)
    lower = for {name, rank} <- @rank, rank < Map.fetch!(@rank, step), do: name

    sql = """
    UPDATE phone_calls SET status = ?, #{column} = ?
    WHERE id = ? AND status IN (#{in_list(lower)})
    """

    changed_or(conn, sql, [step, stamp, id], id, &{:ok, &1})
  end

  defp consume(conn, id, counter, cap) do
    sql = "UPDATE phone_calls SET #{counter} = #{counter} + 1 WHERE id = ? AND #{counter} < ?"
    changed_or(conn, sql, [id, cap], id, fn _row -> {:error, {:cap_reached, counter}} end)
  end

  # Cumulative snapshots replace one another and never sum. One reported for
  # less voice time than the row holds is older, and is left out.
  defp record_usage(conn, id, usage_json, voice_seconds) do
    sql = """
    UPDATE phone_calls SET usage_json = ?, voice_seconds = ?
    WHERE id = ? AND status IN (#{@non_terminal_sql})
      AND (voice_seconds IS NULL OR ? IS NULL OR voice_seconds <= ?)
    """

    params = [usage_json, voice_seconds, id, voice_seconds, voice_seconds]
    changed_or(conn, sql, params, id, &{:ok, &1})
  end

  defp mark_cancel_requested(conn, id, stamp) do
    sql = """
    UPDATE phone_calls SET cancel_requested_at = ?
    WHERE id = ? AND cancel_requested_at IS NULL AND status IN (#{@non_terminal_sql})
    """

    changed_or(conn, sql, [stamp, id], id, &{:ok, &1})
  end

  # --- terminal writes ---------------------------------------------------------

  defp guarded_update(conn, id, status, fields, guard) do
    columns = Enum.filter(@terminal_columns, &Map.has_key?(fields, &1))
    assignments = Enum.map_join([:status | columns], ", ", &"#{&1} = ?")
    params = [status | Enum.map(columns, &Map.fetch!(fields, &1))] ++ [id]
    sql = "UPDATE phone_calls SET #{assignments} WHERE id = ? AND #{guard}"

    changed_or(conn, sql, params, id, &terminal_refusal(&1, status))
  end

  defp terminal_refusal(%{status: current}, _status) when current in @terminal,
    do: {:error, :already_terminal}

  defp terminal_refusal(%{status: current}, _status), do: {:error, {:dispatched, current}}

  defp release_slot(conn, id, reason, stamp) do
    sql = """
    UPDATE phone_calls SET slot_released_at = ?, slot_release_reason = ?
    WHERE id = ? AND status IN (#{@uncertain_sql}) AND slot_released_at IS NULL
    """

    changed_or(conn, sql, [stamp, reason, id], id, fn row ->
      {:error, {:not_releasable, row.status}}
    end)
  end

  defp mark_report(conn, id, fields) do
    columns = Enum.filter(@report_columns, &Map.has_key?(fields, &1))
    assignments = Enum.map_join(columns, ", ", &"#{&1} = ?")
    params = Enum.map(columns, &Map.fetch!(fields, &1)) ++ [id]

    update_returning(
      conn,
      "UPDATE phone_calls SET #{assignments} WHERE id = ? AND status IN (#{@terminal_sql})",
      params
    )
  end

  # --- retention ----------------------------------------------------------------

  # Two periods: a terminal row that no longer holds the slot is deleted once
  # it is older than the audit period, and its excerpts are cleared once it
  # ended longer ago than the excerpt period. Both in one transaction.
  defp prune(conn, now, audit_cutoff, excerpt_cutoff) do
    delete = """
    DELETE FROM phone_calls
    WHERE created_at < ? AND status IN (#{@terminal_sql}) AND NOT #{@holds_slot_sql}
    """

    clear = """
    UPDATE phone_calls SET evidence_json = NULL, evidence_pruned_at = ?
    WHERE evidence_json IS NOT NULL AND status IN (#{@terminal_sql})
      AND COALESCE(ended_at, created_at) < ?
    """

    with {:ok, deleted} <- KeptSql.execute_changes(conn, delete, [audit_cutoff, now]),
         {:ok, cleared} <- KeptSql.execute_changes(conn, clear, [now, excerpt_cutoff]) do
      {:ok, %{deleted: deleted, excerpts_cleared: cleared}}
    end
  end

  # --- plumbing ---------------------------------------------------------------

  # Runs a guarded UPDATE; one changed row answers the row as it is now, none
  # answers `refusal` applied to the row (or `:not_found`).
  defp changed_or(conn, sql, params, id, refusal) do
    with {:ok, changed} <- KeptSql.execute_changes(conn, sql, params) do
      case {changed, fetch(conn, id)} do
        {1, {:ok, row}} -> {:ok, row}
        {0, {:ok, row}} -> refusal.(row)
        {_changed, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp update_returning(conn, sql, params) do
    id = List.last(params)

    with {:ok, changed} <- KeptSql.execute_changes(conn, sql, params) do
      case {changed, fetch(conn, id)} do
        {1, {:ok, row}} -> {:ok, row}
        {0, {:ok, row}} -> {:error, {:not_terminal, row.status}}
        {_changed, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp fetch(conn, id), do: one(conn, "SELECT #{@select} FROM phone_calls WHERE id = ?", [id])

  defp one(conn, sql, params) do
    case KeptSql.query_all(conn, sql, params) do
      {:ok, [values | _rest]} -> {:ok, to_row(values)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp many(conn, sql, params) do
    with {:ok, rows} <- KeptSql.query_all(conn, sql, params), do: {:ok, Enum.map(rows, &to_row/1)}
  end

  defp to_row(values), do: @columns |> Enum.zip(values) |> Map.new()

  defp in_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
