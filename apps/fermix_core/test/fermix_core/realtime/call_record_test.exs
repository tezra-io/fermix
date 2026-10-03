defmodule FermixCore.Realtime.CallRecordTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.LiveText

  @uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @other_uuid "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
  @third_uuid "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
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

    # The end of a speaker-labelled request is the ask itself, so the record
    # keeps the end, cut the way the request the bridge was given is (M56 §4.1).
    test "the request is capped at 2 KB from the front on a character boundary" do
      # Two-byte characters after one ASCII byte: the cut point falls mid-character.
      long = "a" <> String.duplicate("é", 2_000) <> "user: use that link"

      [task] =
        CallRecord.new(@uuid, "openai_live")
        |> CallRecord.put_task("dg_1", 1, "running", %{request: long})
        |> Map.fetch!(:tasks)

      assert byte_size(task["request"]) <= 2_048
      assert String.valid?(task["request"])
      assert String.starts_with?(task["request"], LiveText.cut_marker())
      assert String.ends_with?(task["request"], "user: use that link")
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
      assert :ok = CallRecord.close(record, :cost_limit, usage, @ended, opts, :nothing)

      assert {:ok,
              %{
                end_reason: "cost_limit",
                voice_cost_cents: 5.35,
                accounting: "complete",
                ended_at: "2026-10-02T09:06:30.000000Z",
                gist_status: "none",
                row_state: "none"
              }} = get(repo)
    end

    # M56 §4.2: what a call owes the chat is written with its settled bill.
    test "a close owes a gist and a row, a row alone, or nothing", %{opts: opts, repo: repo} do
      usage = %{voice_cost_cents: 5.35, accounting: "complete"}

      for {owes, uuid, gist_status, row_state} <- [
            {:gist, @uuid, "pending", "row_pending"},
            {:row, @other_uuid, "none", "row_pending"},
            {:nothing, @third_uuid, "none", "none"}
          ] do
        record = CallRecord.new(uuid, "openai_live")
        :ok = CallRecord.open(record, @started, opts)
        assert :ok = CallRecord.close(record, :call_stop, usage, @ended, opts, owes)

        assert {:ok, %{gist_status: ^gist_status, row_state: ^row_state}} =
                 Repo.get_voice_call(uuid, server: repo)
      end
    end

    test "a gist is recorded once with its mark, or failed once", %{opts: opts, repo: repo} do
      owe!(@uuid, :gist, opts)
      assert :ok = CallRecord.record_gist(@uuid, {:ok, "Planned the trip.", true}, opts)

      assert {:ok, %{gist: "Planned the trip.", gist_status: "written", gist_tainted: true}} =
               get(repo)

      assert {:error, :not_found} = CallRecord.record_gist(@uuid, {:error, :timeout}, opts)

      owe!(@other_uuid, :gist, opts)
      assert :ok = CallRecord.record_gist(@other_uuid, {:error, :timeout}, opts)

      assert {:ok, %{gist: nil, gist_status: "failed"}} =
               Repo.get_voice_call(@other_uuid, server: repo)
    end

    test "an owed row is rendered from the record, written once and marked written", %{
      opts: opts,
      repo: repo
    } do
      owe!(@uuid, :gist, opts)
      :ok = CallRecord.record_gist(@uuid, {:ok, "Planned the trip.", false}, opts)
      test_pid = self()

      write = fn call, text ->
        send(test_pid, {:row, call, text})
        {:ok, 77}
      end

      assert {:ok, 77} = CallRecord.write_row(@uuid, write, opts)
      assert_receive {:row, %{"uuid" => @uuid, "event" => "ended"}, text}
      assert text == "Voice call, 7 minutes\n\nPlanned the trip."
      assert {:ok, %{row_state: "row_written"}} = get(repo)

      assert :not_owed = CallRecord.write_row(@uuid, write, opts)
      refute_received {:row, _call, _text}
    end

    # The row carries the settled cost and the gist or its failure, so it waits
    # for both (M56 §4.2): a gist still being made holds it back.
    test "a row is not written while its gist is still pending", %{opts: opts} do
      owe!(@uuid, :gist, opts)

      assert {:error, :gist_pending} =
               CallRecord.write_row(@uuid, fn _call, _text -> flunk("written") end, opts)
    end

    test "a write that fails leaves the row owed", %{opts: opts, repo: repo} do
      owe!(@uuid, :row, opts)

      assert {:error, :no_timeline} =
               CallRecord.write_row(@uuid, fn _call, _text -> {:error, :no_timeline} end, opts)

      assert {:ok, %{row_state: "row_pending"}} = get(repo)
    end

    # M56 §4.2, §8: a daemon that died after a call settled left its gist
    # pending and its row owed. The boot fails the gist, which no process will
    # finish, and writes the row from the task list.
    test "the boot sweep fails a pending gist and writes every owed row", %{
      opts: opts,
      repo: repo
    } do
      record =
        CallRecord.new(@uuid, "openai_live")
        |> CallRecord.put_task("dg_1", 1, "completed", %{summary: "Booked for 10am."})

      :ok = CallRecord.open(record, @started, opts)
      usage = %{voice_cost_cents: 5.35, accounting: "complete"}
      :ok = CallRecord.close(record, :call_stop, usage, @ended, opts, :gist)
      owe!(@other_uuid, :row, opts)
      owe!(@third_uuid, :nothing, opts)
      test_pid = self()

      write = fn call, text ->
        send(test_pid, {:row, call["uuid"], call["gist_status"], text})
        {:ok, 9}
      end

      cutoff = DateTime.add(@ended, 3_600, :second)
      assert {:ok, written} = CallRecord.sweep_rows(cutoff, write, opts)
      assert Enum.sort(written) == Enum.sort([@uuid, @other_uuid])

      assert_receive {:row, @uuid, "failed", text}
      assert text == "Voice call, 7 minutes\n\n- Completed: Booked for 10am."
      assert_receive {:row, @other_uuid, "none", "Voice call, 7 minutes"}
      refute_received {:row, @third_uuid, _status, _text}

      assert {:ok, %{gist_status: "failed", row_state: "row_written"}} = get(repo)
      assert {:ok, []} = CallRecord.sweep_rows(cutoff, write, opts)
    end

    test "a call this boot started is not swept", %{opts: opts, repo: repo} do
      owe!(@uuid, :gist, opts)

      assert {:ok, []} =
               CallRecord.sweep_rows(@started, fn _call, _text -> flunk("written") end, opts)

      assert {:ok, %{gist_status: "pending", row_state: "row_pending"}} = get(repo)
    end

    test "memory off answers disabled, which is a configuration, not a failure" do
      repo = :"call_record_off_#{System.unique_integer([:positive])}"
      start_supervised!({Repo, name: repo, enabled: false}, id: repo)

      assert {:error, :disabled} =
               CallRecord.open(CallRecord.new(@uuid, "openai_live"), @started, server: repo)

      assert {:error, :disabled} = CallRecord.recent_gists(3, server: repo)

      assert {:error, :disabled} =
               CallRecord.sweep_rows(@ended, fn _c, _t -> {:ok, 1} end, server: repo)
    end

    test "the recent gists are read newest first, and none asked for reads nothing", %{
      opts: opts
    } do
      owe!(@uuid, :gist, opts)
      assert {:ok, []} = CallRecord.recent_gists(3, opts)

      :ok = CallRecord.record_gist(@uuid, {:ok, "Planned the trip.", true}, opts)

      assert {:ok, [%{gist: "Planned the trip.", tainted: true, started_at: started_at}]} =
               CallRecord.recent_gists(3, opts)

      assert started_at == "2026-10-02T09:00:00.000000Z"
      assert {:ok, []} = CallRecord.recent_gists(0, server: :no_such_repo)
    end
  end

  defp get(repo), do: Repo.get_voice_call(@uuid, server: repo)

  defp owe!(uuid, owes, opts) do
    record = CallRecord.new(uuid, "openai_live")
    :ok = CallRecord.open(record, @started, opts)
    usage = %{voice_cost_cents: 5.35, accounting: "complete"}
    :ok = CallRecord.close(record, :call_stop, usage, @ended, opts, owes)
  end
end
