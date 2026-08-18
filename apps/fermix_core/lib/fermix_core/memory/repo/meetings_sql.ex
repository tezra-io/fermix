defmodule FermixCore.Memory.Repo.MeetingsSql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s meetings operations (M21 Phase 3).
  # The `TemporalSql` split: every function takes the caller's `conn` and is
  # invoked only from Repo `handle_call`s, so the single-writer architecture is
  # unchanged; the split keeps `repo.ex` bounded.
  #
  # `normalize_*` runs in the *caller* process, before the GenServer call, so a
  # bad value fails at the boundary with a clear error instead of inside the
  # single writer.

  require Logger

  alias Exqlite.Sqlite3

  @platforms ~w(meet zoom)

  # Statuses a meeting can hold while a Session is (or should be) alive. Boot
  # reconciliation and the `:active` list scope share this one definition.
  @live_statuses ~w(
    requested installing launching joining knocking admitted capturing
    leaving summarizing removed_by_host meeting_ended max_duration alone_timeout
  )

  @terminal_statuses ~w(
    delivered denied login_required signin_required bot_blocked knock_timeout failed
  )

  @statuses @live_statuses ++ @terminal_statuses

  @id_pattern ~r/^mtg_[A-Za-z0-9_-]{11}$/
  @timestamp_pattern ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/

  @url_max 2_000
  @title_max 240
  @error_max 500
  @artifact_dir_max 1_000
  @list_default_limit 20
  @list_max_limit 50

  # Bound on the boot-sweep read. The ids are reported to the operator; the
  # UPDATE is unbounded, so a fuller page than this means more rows were fixed
  # than were named, which is logged rather than silently trimmed.
  @sweep_page 100

  @columns [
    :id,
    :platform,
    :url,
    :title,
    :status,
    :requested_by,
    :origin_session_id,
    :started_at,
    :ended_at,
    :artifact_dir,
    :error,
    :created_at
  ]

  # Columns an `update_status` may set. `status` is its own argument (every
  # transition writes it); `id`, `platform`, `url`, `requested_by`, and
  # `created_at` are immutable facts of the request.
  @update_fields [:started_at, :ended_at, :artifact_dir, :error]

  @select Enum.map_join(@columns, ", ", &Atom.to_string/1)
  @placeholders Enum.map_join(@columns, ", ", fn _column -> "?" end)
  @live_placeholders Enum.map_join(@live_statuses, ", ", fn _status -> "?" end)

  @schema_sql """
  CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    platform TEXT NOT NULL CHECK (platform IN ('meet','zoom')),
    url TEXT NOT NULL,
    title TEXT,
    status TEXT NOT NULL DEFAULT 'requested' CHECK (status IN (
      'requested','installing','launching','joining','knocking','admitted',
      'capturing','leaving','summarizing',
      'removed_by_host','meeting_ended','max_duration','alone_timeout',
      'delivered',
      'denied','login_required','signin_required','bot_blocked','knock_timeout','failed'
    )),
    requested_by TEXT NOT NULL CHECK (requested_by = 'operator'),
    origin_session_id TEXT,
    started_at TEXT,
    ended_at TEXT,
    artifact_dir TEXT,
    error TEXT,
    created_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_meetings_status_created
    ON meetings(status, created_at DESC);
  """

  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc "Statuses that mean a Session should be alive for this row."
  @spec live_statuses() :: [String.t()]
  def live_statuses, do: @live_statuses

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
    if Regex.match?(@timestamp_pattern, value),
      do: {:ok, value},
      else: {:error, :not_fixed_width}
  end

  def timestamp(_value), do: {:error, :not_fixed_width}

  # --- normalization (caller process) --------------------------------------

  @doc "Validates the attribute map for a new meeting row."
  @spec normalize_insert(map()) :: {:ok, map()} | {:error, term()}
  def normalize_insert(attrs) when is_map(attrs) do
    with {:ok, id} <- normalize_id(Map.get(attrs, :id)),
         {:ok, platform} <- normalize_platform(Map.get(attrs, :platform)),
         {:ok, url} <- normalize_url(Map.get(attrs, :url)),
         {:ok, title} <- normalize_title(Map.get(attrs, :title)),
         {:ok, requested_by} <- normalize_requested_by(Map.get(attrs, :requested_by, "operator")),
         {:ok, origin} <- normalize_origin(Map.get(attrs, :origin_session_id)),
         {:ok, created_at} <- normalize_stamp(:created_at, Map.get(attrs, :created_at)) do
      {:ok,
       %{
         id: id,
         platform: platform,
         url: url,
         title: title,
         status: "requested",
         requested_by: requested_by,
         origin_session_id: origin,
         started_at: nil,
         ended_at: nil,
         artifact_dir: nil,
         error: nil,
         created_at: created_at
       }}
    end
  end

  @doc """
  Validates a status transition and its side fields.

  Returns the fields as an ordered keyword list so the generated UPDATE is
  deterministic. An unknown field key is refused rather than dropped: a typo
  that silently writes nothing is the bug this boundary exists to catch.
  """
  @spec normalize_status_update(String.t(), map()) ::
          {:ok, {String.t(), keyword()}} | {:error, term()}
  def normalize_status_update(status, fields) when is_map(fields) do
    with {:ok, checked} <- normalize_status(status),
         :ok <- reject_unknown_fields(fields),
         {:ok, updates} <- normalize_update_fields(fields) do
      {:ok, {checked, updates}}
    end
  end

  @doc "Validates and clamps a `list` filter."
  @spec normalize_list_filter(map()) :: {:ok, map()} | {:error, term()}
  def normalize_list_filter(filter) when is_map(filter) do
    with {:ok, scope} <- normalize_scope(Map.get(filter, :scope, :recent)),
         {:ok, limit} <- normalize_limit(Map.get(filter, :limit, @list_default_limit)) do
      {:ok, %{scope: scope, limit: limit}}
    end
  end

  @doc "Validates the boot-sweep arguments."
  @spec normalize_sweep(String.t(), DateTime.t() | String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def normalize_sweep(error_text, now) when is_binary(error_text) do
    with {:ok, text} <- normalize_error(error_text),
         {:ok, stamp} <- normalize_stamp(:ended_at, now) do
      {:ok, {text, stamp}}
    end
  end

  def normalize_sweep(_error_text, _now), do: {:error, {:invalid, :error, :not_a_string}}

  # --- statements (single-writer process) ----------------------------------

  @spec insert(term(), map()) :: {:ok, map()} | {:error, term()}
  def insert(conn, row) when is_map(row) do
    params = Enum.map(@columns, &Map.fetch!(row, &1))

    with {:ok, rows} <-
           query_all(
             conn,
             "INSERT INTO meetings (#{@select}) VALUES (#{@placeholders}) RETURNING #{@select}",
             params
           ) do
      one_row(rows)
    end
  end

  @spec update_status(term(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def update_status(conn, id, status, updates)
      when is_binary(id) and is_binary(status) and is_list(updates) do
    assignments = Enum.map_join([:status | Keyword.keys(updates)], ", ", &"#{&1} = ?")
    params = [status | Keyword.values(updates)] ++ [id]

    with {:ok, rows} <-
           query_all(
             conn,
             "UPDATE meetings SET #{assignments} WHERE id = ? RETURNING #{@select}",
             params
           ) do
      one_row(rows)
    end
  end

  @spec fetch(term(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch(conn, id) when is_binary(id) do
    with {:ok, rows} <-
           query_all(conn, "SELECT #{@select} FROM meetings WHERE id = ? LIMIT 1", [id]) do
      one_row(rows)
    end
  end

  @spec list(term(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(conn, %{scope: :active, limit: limit}) do
    select_rows(
      conn,
      """
      SELECT #{@select} FROM meetings
      WHERE status IN (#{@live_placeholders})
      ORDER BY created_at DESC, id DESC
      LIMIT ?
      """,
      @live_statuses ++ [limit]
    )
  end

  def list(conn, %{scope: :recent, limit: limit}) do
    select_rows(
      conn,
      "SELECT #{@select} FROM meetings ORDER BY created_at DESC, id DESC LIMIT ?",
      [limit]
    )
  end

  @doc """
  Fails every row still in a live status — the daemon restarted, so no Session
  owns them any more. Returns the ids it named (bounded page); a full page is
  logged, because the UPDATE fixes more rows than the report lists.
  """
  @spec sweep_live(term(), String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def sweep_live(conn, error_text, stamp) when is_binary(error_text) and is_binary(stamp) do
    transaction(conn, fn -> sweep_live_in_tx(conn, error_text, stamp) end)
  end

  defp sweep_live_in_tx(conn, error_text, stamp) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT id FROM meetings
             WHERE status IN (#{@live_placeholders})
             ORDER BY created_at ASC, id ASC
             LIMIT ?
             """,
             @live_statuses ++ [@sweep_page]
           ),
         :ok <- sweep_update(conn, error_text, stamp) do
      ids = Enum.map(rows, fn [id] -> id end)
      log_sweep_overflow(ids)
      {:ok, ids}
    end
  end

  defp sweep_update(conn, error_text, stamp) do
    execute(
      conn,
      """
      UPDATE meetings SET status = 'failed', error = ?, ended_at = ?
      WHERE status IN (#{@live_placeholders})
      """,
      [error_text, stamp] ++ @live_statuses
    )
  end

  defp log_sweep_overflow(ids) when length(ids) < @sweep_page, do: :ok

  defp log_sweep_overflow(ids) do
    Logger.warning(
      "meetings boot sweep reported #{length(ids)} ids (page bound) — more stranded rows were failed than are listed"
    )
  end

  # --- normalization helpers -----------------------------------------------

  defp normalize_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id),
      do: {:ok, id},
      else: {:error, {:invalid, :id, :malformed}}
  end

  defp normalize_id(_id), do: {:error, {:invalid, :id, :not_a_string}}

  defp normalize_platform(platform) when platform in @platforms, do: {:ok, platform}

  defp normalize_platform(platform) when is_atom(platform) and not is_nil(platform),
    do: platform |> Atom.to_string() |> normalize_platform()

  defp normalize_platform(_platform), do: {:error, {:invalid, :platform, :unknown}}

  defp normalize_url(url) when is_binary(url) do
    cond do
      String.trim(url) == "" -> {:error, {:invalid, :url, :blank}}
      byte_size(url) > @url_max -> {:error, {:invalid, :url, :too_long}}
      true -> {:ok, url}
    end
  end

  defp normalize_url(_url), do: {:error, {:invalid, :url, :not_a_string}}

  defp normalize_title(nil), do: {:ok, nil}

  defp normalize_title(title) when is_binary(title) do
    if byte_size(title) > @title_max,
      do: {:error, {:invalid, :title, :too_long}},
      else: {:ok, title}
  end

  defp normalize_title(_title), do: {:error, {:invalid, :title, :not_a_string}}

  defp normalize_requested_by("operator"), do: {:ok, "operator"}
  defp normalize_requested_by(_value), do: {:error, {:invalid, :requested_by, :not_operator}}

  defp normalize_origin(nil), do: {:ok, nil}
  defp normalize_origin(origin) when is_binary(origin), do: {:ok, origin}
  defp normalize_origin(_origin), do: {:error, {:invalid, :origin_session_id, :not_a_string}}

  defp normalize_status(status) when status in @statuses, do: {:ok, status}
  defp normalize_status(_status), do: {:error, {:invalid, :status, :unknown}}

  defp reject_unknown_fields(fields) do
    case fields |> Map.keys() |> Enum.reject(&(&1 in @update_fields)) do
      [] -> :ok
      [key | _rest] -> {:error, {:invalid, :fields, {:unknown_key, key}}}
    end
  end

  defp normalize_update_fields(fields) do
    @update_fields
    |> Enum.filter(&Map.has_key?(fields, &1))
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case normalize_update_field(key, Map.fetch!(fields, key)) do
        {:ok, value} -> {:cont, {:ok, acc ++ [{key, value}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_update_field(key, value) when key in [:started_at, :ended_at],
    do: normalize_stamp(key, value)

  defp normalize_update_field(:artifact_dir, value) when is_binary(value) do
    if byte_size(value) > @artifact_dir_max,
      do: {:error, {:invalid, :artifact_dir, :too_long}},
      else: {:ok, value}
  end

  defp normalize_update_field(:artifact_dir, _value),
    do: {:error, {:invalid, :artifact_dir, :not_a_string}}

  defp normalize_update_field(:error, value), do: normalize_error(value)

  defp normalize_error(nil), do: {:ok, nil}

  defp normalize_error(text) when is_binary(text) do
    if byte_size(text) > @error_max,
      do: {:error, {:invalid, :error, :too_long}},
      else: {:ok, text}
  end

  defp normalize_error(_text), do: {:error, {:invalid, :error, :not_a_string}}

  defp normalize_stamp(key, value) do
    case timestamp(value) do
      {:ok, stamp} -> {:ok, stamp}
      {:error, :not_fixed_width} -> {:error, {:invalid, key, :not_fixed_width}}
    end
  end

  defp normalize_scope(scope) when scope in [:active, :recent], do: {:ok, scope}
  defp normalize_scope(_scope), do: {:error, {:invalid, :scope, :unknown}}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0,
    do: {:ok, min(limit, @list_max_limit)}

  defp normalize_limit(_limit), do: {:error, {:invalid, :limit, :not_a_positive_integer}}

  # --- rows + sqlite plumbing ----------------------------------------------

  defp select_rows(conn, sql, params) do
    with {:ok, rows} <- query_all(conn, sql, params), do: {:ok, Enum.map(rows, &meeting_row/1)}
  end

  defp one_row([row | _rest]), do: {:ok, meeting_row(row)}
  defp one_row([]), do: {:error, :not_found}

  defp meeting_row([
         id,
         platform,
         url,
         title,
         status,
         requested_by,
         origin_session_id,
         started_at,
         ended_at,
         artifact_dir,
         error,
         created_at
       ]) do
    %{
      id: id,
      platform: platform,
      url: url,
      title: title,
      status: status,
      requested_by: requested_by,
      origin_session_id: origin_session_id,
      started_at: started_at,
      ended_at: ended_at,
      artifact_dir: artifact_dir,
      error: error,
      created_at: created_at
    }
  end

  defp transaction(conn, operation) do
    case execute(conn, "BEGIN IMMEDIATE", []) do
      :ok -> finish_transaction(conn, operation.())
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_transaction(conn, {:ok, _value} = result) do
    case execute(conn, "COMMIT", []) do
      :ok -> result
      {:error, reason} -> rollback(conn, {:commit_failed, reason})
    end
  end

  defp finish_transaction(conn, {:error, reason}), do: rollback(conn, reason)

  defp rollback(conn, reason) do
    case execute(conn, "ROLLBACK", []) do
      :ok -> {:error, reason}
      {:error, rollback_reason} -> {:error, {:rollback_failed, reason, rollback_reason}}
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

  defp with_statement(conn, sql, operation) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} -> release_statement(conn, stmt, operation.(stmt))
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_statement(conn, stmt, result) do
    case Sqlite3.release(conn, stmt) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind(_stmt, []), do: :ok
  defp bind(stmt, params), do: Sqlite3.bind(stmt, params)

  defp step_result(:done), do: :ok
  defp step_result(:busy), do: {:error, :busy}
  defp step_result({:row, _row}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}

  defp pad_microseconds(%DateTime{microsecond: {value, _precision}} = at) do
    %{at | microsecond: {value, 6}}
  end
end
