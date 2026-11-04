defmodule FermixCore.Memory.Repo.InboundEventsSql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s channel event ids (M75 B15): the
  # ids `FermixChannels.Gateway.Idempotency` has taken in, kept in `memory.db`
  # for their window so a provider's retry that arrives after a restart, or
  # after the home moved to another host, is still a duplicate. Every function
  # that takes a `conn` runs only from a Repo `handle_call`, so the single
  # writer is unchanged and a claim is atomic against every other Repo caller.
  #
  # Times are Unix milliseconds of the wall clock, because a row outlives the
  # process (and the host) that wrote it; the caller passes them in, so a test
  # injects its own clock.

  alias Exqlite.Sqlite3

  @channel_max 64
  @event_id_max 512
  @prune_limit_max 10_000

  @schema_sql """
  CREATE TABLE IF NOT EXISTS channel_event_ids (
    channel TEXT NOT NULL,
    event_id TEXT NOT NULL,
    recorded_at_ms INTEGER NOT NULL,
    expires_at_ms INTEGER NOT NULL,
    PRIMARY KEY (channel, event_id)
  );

  CREATE INDEX IF NOT EXISTS idx_channel_event_ids_expiry
    ON channel_event_ids(expires_at_ms);
  """

  @doc "The table and its expiry index, as migration 53 creates them."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc """
  `{:ok, {channel, event_id}}` when both fit the table's bounds, else the bound
  the caller broke. Runs in the caller, before the Repo call.
  """
  @spec normalize_key(atom() | String.t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def normalize_key(channel, event_id) when is_atom(channel),
    do: normalize_key(Atom.to_string(channel), event_id)

  def normalize_key(channel, event_id) when is_binary(channel) and is_binary(event_id) do
    cond do
      channel == "" or byte_size(channel) > @channel_max -> {:error, {:invalid_channel, channel}}
      event_id == "" -> {:error, :empty_event_id}
      byte_size(event_id) > @event_id_max -> {:error, {:event_id_too_long, byte_size(event_id)}}
      true -> {:ok, {channel, event_id}}
    end
  end

  @doc "The most rows one prune may delete."
  @spec prune_limit_max() :: pos_integer()
  def prune_limit_max, do: @prune_limit_max

  # --- statements (single-writer process) ----------------------------------

  @doc """
  Records the id until `expires_at_ms` unless a live row holds it: `:fresh`
  when it was absent or its row had expired (the row is renewed), and
  `{:duplicate, expires_at_ms}` with the live row's expiry otherwise.
  """
  @spec claim(term(), String.t(), String.t(), integer(), integer()) ::
          {:ok, :fresh | {:duplicate, integer()}} | {:error, term()}
  def claim(conn, channel, event_id, now_ms, expires_at_ms)
      when is_binary(channel) and is_binary(event_id) and is_integer(now_ms) and
             is_integer(expires_at_ms) and expires_at_ms > now_ms do
    upsert = """
    INSERT INTO channel_event_ids (channel, event_id, recorded_at_ms, expires_at_ms)
    VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT (channel, event_id) DO UPDATE
      SET recorded_at_ms = excluded.recorded_at_ms, expires_at_ms = excluded.expires_at_ms
      WHERE channel_event_ids.expires_at_ms <= excluded.recorded_at_ms
    RETURNING expires_at_ms
    """

    case query_all(conn, upsert, [channel, event_id, now_ms, expires_at_ms]) do
      {:ok, [[_written]]} -> {:ok, :fresh}
      {:ok, []} -> live_expiry(conn, channel, event_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_expiry(conn, channel, event_id) do
    select =
      "SELECT expires_at_ms FROM channel_event_ids WHERE channel = ?1 AND event_id = ?2"

    case query_all(conn, select, [channel, event_id]) do
      {:ok, [[expires_at_ms]]} -> {:ok, {:duplicate, expires_at_ms}}
      {:ok, []} -> {:error, :claim_lost}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes the id's row, if any."
  @spec forget(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def forget(conn, channel, event_id) when is_binary(channel) and is_binary(event_id) do
    delete = "DELETE FROM channel_event_ids WHERE channel = ?1 AND event_id = ?2"

    case query_all(conn, delete, [channel, event_id]) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes at most `limit` rows that expired at or before `now_ms`, through the
  expiry index, so a prune reads only the rows it deletes. Answers how many it
  deleted; fewer than `limit` means none expired is left.
  """
  @spec prune(term(), integer(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(conn, now_ms, limit)
      when is_integer(now_ms) and is_integer(limit) and limit > 0 and limit <= @prune_limit_max do
    delete = """
    DELETE FROM channel_event_ids WHERE rowid IN (
      SELECT rowid FROM channel_event_ids WHERE expires_at_ms <= ?1
      ORDER BY expires_at_ms LIMIT ?2
    )
    RETURNING 1
    """

    case query_all(conn, delete, [now_ms, limit]) do
      {:ok, rows} -> {:ok, length(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp query_all(conn, sql, params) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} -> release_statement(conn, stmt, bind_and_fetch(conn, stmt, params))
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_and_fetch(conn, stmt, params) do
    with :ok <- Sqlite3.bind(stmt, params), do: Sqlite3.fetch_all(conn, stmt)
  end

  defp release_statement(conn, stmt, result) do
    case Sqlite3.release(conn, stmt) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
