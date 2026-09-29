defmodule FermixCore.Memory.Repo.MobileSql do
  @moduledoc false

  alias Exqlite.Sqlite3

  @request_sweep_limit 200
  @max_link_previews 4
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @transports ~w(mobile companion)
  # Private-use code points bracket each match in a search excerpt; they are
  # stripped before the excerpt leaves this module, leaving plain text and the
  # ranges they marked.
  @match_open "\u{E000}"
  @match_close "\u{E001}"
  @excerpt_tokens 16

  @schema_sql """
  CREATE TABLE IF NOT EXISTS mobile_profile_state (
    agent_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    next_server_seq INTEGER NOT NULL DEFAULT 1 CHECK (next_server_seq > 0),
    read_up_to_seq INTEGER NOT NULL DEFAULT 0 CHECK (read_up_to_seq >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (agent_id, owner_id, profile_id)
  );

  CREATE TABLE IF NOT EXISTS mobile_timeline (
    agent_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    server_seq INTEGER NOT NULL CHECK (server_seq > 0),
    kind TEXT NOT NULL DEFAULT 'message',
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    client_msg_id TEXT,
    in_reply_to TEXT,
    media_refs_json TEXT NOT NULL DEFAULT '[]',
    metadata_json TEXT,
    proactive_key TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (agent_id, owner_id, profile_id, server_seq),
    FOREIGN KEY (agent_id, owner_id, profile_id)
      REFERENCES mobile_profile_state(agent_id, owner_id, profile_id)
      ON DELETE RESTRICT
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_mobile_timeline_proactive
    ON mobile_timeline(agent_id, owner_id, profile_id, proactive_key)
    WHERE proactive_key IS NOT NULL;

  CREATE TABLE IF NOT EXISTS mobile_client_requests (
    agent_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    client_msg_id TEXT NOT NULL,
    request_type TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('accepted', 'running', 'completed', 'failed')),
    payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
    payload_json TEXT NOT NULL,
    turn_id TEXT,
    result_server_seq INTEGER CHECK (result_server_seq IS NULL OR result_server_seq > 0),
    error_json TEXT,
    claimed_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (agent_id, owner_id, profile_id, client_msg_id)
  );

  CREATE INDEX IF NOT EXISTS idx_mobile_client_requests_expiry
    ON mobile_client_requests(expires_at);
  """

  @client_message_schema_sql """
  CREATE UNIQUE INDEX IF NOT EXISTS idx_mobile_timeline_client_message
    ON mobile_timeline(agent_id, owner_id, profile_id, client_msg_id)
    WHERE client_msg_id IS NOT NULL;
  """

  @attempt_fence_schema_sql """
  ALTER TABLE mobile_client_requests ADD COLUMN authenticated_device_id TEXT;
  ALTER TABLE mobile_client_requests ADD COLUMN runner_epoch TEXT;
  ALTER TABLE mobile_client_requests
    ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0);
  ALTER TABLE mobile_timeline ADD COLUMN request_client_msg_id TEXT;
  ALTER TABLE mobile_timeline
    ADD COLUMN request_attempt INTEGER CHECK (request_attempt IS NULL OR request_attempt >= 0);
  ALTER TABLE mobile_timeline ADD COLUMN output_key TEXT;

  CREATE UNIQUE INDEX idx_mobile_request_outputs
    ON mobile_timeline(
      agent_id, owner_id, profile_id, request_client_msg_id, request_attempt, output_key
    )
    WHERE output_key IS NOT NULL;

  CREATE INDEX idx_mobile_client_requests_recovery
    ON mobile_client_requests(agent_id, owner_id, status, claimed_at, profile_id, client_msg_id);
  """

  # Migration 33, the companion socket. Each durable request names the transport
  # that claimed it, so a transport's boot recovery reruns only its own requests
  # (every row before this column is a mobile one). The timeline gets an FTS5
  # index over `content`, written by triggers on the same insert, update and
  # delete that change the row, and rebuilt once for the rows already there.
  #
  # The timeline's primary key is composite, so the index follows its implicit
  # rowid. That rowid is stable because nothing here ever VACUUMs memory.db; a
  # VACUUM would renumber it and must be followed by the 'rebuild' below.
  @companion_schema_sql """
  ALTER TABLE mobile_client_requests
    ADD COLUMN transport TEXT NOT NULL DEFAULT 'mobile'
    CHECK (transport IN ('mobile', 'companion'));

  CREATE VIRTUAL TABLE IF NOT EXISTS mobile_timeline_fts
  USING fts5(content, content=mobile_timeline);

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_fts_ai AFTER INSERT ON mobile_timeline BEGIN
    INSERT INTO mobile_timeline_fts(rowid, content) VALUES (new.rowid, new.content);
  END;

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_fts_ad AFTER DELETE ON mobile_timeline BEGIN
    INSERT INTO mobile_timeline_fts(mobile_timeline_fts, rowid, content)
    VALUES ('delete', old.rowid, old.content);
  END;

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_fts_au
  AFTER UPDATE OF content ON mobile_timeline BEGIN
    INSERT INTO mobile_timeline_fts(mobile_timeline_fts, rowid, content)
    VALUES ('delete', old.rowid, old.content);
    INSERT INTO mobile_timeline_fts(rowid, content) VALUES (new.rowid, new.content);
  END;

  INSERT INTO mobile_timeline_fts(mobile_timeline_fts) VALUES ('rebuild');
  """

  # Migration 34, cancel before the queue. A `cancel` can reach a request that
  # was claimed and acknowledged but not yet handed to the queue; the mark on
  # the request is what the hand-off and boot recovery read, so the cancel is
  # not lost in that window.
  @cancel_schema_sql """
  ALTER TABLE mobile_client_requests ADD COLUMN cancelled_at TEXT;
  """

  # A claim's high-water mark of earlier attempts. Every row that carries a
  # `request_client_msg_id` is a request output with an `output_key`, so the
  # `output_key IS NOT NULL` term changes no answer; it lets the partial index
  # serve the lookup instead of a walk over the whole profile's timeline inside
  # the claim's write transaction.
  @prior_attempt_high_water_sql """
  SELECT COALESCE(MAX(request_attempt), 0) FROM mobile_timeline
  WHERE agent_id = ? AND owner_id = ? AND profile_id = ?
    AND request_client_msg_id = ? AND output_key IS NOT NULL
  """

  # The index rows for the refs one written row names: an attached file's
  # position in `media_refs_json`, or a link preview's in `previews_json`. The
  # paths index into the row's own JSON, so an entry that is not an object
  # naming a text ref is skipped and never an error in the writer's statement.
  @index_attachment_refs_sql """
  INSERT INTO mobile_timeline_media (agent_id, owner_id, profile_id, server_seq, source, idx, ref)
  SELECT new.agent_id, new.owner_id, new.profile_id, new.server_seq, 'attachment',
         CAST(refs.key AS INTEGER), json_extract(new.media_refs_json, refs.fullkey || '.ref')
  FROM json_each(
    CASE WHEN json_valid(new.media_refs_json) THEN new.media_refs_json ELSE '[]' END
  ) AS refs
  WHERE json_type(new.media_refs_json, refs.fullkey || '.ref') = 'text';
  """

  @index_preview_images_sql """
  INSERT INTO mobile_timeline_media (agent_id, owner_id, profile_id, server_seq, source, idx, ref)
  SELECT new.agent_id, new.owner_id, new.profile_id, new.server_seq, 'preview',
         CAST(previews.key AS INTEGER),
         json_extract(new.previews_json, previews.fullkey || '.image.ref')
  FROM json_each(new.previews_json) AS previews
  WHERE json_type(new.previews_json, previews.fullkey || '.image.ref') = 'text';
  """

  # Migration 36, the media index and link previews. It adds tables beside the
  # timeline and no column to it: every earlier engine decodes a timeline row
  # by position from `SELECT *`, so one more column would crash it on a
  # database this engine migrated. `media_fetch` authorizes a ref by the newest
  # row that names it, so every ref a row names (an attached file, or a link
  # preview's image) has an index row. Triggers write them in the statement
  # that writes the refs, for every writer, so the rows an older engine writes
  # after a rollback are indexed too; the backfill indexes the rows already
  # written. A row's link previews are its own cards, kept in their own row
  # beside it, never as one of its media refs.
  @media_index_schema_sql """
  CREATE TABLE IF NOT EXISTS mobile_timeline_media (
    agent_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    server_seq INTEGER NOT NULL CHECK (server_seq > 0),
    source TEXT NOT NULL CHECK (source IN ('attachment', 'preview')),
    idx INTEGER NOT NULL CHECK (idx >= 0),
    ref TEXT NOT NULL,
    PRIMARY KEY (agent_id, owner_id, profile_id, server_seq, source, idx)
  ) WITHOUT ROWID;

  CREATE INDEX IF NOT EXISTS idx_mobile_timeline_media_ref
    ON mobile_timeline_media(agent_id, owner_id, profile_id, ref, server_seq DESC, source, idx);

  CREATE TABLE IF NOT EXISTS mobile_timeline_link_previews (
    agent_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    server_seq INTEGER NOT NULL CHECK (server_seq > 0),
    previews_json TEXT NOT NULL,
    PRIMARY KEY (agent_id, owner_id, profile_id, server_seq)
  ) WITHOUT ROWID;

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_media_ai AFTER INSERT ON mobile_timeline BEGIN
    #{@index_attachment_refs_sql}
  END;

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_media_au
  AFTER UPDATE OF media_refs_json ON mobile_timeline BEGIN
    DELETE FROM mobile_timeline_media
    WHERE agent_id = old.agent_id AND owner_id = old.owner_id AND profile_id = old.profile_id
      AND server_seq = old.server_seq AND source = 'attachment';
    #{@index_attachment_refs_sql}
  END;

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_link_previews_ai
  AFTER INSERT ON mobile_timeline_link_previews BEGIN
    #{@index_preview_images_sql}
  END;

  CREATE TRIGGER IF NOT EXISTS mobile_timeline_link_previews_au
  AFTER UPDATE OF previews_json ON mobile_timeline_link_previews BEGIN
    DELETE FROM mobile_timeline_media
    WHERE agent_id = old.agent_id AND owner_id = old.owner_id AND profile_id = old.profile_id
      AND server_seq = old.server_seq AND source = 'preview';
    #{@index_preview_images_sql}
  END;

  INSERT OR IGNORE INTO mobile_timeline_media (
    agent_id, owner_id, profile_id, server_seq, source, idx, ref
  )
  SELECT timeline.agent_id, timeline.owner_id, timeline.profile_id, timeline.server_seq,
         'attachment', CAST(refs.key AS INTEGER),
         json_extract(timeline.media_refs_json, refs.fullkey || '.ref')
  FROM mobile_timeline AS timeline
  JOIN json_each(
    CASE WHEN json_valid(timeline.media_refs_json)
      THEN timeline.media_refs_json ELSE '[]' END
  ) AS refs
  WHERE json_type(timeline.media_refs_json, refs.fullkey || '.ref') = 'text';
  """

  # A timeline row as this engine reads it: its columns by name, and its link
  # previews from their own table. A column a later migration adds is never
  # decoded by position here.
  @timeline_row_sql """
  SELECT t.agent_id, t.owner_id, t.profile_id, t.server_seq, t.kind, t.role, t.content,
         t.client_msg_id, t.in_reply_to, t.media_refs_json, t.metadata_json, t.proactive_key,
         t.created_at, t.request_client_msg_id, t.request_attempt, t.output_key,
         COALESCE(p.previews_json, '[]')
  FROM mobile_timeline AS t
  LEFT JOIN mobile_timeline_link_previews AS p
    ON p.agent_id = t.agent_id AND p.owner_id = t.owner_id
   AND p.profile_id = t.profile_id AND p.server_seq = t.server_seq
  """

  # A request row as this engine reads and returns it, its columns by name.
  @request_columns """
  agent_id, owner_id, profile_id, client_msg_id, request_type, status, payload_digest,
  payload_json, turn_id, result_server_seq, error_json, claimed_at, expires_at, updated_at,
  authenticated_device_id, runner_epoch, attempt, transport, cancelled_at
  """

  # The newest row naming the ref wins, and within it an attachment before a
  # preview image, first position first.
  @media_descriptor_sql """
  SELECT media.server_seq,
         CASE media.source
           WHEN 'attachment' THEN json_extract(timeline.media_refs_json, '$[' || media.idx || ']')
           ELSE json_extract(previews.previews_json, '$[' || media.idx || '].image')
         END
  FROM mobile_timeline_media AS media
  JOIN mobile_timeline AS timeline
    ON timeline.agent_id = media.agent_id AND timeline.owner_id = media.owner_id
   AND timeline.profile_id = media.profile_id AND timeline.server_seq = media.server_seq
  LEFT JOIN mobile_timeline_link_previews AS previews
    ON previews.agent_id = media.agent_id AND previews.owner_id = media.owner_id
   AND previews.profile_id = media.profile_id AND previews.server_seq = media.server_seq
  WHERE media.agent_id = ? AND media.owner_id = ? AND media.profile_id = ? AND media.ref = ?
  ORDER BY media.server_seq DESC, media.source ASC, media.idx ASC
  LIMIT 1
  """

  @search_rows_sql """
  SELECT t.server_seq, t.role, t.created_at,
         snippet(mobile_timeline_fts, 0, ?, ?, '…', #{@excerpt_tokens})
  FROM mobile_timeline_fts
  CROSS JOIN mobile_timeline AS t ON t.rowid = mobile_timeline_fts.rowid
  WHERE mobile_timeline_fts MATCH ?
    AND t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ?
    AND (? IS NULL OR t.server_seq < ?)
  ORDER BY mobile_timeline_fts.rowid DESC LIMIT ?
  """

  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @spec client_message_schema_sql() :: String.t()
  def client_message_schema_sql, do: @client_message_schema_sql

  @spec attempt_fence_schema_sql() :: String.t()
  def attempt_fence_schema_sql, do: @attempt_fence_schema_sql

  @spec companion_schema_sql() :: String.t()
  def companion_schema_sql, do: @companion_schema_sql

  @spec cancel_schema_sql() :: String.t()
  def cancel_schema_sql, do: @cancel_schema_sql

  @spec media_index_schema_sql() :: String.t()
  def media_index_schema_sql, do: @media_index_schema_sql

  @doc "The claim's prior-attempt query, whose plan a test pins to its index."
  @spec prior_attempt_high_water_sql() :: String.t()
  def prior_attempt_high_water_sql, do: @prior_attempt_high_water_sql

  @doc "The media authorization query, whose plan a test pins to its index."
  @spec media_descriptor_sql() :: String.t()
  def media_descriptor_sql, do: @media_descriptor_sql

  @doc "The search page query, whose plan a test pins to the full-text index's order."
  @spec search_rows_sql() :: String.t()
  def search_rows_sql, do: @search_rows_sql

  @spec append(term(), map()) :: {:ok, map()} | {:error, term()}
  def append(conn, attrs) do
    timeline = normalize_timeline(attrs)
    transaction(conn, fn -> append_in_tx(conn, timeline) end)
  end

  @spec append_client_message(term(), map()) ::
          {:ok, {:created | :existing, map()}} | {:error, term()}
  def append_client_message(conn, attrs) do
    timeline = normalize_timeline(attrs)

    transaction(conn, fn ->
      case fetch_by_client_message(conn, timeline) do
        {:ok, row} -> {:ok, {:existing, row}}
        {:error, :not_found} -> create_client_message(conn, timeline)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec append_proactive(term(), map()) ::
          {:ok, {:created | :existing, map()}} | {:error, term()}
  def append_proactive(conn, attrs) do
    timeline = normalize_timeline(attrs)

    transaction(conn, fn ->
      case fetch_by_proactive(conn, timeline) do
        {:ok, row} -> {:ok, {:existing, row}}
        {:error, :not_found} -> create_proactive(conn, timeline)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec history(term(), map(), non_neg_integer(), 1..200) ::
          {:ok, map()} | {:error, term()}
  def history(conn, selector, after_seq, limit) do
    profile = normalize_profile(selector)

    with {:ok, rows} <- history_rows(conn, profile, after_seq, limit),
         {:ok, head} <- history_head(conn, profile) do
      messages = Enum.map(rows, &timeline_row/1)

      {:ok,
       %{
         messages: messages,
         next_after_seq: next_cursor(messages, after_seq),
         history_head_seq: head
       }}
    end
  end

  @doc """
  The newest `limit` rows older than `before_seq`, oldest first. The page is
  exact: `next_before_seq` is present only when an older row exists.
  """
  @spec history_before(term(), map(), pos_integer(), 1..200) ::
          {:ok, map()} | {:error, term()}
  def history_before(conn, selector, before_seq, limit) do
    profile = normalize_profile(selector)

    with {:ok, rows} <- history_rows_before(conn, profile, before_seq, limit + 1),
         {:ok, head} <- history_head(conn, profile) do
      {page, older?} = split_page(rows, limit)
      messages = page |> Enum.map(&timeline_row/1) |> Enum.reverse()

      {:ok,
       %{
         messages: messages,
         next_before_seq: older_cursor(messages, older?),
         history_head_seq: head
       }}
    end
  end

  @doc """
  Full-text search of one profile's timeline, newest first, below `before_seq`
  when given. `query` is user text, never FTS syntax: each whitespace-separated
  token becomes a quoted prefix phrase and the phrases are ANDed, so operators,
  column filters and stray quotes are literal. A query with no searchable token
  matches nothing. Each hit carries a plain-text excerpt and the ranges in it
  that matched, in Unicode scalar values.
  """
  @spec search(term(), map(), String.t(), pos_integer() | nil, pos_integer()) ::
          {:ok, %{hits: [map()], next_before_seq: pos_integer() | nil}} | {:error, term()}
  def search(conn, selector, query, before_seq, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    profile = normalize_profile(selector)

    case match_expression(query) do
      {:ok, match} -> search_matching(conn, profile, match, before_seq, limit)
      :empty -> {:ok, %{hits: [], next_before_seq: nil}}
    end
  end

  @spec history_head(term(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def history_head(conn, selector) do
    profile = normalize_profile(selector)

    with {:ok, [[head]]} <-
           query_all(
             conn,
             """
             SELECT COALESCE(MAX(server_seq), 0) FROM mobile_timeline
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ?
             """,
             profile_params(profile)
           ) do
      {:ok, head}
    end
  end

  @spec media_descriptor(term(), map(), String.t()) ::
          {:ok, %{server_seq: pos_integer(), media: map()}}
          | {:error, :not_found | {:malformed_media_descriptor, term()} | term()}
  def media_descriptor(conn, selector, ref) do
    profile = normalize_profile(selector)

    with {:ok, rows} <- query_all(conn, @media_descriptor_sql, profile_params(profile) ++ [ref]) do
      media_descriptor_result(rows, ref)
    end
  end

  @doc """
  Add one link preview to a row: its `url`, `site` and `title`, an optional
  `description`, and an optional `image` media descriptor, which `media_fetch`
  then serves through this row. A preview whose url the row already has is
  the same preview. A request output from an older attempt is refused.
  """
  @spec attach_link_preview(term(), map(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def attach_link_preview(conn, selector, server_seq, preview) do
    profile = normalize_profile(selector)

    transaction(conn, fn ->
      with :ok <- validate_link_preview(preview),
           {:ok, row} <- fetch_timeline(conn, profile, server_seq),
           :ok <- ensure_timeline_attachment_fence(conn, profile, row),
           do: append_link_preview(conn, profile, row, preview)
    end)
  end

  @doc """
  Advance the read frontier to the reported seq, clamped to the history head
  in the same transaction: it never moves back, and never past the newest row.
  A frontier stored past the head before this clamp comes back to it here.
  """
  @spec advance_read_frontier(term(), map(), non_neg_integer(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def advance_read_frontier(conn, selector, reported_seq, now) do
    profile = normalize_profile(selector)
    stamp = timestamp(now)

    transaction(conn, fn ->
      with {:ok, head} <- history_head(conn, profile),
           reported = min(reported_seq, head),
           :ok <- ensure_profile(conn, profile, stamp, reported),
           :ok <- max_merge_read_frontier(conn, profile, reported, head, stamp),
           do: read_frontier(conn, profile)
    end)
  end

  @spec read_frontier(term(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def read_frontier(conn, selector) do
    profile = normalize_profile(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT read_up_to_seq FROM mobile_profile_state
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ? LIMIT 1
             """,
             profile_params(profile)
           ) do
      read_frontier_result(rows)
    end
  end

  @spec claim_request(term(), map(), map()) ::
          {:ok, {:claimed | :duplicate | :conflict, map()}} | {:error, term()}
  def claim_request(conn, selector, attrs) do
    request = normalize_request(selector, attrs)
    transaction(conn, fn -> claim_request_in_tx(conn, request) end)
  end

  @spec get_request(term(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_request(conn, selector, client_msg_id) do
    profile = normalize_profile(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@request_columns} FROM mobile_client_requests
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
             LIMIT 1
             """,
             profile_params(profile) ++ [client_msg_id]
           ) do
      request_result(rows)
    end
  end

  @doc """
  Record a cancel on a request that has not settled, in one step: the mark
  (`cancelled_at`, set once) is what the hand-off to the queue and boot
  recovery read, so a cancel that arrives before the request is queued is
  never lost. A settled request is left as it is.
  """
  @spec cancel_request(term(), map(), String.t(), DateTime.t()) ::
          {:ok, {:marked | :settled, map()}} | {:error, term()}
  def cancel_request(conn, selector, client_msg_id, now) do
    profile = normalize_profile(selector)

    transaction(conn, fn ->
      with {:ok, rows} <-
             query_all(
               conn,
               """
               UPDATE mobile_client_requests
               SET cancelled_at = COALESCE(cancelled_at, ?), updated_at = ?
               WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
                 AND status IN ('accepted', 'running')
               RETURNING #{@request_columns}
               """,
               [timestamp(now), timestamp(now)] ++ profile_params(profile) ++ [client_msg_id]
             ) do
        cancelled_request(conn, profile, client_msg_id, rows)
      end
    end)
  end

  @doc """
  Record a cancel on every unsettled request one device claimed, in one step,
  as its revocation does: a hand-off or a boot recovery that reads the mark
  never runs the request. Answers the requests it marked.
  """
  @spec cancel_device_requests(term(), map(), String.t(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def cancel_device_requests(conn, selector, device_id, now) do
    owner = normalize_owner(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             UPDATE mobile_client_requests
             SET cancelled_at = COALESCE(cancelled_at, ?), updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND transport = 'mobile'
               AND authenticated_device_id = ? AND status IN ('accepted', 'running')
             RETURNING #{@request_columns}
             """,
             [timestamp(now), timestamp(now), owner.agent_id, owner.owner_id, device_id]
           ) do
      {:ok, Enum.map(rows, &request_row/1)}
    end
  end

  defp cancelled_request(_conn, _profile, _client_msg_id, [row]),
    do: {:ok, {:marked, request_row(row)}}

  defp cancelled_request(conn, profile, client_msg_id, []) do
    with {:ok, request} <- get_request(conn, profile, client_msg_id),
         do: {:ok, {:settled, request}}
  end

  @spec start_request(term(), map(), String.t(), String.t(), DateTime.t()) ::
          {:ok, {:started | :active | :completed | :failed, map()}} | {:error, term()}
  def start_request(conn, selector, client_msg_id, runner_epoch, now) do
    profile = normalize_profile(selector)
    epoch = nonempty_string!(runner_epoch, :runner_epoch)

    transaction(conn, fn ->
      start_request_in_tx(conn, profile, client_msg_id, epoch, now)
    end)
  end

  @spec recoverable_requests(term(), map(), String.t(), 1..200, DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def recoverable_requests(conn, selector, runner_epoch, limit, now) do
    owner = normalize_owner(selector)
    transport = transport!(selector)
    epoch = nonempty_string!(runner_epoch, :runner_epoch)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@request_columns} FROM mobile_client_requests
             WHERE agent_id = ? AND owner_id = ? AND transport = ? AND expires_at > ?
               AND (status = 'accepted' OR (status = 'running' AND runner_epoch IS NOT ?))
             ORDER BY claimed_at ASC, profile_id ASC, client_msg_id ASC
             LIMIT ?
             """,
             [owner.agent_id, owner.owner_id, transport, timestamp(now), epoch, limit]
           ) do
      {:ok, Enum.map(rows, &request_row/1)}
    end
  end

  @spec settle_request(term(), map(), String.t(), String.t(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def settle_request(conn, selector, client_msg_id, status, fields, now) do
    profile = normalize_profile(selector)
    settlement = normalize_settlement(status, fields, now)

    transaction(conn, fn ->
      settle_request_in_tx(conn, profile, client_msg_id, settlement)
    end)
  end

  @doc """
  Release a running attempt whose runner died without settling it.

  The claim returns to `accepted` with its attempt counter intact, so the next
  start — a client resend or the next boot's recovery scan — runs as a new
  attempt. Fenced on the exact attempt, so a settled or superseded request is
  never dragged back into flight.
  """
  @spec abandon_request(term(), map(), String.t(), non_neg_integer(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def abandon_request(conn, selector, client_msg_id, attempt, now) do
    profile = normalize_profile(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             UPDATE mobile_client_requests
             SET status = 'accepted', runner_epoch = NULL, updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
               AND status = 'running' AND attempt = ?
             RETURNING #{@request_columns}
             """,
             [timestamp(now)] ++ profile_params(profile) ++ [client_msg_id, attempt]
           ) do
      updated_request_result(rows)
    end
  end

  @spec append_client_output(
          term(),
          map(),
          String.t(),
          non_neg_integer(),
          String.t(),
          map(),
          DateTime.t()
        ) ::
          {:ok, {:created | :existing, map()}} | {:error, term()}
  def append_client_output(conn, selector, client_msg_id, attempt, output_key, attrs, now) do
    timeline =
      attrs
      |> Map.put_new(:created_at, now)
      |> then(&normalize_client_output(selector, client_msg_id, attempt, output_key, &1))

    transaction(conn, fn ->
      append_client_output_in_tx(conn, timeline, attempt, now)
    end)
  end

  @spec complete_request(term(), map(), String.t(), non_neg_integer(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def complete_request(conn, selector, client_msg_id, attempt, fields, now) do
    profile = normalize_profile(selector)
    settlement = normalize_settlement("completed", Map.put(fields, :attempt, attempt), now)
    transaction(conn, fn -> settle_request_in_tx(conn, profile, client_msg_id, settlement) end)
  end

  @spec append_client_response(term(), map(), String.t(), non_neg_integer(), map(), DateTime.t()) ::
          {:ok, {:created | :existing, map()}} | {:error, term()}
  def append_client_response(conn, selector, client_msg_id, attempt, attrs, now) do
    timeline =
      attrs
      |> Map.put_new(:created_at, now)
      |> then(&normalize_client_output(selector, client_msg_id, attempt, "text:final", &1))

    transaction(conn, fn ->
      with {:ok, output} <- append_client_output_in_tx(conn, timeline, attempt, now),
           {:ok, _request} <- complete_after_output(conn, timeline, attempt, output, now),
           do: {:ok, output}
    end)
  end

  @spec update_client_message(term(), map(), String.t(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def update_client_message(conn, selector, client_msg_id, attempt, attrs) do
    profile = normalize_profile(selector)

    transaction(conn, fn ->
      update_client_message_in_tx(conn, profile, client_msg_id, attempt, attrs)
    end)
  end

  defp create_proactive(conn, timeline) do
    with {:ok, row} <- append_in_tx(conn, timeline), do: {:ok, {:created, row}}
  end

  defp create_client_message(conn, timeline) do
    with {:ok, row} <- append_in_tx(conn, timeline), do: {:ok, {:created, row}}
  end

  defp append_in_tx(conn, timeline) do
    with :ok <- ensure_profile(conn, timeline, timeline.created_at),
         {:ok, server_seq} <- next_server_seq(conn, timeline),
         :ok <- insert_timeline(conn, timeline, server_seq),
         :ok <- increment_server_seq(conn, timeline, server_seq),
         do: fetch_timeline(conn, timeline, server_seq)
  end

  defp ensure_profile(conn, selector, stamp, read_up_to_seq \\ 0) do
    execute(
      conn,
      """
      INSERT INTO mobile_profile_state (
        agent_id, owner_id, profile_id, next_server_seq, read_up_to_seq, created_at, updated_at
      ) VALUES (?, ?, ?, 1, ?, ?, ?)
      ON CONFLICT(agent_id, owner_id, profile_id) DO NOTHING
      """,
      profile_params(selector) ++ [read_up_to_seq, stamp, stamp]
    )
  end

  defp next_server_seq(conn, selector) do
    with {:ok, [[server_seq]]} <-
           query_all(
             conn,
             """
             SELECT next_server_seq FROM mobile_profile_state
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ?
             """,
             profile_params(selector)
           ) do
      {:ok, server_seq}
    end
  end

  defp insert_timeline(conn, timeline, server_seq) do
    execute(
      conn,
      """
      INSERT INTO mobile_timeline (
        agent_id, owner_id, profile_id, server_seq, kind, role, content,
        client_msg_id, in_reply_to, media_refs_json, metadata_json, proactive_key, created_at,
        request_client_msg_id, request_attempt, output_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      timeline_insert_params(timeline, server_seq)
    )
  end

  defp increment_server_seq(conn, timeline, server_seq) do
    execute(
      conn,
      """
      UPDATE mobile_profile_state SET next_server_seq = ?, updated_at = ?
      WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND next_server_seq = ?
      """,
      [server_seq + 1, timeline.created_at] ++ profile_params(timeline) ++ [server_seq]
    )
  end

  defp fetch_timeline(conn, selector, server_seq) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             #{@timeline_row_sql}
             WHERE t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ? AND t.server_seq = ?
             LIMIT 1
             """,
             profile_params(selector) ++ [server_seq]
           ) do
      timeline_result(rows)
    end
  end

  defp fetch_by_proactive(conn, timeline) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             #{@timeline_row_sql}
             WHERE t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ? AND t.proactive_key = ?
             LIMIT 1
             """,
             profile_params(timeline) ++ [timeline.proactive_key]
           ) do
      timeline_result(rows)
    end
  end

  defp fetch_by_client_message(conn, timeline) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             #{@timeline_row_sql}
             WHERE t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ? AND t.client_msg_id = ?
             LIMIT 1
             """,
             profile_params(timeline) ++ [timeline.client_msg_id]
           ) do
      timeline_result(rows)
    end
  end

  defp history_rows(conn, profile, after_seq, limit) do
    query_all(
      conn,
      """
      #{@timeline_row_sql}
      WHERE t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ? AND t.server_seq > ?
      ORDER BY t.server_seq ASC LIMIT ?
      """,
      profile_params(profile) ++ [after_seq, limit]
    )
  end

  defp next_cursor([], after_seq), do: after_seq
  defp next_cursor(messages, _after_seq), do: List.last(messages).server_seq

  defp history_rows_before(conn, profile, before_seq, limit) do
    query_all(
      conn,
      """
      #{@timeline_row_sql}
      WHERE t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ? AND t.server_seq < ?
      ORDER BY t.server_seq DESC LIMIT ?
      """,
      profile_params(profile) ++ [before_seq, limit]
    )
  end

  # Rows were fetched one past the page: that extra row is the proof an older
  # page exists, and it is never shipped.
  defp split_page(rows, limit), do: {Enum.take(rows, limit), length(rows) > limit}

  defp older_cursor([oldest | _rest], true), do: oldest.server_seq
  defp older_cursor(_messages, _older?), do: nil

  defp search_matching(conn, profile, match, before_seq, limit) do
    with {:ok, rows} <- search_rows(conn, profile, match, before_seq, limit + 1) do
      {page, older?} = split_page(rows, limit)
      hits = Enum.map(page, &search_hit/1)
      {:ok, %{hits: hits, next_before_seq: older_hit_cursor(hits, older?)}}
    end
  end

  defp search_rows(conn, profile, match, before_seq, limit) do
    query_all(
      conn,
      @search_rows_sql,
      [@match_open, @match_close, match] ++
        profile_params(profile) ++ [before_seq, before_seq, limit]
    )
  end

  defp older_hit_cursor(hits, true), do: List.last(hits).server_seq
  defp older_hit_cursor(_hits, false), do: nil

  defp search_hit([server_seq, role, created_at, marked]) do
    {excerpt, ranges} = unmark_excerpt(marked)

    %{
      server_seq: server_seq,
      role: role,
      created_at: parse_timestamp!(created_at),
      excerpt: excerpt,
      ranges: ranges
    }
  end

  # Walks the marked excerpt once, counting Unicode scalar values of the text
  # that remains once the markers are gone. A marker left open by content that
  # itself contains one closes at the end of the excerpt.
  defp unmark_excerpt(marked) do
    {text, offset, ranges, open} =
      marked
      |> String.codepoints()
      |> Enum.reduce({[], 0, [], nil}, &unmark_step/2)

    ranges = if open, do: [%{start: open, length: offset - open} | ranges], else: ranges

    {text |> Enum.reverse() |> Enum.join(),
     ranges |> Enum.reverse() |> Enum.filter(&(&1.length > 0))}
  end

  defp unmark_step(@match_open, {text, offset, ranges, _open}),
    do: {text, offset, ranges, offset}

  defp unmark_step(@match_close, {text, offset, ranges, open}) when is_integer(open),
    do: {text, offset, [%{start: open, length: offset - open} | ranges], nil}

  defp unmark_step(@match_close, acc), do: acc

  defp unmark_step(char, {text, offset, ranges, open}),
    do: {[char | text], offset + 1, ranges, open}

  defp match_expression(query) do
    tokens =
      query
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.filter(&Regex.match?(~r/[\p{L}\p{N}]/u, &1))

    case tokens do
      [] -> :empty
      tokens -> {:ok, Enum.map_join(tokens, " AND ", &prefix_phrase/1)}
    end
  end

  defp prefix_phrase(token), do: ~s("#{String.replace(token, ~s("), ~s(""))}"*)

  defp max_merge_read_frontier(conn, profile, reported_seq, head, stamp) do
    execute(
      conn,
      """
      UPDATE mobile_profile_state
      SET read_up_to_seq = MIN(MAX(read_up_to_seq, ?), ?), updated_at = ?
      WHERE agent_id = ? AND owner_id = ? AND profile_id = ?
      """,
      [reported_seq, head, stamp] ++ profile_params(profile)
    )
  end

  defp read_frontier_result([[read_up_to_seq]]), do: {:ok, read_up_to_seq}
  defp read_frontier_result([]), do: {:ok, 0}

  defp claim_request_in_tx(conn, request) do
    with :ok <- delete_expired_request(conn, request),
         :ok <- sweep_expired_requests(conn, request.claimed_at) do
      case get_request(conn, request, request.client_msg_id) do
        {:ok, existing} -> classify_claim(request, existing)
        {:error, :not_found} -> insert_claim(conn, request)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp classify_claim(request, existing) do
    if existing.request_type == request.request_type and
         existing.payload_digest == request.payload_digest and
         existing.transport == request.transport do
      {:ok, {:duplicate, existing}}
    else
      {:ok, {:conflict, existing}}
    end
  end

  defp insert_claim(conn, request) do
    with {:ok, attempt} <- prior_attempt_high_water(conn, request),
         :ok <-
           execute(
             conn,
             """
             INSERT INTO mobile_client_requests (
               agent_id, owner_id, profile_id, client_msg_id, request_type, status,
               payload_digest, payload_json, turn_id, result_server_seq, error_json,
               claimed_at, expires_at, updated_at, authenticated_device_id,
               runner_epoch, attempt, transport
             ) VALUES (?, ?, ?, ?, ?, 'accepted', ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, NULL, ?, ?)
             """,
             request_insert_params(request) ++ [attempt, request.transport]
           ),
         {:ok, row} <- get_request(conn, request, request.client_msg_id) do
      {:ok, {:claimed, row}}
    end
  end

  # A claim whose TTL lapsed is deleted and re-inserted, but the previous
  # generation's output rows survive in the timeline. Resuming the attempt
  # sequence above their high-water mark keeps the fresh run's output keys
  # distinct, so its outputs are recorded instead of resolving to stale rows.
  defp prior_attempt_high_water(conn, request) do
    with {:ok, [[attempt]]} <-
           query_all(
             conn,
             @prior_attempt_high_water_sql,
             profile_params(request) ++ [request.client_msg_id]
           ) do
      {:ok, attempt}
    end
  end

  defp delete_expired_request(conn, request) do
    execute(
      conn,
      """
      DELETE FROM mobile_client_requests
      WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
        AND expires_at <= ?
      """,
      profile_params(request) ++ [request.client_msg_id, timestamp(request.claimed_at)]
    )
  end

  defp sweep_expired_requests(conn, claimed_at) do
    execute(
      conn,
      """
      DELETE FROM mobile_client_requests
      WHERE rowid IN (
        SELECT rowid FROM mobile_client_requests
        WHERE expires_at <= ?
        ORDER BY expires_at ASC
        LIMIT #{@request_sweep_limit}
      )
      """,
      [timestamp(claimed_at)]
    )
  end

  defp settle_request_in_tx(conn, profile, client_msg_id, settlement) do
    with {:ok, existing} <- get_request(conn, profile, client_msg_id),
         :ok <- matching_attempt(existing, settlement.attempt),
         :update <- request_transition(existing.status, settlement.status) do
      update_request(conn, profile, client_msg_id, settlement)
    else
      :unchanged -> get_request(conn, profile, client_msg_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_request_in_tx(conn, profile, client_msg_id, runner_epoch, now) do
    with {:ok, request} <- get_request(conn, profile, client_msg_id),
         :ok <- ensure_request_unexpired(request, now) do
      start_request_by_status(conn, profile, request, runner_epoch, now)
    end
  end

  defp ensure_request_unexpired(request, now) do
    if DateTime.compare(request.expires_at, now) == :gt, do: :ok, else: {:error, :expired}
  end

  defp start_request_by_status(_conn, _profile, %{status: "completed"} = row, _epoch, _now),
    do: {:ok, {:completed, row}}

  defp start_request_by_status(_conn, _profile, %{status: "failed"} = row, _epoch, _now),
    do: {:ok, {:failed, row}}

  defp start_request_by_status(_conn, _profile, %{status: "running"} = row, epoch, _now)
       when row.runner_epoch == epoch,
       do: {:ok, {:active, row}}

  defp start_request_by_status(conn, profile, request, epoch, now)
       when request.status in ["accepted", "running"] do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             UPDATE mobile_client_requests
             SET status = 'running', runner_epoch = ?, attempt = attempt + 1,
                 turn_id = NULL, result_server_seq = NULL, error_json = NULL, updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
               AND status = ? AND attempt = ? AND expires_at > ?
             RETURNING #{@request_columns}
             """,
             [epoch, timestamp(now)] ++
               profile_params(profile) ++
               [request.client_msg_id, request.status, request.attempt, timestamp(now)]
           ) do
      started_request_result(conn, profile, request.client_msg_id, epoch, rows)
    end
  end

  defp started_request_result(_conn, _profile, _client_msg_id, _epoch, [row]) do
    {:ok, {:started, request_row(row)}}
  end

  defp started_request_result(_conn, _profile, _client_msg_id, _epoch, []),
    do: {:error, :start_conflict}

  defp matching_attempt(%{attempt: attempt}, attempt), do: :ok
  defp matching_attempt(_request, _attempt), do: {:error, :stale_attempt}

  defp request_transition("running", _next), do: :update
  defp request_transition(status, status) when status in ["completed", "failed"], do: :unchanged

  defp request_transition(status, _next) when status in ["completed", "failed"] do
    {:error, :already_settled}
  end

  defp request_transition(_status, _next), do: {:error, :stale_attempt}

  defp update_request(conn, profile, client_msg_id, settlement) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             UPDATE mobile_client_requests
             SET status = ?, turn_id = COALESCE(?, turn_id),
                 result_server_seq = COALESCE(?, result_server_seq),
                 error_json = COALESCE(?, error_json), updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
               AND status = 'running' AND attempt = ?
             RETURNING #{@request_columns}
             """,
             settlement_params(settlement) ++
               profile_params(profile) ++ [client_msg_id, settlement.attempt]
           ) do
      updated_request_result(rows)
    end
  end

  defp updated_request_result([row]), do: {:ok, request_row(row)}
  defp updated_request_result([]), do: {:error, :stale_attempt}

  defp append_client_output_in_tx(conn, timeline, attempt, now) do
    with {:ok, request} <- get_request(conn, timeline, timeline.request_client_msg_id),
         :ok <- ensure_running_attempt(request, attempt),
         {:ok, output} <- find_or_append_output(conn, timeline),
         :ok <- record_output_result(conn, timeline, attempt, output, now) do
      {:ok, output}
    end
  end

  defp ensure_running_attempt(%{status: "running", attempt: attempt}, attempt), do: :ok
  defp ensure_running_attempt(_request, _attempt), do: {:error, :stale_attempt}

  defp find_or_append_output(conn, timeline) do
    case fetch_by_output(conn, timeline) do
      {:ok, row} -> {:ok, {:existing, row}}
      {:error, :not_found} -> append_new_output(conn, timeline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_by_output(conn, timeline) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             #{@timeline_row_sql}
             WHERE t.agent_id = ? AND t.owner_id = ? AND t.profile_id = ?
               AND t.request_client_msg_id = ? AND t.request_attempt = ? AND t.output_key = ?
             LIMIT 1
             """,
             profile_params(timeline) ++
               [timeline.request_client_msg_id, timeline.request_attempt, timeline.output_key]
           ) do
      timeline_result(rows)
    end
  end

  defp append_new_output(conn, timeline) do
    with {:ok, row} <- append_in_tx(conn, timeline), do: {:ok, {:created, row}}
  end

  defp record_output_result(conn, timeline, attempt, {_state, row}, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             UPDATE mobile_client_requests
             SET result_server_seq = CASE
                   WHEN result_server_seq IS NULL OR result_server_seq < ? THEN ?
                   ELSE result_server_seq
                 END,
                 updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ? AND client_msg_id = ?
               AND status = 'running' AND attempt = ?
             RETURNING client_msg_id
             """,
             [row.server_seq, row.server_seq, timestamp(now)] ++
               profile_params(timeline) ++ [timeline.request_client_msg_id, attempt]
           ) do
      output_result_update(rows)
    end
  end

  defp output_result_update([[_client_msg_id]]), do: :ok
  defp output_result_update([]), do: {:error, :stale_attempt}

  defp complete_after_output(conn, timeline, attempt, {_state, row}, now) do
    settlement =
      normalize_settlement(
        "completed",
        %{attempt: attempt, result_server_seq: row.server_seq},
        now
      )

    settle_request_in_tx(conn, timeline, timeline.request_client_msg_id, settlement)
  end

  defp update_client_message_in_tx(conn, profile, client_msg_id, attempt, attrs) do
    with {:ok, request} <- get_request(conn, profile, client_msg_id),
         :ok <- ensure_running_attempt(request, attempt),
         {:ok, current} <-
           fetch_by_client_message(conn, Map.put(profile, :client_msg_id, client_msg_id)),
         :ok <- ensure_user_message(current),
         {:ok, update} <- normalize_client_update(attrs, current),
         do: update_client_message_row(conn, profile, client_msg_id, update)
  end

  defp ensure_user_message(%{role: "user"}), do: :ok
  defp ensure_user_message(_row), do: {:error, :not_found}

  defp normalize_client_update(attrs, current) do
    allowed = MapSet.new([:content, :media_refs, :metadata])

    case Enum.find(Map.keys(attrs), &(not MapSet.member?(allowed, &1))) do
      nil -> {:ok, client_update(attrs, current)}
      key -> {:error, {:invalid_update_field, key}}
    end
  end

  defp client_update(attrs, current) do
    %{
      content: optional_update(attrs, :content, current.content, &string_value!(&1, :content)),
      media_refs: optional_update(attrs, :media_refs, current.media_refs, &media_refs!/1),
      metadata: Map.get(attrs, :metadata, current.metadata)
    }
  end

  defp optional_update(attrs, key, current, normalize) do
    if Map.has_key?(attrs, key), do: normalize.(Map.fetch!(attrs, key)), else: current
  end

  # The caller read this user row in the same transaction; it is read back,
  # with its previews, once rewritten.
  defp update_client_message_row(conn, profile, client_msg_id, update) do
    with :ok <-
           execute(
             conn,
             """
             UPDATE mobile_timeline
             SET content = ?, media_refs_json = ?, metadata_json = ?
             WHERE agent_id = ? AND owner_id = ? AND profile_id = ?
               AND client_msg_id = ? AND role = 'user'
             """,
             [update.content, Jason.encode!(update.media_refs), encode_json(update.metadata)] ++
               profile_params(profile) ++ [client_msg_id]
           ),
         do: fetch_by_client_message(conn, Map.put(profile, :client_msg_id, client_msg_id))
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

  defp normalize_profile(attrs) do
    %{
      agent_id: string!(attrs, :agent_id),
      owner_id: string!(attrs, :owner_id),
      profile_id: string!(attrs, :profile_id)
    }
  end

  defp normalize_owner(attrs) do
    %{
      agent_id: string!(attrs, :agent_id),
      owner_id: string!(attrs, :owner_id)
    }
  end

  defp transport!(attrs) do
    case Map.fetch!(attrs, :transport) do
      transport when transport in @transports ->
        transport

      value ->
        raise ArgumentError,
              "expected :transport in #{inspect(@transports)}, got: #{inspect(value)}"
    end
  end

  # A mobile claim names the Noise-authenticated device that made it; the
  # companion socket's trust is the 0600 socket itself, so it names no device.
  defp claimant_device!(attrs, "mobile"),
    do: nonempty_string!(Map.fetch!(attrs, :authenticated_device_id), :authenticated_device_id)

  defp claimant_device!(attrs, "companion") do
    case Map.get(attrs, :authenticated_device_id) do
      nil -> nil
      value -> raise ArgumentError, "a companion claim names no device, got: #{inspect(value)}"
    end
  end

  defp normalize_timeline(attrs) do
    attrs
    |> normalize_profile()
    |> Map.merge(%{
      kind: optional_string!(attrs, :kind) || "message",
      role: string!(attrs, :role),
      content: string!(attrs, :content),
      client_msg_id: optional_string!(attrs, :client_msg_id),
      in_reply_to: optional_string!(attrs, :in_reply_to),
      media_refs: media_refs!(Map.get(attrs, :media_refs, [])),
      metadata: Map.get(attrs, :metadata),
      proactive_key: optional_string!(attrs, :proactive_key),
      request_client_msg_id: optional_string!(attrs, :request_client_msg_id),
      request_attempt: optional_nonnegative_integer!(attrs, :request_attempt),
      output_key: optional_string!(attrs, :output_key),
      created_at: timestamp(Map.get(attrs, :created_at, DateTime.utc_now()))
    })
  end

  defp normalize_client_output(selector, client_msg_id, attempt, output_key, attrs) do
    attrs
    |> Map.merge(normalize_profile(selector))
    |> Map.put(:role, "assistant")
    |> Map.put(:in_reply_to, client_msg_id)
    |> Map.put(:request_client_msg_id, client_msg_id)
    |> Map.put(:request_attempt, attempt)
    |> Map.put(:output_key, output_key)
    |> normalize_timeline()
  end

  defp normalize_request(selector, attrs) do
    transport = transport!(attrs)

    selector
    |> normalize_profile()
    |> Map.merge(%{
      client_msg_id: string!(attrs, :client_msg_id),
      request_type: string!(attrs, :request_type),
      payload: Map.fetch!(attrs, :payload),
      payload_digest: digest!(attrs, :payload_digest),
      transport: transport,
      authenticated_device_id: claimant_device!(attrs, transport),
      claimed_at: datetime!(attrs, :claimed_at),
      expires_at: datetime!(attrs, :expires_at)
    })
  end

  defp normalize_settlement(status, fields, now) do
    %{
      status: string_value!(status, :status),
      turn_id: optional_string!(fields, :turn_id),
      result_server_seq: optional_positive_integer!(fields, :result_server_seq),
      error: Map.get(fields, :error),
      attempt: nonnegative_integer!(fields, :attempt),
      updated_at: timestamp(now)
    }
  end

  defp profile_params(profile), do: [profile.agent_id, profile.owner_id, profile.profile_id]

  defp timeline_insert_params(timeline, server_seq) do
    profile_params(timeline) ++
      [
        server_seq,
        timeline.kind,
        timeline.role,
        timeline.content,
        timeline.client_msg_id,
        timeline.in_reply_to,
        Jason.encode!(timeline.media_refs),
        encode_json(timeline.metadata),
        timeline.proactive_key,
        timeline.created_at,
        timeline.request_client_msg_id,
        timeline.request_attempt,
        timeline.output_key
      ]
  end

  defp request_insert_params(request) do
    profile_params(request) ++
      [
        request.client_msg_id,
        request.request_type,
        request.payload_digest,
        Jason.encode!(request.payload),
        timestamp(request.claimed_at),
        timestamp(request.expires_at),
        timestamp(request.claimed_at),
        request.authenticated_device_id
      ]
  end

  defp settlement_params(settlement) do
    [
      settlement.status,
      settlement.turn_id,
      settlement.result_server_seq,
      encode_json(settlement.error),
      settlement.updated_at
    ]
  end

  defp timeline_result([row]), do: {:ok, timeline_row(row)}
  defp timeline_result([]), do: {:error, :not_found}
  defp request_result([row]), do: {:ok, request_row(row)}
  defp request_result([]), do: {:error, :not_found}

  defp media_descriptor_result([[server_seq, media_json]], ref) do
    with {:ok, media} <- decode_media_descriptor(media_json),
         :ok <- validate_media_descriptor(media, ref) do
      {:ok, %{server_seq: server_seq, media: media}}
    end
  end

  defp media_descriptor_result([], _ref), do: {:error, :not_found}

  defp decode_media_descriptor(media_json) do
    case Jason.decode(media_json) do
      {:ok, media} when is_map(media) -> {:ok, media}
      {:ok, _value} -> malformed_descriptor(:not_an_object)
      {:error, _reason} -> malformed_descriptor(:invalid_json)
    end
  end

  defp validate_media_descriptor(media, ref) do
    with :ok <- required_descriptor_value(media, "ref", &(&1 == ref and valid_digest?(&1))),
         :ok <- required_descriptor_value(media, "kind", &nonempty_string?/1),
         :ok <- required_descriptor_value(media, "mime", &nonempty_string?/1),
         :ok <- required_descriptor_value(media, "size_bytes", &nonnegative_integer?/1),
         do: optional_descriptor_digest(media, ref)
  end

  defp required_descriptor_value(media, key, valid?) do
    case Map.fetch(media, key) do
      {:ok, value} -> if valid?.(value), do: :ok, else: malformed_field(key)
      :error -> malformed_descriptor({:missing_field, key})
    end
  end

  defp optional_descriptor_digest(media, ref) do
    case Map.fetch(media, "sha256") do
      :error -> :ok
      {:ok, ^ref} -> :ok
      {:ok, _value} -> malformed_field("sha256")
    end
  end

  defp malformed_field(key), do: malformed_descriptor({:invalid_field, key})
  defp malformed_descriptor(reason), do: {:error, {:malformed_media_descriptor, reason}}
  defp nonempty_string?(value), do: is_binary(value) and value != ""
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@sha256, value)

  # What a stored preview may hold: a url, a site and a title, text when
  # present, and an image that is a well-formed media descriptor of its own
  # ref. An absent field is an absent key, never a null.
  defp validate_link_preview(preview) when is_map(preview) do
    with :ok <- known_preview_keys(preview),
         :ok <- required_preview_text(preview, ~w(url site title)),
         :ok <- optional_preview_text(preview, "description") do
      preview_image(Map.fetch(preview, "image"))
    end
  end

  defp validate_link_preview(_preview), do: invalid_preview(:not_a_map)

  defp known_preview_keys(preview) do
    case Map.keys(preview) -- ~w(url site title description image) do
      [] -> :ok
      [key | _rest] -> invalid_preview({:unknown_field, key})
    end
  end

  defp required_preview_text(preview, keys) do
    case Enum.find(keys, &(not nonempty_string?(Map.get(preview, &1)))) do
      nil -> :ok
      key -> invalid_preview({:invalid_field, key})
    end
  end

  defp optional_preview_text(preview, key) do
    case Map.fetch(preview, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, _value} -> invalid_preview({:invalid_field, key})
    end
  end

  defp preview_image(:error), do: :ok

  defp preview_image({:ok, %{"ref" => ref} = image}) do
    case validate_media_descriptor(image, ref) do
      :ok -> :ok
      {:error, {:malformed_media_descriptor, reason}} -> invalid_preview({:image, reason})
    end
  end

  defp preview_image({:ok, _image}), do: invalid_preview({:image, {:missing_field, "ref"}})

  defp invalid_preview(reason), do: {:error, {:invalid_link_preview, reason}}

  # The unfurler asks for at most two previews a row; this bounds what any
  # caller can pile onto one row.
  defp append_link_preview(conn, profile, row, preview) do
    cond do
      Enum.any?(row.link_previews, &(&1["url"] == preview["url"])) ->
        {:ok, row}

      length(row.link_previews) >= @max_link_previews ->
        {:error, {:too_many_link_previews, @max_link_previews}}

      true ->
        update_link_previews(conn, profile, row, row.link_previews ++ [preview])
    end
  end

  # A row's previews are one row of their own, keyed like it; its triggers
  # index their images.
  defp update_link_previews(conn, profile, row, previews) do
    with :ok <-
           execute(
             conn,
             """
             INSERT INTO mobile_timeline_link_previews (
               agent_id, owner_id, profile_id, server_seq, previews_json
             ) VALUES (?, ?, ?, ?, ?)
             ON CONFLICT (agent_id, owner_id, profile_id, server_seq)
             DO UPDATE SET previews_json = excluded.previews_json
             """,
             profile_params(profile) ++ [row.server_seq, Jason.encode!(previews)]
           ),
         do: fetch_timeline(conn, profile, row.server_seq)
  end

  defp ensure_timeline_attachment_fence(_conn, _profile, %{request_client_msg_id: nil}), do: :ok

  defp ensure_timeline_attachment_fence(conn, profile, row) do
    with {:ok, request} <- get_request(conn, profile, row.request_client_msg_id) do
      matching_attempt(request, row.request_attempt)
    end
  end

  defp timeline_row([
         agent_id,
         owner_id,
         profile_id,
         server_seq,
         kind,
         role,
         content,
         client_msg_id,
         in_reply_to,
         media_refs_json,
         metadata_json,
         proactive_key,
         created_at,
         request_client_msg_id,
         request_attempt,
         output_key,
         previews_json
       ]) do
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      profile_id: profile_id,
      server_seq: server_seq,
      kind: kind,
      role: role,
      content: content,
      client_msg_id: client_msg_id,
      in_reply_to: in_reply_to,
      media_refs: Jason.decode!(media_refs_json),
      metadata: decode_json(metadata_json),
      proactive_key: proactive_key,
      request_client_msg_id: request_client_msg_id,
      request_attempt: request_attempt,
      output_key: output_key,
      link_previews: Jason.decode!(previews_json),
      created_at: parse_timestamp!(created_at)
    }
  end

  defp request_row([
         agent_id,
         owner_id,
         profile_id,
         client_msg_id,
         request_type,
         status,
         payload_digest,
         payload_json,
         turn_id,
         result_server_seq,
         error_json,
         claimed_at,
         expires_at,
         updated_at,
         authenticated_device_id,
         runner_epoch,
         attempt,
         transport,
         cancelled_at
       ]) do
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      profile_id: profile_id,
      client_msg_id: client_msg_id,
      request_type: request_type,
      status: status,
      payload_digest: payload_digest,
      payload: Jason.decode!(payload_json),
      turn_id: turn_id,
      result_server_seq: result_server_seq,
      error: decode_json(error_json),
      authenticated_device_id: authenticated_device_id,
      runner_epoch: runner_epoch,
      attempt: attempt,
      transport: transport,
      cancelled_at: cancelled_at && parse_timestamp!(cancelled_at),
      claimed_at: parse_timestamp!(claimed_at),
      expires_at: parse_timestamp!(expires_at),
      updated_at: parse_timestamp!(updated_at)
    }
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

  defp string!(attrs, key), do: attrs |> Map.fetch!(key) |> string_value!(key)
  defp string_value!(value, _key) when is_binary(value), do: value

  defp string_value!(value, key) do
    raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
  end

  defp nonempty_string!(value, key) do
    if is_binary(value) and value != "" do
      value
    else
      raise ArgumentError, "expected #{inspect(key)} to be a non-empty string"
    end
  end

  defp optional_string!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> string_value!(value, key)
    end
  end

  defp optional_positive_integer!(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        nil

      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "expected #{inspect(key)} to be a positive integer, got: #{inspect(value)}"
    end
  end

  defp optional_nonnegative_integer!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> nonnegative_integer!(attrs, key, value)
    end
  end

  defp nonnegative_integer!(attrs, key) do
    attrs |> Map.fetch!(key) |> then(&nonnegative_integer!(attrs, key, &1))
  end

  defp nonnegative_integer!(_attrs, _key, value) when is_integer(value) and value >= 0,
    do: value

  defp nonnegative_integer!(_attrs, key, value) do
    raise ArgumentError,
          "expected #{inspect(key)} to be a non-negative integer, got: #{inspect(value)}"
  end

  defp media_refs!(refs) when is_list(refs) do
    Enum.map(refs, fn
      ref when is_map(ref) -> ref
      value -> raise ArgumentError, "expected media_refs to contain maps, got: #{inspect(value)}"
    end)
  end

  defp media_refs!(value),
    do: raise(ArgumentError, "expected media_refs to be a list, got: #{inspect(value)}")

  defp digest!(attrs, key) do
    value = string!(attrs, key)

    if byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/) do
      value
    else
      raise ArgumentError, "expected #{inspect(key)} to be a lowercase SHA-256 digest"
    end
  end

  defp datetime!(attrs, key) do
    case Map.fetch!(attrs, key) do
      %DateTime{} = value ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a DateTime, got: #{inspect(value)}"
    end
  end

  defp encode_json(nil), do: nil
  defp encode_json(value), do: Jason.encode!(value)
  defp decode_json(nil), do: nil
  defp decode_json(value), do: Jason.decode!(value)

  defp timestamp(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> then(fn timestamp -> %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}} end)
    |> DateTime.to_iso8601()
  end

  defp timestamp(value) when is_binary(value), do: value

  defp parse_timestamp!(value) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(value)
    timestamp
  end
end
