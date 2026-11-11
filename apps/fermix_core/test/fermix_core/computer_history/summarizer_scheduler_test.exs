defmodule FermixCore.ComputerHistory.Summarizer.SchedulerTest do
  @moduledoc """
  MILESTONE_32 §10; M97 §8.1 — the scheduler's two halves: sending this
  machine's sittings under a claim in its own store, and the home's roll-up.
  """
  # async: false — the cycle-line case lowers the global Logger level, which
  # config/test.exs pins to :warning.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Report
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Summarizer.Scheduler

  setup do
    unique = System.unique_integer([:positive])
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("ch-sched")
    spool = start_supervised!({Spool, name: nil, path: Path.join([dir, "device", "history.db"])})
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)

    %{spool: spool, unique: unique}
  end

  defp uplink(_payload), do: {:error, :unused}

  defp start_scheduler(ctx, opts) do
    defaults = [
      name: :"ch_sched_#{ctx.unique}",
      spool: ctx.spool,
      repo: nil,
      uplink: &uplink/1,
      recording_fun: fn -> true end,
      timer_enabled: false,
      run_sittings_fun: fn _opts -> {:ok, %{sittings: 0, sent: 0, notes: 0, events: 0}} end,
      run_rollup_fun: fn _opts -> :skipped end,
      deliver_fun: fn _opts -> %{applied: [], away: [], failed: []} end,
      apply_here_fun: fn _opts -> {:ok, 0} end
    ]

    start_supervised!({Scheduler, Keyword.merge(defaults, opts)})
  end

  defp tick(pid) do
    send(pid, :tick)
    _ = :sys.get_state(pid)
    :ok
  end

  test "a tick claims, sends this machine's sittings, and releases the claim", ctx do
    test_pid = self()

    fun = fn opts ->
      send(test_pid, {:ran, opts[:spool], opts[:uplink]})
      {:ok, %{sittings: 1, sent: 1, notes: 1, events: 3}}
    end

    pid = start_scheduler(ctx, run_sittings_fun: fun)
    tick(pid)

    spool = ctx.spool
    assert_receive {:ran, ^spool, uplink} when is_function(uplink, 1)
    # The claim was released — status is idle again.
    {:ok, state} = Spool.state(server: spool)
    assert state.status == "idle"
  end

  # The cycle line reads every key of `Sittings.result`, so a result shape that
  # drifts must fail here rather than in a production daemon's debug log.
  test "the cycle line names the sittings, sends and notes", ctx do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    fun = fn _opts -> {:ok, %{sittings: 3, sent: 2, notes: 1, events: 7}} end
    pid = start_scheduler(ctx, run_sittings_fun: fun)

    log = capture_log([level: :debug], fn -> tick(pid) end)

    assert log =~ "3 sitting(s), 2 sent, 1 note(s), 7 event(s)"
  end

  test "a held cycle says why", ctx do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    pid = start_scheduler(ctx, run_sittings_fun: fn _opts -> {:held, "unanswered"} end)

    log = capture_log([level: :info], fn -> tick(pid) end)

    assert log =~ ~s(computer_history sending held: "unanswered")
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

  test "a concurrent claim is not run twice", ctx do
    test_pid = self()
    fun = fn _opts -> send(test_pid, :ran) end

    # Pre-claim the cycle (status -> running) so the scheduler's tick sees it held.
    {:ok, _} = Spool.claim(DateTime.utc_now(), :timer.minutes(30), server: ctx.spool)

    pid = start_scheduler(ctx, run_sittings_fun: fun)
    tick(pid)

    refute_received :ran
  end

  test "nothing is sent while this machine does not record", ctx do
    test_pid = self()
    fun = fn _opts -> send(test_pid, :ran) end

    pid = start_scheduler(ctx, run_sittings_fun: fun, recording_fun: fn -> false end)
    tick(pid)

    refute_received :ran
  end

  # The home: its roll-up runs on every tick it holds a home store, with this
  # machine's store for the guard while it records, and none while it does not.
  test "the home rolls up with this machine's store while it records", ctx do
    test_pid = self()
    fun = fn opts -> send(test_pid, {:rolled, opts[:repo], opts[:spool]}) && :ok end

    pid = start_scheduler(ctx, repo: :a_home_repo, run_rollup_fun: fun)
    tick(pid)

    spool = ctx.spool
    assert_receive {:rolled, :a_home_repo, ^spool}
  end

  test "a home that records nothing rolls up with no machine store", ctx do
    test_pid = self()
    fun = fn opts -> send(test_pid, {:rolled, opts[:spool]}) && :ok end

    pid =
      start_scheduler(ctx,
        repo: :a_home_repo,
        uplink: nil,
        recording_fun: fn -> false end,
        run_rollup_fun: fun
      )

    tick(pid)

    assert_receive {:rolled, nil}
  end

  # M97 §8.5: the home's tick tells its computers of the purges and pauses they
  # have not applied, which is how one that was away gets them; a computer,
  # which keeps no home store, tells nobody.
  test "the home's tick delivers purges and pauses; a computer's does not", ctx do
    test_pid = self()

    deliver = fn opts ->
      send(test_pid, {:delivered, opts[:repo]})
      %{applied: [], away: [], failed: []}
    end

    home = start_scheduler(ctx, repo: :a_home_repo, deliver_fun: deliver)
    tick(home)
    assert_receive {:delivered, :a_home_repo}
    stop_supervised!(Scheduler)

    computer = start_scheduler(ctx, repo: nil, deliver_fun: deliver)
    tick(computer)
    refute_received {:delivered, _repo}
  end

  # M97 §8.5, history_submit HS-2: a purge or pause from chat this machine has
  # not applied (its own apply failed) is applied on the home's next tick,
  # whether or not history records here now: a store that holds raw events from
  # before an off still owes the purge its delete.
  test "the home's tick applies this machine's own pending intervals, recording or not", ctx do
    test_pid = self()
    apply_here = fn opts -> send(test_pid, {:applied_here, opts}) && {:ok, 0} end

    pid =
      start_scheduler(ctx,
        repo: :a_home_repo,
        recording_fun: fn -> false end,
        apply_here_fun: apply_here
      )

    tick(pid)
    spool = ctx.spool
    assert_receive {:applied_here, [repo: :a_home_repo, spool: ^spool]}
  end

  test "a home that keeps no store applies nothing here and sends nothing", ctx do
    test_pid = self()

    pid =
      start_scheduler(ctx,
        repo: :a_home_repo,
        spool: nil,
        run_sittings_fun: fn _opts -> send(test_pid, :sent) end,
        apply_here_fun: fn _opts -> send(test_pid, :applied_here) && {:ok, 0} end
      )

    tick(pid)
    refute_received :sent
    refute_received :applied_here
  end

  # M97 §8.5: the home holds no raw record of a computer, so a computer reports
  # its recorder (a state word and counts) from its sending cycle.
  test "a computer reports its recorder after its sittings, from the same cycle", ctx do
    test_pid = self()

    pid =
      start_scheduler(ctx,
        report: fn report -> send(test_pid, {:report, self(), report}) && :ok end,
        run_sittings_fun: fn _opts -> send(test_pid, {:sittings, self()}) && {:ok, empty()} end,
        status_fun: fn -> %{mode: :capturing, reason: nil, lock_holder: nil} end
      )

    tick(pid)
    assert_receive {:sittings, cycle}
    assert_receive {:report, ^cycle, report}
    assert %{"recorder" => "running", "events" => 0, "unsent" => 0} = report
    assert Report.validate(report) == :ok
  end

  defp empty, do: %{sittings: 0, sent: 0, notes: 0, events: 0}

  test "a computer, with no home store, never rolls up", ctx do
    test_pid = self()
    fun = fn _opts -> send(test_pid, :rolled) && :ok end

    pid = start_scheduler(ctx, repo: nil, run_rollup_fun: fun)
    tick(pid)

    refute_received :rolled
  end
end
