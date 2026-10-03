defmodule FermixCore.Realtime.CallRecordTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord

  @uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @started ~U[2026-10-02 09:00:00.000000Z]
  @ended ~U[2026-10-02 09:06:30.000000Z]

  describe "tasks" do
    test "a task moves through its states and keeps its request and summary" do
      record =
        CallRecord.new(@uuid, "openai_live")
        |> CallRecord.put_task("dg_1", 1, "created")
        |> CallRecord.put_task("dg_1", 1, "running", %{request: "user: book the room"})
        |> CallRecord.put_task("dg_1", 1, "completed", %{summary: "Booked for 10am."})

      assert record.tasks == [
               %{
                 "task_id" => "dg_1",
                 "revision" => 1,
                 "state" => "completed",
                 "request" => "user: book the room",
                 "summary" => "Booked for 10am."
               }
             ]
    end

    test "tasks keep the order they were created in, one entry per id and revision" do
      record =
        CallRecord.new(@uuid, "openai_live")
        |> CallRecord.put_task("dg_1", 1, "created")
        |> CallRecord.put_task("dg_2", 1, "created")
        |> CallRecord.put_task("dg_1", 1, "running", %{request: "user: a"})
        |> CallRecord.put_task("dg_1", 2, "created")

      assert Enum.map(record.tasks, &{&1["task_id"], &1["revision"], &1["state"]}) == [
               {"dg_1", 1, "running"},
               {"dg_2", 1, "created"},
               {"dg_1", 2, "created"}
             ]
    end

    test "the request is capped at 2 KB on a character boundary" do
      # One ASCII byte, then two-byte characters: byte 2,048 falls mid-character.
      long = "a" <> String.duplicate("é", 2_000)

      [task] =
        CallRecord.new(@uuid, "openai_live")
        |> CallRecord.put_task("dg_1", 1, "running", %{request: long})
        |> Map.fetch!(:tasks)

      assert byte_size(task["request"]) == 2_047
      assert String.valid?(task["request"])
    end

    test "the state vocabulary is closed, the later stages' words included" do
      record = CallRecord.new(@uuid, "openai_live")

      for state <- ~w(created running detached completed failed cancelled timed_out) do
        assert %CallRecord{} = CallRecord.put_task(record, "dg_1", 1, state)
      end

      assert_raise FunctionClauseError, fn ->
        CallRecord.put_task(record, "dg_1", 1, "pending")
      end
    end

    test "a call keeps its 64 most recent tasks" do
      record =
        Enum.reduce(1..70, CallRecord.new(@uuid, "openai_live"), fn index, acc ->
          CallRecord.put_task(acc, "dg_#{index}", 1, "created")
        end)

      assert length(record.tasks) == 64
      assert hd(record.tasks)["task_id"] == "dg_7"
      assert List.last(record.tasks)["task_id"] == "dg_70"
    end

    test "after a restart an unfinished task has failed, and a finished one stands" do
      record =
        ~w(created running detached completed failed cancelled timed_out)
        |> Enum.with_index(1)
        |> Enum.reduce(CallRecord.new(@uuid, "openai_live"), fn {state, index}, acc ->
          CallRecord.put_task(acc, "dg_#{index}", 1, state, %{summary: "was #{state}"})
        end)

      swept = CallRecord.fail_unfinished(record.tasks)

      assert Enum.map(swept, &{&1["state"], &1["summary"]}) == [
               {"failed", "daemon_restarted"},
               {"failed", "daemon_restarted"},
               {"failed", "daemon_restarted"},
               {"completed", "was completed"},
               {"failed", "was failed"},
               {"cancelled", "was cancelled"},
               {"timed_out", "was timed_out"}
             ]
    end

    # A stored document is read back, not trusted: a task missing a field must
    # not crash the sweep that reads it at every boot.
    test "a stored task missing its fields is still failed, never raised on" do
      assert CallRecord.fail_unfinished([%{"task_id" => "dg_1"}]) == [
               %{"task_id" => "dg_1", "state" => "failed", "summary" => "daemon_restarted"}
             ]
    end
  end

  describe "the record in the memory database" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-call-record-#{unique}.db")
      repo = :"call_record_repo_#{unique}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      %{opts: CallRecord.repo_opts(repo), repo: repo}
    end

    test "opens, writes every task state and closes with the settled bill", %{
      opts: opts,
      repo: repo
    } do
      record = CallRecord.new(@uuid, "openai_live")
      assert :ok = CallRecord.open(record, @started, opts)

      record = CallRecord.put_task(record, "dg_1", 1, "running", %{request: "user: a"})
      assert :ok = CallRecord.write_tasks(record, opts)
      assert {:ok, %{tasks: [%{"state" => "running"}], ended_at: nil}} = get(repo)

      usage = %{voice_cost_cents: 5.35, accounting: "complete"}
      assert :ok = CallRecord.close(record, :cost_limit, usage, @ended, opts)

      assert {:ok,
              %{
                end_reason: "cost_limit",
                voice_cost_cents: 5.35,
                accounting: "complete",
                ended_at: "2026-10-02T09:06:30.000000Z"
              }} = get(repo)
    end

    test "memory off answers disabled, which is a configuration, not a failure" do
      repo = :"call_record_off_#{System.unique_integer([:positive])}"
      start_supervised!({Repo, name: repo, enabled: false}, id: repo)

      assert {:error, :disabled} =
               CallRecord.open(CallRecord.new(@uuid, "openai_live"), @started, server: repo)
    end
  end

  defp get(repo), do: Repo.get_voice_call(@uuid, server: repo)
end
