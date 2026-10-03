defmodule FermixCore.Realtime.CallSweepTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallSweep

  @interrupted "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @silent "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
  @finished "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
  @this_boot "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-call-sweep-#{unique}.db")
    repo = :"call_sweep_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  test "closes every record a restart left open and fails its unfinished tasks", %{repo: repo} do
    earlier = DateTime.add(DateTime.utc_now(), -600, :second)

    interrupted =
      CallRecord.new(@interrupted, "openai_live")
      |> CallRecord.put_task("dg_1", 1, "completed", %{summary: "Booked."})
      |> CallRecord.put_task("dg_2", 1, "running", %{request: "user: and lunch"})
      |> CallRecord.put_task("dg_3", 1, "created")

    open!(interrupted, earlier, repo)
    open!(CallRecord.new(@silent, "openai_live"), earlier, repo)
    finished = CallRecord.new(@finished, "openai_live")
    open!(finished, earlier, repo)
    usage = %{voice_cost_cents: 1.5, accounting: "complete"}
    :ok = CallRecord.close(finished, :call_stop, usage, earlier, CallRecord.repo_opts(repo))

    log = capture_log(fn -> run_sweep(repo) end)
    assert log =~ "closed 2 call record(s)"

    assert {:ok, swept} = Repo.get_voice_call(@interrupted, server: repo)

    assert %{end_reason: "daemon_restarted", accounting: "incomplete", voice_cost_cents: nil} =
             swept

    assert is_binary(swept.ended_at)

    assert Enum.map(swept.tasks, &{&1["task_id"], &1["state"], &1["summary"]}) == [
             {"dg_1", "completed", "Booked."},
             {"dg_2", "failed", "daemon_restarted"},
             {"dg_3", "failed", "daemon_restarted"}
           ]

    assert {:ok, %{end_reason: "daemon_restarted"}} = Repo.get_voice_call(@silent, server: repo)

    assert {:ok, %{end_reason: "call_stop", voice_cost_cents: 1.5}} =
             Repo.get_voice_call(@finished, server: repo)
  end

  # The cutoff is taken before the voice socket exists: a call this boot
  # started is a live call, never a stranded record.
  test "a call started after the sweep began is left open", %{repo: repo} do
    later = DateTime.add(DateTime.utc_now(), 3_600, :second)
    open!(CallRecord.new(@this_boot, "openai_live"), later, repo)

    run_sweep(repo)

    assert {:ok, %{ended_at: nil, end_reason: nil}} =
             Repo.get_voice_call(@this_boot, server: repo)
  end

  test "with memory off there is nothing to sweep and nothing is said" do
    repo = :"call_sweep_off_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: repo, enabled: false}, id: repo)

    refute capture_log(fn -> run_sweep(repo) end) =~ "call record"
  end

  defp open!(record, started_at, repo) do
    opts = CallRecord.repo_opts(repo)
    :ok = CallRecord.open(record, started_at, opts)
    :ok = CallRecord.write_tasks(record, opts)
  end

  # A boot step, not a service: the pass runs once and the process stops normally.
  defp run_sweep(repo) do
    {:ok, sweep} = CallSweep.start_link(record_repo: repo)
    ref = Process.monitor(sweep)
    assert_receive {:DOWN, ^ref, :process, ^sweep, :normal}, 5_000
  end
end
