defmodule FermixCore.Memory.Repo.TripsSql do
  @moduledoc """
  The store's half of the owner's trips (M89 §05), served by
  `FermixCore.Memory.Repo.trips_call/2`. Every function that takes a `conn`
  runs only from the Repo's `handle_call`, so the single writer is unchanged
  and one `trip_edit` call is one transaction against every other Repo caller.
  What an op means is `FermixCore.Trips.Ops`, a pure module this one hands the
  loaded rows to inside the transaction; this module only reads, writes and
  purges rows.

  A trip is a row of `trips`; its days and stops are rows of `trip_rows`,
  ordered by `position` and numbered by `n`, which the trip's `next_n` hands
  out and never takes back. A removed row or trip keeps its `removed_at`, and
  a stop removed with its day keeps the day's id in `removed_with`: rows
  removed more than 30 days ago are deleted in the same transaction as the
  next edit of their trip, and trips by the sweep when the store opens
  (`{:purge_removed_trips, now}`). A device's edit is applied once by its
  `client_msg_id`, its receipt in the table the lists' edits use, by kind
  (`KeptSql.once/4`). The transaction, the statement helpers and the 30-day
  cutoff are what every kept kind shares (`Memory.Repo.KeptSql`).

  Rows are selected by column name and decoded by name (`decode_row/1`) into
  the map `Trips.Ops` names `row`.
  """

  alias FermixCore.Memory.Repo.KeptSql
  alias FermixCore.Memory.Repo.TemporalSql
  alias FermixCore.Trips.Ops

  @trip_columns ~w(id owner_id agent_id title starts_on timezone position rev next_n created_at
                   updated_at removed_at)a
  @row_columns ~w(id trip_id n kind text note local_time duration_min fixed timezone place_json
                  position added_after_outside_content made_via created_at updated_at removed_at
                  removed_with)a
  @trip_select Enum.map_join(@trip_columns, ", ", &Atom.to_string/1)
  @row_select Enum.map_join(@row_columns, ", ", &Atom.to_string/1)
  @trip_placeholders Enum.map_join(@trip_columns, ", ", fn _column -> "?" end)
  @row_placeholders Enum.map_join(@row_columns, ", ", fn _column -> "?" end)

  @schema_sql """
  CREATE TABLE IF NOT EXISTS trips (
    id TEXT PRIMARY KEY,                           -- "tr_" + ten base32 characters
    owner_id TEXT NOT NULL DEFAULT 'default',
    agent_id TEXT NOT NULL DEFAULT 'main',
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 80),
    starts_on TEXT CHECK (
      starts_on IS NULL OR starts_on GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
    ),
    timezone TEXT CHECK (timezone IS NULL OR length(timezone) BETWEEN 1 AND 64),
    position INTEGER NOT NULL,                     -- order in the picker
    rev INTEGER NOT NULL DEFAULT 0 CHECK (rev >= 0),
    next_n INTEGER NOT NULL DEFAULT 1 CHECK (next_n >= 1),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    removed_at TEXT
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_trips_live_title
    ON trips(owner_id, agent_id, lower(title)) WHERE removed_at IS NULL;
  CREATE INDEX IF NOT EXISTS idx_trips_owner ON trips(owner_id, agent_id, removed_at, position);

  CREATE TABLE IF NOT EXISTS trip_rows (
    id TEXT PRIMARY KEY,                           -- "ti_" + ten base32 characters
    trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    n INTEGER NOT NULL CHECK (n >= 1),             -- the row's number in its trip
    kind TEXT NOT NULL CHECK (kind IN ('day', 'stop')),
    text TEXT NOT NULL CHECK (length(text) <= 200),
    note TEXT CHECK (note IS NULL OR length(note) BETWEEN 1 AND 1000),
    local_time TEXT CHECK (local_time IS NULL OR local_time GLOB '[0-2][0-9]:[0-5][0-9]'),
    duration_min INTEGER CHECK (duration_min IS NULL OR duration_min BETWEEN 1 AND 1440),
    fixed INTEGER NOT NULL DEFAULT 0 CHECK (fixed IN (0, 1)),
    timezone TEXT CHECK (timezone IS NULL OR length(timezone) BETWEEN 1 AND 64),
    place_json TEXT CHECK (
      place_json IS NULL OR (json_valid(place_json) AND length(place_json) <= 4096)
    ),
    position INTEGER NOT NULL,                     -- gaps of 1,024, renumbered when one closes
    added_after_outside_content INTEGER NOT NULL DEFAULT 0 CHECK (
      added_after_outside_content IN (0, 1)
    ),
    made_via TEXT NOT NULL CHECK (made_via IN ('mac', 'phone', 'chat', 'job')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    removed_at TEXT,
    removed_with TEXT CHECK (removed_with IS NULL OR removed_at IS NOT NULL),
    UNIQUE (trip_id, n),
    CHECK (kind = 'stop' OR (length(text) <= 80 AND note IS NULL AND local_time IS NULL
      AND duration_min IS NULL AND fixed = 0 AND place_json IS NULL)),
    CHECK (kind = 'day' OR (length(text) >= 1 AND timezone IS NULL))
  );
  CREATE INDEX IF NOT EXISTS idx_trip_rows_trip ON trip_rows(trip_id, removed_at, position);
  """

  @doc "The two tables and their indexes, as migration 63 creates them."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  # --- requests (single-writer process) ------------------------------------

  @doc "Serves one request about the owner's trips on the Repo's connection."
  @spec handle(term(), tuple()) :: {:ok, term()} | {:error, term()}
  def handle(conn, {:index, owner_id, agent_id}), do: index(conn, owner_id, agent_id)

  def handle(conn, {:read_trip, owner_id, agent_id, ref}),
    do: read_trip(conn, owner_id, agent_id, ref)

  def handle(conn, {:trip_by_id, owner_id, agent_id, trip_id, removed?}),
    do: trip_by_id(conn, owner_id, agent_id, trip_id, removed?)

  def handle(conn, {:edit, owner_id, agent_id, call, edit}),
    do: KeptSql.in_transaction(conn, fn -> edit(conn, {owner_id, agent_id}, call, edit) end)

  def handle(conn, {:device_edit, owner_id, agent_id, client_msg_id, call, edit}) do
    KeptSql.in_transaction(conn, fn ->
      device_edit(conn, {owner_id, agent_id, client_msg_id}, call, edit)
    end)
  end

  def handle(conn, {:purge_removed_trips, %DateTime{} = now}),
    do: KeptSql.in_transaction(conn, fn -> purge_removed_trips(conn, now) end)

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- reads ---------------------------------------------------------------

  # Every live trip with its day and stop counts, in picker order.
  defp index(conn, owner_id, agent_id) do
    sql = """
    SELECT #{prefixed("t", @trip_columns)},
      COALESCE(SUM(CASE WHEN r.kind = 'day' THEN 1 ELSE 0 END), 0),
      COALESCE(SUM(CASE WHEN r.kind = 'stop' THEN 1 ELSE 0 END), 0)
    FROM trips AS t
    LEFT JOIN trip_rows AS r ON r.trip_id = t.id AND r.removed_at IS NULL
    WHERE t.owner_id = ? AND t.agent_id = ? AND t.removed_at IS NULL
    GROUP BY t.id
    ORDER BY t.position, t.id
    """

    with {:ok, rows} <- KeptSql.query_all(conn, sql, [owner_id, agent_id]) do
      {:ok, Enum.map(rows, &counted_trip/1)}
    end
  end

  defp counted_trip(values) do
    {trip_values, [days, stops]} = Enum.split(values, length(@trip_columns))
    trip_values |> decode_trip() |> Map.merge(%{days: days, stops: stops})
  end

  defp read_trip(conn, owner_id, agent_id, ref) do
    with {:ok, trips} <- live_trips(conn, owner_id, agent_id),
         {:ok, trip} <- Ops.resolve(trips, ref),
         {:ok, rows} <- live_rows(conn, trip.id) do
      {:ok, %{trip: trip, rows: rows}}
    end
  end

  # One trip by id, live or removed and not yet swept, with its live rows and,
  # when asked, the rows removed from it in the last 30 days, newest first.
  defp trip_by_id(conn, owner_id, agent_id, trip_id, removed?) do
    sql = "SELECT #{@trip_select} FROM trips WHERE owner_id = ? AND agent_id = ? AND id = ?"

    with {:ok, [values]} <- KeptSql.query_all(conn, sql, [owner_id, agent_id, trip_id]),
         trip = decode_trip(values),
         {:ok, rows} <- live_rows(conn, trip.id),
         {:ok, gone} <- if(removed?, do: removed_rows(conn, trip.id), else: {:ok, []}) do
      {:ok, %{trip: trip, rows: rows, removed_rows: gone}}
    else
      {:ok, []} -> {:error, {:no_such_trip, trip_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_trips(conn, owner_id, agent_id) do
    sql = """
    SELECT #{@trip_select} FROM trips
    WHERE owner_id = ? AND agent_id = ? AND removed_at IS NULL
    ORDER BY position, id
    """

    with {:ok, rows} <- KeptSql.query_all(conn, sql, [owner_id, agent_id]) do
      {:ok, Enum.map(rows, &decode_trip/1)}
    end
  end

  defp removed_trip(_conn, _owner_id, _agent_id, nil), do: {:ok, []}

  defp removed_trip(conn, owner_id, agent_id, trip_id) do
    sql = """
    SELECT #{@trip_select} FROM trips
    WHERE owner_id = ? AND agent_id = ? AND id = ? AND removed_at IS NOT NULL
    """

    with {:ok, rows} <- KeptSql.query_all(conn, sql, [owner_id, agent_id, trip_id]) do
      {:ok, Enum.map(rows, &decode_trip/1)}
    end
  end

  defp live_rows(conn, trip_id) do
    sql = """
    SELECT #{@row_select} FROM trip_rows
    WHERE trip_id = ? AND removed_at IS NULL
    ORDER BY position, n
    """

    with {:ok, rows} <- KeptSql.query_all(conn, sql, [trip_id]) do
      {:ok, Enum.map(rows, &decode_row/1)}
    end
  end

  defp removed_rows(conn, trip_id) do
    sql = """
    SELECT #{@row_select} FROM trip_rows
    WHERE trip_id = ? AND removed_at IS NOT NULL
    ORDER BY removed_at DESC, n
    """

    with {:ok, rows} <- KeptSql.query_all(conn, sql, [trip_id]) do
      {:ok, Enum.map(rows, &decode_row/1)}
    end
  end

  # --- the edit ------------------------------------------------------------

  # Loads the owner's trips and the rows of the trip the call names, hands them
  # to `Ops`, and writes what it changed. Inside `in_transaction/2`, so a
  # refusal of any op leaves every trip as it was.
  defp edit(conn, {owner_id, agent_id}, call, edit) do
    with {:ok, live} <- live_trips(conn, owner_id, agent_id),
         {:ok, gone} <- removed_trip(conn, owner_id, agent_id, Ops.restored_trip(call)),
         trips = live ++ gone,
         id = Ops.referenced(trips, call),
         {:ok, rows} <- rows_of(conn, id, &live_rows/2),
         {:ok, removed} <- removed_of(conn, id, Ops.restores_rows?(call)),
         loaded = %{trips: trips, rows: rows, removed: removed},
         {:ok, result} <- Ops.apply(loaded, call, edit),
         :ok <- write(conn, {owner_id, agent_id}, result, edit.now) do
      {:ok, result}
    end
  end

  defp rows_of(_conn, nil, _read), do: {:ok, []}
  defp rows_of(conn, id, read), do: read.(conn, id)

  defp removed_of(conn, id, true), do: rows_of(conn, id, &removed_rows/2)
  defp removed_of(_conn, _id, false), do: {:ok, []}

  # A device's edit, once (`KeptSql.once/4`): an id already recorded is
  # answered as the duplicate it is, with the trip it changed and what it made,
  # and changes nothing; a new one is applied and recorded in the same
  # transaction.
  defp device_edit(conn, {owner_id, agent_id, client_msg_id}, call, edit) do
    key = {"trip", owner_id, agent_id, client_msg_id}

    apply = fn ->
      with {:ok, result} <- edit(conn, {owner_id, agent_id}, call, edit),
           do: {:ok, result, %{id: result.trip.id, made: result.made}}
    end

    case KeptSql.once(conn, key, edit.now, apply) do
      {:ok, {:applied, result}} ->
        {:ok, {:applied, result}}

      {:ok, {:duplicate, receipt}} ->
        {:ok, {:duplicate, %{trip_id: receipt.id, made: receipt.made}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A call that changed nothing writes nothing. One trip changes per call, so
  # its live title never meets another's mid-call; then its rows, then the
  # purge of its rows removed past the retention.
  defp write(_conn, _owner, %{changed?: false}, _now), do: :ok

  defp write(conn, {owner_id, agent_id}, %{trip: trip} = result, now) do
    with :ok <- write_trip(conn, owner_id, agent_id, trip),
         :ok <- each(dirty_rows(result), &write_row(conn, &1)) do
      purge_rows(conn, trip.id, now)
    end
  end

  defp write_trip(conn, owner_id, agent_id, %{created?: true} = trip) do
    values = trip |> Map.merge(%{owner_id: owner_id, agent_id: agent_id}) |> trip_values()
    sql = "INSERT INTO trips (#{@trip_select}) VALUES (#{@trip_placeholders})"
    KeptSql.execute(conn, sql, values)
  end

  # A trip a call brings back is the one row this update finds removed.
  defp write_trip(conn, _owner_id, _agent_id, trip) do
    live = if Map.get(trip, :restored?, false), do: "IS NOT NULL", else: "IS NULL"

    sql = """
    UPDATE trips SET title = ?, starts_on = ?, timezone = ?, rev = ?, next_n = ?,
      updated_at = ?, removed_at = ?
    WHERE id = ? AND removed_at #{live}
    """

    params = [
      trip.title,
      optional_date(trip.starts_on),
      trip.timezone,
      trip.rev,
      trip.next_n,
      stamp(trip.updated_at),
      optional_stamp(trip.removed_at),
      trip.id
    ]

    expect_one(conn, sql, params, {:trip_gone, trip.id})
  end

  # The live rows an op changed, then the rows it removed, less any added and
  # removed in this same call, which never reach the store.
  defp dirty_rows(result) do
    live = Enum.filter(result.rows, & &1.dirty)
    removed = Enum.reject(result.removed_rows, &(&1.dirty == :new))
    live ++ Enum.map(removed, &Map.put(&1, :dirty, :removed))
  end

  defp write_row(conn, %{dirty: :new} = row) do
    sql = "INSERT INTO trip_rows (#{@row_select}) VALUES (#{@row_placeholders})"
    KeptSql.execute(conn, sql, row_values(row))
  end

  # A row coming back is the one this update finds removed; every other is
  # found live, a removal included.
  defp write_row(conn, row) do
    live = if row.dirty == :restored, do: "IS NOT NULL", else: "IS NULL"

    sql = """
    UPDATE trip_rows SET text = ?, note = ?, local_time = ?, duration_min = ?, fixed = ?,
      timezone = ?, place_json = ?, position = ?, added_after_outside_content = ?,
      updated_at = ?, removed_at = ?, removed_with = ?
    WHERE id = ? AND removed_at #{live}
    """

    params = [
      row.text,
      row.note,
      row.time,
      row.duration,
      bit(row.fixed),
      row.timezone,
      place_json(row.place),
      row.position,
      bit(row.stamped),
      stamp(row.updated_at),
      optional_stamp(row.removed_at),
      row.removed_with,
      row.id
    ]

    expect_one(conn, sql, params, {:row_gone, row.id})
  end

  # Rows of `trip_id` removed more than the retention ago, deleted with the
  # edit that touches their trip: no timer ever purges them.
  defp purge_rows(conn, trip_id, now) do
    KeptSql.execute(
      conn,
      "DELETE FROM trip_rows WHERE trip_id = ? AND removed_at IS NOT NULL AND removed_at < ?",
      [trip_id, KeptSql.cutoff(now)]
    )
  end

  # Every trip removed more than the retention before `now`, its rows with it
  # (the foreign key cascades), answering how many trips went. The Repo runs
  # it once when it opens the store, beside the lists' sweep, and no timer.
  defp purge_removed_trips(conn, now) do
    sql = "DELETE FROM trips WHERE removed_at IS NOT NULL AND removed_at < ? RETURNING 1"

    with {:ok, rows} <- KeptSql.query_all(conn, sql, [KeptSql.cutoff(now)]),
         do: {:ok, length(rows)}
  end

  defp expect_one(conn, sql, params, gone) do
    case KeptSql.execute_changes(conn, sql, params) do
      {:ok, 1} -> :ok
      {:ok, _other} -> {:error, gone}
      {:error, reason} -> {:error, reason}
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- row mapping ---------------------------------------------------------

  defp trip_values(trip) do
    [
      trip.id,
      trip.owner_id,
      trip.agent_id,
      trip.title,
      optional_date(trip.starts_on),
      trip.timezone,
      trip.position,
      trip.rev,
      trip.next_n,
      stamp(trip.created_at),
      stamp(trip.updated_at),
      optional_stamp(trip.removed_at)
    ]
  end

  defp row_values(row) do
    [
      row.id,
      row.trip_id,
      row.n,
      Atom.to_string(row.kind),
      row.text,
      row.note,
      row.time,
      row.duration,
      bit(row.fixed),
      row.timezone,
      place_json(row.place),
      row.position,
      bit(row.stamped),
      row.made_via,
      stamp(row.created_at),
      stamp(row.updated_at),
      optional_stamp(row.removed_at),
      row.removed_with
    ]
  end

  defp decode_trip(values) do
    raw = @trip_columns |> Enum.zip(values) |> Map.new()

    Map.merge(raw, %{
      starts_on: optional_date_parse(raw.starts_on),
      created_at: parse_stamp(raw.created_at),
      updated_at: parse_stamp(raw.updated_at),
      removed_at: optional_parse(raw.removed_at),
      created?: false,
      restored?: false
    })
  end

  @doc """
  One `trip_rows` row, its values in the order of the store's columns, as
  `Trips.Ops` names a `row`: `time` and `duration` for `local_time` and
  `duration_min`, `place` for `place_json` decoded, `stamped` for
  `added_after_outside_content`, and `dirty` nil.
  """
  @spec decode_row([term()]) :: Ops.row()
  def decode_row(values) when is_list(values) and length(values) == length(@row_columns) do
    raw = @row_columns |> Enum.zip(values) |> Map.new()

    %{
      id: raw.id,
      trip_id: raw.trip_id,
      n: raw.n,
      kind: kind(raw.kind),
      text: raw.text,
      note: raw.note,
      time: raw.local_time,
      duration: raw.duration_min,
      fixed: raw.fixed == 1,
      timezone: raw.timezone,
      place: place(raw.place_json),
      position: raw.position,
      stamped: raw.added_after_outside_content == 1,
      made_via: raw.made_via,
      created_at: parse_stamp(raw.created_at),
      updated_at: parse_stamp(raw.updated_at),
      removed_at: optional_parse(raw.removed_at),
      removed_with: raw.removed_with,
      dirty: nil
    }
  end

  defp kind("day"), do: :day
  defp kind("stop"), do: :stop

  defp place(nil), do: nil

  defp place(json) do
    {:ok, place} = Jason.decode(json)
    place
  end

  defp place_json(nil), do: nil
  defp place_json(place), do: Jason.encode!(place)

  defp prefixed(alias_name, columns), do: Enum.map_join(columns, ", ", &"#{alias_name}.#{&1}")

  defp bit(true), do: 1
  defp bit(false), do: 0

  defp optional_date(nil), do: nil
  defp optional_date(%Date{} = date), do: Date.to_iso8601(date)

  defp optional_date_parse(nil), do: nil
  defp optional_date_parse(value), do: Date.from_iso8601!(value)

  defp stamp(%DateTime{} = at) do
    {:ok, value} = TemporalSql.timestamp(at)
    value
  end

  defp optional_stamp(nil), do: nil
  defp optional_stamp(at), do: stamp(at)

  defp parse_stamp(value) do
    {:ok, at, _offset} = DateTime.from_iso8601(value)
    at
  end

  defp optional_parse(nil), do: nil
  defp optional_parse(value), do: parse_stamp(value)
end
