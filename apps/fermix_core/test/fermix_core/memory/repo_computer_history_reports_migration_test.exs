defmodule FermixCore.Memory.RepoComputerHistoryReportsMigrationTest do
  # M97 §8.5: memory.db's migration 60. Each machine's row on the home gains
  # the owner's pending off from chat and the machine's last report of its
  # recorder; a row already there keeps everything it had.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  @version 60

  setup do
    dir = SafeRm.make_tmp_dir!("ch-reports-migration")
    on_exit(fn -> SafeRm.rm_rf(dir) end)

    %{
      dir: dir,
      db_path: Path.join(dir, "memory.db"),
      repo: :"ch_reports_migration_#{System.unique_integer([:positive])}"
    }
  end

  defp start_repo(ctx, id) do
    start_supervised!(
      {Repo,
       name: ctx.repo,
       enabled: true,
       database_path: ctx.db_path,
       history_spool_path: Path.join([ctx.dir, "device", "history.db"]),
       history_server?: false,
       history_recorder?: true},
      id: id
    )
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp query(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readonly)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end

  defp columns(db_path),
    do: query(db_path, "SELECT name FROM pragma_table_info('computer_history_computers')")

  test "a store from before it gains the columns and keeps its rows", ctx do
    start_repo(ctx, :first)
    stop_supervised!(:first)

    raw(ctx.db_path, """
    ALTER TABLE computer_history_computers DROP COLUMN off_requested_at;
    ALTER TABLE computer_history_computers DROP COLUMN report;
    ALTER TABLE computer_history_computers DROP COLUMN report_at;
    INSERT INTO computer_history_computers (computer_id, delivered_mark, last_status)
      VALUES ('studio-7f3a', 4, 'summarized');
    DELETE FROM schema_migrations WHERE version = #{@version};
    """)

    refute ["report"] in columns(ctx.db_path)

    start_repo(ctx, :upgraded)

    assert [["off_requested_at"], ["report"], ["report_at"]] --
             columns(ctx.db_path) == []

    assert [[@version]] =
             query(
               ctx.db_path,
               "SELECT version FROM schema_migrations WHERE version = #{@version}"
             )

    assert {:ok, [row]} = Repo.computer_history_home(:computer_rows, [], server: ctx.repo)

    assert %{
             computer_id: "studio-7f3a",
             delivered_mark: 4,
             last_status: "summarized",
             off_requested_at: nil,
             report: nil
           } = row
  end

  test "a store that has it runs it again with no change", ctx do
    start_repo(ctx, :first)
    stop_supervised!(:first)
    before = columns(ctx.db_path)

    raw(ctx.db_path, "DELETE FROM schema_migrations WHERE version = #{@version};")
    start_repo(ctx, :again)

    assert columns(ctx.db_path) == before
  end
end
