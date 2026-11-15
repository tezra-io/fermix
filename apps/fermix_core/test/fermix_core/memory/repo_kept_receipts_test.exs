defmodule FermixCore.Memory.RepoKeptReceiptsTest do
  # M89 §07: the receipts a device's edits leave (`checklist_edits`, migration
  # 57) name the kind of thing they changed. Migration 62 adds the column to a
  # store an older engine wrote, its receipts read as the lists', and an edit
  # sent again is still answered as the duplicate it is.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Checklists.Registry
  alias FermixCore.Memory.Repo

  @version 62
  # Every title and id here is invented.
  @now ~U[2031-06-02 14:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-kept-receipts-#{unique}.db")
    repo = :"kept_receipts_repo_#{unique}"
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

  defp columns(conn) do
    conn |> query!("PRAGMA table_info(checklist_edits)") |> Enum.map(&Enum.at(&1, 1))
  end

  # A device's create, as the Mac sends it; the notifier is the test's own, so
  # no connection anywhere hears of it.
  defp create(repo, client_msg_id, title, now) do
    Registry.device_edit(
      %{"client_msg_id" => client_msg_id, "op" => %{"op" => "create", "title" => title}},
      :independent,
      repo: repo,
      now: now,
      notifier: fn _changes -> :ok end
    )
  end

  test "a fresh store's receipts carry their kind, from migration 62 once", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1

    with_raw_conn(db_path, fn conn -> assert "kind" in columns(conn) end)

    assert {:ok, %{duplicate: false, made: made}} = create(repo, "mac-1", "Groceries", @now)

    with_raw_conn(db_path, fn conn ->
      assert [["checklist", ^made]] =
               query!(conn, "SELECT kind, made_id FROM checklist_edits")
    end)
  end

  test "a store an engine at version 61 wrote keeps its receipts, read as the lists'", %{
    repo: repo,
    db_path: db_path
  } do
    assert {:ok, %{list_id: list_id, made: made}} = create(repo, "mac-7", "Groceries", @now)
    :ok = stop_supervised(repo)

    # The receipts table as migration 57 made it, holding the receipt.
    with_raw_conn(db_path, fn conn ->
      :ok = Sqlite3.execute(conn, "ALTER TABLE checklist_edits DROP COLUMN kind")
      :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = #{@version}")
      refute "kind" in columns(conn)

      assert [["mac-7", ^list_id]] =
               query!(conn, "SELECT client_msg_id, made_id FROM checklist_edits")
    end)

    reopened = :"#{repo}_reopened"
    start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

    assert {:ok, versions} = Repo.migration_versions(server: reopened)
    assert Enum.count(versions, &(&1 == @version)) == 1

    with_raw_conn(db_path, fn conn ->
      assert [["mac-7", "checklist"]] =
               query!(conn, "SELECT client_msg_id, kind FROM checklist_edits")
    end)

    assert {:ok, %{list_id: ^list_id, made: ^made, duplicate: true}} =
             create(reopened, "mac-7", "Groceries", @now)

    assert {:ok, [%{title: "Groceries"}]} =
             Repo.checklists_call({:index, "default", "main"}, server: reopened)
  end

  test "migrating again changes nothing", %{repo: repo, db_path: db_path} do
    assert {:ok, _made} = create(repo, "mac-2", "Groceries", @now)
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert Enum.count(versions, &(&1 == @version)) == 1

    with_raw_conn(db_path, fn conn ->
      assert Enum.count(columns(conn), &(&1 == "kind")) == 1

      assert [["mac-2", "checklist"]] =
               query!(conn, "SELECT client_msg_id, kind FROM checklist_edits")
    end)
  end

  test "a receipt older than 30 days is gone after the next device edit", %{
    repo: repo,
    db_path: db_path
  } do
    old = DateTime.add(@now, -31 * 86_400, :second)
    recent = DateTime.add(@now, -29 * 86_400, :second)

    assert {:ok, %{duplicate: false}} = create(repo, "mac-old", "Errands", old)
    assert {:ok, %{duplicate: false}} = create(repo, "mac-recent", "Packing", recent)
    assert {:ok, %{duplicate: false}} = create(repo, "mac-now", "Garden", @now)

    with_raw_conn(db_path, fn conn ->
      assert [["mac-now"], ["mac-recent"]] =
               query!(conn, "SELECT client_msg_id FROM checklist_edits ORDER BY client_msg_id")
    end)
  end
end
