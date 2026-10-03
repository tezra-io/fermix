defmodule FermixCore.Memory.Repo.VoiceCallsSql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s Live call records (M56 §4.2).
  # The `MeetingsSql` split: every statement takes the caller's `conn` and runs
  # only from a Repo `handle_call`, so the single writer is unchanged.
  #
  # `normalize_*` and `decode/1` run in the *caller* process, before and after
  # the GenServer call: a bad value fails at the boundary with a clear error,
  # and a stored document that does not decode is the caller's error, never a
  # crash of the single writer. Task maps are opaque here; their vocabulary is
  # `Realtime.CallRecord`'s.

  alias Exqlite.Sqlite3

  @accounting ~w(complete incomplete running)

  # What a close may owe the chat (M56 §4.2): a gist to make and a row to
  # write, or nothing. Their ends (`written`, `failed`, `row_written`) are
  # written by their own statements, never by a close.
  @owed_gist ~w(none pending)
  @owed_row ~w(none row_pending)

  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @engine_max 64
  @end_reason_max 100
  # A record holds at most 64 tasks of about 2.5 KB each; past this the
  # document is a runaway, refused rather than stored.
  @tasks_json_max 262_144
  @list_limit 100
  # A gist is a few sentences (`Realtime.CallGist` cuts it to 1,200 bytes);
  # past this it is a runaway, refused rather than stored.
  @gist_max 4_096

  @columns [
    :uuid,
    :engine,
    :started_at,
    :ended_at,
    :end_reason,
    :voice_cost_cents,
    :accounting,
    :tasks_json,
    :gist,
    :gist_status,
    :row_state,
    :created_at,
    :gist_tainted
  ]

  @select Enum.map_join(@columns, ", ", &Atom.to_string/1)

  # `gist_status` and `row_state` start at `none`; a close moves them to what
  # the call owes the chat, and the gist and the row's writers move them on.
  @schema_sql """
  CREATE TABLE IF NOT EXISTS voice_calls (
    uuid TEXT PRIMARY KEY,
    engine TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    end_reason TEXT,
    voice_cost_cents REAL,
    accounting TEXT CHECK (accounting IS NULL OR accounting IN ('complete','incomplete','running')),
    tasks_json TEXT NOT NULL DEFAULT '[]',
    gist TEXT,
    gist_status TEXT NOT NULL DEFAULT 'none',
    row_state TEXT NOT NULL DEFAULT 'none' CHECK (row_state IN ('none','row_pending','row_written')),
    created_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_voice_calls_started ON voice_calls(started_at);
  """

  # Whether a gist was drawn from Computer History content (M56 §9): a column
  # beside it, so every reader sees the mark with the text.
  @gist_taint_schema_sql """
  ALTER TABLE voice_calls ADD COLUMN gist_tainted INTEGER NOT NULL DEFAULT 0
    CHECK (gist_tainted IN (0, 1));
  """

  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @spec gist_taint_schema_sql() :: String.t()
  def gist_taint_schema_sql, do: @gist_taint_schema_sql

  # --- normalization (caller process) --------------------------------------

  @doc "Validates the attribute map for a newly opened record."
  @spec normalize_insert(map()) :: {:ok, map()} | {:error, term()}
  def normalize_insert(attrs) when is_map(attrs) do
    with {:ok, uuid} <- normalize_uuid(Map.get(attrs, :uuid)),
         {:ok, engine} <- normalize_text(:engine, Map.get(attrs, :engine), @engine_max),
         {:ok, started_at} <- normalize_stamp(:started_at, Map.get(attrs, :started_at)),
         {:ok, created_at} <- normalize_stamp(:created_at, Map.get(attrs, :created_at)) do
      {:ok, %{uuid: uuid, engine: engine, started_at: started_at, created_at: created_at}}
    end
  end

  @doc "Validates a task list and encodes it as the stored document."
  @spec normalize_tasks(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_tasks(tasks) when is_list(tasks) do
    with :ok <- check_task_maps(tasks),
         {:ok, json} <- Jason.encode(tasks) do
      check_tasks_size(json)
    end
  end

  def normalize_tasks(_tasks), do: {:error, {:invalid, :tasks, :not_a_list_of_maps}}

  @doc "Validates the fields a close writes, in the order the UPDATE binds them."
  @spec normalize_close(map()) :: {:ok, list()} | {:error, term()}
  def normalize_close(fields) when is_map(fields) do
    with {:ok, ended_at} <- normalize_stamp(:ended_at, Map.get(fields, :ended_at)),
         {:ok, reason} <-
           normalize_text(:end_reason, Map.get(fields, :end_reason), @end_reason_max),
         {:ok, cost} <- normalize_cost(Map.get(fields, :voice_cost_cents)),
         {:ok, accounting} <- normalize_accounting(Map.get(fields, :accounting)),
         {:ok, tasks_json} <- normalize_tasks(Map.get(fields, :tasks)),
         {:ok, gist_status} <- normalize_owed(:gist_status, fields, @owed_gist),
         {:ok, row_state} <- normalize_owed(:row_state, fields, @owed_row) do
      {:ok, [ended_at, reason, cost, accounting, tasks_json, gist_status, row_state]}
    end
  end

  @doc "Validates a gist and its Computer History mark, as the UPDATE binds them."
  @spec normalize_gist(term(), term()) :: {:ok, [String.t() | 0 | 1]} | {:error, term()}
  def normalize_gist(gist, tainted?) do
    with {:ok, gist} <- normalize_text(:gist, gist, @gist_max),
         {:ok, tainted} <- normalize_flag(:gist_tainted, tainted?) do
      {:ok, [gist, tainted]}
    end
  end

  @doc "Validates how many gists one read may ask for: 1 to #{@list_limit}."
  @spec normalize_limit(term()) :: {:ok, pos_integer()} | {:error, term()}
  def normalize_limit(limit) when is_integer(limit) and limit > 0 and limit <= @list_limit,
    do: {:ok, limit}

  def normalize_limit(_limit), do: {:error, {:invalid, :limit, :out_of_range}}

  @doc "The fixed-width UTC form of a cutoff instant."
  @spec normalize_cutoff(DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_cutoff(cutoff), do: normalize_stamp(:cutoff, cutoff)

  @doc """
  A stored row as callers read it: `tasks` decoded from the document and
  `gist_tainted` a boolean.
  """
  @spec decode(map()) :: {:ok, map()} | {:error, term()}
  def decode(%{tasks_json: json, uuid: uuid} = row) do
    case Jason.decode(json) do
      {:ok, tasks} when is_list(tasks) ->
        {:ok,
         row
         |> Map.delete(:tasks_json)
         |> Map.put(:tasks, tasks)
         |> Map.update!(:gist_tainted, &(&1 == 1))}

      _unreadable ->
        {:error, {:invalid_tasks_json, uuid}}
    end
  end

  # --- statements (single-writer process) ----------------------------------

  @spec insert(term(), map()) :: {:ok, map()} | {:error, term()}
  def insert(conn, row) when is_map(row) do
    returning(
      conn,
      """
      INSERT INTO voice_calls (uuid, engine, started_at, created_at)
      VALUES (?, ?, ?, ?)
      RETURNING #{@select}
      """,
      [row.uuid, row.engine, row.started_at, row.created_at]
    )
  end

  @spec update_tasks(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_tasks(conn, uuid, tasks_json) when is_binary(uuid) and is_binary(tasks_json) do
    returning(
      conn,
      "UPDATE voice_calls SET tasks_json = ? WHERE uuid = ? RETURNING #{@select}",
      [tasks_json, uuid]
    )
  end

  @doc "Closes an open record; `:not_found` when there is none, closed ones included."
  @spec close(term(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def close(conn, uuid, [_ended, _reason, _cost, _accounting, _tasks, _gist, _row] = params)
      when is_binary(uuid) do
    returning(
      conn,
      """
      UPDATE voice_calls
      SET ended_at = ?, end_reason = ?, voice_cost_cents = ?, accounting = ?, tasks_json = ?,
          gist_status = ?, row_state = ?
      WHERE uuid = ? AND ended_at IS NULL
      RETURNING #{@select}
      """,
      params ++ [uuid]
    )
  end

  @doc """
  Writes the gist a close left pending, and its mark; `:not_found` unless the
  record's gist is still pending, so a gist is settled once, by whichever
  writer comes first.
  """
  @spec write_gist(term(), String.t(), [String.t() | 0 | 1]) :: {:ok, map()} | {:error, term()}
  def write_gist(conn, uuid, [_gist, _tainted] = params) when is_binary(uuid) do
    returning(
      conn,
      """
      UPDATE voice_calls SET gist = ?, gist_tainted = ?, gist_status = 'written'
      WHERE uuid = ? AND gist_status = 'pending'
      RETURNING #{@select}
      """,
      params ++ [uuid]
    )
  end

  @doc "Fails the gist a close left pending; `:not_found` unless it is still pending."
  @spec fail_gist(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def fail_gist(conn, uuid) when is_binary(uuid) do
    returning(
      conn,
      """
      UPDATE voice_calls SET gist_status = 'failed'
      WHERE uuid = ? AND gist_status = 'pending'
      RETURNING #{@select}
      """,
      [uuid]
    )
  end

  @doc "Marks an owed row written; `:not_found` unless the row is still owed."
  @spec mark_row_written(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def mark_row_written(conn, uuid) when is_binary(uuid) do
    returning(
      conn,
      """
      UPDATE voice_calls SET row_state = 'row_written'
      WHERE uuid = ? AND row_state = 'row_pending'
      RETURNING #{@select}
      """,
      [uuid]
    )
  end

  @spec fetch(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(conn, uuid) when is_binary(uuid) do
    returning(conn, "SELECT #{@select} FROM voice_calls WHERE uuid = ? LIMIT 1", [uuid])
  end

  @doc """
  Open records started before `cutoff`, oldest first, at most #{@list_limit}.
  The cutoff keeps a call this boot started out of a sweep of the last one's.
  """
  @spec list_open(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open(conn, cutoff) when is_binary(cutoff) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@select} FROM voice_calls
             WHERE ended_at IS NULL AND started_at < ?
             ORDER BY started_at ASC, uuid ASC
             LIMIT ?
             """,
             [cutoff, @list_limit]
           ) do
      {:ok, Enum.map(rows, &voice_call_row/1)}
    end
  end

  @doc """
  Closed records that still owe their chat row, started before `cutoff`,
  oldest first, at most #{@list_limit}: the rows a boot writes.
  """
  @spec list_owed_rows(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_owed_rows(conn, cutoff) when is_binary(cutoff) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@select} FROM voice_calls
             WHERE row_state = 'row_pending' AND started_at < ?
             ORDER BY started_at ASC, uuid ASC
             LIMIT ?
             """,
             [cutoff, @list_limit]
           ) do
      {:ok, Enum.map(rows, &voice_call_row/1)}
    end
  end

  @doc """
  The gists of the newest calls that have one, newest first, at most `limit`
  (M56 §4.2, §4.3): each with when its call started and whether it was drawn
  from Computer History. A call with no gist is skipped.
  """
  @spec recent_gists(term(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def recent_gists(conn, limit) when is_integer(limit) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT started_at, gist, gist_tainted FROM voice_calls
             WHERE gist IS NOT NULL
             ORDER BY started_at DESC, uuid DESC
             LIMIT ?
             """,
             [limit]
           ) do
      {:ok,
       Enum.map(rows, fn [started_at, gist, tainted] ->
         %{started_at: started_at, gist: gist, tainted: tainted == 1}
       end)}
    end
  end

  @doc "The most open records `list_open/2` returns at once."
  @spec list_limit() :: pos_integer()
  def list_limit, do: @list_limit

  # --- normalization helpers -----------------------------------------------

  defp normalize_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_pattern, uuid),
      do: {:ok, uuid},
      else: {:error, {:invalid, :uuid, :malformed}}
  end

  defp normalize_uuid(_uuid), do: {:error, {:invalid, :uuid, :not_a_string}}

  defp normalize_text(key, text, max) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, {:invalid, key, :blank}}
      byte_size(text) > max -> {:error, {:invalid, key, :too_long}}
      true -> {:ok, text}
    end
  end

  defp normalize_text(key, _text, _max), do: {:error, {:invalid, key, :not_a_string}}

  defp normalize_cost(nil), do: {:ok, nil}
  defp normalize_cost(cost) when is_number(cost) and cost >= 0, do: {:ok, cost / 1}
  defp normalize_cost(_cost), do: {:error, {:invalid, :voice_cost_cents, :not_a_cost}}

  defp normalize_accounting(accounting) when accounting in @accounting, do: {:ok, accounting}
  defp normalize_accounting(_accounting), do: {:error, {:invalid, :accounting, :unknown}}

  defp normalize_owed(key, fields, vocabulary) do
    value = Map.get(fields, key)
    if value in vocabulary, do: {:ok, value}, else: {:error, {:invalid, key, :unknown}}
  end

  defp normalize_flag(_key, true), do: {:ok, 1}
  defp normalize_flag(_key, false), do: {:ok, 0}
  defp normalize_flag(key, _value), do: {:error, {:invalid, key, :not_a_boolean}}

  defp check_task_maps(tasks) do
    if Enum.all?(tasks, &is_map/1),
      do: :ok,
      else: {:error, {:invalid, :tasks, :not_a_list_of_maps}}
  end

  defp check_tasks_size(json) when byte_size(json) > @tasks_json_max,
    do: {:error, {:invalid, :tasks, :too_long}}

  defp check_tasks_size(json), do: {:ok, json}

  # One fixed-width UTC form, so the cutoff compares as text.
  defp normalize_stamp(_key, %DateTime{} = value) do
    {:ok,
     value
     |> DateTime.shift_zone!("Etc/UTC")
     |> pad_microseconds()
     |> DateTime.to_iso8601()}
  end

  defp normalize_stamp(key, _value), do: {:error, {:invalid, key, :not_a_datetime}}

  defp pad_microseconds(%DateTime{microsecond: {value, _precision}} = at) do
    %{at | microsecond: {value, 6}}
  end

  # --- rows + sqlite plumbing ----------------------------------------------

  defp returning(conn, sql, params) do
    case query_all(conn, sql, params) do
      {:ok, [row | _rest]} -> {:ok, voice_call_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp voice_call_row(values), do: @columns |> Enum.zip(values) |> Map.new()

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
