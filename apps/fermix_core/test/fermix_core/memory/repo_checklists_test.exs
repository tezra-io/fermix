defmodule FermixCore.Memory.RepoChecklistsTest do
  # MILESTONE_85 §06: migration 56 adds the owner's lists to a store an older
  # engine wrote, rewrites nothing, and runs once.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @version 56

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
    assert Enum.max(versions) == @version

    with_raw_conn(db_path, fn conn -> assert objects(conn) == @objects end)
  end

  test "a store an engine at version 55 wrote gains the lists on the next open, its rows kept",
       %{repo: repo, db_path: db_path} do
    :ok = stop_supervised(repo)

    # The store as it stood before this migration, with a memory of the owner's.
    with_raw_conn(db_path, fn conn ->
      :ok = Sqlite3.execute(conn, "DROP TABLE checklist_items")
      :ok = Sqlite3.execute(conn, "DROP TABLE checklists")
      :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = #{@version}")

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

    with_raw_conn(db_path, fn conn ->
      assert objects(conn) == @objects
      assert [["Lists on the Mac"]] = query!(conn, "SELECT value FROM memories")
    end)

    assert {:ok, []} = Repo.checklists_call({:index, "default", "main"}, server: reopened)
  end

  test "migrating again changes nothing", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1
  end
end
