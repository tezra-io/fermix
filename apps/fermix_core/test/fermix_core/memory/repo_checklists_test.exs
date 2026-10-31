defmodule FermixCore.Memory.RepoChecklistsTest do
  # MILESTONE_85 §06: migration 56 adds the owner's lists to a store an older
  # engine wrote, rewrites nothing, and runs once; §07's migration 57 adds the
  # record of the edits the owner's devices sent, the same way.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Checklists.Registry
  alias FermixCore.Memory.Repo

  @version 56
  @edits_version 57

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-checklists-repo-#{unique}.db")
    repo = :"checklists_migration_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  defp with_raw_conn(db_path, fun) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp query!(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  defp objects(conn) do
    conn
    |> query!(
      "SELECT type, name FROM sqlite_master " <>
        "WHERE tbl_name IN ('checklists', 'checklist_items') AND name NOT LIKE 'sqlite_%' " <>
        "ORDER BY type, name"
    )
  end

  defp edit_objects(conn) do
    conn
    |> query!(
      "SELECT type, name FROM sqlite_master " <>
        "WHERE tbl_name = 'checklist_edits' AND name NOT LIKE 'sqlite_%' ORDER BY type, name"
    )
  end

  @edit_objects [["index", "idx_checklist_edits_created"], ["table", "checklist_edits"]]

  @objects [
    ["index", "idx_checklist_items_list"],
    ["index", "idx_checklists_live_title"],
    ["index", "idx_checklists_owner"],
    ["table", "checklist_items"],
    ["table", "checklists"]
  ]

  test "a fresh store gets both tables, their indexes and the version", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions
    assert @edits_version in versions

    with_raw_conn(db_path, fn conn ->
      assert objects(conn) == @objects
      assert edit_objects(conn) == @edit_objects
    end)
  end

  test "a store an engine at version 55 wrote gains the lists on the next open, its rows kept",
       %{repo: repo, db_path: db_path} do
    :ok = stop_supervised(repo)

    # The store as it stood before this migration, with a memory of the owner's.
    with_raw_conn(db_path, fn conn ->
      :ok = Sqlite3.execute(conn, "DROP TABLE checklist_edits")
      :ok = Sqlite3.execute(conn, "DROP TABLE checklist_items")
      :ok = Sqlite3.execute(conn, "DROP TABLE checklists")

      :ok =
        Sqlite3.execute(
          conn,
          "DELETE FROM schema_migrations WHERE version IN (#{@version}, #{@edits_version})"
        )

      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO memories (scope_type, scope_id, category, key, value) " <>
            "VALUES ('owner', 'default', 'goal', 'fermix_backlog_1', 'Lists on the Mac')"
        )

      assert [[55]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
      assert objects(conn) == []
    end)

    reopened = :"#{repo}_reopened"
    start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

    assert {:ok, versions} = Repo.migration_versions(server: reopened)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert Enum.count(versions, &(&1 == @edits_version)) == 1

    with_raw_conn(db_path, fn conn ->
      assert objects(conn) == @objects
      assert edit_objects(conn) == @edit_objects
      assert [["Lists on the Mac"]] = query!(conn, "SELECT value FROM memories")
    end)

    assert {:ok, []} = Repo.checklists_call({:index, "default", "main"}, server: reopened)
  end

  test "a store an engine at version 56 wrote gains the edit records, its lists kept",
       %{repo: repo, db_path: db_path} do
    owner = %{
      agent_name: "main",
      conversation_key: {"telegram", "40017", :root},
      source_trust: :operator,
      computer_use_origin: :interactive,
      chat_type: "private",
      outside_sources: MapSet.new()
    }

    # Every title here is invented.
    {:ok, _} =
      Registry.edit(
        %{"changes" => [%{"list" => "Groceries", "ops" => [%{"op" => "create"}]}]},
        owner,
        repo: repo
      )

    :ok = stop_supervised(repo)

    with_raw_conn(db_path, fn conn ->
      :ok = Sqlite3.execute(conn, "DROP TABLE checklist_edits")

      :ok =
        Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = #{@edits_version}")

      assert [[56]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
    end)

    reopened = :"#{repo}_reopened"
    start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

    assert {:ok, versions} = Repo.migration_versions(server: reopened)
    assert Enum.count(versions, &(&1 == @edits_version)) == 1

    with_raw_conn(db_path, fn conn ->
      assert edit_objects(conn) == @edit_objects
      assert [["Groceries"]] = query!(conn, "SELECT title FROM checklists")
    end)
  end

  test "migrating again changes nothing", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
    assert Enum.count(versions, &(&1 == @edits_version)) == 1
  end
end
