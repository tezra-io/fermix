defmodule FermixCore.Memory.Repo.KeptSql do
  @moduledoc """
  The store's half of what every kept kind shares (M89 §07): one transaction,
  the statement helpers, the 30-day cutoff and the receipts a device's edits
  leave. Each kind's own SQL module (`ChecklistsSql` for the lists) keeps its
  tables, rows and sweeps, and calls these from the Repo's `handle_call`
  only, so the single writer stays the only writer and nothing here raises
  inside the Repo process.

  A device's edit is applied once by its `client_msg_id` (`once/4`): the
  receipt names the kind, the thing the edit changed and what an add or a
  create made, so an edit sent again (a reconnect, an outbox's replay) is
  answered as the duplicate it is and changes nothing. Receipts live in the
  table the lists made (`checklist_edits`, migration 57), whose `kind` column
  migration 62 added; its id column keeps the name 57 gave it, so an engine
  from before 62 still reads and writes the store. A receipt is kept 30 days
  and deleted, whatever its kind, in the transaction of any later device
  edit.
  """

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo.TemporalSql

  # The kinds a receipt may name: the CHECK migration 62 wrote, which SQLite
  # cannot widen in place, so it names the trips to come (M89 §05) as well.
  @receipt_kinds ["checklist", "trip"]
  @retention_seconds 30 * 86_400
  @receipt_columns_57 ~w(owner_id agent_id client_msg_id checklist_id made_id created_at)
  @receipt_kinds_sql """
  ALTER TABLE checklist_edits ADD COLUMN kind TEXT NOT NULL DEFAULT 'checklist'
    CHECK (kind IN ('checklist', 'trip'));
  """

  @typedoc "One device edit: its kind, the owner's ids and the edit's `client_msg_id`."
  @type receipt_key :: {
          kind :: String.t(),
          owner_id :: String.t(),
          agent_id :: String.t(),
          client_msg_id :: String.t()
        }

  @typedoc "What a receipt says the edit changed and made."
  @type receipt :: %{id: String.t(), made: String.t() | nil}

  @doc """
  Migration 62's columns, as `Memory.Repo` adds them: `kind` added while the
  receipts table holds 57's columns, nothing once it holds `kind`.
  """
  @spec receipt_kinds_columns() :: %{before: [String.t()], after: [String.t()], sql: String.t()}
  def receipt_kinds_columns,
    do: %{
      before: @receipt_columns_57,
      after: @receipt_columns_57 ++ ["kind"],
      sql: @receipt_kinds_sql
    }

  @doc """
  The stored stamp 30 days before `now`: a removed row, a removed thing or a
  receipt older than it is deleted.
  """
  @spec cutoff(DateTime.t()) :: String.t()
  def cutoff(%DateTime{} = now), do: now |> DateTime.add(-@retention_seconds, :second) |> stamp()

  # --- a device's edit, once -----------------------------------------------

  @doc """
  Runs `apply` once for `key`, inside the caller's `in_transaction/2`. With no
  receipt for the key, `apply` answers `{:ok, value, receipt}`, the receipt is
  written and every receipt past the cutoff deleted, and the answer is
  `{:applied, value}`; with one, `apply` never runs and the answer is
  `{:duplicate, receipt}`. A `client_msg_id` another kind already used is
  found by no lookup and fails its insert, so the transaction rolls back.
  """
  @spec once(term(), receipt_key(), DateTime.t(), (-> {:ok, term(), receipt()} | {:error, term()})) ::
          {:ok, {:applied, term()} | {:duplicate, receipt()}} | {:error, term()}
  def once(conn, {kind, owner_id, agent_id, client_msg_id} = key, %DateTime{} = now, apply)
      when kind in @receipt_kinds and is_binary(owner_id) and is_binary(agent_id) and
             is_binary(client_msg_id) and is_function(apply, 0) do
    case receipt(conn, key) do
      {:ok, nil} -> applied(conn, key, now, apply.())
      {:ok, receipt} -> {:ok, {:duplicate, receipt}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp applied(conn, key, now, {:ok, value, %{id: id, made: made}}) when is_binary(id) do
    with :ok <- insert_receipt(conn, key, {id, made}, now),
         :ok <- purge_receipts(conn, now) do
      {:ok, {:applied, value}}
    end
  end

  defp applied(_conn, _key, _now, {:error, reason}), do: {:error, reason}

  defp receipt(conn, {kind, owner_id, agent_id, client_msg_id}) do
    sql = """
    SELECT checklist_id, made_id FROM checklist_edits
    WHERE owner_id = ? AND agent_id = ? AND client_msg_id = ? AND kind = ?
    """

    case query_all(conn, sql, [owner_id, agent_id, client_msg_id, kind]) do
      {:ok, []} -> {:ok, nil}
      {:ok, [[id, made]]} -> {:ok, %{id: id, made: made}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_receipt(conn, {kind, owner_id, agent_id, client_msg_id}, {id, made}, now) do
    sql = """
    INSERT INTO checklist_edits (owner_id, agent_id, client_msg_id, kind, checklist_id, made_id,
      created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """

    execute(conn, sql, [owner_id, agent_id, client_msg_id, kind, id, made, stamp(now)])
  end

  defp purge_receipts(conn, now),
    do: execute(conn, "DELETE FROM checklist_edits WHERE created_at < ?", [cutoff(now)])

  # --- sqlite plumbing -----------------------------------------------------

  @doc """
  Runs `fun` in `BEGIN IMMEDIATE` … `COMMIT`, rolled back when it answers an
  error or the commit fails. A failed BEGIN leaves no open transaction, so it
  is the only path that returns without ROLLBACK; every failure after it rolls
  back, or the single writer's one connection is left inside an open BEGIN
  IMMEDIATE.
  """
  @spec in_transaction(term(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def in_transaction(conn, fun) when is_function(fun, 0) do
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
          "Kept-thing transaction rollback failed: #{inspect(rollback_error)} " <>
            "(original error: #{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  @doc "Every row `sql` selects with `params` bound."
  @spec query_all(term(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  def query_all(conn, sql, params) when is_binary(sql) and is_list(params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params), do: Sqlite3.fetch_all(conn, stmt)
    end)
  end

  @doc "Runs one statement with `params` bound."
  @spec execute(term(), String.t(), list()) :: :ok | {:error, term()}
  def execute(conn, sql, params) when is_binary(sql) and is_list(params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params), do: step_result(Sqlite3.step(conn, stmt))
    end)
  end

  @doc "Runs one statement with `params` bound, answering how many rows it changed."
  @spec execute_changes(term(), String.t(), list()) :: {:ok, non_neg_integer()} | {:error, term()}
  def execute_changes(conn, sql, params) when is_binary(sql) and is_list(params) do
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

  defp stamp(%DateTime{} = at) do
    {:ok, value} = TemporalSql.timestamp(at)
    value
  end
end
