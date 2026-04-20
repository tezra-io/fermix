defmodule FermixCore.Memory.Repo do
  @moduledoc """
  SQLite-backed durable memory owner for conversation history and stored facts.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Config

  @migration_version 1

  @base_schema_sql """
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    channel TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    thread_scope TEXT NOT NULL DEFAULT 'root',
    sender TEXT NOT NULL,
    role TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'chat_message',
    content TEXT NOT NULL,
    metadata_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );
  CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON messages(agent_id, channel, chat_id, thread_scope, created_at, id);

  CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    scope_type TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    category TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 1.0,
    promote_target TEXT NOT NULL DEFAULT 'none',
    source_message_id INTEGER REFERENCES messages(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_scope_key
    ON memories(agent_id, owner_id, scope_type, scope_id, key);
  """

  @type message_attrs :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_scope) => String.t() | atom() | integer(),
          required(:sender) => String.t(),
          required(:role) => String.t(),
          required(:kind) => String.t(),
          required(:content) => String.t(),
          optional(:metadata) => map() | nil,
          optional(:created_at) => DateTime.t()
        }

  @type message_selector :: %{
          required(:agent_id) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_scope) => String.t() | atom() | integer()
        }

  @type memory_attrs :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:scope_type) => String.t(),
          required(:scope_id) => String.t(),
          required(:category) => String.t(),
          required(:key) => String.t(),
          required(:value) => String.t(),
          optional(:confidence) => float(),
          optional(:promote_target) => String.t(),
          optional(:source_message_id) => integer() | nil,
          optional(:created_at) => DateTime.t(),
          optional(:updated_at) => DateTime.t()
        }

  @type memory_selector :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          optional(:scope_type) => String.t(),
          optional(:scope_id) => String.t(),
          optional(:category) => String.t(),
          optional(:key) => String.t()
        }

  @type message_row :: %{
          id: integer(),
          agent_id: String.t(),
          owner_id: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          thread_scope: String.t(),
          sender: String.t(),
          role: String.t(),
          kind: String.t(),
          content: String.t(),
          metadata: map() | nil,
          created_at: DateTime.t()
        }

  @type memory_row :: %{
          id: integer(),
          agent_id: String.t(),
          owner_id: String.t(),
          scope_type: String.t(),
          scope_id: String.t(),
          category: String.t(),
          key: String.t(),
          value: String.t(),
          confidence: float(),
          promote_target: String.t(),
          source_message_id: integer() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type state :: %{
          enabled: boolean(),
          conn: reference() | nil,
          database_path: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :enabled?)
  end

  @spec insert_message(message_attrs(), keyword()) :: {:ok, message_row()} | {:error, term()}
  def insert_message(attrs, opts \\ []) when is_map(attrs) do
    call({:insert_message, attrs}, opts)
  end

  @spec get_messages(message_selector(), keyword()) :: {:ok, [message_row()]} | {:error, term()}
  def get_messages(selector, opts \\ []) when is_map(selector) do
    call({:get_messages, selector, Keyword.get(opts, :limit, 50)}, opts)
  end

  @spec message_count(message_selector(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def message_count(selector, opts \\ []) when is_map(selector) do
    call({:message_count, selector}, opts)
  end

  @spec delete_messages(message_selector(), keyword()) :: :ok | {:error, term()}
  def delete_messages(selector, opts \\ []) when is_map(selector) do
    call({:delete_messages, selector}, opts)
  end

  @spec upsert_memory(memory_attrs(), keyword()) :: {:ok, memory_row()} | {:error, term()}
  def upsert_memory(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_memory, attrs}, opts)
  end

  @spec get_memory(memory_selector(), keyword()) ::
          {:ok, memory_row()} | {:error, :not_found | term()}
  def get_memory(selector, opts \\ []) when is_map(selector) do
    call({:get_memory, selector}, opts)
  end

  @spec get_memories(memory_selector(), keyword()) :: {:ok, [memory_row()]} | {:error, term()}
  def get_memories(selector, opts \\ []) when is_map(selector) do
    call({:get_memories, selector}, opts)
  end

  @spec delete_memory(memory_selector(), keyword()) :: :ok | {:error, term()}
  def delete_memory(selector, opts \\ []) when is_map(selector) do
    call({:delete_memory, selector}, opts)
  end

  @spec migrate(keyword()) :: :ok | {:error, term()}
  def migrate(opts \\ []) do
    call(:migrate, opts)
  end

  @spec migration_versions(keyword()) :: {:ok, [integer()]} | {:error, term()}
  def migration_versions(opts \\ []) do
    call(:migration_versions, opts)
  end

  @spec journal_mode(keyword()) :: {:ok, String.t()} | {:error, term()}
  def journal_mode(opts \\ []) do
    call(:journal_mode, opts)
  end

  @impl true
  def init(opts) do
    enabled = Config.enabled?(opts)
    database_path = Config.database_path(opts)

    case open_connection(enabled, database_path) do
      {:ok, conn} ->
        {:ok, %{enabled: true, conn: conn, database_path: database_path}}

      :disabled ->
        {:ok, %{enabled: false, conn: nil, database_path: database_path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok

  def terminate(_reason, %{conn: conn}) do
    case Sqlite3.close(conn) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  def handle_call(:migrate, _from, state) do
    {:reply, with_connection(state, &run_migrations/1), state}
  end

  def handle_call(:migration_versions, _from, state) do
    {:reply, with_connection(state, &migration_versions_for_conn/1), state}
  end

  def handle_call(:journal_mode, _from, state) do
    {:reply, with_connection(state, &journal_mode_for_conn/1), state}
  end

  def handle_call({:insert_message, attrs}, _from, state) do
    reply = with_connection(state, &insert_message_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_messages, selector, limit}, _from, state) do
    reply = with_connection(state, &fetch_messages(&1, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:message_count, selector}, _from, state) do
    reply = with_connection(state, &count_messages(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:delete_messages, selector}, _from, state) do
    reply = with_connection(state, &delete_message_rows(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:upsert_memory, attrs}, _from, state) do
    reply = with_connection(state, &upsert_memory_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_memory, selector}, _from, state) do
    reply = with_connection(state, &fetch_memory(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:get_memories, selector}, _from, state) do
    reply = with_connection(state, &fetch_memories(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:delete_memory, selector}, _from, state) do
    reply = with_connection(state, &delete_memory_row(&1, selector))
    {:reply, reply, state}
  end

  defp call(request, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, request)
  end

  defp open_connection(false, _database_path), do: :disabled

  defp open_connection(true, database_path) do
    with :ok <- ensure_database_dir(database_path),
         {:ok, conn} <- Sqlite3.open(database_path, mode: :readwrite),
         :ok <- configure_connection(conn),
         :ok <- run_migrations(conn) do
      {:ok, conn}
    end
  end

  defp ensure_database_dir(":memory:"), do: :ok

  defp ensure_database_dir(database_path) do
    database_path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp configure_connection(conn) do
    Sqlite3.execute(
      conn,
      "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"
    )
  end

  defp with_connection(%{enabled: false}, _fun), do: {:error, :disabled}
  defp with_connection(%{conn: conn}, fun), do: fun.(conn)

  defp run_migrations(conn) do
    with :ok <- ensure_schema_migrations_table(conn),
         {:ok, versions} <- migration_versions_for_conn(conn),
         :ok <- apply_base_migration(conn, versions) do
      :ok
    end
  end

  defp ensure_schema_migrations_table(conn) do
    Sqlite3.execute(
      conn,
      """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      );
      """
    )
  end

  defp apply_base_migration(conn, versions) do
    if Enum.member?(versions, @migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@base_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@migration_version});
        COMMIT;
        """
      )
    end
  end

  defp migration_versions_for_conn(conn) do
    with {:ok, rows} <-
           query_all(conn, "SELECT version FROM schema_migrations ORDER BY version ASC", []),
         do: {:ok, Enum.map(rows, fn [version] -> version end)}
  end

  defp journal_mode_for_conn(conn) do
    with {:ok, [[mode]]} <- query_all(conn, "PRAGMA journal_mode", []) do
      {:ok, String.downcase(mode)}
    end
  end

  defp insert_message_row(conn, attrs) do
    message = normalize_message_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO messages (
               agent_id,
               owner_id,
               channel,
               chat_id,
               thread_scope,
               sender,
               role,
               kind,
               content,
               metadata_json,
               created_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             message_insert_params(message)
           ),
         {:ok, [row]} <-
           query_all(conn, "SELECT * FROM messages WHERE id = last_insert_rowid()", []) do
      {:ok, message_row(row)}
    end
  end

  defp fetch_messages(conn, selector, limit) do
    message_selector = normalize_message_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM messages
             WHERE agent_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
             ORDER BY created_at DESC, id DESC
             LIMIT ?
             """,
             [
               message_selector.agent_id,
               message_selector.channel,
               message_selector.chat_id,
               message_selector.thread_scope,
               limit
             ]
           ) do
      {:ok, rows |> Enum.map(&message_row/1) |> Enum.reverse()}
    end
  end

  defp count_messages(conn, selector) do
    message_selector = normalize_message_selector(selector)

    with {:ok, [[count]]} <-
           query_all(
             conn,
             """
             SELECT COUNT(*)
             FROM messages
             WHERE agent_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
             """,
             [
               message_selector.agent_id,
               message_selector.channel,
               message_selector.chat_id,
               message_selector.thread_scope
             ]
           ) do
      {:ok, count}
    end
  end

  defp delete_message_rows(conn, selector) do
    message_selector = normalize_message_selector(selector)

    execute(
      conn,
      """
      DELETE FROM messages
      WHERE agent_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
      """,
      [
        message_selector.agent_id,
        message_selector.channel,
        message_selector.chat_id,
        message_selector.thread_scope
      ]
    )
  end

  defp upsert_memory_row(conn, attrs) do
    memory = normalize_memory_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO memories (
               agent_id,
               owner_id,
               scope_type,
               scope_id,
               category,
               key,
               value,
               confidence,
               promote_target,
               source_message_id,
               created_at,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(agent_id, owner_id, scope_type, scope_id, key)
             DO UPDATE SET
               category = excluded.category,
               value = excluded.value,
               confidence = excluded.confidence,
               promote_target = excluded.promote_target,
               source_message_id = excluded.source_message_id,
               updated_at = excluded.updated_at
             """,
             memory_insert_params(memory)
           ),
         {:ok, row} <- fetch_memory(conn, memory_lookup(memory)) do
      {:ok, row}
    end
  end

  defp fetch_memory(conn, selector) do
    {where_sql, params} = memory_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM memories
             WHERE #{where_sql}
             ORDER BY updated_at DESC, id DESC
             LIMIT 1
             """,
             params
           ) do
      case rows do
        [row] -> {:ok, memory_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_memories(conn, selector) do
    {where_sql, params} = memory_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM memories
             WHERE #{where_sql}
             ORDER BY updated_at DESC, id DESC
             """,
             params
           ) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  defp delete_memory_row(conn, selector) do
    {where_sql, params} = memory_where_clause(selector)
    execute(conn, "DELETE FROM memories WHERE #{where_sql}", params)
  end

  defp query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params),
           {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
        {:ok, rows}
      end
    end)
  end

  defp execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params),
           result <- Sqlite3.step(conn, stmt) do
        step_result(result)
      end
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
      {:ok, stmt} ->
        result = fun.(stmt)

        case Sqlite3.release(conn, stmt) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_message_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      owner_id: fetch_string!(attrs, :owner_id),
      channel: fetch_string!(attrs, :channel),
      chat_id: fetch_string!(attrs, :chat_id),
      thread_scope: normalize_thread_scope(Map.fetch!(attrs, :thread_scope)),
      sender: fetch_string!(attrs, :sender),
      role: fetch_string!(attrs, :role),
      kind: fetch_string!(attrs, :kind),
      content: fetch_string!(attrs, :content),
      metadata: Map.get(attrs, :metadata),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now()))
    }
  end

  defp normalize_message_selector(selector) do
    %{
      agent_id: fetch_string!(selector, :agent_id),
      channel: fetch_string!(selector, :channel),
      chat_id: fetch_string!(selector, :chat_id),
      thread_scope: normalize_thread_scope(Map.fetch!(selector, :thread_scope))
    }
  end

  defp normalize_memory_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      owner_id: fetch_string!(attrs, :owner_id),
      scope_type: fetch_string!(attrs, :scope_type),
      scope_id: fetch_string!(attrs, :scope_id),
      category: fetch_string!(attrs, :category),
      key: fetch_string!(attrs, :key),
      value: fetch_string!(attrs, :value),
      confidence: Map.get(attrs, :confidence, 1.0),
      promote_target: Map.get(attrs, :promote_target, "none"),
      source_message_id: Map.get(attrs, :source_message_id),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now())),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp message_insert_params(message) do
    [
      message.agent_id,
      message.owner_id,
      message.channel,
      message.chat_id,
      message.thread_scope,
      message.sender,
      message.role,
      message.kind,
      message.content,
      encode_metadata(message.metadata),
      message.created_at
    ]
  end

  defp memory_insert_params(memory) do
    [
      memory.agent_id,
      memory.owner_id,
      memory.scope_type,
      memory.scope_id,
      memory.category,
      memory.key,
      memory.value,
      memory.confidence,
      memory.promote_target,
      memory.source_message_id,
      memory.created_at,
      memory.updated_at
    ]
  end

  defp memory_lookup(memory) do
    %{
      agent_id: memory.agent_id,
      owner_id: memory.owner_id,
      scope_type: memory.scope_type,
      scope_id: memory.scope_id,
      key: memory.key
    }
  end

  defp memory_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"#{column_name(key)} = ?", params ++ [value]}
    end)
    |> then(fn {clauses, params} ->
      {Enum.join(clauses, " AND "), params}
    end)
  end

  defp column_name(:key), do: "\"key\""

  defp column_name(key) when key in [:agent_id, :owner_id, :scope_type, :scope_id, :category] do
    Atom.to_string(key)
  end

  defp message_row([
         id,
         agent_id,
         owner_id,
         channel,
         chat_id,
         thread_scope,
         sender,
         role,
         kind,
         content,
         metadata_json,
         created_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      owner_id: owner_id,
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope,
      sender: sender,
      role: role,
      kind: kind,
      content: content,
      metadata: decode_metadata(metadata_json),
      created_at: parse_timestamp!(created_at)
    }
  end

  defp memory_row([
         id,
         agent_id,
         owner_id,
         scope_type,
         scope_id,
         category,
         key,
         value,
         confidence,
         promote_target,
         source_message_id,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: scope_type,
      scope_id: scope_id,
      category: category,
      key: key,
      value: value,
      confidence: confidence * 1.0,
      promote_target: promote_target,
      source_message_id: source_message_id,
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp encode_metadata(nil), do: nil
  defp encode_metadata(metadata), do: Jason.encode!(metadata)

  defp decode_metadata(nil), do: nil
  defp decode_metadata(metadata_json), do: Jason.decode!(metadata_json)

  defp timestamp_string(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp parse_timestamp!(value) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(value)
    timestamp
  end

  defp normalize_thread_scope(:root), do: "root"
  defp normalize_thread_scope(value) when is_binary(value), do: value
  defp normalize_thread_scope(value) when is_integer(value), do: Integer.to_string(value)

  defp fetch_string!(attrs, key) do
    value = Map.fetch!(attrs, key)

    if is_binary(value) do
      value
    else
      raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end
end
