defmodule FermixCore.Harness.MachineStore.Sql do
  @moduledoc """
  The SQL of this machine's coding store (`Harness.MachineStore`,
  `device/coding.db`). Every function takes an open connection and answers
  `:ok`, `{:ok, value}` or `{:error, reason}`; none raises on what the
  database says.

  Schema v1 holds one table, `coding_agent_marks`: one row per coding agent
  whose last run here failed to sign in (M98 D10), with the stat of the
  agent's sign-in file when it was marked (its size, mtime and inode, never
  its bytes) so a later check can tell the file changed.
  """

  alias Exqlite.Sqlite3

  @schema_version 1

  @schema_sql """
  CREATE TABLE IF NOT EXISTS coding_agent_marks (
    vendor TEXT PRIMARY KEY CHECK (vendor IN ('codex','claude')),
    marked_at TEXT NOT NULL,
    run_id TEXT NOT NULL,
    sign_in_file TEXT,
    file_stat TEXT
  );
  """

  @doc "The schema version this module writes."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Creates the schema (each statement safe to run again)."
  @spec create_schema(term()) :: :ok | {:error, term()}
  def create_schema(conn), do: Sqlite3.execute(conn, @schema_sql)

  @doc "Every mark, keyed by agent."
  @spec marks(term()) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def marks(conn) do
    sql = "SELECT vendor, marked_at, run_id, sign_in_file, file_stat FROM coding_agent_marks"

    with {:ok, rows} <- query_all(conn, sql, []) do
      collect(rows, %{})
    end
  end

  @doc """
  Writes `vendor`'s mark, replacing the one it had. The caller has checked
  its shape (`Harness.MachineStore.put_mark/3`).
  """
  @spec put_mark(term(), String.t(), map()) :: :ok | {:error, term()}
  def put_mark(conn, vendor, %{marked_at: %DateTime{} = at, run_id: run_id} = mark) do
    sql =
      "INSERT INTO coding_agent_marks (vendor, marked_at, run_id, sign_in_file, file_stat) " <>
        "VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(vendor) DO UPDATE SET " <>
        "marked_at = excluded.marked_at, run_id = excluded.run_id, " <>
        "sign_in_file = excluded.sign_in_file, file_stat = excluded.file_stat"

    with {:ok, stat} <- encode_stat(Map.get(mark, :file_stat)) do
      params = [vendor, DateTime.to_iso8601(at), run_id, Map.get(mark, :sign_in_file), stat]
      execute(conn, sql, params)
    end
  end

  @doc """
  Deletes the marks of `vendors` (one not marked is not an error). The caller
  has checked each is an agent's tag.
  """
  @spec delete_marks(term(), [String.t()]) :: :ok | {:error, term()}
  def delete_marks(conn, vendors) when is_list(vendors) do
    Enum.reduce_while(vendors, :ok, fn vendor, :ok ->
      case execute(conn, "DELETE FROM coding_agent_marks WHERE vendor = ?1", [vendor]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Records the schema version as applied."
  @spec record_version(term()) :: :ok | {:error, term()}
  def record_version(conn) do
    execute(conn, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (?1)", [
      @schema_version
    ])
  end

  # --- rows ---------------------------------------------------------------------

  defp collect([], acc), do: {:ok, acc}

  defp collect([[vendor, at, run_id, file, stat] | rest], acc) do
    case decode_stat(stat) do
      {:ok, decoded} ->
        mark = %{
          vendor: vendor,
          marked_at: at,
          run_id: run_id,
          sign_in_file: file,
          file_stat: decoded
        }

        collect(rest, Map.put(acc, vendor, mark))

      {:error, reason} ->
        {:error, {:unreadable_mark, vendor, reason}}
    end
  end

  defp encode_stat(nil), do: {:ok, nil}

  defp encode_stat(%{} = stat) do
    case Jason.encode(stat) do
      {:ok, text} -> {:ok, text}
      {:error, error} -> {:error, {:unencodable_stat, Exception.message(error)}}
    end
  end

  defp decode_stat(nil), do: {:ok, nil}

  defp decode_stat(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = stat} -> {:ok, stat}
      {:ok, _other} -> {:error, :not_a_stat}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # --- statements -----------------------------------------------------------------

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
