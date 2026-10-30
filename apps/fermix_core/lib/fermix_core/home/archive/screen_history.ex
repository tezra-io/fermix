defmodule FermixCore.Home.Archive.ScreenHistory do
  @moduledoc """
  Clears screen history (computer history, M32) from a restored home's
  database before the restore returns.

  Those rows describe what one Mac's screen showed and promise to stay on that
  device and to go when purged; a copy on another host keeps neither promise
  (M75 §13). So a restore deletes them through the purge the feature already
  owns (`ComputerHistorySql.purge_window/4`, every row from the epoch to now),
  on the restored file opened directly: no `Memory.Repo` runs for it, and the
  live engine's database is never opened. A row stamped after now (a source
  clock ahead of this one) is refused by name rather than left behind.
  """

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo.ComputerHistorySql

  @tables ~w(computer_history_access computer_history_events computer_history_memories computer_history_purges)

  @doc """
  Deletes every screen-history row in the database at `db_path` stamped at or
  before `now_ms`, answering how many events and summaries went. A database
  without the feature's tables has none.
  """
  @spec clear(Path.t(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear(db_path, now_ms) when is_binary(db_path) and is_integer(now_ms) and now_ms >= 0 do
    with :ok <- existing(db_path),
         {:ok, conn} <- open(db_path) do
      close_after(conn, clear_open(conn, now_ms))
    end
  end

  defp existing(db_path) do
    if File.regular?(db_path), do: :ok, else: {:error, {:screen_history, {:no_database, db_path}}}
  end

  defp open(db_path) do
    case Sqlite3.open(db_path) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:screen_history, reason}}
    end
  end

  defp clear_open(conn, now_ms) do
    case tables(conn) do
      {:ok, []} -> {:ok, 0}
      {:ok, @tables} -> purge(conn, now_ms)
      {:ok, partial} -> {:error, {:screen_history, {:partial_schema, partial}}}
      {:error, reason} -> {:error, {:screen_history, reason}}
    end
  end

  defp purge(conn, now_ms) do
    with {:ok, %{events: events, memories: memories}} <-
           ComputerHistorySql.purge_window(conn, 0, now_ms, now_ms),
         {:ok, 0} <- remaining(conn) do
      {:ok, events + memories}
    else
      {:ok, left} when is_integer(left) -> {:error, {:screen_history_remaining, left}}
      {:error, reason} -> {:error, {:screen_history, reason}}
    end
  end

  defp remaining(conn) do
    with {:ok, events} <- ComputerHistorySql.count_events(conn),
         {:ok, memories} <- ComputerHistorySql.count_memories(conn, :all, :all) do
      {:ok, events + memories}
    end
  end

  defp tables(conn) do
    names = Enum.map_join(@tables, ", ", &"'#{&1}'")

    sql =
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (#{names}) ORDER BY name"

    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      rows = Sqlite3.fetch_all(conn, stmt)
      released = Sqlite3.release(conn, stmt)

      case {rows, released} do
        {{:ok, rows}, :ok} -> {:ok, List.flatten(rows)}
        {{:error, _reason} = error, _released} -> error
        {_rows, {:error, _reason} = error} -> error
      end
    end
  end

  defp close_after(conn, result) do
    case {result, Sqlite3.close(conn)} do
      {result, :ok} -> result
      {{:ok, _count}, {:error, reason}} -> {:error, {:screen_history, reason}}
      {error, {:error, _reason}} -> error
    end
  end
end
