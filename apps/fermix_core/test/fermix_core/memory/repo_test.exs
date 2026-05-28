defmodule FermixCore.Memory.RepoTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry

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
    assert {:ok, [1, 2, 3, 4, 5, 6, 7, 8, 9]} = Repo.migration_versions(server: repo)
  end

  test "enabled_server returns nil when a named repo exits during lookup" do
    repo_name = :"exiting_repo_#{System.unique_integer([:positive])}"

    start_supervised!({ExitingRepo, name: repo_name})

    assert is_nil(Repo.enabled_server(repo_name))
  end

  test "rerunning migrations is idempotent", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, [1, 2, 3, 4, 5, 6, 7, 8, 9]} = Repo.migration_versions(server: repo)

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, [1, 2, 3, 4, 5, 6, 7, 8, 9]} = Repo.migration_versions(server: repo)
  end

  test "fermix_md migration rewrites resource_path so rollback targets FERMIX.md", %{
    repo: repo,
    db_path: db_path
  } do
    dir = Path.join(System.tmp_dir!(), "fermix-md-rename-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    legacy_path = Path.join(dir, "AGENTS.md")
    fermix_path = Path.join(dir, "FERMIX.md")

    # Simulate a pre-rename install: an `agents_md` resource registered at the
    # legacy AGENTS.md path with two revisions, then drop the v8 marker so the
    # migration re-runs against the legacy rows on the next open.
    seed_legacy_agents_md(repo, legacy_path)
    drop_migration_version(db_path, 8)

    assert :ok = Repo.migrate(server: repo)

    selector = %{agent_id: "main", resource_type: "fermix_md", scope_id: "global"}
    assert {:ok, migrated} = Repo.get_resource(selector, server: repo)
    assert migrated.resource_path == fermix_path

    # BootstrapRename already moved the file: current content lives at FERMIX.md
    # and the legacy AGENTS.md is gone.
    File.write!(fermix_path, "rev-two")

    assert {:ok, rolled_back} = Registry.rollback("main", "fermix_md", "global", 1, repo: repo)
    assert rolled_back.revision == 3

    assert File.read!(fermix_path) == "rev-one"
    refute File.exists?(legacy_path)
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
      assert "archived_at" in columns
      assert "archived_by" in columns
      assert "archive_reason" in columns

      assert {:ok, review_state_columns} = sqlite_column_names(conn, "memory_review_state")
      assert "last_reviewed_message_id" in review_state_columns
      assert "last_review_failed_at" in review_state_columns

      assert {:ok, job_columns} = sqlite_column_names(conn, "scheduled_jobs")
      assert "expires_at" in job_columns
    after
      Sqlite3.close(conn)
    end
  end

  test "supports resource registry and revision queries through the repo API", %{repo: repo} do
    resource = %{
      agent_id: "main",
      resource_type: "fermix_md",
      scope_id: "global",
      current_revision: 0,
      resource_path: "/tmp/FERMIX.md"
    }

    assert {:ok, registered} = Repo.upsert_resource(resource, server: repo)
    assert registered.current_revision == 0
    assert registered.resource_path == "/tmp/FERMIX.md"

    revision = %{
      agent_id: "main",
      resource_type: "fermix_md",
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

  test "archives and restores memories by exact row id", %{repo: repo} do
    attrs = %{
      agent_id: "main",
      owner_id: "default",
      scope_type: "owner",
      scope_id: "default",
      category: "preference",
      key: "editor",
      value: "helix"
    }

    assert {:ok, memory} = Repo.upsert_memory(attrs, server: repo)

    assert {:ok, archived} =
             Repo.archive_memory(
               %{id: memory.id, agent_id: "main", owner_id: "default", archived?: false},
               "memory_reviewer",
               "superseded",
               ~U[2026-05-27 10:00:00Z],
               server: repo
             )

    assert archived.id == memory.id
    assert archived.archived_by == "memory_reviewer"
    assert archived.archive_reason == "superseded"

    assert {:ok, []} =
             Repo.get_memories(%{agent_id: "main", owner_id: "default", archived?: false},
               server: repo
             )

    assert {:ok, restored} = Repo.restore_memory(memory.id, server: repo)
    assert restored.archived_at == nil
    assert restored.archived_by == nil
  end

  test "tracks review state with success and failure pointer semantics", %{repo: repo} do
    selector = %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root"
    }

    assert {:ok, claimed} =
             Repo.claim_memory_review(selector, ~U[2026-05-27 10:00:00Z], 60_000, server: repo)

    assert DateTime.compare(claimed.last_review_started_at, ~U[2026-05-27 10:00:00Z]) == :eq

    assert {:error, :concurrent_run} =
             Repo.claim_memory_review(selector, ~U[2026-05-27 10:00:01Z], 60_000, server: repo)

    assert {:ok, failed} =
             Repo.fail_memory_review(selector, ~U[2026-05-27 10:01:00Z], server: repo)

    assert failed.last_reviewed_message_id == nil
    assert failed.failure_count == 1
    assert failed.last_review_status == "failed"

    assert {:ok, _claimed} =
             Repo.claim_memory_review(selector, ~U[2026-05-27 10:07:00Z], 60_000, server: repo)

    assert {:ok, completed} =
             Repo.complete_memory_review(selector, :ok, 42, ~U[2026-05-27 10:07:10Z],
               server: repo
             )

    assert completed.last_reviewed_message_id == 42
    assert completed.failure_count == 0
    assert completed.last_review_failed_at == nil
  end

  test "fetches new user messages by owner and monotonic id", %{repo: repo} do
    base = %{
      agent_id: "main",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root",
      sender: "alice",
      kind: "chat_message",
      content: "ignored"
    }

    assert {:ok, first} =
             Repo.insert_message(Map.merge(base, %{owner_id: "owner-a", role: "user"}),
               server: repo
             )

    assert {:ok, _assistant} =
             Repo.insert_message(
               Map.merge(base, %{owner_id: "owner-a", role: "assistant", content: "reply"}),
               server: repo
             )

    assert {:ok, second} =
             Repo.insert_message(
               Map.merge(base, %{owner_id: "owner-a", role: "user", content: "next"}),
               server: repo
             )

    assert {:ok, _other_owner} =
             Repo.insert_message(Map.merge(base, %{owner_id: "owner-b", role: "user"}),
               server: repo
             )

    selector = %{
      agent_id: "main",
      owner_id: "owner-a",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root"
    }

    assert {:ok, [message]} = Repo.get_user_messages_after(selector, first.id, 10, server: repo)
    assert message.id == second.id
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

  defp seed_legacy_agents_md(repo, legacy_path) do
    base = %{agent_id: "main", resource_type: "agents_md", scope_id: "global"}

    {:ok, _} =
      Repo.upsert_resource(Map.merge(base, %{current_revision: 0, resource_path: legacy_path}),
        server: repo
      )

    Enum.each([{1, "rev-one", nil}, {2, "rev-two", 1}], fn {revision, content, parent} ->
      {:ok, _} =
        Repo.insert_revision(
          Map.merge(base, %{
            revision: revision,
            parent_revision: parent,
            content_hash: sha256_hex(content),
            content: content,
            byte_size: byte_size(content),
            mutation_source: "seed",
            provenance: %{"trigger" => "seed"}
          }),
          server: repo
        )
    end)

    {:ok, _} =
      Repo.upsert_resource(Map.merge(base, %{current_revision: 2, resource_path: legacy_path}),
        server: repo
      )
  end

  defp drop_migration_version(db_path, version) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
    :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = #{version};")
    :ok = Sqlite3.close(conn)
  end

  defp sha256_hex(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
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
