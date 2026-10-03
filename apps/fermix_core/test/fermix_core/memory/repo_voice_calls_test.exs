defmodule FermixCore.Memory.RepoVoiceCallsTest do
  # The `voice_calls` table: one Live call's durable record (M56 §4.2).
  # Membership, never list equality, for the migration version, the way the
  # meetings tripwire asserts its own.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo

  @voice_calls_version 37
  @uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @other_uuid "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
  @started ~U[2026-10-02 09:00:00.000000Z]
  @ended ~U[2026-10-02 09:06:30.000000Z]

  @task %{
    "task_id" => "dg_1",
    "revision" => 1,
    "state" => "running",
    "request" => "user: book the room",
    "summary" => nil
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-voice-calls-#{unique}.db")
    repo = :"memory_repo_voice_calls_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, db_path: db_path}
  end

  test "the voice_calls migration is applied on a fresh database and reruns cleanly", %{
    repo: repo
  } do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @voice_calls_version in versions

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, again} = Repo.migration_versions(server: repo)
    assert length(again) == length(Enum.uniq(again))
  end

  test "a record opens with no tasks, no end and the row and gist states at none", %{
    repo: repo
  } do
    assert {:ok, row} = create(repo, @uuid)

    assert row == %{
             uuid: @uuid,
             engine: "openai_live",
             started_at: "2026-10-02T09:00:00.000000Z",
             ended_at: nil,
             end_reason: nil,
             voice_cost_cents: nil,
             accounting: nil,
             tasks: [],
             gist: nil,
             gist_status: "none",
             row_state: "none",
             created_at: "2026-10-02T09:00:00.000000Z"
           }

    assert Repo.get_voice_call(@uuid, server: repo) == {:ok, row}
  end

  test "the tasks are written whole and read back as they were", %{repo: repo} do
    {:ok, _row} = create(repo, @uuid)
    pending = %{@task | "task_id" => "dg_2", "state" => "created", "request" => nil}

    assert {:ok, row} = Repo.update_voice_call_tasks(@uuid, [@task, pending], server: repo)
    assert row.tasks == [@task, pending]
    assert {:ok, %{tasks: [@task, ^pending]}} = Repo.get_voice_call(@uuid, server: repo)
  end

  test "a record closes once with its reason, cost, accounting and final tasks", %{repo: repo} do
    {:ok, _row} = create(repo, @uuid)
    done = %{@task | "state" => "completed", "summary" => "Booked for 10am."}

    assert {:ok, closed} = Repo.close_voice_call(@uuid, close_fields([done]), server: repo)

    assert %{
             ended_at: "2026-10-02T09:06:30.000000Z",
             end_reason: "call_stop",
             voice_cost_cents: 32.5,
             accounting: "complete",
             tasks: [^done]
           } = closed

    # Closed is final: a second close finds no open record.
    assert {:error, :not_found} =
             Repo.close_voice_call(@uuid, close_fields([]), server: repo)

    assert {:ok, ^closed} = Repo.get_voice_call(@uuid, server: repo)
  end

  test "an unknown cost is stored as unknown, never as zero", %{repo: repo} do
    {:ok, _row} = create(repo, @uuid)
    fields = %{close_fields([]) | voice_cost_cents: nil, accounting: "incomplete"}

    assert {:ok, %{voice_cost_cents: nil, accounting: "incomplete"}} =
             Repo.close_voice_call(@uuid, fields, server: repo)
  end

  test "the open records started before a cutoff are listed oldest first", %{repo: repo} do
    {:ok, _row} = create(repo, @other_uuid, ~U[2026-10-02 08:00:00.000000Z])
    {:ok, _row} = create(repo, @uuid, @started)
    closed = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
    {:ok, _row} = create(repo, closed, @started)
    {:ok, _row} = Repo.close_voice_call(closed, close_fields([]), server: repo)
    later = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    {:ok, _row} = create(repo, later, ~U[2026-10-02 10:00:00.000000Z])

    assert {:ok, rows} =
             Repo.list_open_voice_calls(~U[2026-10-02 09:30:00.000000Z], server: repo)

    assert Enum.map(rows, & &1.uuid) == [@other_uuid, @uuid]
  end

  test "the boundary refuses what the table would not hold", %{repo: repo} do
    assert {:error, {:invalid, :uuid, :malformed}} = create(repo, "voice_live:7")

    {:ok, _row} = create(repo, @uuid)

    assert {:error, {:invalid, :accounting, :unknown}} =
             Repo.close_voice_call(@uuid, %{close_fields([]) | accounting: "settled"},
               server: repo
             )

    assert {:error, {:invalid, :tasks, :not_a_list_of_maps}} =
             Repo.update_voice_call_tasks(@uuid, ["dg_1"], server: repo)
  end

  test "the row state CHECK refuses a value outside its vocabulary", %{
    repo: repo,
    db_path: db_path
  } do
    {:ok, _row} = create(repo, @uuid)
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      assert {:error, message} =
               Sqlite3.execute(conn, "UPDATE voice_calls SET row_state = 'shown'")

      assert message =~ "CHECK"
    after
      Sqlite3.close(conn)
    end
  end

  test "memory off is a configuration: every call answers disabled" do
    repo = :"memory_repo_voice_calls_off_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: repo, enabled: false}, id: repo)

    assert {:error, :disabled} = create(repo, @uuid)
    assert {:error, :disabled} = Repo.list_open_voice_calls(@started, server: repo)
  end

  defp create(repo, uuid, started_at \\ @started) do
    Repo.create_voice_call(
      %{uuid: uuid, engine: "openai_live", started_at: started_at, created_at: started_at},
      server: repo
    )
  end

  defp close_fields(tasks) do
    %{
      ended_at: @ended,
      end_reason: "call_stop",
      voice_cost_cents: 32.5,
      accounting: "complete",
      tasks: tasks
    }
  end
end
