defmodule FermixCore.Jobs.SchedulerCuesTest do
  @moduledoc """
  Cue admission inside `Jobs.Scheduler` (M60 §9.2): coalesced wakes, the cue
  share of the run slots, adoption after a restart, and the scheduler's own
  settle of a crashed or orphaned cue run (§9.4).
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Jobs.CueAdmission
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesRunsSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-05-02 14:00:00Z]
  @cron_due ~U[2026-05-02 14:15:00Z]
  # Process work (a claim, a runner spawn, a settle) under a loaded runner.
  @arrives_ms 10_000

  defmodule ParkedRunner do
    @moduledoc false
    # A runner that publishes its run id like the real Runner, reports the run
    # the scheduler started it with, then parks until the test tells it to
    # finish (settling its own run at the time the test gives, then reporting
    # the settle) or to crash.
    alias FermixCore.Jobs.CueAdmission
    alias FermixCore.Jobs.Runner
    alias FermixCore.Memory.Repo

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :run).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      run = Keyword.fetch!(opts, :run)
      notify = Keyword.fetch!(opts, :notify)
      repo = Keyword.fetch!(opts, :repo)
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Runner.put_run_id(run.id)
          send(parent, {:labelled, self()})
          send(notify, {:parked, run, Map.get(run, :cue_delivery_id), self()})
          park(run, repo, notify)
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      after
        10_000 -> {:error, :label_timeout}
      end
    end

    defp park(run, repo, notify) do
      receive do
        {:finish, outcome, %DateTime{} = now} ->
          finish(run, outcome, now, repo)
          send(notify, {:settled, run.id})

        :crash ->
          exit(:runner_crashed)
      end
    end

    defp finish(%{trigger: "cue"} = run, outcome, now, repo) do
      attrs = Map.merge(run, %{status: "ok", completed_at: now, updated_at: now})
      {:ok, _settled} = CueAdmission.settle(attrs, outcome, server: repo)
    end

    defp finish(run, _outcome, now, repo) do
      attrs = Map.merge(run, %{status: "ok", completed_at: now, updated_at: now})
      {:ok, _settled} = Repo.settle_job_run(attrs, server: repo)
    end
  end

  defmodule RecordingRepo do
    @moduledoc false
    # Forwards every request to the real Repo after reporting it to the test.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(request, _from, state) do
      send(state.notify, {:repo_request, request})
      {:reply, GenServer.call(state.real, request), state}
    end
  end

  defmodule ScanFailingRepo do
    @moduledoc false
    # Answers the first `fail` reconcile scans as a Repo that did not answer in
    # time, and forwards everything else to the real Repo.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call({:unsettled_job_runs, _limit}, _from, %{fail: n} = state) when n > 0,
      do: {:reply, {:error, :repo_timeout}, %{state | fail: n - 1}}

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.real, request), state}
  end

  setup do
    ctx = start_repo("scheduler_cues")
    runner_supervisor = :"cue_runner_supervisor_#{System.unique_integer([:positive])}"
    start_supervised!({RunnerSupervisor, name: runner_supervisor})
    {:ok, clock} = Agent.start_link(fn -> @now end)
    Map.merge(ctx, %{runner_supervisor: runner_supervisor, clock: clock})
  end

  # --- fixtures ------------------------------------------------------------------

  defp watcher(conn, sources, opts \\ []) do
    id = insert_watcher(conn, %{filter: "none", sources: sources})
    cap = Keyword.get(opts, :daily_cap, 0)
    exec!(conn, "UPDATE cue_watchers SET daily_cap = ? WHERE id = ?", [cap, id])
    [[job_id]] = rows(conn, "SELECT task_job_id FROM cue_watchers WHERE id = ?", [id])

    exec!(
      conn,
      "UPDATE scheduled_jobs SET schedule_kind = 'cue', schedule_expr = 'cue', " <>
        "next_run_at = NULL, timezone = 'UTC' WHERE id = ?",
      [job_id]
    )

    %{id: id, job_id: job_id}
  end

  defp delivery(conn, watcher, source, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    received = Map.get(attrs, :received_at, DateTime.add(@now, -600, :second))

    [[cue_id]] =
      rows(
        conn,
        """
        INSERT INTO cues (source_ref, item_id, type, received_at, content_hash, payload,
          payload_bytes, routed_count, last_seen_at)
        VALUES (?, ?, 't', ?, ?, '{}', 2, 1, ?) RETURNING id
        """,
        [source, "item-#{unique}", CuesSql.stamp(received), "h#{unique}", CuesSql.stamp(received)]
      )

    [[id]] =
      rows(
        conn,
        """
        INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, received_at, state,
          ready_at, valid_until)
        VALUES (?, ?, ?, ?, 'passed', ?, ?) RETURNING id
        """,
        [
          cue_id,
          watcher.id,
          source,
          CuesSql.stamp(received),
          CuesSql.stamp(received),
          CuesSql.stamp(DateTime.add(received, 7 * 86_400, :second))
        ]
      )

    id
  end

  defp delivery_state(conn, id) do
    [[state, attempts, ready_at]] =
      rows(conn, "SELECT state, task_attempts, ready_at FROM cue_deliveries WHERE id = ?", [id])

    %{state: state, task_attempts: attempts, ready_at: CuesSql.parse_stamp(ready_at)}
  end

  # A recurring job created at @now, so it falls due at @cron_due.
  defp cron_job(repo, name) do
    {:ok, job} =
      Registry.create_job(
        %{
          created_by_trust: "operator",
          name: name,
          schedule: "every 15 minutes",
          task_prompt: "Run."
        },
        repo: repo,
        now: @now
      )

    job
  end

  defp start_scheduler(ctx, opts \\ []) do
    name = :"cue_scheduler_#{System.unique_integer([:positive])}"
    clock = ctx.clock

    child =
      {Scheduler,
       [
         name: name,
         repo: Keyword.get(opts, :repo, ctx.repo),
         runner_supervisor: ctx.runner_supervisor,
         scheduler_enabled: true,
         timer_enabled: false,
         runner_module: ParkedRunner,
         runner_notify: self(),
         clock: fn -> Agent.get(clock, & &1) end,
         cues_running?: fn -> true end,
         cue_notice: Keyword.get(opts, :cue_notice, fn _watcher, _kind, _data -> :ok end),
         max_active_runs: 4
       ]}

    start_supervised!(child)
    name
  end

  defp set_clock(ctx, at), do: Agent.update(ctx.clock, fn _old -> at end)

  # Waits until every message already in the scheduler's mailbox, and the
  # admission pass any of them requested, has been handled.
  defp drain(scheduler) do
    _state = :sys.get_state(scheduler)
    _state = :sys.get_state(scheduler)
    :ok
  end

  defp assert_parked(trigger) do
    assert_receive {:parked, %{trigger: ^trigger} = run, cue_delivery, pid}, @arrives_ms
    {run, cue_delivery, pid}
  end

  defp active_runners(ctx), do: DynamicSupervisor.count_children(ctx.runner_supervisor).active

  # Tells a parked runner to settle its run at the test clock's time, and
  # waits for it to report the settle.
  defp finish_run(ctx, %{id: run_id}, pid, outcome) do
    send(pid, {:finish, outcome, Agent.get(ctx.clock, & &1)})
    assert_receive {:settled, ^run_id}, @arrives_ms
  end

  # A runner that exited is let go by its supervisor when that supervisor
  # handles the exit. `terminate_child/2` is served in the supervisor's order,
  # so once it returns the slot is free, whichever came first.
  defp let_go(ctx, pid) do
    case DynamicSupervisor.terminate_child(ctx.runner_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  # --- wakes ---------------------------------------------------------------------

  describe "cue_wake/1" do
    test "a burst of wakes is one admission pass", ctx do
      {:ok, proxy} = start_supervised({RecordingRepo, real: ctx.repo, notify: self()})
      scheduler = start_scheduler(ctx, repo: proxy)
      drain(scheduler)
      flush_requests()

      pid = GenServer.whereis(scheduler)
      :ok = :sys.suspend(pid)
      for _n <- 1..10, do: :ok = Scheduler.cue_wake(scheduler)
      :ok = :sys.resume(pid)
      drain(scheduler)

      assert Enum.count(flush_requests(), &admission_request?/1) == 1
    end

    test "a wake starts the task's run, holding the claimed delivery", ctx do
      w = watcher(ctx.conn, ["src-a"])
      scheduler = start_scheduler(ctx)
      drain(scheduler)
      id = delivery(ctx.conn, w, "src-a")

      :ok = Scheduler.cue_wake(scheduler)

      {run, cue_delivery, _pid} = assert_parked("cue")
      assert cue_delivery == id
      assert run.job_id == w.job_id
      assert run.cue_delivery_id == id
      assert delivery_state(ctx.conn, id).state == "claimed"
    end

    test "a cast to a scheduler that is not running is dropped" do
      assert :ok = Scheduler.cue_wake(:"no_scheduler_#{System.unique_integer([:positive])}")
    end
  end

  describe "admission triggers" do
    test "a run's end admits the task's next cue without waiting for a tick", ctx do
      w = watcher(ctx.conn, ["src-a"])
      _first = delivery(ctx.conn, w, "src-a")
      second = delivery(ctx.conn, w, "src-a")
      _scheduler = start_scheduler(ctx)

      {run, _first_delivery, pid} = assert_parked("cue")
      finish_run(ctx, run, pid, :ignored)

      {_run, cue_delivery, _pid} = assert_parked("cue")
      assert cue_delivery == second
    end

    test "job_changed admits a resumed task's cues", ctx do
      w = watcher(ctx.conn, ["src-a"])
      id = delivery(ctx.conn, w, "src-a")

      exec!(ctx.conn, "UPDATE scheduled_jobs SET enabled = 0, state = 'paused' WHERE id = ?", [
        w.job_id
      ])

      scheduler = start_scheduler(ctx)
      drain(scheduler)
      assert delivery_state(ctx.conn, id).state == "passed"

      exec!(ctx.conn, "UPDATE scheduled_jobs SET enabled = 1, state = 'scheduled' WHERE id = ?", [
        w.job_id
      ])

      :ok = Scheduler.job_changed(scheduler)
      {_run, ^id, _pid} = assert_parked("cue")
    end

    test "the reconcile tick finds a cue whose wake was lost", ctx do
      w = watcher(ctx.conn, ["src-a"])
      scheduler = start_scheduler(ctx)
      drain(scheduler)
      id = delivery(ctx.conn, w, "src-a")

      send(GenServer.whereis(scheduler), :reconcile_tick)
      {_run, ^id, _pid} = assert_parked("cue")
    end
  end

  # --- C14 / C33: slots ------------------------------------------------------------

  describe "run slots (C14, C33)" do
    test "three cue runs leave a slot that a due cron run takes; a freed slot goes to cron",
         ctx do
      watchers = for n <- 1..4, do: watcher(ctx.conn, ["src-#{n}"])
      [d1, d2, d3, d4] = Enum.map(watchers, fn w -> delivery(ctx.conn, w, w_source(ctx, w)) end)
      cron_a = cron_job(ctx.repo, "Cron A")
      cron_b = cron_job(ctx.repo, "Cron B")
      scheduler = start_scheduler(ctx)

      cue_runs = for _n <- 1..3, do: assert_parked("cue")
      assert cue_runs |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [d1, d2, d3]
      drain(scheduler)
      assert delivery_state(ctx.conn, d4).state == "passed"

      # Three cue runs active: a due cron run still starts (one of the two; the
      # ceiling holds the other back).
      set_clock(ctx, @cron_due)
      :ok = Scheduler.tick(scheduler, now: @cron_due)
      {first_cron, nil, _pid} = assert_parked("schedule")
      assert first_cron.job_id in [cron_a.id, cron_b.id]
      assert active_runners(ctx) == 4
      assert delivery_state(ctx.conn, d4).state == "passed"

      # Four active: when a cue run ends, the held cron run takes the slot. The
      # run's end requests a pass on its own; the tick makes one more once the
      # runner supervisor has let the slot go, whichever pass sees it first.
      {cue_run, _delivery, cue_pid} = hd(cue_runs)
      ref = Process.monitor(cue_pid)
      finish_run(ctx, cue_run, cue_pid, :ignored)
      assert_receive {:DOWN, ^ref, :process, ^cue_pid, :normal}, @arrives_ms
      let_go(ctx, cue_pid)
      :ok = Scheduler.tick(scheduler, now: @cron_due)
      {second_cron, nil, _pid} = assert_parked("schedule")
      assert second_cron.job_id in [cron_a.id, cron_b.id]
      assert second_cron.job_id != first_cron.job_id

      :ok = Scheduler.tick(scheduler, now: @cron_due)
      drain(scheduler)
      assert delivery_state(ctx.conn, d4).state == "passed"
    end

    test "adopted runs count as cue runs after a scheduler restart", ctx do
      watchers = for n <- 1..4, do: watcher(ctx.conn, ["src-#{n}"])
      deliveries = Enum.map(watchers, fn w -> delivery(ctx.conn, w, w_source(ctx, w)) end)
      _first = start_scheduler(ctx)
      for _n <- 1..3, do: assert_parked("cue")

      # Scheduler-only restart: the runners outlive it under the runner supervisor.
      stop_supervised!(Scheduler)
      cron = cron_job(ctx.repo, "After Restart")
      second = start_scheduler(ctx)
      drain(second)

      monitors = :sys.get_state(second).run_monitors
      assert map_size(monitors) == 3
      assert Enum.all?(monitors, fn {_ref, info} -> info.trigger == "cue" end)
      assert delivery_state(ctx.conn, List.last(deliveries)).state == "passed"

      set_clock(ctx, @cron_due)
      :ok = Scheduler.tick(second, now: @cron_due)
      {run, nil, _pid} = assert_parked("schedule")
      assert run.job_id == cron.id
    end

    # TLA cue_inbox CUE-2: with the scan failed the monitors are empty while
    # the runner supervisor still counts the surviving cue runners, so the cue
    # share would read as free and a fourth cue run would take the last slot.
    test "after a restart whose adoption scan fails, no cue run starts until a reconcile succeeds",
         ctx do
      watchers = for n <- 1..4, do: watcher(ctx.conn, ["src-#{n}"])
      deliveries = Enum.map(watchers, fn w -> delivery(ctx.conn, w, w_source(ctx, w)) end)
      waiting = List.last(deliveries)
      _first = start_scheduler(ctx)
      cue_runs = for _n <- 1..3, do: assert_parked("cue")

      stop_supervised!(Scheduler)
      cron = cron_job(ctx.repo, "During Unknown Runs")
      {:ok, proxy} = start_supervised({ScanFailingRepo, real: ctx.repo, fail: 1})
      second = start_scheduler(ctx, repo: proxy)
      drain(second)

      assert :sys.get_state(second).run_monitors == %{}
      :ok = Scheduler.cue_wake(second)
      drain(second)
      assert active_runners(ctx) == 3
      assert delivery_state(ctx.conn, waiting).state == "passed"

      # Cron runs keep their slot rule: the due run starts beside the three.
      set_clock(ctx, @cron_due)
      :ok = Scheduler.tick(second, now: @cron_due)
      {cron_run, nil, _pid} = assert_parked("schedule")
      assert cron_run.job_id == cron.id

      # A reconcile that succeeds adopts the three; the share is full.
      send(GenServer.whereis(second), :reconcile_tick)
      drain(second)
      assert map_size(:sys.get_state(second).run_monitors) == 4
      assert delivery_state(ctx.conn, waiting).state == "passed"

      # A cue run that ends frees a cue slot, and the waiting cue takes it.
      {cue_run, _delivery, cue_pid} = hd(cue_runs)
      ref = Process.monitor(cue_pid)
      finish_run(ctx, cue_run, cue_pid, :ignored)
      assert_receive {:DOWN, ^ref, :process, ^cue_pid, :normal}, @arrives_ms
      let_go(ctx, cue_pid)
      :ok = Scheduler.cue_wake(second)
      {_run, ^waiting, _pid} = assert_parked("cue")
    end

    test "free cue slots are the smaller of the open slots and the cue share" do
      cue = %{trigger: "cue"}
      cron = %{trigger: "schedule"}
      assert CueAdmission.free_slots(0, %{}, 4) == 3
      assert CueAdmission.free_slots(3, %{a: cue, b: cue, c: cue}, 4) == 0
      assert CueAdmission.free_slots(3, %{a: cue, b: cron, c: cron}, 4) == 1
      assert CueAdmission.free_slots(4, %{a: cue, b: cron, c: cron, d: cron}, 4) == 0
      assert CueAdmission.free_slots(5, %{}, 4) == 0
    end
  end

  # --- C25: the cap notice --------------------------------------------------------------

  describe "cap notice (C25)" do
    test "a watcher held only by its daily cap is told so, with the cap and what waits", ctx do
      w = watcher(ctx.conn, ["src-a"], daily_cap: 1)
      _first = delivery(ctx.conn, w, "src-a")
      second = delivery(ctx.conn, w, "src-a")
      test_pid = self()

      notice = fn watcher_id, kind, data ->
        send(test_pid, {:cue_notice, watcher_id, kind, data})
      end

      scheduler = start_scheduler(ctx, cue_notice: notice)

      # While the first run is active its job holds the second cue: not the cap.
      {run, _delivery, pid} = assert_parked("cue")
      drain(scheduler)
      refute_received {:cue_notice, _watcher, _kind, _data}

      finish_run(ctx, run, pid, :ignored)

      assert_receive {:cue_notice, watcher_id, :cap_reached, %{cap: 1, waiting: 1}},
                     @arrives_ms

      assert watcher_id == w.id
      assert delivery_state(ctx.conn, second).state == "passed"
    end
  end

  # --- errors (design §14) -------------------------------------------------------------

  describe "admission errors" do
    test "a failed scan and a failed settle are traced as sweep_error, then logged" do
      repo = :"cue_disabled_repo_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({Repo, name: repo, enabled: false}, id: repo))
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], :emitter)
      opts = [repo_opts: [server: repo], cue_notice: fn _watcher, _kind, _data -> :ok end]

      assert CueAdmission.claim(2, @now, fn job_id -> %{id: job_id} end, opts) == []

      assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m,
                       %{phase: :sweep_error, reason: :cue_claim, result: :error}}

      run = %{id: "run_traced", job_id: "job_traced", status: "error", completed_at: @now}
      assert {:error, :disabled} = CueAdmission.settle(run, {:failed, :other}, server: repo)

      assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m,
                       %{phase: :sweep_error, reason: :cue_settle} = meta}

      assert {meta.job_id, meta.run_id, meta.error_class} ==
               {"job_traced", "run_traced", "disabled"}
    end
  end

  # --- the scheduler's settle (C12, C18) ---------------------------------------------

  describe "crash and reap settle" do
    test "a run that crashes after an allowed mandate call is exhausted, never retried",
         ctx do
      w = watcher(ctx.conn, ["src-a"])
      id = delivery(ctx.conn, w, "src-a")
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], job_id: w.job_id)
      _scheduler = start_scheduler(ctx)
      {run, ^id, pid} = assert_parked("cue")

      exec!(ctx.conn, "UPDATE job_runs SET tools_started_at = ?, started_at = ? WHERE id = ?", [
        DateTime.to_iso8601(@now),
        DateTime.to_iso8601(@now),
        run.id
      ])

      send(pid, :crash)

      assert_receive {:telemetry, _event, _m, %{phase: :exhausted} = meta}, @arrives_ms
      assert meta.session_id == run.session_id
      assert meta.outcome == "failed_after_action"
      assert %{state: "exhausted"} = delivery_state(ctx.conn, id)

      {:ok, job} = Repo.get_scheduled_job(w.job_id, server: ctx.repo)
      assert job.state == "scheduled"
      assert job.last_status == nil
    end

    test "a run that crashes before any action is retried with an attempt spent", ctx do
      w = watcher(ctx.conn, ["src-a"])
      id = delivery(ctx.conn, w, "src-a")
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], job_id: w.job_id)
      _scheduler = start_scheduler(ctx)
      {run, ^id, pid} = assert_parked("cue")

      send(pid, :crash)

      assert_receive {:telemetry, _event, _m, %{phase: :retry} = meta}, @arrives_ms
      assert meta.session_id == run.session_id
      assert meta.attempt == 1

      assert %{state: "passed", task_attempts: 1, ready_at: ready_at} =
               delivery_state(ctx.conn, id)

      assert DateTime.diff(ready_at, @now, :second) == 30
    end

    test "a restart with a cue run in flight settles it by the reap rows", ctx do
      capped = watcher(ctx.conn, ["src-a"], daily_cap: 10)
      uncapped = watcher(ctx.conn, ["src-b"])
      started = watcher(ctx.conn, ["src-c"], daily_cap: 10)
      held = delivery(ctx.conn, capped, "src-a")
      spent = delivery(ctx.conn, uncapped, "src-b")
      ran = delivery(ctx.conn, started, "src-c")

      # A daemon that died mid-run: claimed rows, no runner behind them.
      for w <- [capped, uncapped, started] do
        {:ok, _claim} = Repo.claim_cue_run(w.job_id, orphan_run(w), @now, server: ctx.repo)
      end

      exec!(
        ctx.conn,
        "UPDATE job_runs SET status = 'running', started_at = ? WHERE job_id = ?",
        [DateTime.to_iso8601(@now), started.job_id]
      )

      scheduler = start_scheduler(ctx)
      drain(scheduler)

      assert %{state: "passed", task_attempts: 0} = delivery_state(ctx.conn, held)
      assert %{state: "passed", task_attempts: 1} = delivery_state(ctx.conn, spent)
      assert %{state: "passed", task_attempts: 1} = delivery_state(ctx.conn, ran)

      for w <- [capped, uncapped, started] do
        {:ok, [run]} = Repo.list_job_runs(%{job_id: w.job_id}, server: ctx.repo)
        assert run.status == "error"
        assert run.error =~ "no live runner"
        {:ok, job} = Repo.get_scheduled_job(w.job_id, server: ctx.repo)
        assert job.state == "scheduled"
      end
    end
  end

  # --- telemetry and session ids ------------------------------------------------------

  describe "claimed telemetry and session ids" do
    test "the claim emits claimed with the run's session id and queue time", ctx do
      w = watcher(ctx.conn, ["src-a"])
      id = delivery(ctx.conn, w, "src-a", %{received_at: DateTime.add(@now, -90, :second)})
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], job_id: w.job_id)
      _scheduler = start_scheduler(ctx)
      {run, ^id, _pid} = assert_parked("cue")

      assert_receive {:telemetry, [:fermix, :cue, :lifecycle], measurements,
                      %{phase: :claimed} = meta},
                     @arrives_ms

      assert measurements.queue_ms == 90_000
      assert meta.session_id == run.session_id
      assert meta.run_id == run.id
      assert meta.delivery_id == id
      assert meta.watcher_id == w.id
      assert meta.source_ref == "src-a"
    end

    test "two runs of one job started in one second never share a session id", ctx do
      w = watcher(ctx.conn, ["src-a"])
      _first = delivery(ctx.conn, w, "src-a")
      _second = delivery(ctx.conn, w, "src-a")
      cron = cron_job(ctx.repo, "Cron Session")
      scheduler = start_scheduler(ctx)

      # The clock stands still: both cue runs start in the same second.
      {first_run, _d, pid} = assert_parked("cue")
      finish_run(ctx, first_run, pid, :ignored)
      {second_run, _d, _pid} = assert_parked("cue")
      assert first_run.job_id == second_run.job_id
      assert first_run.session_id != second_run.session_id

      for run <- [first_run, second_run] do
        assert run.session_id =~ ~r/^cron_#{run.job_id}_20260502_140000_[0-9a-f]{6}$/
      end

      set_clock(ctx, @cron_due)
      :ok = Scheduler.tick(scheduler, now: @cron_due)
      {cron_run, nil, _pid} = assert_parked("schedule")
      assert cron_run.session_id =~ ~r/^cron_#{cron.id}_20260502_141500_[0-9a-f]{6}$/
    end
  end

  # --- helpers -----------------------------------------------------------------------

  defp w_source(ctx, w) do
    [[source]] =
      rows(ctx.conn, "SELECT source_ref FROM cue_watcher_sources WHERE watcher_id = ?", [w.id])

    source
  end

  defp orphan_run(w) do
    %{
      id: "run_orphan_#{System.unique_integer([:positive])}",
      job_id: w.job_id,
      session_id: "cron_#{w.job_id}_orphan",
      trigger: "cue",
      status: "queued",
      claimed_at: @now,
      delivery_status: "none",
      created_at: @now,
      updated_at: @now
    }
  end

  defp admission_request?({:cues, CuesRunsSql, {:admission_candidates, _now, _limit}}), do: true
  defp admission_request?(_request), do: false

  defp flush_requests(acc \\ []) do
    receive do
      {:repo_request, request} -> flush_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
