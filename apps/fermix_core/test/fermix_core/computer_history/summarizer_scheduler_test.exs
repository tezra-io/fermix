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
      {:ok, %{memory_written: true, events: 1, sessions: 1, empty_batches: 0}}
    end

    pid = start_scheduler(repo, unique, fun)
    send(pid, :tick)
    _ = :sys.get_state(pid)

    assert_receive {:ran, ^repo}
    # The claim was released — status is idle again.
    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert state.status == "idle"
  end

  # The cycle line reads every key of `Summarizer.cycle_result`, so a result shape
  # that drifts must fail here rather than in a production daemon's debug log.
  test "the cycle line names the sitting and empty counts", %{repo: repo, unique: unique} do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    fun = fn _opts ->
      {:ok, %{memory_written: false, events: 7, sessions: 3, empty_batches: 2}}
    end

    pid = start_scheduler(repo, unique, fun)

    log =
      capture_log([level: :debug], fn ->
        send(pid, :tick)
        _ = :sys.get_state(pid)
      end)

    assert log =~ "7 events in 3 session(s), 2 empty, memory=false"
  end

  # A tick is cheap when nothing closed, and 5 minutes is what makes "summarized
  # when the sitting ends" feel immediate rather than half-hourly (§24.2). The
  # claim window and the cycle timeout must stay well above it so a running cycle
  # can never be overtaken by the next tick.
  test "the default cadence is five minutes, inside the claim and timeout windows" do
    pid = start_supervised!({Scheduler, name: :ch_sched_cadence, timer_enabled: false})
    state = :sys.get_state(pid)

    assert state.tick_interval_ms == :timer.minutes(5)
    assert state.claim_stale_after_ms == :timer.minutes(30)
    assert state.cycle_timeout_ms == :timer.minutes(15)
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
