defmodule FermixCore.Memory.RepoTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  defmodule ExitingRepo do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:enabled?, _from, state) do
      {:stop, :normal, state}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-repo-#{unique}.db")
    repo_name = :"memory_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name, db_path: db_path}
  end

  test "opens sqlite, enables wal mode, and runs the base migration", %{repo: repo} do
    assert {:ok, "wal"} = Repo.journal_mode(server: repo)
    assert {:ok, [1, 2, 3, 4, 5, 6, 7]} = Repo.migration_versions(server: repo)
  end

  test "enabled_server returns nil when a named repo exits during lookup" do
    repo_name = :"exiting_repo_#{System.unique_integer([:positive])}"

    start_supervised!({ExitingRepo, name: repo_name})

    assert is_nil(Repo.enabled_server(repo_name))
  end

  test "rerunning migrations is idempotent", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, [1, 2, 3, 4, 5, 6, 7]} = Repo.migration_versions(server: repo)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, [1, 2, 3, 4, 5, 6, 7]} = Repo.migration_versions(server: repo)
  end

  test "resource migration creates required tables and indexes", %{db_path: db_path, repo: repo} do
    assert :ok = Repo.migrate(server: repo)

    assert {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      assert {:ok, tables} =
               sqlite_values(
                 conn,
                 "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)",
                 ["resources", "resource_revisions"]
               )

      assert Enum.sort(tables) == ["resource_revisions", "resources"]

      assert {:ok, resource_indexes} = sqlite_index_names(conn, "resources")
      assert "idx_resources_type_scope" in resource_indexes

      assert {:ok, revision_indexes} = sqlite_index_names(conn, "resource_revisions")

      assert "idx_revisions_latest" in revision_indexes
      assert "idx_revisions_resource_version" in revision_indexes
    after
      Sqlite3.close(conn)
    end
  end

  test "jobs migration creates registry tables and memory provenance columns", %{
    db_path: db_path,
    repo: repo
  } do
    assert :ok = Repo.migrate(server: repo)

    assert {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      assert {:ok, tables} =
               sqlite_values(
                 conn,
                 "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?, ?)",
                 ["scheduled_jobs", "job_runs", "memory_sources"]
               )

      assert Enum.sort(tables) == ["job_runs", "memory_sources", "scheduled_jobs"]

      assert {:ok, columns} = sqlite_column_names(conn, "memories")
      assert "source_id" in columns
      assert "source_name" in columns
      assert "session_id" in columns
      assert "run_id" in columns

      assert {:ok, job_columns} = sqlite_column_names(conn, "scheduled_jobs")
      assert "expires_at" in job_columns
    after
      Sqlite3.close(conn)
    end
  end

  test "supports resource registry and revision queries through the repo API", %{repo: repo} do
    resource = %{
      agent_id: "main",
      resource_type: "agents_md",
      scope_id: "global",
      current_revision: 0,
      resource_path: "/tmp/AGENTS.md"
    }

    assert {:ok, registered} = Repo.upsert_resource(resource, server: repo)
    assert registered.current_revision == 0
    assert registered.resource_path == "/tmp/AGENTS.md"

    revision = %{
      agent_id: "main",
      resource_type: "agents_md",
      scope_id: "global",
      revision: 1,
      parent_revision: nil,
      content_hash: String.duplicate("a", 64),
      content: "hello",
      byte_size: 5,
      mutation_source: "seed",
      provenance: %{"trigger" => "seed"}
    }

    assert {:ok, inserted} = Repo.insert_revision(revision, server: repo)
    assert inserted.revision == 1
    assert inserted.provenance == %{"trigger" => "seed"}

    assert {:ok, _resource} =
             Repo.upsert_resource(%{resource | current_revision: 1}, server: repo)

    assert {:ok, stored} = Repo.get_resource(resource, server: repo)
    assert stored.current_revision == 1

    assert {:ok, latest} = Repo.get_latest_revision(resource, server: repo)
    assert latest.id == inserted.id

    assert {:ok, fetched} = Repo.get_revision(Map.put(resource, :revision, 1), server: repo)
    assert fetched.content == "hello"

    assert {:ok, [history]} = Repo.list_revisions(resource, server: repo)
    assert history.revision == 1

    assert {:ok, 1} = Repo.revision_count(resource, server: repo)
  end

  test "scheduled jobs require an existing memory source", %{repo: repo} do
    refute match?(
             {:ok, _job},
             Repo.upsert_scheduled_job(scheduled_job_attrs(), server: repo)
           )

    assert {:error, :not_found} = Repo.get_scheduled_job("daily_digest", server: repo)
  end

  test "create_job_with_source rolls both rows back when job insert fails", %{repo: repo} do
    source = memory_source_attrs(%{id: "job:atomic_failure"})
    job = scheduled_job_attrs(%{memory_source_id: "job:missing_source"})

    refute match?(
             {:ok, _job},
             Repo.create_job_with_source(job, source, server: repo)
           )

    assert {:error, :not_found} = Repo.get_scheduled_job("daily_digest", server: repo)
    assert {:error, :not_found} = Repo.get_memory_source("job:atomic_failure", server: repo)
  end

  test "supports message CRUD through the repo API", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root",
      sender: "alice",
      role: "user",
      kind: "chat_message",
      content: "hello world",
      metadata: %{"source" => "test"}
    }

    assert {:ok, inserted} = Repo.insert_message(attrs, server: repo)
    assert inserted.id > 0
    assert inserted.metadata == %{"source" => "test"}

    selector = %{
      agent_id: "main",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root"
    }

    assert {:ok, 1} = Repo.message_count(selector, server: repo)
    assert {:ok, [stored]} = Repo.get_messages(selector, server: repo)
    assert stored.id == inserted.id
    assert stored.sender == "alice"
    assert stored.content == "hello world"

    assert :ok = Repo.delete_messages(selector, server: repo)
    assert {:ok, 0} = Repo.message_count(selector, server: repo)
    assert {:ok, []} = Repo.get_messages(selector, server: repo)
  end

  test "requires conversation scope when fetching messages", %{repo: repo} do
    assert {:error, {:missing_required_message_selector_key, :agent_id}} =
             Repo.get_messages(%{}, server: repo)
  end

  test "supports memory upsert, lookup, listing, and delete", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-1:root",
      category: "preference",
      key: "language",
      value: "en"
    }

    assert {:ok, first} = Repo.upsert_memory(attrs, server: repo)
    assert first.value == "en"

    assert {:ok, updated} =
             Repo.upsert_memory(Map.merge(attrs, %{value: "fr", confidence: 0.9}), server: repo)

    assert updated.id == first.id
    assert updated.value == "fr"
    assert updated.confidence == 0.9

    selector = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-1:root",
      key: "language"
    }

    assert {:ok, stored} = Repo.get_memory(selector, server: repo)
    assert stored.value == "fr"

    assert {:ok, [memory]} =
             Repo.get_memories(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-1:root"
               },
               server: repo
             )

    assert memory.id == updated.id

    assert :ok = Repo.delete_memory(selector, server: repo)
    assert {:error, :not_found} = Repo.get_memory(selector, server: repo)
  end

  test "persists memory source provenance fields", %{repo: repo} do
    attrs = %{
      agent_id: "job:daily_digest",
      owner_id: "default",
      scope_type: "job",
      scope_id: "job:daily_digest",
      category: "summary",
      key: "latest",
      value: "Daily digest output",
      source_id: "job:daily_digest",
      source_type: "scheduled_job",
      source_name: "Daily Digest",
      source_description: "Runs every morning.",
      session_id: "cron_daily_digest_20260502_080000",
      run_id: "run_1"
    }

    assert {:ok, stored} = Repo.upsert_memory(attrs, server: repo)
    assert stored.source_id == "job:daily_digest"
    assert stored.source_name == "Daily Digest"
    assert stored.session_id == "cron_daily_digest_20260502_080000"
    assert stored.run_id == "run_1"

    assert {:ok, [match]} =
             Repo.search_memories(
               "digest",
               selector: %{source_id: "job:daily_digest"},
               server: repo
             )

    assert match.source_type == "scheduled_job"
    assert match.source_description == "Runs every morning."
  end

  test "supports explicit bulk memory deletes by selector", %{repo: repo} do
    base_attrs = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-bulk:root",
      category: "preference",
      value: "stored"
    }

    assert {:ok, _memory} =
             Repo.upsert_memory(Map.put(base_attrs, :key, "language"), server: repo)

    assert {:ok, _memory} =
             Repo.upsert_memory(Map.put(base_attrs, :key, "timezone"), server: repo)

    selector = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-bulk:root"
    }

    assert {:error, {:missing_required_memory_selector_key, :key}} =
             Repo.delete_memory(selector, server: repo)

    assert :ok = Repo.delete_memories(selector, server: repo)
    assert {:ok, []} = Repo.get_memories(selector, server: repo)
  end

  test "keeps memory fts results in sync across upserts and deletes", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "conversation",
      scope_id: "telegram:chat-search:root",
      category: "preference",
      key: "timezone",
      value: "UTC timezone preference"
    }

    assert {:ok, inserted} = Repo.upsert_memory(attrs, server: repo)

    assert {:ok, [match]} =
             Repo.search_memories(
               "utc",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )

    assert match.id == inserted.id
    assert match.key == "timezone"
    assert is_float(match.rank)

    assert {:ok, _updated} =
             Repo.upsert_memory(Map.put(attrs, :value, "calendar preference"), server: repo)

    assert {:ok, []} =
             Repo.search_memories(
               "utc",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )

    assert {:ok, [updated]} =
             Repo.search_memories(
               "calendar",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )

    assert updated.id == inserted.id

    assert :ok =
             Repo.delete_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root",
                 key: "timezone"
               },
               server: repo
             )

    assert {:ok, []} =
             Repo.search_memories(
               "calendar",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "telegram:chat-search:root"
               },
               server: repo
             )
  end

  test "keeps message fts results in sync across inserts and deletes", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-search",
      thread_scope: "root",
      sender: "alice",
      role: "user",
      kind: "chat_message",
      content: "timezone preferences came up in chat"
    }

    assert {:ok, inserted} = Repo.insert_message(attrs, server: repo)

    assert {:ok, [match]} =
             Repo.search_messages(
               "timezone",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 channel: "telegram",
                 chat_id: "chat-search",
                 thread_scope: "root"
               },
               server: repo
             )

    assert match.id == inserted.id
    assert match.content =~ "timezone"
    assert is_float(match.rank)

    assert :ok =
             Repo.delete_messages(
               %{
                 agent_id: "main",
                 channel: "telegram",
                 chat_id: "chat-search",
                 thread_scope: "root"
               },
               server: repo
             )

    assert {:ok, []} =
             Repo.search_messages(
               "timezone",
               selector: %{
                 agent_id: "main",
                 owner_id: "default",
                 channel: "telegram",
                 chat_id: "chat-search",
                 thread_scope: "root"
               },
               server: repo
             )
  end

  defp sqlite_values(conn, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, params),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt),
         :ok <- Sqlite3.release(conn, stmt) do
      {:ok, Enum.map(rows, fn [value | _rest] -> value end)}
    end
  end

  defp sqlite_index_names(conn, table) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, "PRAGMA index_list(#{table})"),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt),
         :ok <- Sqlite3.release(conn, stmt) do
      {:ok, Enum.map(rows, fn [_seq, name | _rest] -> name end)}
    end
  end

  defp sqlite_column_names(conn, table) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, "PRAGMA table_info(#{table})"),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt),
         :ok <- Sqlite3.release(conn, stmt) do
      {:ok, Enum.map(rows, fn [_cid, name | _rest] -> name end)}
    end
  end

  defp scheduled_job_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "daily_digest",
        name: "Daily Digest",
        schedule_kind: "interval",
        schedule_expr: "every 15 minutes",
        timezone: "UTC",
        next_run_at: ~U[2026-05-02 14:15:00Z],
        task_prompt: "Summarize changes.",
        memory_source_id: "job:daily_digest"
      },
      overrides
    )
  end

  defp memory_source_attrs(overrides) do
    Map.merge(
      %{
        id: "job:daily_digest",
        source_type: "scheduled_job",
        name: "Daily Digest",
        description: "Summarizes changes.",
        memory_scope: "job:daily_digest",
        output_scope: "cron:daily_digest",
        metadata: %{"job_id" => "daily_digest"}
      },
      overrides
    )
  end
end
