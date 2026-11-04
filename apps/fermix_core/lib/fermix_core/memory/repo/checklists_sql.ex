defmodule FermixCore.Memory.Repo.ChecklistsSql do
  @moduledoc false
  # Private SQL for the owner's lists (MILESTONE_85 §06), served by
  # `FermixCore.Memory.Repo.checklists_call/2`. Every function that takes a
  # `conn` runs only from the Repo's `handle_call`, so the single writer is
  # unchanged and one `checklist_edit` call is one transaction against every
  # other Repo caller. What an op means is `FermixCore.Checklists.Ops`, a pure
  # module this one hands the loaded rows to inside the transaction; this
  # module only reads, writes and purges rows.
  #
  # A list is a row of `checklists`; its sections and items are rows of
  # `checklist_items`, ordered by `position` and numbered by `n`, which the
  # list's `next_n` hands out and never takes back. A removed row or list keeps
  # its `removed_at`: rows removed more than 30 days ago are deleted in the
  # same transaction as the next edit of their list, and lists by the boot
  # sweep (`purge_removed_lists/2`). Rows are selected by column name and
  # decoded by name.

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Checklists.Ops
  alias FermixCore.Memory.Repo.TemporalSql

  @list_columns ~w(id owner_id agent_id title folder position rev next_n created_at updated_at
                   removed_at)a
  @item_columns ~w(id checklist_id n kind text note done done_at position
                   added_after_outside_content made_via created_at updated_at removed_at)a
  @list_select Enum.map_join(@list_columns, ", ", &Atom.to_string/1)
  @item_select Enum.map_join(@item_columns, ", ", &Atom.to_string/1)
  @item_placeholders Enum.map_join(@item_columns, ", ", fn _column -> "?" end)
  @list_placeholders Enum.map_join(@list_columns, ", ", fn _column -> "?" end)
  @retention_seconds 30 * 86_400

  @schema_sql """
  CREATE TABLE IF NOT EXISTS checklists (
    id TEXT PRIMARY KEY,                           -- "ck_" + ten base32 characters
    owner_id TEXT NOT NULL DEFAULT 'default',
    agent_id TEXT NOT NULL DEFAULT 'main',
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 80),
    folder TEXT CHECK (folder IS NULL OR length(folder) BETWEEN 1 AND 40),
    position INTEGER NOT NULL,                     -- order in the picker
    rev INTEGER NOT NULL DEFAULT 0 CHECK (rev >= 0),
    next_n INTEGER NOT NULL DEFAULT 1 CHECK (next_n >= 1),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    removed_at TEXT
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_checklists_live_title
    ON checklists(owner_id, agent_id, lower(title)) WHERE removed_at IS NULL;
  CREATE INDEX IF NOT EXISTS idx_checklists_owner
    ON checklists(owner_id, agent_id, removed_at, position);

  CREATE TABLE IF NOT EXISTS checklist_items (
    id TEXT PRIMARY KEY,                           -- "ci_" + ten base32 characters
    checklist_id TEXT NOT NULL REFERENCES checklists(id) ON DELETE CASCADE,
    n INTEGER NOT NULL CHECK (n >= 1),             -- the row's number in its list
    kind TEXT NOT NULL CHECK (kind IN ('item', 'section')),
    text TEXT NOT NULL CHECK (length(text) BETWEEN 1 AND 280),
    note TEXT CHECK (note IS NULL OR length(note) BETWEEN 1 AND 1000),
    done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
    done_at TEXT,
    position INTEGER NOT NULL,                     -- gaps of 1,024, renumbered when one closes
    added_after_outside_content INTEGER NOT NULL DEFAULT 0 CHECK (
      added_after_outside_content IN (0, 1)
    ),
    made_via TEXT NOT NULL CHECK (made_via IN ('mac', 'phone', 'chat', 'job')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    removed_at TEXT,
    UNIQUE (checklist_id, n),
    CHECK (kind = 'item' OR (note IS NULL AND done = 0)),
    CHECK ((done = 1) = (done_at IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS idx_checklist_items_list
    ON checklist_items(checklist_id, removed_at, position);
  """

  # Migration 57 (M85 §07): each edit a device sent, by its `client_msg_id`,
  # so one sent again (a reconnect, an outbox's replay) is answered as a
  # duplicate and changes nothing. Kept 30 days, deleted with a later device
  # edit, and naming the list it changed and the id an add or create made.
  @edits_schema_sql """
  CREATE TABLE IF NOT EXISTS checklist_edits (
    owner_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    client_msg_id TEXT NOT NULL CHECK (length(client_msg_id) BETWEEN 1 AND 128),
    checklist_id TEXT NOT NULL,
    made_id TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (owner_id, agent_id, client_msg_id)
  );
  CREATE INDEX IF NOT EXISTS idx_checklist_edits_created ON checklist_edits(created_at);
  """

  @doc "The two tables and their indexes, as migration 56 creates them."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc "The device edits' table, as migration 57 creates it."
  @spec edits_schema_sql() :: String.t()
  def edits_schema_sql, do: @edits_schema_sql

  @doc "How long a removed row or list is kept before it is deleted, in seconds."
  @spec retention_seconds() :: pos_integer()
  def retention_seconds, do: @retention_seconds

  # --- requests (single-writer process) ------------------------------------

  @spec handle(term(), tuple()) :: {:ok, term()} | {:error, term()}
  def handle(conn, {:index, owner_id, agent_id}), do: index(conn, owner_id, agent_id)

  def handle(conn, {:names, owner_id, agent_id}), do: live_lists(conn, owner_id, agent_id)

  def handle(conn, {:read_list, owner_id, agent_id, ref}),
    do: read_list(conn, owner_id, agent_id, ref)

  def handle(conn, {:read_folder, owner_id, agent_id, folder}),
    do: read_folder(conn, owner_id, agent_id, folder)

  def handle(conn, {:edit, owner_id, agent_id, changes, edit}),
    do: in_transaction(conn, fn -> edit(conn, owner_id, agent_id, changes, edit) end)

  def handle(conn, {:list_by_id, owner_id, agent_id, list_id, removed?}),
    do: list_by_id(conn, owner_id, agent_id, list_id, removed?)

  def handle(conn, {:device_edit, owner_id, agent_id, client_msg_id, changes, edit}) do
    in_transaction(conn, fn ->
      device_edit(conn, {owner_id, agent_id, client_msg_id}, changes, edit)
    end)
  end

  def handle(conn, {:purge_removed_lists, %DateTime{} = now}),
    do: in_transaction(conn, fn -> purge_removed_lists(conn, now) end)

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- reads ---------------------------------------------------------------

  # Every live list with its open and done item counts, in picker order.
  defp index(conn, owner_id, agent_id) do
    sql = """
    SELECT #{prefixed("c", @list_columns)},
      COALESCE(SUM(CASE WHEN i.kind = 'item' AND i.done = 0 THEN 1 ELSE 0 END), 0),
      COALESCE(SUM(CASE WHEN i.kind = 'item' AND i.done = 1 THEN 1 ELSE 0 END), 0)
    FROM checklists AS c
    LEFT JOIN checklist_items AS i ON i.checklist_id = c.id AND i.removed_at IS NULL
    WHERE c.owner_id = ? AND c.agent_id = ? AND c.removed_at IS NULL
    GROUP BY c.id
    ORDER BY c.position, c.id
    """

    with {:ok, rows} <- query_all(conn, sql, [owner_id, agent_id]) do
      {:ok, Enum.map(rows, &counted_list/1)}
    end
  end

  defp counted_list(values) do
    {list_values, [open, done]} = Enum.split(values, length(@list_columns))
    list_values |> decode_list() |> Map.merge(%{open: open, done: done})
  end

  defp read_list(conn, owner_id, agent_id, ref) do
    with {:ok, lists} <- live_lists(conn, owner_id, agent_id),
         {:ok, list} <- Ops.resolve(lists, ref),
         {:ok, rows} <- live_rows(conn, list.id) do
      {:ok, %{list: list, rows: rows}}
    end
  end

  defp read_folder(conn, owner_id, agent_id, folder) do
    with {:ok, lists} <- live_lists(conn, owner_id, agent_id),
         {:ok, members} <- Ops.folder_lists(lists, folder),
         {:ok, rows} <- rows_of(conn, Enum.map(members, & &1.id), &live_rows/2) do
      {:ok, Enum.map(members, &%{list: &1, rows: Map.fetch!(rows, &1.id)})}
    end
  end

  # One list by id, live or removed and not yet swept, with its live rows and,
  # when asked, the rows removed from it in the last 30 days, newest first.
  defp list_by_id(conn, owner_id, agent_id, list_id, removed?) do
    sql = """
    SELECT #{@list_select} FROM checklists WHERE owner_id = ? AND agent_id = ? AND id = ?
    """

    with {:ok, [values]} <- query_all(conn, sql, [owner_id, agent_id, list_id]),
         list = decode_list(values),
         {:ok, rows} <- live_rows(conn, list.id),
         {:ok, gone} <- if(removed?, do: removed_rows(conn, list.id), else: {:ok, []}) do
      {:ok, %{list: list, rows: rows, removed_rows: gone}}
    else
      {:ok, []} -> {:error, {:no_such_list, list_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp removed_rows(conn, list_id) do
    sql = """
    SELECT #{@item_select} FROM checklist_items
    WHERE checklist_id = ? AND removed_at IS NOT NULL
    ORDER BY removed_at DESC, n
    """

    with {:ok, rows} <- query_all(conn, sql, [list_id]) do
      {:ok, Enum.map(rows, &decode_item/1)}
    end
  end

  defp removed_lists(_conn, _owner_id, _agent_id, []), do: {:ok, []}

  defp removed_lists(conn, owner_id, agent_id, ids) do
    marks = Enum.map_join(ids, ", ", fn _id -> "?" end)

    sql = """
    SELECT #{@list_select} FROM checklists
    WHERE owner_id = ? AND agent_id = ? AND removed_at IS NOT NULL AND id IN (#{marks})
    """

    with {:ok, rows} <- query_all(conn, sql, [owner_id, agent_id | ids]) do
      {:ok, Enum.map(rows, &decode_list/1)}
    end
  end

  defp live_lists(conn, owner_id, agent_id) do
    sql = """
    SELECT #{@list_select} FROM checklists
    WHERE owner_id = ? AND agent_id = ? AND removed_at IS NULL
    ORDER BY position, id
    """

    with {:ok, rows} <- query_all(conn, sql, [owner_id, agent_id]) do
      {:ok, Enum.map(rows, &decode_list/1)}
    end
  end

  defp live_rows(conn, list_id) do
    sql = """
    SELECT #{@item_select} FROM checklist_items
    WHERE checklist_id = ? AND removed_at IS NULL
    ORDER BY position, n
    """

    with {:ok, rows} <- query_all(conn, sql, [list_id]) do
      {:ok, Enum.map(rows, &decode_item/1)}
    end
  end

  # --- the edit ------------------------------------------------------------

  # Loads the owner's lists and the rows of every list the call names, hands
  # them to `Ops`, and writes what it changed. Inside `in_transaction/2`, so a
  # refusal of any op leaves every list as it was.
  defp edit(conn, owner_id, agent_id, changes, edit) do
    with {:ok, live} <- live_lists(conn, owner_id, agent_id),
         {:ok, gone} <- removed_lists(conn, owner_id, agent_id, Ops.restored_lists(changes)),
         lists = live ++ gone,
         ids = Ops.referenced(lists, changes),
         {:ok, rows} <- rows_of(conn, ids, &live_rows/2),
         {:ok, removed} <- removed_of(conn, ids, Ops.restores_rows?(changes)),
         loaded = %{lists: lists, rows: rows, removed: removed},
         {:ok, result} <- Ops.apply(loaded, changes, edit),
         :ok <- write(conn, {owner_id, agent_id, lists}, result, edit.now) do
      {:ok, result}
    end
  end

  defp removed_of(_conn, _ids, false), do: {:ok, %{}}
  defp removed_of(conn, ids, true), do: rows_of(conn, ids, &removed_rows/2)

  # A device's edit, once: an id already recorded is answered as the duplicate
  # it is, and changes nothing; a new one is applied and recorded in the same
  # transaction, and records older than the retention go with it.
  defp device_edit(conn, key, changes, edit) do
    case edit_record(conn, key) do
      {:ok, nil} -> applied_device_edit(conn, key, changes, edit)
      {:ok, record} -> {:ok, {:duplicate, record}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp applied_device_edit(conn, {owner_id, agent_id, client_msg_id}, changes, edit) do
    with {:ok, result} <- edit(conn, owner_id, agent_id, changes, edit),
         [%{list_id: list_id} | _rest] = result.summary,
         record = %{list_id: list_id, made: result.made},
         :ok <- insert_edit_record(conn, {owner_id, agent_id, client_msg_id}, record, edit.now),
         :ok <- purge_edit_records(conn, edit.now) do
      {:ok, {:applied, result}}
    end
  end

  defp edit_record(conn, {owner_id, agent_id, client_msg_id}) do
    sql = """
    SELECT checklist_id, made_id FROM checklist_edits
    WHERE owner_id = ? AND agent_id = ? AND client_msg_id = ?
    """

    case query_all(conn, sql, [owner_id, agent_id, client_msg_id]) do
      {:ok, []} -> {:ok, nil}
      {:ok, [[list_id, made]]} -> {:ok, %{list_id: list_id, made: made}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_edit_record(conn, {owner_id, agent_id, client_msg_id}, record, now) do
    sql = """
    INSERT INTO checklist_edits (owner_id, agent_id, client_msg_id, checklist_id, made_id,
      created_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """

    execute(conn, sql, [
      owner_id,
      agent_id,
      client_msg_id,
      record.list_id,
      record.made,
      stamp(now)
    ])
  end

  defp purge_edit_records(conn, now) do
    cutoff = now |> DateTime.add(-@retention_seconds, :second) |> stamp()
    execute(conn, "DELETE FROM checklist_edits WHERE created_at < ?", [cutoff])
  end

  defp rows_of(conn, list_ids, read) do
    Enum.reduce_while(list_ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case read.(conn, id) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, id, rows)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The unique index on live titles must never see two lists hold one title
  # mid-call, whatever order the call touched them in: every existing list
  # whose title moves or which is removed first gives its title up for a
  # placeholder no title can be (it starts with a control character), so the
  # final writes land in any order. Then the new lists, which the rows moved or
  # added into them reference; then the rows; then the purge.
  defp write(conn, {owner_id, agent_id, stored}, result, now) do
    changed = Enum.map(result.changed, &Map.fetch!(result.lists, &1))
    {created, existing} = Enum.split_with(changed, & &1.created?)
    titles = Map.new(stored, &{&1.id, &1.title})
    moving = Enum.filter(existing, &title_moves?(&1, titles))

    with :ok <- each(moving, &free_title(conn, &1)),
         :ok <- each(existing, &update_list(conn, &1)),
         :ok <- each(created, &insert_list(conn, owner_id, agent_id, &1)),
         :ok <- each(dirty_rows(result, changed), &write_row(conn, &1)) do
      each(changed, &purge_rows(conn, &1.id, now))
    end
  end

  # A removed list coming back holds no live title to give up.
  defp title_moves?(list, titles) do
    not Map.get(list, :restored?, false) and
      (list.removed_at != nil or list.title != Map.fetch!(titles, list.id))
  end

  # The live rows an op changed, then the rows it removed, less any added and
  # removed in this same call, which never reach the store.
  defp dirty_rows(result, changed) do
    live = Enum.flat_map(changed, &Map.get(result.rows, &1.id, []))
    removed = Enum.reject(result.removed_rows, &(&1.dirty == :new))
    Enum.filter(live, & &1.dirty) ++ Enum.map(removed, &Map.put(&1, :dirty, :removed))
  end

  defp free_title(conn, list) do
    sql = "UPDATE checklists SET title = ? WHERE id = ? AND removed_at IS NULL"
    expect_one(conn, sql, [<<1>> <> list.id, list.id], {:list_gone, list.id})
  end

  defp insert_list(conn, owner_id, agent_id, list) do
    values = list |> Map.merge(%{owner_id: owner_id, agent_id: agent_id}) |> list_values()
    sql = "INSERT INTO checklists (#{@list_select}) VALUES (#{@list_placeholders})"
    execute(conn, sql, values)
  end

  # A list a call brings back is the one row this update finds removed.
  defp update_list(conn, list) do
    live = if Map.get(list, :restored?, false), do: "IS NOT NULL", else: "IS NULL"

    sql = """
    UPDATE checklists SET title = ?, folder = ?, rev = ?, next_n = ?, updated_at = ?,
      removed_at = ?
    WHERE id = ? AND removed_at #{live}
    """

    params = [
      list.title,
      list.folder,
      list.rev,
      list.next_n,
      stamp(list.updated_at),
      optional_stamp(list.removed_at),
      list.id
    ]

    expect_one(conn, sql, params, {:list_gone, list.id})
  end

  defp write_row(conn, %{dirty: :new} = row) do
    sql = "INSERT INTO checklist_items (#{@item_select}) VALUES (#{@item_placeholders})"
    execute(conn, sql, item_values(row))
  end

  defp write_row(conn, row) do
    live = if row.dirty == :restored, do: "IS NOT NULL", else: "IS NULL"

    sql = """
    UPDATE checklist_items SET checklist_id = ?, n = ?, text = ?, note = ?, done = ?,
      done_at = ?, position = ?, added_after_outside_content = ?, updated_at = ?,
      removed_at = ?
    WHERE id = ? AND removed_at #{live}
    """

    params = [
      row.checklist_id,
      row.n,
      row.text,
      row.note,
      bit(row.done),
      optional_stamp(row.done_at),
      row.position,
      bit(row.stamped),
      stamp(row.updated_at),
      optional_stamp(Map.get(row, :removed_at)),
      row.id
    ]

    expect_one(conn, sql, params, {:row_gone, row.id})
  end

  # Rows of `list_id` removed more than the retention ago, deleted with the
  # edit that touches their list (§06): no timer ever purges them.
  defp purge_rows(conn, list_id, now) do
    cutoff = now |> DateTime.add(-@retention_seconds, :second) |> stamp()

    execute(
      conn,
      "DELETE FROM checklist_items WHERE checklist_id = ? AND removed_at IS NOT NULL " <>
        "AND removed_at < ?",
      [list_id, cutoff]
    )
  end

  # Every list removed more than the retention before `now`, its rows with it
  # (the foreign key cascades), answering how many lists went. The Repo runs it
  # once when it opens the store: the one sweep lists have, and no timer.
  defp purge_removed_lists(conn, %DateTime{} = now) do
    cutoff = now |> DateTime.add(-@retention_seconds, :second) |> stamp()
    sql = "DELETE FROM checklists WHERE removed_at IS NOT NULL AND removed_at < ? RETURNING 1"

    with {:ok, rows} <- query_all(conn, sql, [cutoff]), do: {:ok, length(rows)}
  end

  defp expect_one(conn, sql, params, gone) do
    case execute_changes(conn, sql, params) do
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

  defp list_values(list) do
    [
      list.id,
      list.owner_id,
      list.agent_id,
      list.title,
      list.folder,
      list.position,
      list.rev,
      list.next_n,
      stamp(list.created_at),
      stamp(list.updated_at),
      optional_stamp(list.removed_at)
    ]
  end

  defp item_values(row) do
    [
      row.id,
      row.checklist_id,
      row.n,
      Atom.to_string(row.kind),
      row.text,
      row.note,
      bit(row.done),
      optional_stamp(row.done_at),
      row.position,
      bit(row.stamped),
      row.made_via,
      stamp(row.created_at),
      stamp(row.updated_at),
      nil
    ]
  end

  defp decode_list(values) do
    raw = @list_columns |> Enum.zip(values) |> Map.new()

    Map.merge(raw, %{
      created_at: parse_stamp(raw.created_at),
      updated_at: parse_stamp(raw.updated_at),
      removed_at: optional_parse(raw.removed_at),
      created?: false
    })
  end

  defp decode_item(values) do
    raw = @item_columns |> Enum.zip(values) |> Map.new()

    %{
      id: raw.id,
      checklist_id: raw.checklist_id,
      n: raw.n,
      kind: kind(raw.kind),
      text: raw.text,
      note: raw.note,
      done: raw.done == 1,
      done_at: optional_parse(raw.done_at),
      position: raw.position,
      stamped: raw.added_after_outside_content == 1,
      made_via: raw.made_via,
      created_at: parse_stamp(raw.created_at),
      updated_at: parse_stamp(raw.updated_at),
      removed_at: optional_parse(raw.removed_at),
      dirty: nil
    }
  end

  defp kind("item"), do: :item
  defp kind("section"), do: :section

  defp prefixed(alias_name, columns), do: Enum.map_join(columns, ", ", &"#{alias_name}.#{&1}")

  defp bit(true), do: 1
  defp bit(false), do: 0

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

  # --- sqlite plumbing -----------------------------------------------------

  # A failed BEGIN leaves no open transaction, so it is the only path that
  # returns without ROLLBACK; every failure after it rolls back, or the single
  # writer's one connection is left inside an open BEGIN IMMEDIATE.
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
          "Checklist transaction rollback failed: #{inspect(rollback_error)} " <>
            "(original error: #{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  defp query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params), do: Sqlite3.fetch_all(conn, stmt)
    end)
  end

  defp execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params), do: step_result(Sqlite3.step(conn, stmt))
    end)
  end

  defp execute_changes(conn, sql, params) do
    with :ok <- execute(conn, sql, params), do: Sqlite3.changes(conn)
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
