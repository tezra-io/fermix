defmodule FermixCore.Memory.RepoMeetingsMigrationTest do
  # The loud tripwire for a silently-skipped migration version: meetings claims
  # 26 while 23-25 stay reserved, so membership — never list equality — is what
  # this asserts.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @meetings_version 26
  @now ~U[2026-08-17 10:15:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-meetings-migration-#{unique}.db")
    repo_name = :"memory_repo_meetings_migration_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name, db_path: db_path}
  end

  test "the meetings migration is applied on a fresh database", %{repo: repo} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @meetings_version in versions
  end

  test "rerunning migrate is idempotent", %{repo: repo} do
    assert :ok = Repo.migrate(server: repo)
    assert {:ok, versions} = Repo.migration_versions(server: repo)

    assert @meetings_version in versions
    assert length(versions) == length(Enum.uniq(versions))
  end

  test "a meeting round-trips through the table", %{repo: repo} do
    assert {:ok, created} =
             Repo.create_meeting(
               %{
                 id: "mtg_AbCdEfGhIjK",
                 platform: "zoom",
                 url: "https://zoom.us/j/123456789",
                 title: "Board call",
                 requested_by: "operator",
                 origin_session_id: nil,
                 created_at: @now
               },
               server: repo
             )

    assert created.status == "requested"

    assert {:ok, fetched} = Repo.get_meeting("mtg_AbCdEfGhIjK", server: repo)
    assert fetched == created

    assert {:ok, [%{id: "mtg_AbCdEfGhIjK"}]} =
             Repo.list_meetings(%{scope: :active}, server: repo)
  end

  test "the status CHECK refuses a value outside the state machine", %{
    db_path: db_path,
    repo: repo
  } do
    {:ok, _meeting} =
      Repo.create_meeting(
        %{
          id: "mtg_AbCdEfGhIjK",
          platform: "meet",
          url: "https://meet.google.com/abc-defg-hij",
          title: nil,
          requested_by: "operator",
          origin_session_id: nil,
          created_at: @now
        },
        server: repo
      )

    with_raw_conn(db_path, fn conn ->
      assert {:error, message} =
               Sqlite3.execute(
                 conn,
                 "UPDATE meetings SET status = 'wandering' WHERE id = 'mtg_AbCdEfGhIjK'"
               )

      assert message =~ "CHECK constraint failed"
    end)
  end

  test "sweep_live_meetings flips only the live rows and reports their ids", %{repo: repo} do
    insert(repo, "mtg_00000000001", "capturing")
    insert(repo, "mtg_00000000002", "delivered")

    assert {:ok, ["mtg_00000000001"]} =
             Repo.sweep_live_meetings("daemon_restarted", @now, server: repo)

    assert {:ok, %{status: "failed", error: "daemon_restarted"}} =
             Repo.get_meeting("mtg_00000000001", server: repo)

    assert {:ok, %{status: "delivered"}} = Repo.get_meeting("mtg_00000000002", server: repo)
  end

  defp insert(repo, id, status) do
    {:ok, _meeting} =
      Repo.create_meeting(
        %{
          id: id,
          platform: "meet",
          url: "https://meet.google.com/abc-defg-hij",
          title: nil,
          requested_by: "operator",
          origin_session_id: nil,
          created_at: @now
        },
        server: repo
      )

    {:ok, _updated} = Repo.update_meeting_status(id, status, %{}, server: repo)
  end

  defp with_raw_conn(db_path, fun) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end
end
