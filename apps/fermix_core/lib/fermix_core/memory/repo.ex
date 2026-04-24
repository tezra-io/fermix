defmodule FermixCore.Memory.Repo do
  @moduledoc """
  SQLite-backed durable memory owner for conversation history and stored facts.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Scope

  @base_migration_version 1
  @fts_migration_version 2
  @resource_migration_version 3
  @sqlite_open_intent :readwritecreate

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

  @fts_schema_sql """
  CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
  USING fts5(category, key, value, content=memories, content_rowid=id);

  CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
    INSERT INTO memories_fts(rowid, category, key, value)
    VALUES (new.id, new.category, new.key, new.value);
  END;

  CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, category, key, value)
    VALUES('delete', old.id, old.category, old.key, old.value);
  END;

  CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, category, key, value)
    VALUES('delete', old.id, old.category, old.key, old.value);
    INSERT INTO memories_fts(rowid, category, key, value)
    VALUES (new.id, new.category, new.key, new.value);
  END;

  CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
  USING fts5(role, kind, content, content=messages, content_rowid=id);

  CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, role, kind, content)
    VALUES (new.id, new.role, new.kind, new.content);
  END;

  CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, role, kind, content)
    VALUES('delete', old.id, old.role, old.kind, old.content);
  END;

  CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, role, kind, content)
    VALUES('delete', old.id, old.role, old.kind, old.content);
    INSERT INTO messages_fts(rowid, role, kind, content)
    VALUES (new.id, new.role, new.kind, new.content);
  END;
  """

  @resource_schema_sql """
  CREATE TABLE IF NOT EXISTS resources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    resource_type TEXT NOT NULL,
    scope_id TEXT NOT NULL DEFAULT 'global',
    resource_path TEXT,
    current_revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_resources_type_scope
    ON resources(agent_id, resource_type, scope_id);

  CREATE TABLE IF NOT EXISTS resource_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    resource_type TEXT NOT NULL,
    scope_id TEXT NOT NULL DEFAULT 'global',
    revision INTEGER NOT NULL,
    parent_revision INTEGER,
    content_hash TEXT NOT NULL,
    content TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    mutation_source TEXT NOT NULL,
    provenance_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_revisions_resource_version
    ON resource_revisions(agent_id, resource_type, scope_id, revision);

  CREATE INDEX IF NOT EXISTS idx_revisions_latest
    ON resource_revisions(agent_id, resource_type, scope_id, created_at DESC);
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
          required(:thread_scope) => String.t() | atom() | integer(),
          optional(:owner_id) => String.t(),
          optional(:role) => String.t(),
          optional(:kind) => String.t()
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

  @type memory_key_selector :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          optional(:scope_type) => String.t(),
          optional(:scope_id) => String.t(),
          optional(:category) => String.t(),
          required(:key) => String.t()
        }

  @type resource_attrs :: %{
          required(:agent_id) => String.t(),
          required(:resource_type) => String.t(),
          required(:scope_id) => String.t(),
          required(:current_revision) => non_neg_integer(),
          optional(:resource_path) => String.t() | nil
        }

  @type resource_selector :: %{
          required(:agent_id) => String.t(),
          required(:resource_type) => String.t(),
          required(:scope_id) => String.t()
        }

  @type revision_attrs :: %{
          required(:agent_id) => String.t(),
          required(:resource_type) => String.t(),
          required(:scope_id) => String.t(),
          required(:revision) => pos_integer(),
          required(:parent_revision) => pos_integer() | nil,
          required(:content_hash) => String.t(),
          required(:content) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:mutation_source) => String.t(),
          optional(:provenance) => map() | nil
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

  @type message_search_row :: %{
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
          created_at: DateTime.t(),
          rank: float()
        }

  @type message_search_selector :: %{
          required(:agent_id) => String.t(),
          optional(:owner_id) => String.t(),
          optional(:channel) => String.t(),
          optional(:chat_id) => String.t(),
          optional(:thread_scope) => String.t() | atom() | integer(),
          optional(:role) => String.t(),
          optional(:kind) => String.t()
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

  @type memory_search_row :: %{
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
          updated_at: DateTime.t(),
          rank: float()
        }

  @type resource_row :: %{
          id: integer(),
          agent_id: String.t(),
          resource_type: String.t(),
          scope_id: String.t(),
          resource_path: String.t() | nil,
          current_revision: non_neg_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type resource_revision_row :: %{
          id: integer(),
          agent_id: String.t(),
          resource_type: String.t(),
          scope_id: String.t(),
          revision: pos_integer(),
          parent_revision: pos_integer() | nil,
          content_hash: String.t(),
          content: String.t(),
          byte_size: non_neg_integer(),
          mutation_source: String.t(),
          provenance: map() | nil,
          created_at: DateTime.t()
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

  @spec enabled_server(pid() | atom()) :: pid() | atom() | nil
  def enabled_server(server) when is_pid(server), do: server

  def enabled_server(server) when is_atom(server) do
    if safely_enabled?(server) do
      server
    end
  end

  defp safely_enabled?(server) do
    enabled?(server: server)
  catch
    :exit, {:noproc, _call} -> false
    :exit, {:normal, _call} -> false
    :exit, {:shutdown, _call} -> false
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

  @doc """
  Deletes one memory selected by key and scope.

  Use `delete_memories/2` for bulk deletes by scope or category.
  """
  @spec delete_memory(memory_key_selector(), keyword()) :: :ok | {:error, term()}
  def delete_memory(selector, opts \\ []) when is_map(selector) do
    with {:ok, selector} <- require_memory_key(selector) do
      call({:delete_memory, selector}, opts)
    end
  end

  @doc """
  Deletes all memories matching the selector.
  """
  @spec delete_memories(memory_selector(), keyword()) :: :ok | {:error, term()}
  def delete_memories(selector, opts \\ []) when is_map(selector) do
    call({:delete_memories, selector}, opts)
  end

  @spec search_memories(String.t(), keyword()) :: {:ok, [memory_search_row()]} | {:error, term()}
  def search_memories(query, opts \\ []) when is_binary(query) do
    call(
      {:search_memories, query, Keyword.get(opts, :selector, %{}), Keyword.get(opts, :limit, 10)},
      opts
    )
  end

  @spec search_messages(String.t(), keyword()) :: {:ok, [message_search_row()]} | {:error, term()}
  def search_messages(query, opts \\ []) when is_binary(query) do
    call(
      {:search_messages, query, Keyword.get(opts, :selector, %{}), Keyword.get(opts, :limit, 10)},
      opts
    )
  end

  @spec upsert_resource(resource_attrs(), keyword()) :: {:ok, resource_row()} | {:error, term()}
  def upsert_resource(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_resource, attrs}, opts)
  end

  @spec get_resource(resource_selector(), keyword()) ::
          {:ok, resource_row()} | {:error, :not_found | term()}
  def get_resource(selector, opts \\ []) when is_map(selector) do
    call({:get_resource, selector}, opts)
  end

  @spec insert_revision(revision_attrs(), keyword()) ::
          {:ok, resource_revision_row()} | {:error, term()}
  def insert_revision(attrs, opts \\ []) when is_map(attrs) do
    call({:insert_revision, attrs}, opts)
  end

  @spec commit_resource_revision(map(), keyword()) ::
          {:ok, resource_revision_row() | :unchanged} | {:error, term()}
  def commit_resource_revision(attrs, opts \\ []) when is_map(attrs) do
    call({:commit_resource_revision, attrs}, opts)
  end

  @spec get_revision(map(), keyword()) ::
          {:ok, resource_revision_row()} | {:error, :not_found | term()}
  def get_revision(selector, opts \\ []) when is_map(selector) do
    call({:get_revision, selector}, opts)
  end

  @spec get_latest_revision(resource_selector(), keyword()) ::
          {:ok, resource_revision_row()} | {:error, :not_found | term()}
  def get_latest_revision(selector, opts \\ []) when is_map(selector) do
    call({:get_latest_revision, selector}, opts)
  end

  @spec list_revisions(resource_selector(), keyword()) ::
          {:ok, [resource_revision_row()]} | {:error, term()}
  def list_revisions(selector, opts \\ []) when is_map(selector) do
    call(
      {:list_revisions, selector, Keyword.get(opts, :limit, 20), Keyword.get(opts, :offset, 0)},
      opts
    )
  end

  @spec revision_count(resource_selector(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revision_count(selector, opts \\ []) when is_map(selector) do
    call({:revision_count, selector}, opts)
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

  def handle_call({:delete_memories, selector}, _from, state) do
    reply = with_connection(state, &delete_memory_row(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:search_memories, query, selector, limit}, _from, state) do
    reply = with_connection(state, &search_memory_rows(&1, query, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:search_messages, query, selector, limit}, _from, state) do
    reply = with_connection(state, &search_message_rows(&1, query, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:upsert_resource, attrs}, _from, state) do
    reply = with_connection(state, &upsert_resource_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_resource, selector}, _from, state) do
    reply = with_connection(state, &fetch_resource(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:insert_revision, attrs}, _from, state) do
    reply = with_connection(state, &insert_revision_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:commit_resource_revision, attrs}, _from, state) do
    reply = with_connection(state, &commit_resource_revision_tx(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_revision, selector}, _from, state) do
    reply = with_connection(state, &fetch_revision(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:get_latest_revision, selector}, _from, state) do
    reply = with_connection(state, &fetch_latest_revision(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:list_revisions, selector, limit, offset}, _from, state) do
    reply = with_connection(state, &fetch_revisions(&1, selector, limit, offset))
    {:reply, reply, state}
  end

  def handle_call({:revision_count, selector}, _from, state) do
    reply = with_connection(state, &count_revisions(&1, selector))
    {:reply, reply, state}
  end

  defp call(request, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, request)
  end

  defp open_connection(false, _database_path), do: :disabled

  defp open_connection(true, database_path) do
    with :ok <- ensure_database_dir(database_path),
         {:ok, conn} <- Sqlite3.open(database_path, sqlite_open_opts(@sqlite_open_intent)),
         :ok <- configure_connection(conn),
         :ok <- run_migrations(conn) do
      {:ok, conn}
    end
  end

  defp sqlite_open_opts(:readwritecreate) do
    # Exqlite exposes SQLite READWRITE | CREATE as :readwrite.
    [mode: :readwrite]
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
         :ok <- apply_base_migration(conn, versions),
         :ok <- apply_fts_migration(conn, versions),
         :ok <- apply_resource_migration(conn, versions) do
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
    if Enum.member?(versions, @base_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@base_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@base_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_fts_migration(conn, versions) do
    if Enum.member?(versions, @fts_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@fts_schema_sql}
        INSERT INTO memories_fts(memories_fts) VALUES('rebuild');
        INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
        INSERT INTO schema_migrations(version) VALUES (#{@fts_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_resource_migration(conn, versions) do
    if Enum.member?(versions, @resource_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@resource_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@resource_migration_version});
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
    with {:ok, {where_sql, params}} <- message_fetch_where_clause(selector),
         {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM messages
             WHERE #{where_sql}
             ORDER BY created_at DESC, id DESC
             LIMIT ?
             """,
             params ++ [limit]
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

  defp search_memory_rows(conn, query, selector, limit) do
    {where_sql, params} = search_memory_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT
               memories.*,
               bm25(memories_fts) AS rank
             FROM memories_fts
             JOIN memories ON memories.id = memories_fts.rowid
             WHERE memories_fts MATCH ? AND #{where_sql}
             ORDER BY bm25(memories_fts), memories.updated_at DESC, memories.id DESC
             LIMIT ?
             """,
             [query | params] ++ [limit]
           ) do
      {:ok, Enum.map(rows, &memory_search_row/1)}
    end
  end

  defp search_message_rows(conn, query, selector, limit) do
    {where_sql, params} = message_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT
               messages.*,
               bm25(messages_fts) AS rank
             FROM messages_fts
             JOIN messages ON messages.id = messages_fts.rowid
             WHERE messages_fts MATCH ? AND #{where_sql}
             ORDER BY bm25(messages_fts), messages.created_at DESC, messages.id DESC
             LIMIT ?
             """,
             [query | params] ++ [limit]
           ) do
      {:ok, Enum.map(rows, &message_search_row/1)}
    end
  end

  defp upsert_resource_row(conn, attrs) do
    resource = normalize_resource_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO resources (
               agent_id,
               resource_type,
               scope_id,
               resource_path,
               current_revision,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(agent_id, resource_type, scope_id)
             DO UPDATE SET
               resource_path = COALESCE(excluded.resource_path, resources.resource_path),
               current_revision = excluded.current_revision,
               updated_at = excluded.updated_at
             """,
             resource_upsert_params(resource)
           ),
         {:ok, row} <- fetch_resource(conn, resource_selector(resource)) do
      {:ok, row}
    end
  end

  defp fetch_resource(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resources
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             LIMIT 1
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      case rows do
        [row] -> {:ok, resource_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp insert_revision_row(conn, attrs) do
    revision = normalize_revision_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO resource_revisions (
               agent_id,
               resource_type,
               scope_id,
               revision,
               parent_revision,
               content_hash,
               content,
               byte_size,
               mutation_source,
               provenance_json,
               created_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             revision_insert_params(revision)
           ),
         {:ok, [row]} <-
           query_all(conn, "SELECT * FROM resource_revisions WHERE id = last_insert_rowid()", []) do
      {:ok, resource_revision_row(row)}
    end
  end

  defp commit_resource_revision_tx(conn, attrs) do
    revision = normalize_commit_revision_attrs(attrs)

    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         result <- commit_resource_revision_in_tx(conn, revision),
         :ok <- finish_resource_commit(conn, result) do
      result
    else
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> rollback_resource_commit(conn, reason)
    end
  end

  defp commit_resource_revision_in_tx(conn, revision) do
    with {:ok, current} <- fetch_resource_current(conn, revision),
         false <- current.content_hash == revision.content_hash,
         attrs <- revision_attrs_for_commit(revision, current),
         {:ok, inserted} <- insert_revision_row(conn, attrs),
         {:ok, _resource} <-
           upsert_resource_row(conn, resource_attrs_for_commit(revision, inserted)) do
      {:ok, inserted}
    else
      true -> {:ok, :unchanged}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_resource_commit(conn, {:ok, _result}) do
    execute(conn, "COMMIT", [])
  end

  defp finish_resource_commit(_conn, {:error, reason}), do: {:error, reason}

  defp rollback_resource_commit(conn, reason) do
    _rollback_result = execute(conn, "ROLLBACK", [])
    {:error, reason}
  end

  defp fetch_resource_current(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT resources.current_revision, resource_revisions.content_hash
             FROM resources
             LEFT JOIN resource_revisions
               ON resource_revisions.agent_id = resources.agent_id
              AND resource_revisions.resource_type = resources.resource_type
              AND resource_revisions.scope_id = resources.scope_id
              AND resource_revisions.revision = resources.current_revision
             WHERE resources.agent_id = ?
               AND resources.resource_type = ?
               AND resources.scope_id = ?
             LIMIT 1
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      case rows do
        [[current_revision, content_hash]] ->
          {:ok, %{current_revision: current_revision, content_hash: content_hash}}

        [] ->
          {:ok, %{current_revision: 0, content_hash: nil}}
      end
    end
  end

  defp fetch_revision(conn, selector) do
    revision = normalize_revision_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ? AND revision = ?
             LIMIT 1
             """,
             [revision.agent_id, revision.resource_type, revision.scope_id, revision.revision]
           ) do
      case rows do
        [row] -> {:ok, resource_revision_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_latest_revision(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             ORDER BY revision DESC
             LIMIT 1
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      case rows do
        [row] -> {:ok, resource_revision_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_revisions(conn, selector, limit, offset) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             ORDER BY revision DESC
             LIMIT ? OFFSET ?
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id, limit, offset]
           ) do
      {:ok, Enum.map(rows, &resource_revision_row/1)}
    end
  end

  defp count_revisions(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, [[count]]} <-
           query_all(
             conn,
             """
             SELECT COUNT(*)
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      {:ok, count}
    end
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
      thread_scope: Scope.normalize_thread_scope(Map.fetch!(attrs, :thread_scope)),
      sender: fetch_string!(attrs, :sender),
      role: fetch_string!(attrs, :role),
      kind: fetch_string!(attrs, :kind),
      content: fetch_string!(attrs, :content),
      metadata: Map.get(attrs, :metadata),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now()))
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

  defp normalize_resource_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      resource_type: fetch_string!(attrs, :resource_type),
      scope_id: fetch_string!(attrs, :scope_id),
      resource_path: optional_string!(attrs, :resource_path),
      current_revision: fetch_non_negative_integer!(attrs, :current_revision),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp normalize_resource_selector(selector) do
    %{
      agent_id: fetch_string!(selector, :agent_id),
      resource_type: fetch_string!(selector, :resource_type),
      scope_id: fetch_string!(selector, :scope_id)
    }
  end

  defp normalize_revision_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      resource_type: fetch_string!(attrs, :resource_type),
      scope_id: fetch_string!(attrs, :scope_id),
      revision: fetch_positive_integer!(attrs, :revision),
      parent_revision: optional_positive_integer!(attrs, :parent_revision),
      content_hash: fetch_string!(attrs, :content_hash),
      content: fetch_string!(attrs, :content),
      byte_size: fetch_non_negative_integer!(attrs, :byte_size),
      mutation_source: fetch_string!(attrs, :mutation_source),
      provenance: Map.get(attrs, :provenance),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now()))
    }
  end

  defp normalize_commit_revision_attrs(attrs) do
    attrs
    |> Map.put(:revision, 1)
    |> Map.put(:parent_revision, nil)
    |> normalize_revision_attrs()
    |> Map.put(:resource_path, optional_string!(attrs, :resource_path))
  end

  defp normalize_revision_selector(selector) do
    selector
    |> normalize_resource_selector()
    |> Map.put(:revision, fetch_positive_integer!(selector, :revision))
  end

  defp normalize_message_selector(selector) do
    %{
      agent_id: fetch_string!(selector, :agent_id),
      channel: fetch_string!(selector, :channel),
      chat_id: fetch_string!(selector, :chat_id),
      thread_scope: Scope.normalize_thread_scope(Map.fetch!(selector, :thread_scope))
    }
  end

  defp normalize_message_search_selector(selector) do
    selector
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{}, fn
      {:thread_scope, value} -> {:thread_scope, Scope.normalize_thread_scope(value)}
      {key, value} -> {key, fetch_string_value!(key, value)}
    end)
  end

  defp normalize_message_fetch_selector(selector) do
    with {:ok, required} <- required_message_selector(selector) do
      {:ok, Map.merge(required, optional_message_fetch_filters(selector))}
    end
  end

  defp required_message_selector(selector) do
    Enum.reduce_while([:agent_id, :channel, :chat_id, :thread_scope], {:ok, %{}}, fn key,
                                                                                     {:ok, acc} ->
      case Map.fetch(selector, key) do
        {:ok, nil} ->
          {:halt, {:error, {:missing_required_message_selector_key, key}}}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, key, normalize_message_selector_value!(key, value))}}

        :error ->
          {:halt, {:error, {:missing_required_message_selector_key, key}}}
      end
    end)
  end

  defp optional_message_fetch_filters(selector) do
    [:owner_id, :sender, :role, :kind]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(selector, key) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, key, fetch_string_value!(key, value))
        :error -> acc
      end
    end)
  end

  defp normalize_message_selector_value!(:thread_scope, value) do
    Scope.normalize_thread_scope(value)
  end

  defp normalize_message_selector_value!(key, value), do: fetch_string_value!(key, value)

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

  defp resource_upsert_params(resource) do
    [
      resource.agent_id,
      resource.resource_type,
      resource.scope_id,
      resource.resource_path,
      resource.current_revision,
      resource.updated_at
    ]
  end

  defp revision_insert_params(revision) do
    [
      revision.agent_id,
      revision.resource_type,
      revision.scope_id,
      revision.revision,
      revision.parent_revision,
      revision.content_hash,
      revision.content,
      revision.byte_size,
      revision.mutation_source,
      encode_metadata(revision.provenance),
      revision.created_at
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

  defp resource_selector(resource) do
    %{
      agent_id: resource.agent_id,
      resource_type: resource.resource_type,
      scope_id: resource.scope_id
    }
  end

  defp revision_attrs_for_commit(revision, current) do
    revision
    |> Map.put(:revision, current.current_revision + 1)
    |> Map.put(:parent_revision, parent_revision(current.current_revision))
  end

  defp resource_attrs_for_commit(revision, inserted) do
    %{
      agent_id: revision.agent_id,
      resource_type: revision.resource_type,
      scope_id: revision.scope_id,
      resource_path: revision.resource_path,
      current_revision: inserted.revision
    }
  end

  defp parent_revision(0), do: nil
  defp parent_revision(revision), do: revision

  defp require_memory_key(selector) do
    case Map.fetch(selector, :key) do
      {:ok, value} when is_binary(value) -> {:ok, selector}
      {:ok, _value} -> {:error, {:invalid_memory_selector_key, :key}}
      :error -> {:error, {:missing_required_memory_selector_key, :key}}
    end
  end

  defp memory_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"#{column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp search_memory_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"memories.#{search_memory_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp message_where_clause(selector) do
    selector
    |> normalize_message_search_selector()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"messages.#{message_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp message_fetch_where_clause(selector) do
    with {:ok, normalized} <- normalize_message_fetch_selector(selector) do
      clause =
        normalized
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map_reduce([], fn {key, value}, params ->
          {"messages.#{message_column_name(key)} = ?", params ++ [value]}
        end)
        |> join_where_clause()

      {:ok, clause}
    end
  end

  defp join_where_clause({[], params}), do: {"1 = 1", params}

  defp join_where_clause({clauses, params}) do
    {Enum.join(clauses, " AND "), params}
  end

  defp column_name(:key), do: "\"key\""

  defp column_name(key) when key in [:agent_id, :owner_id, :scope_type, :scope_id, :category] do
    Atom.to_string(key)
  end

  defp search_memory_column_name(:key), do: "\"key\""

  defp search_memory_column_name(key)
       when key in [:agent_id, :owner_id, :scope_type, :scope_id, :category] do
    Atom.to_string(key)
  end

  defp message_column_name(key)
       when key in [
              :agent_id,
              :owner_id,
              :channel,
              :chat_id,
              :thread_scope,
              :sender,
              :role,
              :kind
            ] do
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

  defp message_search_row([
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
         created_at,
         rank
       ]) do
    message_row([
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
    ])
    |> Map.put(:rank, rank * 1.0)
  end

  defp memory_search_row([
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
         updated_at,
         rank
       ]) do
    memory_row([
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
    ])
    |> Map.put(:rank, rank * 1.0)
  end

  defp resource_row([
         id,
         agent_id,
         resource_type,
         scope_id,
         resource_path,
         current_revision,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      resource_type: resource_type,
      scope_id: scope_id,
      resource_path: resource_path,
      current_revision: current_revision,
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp resource_revision_row([
         id,
         agent_id,
         resource_type,
         scope_id,
         revision,
         parent_revision,
         content_hash,
         content,
         byte_size,
         mutation_source,
         provenance_json,
         created_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      resource_type: resource_type,
      scope_id: scope_id,
      revision: revision,
      parent_revision: parent_revision,
      content_hash: content_hash,
      content: content,
      byte_size: byte_size,
      mutation_source: mutation_source,
      provenance: decode_metadata(provenance_json),
      created_at: parse_timestamp!(created_at)
    }
  end

  defp encode_metadata(nil), do: nil
  defp encode_metadata(metadata), do: Jason.encode!(metadata)

  defp decode_metadata(nil), do: nil
  defp decode_metadata(metadata_json), do: Jason.decode!(metadata_json)

  defp timestamp_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_string(value) when is_binary(value), do: value

  defp parse_timestamp!(value) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(value)
    timestamp
  end

  defp fetch_string!(attrs, key) do
    value = Map.fetch!(attrs, key)

    fetch_string_value!(key, value)
  end

  defp fetch_string_value!(key, value) do
    if is_binary(value) do
      value
    else
      raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end

  defp optional_string!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> fetch_string_value!(key, value)
    end
  end

  defp fetch_non_negative_integer!(attrs, key) do
    value = Map.fetch!(attrs, key)
    non_negative_integer_value!(key, value)
  end

  defp fetch_positive_integer!(attrs, key) do
    value = Map.fetch!(attrs, key)
    positive_integer_value!(key, value)
  end

  defp optional_positive_integer!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> positive_integer_value!(key, value)
    end
  end

  defp non_negative_integer_value!(_key, value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer_value!(key, value) do
    raise ArgumentError,
          "expected #{inspect(key)} to be a non-negative integer, got: #{inspect(value)}"
  end

  defp positive_integer_value!(_key, value) when is_integer(value) and value > 0, do: value

  defp positive_integer_value!(key, value) do
    raise ArgumentError,
          "expected #{inspect(key)} to be a positive integer, got: #{inspect(value)}"
  end
end
