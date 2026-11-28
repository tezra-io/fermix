defmodule FermixTestSupport.PhoneCallStores do
  @moduledoc """
  A phone-call store as an earlier migration left it, made from a store at
  the latest schema with its calls kept, for the tests that reopen it on the
  migrations after.

    * `as_67!/1`: the table as migration 67 first laid it down: the columns
      67 never had gone, the slot released on verified termination alone, a
      call reused by its request alone, no `finished` outcome, and versions
      68 and 77 forgotten.
    * `as_68!/1`: the table as migration 68 rebuilt it, before a call could
      read `finished`: every column kept, the outcome's CHECK without the
      word, and version 77 forgotten.

  The Repo on `db_path` must be stopped.
  """

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo.PhoneCallsSql

  @later ~w(outcome_uncertainty closed_at closure_reason parent_session)
  # The four lines the table's definition gained after 67, exactly as stored.
  @later_lines """
    outcome_uncertainty TEXT
      CHECK (outcome_uncertainty IS NULL OR length(outcome_uncertainty) <= 500),
    closed_at TEXT,
    closure_reason TEXT CHECK (closure_reason IS NULL OR length(closure_reason) <= 120),
    parent_session TEXT,
  """
  @wide "slot_release_reason IN ('verified_termination', 'owner_confirmed')"
  @narrow "slot_release_reason = 'verified_termination'"
  # The outcome word 77 added to the CHECK, as the definition lists it.
  @finished ", 'finished'"
  @indexes_67 [
    "CREATE UNIQUE INDEX idx_phone_calls_request ON phone_calls(request_id)",
    "CREATE INDEX idx_phone_calls_owner ON phone_calls(owner_id, created_at DESC)",
    "CREATE INDEX idx_phone_calls_status ON phone_calls(status, created_at)",
    "CREATE INDEX idx_phone_calls_report ON phone_calls(report_status, next_delivery_at)"
  ]

  @doc "Puts the store at `db_path` back to migration 67's table, every call kept."
  @spec as_67!(String.t()) :: :ok
  def as_67!(db_path) when is_binary(db_path) do
    {:ok, conn} = Sqlite3.open(db_path)
    ddl = conn |> table_ddl!() |> without_finished!() |> ddl_67!()
    copied = PhoneCallsSql.columns() |> Enum.map(&Atom.to_string/1) |> Kernel.--(@later)

    statements =
      remade(ddl, Enum.join(copied, ", ")) ++
        @indexes_67 ++ ["DELETE FROM schema_migrations WHERE version IN (68, 77)"]

    Enum.each(statements, &(:ok = Sqlite3.execute(conn, &1)))
    :ok = Sqlite3.close(conn)
  end

  @doc "Puts the store at `db_path` back to migration 68's table, every call kept."
  @spec as_68!(String.t()) :: :ok
  def as_68!(db_path) when is_binary(db_path) do
    {:ok, conn} = Sqlite3.open(db_path)
    ddl = conn |> table_ddl!() |> without_finished!()
    columns = Enum.map_join(PhoneCallsSql.columns(), ", ", &Atom.to_string/1)

    indexes =
      conn
      |> rows!(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'phone_calls' " <>
          "AND sql IS NOT NULL ORDER BY name"
      )
      |> List.flatten()

    statements =
      remade(ddl, columns) ++
        indexes ++ ["DELETE FROM schema_migrations WHERE version = 77"]

    Enum.each(statements, &(:ok = Sqlite3.execute(conn, &1)))
    :ok = Sqlite3.close(conn)
  end

  @doc "The `phone_calls` table's stored definition and its indexes' names and SQL."
  @spec schema!(String.t()) :: [[String.t() | nil]]
  def schema!(db_path) when is_binary(db_path) do
    {:ok, conn} = Sqlite3.open(db_path)

    rows =
      rows!(
        conn,
        "SELECT type, name, sql FROM sqlite_master WHERE tbl_name = 'phone_calls' ORDER BY name"
      )

    :ok = Sqlite3.close(conn)
    rows
  end

  # The table made again from `ddl`, `columns` copied across, the old one
  # dropped with its indexes.
  defp remade(ddl, columns) do
    [
      "ALTER TABLE phone_calls RENAME TO phone_calls_latest",
      ddl,
      "INSERT INTO phone_calls (#{columns}) SELECT #{columns} FROM phone_calls_latest",
      "DROP TABLE phone_calls_latest"
    ]
  end

  defp table_ddl!(conn) do
    [[ddl]] =
      rows!(conn, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'phone_calls'")

    ddl
  end

  defp without_finished!(ddl) do
    [before, after_word] = String.split(ddl, @finished)
    before <> after_word
  end

  defp ddl_67!(ddl) do
    [before, after_later] = String.split(ddl, @later_lines)
    [narrowed_before, narrowed_after] = String.split(before <> after_later, @wide)
    narrowed_before <> @narrow <> narrowed_after
  end

  defp rows!(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end
end
