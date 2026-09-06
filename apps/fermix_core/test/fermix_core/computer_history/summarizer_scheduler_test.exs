defmodule FermixCore.ComputerHistory.Summarizer.SchedulerTest do
  @moduledoc "MILESTONE_32 §10 — the summarizer scheduler's claim/run/release loop."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Summarizer.Scheduler
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-sched-#{unique}.db")
    repo_name = :"ch_sched_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name, unique: unique}
  end

  defp start_scheduler(repo, unique, run_cycle_fun) do
    start_supervised!(
      {Scheduler,
       name: :"ch_sched_#{unique}", repo: repo, timer_enabled: false, run_cycle_fun: run_cycle_fun}
    )
  end

  test "a tick claims, runs the cycle, and releases the claim", %{repo: repo, unique: unique} do
    test_pid = self()

    fun = fn opts ->
      send(test_pid, {:ran, opts[:repo]})
      {:ok, %{memory_written: true, events: 1}}
    end

    pid = start_scheduler(repo, unique, fun)
    send(pid, :tick)
    _ = :sys.get_state(pid)

    assert_receive {:ran, ^repo}, 1_000

    # The claim was released — status is idle again.
    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.status == "idle"
  end

  test "a concurrent claim is not run twice", %{repo: repo, unique: unique} do
    test_pid = self()
    fun = fn _opts -> send(test_pid, :ran) end

    # Pre-claim the cycle (status -> running) so the scheduler's tick sees it held.
    {:ok, _} =
      Repo.computer_history_claim_cycle(DateTime.utc_now(), :timer.minutes(30), server: repo)

    pid = start_scheduler(repo, unique, fun)
    send(pid, :tick)
    _ = :sys.get_state(pid)

    refute_receive :ran, 200
  end
end
