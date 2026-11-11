defmodule FermixTestSupport.HistorySpool do
  @moduledoc """
  A machine's history store (`FermixCore.ComputerHistory.Spool`) as a test
  sets it up or reads it, beside the store's own requests: a pause horizon as
  an earlier writer may have left it (the store's own writes only ever raise
  a valid one), and the oldest raw event's stamp.
  """

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory.Spool

  @doc "Write `until` as the pause horizon of the store `spool` runs, whatever text it is."
  @spec put_pause_until(GenServer.server(), String.t()) :: :ok
  def put_pause_until(spool, until) when is_binary(until) do
    {:ok, _state} = Spool.state(server: spool)
    %{path: path} = :sys.get_state(spool)
    {:ok, conn} = Sqlite3.open(path)

    try do
      {:ok, stmt} =
        Sqlite3.prepare(conn, "UPDATE computer_history_state SET pause_until = ?1 WHERE id = 1")

      :ok = Sqlite3.bind(stmt, [until])
      :done = Sqlite3.step(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
    after
      Sqlite3.close(conn)
    end
  end

  @doc "The stamp of the oldest raw event the store holds, or nil."
  @spec oldest_ts(GenServer.server()) :: integer() | nil
  def oldest_ts(spool) do
    {:ok, events} = Spool.events_after(0, 100_000, server: spool)
    events |> Enum.map(& &1.ts) |> Enum.min(fn -> nil end)
  end
end
