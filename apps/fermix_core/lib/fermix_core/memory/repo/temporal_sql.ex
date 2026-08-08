defmodule FermixCore.Memory.Repo.TemporalSql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s temporal-event operations
  # (MILESTONE_30 §7). Every function takes the caller's `conn` and is invoked
  # only from Repo's `handle_call`s, so the single-writer architecture is
  # unchanged; the split exists to keep `repo.ex` bounded (§7 preamble).
  #
  # Normalization (`normalize_*`) runs in the *caller* process, before the
  # GenServer call, so a bad value fails at the boundary with a clear error
  # instead of inside the single writer.

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Temporal.Planner

  @kinds ~w(birthday anniversary appointment deadline event follow_up explicit_reminder)
  @time_kinds ~w(date datetime)
  @recurrence_kinds ~w(once yearly)
  @leap_policies ~w(feb_28 mar_1)
  @origins ~w(interactive voice)
  @event_statuses ~w(active completed cancelled)

  @max_attempts 5
  @title_max 240
  @description_max 2_000
  @json_max 16_384
  @last_error_max 500
  @sweep_limit 100
  @empty_sweep %{pending: [], failed: [], expired: []}
  @list_default_limit 25
  @list_max_limit 100
  @max_window_days 731
  @far_future "9999-12-31"

  @timestamp_pattern ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/
  @date_pattern ~r/^\d{4}-\d{2}-\d{2}$/

  @event_columns [
    :id,
    :agent_id,
    :owner_id,
    :dedupe_key,
    :title,
    :description,
    :kind,
    :time_kind,
    :local_date,
    :local_time,
    :timezone,
    :occurrence_at,
    :recurrence_kind,
    :recurrence_month,
    :recurrence_day,
    :leap_day_policy,
    :reminder_plan_json,
    :next_occurrence_on,
    :materialized_through_on,
    :delivery_platform,
    :delivery_destination,
    :delivery_thread_scope,
    :revision,
    :status,
    :source_channel,
    :source_chat_id,
    :source_thread_scope,
    :source_session_id,
    :created_by_trust,
    :created_by_origin,
    :created_at,
    :updated_at,
    # APPENDED by migration v19's ALTER (§22.3, post-delivery follow-ups), never
    # inserted mid-list, for the same reason `source_reminder_id` is appended
    # below: a database that reached this column by migrating must have the same
    # column order as one created today.
    :followup
  ]

  @reminder_columns [
    :id,
    :event_id,
    :event_revision,
    :occurrence_key,
    :reminder_rule_id,
    :event_occurrence_at,
    :scheduled_for,
    :ready_at,
    :valid_until,
    :payload_json,
    :delivery_platform,
    :delivery_destination,
    :delivery_thread_scope,
    :status,
    :attempt_count,
    :sent_at,
    :failed_at,
    :last_error,
    :created_at,
    :updated_at,
    # APPENDED by migration v18's ALTER (§20 snooze), never inserted mid-list: a
    # database that reached this column by migrating must have the same column
    # order as one created today.
    :source_reminder_id
  ]

  # Reminder statuses a snooze source may not be in (§20). `delivering` is its
  # own rejection: a send in flight cannot be recalled.
  @terminal_source_statuses ~w(failed expired cancelled)

  # A twin at the requested instant in one of these statuses is a live
  # commitment — scheduled, or already mid-send — so the owner's ask is already
  # true and repeating it must not write.
  @live_snooze_statuses ~w(pending delivering)

  # A twin the scheduler can never fire again. The partial unique index on
  # (source_reminder_id, scheduled_for) is status-blind, so one source deferred
  # to one instant is ONE row whatever state it reached: this row is revived in
  # place rather than replaced by a second insert that cannot exist.
  @revivable_snooze_statuses ~w(cancelled superseded failed expired)

  # Bound on the one-active-snooze cleanup read (§20). More than one pending
  # snooze per source is impossible, so a full page is a broken invariant.
  @supersede_page 10

  # Columns an `event_update` may set (§7.3). `status`, `revision`, provenance,
  # and the horizon caches are owned by the Repo, never by a caller patch.
  @updatable_columns [
    :dedupe_key,
    :title,
    :description,
    :kind,
    :time_kind,
    :local_date,
    :local_time,
    :timezone,
    :occurrence_at,
    :recurrence_kind,
    :recurrence_month,
    :recurrence_day,
    :leap_day_policy,
    :reminder_plan,
    :delivery_platform,
    :delivery_destination,
    :delivery_thread_scope,
    :followup
  ]

  # Columns a create must supply; everything else has an explicit default.
  @required_create_columns [
    :dedupe_key,
    :title,
    :kind,
    :time_kind,
    :timezone,
    :recurrence_kind,
    :reminder_plan_json,
    :delivery_platform,
    :delivery_destination
  ]

  # Fields that decide whether a repeated active create is the *same* event
  # (returned as-is) or an identity collision that must go through
  # `event_update`. Title/description differences are not collisions: the
  # dedupe key already carries the semantic identity.
  @identity_columns [
    :time_kind,
    :local_date,
    :local_time,
    :timezone,
    :occurrence_at,
    :recurrence_kind,
    :recurrence_month,
    :recurrence_day,
    :leap_day_policy,
    :reminder_plan_json,
    :delivery_platform,
    :delivery_destination,
    :delivery_thread_scope
  ]

  @event_select Enum.map_join(@event_columns, ", ", &Atom.to_string/1)
  @event_select_e Enum.map_join(@event_columns, ", ", &("e." <> Atom.to_string(&1)))
  @event_placeholders Enum.map_join(@event_columns, ", ", fn _column -> "?" end)
  @reminder_select Enum.map_join(@reminder_columns, ", ", &Atom.to_string/1)
  @reminder_select_r Enum.map_join(@reminder_columns, ", ", &("r." <> Atom.to_string(&1)))
  @reminder_placeholders Enum.map_join(@reminder_columns, ", ", fn _column -> "?" end)

  @schema_sql """
  CREATE TABLE IF NOT EXISTS temporal_events (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    dedupe_key TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    kind TEXT NOT NULL CHECK (
      kind IN ('birthday', 'anniversary', 'appointment', 'deadline',
               'event', 'follow_up', 'explicit_reminder')
    ),
    time_kind TEXT NOT NULL CHECK (time_kind IN ('date', 'datetime')),
    local_date TEXT,
    local_time TEXT,
    timezone TEXT NOT NULL,
    occurrence_at TEXT,
    recurrence_kind TEXT NOT NULL CHECK (recurrence_kind IN ('once', 'yearly')),
    recurrence_month INTEGER,
    recurrence_day INTEGER,
    leap_day_policy TEXT CHECK (
      leap_day_policy IS NULL OR leap_day_policy IN ('feb_28', 'mar_1')
    ),
    reminder_plan_json TEXT NOT NULL,
    next_occurrence_on TEXT,
    materialized_through_on TEXT,
    delivery_platform TEXT NOT NULL,
    delivery_destination TEXT NOT NULL,
    delivery_thread_scope TEXT NOT NULL DEFAULT 'root',
    revision INTEGER NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'active' CHECK (
      status IN ('active', 'completed', 'cancelled')
    ),
    source_channel TEXT NOT NULL,
    source_chat_id TEXT NOT NULL,
    source_thread_scope TEXT NOT NULL DEFAULT 'root',
    source_session_id TEXT,
    created_by_trust TEXT NOT NULL CHECK (created_by_trust = 'operator'),
    created_by_origin TEXT NOT NULL CHECK (
      created_by_origin IN ('interactive', 'voice')
    ),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_temporal_events_owner_status_next
    ON temporal_events(owner_id, status, next_occurrence_on);
  CREATE UNIQUE INDEX IF NOT EXISTS idx_temporal_events_active_dedupe
    ON temporal_events(owner_id, dedupe_key)
    WHERE status = 'active';
  CREATE INDEX IF NOT EXISTS idx_temporal_events_kind
    ON temporal_events(owner_id, kind);
  CREATE INDEX IF NOT EXISTS idx_temporal_events_annual_horizon
    ON temporal_events(status, recurrence_kind, materialized_through_on, id);

  CREATE TABLE IF NOT EXISTS reminder_occurrences (
    id TEXT PRIMARY KEY,
    event_id TEXT NOT NULL REFERENCES temporal_events(id) ON DELETE RESTRICT,
    event_revision INTEGER NOT NULL,
    occurrence_key TEXT NOT NULL,
    reminder_rule_id TEXT NOT NULL,
    event_occurrence_at TEXT NOT NULL,
    scheduled_for TEXT NOT NULL,
    ready_at TEXT NOT NULL,
    valid_until TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    delivery_platform TEXT NOT NULL,
    delivery_destination TEXT NOT NULL,
    delivery_thread_scope TEXT NOT NULL DEFAULT 'root',
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
      status IN ('pending', 'delivering', 'delivered', 'failed',
                 'expired', 'superseded', 'cancelled')
    ),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 5),
    sent_at TEXT,
    failed_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK (status != 'delivered' OR sent_at IS NOT NULL),
    UNIQUE(event_id, event_revision, occurrence_key, reminder_rule_id)
  );

  CREATE INDEX IF NOT EXISTS idx_reminder_occurrences_due
    ON reminder_occurrences(status, ready_at, id);
  CREATE INDEX IF NOT EXISTS idx_reminder_occurrences_event
    ON reminder_occurrences(event_id, occurrence_key);
  """

  # Snooze (§20), schema-additive on top of the v17 tables. The column is
  # nullable with no default, which is what SQLite requires of an ADD COLUMN
  # carrying a REFERENCES clause while foreign keys are enforced.
  @snooze_schema_sql """
  ALTER TABLE reminder_occurrences
    ADD COLUMN source_reminder_id TEXT
    REFERENCES reminder_occurrences(id) ON DELETE RESTRICT;

  CREATE UNIQUE INDEX IF NOT EXISTS idx_reminder_occurrences_snooze_dedupe
    ON reminder_occurrences(source_reminder_id, scheduled_for)
    WHERE source_reminder_id IS NOT NULL;

  CREATE INDEX IF NOT EXISTS idx_reminder_occurrences_snooze_source
    ON reminder_occurrences(source_reminder_id, status, scheduled_for);

  CREATE INDEX IF NOT EXISTS idx_reminder_occurrences_target_sent
    ON reminder_occurrences(
      delivery_platform, delivery_destination, delivery_thread_scope,
      status, sent_at DESC, id DESC
    );
  """

  # Post-delivery follow-ups (§22.3), schema-additive on top of v17. SQLite
  # stores the flag as 0/1; `event_row/1` is the one place it becomes a boolean.
  # Nothing indexes it: it is read from a row already fetched by id, never
  # selected on.
  @followup_schema_sql """
  ALTER TABLE temporal_events
    ADD COLUMN followup INTEGER NOT NULL DEFAULT 0 CHECK (followup IN (0, 1));
  """

  # The source row plus exactly the parent columns the snooze decisions need.
  # The owner predicate lives in the JOIN: a row belonging to someone else is
  # simply not found, so the lookup cannot confirm its existence either.
  @snooze_parent_columns [:status, :revision, :recurrence_kind, :owner_id, :dedupe_key]

  @snooze_source_sql """
  SELECT #{@reminder_select_r}, #{Enum.map_join(@snooze_parent_columns, ", ", &("e." <> Atom.to_string(&1)))}
  FROM reminder_occurrences r
  JOIN temporal_events e ON e.id = r.event_id
  WHERE r.id = ? AND e.owner_id = ?
  """

  @doc "Schema for the temporal migration."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc "Schema for the additive snooze migration (§20)."
  @spec snooze_schema_sql() :: String.t()
  def snooze_schema_sql, do: @snooze_schema_sql

  @doc "Schema for the additive follow-up-flag migration (§22.3)."
  @spec followup_schema_sql() :: String.t()
  def followup_schema_sql, do: @followup_schema_sql

  @doc "Maximum durable claim cycles for one reminder (§11.4)."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  # --- normalization (caller process) --------------------------------------

  @doc "Serializes a UTC instant to the one fixed-width form used in comparisons."
  @spec timestamp(DateTime.t() | String.t()) :: {:ok, String.t()} | {:error, :not_fixed_width}
  def timestamp(%DateTime{} = value) do
    {:ok,
     value
     |> DateTime.shift_zone!("Etc/UTC")
     |> pad_microseconds()
     |> DateTime.to_iso8601()}
  end

  def timestamp(value) when is_binary(value) do
    if Regex.match?(@timestamp_pattern, value) do
      {:ok, value}
    else
      {:error, :not_fixed_width}
    end
  end

  def timestamp(_value), do: {:error, :not_fixed_width}

  defp pad_microseconds(%DateTime{microsecond: {value, _precision}} = at) do
    %{at | microsecond: {value, 6}}
  end

  @doc "Normalizes the full attribute map for a new event row."
  @spec normalize_event_attrs(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def normalize_event_attrs(attrs, %DateTime{} = now) when is_map(attrs) do
    with {:ok, fields} <- normalize_event_fields(Map.take(attrs, @updatable_columns)),
         :ok <- require_create_columns(fields),
         {:ok, stamp} <- field_timestamp(now, :created_at),
         :ok <- validate_enum(attrs, :created_by_origin, @origins),
         :ok <- validate_trust(attrs) do
      {:ok, base_event_columns(attrs, fields, stamp)}
    end
  end

  defp require_create_columns(fields) do
    case Enum.find(@required_create_columns, &(not Map.has_key?(fields, &1))) do
      nil -> :ok
      key -> {:error, {:missing_field, key}}
    end
  end

  @doc """
  Normalizes an `event_update` patch. Unknown keys are refused; the Repo owns
  status, revision, provenance, and the horizon caches.
  """
  @spec normalize_event_fields(map()) :: {:ok, map()} | {:error, term()}
  def normalize_event_fields(fields) when is_map(fields) do
    with :ok <- reject_unknown_fields(fields),
         {:ok, text} <- normalize_text_fields(fields),
         {:ok, times} <- normalize_time_fields(fields),
         {:ok, enums} <- normalize_enum_fields(fields),
         {:ok, plan} <- normalize_plan_field(fields),
         {:ok, flag} <- normalize_followup_field(fields) do
      {:ok, Map.merge(text, times) |> Map.merge(enums) |> Map.merge(plan) |> Map.merge(flag)}
    end
  end

  @doc """
  Normalizes a `Temporal.Planner` plan into storable rows. Each occurrence must
  carry a caller-assigned `:id`; `ready_at` starts at `scheduled_for`.
  """
  @spec normalize_plan(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def normalize_plan(%{occurrences: occurrences} = plan, %DateTime{} = now)
      when is_list(occurrences) do
    with {:ok, stamp} <- field_timestamp(now, :created_at),
         {:ok, rows} <- normalize_occurrences(occurrences, stamp),
         {:ok, next_on} <- optional_date(Map.get(plan, :next_occurrence_on), :next_occurrence_on),
         {:ok, through_on} <-
           optional_date(Map.get(plan, :materialized_through_on), :materialized_through_on) do
      {:ok,
       %{occurrences: rows, next_occurrence_on: next_on, materialized_through_on: through_on}}
    end
  end

  def normalize_plan(_plan, _now), do: {:error, {:invalid, :plan, :malformed}}

  @doc "Validates a persisted failure reason against the 500-byte cap."
  @spec normalize_error_text(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def normalize_error_text(nil), do: {:ok, nil}

  def normalize_error_text(text) when is_binary(text) do
    if byte_size(text) > @last_error_max do
      {:error, {:invalid, :last_error, :too_long}}
    else
      {:ok, text}
    end
  end

  def normalize_error_text(_text), do: {:error, {:invalid, :last_error, :not_a_string}}

  @doc "Validates and clamps an `event_list` filter (§12.1)."
  @spec normalize_list_filter(map()) :: {:ok, map()} | {:error, term()}
  def normalize_list_filter(filter) when is_map(filter) do
    with {:ok, window} <- normalize_window(filter),
         {:ok, status} <- normalize_list_status(filter),
         {:ok, kind} <- normalize_list_kind(filter),
         {:ok, text} <- normalize_list_text(filter),
         {:ok, floor} <- optional_date(Map.get(filter, :upcoming_from), :upcoming_from),
         {:ok, cursor} <- normalize_cursor(Map.get(filter, :cursor)) do
      {:ok,
       Map.merge(window, %{
         status: status,
         kind: kind,
         cursor: cursor,
         text: text,
         upcoming_from: floor,
         owner_id: Map.get(filter, :owner_id, "default"),
         limit: clamp_limit(Map.get(filter, :limit, @list_default_limit))
       })}
    end
  end

  @doc "Validates a reminder-list filter."
  @spec normalize_reminder_filter(map()) :: {:ok, map()} | {:error, term()}
  def normalize_reminder_filter(filter) when is_map(filter) do
    {:ok,
     %{
       event_id: Map.get(filter, :event_id),
       occurrence_key: Map.get(filter, :occurrence_key),
       status: List.wrap(Map.get(filter, :status, [])),
       limit: clamp_limit(Map.get(filter, :limit, @list_max_limit))
     }}
  end

  @doc """
  Normalizes the attributes of one snooze row (§20): the caller-assigned id, the
  source it defers, the new instant, its validity boundary, the owner asking,
  and whether the source was named outright or resolved from the outbox.
  """
  @spec normalize_snooze_attrs(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def normalize_snooze_attrs(attrs, %DateTime{} = now) when is_map(attrs) do
    with {:ok, selection} <- snooze_selection(attrs),
         {:ok, scheduled_for} <- field_timestamp(Map.get(attrs, :scheduled_for), :scheduled_for),
         {:ok, valid_until} <- field_timestamp(Map.get(attrs, :valid_until), :valid_until),
         :ok <- validate_snooze_window(scheduled_for, valid_until),
         {:ok, stamp} <- field_timestamp(now, :updated_at) do
      {:ok,
       %{
         id: fetch_string!(attrs, :id),
         source_reminder_id: fetch_string!(attrs, :source_reminder_id),
         owner_id: Map.get(attrs, :owner_id, "default"),
         selection: selection,
         scheduled_for: scheduled_for,
         valid_until: valid_until,
         now: stamp
       }}
    end
  end

  defp snooze_selection(attrs) do
    case Map.get(attrs, :selection) do
      selection when selection in [:explicit, :resolved] -> {:ok, selection}
      _other -> {:error, {:invalid, :selection, :unsupported}}
    end
  end

  # Both are fixed-width UTC, so the lexical comparison is the chronological one.
  defp validate_snooze_window(scheduled_for, valid_until) do
    if scheduled_for < valid_until do
      :ok
    else
      {:error, {:invalid, :valid_until, :not_after_scheduled_for}}
    end
  end

  @doc "Validates the target triple and lookback a `snooze that` resolution reads."
  @spec normalize_snooze_target(map()) :: {:ok, map()} | {:error, term()}
  def normalize_snooze_target(target) when is_map(target) do
    with {:ok, platform} <- required_field_text(target, :platform),
         {:ok, destination} <- required_field_text(target, :destination),
         {:ok, thread_scope} <- required_field_text(target, :thread_scope),
         {:ok, since} <- field_timestamp(Map.get(target, :since), :since) do
      {:ok,
       %{
         platform: platform,
         destination: destination,
         thread_scope: thread_scope,
         since: since,
         owner_id: Map.get(target, :owner_id, "default")
       }}
    end
  end

  defp required_field_text(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) -> validate_text(value, key, 1, @title_max)
      _absent -> {:error, {:invalid, key, :empty}}
    end
  end

  @doc "Serializes a keyset cursor pair, or `nil`."
  @spec normalize_cursor(term()) :: {:ok, {String.t(), String.t()} | nil} | {:error, term()}
  def normalize_cursor(nil), do: {:ok, nil}

  def normalize_cursor({deadline, id}) when is_binary(deadline) and is_binary(id) do
    {:ok, {deadline, id}}
  end

  def normalize_cursor(_cursor), do: {:error, {:invalid, :cursor, :malformed}}

  # --- compound operations -------------------------------------------------

  @doc "Creates an event with its planner occurrences in one transaction (§7.1)."
  @spec create_event(term(), map(), map()) ::
          {:ok, {:created | :existing, map(), [map()]}} | {:error, term()}
  def create_event(conn, event, plan) do
    in_transaction(conn, fn -> create_event_in_tx(conn, event, plan) end)
  end

  defp create_event_in_tx(conn, event, plan) do
    case fetch_active_dedupe(conn, event.owner_id, event.dedupe_key) do
      {:ok, nil} -> insert_new_event(conn, event, plan)
      {:ok, existing} -> resolve_existing_event(conn, existing, event)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_new_event(conn, event, plan) do
    row = Map.merge(event, horizon_columns(plan))

    with :ok <- insert_event_row(conn, row),
         {:ok, _inserted} <- insert_occurrences(conn, row, plan.occurrences, 1),
         {:ok, stored} <- fetch_event_raw(conn, event.id),
         {:ok, occurrences} <-
           select_reminders(conn, %{event_id: event.id, limit: @list_max_limit}) do
      {:ok, {:created, event_row(stored), occurrences}}
    end
  end

  # The twin rides back on the refusal. This transaction is the only place that
  # re-read it, and a caller told merely that "something collided" can neither
  # quote the stored date nor ask the owner which of the two events this is.
  defp resolve_existing_event(conn, existing, event) do
    if identical_event?(existing, event) do
      with {:ok, occurrences} <-
             select_reminders(conn, %{event_id: existing.id, limit: @list_max_limit}) do
        {:ok, {:existing, event_row(existing), occurrences}}
      end
    else
      {:error, {:identity_conflict, event_row(existing)}}
    end
  end

  defp identical_event?(existing, event) do
    Enum.all?(@identity_columns, fn column ->
      Map.get(existing, column) == Map.get(event, column)
    end)
  end

  @doc "Applies an `event_update` patch in one transaction (§7.3)."
  @spec update_event(term(), String.t(), map(), map(), String.t()) ::
          {:ok, {map(), [map()]}} | {:error, term()}
  def update_event(conn, id, fields, plan, now) do
    in_transaction(conn, fn -> update_event_in_tx(conn, id, fields, plan, now) end)
  end

  defp update_event_in_tx(conn, id, fields, plan, now) do
    with {:ok, existing} <- fetch_active_event(conn, id),
         :ok <- ensure_no_delivery_in_flight(conn, id),
         revision = existing.revision + 1,
         :ok <- write_event_update(conn, id, fields, plan, revision, now),
         :ok <- cancel_superseded_rows(conn, id, revision, now),
         {:ok, merged} <- fetch_event_raw(conn, id),
         {:ok, _inserted} <- insert_occurrences(conn, merged, plan.occurrences, revision),
         {:ok, rows} <-
           select_reminders(conn, %{event_id: id, revision: revision, limit: @list_max_limit}) do
      {:ok, {event_row(merged), rows}}
    end
  end

  defp write_event_update(conn, id, fields, plan, revision, now) do
    columns = Map.merge(fields, horizon_columns(plan))
    assignments = Enum.map_join(Map.keys(columns), ", ", &"#{&1} = ?")
    params = Enum.map(Map.keys(columns), &Map.fetch!(columns, &1))

    execute(
      conn,
      "UPDATE temporal_events SET #{assignments}, revision = ?, updated_at = ? WHERE id = ?",
      params ++ [revision, now, id]
    )
  end

  defp cancel_superseded_rows(conn, id, revision, now) do
    execute(
      conn,
      """
      UPDATE reminder_occurrences
      SET status = 'cancelled', updated_at = ?
      WHERE event_id = ? AND event_revision < ? AND status = 'pending'
      """,
      [now, id, revision]
    )
  end

  @doc "Soft-cancels an event and its unsent reminders."
  @spec cancel_event(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_event(conn, id, now) do
    in_transaction(conn, fn -> cancel_event_in_tx(conn, id, now) end)
  end

  defp cancel_event_in_tx(conn, id, now) do
    with {:ok, _existing} <- fetch_event_raw(conn, id),
         :ok <- ensure_no_delivery_in_flight(conn, id),
         :ok <- execute_cancel_event(conn, id, now),
         :ok <- execute_cancel_pending(conn, id, now),
         {:ok, cancelled} <- fetch_event_raw(conn, id) do
      {:ok, event_row(cancelled)}
    end
  end

  defp execute_cancel_event(conn, id, now) do
    execute(
      conn,
      "UPDATE temporal_events SET status = 'cancelled', updated_at = ? WHERE id = ?",
      [now, id]
    )
  end

  defp execute_cancel_pending(conn, id, now) do
    execute(
      conn,
      """
      UPDATE reminder_occurrences
      SET status = 'cancelled', updated_at = ?
      WHERE event_id = ? AND status = 'pending'
      """,
      [now, id]
    )
  end

  @doc "Revision-checked, conflict-ignoring materialization (§9.2)."
  @spec materialize(term(), String.t(), pos_integer(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def materialize(conn, id, expected_revision, plan, now) do
    in_transaction(conn, fn -> materialize_in_tx(conn, id, expected_revision, plan, now) end)
  end

  defp materialize_in_tx(conn, id, expected_revision, plan, now) do
    with {:ok, event} <- fetch_event_raw(conn, id),
         :ok <- ensure_revision(event, expected_revision),
         {:ok, inserted} <- insert_occurrences(conn, event, plan.occurrences, expected_revision),
         :ok <- write_horizon(conn, id, plan, now),
         {:ok, advanced} <- fetch_event_raw(conn, id) do
      {:ok, %{inserted: inserted, event: event_row(advanced)}}
    end
  end

  defp ensure_revision(%{status: "active", revision: revision}, expected)
       when revision == expected,
       do: :ok

  defp ensure_revision(_event, _expected), do: {:error, :stale_event_revision}

  defp write_horizon(conn, id, plan, now) do
    execute(
      conn,
      """
      UPDATE temporal_events
      SET next_occurrence_on = ?, materialized_through_on = ?, updated_at = ?
      WHERE id = ?
      """,
      [plan.next_occurrence_on, plan.materialized_through_on, now, id]
    )
  end

  @doc """
  Defers one reminder into a source-linked ad-hoc row, in one transaction (§20).

  In order: re-read the source and its parent under the caller's owner; return
  a live twin at the requested instant untouched; refuse while a sibling snooze
  of this source is mid-send; supersede any other active snooze of this source;
  supersede an explicitly named pending source (a delivered one is history and
  stays delivered); revive a terminal twin at that instant, or insert a new row,
  on the parent's CURRENT revision; and reactivate a completed one-time parent —
  restoring `next_occurrence_on` so the completion scan, which pre-filters on
  that column, can re-complete it once the snooze is terminal.

  The returned id list is every row this transaction moved to `superseded`, so a
  reader can trace each one.
  """
  @spec snooze_reminder(term(), map()) ::
          {:ok, {:created, map(), [String.t()]} | {:existing, map()}} | {:error, term()}
  def snooze_reminder(conn, attrs) do
    in_transaction(conn, fn -> snooze_in_tx(conn, attrs) end)
  end

  defp snooze_in_tx(conn, attrs) do
    with {:ok, source, parent} <- fetch_snooze_source(conn, attrs),
         {:ok, existing} <- fetch_existing_snooze(conn, attrs) do
      resolve_snooze(conn, attrs, source, parent, existing)
    end
  end

  # Idempotent re-snooze: the same source deferred to the same instant is the
  # same LIVE row, and repeating it must not write, supersede, or reactivate
  # anything. A twin that is mid-send is live too — it is about to reach the
  # owner — so it is reported as-is rather than revived under the send.
  defp resolve_snooze(_conn, _attrs, _source, _parent, %{status: status} = existing)
       when status in @live_snooze_statuses do
    {:ok, {:existing, reminder_row(existing)}}
  end

  # A terminal twin is a corpse the scheduler can never fire: reviving it is the
  # only way to honor the ask, because the status-blind unique index makes a
  # second row at that instant impossible. It is a NEW commitment to the owner,
  # so it is reported as `:created`.
  defp resolve_snooze(conn, attrs, source, parent, %{status: status} = existing)
       when status in @revivable_snooze_statuses do
    with :ok <- ensure_no_sibling_delivering(conn, attrs),
         {:ok, superseded} <- supersede_siblings(conn, attrs, source),
         :ok <- revive_snooze_row(conn, attrs, existing, parent),
         :ok <- reactivate_parent(conn, attrs, source, parent),
         {:ok, row} <- fetch_reminder(conn, existing.id) do
      {:ok, {:created, row, superseded}}
    end
  end

  # The only status left is `delivered`, which cannot appear here: a delivered
  # row was sent, so its `scheduled_for` is in the past, and the Registry's
  # `:snooze_in_past` guard refuses a past instant before this transaction
  # opens. Stated as a refusal rather than left as a missing clause — an
  # impossible state must fail this call, not crash the single writer.
  defp resolve_snooze(_conn, _attrs, _source, _parent, %{status: status}) do
    {:error, {:snooze_twin_unexpected_status, status}}
  end

  defp resolve_snooze(conn, attrs, source, parent, nil) do
    with :ok <- ensure_no_sibling_delivering(conn, attrs),
         {:ok, superseded} <- supersede_siblings(conn, attrs, source),
         :ok <- insert_snooze_row(conn, attrs, source, parent),
         :ok <- reactivate_parent(conn, attrs, source, parent),
         {:ok, row} <- fetch_reminder(conn, attrs.id) do
      {:ok, {:created, row, superseded}}
    end
  end

  defp supersede_siblings(conn, attrs, source) do
    with {:ok, snoozes} <- supersede_active_snoozes(conn, attrs),
         {:ok, retired} <- supersede_explicit_source(conn, attrs, source) do
      {:ok, snoozes ++ retired}
    end
  end

  # A sibling snooze of this source that is mid-send cannot be superseded: the
  # channel send is already in flight and cannot be recalled, and a retryable
  # failure returns that row to `pending` — two reminders from one source. Same
  # ask-again contract as `delivery_in_progress` on an event edit. A twin at the
  # requested instant that is itself delivering already returned `{:existing,
  # ...}` above, so every row this can find is a sibling at another instant.
  defp ensure_no_sibling_delivering(conn, attrs) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT 1 FROM reminder_occurrences
             WHERE source_reminder_id = ? AND status = 'delivering' LIMIT 1
             """,
             [attrs.source_reminder_id]
           ) do
      if rows == [], do: :ok, else: {:error, :snooze_delivery_in_progress}
    end
  end

  # Everything a terminal row carries from its dead life is cleared, so the
  # revived row is indistinguishable from a fresh insert: the claim query gates
  # on `attempt_count`, `ready_at`, `valid_until`, and the parent's revision, and
  # a stale value in any of them silently makes the row unclaimable. The
  # revision-qualified UNIQUE tuple cannot collide — either the parent's revision
  # moved, or the only row holding that tuple is this one.
  defp revive_snooze_row(conn, attrs, existing, parent) do
    execute(
      conn,
      """
      UPDATE reminder_occurrences
      SET status = 'pending', attempt_count = 0, last_error = NULL, failed_at = NULL,
          ready_at = scheduled_for, valid_until = ?, event_revision = ?, updated_at = ?
      WHERE id = ?
      """,
      [attrs.valid_until, parent.revision, attrs.now, existing.id]
    )
  end

  defp fetch_snooze_source(conn, attrs) do
    with {:ok, rows} <-
           query_all(conn, @snooze_source_sql, [attrs.source_reminder_id, attrs.owner_id]) do
      case rows do
        [row] -> validate_snooze_source(split_snooze_source(row))
        [] -> {:error, :not_found}
      end
    end
  end

  defp split_snooze_source(values) do
    {reminder_values, parent_values} = Enum.split(values, length(@reminder_columns))
    {raw_reminder(reminder_values), Map.new(Enum.zip(@snooze_parent_columns, parent_values))}
  end

  defp validate_snooze_source({_source, %{status: "cancelled"}}), do: {:error, :parent_cancelled}

  defp validate_snooze_source({%{status: "delivering"}, _parent}),
    do: {:error, :source_delivering}

  defp validate_snooze_source({%{status: status}, _parent})
       when status in @terminal_source_statuses,
       do: {:error, :source_terminal}

  defp validate_snooze_source({source, parent}), do: {:ok, source, parent}

  defp fetch_existing_snooze(conn, attrs) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@reminder_select} FROM reminder_occurrences
             WHERE source_reminder_id = ? AND scheduled_for = ? LIMIT 1
             """,
             [attrs.source_reminder_id, attrs.scheduled_for]
           ) do
      {:ok, first_raw_reminder(rows)}
    end
  end

  defp first_raw_reminder([]), do: nil
  defp first_raw_reminder([row | _rest]), do: raw_reminder(row)

  # At most one active snooze per source (§20): any other still-pending deferral
  # of this reminder loses to the one the owner just asked for. The read is
  # bounded; the UPDATE deliberately is not, so a broken invariant still leaves
  # no orphan pending row behind — it is logged, not hidden.
  defp supersede_active_snoozes(conn, attrs) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT id FROM reminder_occurrences
             WHERE source_reminder_id = ? AND status = 'pending'
             ORDER BY id ASC LIMIT #{@supersede_page}
             """,
             [attrs.source_reminder_id]
           ),
         ids = Enum.map(rows, fn [id] -> id end),
         :ok <- log_supersede_overflow(ids, attrs.source_reminder_id),
         :ok <-
           execute(
             conn,
             """
             UPDATE reminder_occurrences
             SET status = 'superseded', updated_at = ?
             WHERE source_reminder_id = ? AND status = 'pending'
             """,
             [attrs.now, attrs.source_reminder_id]
           ) do
      {:ok, ids}
    end
  end

  defp log_supersede_overflow(ids, _source_id) when length(ids) < @supersede_page, do: :ok

  defp log_supersede_overflow(_ids, source_id) do
    Logger.error(
      "TemporalSql.snooze: reminder #{source_id} has at least #{@supersede_page} pending " <>
        "snoozes. At most one is possible, so the one-active-snooze invariant is broken; " <>
        "every pending row was superseded but only the first #{@supersede_page} are traced."
    )
  end

  # Only an explicitly named pending source is retired — resolution only ever
  # picks a delivered row, and a delivered row is sent history that stays
  # delivered.
  defp supersede_explicit_source(
         conn,
         %{selection: :explicit} = attrs,
         %{status: "pending"} = row
       ) do
    with :ok <-
           execute(
             conn,
             """
             UPDATE reminder_occurrences
             SET status = 'superseded', updated_at = ?
             WHERE id = ? AND status = 'pending'
             """,
             [attrs.now, row.id]
           ) do
      {:ok, [row.id]}
    end
  end

  defp supersede_explicit_source(_conn, _attrs, _source), do: {:ok, []}

  defp insert_snooze_row(conn, attrs, source, parent) do
    execute(
      conn,
      "INSERT INTO reminder_occurrences (#{@reminder_select}) VALUES (#{@reminder_placeholders})",
      snooze_params(attrs, source, parent)
    )
  end

  defp snooze_params(attrs, source, parent) do
    [
      attrs.id,
      source.event_id,
      parent.revision,
      source.occurrence_key,
      snooze_rule_id(attrs),
      source.event_occurrence_at,
      attrs.scheduled_for,
      attrs.scheduled_for,
      attrs.valid_until,
      source.payload_json,
      source.delivery_platform,
      source.delivery_destination,
      source.delivery_thread_scope,
      "pending",
      0,
      nil,
      nil,
      nil,
      attrs.now,
      attrs.now,
      attrs.source_reminder_id
    ]
  end

  # Deterministic, and unique inside the revision-qualified tuple the planner
  # shares: one source deferred to one instant is one rule.
  defp snooze_rule_id(attrs) do
    "snooze:" <> attrs.source_reminder_id <> ":" <> attrs.scheduled_for
  end

  defp reactivate_parent(
         conn,
         attrs,
         source,
         %{status: "completed", recurrence_kind: "once"} = parent
       ) do
    with :ok <- ensure_no_active_twin(conn, parent, source.event_id) do
      execute(
        conn,
        """
        UPDATE temporal_events
        SET status = 'active', next_occurrence_on = ?, updated_at = ?
        WHERE id = ?
        """,
        [source.occurrence_key, attrs.now, source.event_id]
      )
    end
  end

  defp reactivate_parent(_conn, _attrs, _source, _parent), do: :ok

  # The active-dedupe partial unique index made explicit: if this identity is
  # already held by a live event, reactivation is impossible and the WHOLE
  # snooze fails rather than leaving a row attached to a completed parent.
  defp ensure_no_active_twin(conn, parent, event_id) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT 1 FROM temporal_events
             WHERE owner_id = ? AND dedupe_key = ? AND status = 'active' AND id != ? LIMIT 1
             """,
             [parent.owner_id, parent.dedupe_key, event_id]
           ) do
      if rows == [], do: :ok, else: {:error, :dedupe_conflict}
    end
  end

  @doc "Claims at most `limit` due reminders, one `BEGIN IMMEDIATE` per row (§10.2)."
  @spec claim_due(term(), String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def claim_due(conn, now, limit) do
    with {:ok, ids} <- due_reminder_ids(conn, now, limit) do
      claim_each(conn, ids, now)
    end
  end

  defp claim_each(conn, ids, now) do
    Enum.reduce_while(ids, {:ok, []}, &accumulate_claim(conn, &1, &2, now))
  end

  defp accumulate_claim(conn, id, {:ok, acc}, now) do
    case in_transaction(conn, fn -> claim_one(conn, id, now) end) do
      {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
      {:error, :not_claimable} -> {:cont, {:ok, acc}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp claim_one(conn, id, now) do
    with {:ok, raw} <- fetch_claimable(conn, id, now),
         :ok <- write_claim(conn, id, now),
         {:ok, claimed} <- fetch_reminder_raw(conn, raw.id) do
      {:ok, reminder_row(claimed)}
    end
  end

  defp write_claim(conn, id, now) do
    execute(
      conn,
      """
      UPDATE reminder_occurrences
      SET status = 'delivering', attempt_count = attempt_count + 1, updated_at = ?
      WHERE id = ? AND status = 'pending'
      """,
      [now, id]
    )
  end

  @doc "Marks a claimed reminder delivered."
  @spec settle_delivered(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def settle_delivered(conn, id, sent_at) do
    in_transaction(conn, fn ->
      with {:ok, raw} <- fetch_reminder_raw(conn, id),
           :ok <- ensure_delivering(raw) do
        update_reminder(conn, id, %{status: "delivered", sent_at: sent_at, updated_at: sent_at})
      end
    end)
  end

  @doc """
  Settles a failed attempt: `failed` once the attempt cap is exhausted,
  `expired` when the next attempt would not fall strictly inside the validity
  boundary, otherwise `pending` with a later `ready_at` (§11.4) — never an
  unclaimable pending row.
  """
  @spec settle_retry(term(), String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, {:pending | :expired | :failed, map()}} | {:error, term()}
  def settle_retry(conn, id, next_ready_at, last_error, now) do
    in_transaction(conn, fn ->
      with {:ok, raw} <- fetch_reminder_raw(conn, id),
           :ok <- ensure_delivering(raw) do
        apply_retry(conn, raw, next_ready_at, last_error, now)
      end
    end)
  end

  @doc "Marks a claimed reminder terminally failed."
  @spec settle_failed(term(), String.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def settle_failed(conn, id, last_error, now) do
    in_transaction(conn, fn ->
      with {:ok, raw} <- fetch_reminder_raw(conn, id),
           :ok <- ensure_delivering(raw) do
        update_reminder(conn, id, %{
          status: "failed",
          failed_at: now,
          last_error: last_error,
          updated_at: now
        })
      end
    end)
  end

  @doc """
  Settles a row whose worker died (or never started) without settling it. A row
  that is no longer `delivering` is left untouched and reported `:settled` — a
  `:DOWN` after settlement changes nothing (§10.2).
  """
  @spec recover_delivering(term(), String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, {:pending | :expired | :failed | :settled, map()}} | {:error, term()}
  def recover_delivering(conn, id, next_ready_at, last_error, now) do
    in_transaction(conn, fn ->
      with {:ok, raw} <- fetch_reminder_raw(conn, id) do
        recover_row(conn, raw, next_ready_at, last_error, now)
      end
    end)
  end

  defp recover_row(_conn, %{status: status} = raw, _ready, _error, _now)
       when status != "delivering" do
    {:ok, {:settled, reminder_row(raw)}}
  end

  defp recover_row(conn, raw, next_ready_at, last_error, now) do
    apply_retry(conn, raw, next_ready_at, last_error, now)
  end

  # The attempt cap first: a row that just burned its fifth claim is *exhausted*
  # (§11.4 — "on terminal failure or exhaustion, that reminder row becomes
  # failed"), and the delay to a sixth attempt that will never happen says
  # nothing about it. Checking validity first would settle every two-hour
  # reminder `expired` instead, hiding the exhausted row from `event_list`'s
  # delivery summary. Only a row with attempts left expires, because for that
  # row the boundary is the reason there is no next attempt.
  defp apply_retry(conn, raw, next_ready_at, last_error, now) do
    cond do
      raw.attempt_count >= @max_attempts ->
        terminalize(conn, raw.id, "failed", last_error, now)

      next_ready_at >= raw.valid_until ->
        terminalize(conn, raw.id, "expired", last_error, now)

      true ->
        pending_again(conn, raw.id, next_ready_at, last_error, now)
    end
  end

  defp terminalize(conn, id, "failed", last_error, now) do
    with {:ok, row} <-
           update_reminder(conn, id, %{
             status: "failed",
             failed_at: now,
             last_error: last_error,
             updated_at: now
           }) do
      {:ok, {:failed, row}}
    end
  end

  defp terminalize(conn, id, "expired", last_error, now) do
    with {:ok, row} <-
           update_reminder(conn, id, %{status: "expired", last_error: last_error, updated_at: now}) do
      {:ok, {:expired, row}}
    end
  end

  defp pending_again(conn, id, next_ready_at, last_error, now) do
    with {:ok, row} <-
           update_reminder(conn, id, %{
             status: "pending",
             ready_at: next_ready_at,
             last_error: last_error,
             updated_at: now
           }) do
      {:ok, {:pending, row}}
    end
  end

  @doc """
  Boot sweep (§10.2): every row still `delivering` is stranded, so it returns to
  `pending` (keeping its consumed attempt and its `ready_at`), becomes `failed`
  at the attempt cap, or `expired` past its validity boundary.
  """
  @spec sweep_delivering(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def sweep_delivering(conn, now) do
    in_transaction(conn, fn -> sweep_in_tx(conn, now) end)
  end

  defp sweep_in_tx(conn, now) do
    with {:ok, rows} <- select_delivering(conn) do
      Enum.reduce_while(rows, {:ok, @empty_sweep}, &accumulate_sweep(conn, &1, &2, now))
    end
  end

  defp accumulate_sweep(conn, raw, {:ok, acc}, now) do
    case sweep_row(conn, raw, now) do
      {:ok, {bucket, row}} -> {:cont, {:ok, Map.update!(acc, bucket, &(&1 ++ [row.id]))}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp sweep_row(conn, raw, now) do
    cond do
      now >= raw.valid_until ->
        terminalize(conn, raw.id, "expired", raw.last_error, now)

      raw.attempt_count >= @max_attempts ->
        terminalize(conn, raw.id, "failed", raw.last_error, now)

      true ->
        pending_again(conn, raw.id, raw.ready_at, raw.last_error, now)
    end
  end

  @doc """
  One bounded validity-boundary page (§8.3, §9.4): marks passed pending rows
  `superseded` when a later rule of the same occurrence is due and `expired`
  otherwise, then completes passed one-time events whose reminders are all
  terminal. Returns the keyset cursor, or `nil` when the page wrapped.
  """
  @spec reconcile_boundaries(term(), String.t(), {String.t(), String.t()} | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_boundaries(conn, now, cursor, limit) do
    in_transaction(conn, fn -> reconcile_in_tx(conn, now, cursor, limit) end)
  end

  defp reconcile_in_tx(conn, now, cursor, limit) do
    with {:ok, rows} <- select_boundary_page(conn, now, cursor, limit),
         {:ok, marked} <- mark_boundary_rows(conn, rows, now),
         {:ok, completed} <- complete_passed_events(conn, now, limit) do
      {:ok, Map.merge(marked, %{completed_events: completed, cursor: page_cursor(rows, limit)})}
    end
  end

  defp mark_boundary_rows(conn, rows, now) do
    Enum.reduce_while(rows, {:ok, %{expired: [], superseded: []}}, fn raw, {:ok, acc} ->
      case mark_boundary_row(conn, raw, now) do
        {:ok, {bucket, row}} -> {:cont, {:ok, Map.update!(acc, bucket, &(&1 ++ [row.id]))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_boundary_row(conn, raw, now) do
    with {:ok, superseded?} <- later_rule_due?(conn, raw, now) do
      mark_status(conn, raw, superseded?, now)
    end
  end

  defp mark_status(conn, raw, true, now) do
    with {:ok, row} <- update_reminder(conn, raw.id, %{status: "superseded", updated_at: now}) do
      {:ok, {:superseded, row}}
    end
  end

  defp mark_status(conn, raw, false, now) do
    with {:ok, row} <- update_reminder(conn, raw.id, %{status: "expired", updated_at: now}) do
      {:ok, {:expired, row}}
    end
  end

  defp later_rule_due?(conn, raw, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT 1 FROM reminder_occurrences
             WHERE event_id = ? AND occurrence_key = ? AND event_revision = ?
               AND scheduled_for > ? AND scheduled_for <= ? AND status != 'cancelled'
             LIMIT 1
             """,
             [raw.event_id, raw.occurrence_key, raw.event_revision, raw.scheduled_for, now]
           ) do
      {:ok, rows != []}
    end
  end

  defp complete_passed_events(conn, now, limit) do
    with {:ok, candidates} <- select_completion_candidates(conn, now, limit) do
      Enum.reduce_while(candidates, {:ok, []}, &accumulate_completion(conn, &1, &2, now))
    end
  end

  defp accumulate_completion(conn, raw, {:ok, acc}, now) do
    case complete_event(conn, raw, now) do
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # The SQL pre-filter is a superset (a local day can end before or after the
  # UTC day), so the exact boundary is computed here from the stored zone.
  defp complete_event(conn, raw, now) do
    case Planner.event_boundary_at(event_row(raw)) do
      {:ok, boundary} -> complete_if_passed(conn, raw, boundary, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_if_passed(conn, raw, boundary, now) do
    with {:ok, boundary_string} <- timestamp(boundary) do
      write_completion(conn, raw, boundary_string <= now, now)
    end
  end

  defp write_completion(_conn, _raw, false, _now), do: {:ok, nil}

  defp write_completion(conn, raw, true, now) do
    with :ok <-
           execute(
             conn,
             """
             UPDATE temporal_events
             SET status = 'completed', next_occurrence_on = NULL, updated_at = ?
             WHERE id = ? AND status = 'active'
             """,
             [now, raw.id]
           ) do
      {:ok, raw.id}
    end
  end

  # --- reads ---------------------------------------------------------------

  @doc "One bounded annual-horizon page (§9.1)."
  @spec annual_horizon(term(), String.t(), {String.t(), String.t()} | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def annual_horizon(conn, threshold_on, cursor, limit) do
    {cursor_key, cursor_id} = cursor_or_start(cursor)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@event_select}
             FROM temporal_events
             WHERE status = 'active' AND recurrence_kind = 'yearly'
               AND (materialized_through_on IS NULL OR materialized_through_on < ?)
               AND (
                 COALESCE(materialized_through_on, '') > ?
                 OR (COALESCE(materialized_through_on, '') = ? AND id > ?)
               )
             ORDER BY COALESCE(materialized_through_on, '') ASC, id ASC
             LIMIT ?
             """,
             [threshold_on, cursor_key, cursor_key, cursor_id, limit]
           ) do
      raw = Enum.map(rows, &raw_event/1)
      {:ok, %{events: Enum.map(raw, &event_row/1), cursor: event_cursor(raw, limit)}}
    end
  end

  @doc """
  The earliest claimable `ready_at`, or `nil`.

  The predicates are exactly `due_reminder_ids/3`'s minus its `ready_at <= now`:
  a row this query returns but the claim refuses would arm a 0ms timer whose
  tick claims nothing and re-arms at 0ms again. `valid_until > now` is what
  keeps a row the daemon slept through (§10.4) out of that spin.
  """
  @spec next_pending_ready_at(term(), String.t()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def next_pending_ready_at(conn, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT r.ready_at
             FROM reminder_occurrences r
             JOIN temporal_events e ON e.id = r.event_id
             WHERE r.status = 'pending' AND r.attempt_count < #{@max_attempts}
               AND r.valid_until > ?
               AND e.status = 'active' AND e.revision = r.event_revision
             ORDER BY r.ready_at ASC, r.id ASC
             LIMIT 1
             """,
             [now]
           ) do
      {:ok, first_timestamp(rows)}
    end
  end

  defp first_timestamp([]), do: nil
  defp first_timestamp([[value] | _rest]), do: parse_timestamp!(value)

  @doc """
  The most recently delivered reminder in one exact target, or `nil` (§20).

  The predicates are the whole resolution contract: the caller's own owner,
  `delivered` only, a `sent_at` inside the lookback, and the caller's exact
  platform/destination — with the thread component the one place a platform gets
  a say. There is deliberately no looser second attempt: "snooze that" never
  guesses across conversations, owners, or the lookback.

  Slack is that one place. A channel-root `app_mention` carries no `thread_ts`,
  so the adapter keys the conversation by the mention's own `ts`, which is fresh
  for every message — a root-delivered reminder could never be matched by strict
  equality. Slack root messages are visible from every thread in the channel, so
  `root` is inside the caller's visibility class and is matched too, with an
  exact-thread row still winning when both exist. The widening is one-directional
  toward `root`: a reminder delivered into a specific thread still needs that
  exact thread, and no other platform widens at all.
  """
  @spec latest_delivered(term(), map()) :: {:ok, map() | nil} | {:error, term()}
  def latest_delivered(conn, target) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@reminder_select_r}
             FROM reminder_occurrences r
             JOIN temporal_events e ON e.id = r.event_id
             WHERE r.delivery_platform = ? AND r.delivery_destination = ?
               AND #{thread_scope_predicate(target.platform)} AND r.status = 'delivered'
               AND r.sent_at >= ? AND e.owner_id = ?
             ORDER BY CASE WHEN r.delivery_thread_scope = ? THEN 0 ELSE 1 END,
                      r.sent_at DESC, r.id DESC
             LIMIT 1
             """,
             [
               target.platform,
               target.destination,
               target.thread_scope,
               target.since,
               target.owner_id,
               target.thread_scope
             ]
           ) do
      {:ok, first_reminder_row(rows)}
    end
  end

  defp thread_scope_predicate("slack"), do: "r.delivery_thread_scope IN (?, 'root')"
  defp thread_scope_predicate(_platform), do: "r.delivery_thread_scope = ?"

  defp first_reminder_row([]), do: nil
  defp first_reminder_row([row | _rest]), do: row |> raw_reminder() |> reminder_row()

  @doc "Fetches one event row."
  @spec fetch_event(term(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch_event(conn, id) do
    with {:ok, raw} <- fetch_event_raw(conn, id), do: {:ok, event_row(raw)}
  end

  @doc "Fetches one reminder row."
  @spec fetch_reminder(term(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch_reminder(conn, id) do
    with {:ok, raw} <- fetch_reminder_raw(conn, id), do: {:ok, reminder_row(raw)}
  end

  @doc """
  Lists events with the last delivery state and next due reminder per row
  (§12.1), ordered by `(next_occurrence_on, id)` with an opaque keyset cursor.
  """
  @spec list_events(term(), map()) :: {:ok, map()} | {:error, term()}
  def list_events(conn, filter) do
    {where_sql, params} = list_conditions(filter)
    {cursor_key, cursor_id} = cursor_or_start(filter.cursor)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@event_select_e},
               (#{last_delivery_sql("status")}) AS last_delivery_status,
               (#{last_delivery_sql("last_error")}) AS last_delivery_error,
               (#{last_delivery_sql("updated_at")}) AS last_delivery_at,
               (
                 SELECT MIN(r.ready_at) FROM reminder_occurrences r
                 WHERE r.event_id = e.id AND r.status = 'pending'
               ) AS next_reminder_at
             FROM temporal_events e
             WHERE #{where_sql}
               AND (
                 COALESCE(e.next_occurrence_on, '#{@far_future}') > ?
                 OR (COALESCE(e.next_occurrence_on, '#{@far_future}') = ? AND e.id > ?)
               )
             ORDER BY COALESCE(e.next_occurrence_on, '#{@far_future}') ASC, e.id ASC
             LIMIT ?
             """,
             params ++ [cursor_key, cursor_key, cursor_id, filter.limit]
           ) do
      {:ok, listed_events(rows, filter.limit)}
    end
  end

  defp last_delivery_sql(column) do
    """
    SELECT r.#{column} FROM reminder_occurrences r
    WHERE r.event_id = e.id AND r.status IN ('delivered', 'failed')
    ORDER BY r.updated_at DESC, r.id DESC LIMIT 1
    """
  end

  defp listed_events(rows, limit) do
    count = length(@event_columns)

    enriched =
      Enum.map(rows, fn row ->
        {event_values, extras} = Enum.split(row, count)
        raw = raw_event(event_values)
        Map.merge(event_row(raw), delivery_summary(extras))
      end)

    %{events: enriched, cursor: list_cursor(enriched, limit)}
  end

  defp delivery_summary([status, error, delivered_at, next_reminder_at]) do
    %{
      last_delivery_status: status,
      last_delivery_error: error,
      last_delivery_at: parse_optional_timestamp(delivered_at),
      next_reminder_at: parse_optional_timestamp(next_reminder_at)
    }
  end

  @doc "Lists reminder rows for inspection and scheduler reads."
  @spec list_reminders(term(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_reminders(conn, filter), do: select_reminders(conn, filter)

  # --- selects -------------------------------------------------------------

  defp fetch_active_dedupe(conn, owner_id, dedupe_key) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@event_select} FROM temporal_events
             WHERE owner_id = ? AND dedupe_key = ? AND status = 'active' LIMIT 1
             """,
             [owner_id, dedupe_key]
           ) do
      {:ok, first_raw_event(rows)}
    end
  end

  defp first_raw_event([]), do: nil
  defp first_raw_event([row | _rest]), do: raw_event(row)

  defp fetch_event_raw(conn, id) do
    with {:ok, rows} <-
           query_all(conn, "SELECT #{@event_select} FROM temporal_events WHERE id = ?", [id]) do
      case rows do
        [row] -> {:ok, raw_event(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_active_event(conn, id) do
    with {:ok, raw} <- fetch_event_raw(conn, id) do
      ensure_active(raw)
    end
  end

  defp ensure_active(%{status: "active"} = raw), do: {:ok, raw}
  defp ensure_active(_raw), do: {:error, :not_active}

  defp fetch_reminder_raw(conn, id) do
    with {:ok, rows} <-
           query_all(conn, "SELECT #{@reminder_select} FROM reminder_occurrences WHERE id = ?", [
             id
           ]) do
      case rows do
        [row] -> {:ok, raw_reminder(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp ensure_delivering(%{status: "delivering"}), do: :ok
  defp ensure_delivering(_raw), do: {:error, :not_delivering}

  defp ensure_no_delivery_in_flight(conn, id) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT 1 FROM reminder_occurrences WHERE event_id = ? AND status = 'delivering' LIMIT 1",
             [id]
           ) do
      if rows == [], do: :ok, else: {:error, :delivery_in_progress}
    end
  end

  defp due_reminder_ids(conn, now, limit) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT r.id
             FROM reminder_occurrences r
             JOIN temporal_events e ON e.id = r.event_id
             WHERE r.status = 'pending' AND r.attempt_count < #{@max_attempts}
               AND r.ready_at <= ? AND r.valid_until > ?
               AND e.status = 'active' AND e.revision = r.event_revision
             ORDER BY r.ready_at ASC, r.id ASC
             LIMIT ?
             """,
             [now, now, limit]
           ) do
      {:ok, Enum.map(rows, fn [id] -> id end)}
    end
  end

  defp fetch_claimable(conn, id, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@reminder_select_r}
             FROM reminder_occurrences r
             JOIN temporal_events e ON e.id = r.event_id
             WHERE r.id = ? AND r.status = 'pending' AND r.attempt_count < #{@max_attempts}
               AND r.ready_at <= ? AND r.valid_until > ?
               AND e.status = 'active' AND e.revision = r.event_revision
             """,
             [id, now, now]
           ) do
      case rows do
        [row] -> {:ok, raw_reminder(row)}
        [] -> {:error, :not_claimable}
      end
    end
  end

  defp select_delivering(conn) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@reminder_select} FROM reminder_occurrences
             WHERE status = 'delivering' ORDER BY ready_at ASC, id ASC LIMIT #{@sweep_limit}
             """,
             []
           ) do
      {:ok, Enum.map(rows, &raw_reminder/1)}
    end
  end

  defp select_boundary_page(conn, now, cursor, limit) do
    {cursor_key, cursor_id} = cursor_or_start(cursor)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@reminder_select} FROM reminder_occurrences
             WHERE status = 'pending' AND valid_until <= ?
               AND (valid_until > ? OR (valid_until = ? AND id > ?))
             ORDER BY valid_until ASC, id ASC
             LIMIT ?
             """,
             [now, cursor_key, cursor_key, cursor_id, limit]
           ) do
      {:ok, Enum.map(rows, &raw_reminder/1)}
    end
  end

  defp select_completion_candidates(conn, now, limit) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@event_select_e} FROM temporal_events e
             WHERE e.status = 'active' AND e.recurrence_kind = 'once'
               AND e.next_occurrence_on IS NOT NULL AND e.next_occurrence_on <= ?
               AND NOT EXISTS (
                 SELECT 1 FROM reminder_occurrences r
                 WHERE r.event_id = e.id AND r.status IN ('pending', 'delivering')
               )
             ORDER BY e.next_occurrence_on ASC, e.id ASC
             LIMIT ?
             """,
             [String.slice(now, 0, 10), limit]
           ) do
      {:ok, Enum.map(rows, &raw_event/1)}
    end
  end

  defp select_reminders(conn, filter) do
    {where_sql, params} = reminder_conditions(filter)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@reminder_select} FROM reminder_occurrences
             WHERE #{where_sql}
             ORDER BY scheduled_for ASC, id ASC
             LIMIT ?
             """,
             params ++ [Map.get(filter, :limit, @list_max_limit)]
           ) do
      {:ok, Enum.map(rows, &(&1 |> raw_reminder() |> reminder_row()))}
    end
  end

  defp reminder_conditions(filter) do
    [
      {"event_id = ?", Map.get(filter, :event_id)},
      {"occurrence_key = ?", Map.get(filter, :occurrence_key)},
      {"event_revision = ?", Map.get(filter, :revision)}
    ]
    |> Enum.reject(fn {_sql, value} -> is_nil(value) end)
    |> Enum.reduce({["1 = 1"], []}, fn {sql, value}, {clauses, params} ->
      {clauses ++ [sql], params ++ [value]}
    end)
    |> add_status_condition(List.wrap(Map.get(filter, :status, [])))
  end

  defp add_status_condition({clauses, params}, []), do: {Enum.join(clauses, " AND "), params}

  defp add_status_condition({clauses, params}, statuses) do
    placeholders = Enum.map_join(statuses, ", ", fn _status -> "?" end)
    {Enum.join(clauses ++ ["status IN (#{placeholders})"], " AND "), params ++ statuses}
  end

  # `upcoming_from` is the caller's "today" floor for a default listing, and is
  # NULL-safe on purpose: an event whose `next_occurrence_on` cache is missing is
  # a defect to see, not a row to hide. `from` stays a strict window bound.
  defp list_conditions(filter) do
    [
      {"e.owner_id = ?", filter.owner_id},
      {"e.status = ?", filter.status},
      {"e.kind = ?", filter.kind},
      {"(e.next_occurrence_on >= ? OR e.next_occurrence_on IS NULL)", filter[:upcoming_from]},
      {"e.next_occurrence_on >= ?", filter[:from]},
      {"e.next_occurrence_on <= ?", filter[:to]}
    ]
    |> Enum.reject(fn {_sql, value} -> is_nil(value) end)
    |> Enum.reduce({[], []}, fn {sql, value}, {clauses, params} ->
      {clauses ++ [sql], params ++ [value]}
    end)
    |> add_text_condition(filter.text)
  end

  defp add_text_condition({clauses, params}, nil), do: {Enum.join(clauses, " AND "), params}

  defp add_text_condition({clauses, params}, text) do
    pattern = "%" <> escape_like(text) <> "%"

    {
      Enum.join(
        clauses ++
          ["(e.title LIKE ? ESCAPE '\\' OR COALESCE(e.description, '') LIKE ? ESCAPE '\\')"],
        " AND "
      ),
      params ++ [pattern, pattern]
    }
  end

  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # --- writes --------------------------------------------------------------

  defp insert_event_row(conn, event) do
    execute(
      conn,
      "INSERT INTO temporal_events (#{@event_select}) VALUES (#{@event_placeholders})",
      Enum.map(@event_columns, &Map.fetch!(event, &1))
    )
  end

  defp insert_occurrences(conn, event, occurrences, revision) do
    Enum.reduce_while(occurrences, {:ok, 0}, fn row, {:ok, count} ->
      case insert_occurrence(conn, event, row, revision) do
        {:ok, inserted} -> {:cont, {:ok, count + inserted}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_occurrence(conn, event, row, revision) do
    params = [
      row.id,
      event.id,
      revision,
      row.occurrence_key,
      row.reminder_rule_id,
      row.event_occurrence_at,
      row.scheduled_for,
      row.ready_at,
      row.valid_until,
      row.payload_json,
      event.delivery_platform,
      event.delivery_destination,
      event.delivery_thread_scope,
      "pending",
      0,
      nil,
      nil,
      nil,
      row.created_at,
      row.updated_at,
      # A planner row is nobody's snooze; only `snooze_reminder/2` sets the link.
      nil
    ]

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO reminder_occurrences (#{@reminder_select})
             VALUES (#{@reminder_placeholders})
             ON CONFLICT(event_id, event_revision, occurrence_key, reminder_rule_id) DO NOTHING
             """,
             params
           ) do
      Sqlite3.changes(conn)
    end
  end

  defp update_reminder(conn, id, fields) do
    assignments = Enum.map_join(Map.keys(fields), ", ", &"#{&1} = ?")
    params = Enum.map(Map.keys(fields), &Map.fetch!(fields, &1))

    with :ok <-
           execute(
             conn,
             "UPDATE reminder_occurrences SET #{assignments} WHERE id = ?",
             params ++ [id]
           ) do
      fetch_reminder(conn, id)
    end
  end

  # --- row mapping ---------------------------------------------------------

  defp raw_event(values), do: @event_columns |> Enum.zip(values) |> Map.new()
  defp raw_reminder(values), do: @reminder_columns |> Enum.zip(values) |> Map.new()

  defp event_row(raw) do
    raw
    |> Map.drop([:reminder_plan_json])
    |> Map.merge(%{
      local_date: parse_optional_date(raw.local_date),
      local_time: parse_optional_time(raw.local_time),
      occurrence_at: parse_optional_timestamp(raw.occurrence_at),
      next_occurrence_on: parse_optional_date(raw.next_occurrence_on),
      materialized_through_on: parse_optional_date(raw.materialized_through_on),
      reminder_plan: Jason.decode!(raw.reminder_plan_json),
      followup: followup_boolean(raw.followup),
      created_at: parse_timestamp!(raw.created_at),
      updated_at: parse_timestamp!(raw.updated_at)
    })
  end

  # The one integer→boolean point (§22.3), and it is load-bearing: the annual
  # rollover feeds this row straight into the planner, so a raw 0/1 escaping
  # here would snapshot the storage integer into every payload it materializes
  # and read false at the trigger's `== true`. The CHECK admits nothing else, so
  # a third value is a broken database and fails loudly.
  defp followup_boolean(0), do: false
  defp followup_boolean(1), do: true

  defp reminder_row(raw) do
    raw
    |> Map.drop([:payload_json])
    |> Map.merge(%{
      event_occurrence_at: parse_timestamp!(raw.event_occurrence_at),
      scheduled_for: parse_timestamp!(raw.scheduled_for),
      ready_at: parse_timestamp!(raw.ready_at),
      valid_until: parse_timestamp!(raw.valid_until),
      payload: Jason.decode!(raw.payload_json),
      sent_at: parse_optional_timestamp(raw.sent_at),
      failed_at: parse_optional_timestamp(raw.failed_at),
      created_at: parse_timestamp!(raw.created_at),
      updated_at: parse_timestamp!(raw.updated_at)
    })
  end

  defp parse_timestamp!(value) do
    {:ok, at, _offset} = DateTime.from_iso8601(value)
    at
  end

  defp parse_optional_timestamp(nil), do: nil
  defp parse_optional_timestamp(value), do: parse_timestamp!(value)

  defp parse_optional_date(nil), do: nil
  defp parse_optional_date(value), do: Date.from_iso8601!(value)

  defp parse_optional_time(nil), do: nil
  defp parse_optional_time(value), do: Time.from_iso8601!(value)

  # --- cursors -------------------------------------------------------------

  defp cursor_or_start(nil), do: {"", ""}
  defp cursor_or_start({key, id}), do: {key, id}

  defp page_cursor(rows, limit) when length(rows) < limit, do: nil

  defp page_cursor(rows, _limit) do
    last = List.last(rows)
    {last.valid_until, last.id}
  end

  defp event_cursor(rows, limit) when length(rows) < limit, do: nil

  defp event_cursor(rows, _limit) do
    last = List.last(rows)
    {last.materialized_through_on || "", last.id}
  end

  defp list_cursor(rows, limit) when length(rows) < limit, do: nil

  defp list_cursor(rows, _limit) do
    last = List.last(rows)
    {list_cursor_key(last.next_occurrence_on), last.id}
  end

  defp list_cursor_key(nil), do: @far_future
  defp list_cursor_key(%Date{} = date), do: Date.to_iso8601(date)

  # --- normalization helpers -----------------------------------------------

  @optional_create_defaults %{
    description: nil,
    local_date: nil,
    local_time: nil,
    occurrence_at: nil,
    recurrence_month: nil,
    recurrence_day: nil,
    leap_day_policy: nil,
    delivery_thread_scope: "root",
    followup: 0
  }

  defp base_event_columns(attrs, fields, stamp) do
    @optional_create_defaults
    |> Map.merge(fields)
    |> Map.merge(%{
      id: fetch_string!(attrs, :id),
      agent_id: Map.get(attrs, :agent_id, "main"),
      owner_id: Map.get(attrs, :owner_id, "default"),
      next_occurrence_on: nil,
      materialized_through_on: nil,
      revision: 1,
      status: "active",
      source_channel: fetch_string!(attrs, :source_channel),
      source_chat_id: fetch_string!(attrs, :source_chat_id),
      source_thread_scope: Map.get(attrs, :source_thread_scope, "root"),
      source_session_id: Map.get(attrs, :source_session_id),
      created_by_trust: "operator",
      created_by_origin: Map.fetch!(attrs, :created_by_origin),
      created_at: stamp,
      updated_at: stamp
    })
  end

  defp fetch_string!(attrs, key) do
    case Map.fetch!(attrs, key) do
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end

  defp reject_unknown_fields(fields) do
    case Enum.find(Map.keys(fields), &(&1 not in @updatable_columns)) do
      nil -> :ok
      key -> {:error, {:unknown_field, key}}
    end
  end

  defp normalize_text_fields(fields) do
    with {:ok, title} <- bounded_text(fields, :title, 1, @title_max),
         {:ok, description} <- bounded_text(fields, :description, 0, @description_max),
         {:ok, dedupe_key} <- bounded_text(fields, :dedupe_key, 1, @title_max),
         {:ok, timezone} <- bounded_text(fields, :timezone, 1, @title_max),
         {:ok, platform} <- bounded_text(fields, :delivery_platform, 1, @title_max),
         {:ok, destination} <- bounded_text(fields, :delivery_destination, 1, @title_max),
         {:ok, scope} <- bounded_text(fields, :delivery_thread_scope, 1, @title_max) do
      {:ok,
       present_only(fields, %{
         title: title,
         description: description,
         dedupe_key: dedupe_key,
         timezone: timezone,
         delivery_platform: platform,
         delivery_destination: destination,
         delivery_thread_scope: scope
       })}
    end
  end

  defp normalize_time_fields(fields) do
    with {:ok, local_date} <- field_date(fields, :local_date),
         {:ok, local_time} <- field_time(fields, :local_time),
         {:ok, occurrence_at} <- field_optional_timestamp(fields, :occurrence_at) do
      {:ok,
       present_only(fields, %{
         local_date: local_date,
         local_time: local_time,
         occurrence_at: occurrence_at
       })}
    end
  end

  # Keeps only the columns the caller actually supplied, so an `event_update`
  # patch never blanks a stored value it did not mention while an explicit
  # `nil` still clears one.
  defp present_only(fields, normalized) do
    Map.filter(normalized, fn {key, _value} -> Map.has_key?(fields, key) end)
  end

  defp normalize_enum_fields(fields) do
    with :ok <- validate_enum(fields, :kind, @kinds),
         :ok <- validate_enum(fields, :time_kind, @time_kinds),
         :ok <- validate_enum(fields, :recurrence_kind, @recurrence_kinds),
         :ok <- validate_optional_enum(fields, :leap_day_policy, @leap_policies),
         :ok <- validate_month_day(fields) do
      {:ok,
       Map.take(fields, [
         :kind,
         :time_kind,
         :recurrence_kind,
         :leap_day_policy,
         :recurrence_month,
         :recurrence_day
       ])}
    end
  end

  defp normalize_plan_field(fields) do
    case Map.fetch(fields, :reminder_plan) do
      :error -> {:ok, %{}}
      {:ok, plan} -> encode_bounded_json(plan, :reminder_plan, :reminder_plan_json)
    end
  end

  # The one boolean→integer point (§22.3). Callers above this module deal only
  # in booleans, so anything else is a caller bug and is refused rather than
  # coerced: a coerced value is how a flag turns into a silent `false`.
  defp normalize_followup_field(fields) do
    case Map.fetch(fields, :followup) do
      :error -> {:ok, %{}}
      {:ok, true} -> {:ok, %{followup: 1}}
      {:ok, false} -> {:ok, %{followup: 0}}
      {:ok, other} -> {:error, {:invalid, :followup, other}}
    end
  end

  defp encode_bounded_json(value, field, column) when is_list(value) or is_map(value) do
    json = Jason.encode!(value)

    if byte_size(json) > @json_max do
      {:error, {:invalid, field, :too_large}}
    else
      {:ok, %{column => json}}
    end
  end

  defp encode_bounded_json(_value, field, _column), do: {:error, {:invalid, field, :malformed}}

  defp normalize_occurrences(occurrences, stamp) do
    Enum.reduce_while(occurrences, {:ok, []}, fn occurrence, {:ok, acc} ->
      case normalize_occurrence(occurrence, stamp) do
        {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_occurrence(occurrence, stamp) do
    with {:ok, event_at} <- field_timestamp(occurrence.event_occurrence_at, :event_occurrence_at),
         {:ok, scheduled_for} <- field_timestamp(occurrence.scheduled_for, :scheduled_for),
         {:ok, valid_until} <- field_timestamp(occurrence.valid_until, :valid_until),
         {:ok, payload} <- encode_bounded_json(occurrence.payload, :payload, :payload_json) do
      {:ok,
       %{
         id: fetch_string!(occurrence, :id),
         occurrence_key: fetch_string!(occurrence, :occurrence_key),
         reminder_rule_id: fetch_string!(occurrence, :reminder_rule_id),
         event_occurrence_at: event_at,
         scheduled_for: scheduled_for,
         ready_at: scheduled_for,
         valid_until: valid_until,
         payload_json: Map.fetch!(payload, :payload_json),
         created_at: stamp,
         updated_at: stamp
       }}
    end
  end

  defp bounded_text(fields, key, min_bytes, max_bytes) do
    case Map.fetch(fields, key) do
      :error -> {:ok, nil}
      {:ok, nil} when min_bytes == 0 -> {:ok, nil}
      {:ok, value} -> validate_text(value, key, min_bytes, max_bytes)
    end
  end

  defp validate_text(value, key, min_bytes, max_bytes) when is_binary(value) do
    cond do
      byte_size(value) < min_bytes -> {:error, {:invalid, key, :empty}}
      byte_size(value) > max_bytes -> {:error, {:invalid, key, :too_long}}
      true -> {:ok, value}
    end
  end

  defp validate_text(_value, key, _min_bytes, _max_bytes),
    do: {:error, {:invalid, key, :not_a_string}}

  defp field_date(fields, key) do
    case Map.fetch(fields, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, %Date{} = date} -> {:ok, Date.to_iso8601(date)}
      {:ok, value} -> validate_date_string(value, key)
    end
  end

  defp validate_date_string(value, key) when is_binary(value) do
    if Regex.match?(@date_pattern, value) do
      {:ok, value}
    else
      {:error, {:invalid, key, :not_a_date}}
    end
  end

  defp validate_date_string(_value, key), do: {:error, {:invalid, key, :not_a_date}}

  defp optional_date(nil, _key), do: {:ok, nil}
  defp optional_date(%Date{} = date, _key), do: {:ok, Date.to_iso8601(date)}
  defp optional_date(value, key), do: validate_date_string(value, key)

  defp field_time(fields, key) do
    case Map.fetch(fields, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, %Time{} = time} -> {:ok, Time.to_iso8601(time)}
      {:ok, _value} -> {:error, {:invalid, key, :not_a_time}}
    end
  end

  defp field_optional_timestamp(fields, key) do
    case Map.fetch(fields, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> field_timestamp(value, key)
    end
  end

  defp field_timestamp(value, key) do
    case timestamp(value) do
      {:ok, string} -> {:ok, string}
      {:error, :not_fixed_width} -> {:error, {:invalid, key, :not_fixed_width}}
    end
  end

  defp validate_enum(fields, key, allowed) do
    case Map.fetch(fields, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> membership(value, key, allowed)
      {:ok, _value} -> {:error, {:invalid, key, :not_a_string}}
    end
  end

  defp validate_optional_enum(fields, key, allowed) do
    case Map.get(fields, key) do
      nil -> :ok
      value -> membership(value, key, allowed)
    end
  end

  defp membership(value, key, allowed) do
    if value in allowed, do: :ok, else: {:error, {:invalid, key, :unsupported}}
  end

  defp validate_trust(attrs) do
    case Map.get(attrs, :created_by_trust) do
      "operator" -> :ok
      _other -> {:error, {:invalid, :created_by_trust, :unsupported}}
    end
  end

  defp validate_month_day(fields) do
    with :ok <- validate_optional_range(fields, :recurrence_month, 1..12) do
      validate_optional_range(fields, :recurrence_day, 1..31)
    end
  end

  defp validate_optional_range(fields, key, range) do
    case Map.get(fields, key) do
      nil -> :ok
      value when is_integer(value) -> range_membership(value, key, range)
      _value -> {:error, {:invalid, key, :not_an_integer}}
    end
  end

  defp range_membership(value, key, range) do
    if value in range, do: :ok, else: {:error, {:invalid, key, :out_of_range}}
  end

  defp normalize_window(filter) do
    with {:ok, from} <- optional_date(Map.get(filter, :from), :from),
         {:ok, to} <- optional_date(Map.get(filter, :to), :to) do
      validate_window(from, to)
    end
  end

  defp validate_window(nil, to), do: {:ok, %{from: nil, to: to}}
  defp validate_window(from, nil), do: {:ok, %{from: from, to: nil}}

  defp validate_window(from, to) do
    days = Date.diff(Date.from_iso8601!(to), Date.from_iso8601!(from))

    cond do
      days < 0 -> {:error, :invalid_date_window}
      days > @max_window_days -> {:error, :date_window_too_wide}
      true -> {:ok, %{from: from, to: to}}
    end
  end

  defp normalize_list_status(filter) do
    case Map.get(filter, :status, "active") do
      :any -> {:ok, nil}
      value when value in @event_statuses -> {:ok, value}
      _other -> {:error, {:invalid, :status, :unsupported}}
    end
  end

  # `event_list` copies this straight out of model JSON, so it reaches the
  # LIKE-escaper as whatever the model wrote. Every sibling filter field is
  # validated here, in the caller's process; an unvalidated one raises inside
  # the single writer and takes the Repo — and every `:rest_for_one` child after
  # it — down with it.
  defp normalize_list_text(filter) do
    case Map.get(filter, :text) do
      nil -> {:ok, nil}
      text when is_binary(text) and byte_size(text) <= @title_max -> {:ok, text}
      text when is_binary(text) -> {:error, {:invalid, :text, :too_long}}
      _other -> {:error, {:invalid, :text, :not_a_string}}
    end
  end

  defp normalize_list_kind(filter) do
    case Map.get(filter, :kind) do
      nil -> {:ok, nil}
      value when value in @kinds -> {:ok, value}
      _other -> {:error, {:invalid, :kind, :unsupported}}
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @list_max_limit)

  defp clamp_limit(_limit), do: @list_default_limit

  defp horizon_columns(plan) do
    %{
      next_occurrence_on: plan.next_occurrence_on,
      materialized_through_on: plan.materialized_through_on
    }
  end

  # --- sqlite plumbing -----------------------------------------------------

  # A failed BEGIN (including :busy) leaves no open transaction, so that is the
  # only path allowed to return without ROLLBACK. Every failure after a
  # successful BEGIN — the wrapped work or COMMIT itself — must roll back, or
  # the single writer's one connection is left inside an open BEGIN IMMEDIATE.
  defp in_transaction(conn, fun) do
    case execute(conn, "BEGIN IMMEDIATE", []) do
      :ok -> settle_transaction(conn, fun.())
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_transaction(conn, {:ok, _value} = result) do
    case execute(conn, "COMMIT", []) do
      :ok -> result
      {:error, reason} -> rollback(conn, reason)
    end
  end

  defp settle_transaction(conn, {:error, reason}), do: rollback(conn, reason)

  defp rollback(conn, reason) do
    case execute(conn, "ROLLBACK", []) do
      :ok ->
        {:error, reason}

      {:error, rollback_error} ->
        Logger.error(
          "Temporal transaction rollback failed: #{inspect(rollback_error)} " <>
            "(original error: #{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  defp query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        Sqlite3.fetch_all(conn, stmt)
      end
    end)
  end

  defp execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        step_result(Sqlite3.step(conn, stmt))
      end
    end)
  end

  defp bind(_stmt, []), do: :ok
  defp bind(stmt, params), do: Sqlite3.bind(stmt, params)

  defp step_result(:done), do: :ok
  defp step_result(:busy), do: {:error, :busy}
  defp step_result({:row, _row}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}

  defp with_statement(conn, sql, fun) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} -> release_after(conn, stmt, fun.(stmt))
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_after(conn, stmt, result) do
    case Sqlite3.release(conn, stmt) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
