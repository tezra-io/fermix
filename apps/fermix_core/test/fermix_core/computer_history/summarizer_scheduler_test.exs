defmodule FermixCore.ComputerHistory.Summarizer.SchedulerTest do
  @moduledoc "MILESTONE_32 §10 — the summarizer scheduler's claim/run/release loop."
  # async: false — the cycle-line case lowers the global Logger level, which
  # config/test.exs pins to :warning.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
      {:ok, %{memory_written: true, events: 1, batches: 1, empty_batches: 0}}
    end

    pid = start_scheduler(repo, unique, fun)
    send(pid, :tick)
    _ = :sys.get_state(pid)

    assert_receive {:ran, ^repo}, 1_000

    # The claim was released — status is idle again.
    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.status == "idle"
  end

  # The cycle line reads every key of `Summarizer.cycle_result`, so a result shape
  # that drifts must fail here rather than in a production daemon's debug log.
  test "the cycle line names the batch and empty-batch counts", %{repo: repo, unique: unique} do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    fun = fn _opts -> {:ok, %{memory_written: false, events: 7, batches: 3, empty_batches: 2}} end
    pid = start_scheduler(repo, unique, fun)

    log =
      capture_log([level: :debug], fn ->
        send(pid, :tick)
        _ = :sys.get_state(pid)
      end)

    assert log =~ "7 events in 3 batch(es), 2 empty, memory=false"
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
