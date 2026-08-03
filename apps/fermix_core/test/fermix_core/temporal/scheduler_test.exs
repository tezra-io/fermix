defmodule FermixCore.Temporal.SchedulerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.Delivery
  alias FermixCore.Temporal.DeliverySupervisor
  alias FermixCore.Temporal.DeliveryWorker
  alias FermixCore.Temporal.Planner
  alias FermixCore.Temporal.Renderer
  alias FermixCore.Temporal.Scheduler

  @tz "America/New_York"
  @created_at ~U[2026-09-01 12:00:00Z]

  # A worker that parks: it holds its delivery slot and its claim, so capacity,
  # racing-tick, and monitor-invariant behaviour can be observed.
  defmodule ParkedWorker do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.reminder.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(args) do
      notify = Keyword.fetch!(args.delivery_opts, :notify)
      id = args.reminder.id

      pid =
        spawn_link(fn ->
          send(notify, {:worker_started, id, self()})
          Process.sleep(:infinity)
        end)

      {:ok, pid}
    end
  end

  # A worker that dies without settling its claimed row.
  defmodule CrashingWorker do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.reminder.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(args) do
      notify = Keyword.fetch!(args.delivery_opts, :notify)
      id = args.reminder.id

      pid =
        spawn_link(fn ->
          send(notify, {:worker_started, id, self()})
          exit(:temporal_worker_crashed)
        end)

      {:ok, pid}
    end
  end

  # A repo server that faults on every operation, so the scheduler's fault paths
  # can be observed without corrupting a real database.
  defmodule FaultingRepo do
    @moduledoc false

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :db_down}, state}
  end

  # A worker that cannot start at all, after the claim already consumed an attempt.
  defmodule RefusingWorker do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.reminder.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(_args), do: {:error, :worker_start_refused}
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-temporal-scheduler-#{unique}.db")
    repo = :"temporal_sched_repo_#{unique}"
    supervisor = :"temporal_sched_sup_#{unique}"
    clock = :"temporal_sched_clock_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({DeliverySupervisor, name: supervisor})

    start_supervised!(%{
      id: {:clock, clock},
      start: {Agent, :start_link, [fn -> @created_at end, [name: clock]]},
      restart: :temporary
    })

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, supervisor: supervisor, clock: clock, unique: unique}
  end

  defp set_now(ctx, %DateTime{} = now), do: Agent.update(ctx.clock, fn _old -> now end)

  defp start_scheduler(ctx, opts) do
    name = :"temporal_scheduler_#{ctx.unique}_#{System.unique_integer([:positive])}"
    clock = ctx.clock

    start_supervised!(
      {Scheduler,
       Keyword.merge(
         [
           name: name,
           repo: ctx.repo,
           delivery_supervisor: ctx.supervisor,
           delivery_worker_module: ParkedWorker,
           delivery_opts: [notify: self()],
           now_fn: fn -> Agent.get(clock, & &1) end,
           # `config/test.exs` keeps the app-tree instance dark; these instances
           # are the ones under test and opt back in explicitly.
           scheduler_enabled: true,
           timer_enabled: false
         ],
         opts
       )},
      id: name
    )

    name
  end

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp reminder_spec(title, occurrence_at) do
    local = DateTime.shift_zone!(occurrence_at, @tz)

    %{
      title: title,
      description: nil,
      kind: "explicit_reminder",
      time_kind: "datetime",
      local_date: DateTime.to_date(local),
      local_time: DateTime.to_time(local),
      timezone: @tz,
      occurrence_at: occurrence_at,
      recurrence_kind: "once",
      recurrence_month: nil,
      recurrence_day: nil,
      leap_day_policy: nil,
      reminder_plan: [%{rule_id: "at_time", kind: :at_occurrence}]
    }
  end

  defp birthday_spec do
    {:ok, rules} = Defaults.plan_for("birthday", "date")

    %{
      title: "Sarah's birthday",
      description: nil,
      kind: "birthday",
      time_kind: "date",
      local_date: nil,
      local_time: nil,
      timezone: @tz,
      occurrence_at: nil,
      recurrence_kind: "yearly",
      recurrence_month: 9,
      recurrence_day: 14,
      leap_day_policy: nil,
      reminder_plan: rules
    }
  end

  defp create!(ctx, spec, now \\ @created_at) do
    {:ok, plan} = Planner.materialize(spec, now)
    occurrences = Enum.map(plan.occurrences, &Map.put(&1, :id, uid("rem")))

    attrs =
      spec
      |> Map.put(:reminder_plan, Defaults.encode_plan(spec.reminder_plan))
      |> Map.merge(%{
        id: uid("evt"),
        agent_id: "main",
        owner_id: "default",
        dedupe_key: uid("dedupe"),
        delivery_platform: "telegram",
        delivery_destination: "12345",
        delivery_thread_scope: "root",
        source_channel: "telegram",
        source_chat_id: "12345",
        source_thread_scope: "root",
        source_session_id: "sess-1",
        created_by_trust: "operator",
        created_by_origin: "interactive"
      })

    {:ok, {:created, event, rows}} =
      Repo.create_temporal_event(attrs, %{plan | occurrences: occurrences}, now, server: ctx.repo)

    {event, rows}
  end

  defp reminders(ctx, filter) do
    {:ok, rows} = Repo.list_temporal_reminders(filter, server: ctx.repo)
    rows
  end

  defp reminder(ctx, id) do
    {:ok, row} = Repo.get_temporal_reminder(id, server: ctx.repo)
    row
  end

  # `:sys.get_state/1` is a synchronous round trip through the scheduler's own
  # mailbox: any monitor `:DOWN` already queued is handled before it replies, so
  # assertions never race a worker exit.
  defp sync(scheduler), do: :sys.get_state(scheduler)

  defp child_index(order, module) do
    index = Enum.find_index(order, &(&1 == module))
    assert index, "#{inspect(module)} is not a child of the application supervisor"
    index
  end

  defp await_worker_exit(id) do
    assert_receive {:worker_started, ^id, pid}, 1_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    :ok
  end

  describe "due ticks" do
    test "claims a due reminder and starts one monitored worker", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, [])

      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)

      assert_receive {:worker_started, id, _pid}, 1_000
      assert id == row.id
      assert reminder(ctx, row.id).status == "delivering"
      assert reminder(ctx, row.id).attempt_count == 1
      assert map_size(sync(scheduler).monitors) == 1
    end

    test "claims nothing and starts no worker before the due time", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, [])

      early = DateTime.add(due, -60, :second)
      set_now(ctx, early)
      :ok = Scheduler.tick(scheduler, now: early)

      refute_receive {:worker_started, _id, _pid}, 100
      assert reminder(ctx, row.id).status == "pending"
      assert reminder(ctx, row.id).attempt_count == 0
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 0
    end

    test "two racing ticks deliver the row once", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, [])

      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)
      :ok = Scheduler.tick(scheduler, now: due)

      assert_receive {:worker_started, _id, _pid}, 1_000
      refute_receive {:worker_started, _other, _pid}, 100
      assert reminder(ctx, row.id).attempt_count == 1
      assert DynamicSupervisor.count_children(ctx.supervisor).active == 1
    end

    test "never claims more rows than the four free delivery slots", ctx do
      due = ~U[2026-09-20 17:00:00Z]

      rows =
        Enum.map(1..6, fn index ->
          {_event, [row]} = create!(ctx, reminder_spec("Reminder #{index}", due))
          row
        end)

      scheduler = start_scheduler(ctx, [])
      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)

      assert DynamicSupervisor.count_children(ctx.supervisor).active == 4
      statuses = Enum.map(rows, &reminder(ctx, &1.id).status)
      assert Enum.count(statuses, &(&1 == "delivering")) == 4
      assert Enum.count(statuses, &(&1 == "pending")) == 2
      assert map_size(sync(scheduler).monitors) == 4
    end

    test "an unregistered delivery supervisor is zero capacity and re-arms at the floor", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))

      scheduler =
        start_scheduler(ctx,
          delivery_supervisor: :temporal_delivery_supervisor_absent,
          timer_enabled: true
        )

      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)

      assert reminder(ctx, row.id).status == "pending"
      assert reminder(ctx, row.id).attempt_count == 0

      remaining = Process.read_timer(sync(scheduler).due_timer)
      assert remaining > 4_000 and remaining <= 5_000
    end
  end

  describe "worker lifecycle" do
    test "a crashed worker returns the row to pending with its attempt consumed", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, delivery_worker_module: CrashingWorker)

      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)
      :ok = await_worker_exit(row.id)
      sync(scheduler)

      settled = reminder(ctx, row.id)
      assert settled.status == "pending"
      assert settled.attempt_count == 1
      assert DateTime.compare(settled.ready_at, DateTime.add(due, 5, :second)) == :eq
      assert map_size(sync(scheduler).monitors) == 0
    end

    test "a fifth-attempt crash is terminal failed, never a sixth attempt", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, delivery_worker_module: CrashingWorker)

      final =
        Enum.reduce(0..4, due, fn _index, now ->
          set_now(ctx, now)
          :ok = Scheduler.tick(scheduler, now: now)
          :ok = await_worker_exit(row.id)
          sync(scheduler)
          DateTime.add(now, 5, :second)
        end)

      settled = reminder(ctx, row.id)
      assert settled.status == "failed"
      assert settled.attempt_count == 5

      set_now(ctx, final)
      :ok = Scheduler.tick(scheduler, now: final)
      refute_receive {:worker_started, _id, _pid}, 100
      assert reminder(ctx, row.id).attempt_count == 5
    end

    test "a worker that cannot start settles the claimed row at the retry floor", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, delivery_worker_module: RefusingWorker)

      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)

      settled = reminder(ctx, row.id)
      assert settled.status == "pending"
      assert settled.attempt_count == 1
      assert DateTime.compare(settled.ready_at, DateTime.add(due, 5, :second)) == :eq
      assert map_size(sync(scheduler).monitors) == 0
    end
  end

  describe "timers" do
    test "event_changed arms one timer at the earliest ready_at", ctx do
      now = ~U[2026-09-20 16:30:00Z]
      due = ~U[2026-09-20 17:00:00Z]
      set_now(ctx, now)

      scheduler = start_scheduler(ctx, timer_enabled: true)
      create!(ctx, reminder_spec("Submit the report", due))

      :ok = GenServer.cast(scheduler, :event_changed)
      remaining = Process.read_timer(sync(scheduler).due_timer)

      assert remaining > 1_799_000 and remaining <= 1_800_000
    end

    test "a reminder sixty days out arms a bounded recheck instead of a months-long timer", ctx do
      now = ~U[2026-09-20 17:00:00Z]
      set_now(ctx, now)

      scheduler = start_scheduler(ctx, timer_enabled: true)

      create!(
        ctx,
        reminder_spec("Renew the passport", DateTime.add(now, 60 * 86_400, :second)),
        now
      )

      :ok = GenServer.cast(scheduler, :event_changed)
      remaining = Process.read_timer(sync(scheduler).due_timer)

      assert remaining > 86_399_000 and remaining <= 86_400_000
    end

    test "a pending row past its validity boundary never arms a zero-delay timer", ctx do
      # §10.4, the daemon-was-down case: the row is pending but unclaimable, so
      # arming at its `ready_at` would fire a tick that claims nothing and
      # re-arms at 0ms — a ~1kHz spin against the single-writer Repo (§6.3's
      # "a stuck row cannot hot-loop"). The still-valid row is the one the timer
      # must point at.
      stale_due = ~U[2026-09-20 17:00:00Z]
      {_event, [stale]} = create!(ctx, reminder_spec("Stale reminder", stale_due))

      boot = DateTime.add(stale_due, 3 * 86_400, :second)
      live_due = DateTime.add(boot, 1_800, :second)
      {_event, [live]} = create!(ctx, reminder_spec("Live reminder", live_due), boot)

      set_now(ctx, boot)
      scheduler = start_scheduler(ctx, timer_enabled: true)

      assert reminder(ctx, stale.id).status == "pending"
      remaining = Process.read_timer(sync(scheduler).due_timer)
      assert remaining > 1_799_000 and remaining <= 1_800_000

      :ok = Scheduler.tick(scheduler, now: boot)
      refute_receive {:worker_started, _id, _pid}, 100
      assert reminder(ctx, live.id).status == "pending"

      after_tick = Process.read_timer(sync(scheduler).due_timer)
      assert after_tick > 1_799_000 and after_tick <= 1_800_000
    end

    test "no claimable row at all arms no timer instead of spinning", ctx do
      stale_due = ~U[2026-09-20 17:00:00Z]
      {_event, [stale]} = create!(ctx, reminder_spec("Stale reminder", stale_due))

      boot = DateTime.add(stale_due, 3 * 86_400, :second)
      set_now(ctx, boot)
      scheduler = start_scheduler(ctx, timer_enabled: true)

      assert reminder(ctx, stale.id).status == "pending"
      assert is_nil(sync(scheduler).due_timer)

      :ok = Scheduler.tick(scheduler, now: boot)
      assert is_nil(sync(scheduler).due_timer)
    end
  end

  describe "supervision" do
    # §18.4: the scheduler-before-supervisor order and the worker's `:temporary`
    # restart are what replace lease tokens — nothing else stops a worker from
    # outliving the scheduler while holding a durable claim.
    test "a delivery worker is :temporary, so no restart happens outside a claim", _ctx do
      spec =
        DeliveryWorker.child_spec(%{
          reminder: %{id: "rem_spec"},
          repo: :unused,
          now_fn: &DateTime.utc_now/0,
          delivery_opts: []
        })

      assert spec.restart == :temporary
    end

    test "the scheduler starts before its delivery supervisor in the application tree", _ctx do
      order =
        FermixCore.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

      # `which_children/1` reports one fixed order per OTP release, but whether
      # that order is start order or its reverse is an implementation detail.
      # `Repo` provably starts before `MainAgent` in the same list, so it
      # calibrates the direction for the assertion that matters.
      forward? = child_index(order, Repo) < child_index(order, MainAgent)

      assert child_index(order, Scheduler) < child_index(order, DeliverySupervisor) == forward?
    end
  end

  describe "boot sweep" do
    test "resets stranded delivering rows exactly once by attempt and validity", ctx do
      sweep_at = ~U[2026-09-20 17:00:00Z]

      {_event, [fresh]} = create!(ctx, reminder_spec("Fresh claim", sweep_at))

      exhausted_at = DateTime.add(sweep_at, -3_600, :second)
      {_event, [exhausted]} = create!(ctx, reminder_spec("Exhausted claim", exhausted_at))

      expired_at = DateTime.add(sweep_at, -3 * 3_600, :second)
      {_event, [expired]} = create!(ctx, reminder_spec("Stale claim", expired_at))

      # The earliest ready_at wins every claim, so the exhausted row consumes
      # four recovered attempts before the fifth claim strands it.
      Enum.each(1..4, fn _index ->
        {:ok, [claimed]} = Repo.claim_due_reminders(sweep_at, 1, server: ctx.repo)
        assert claimed.id == exhausted.id

        {:ok, {:pending, _row}} =
          Repo.recover_delivering_reminder(exhausted.id, exhausted_at, nil, sweep_at,
            server: ctx.repo
          )
      end)

      {:ok, [fifth]} = Repo.claim_due_reminders(sweep_at, 1, server: ctx.repo)
      assert fifth.attempt_count == 5

      {:ok, [claimed_fresh]} = Repo.claim_due_reminders(sweep_at, 1, server: ctx.repo)
      assert claimed_fresh.id == fresh.id

      claim_stale_at = DateTime.add(expired_at, 3_600, :second)
      {:ok, [claimed_stale]} = Repo.claim_due_reminders(claim_stale_at, 1, server: ctx.repo)
      assert claimed_stale.id == expired.id

      assert length(reminders(ctx, %{status: ["delivering"]})) == 3

      set_now(ctx, sweep_at)
      scheduler = start_scheduler(ctx, [])
      sync(scheduler)

      assert reminders(ctx, %{status: ["delivering"]}) == []
      assert reminder(ctx, fresh.id).status == "pending"
      assert reminder(ctx, fresh.id).attempt_count == 1
      assert DateTime.compare(reminder(ctx, fresh.id).ready_at, fresh.scheduled_for) == :eq
      assert reminder(ctx, exhausted.id).status == "failed"
      assert reminder(ctx, exhausted.id).attempt_count == 5
      assert reminder(ctx, expired.id).status == "expired"

      # A second scheduler lifetime finds nothing left to sweep.
      _second = start_scheduler(ctx, [])
      assert reminder(ctx, fresh.id).status == "pending"
      assert reminder(ctx, fresh.id).attempt_count == 1
    end
  end

  describe "reconciliation" do
    test "after an outage only the latest still-valid reminder is delivered", ctx do
      {_event, rows} = create!(ctx, birthday_spec())

      week_before =
        Enum.find(
          rows,
          &(&1.reminder_rule_id == "week_before" and &1.occurrence_key == "2026-09-14")
        )

      day_of =
        Enum.find(rows, &(&1.reminder_rule_id == "day_of" and &1.occurrence_key == "2026-09-14"))

      outage_end = day_of.scheduled_for
      set_now(ctx, outage_end)
      scheduler = start_scheduler(ctx, [])

      :ok = Scheduler.reconcile(scheduler, now: outage_end)
      :ok = Scheduler.tick(scheduler, now: outage_end)

      assert reminder(ctx, week_before.id).status == "superseded"
      assert reminder(ctx, day_of.id).status == "delivering"
      assert_receive {:worker_started, id, _pid}, 1_000
      assert id == day_of.id
      refute_receive {:worker_started, _other, _pid}, 100
    end

    test "a delivering row with no monitored worker is reset and traced loudly", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      {:ok, [_claimed]} = Repo.claim_due_reminders(due, 1, server: ctx.repo)

      set_now(ctx, due)
      scheduler = start_scheduler(ctx, [])
      # The boot sweep already owns restart recovery, so re-strand the row to
      # reproduce the mid-lifetime invariant break.
      {:ok, [_reclaimed]} = Repo.claim_due_reminders(due, 1, server: ctx.repo)

      log = capture_log(fn -> :ok = Scheduler.reconcile(scheduler, now: due) end)

      assert log =~ "scheduler_error"
      assert reminder(ctx, row.id).status == "pending"
    end

    test "a delivering row owned by a live worker is left alone", ctx do
      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(ctx, reminder_spec("Submit the report", due))
      scheduler = start_scheduler(ctx, [])

      set_now(ctx, due)
      :ok = Scheduler.tick(scheduler, now: due)
      assert_receive {:worker_started, _id, _pid}, 1_000

      :ok = Scheduler.reconcile(scheduler, now: due)

      assert reminder(ctx, row.id).status == "delivering"
    end

    test "the annual horizon rolls forward on one stable event row", ctx do
      {event, _rows} = create!(ctx, birthday_spec())
      assert event.materialized_through_on == ~D[2027-09-14]

      after_occurrence = ~U[2026-09-15 12:00:00Z]
      set_now(ctx, after_occurrence)
      scheduler = start_scheduler(ctx, [])

      :ok = Scheduler.reconcile(scheduler, now: after_occurrence)

      {:ok, rolled} = Repo.get_temporal_event(event.id, server: ctx.repo)
      assert rolled.materialized_through_on == ~D[2028-09-14]
      assert {:ok, %{events: [_one]}} = Repo.list_temporal_events(%{}, server: ctx.repo)

      keys =
        ctx |> reminders(%{event_id: event.id}) |> Enum.map(& &1.occurrence_key) |> Enum.uniq()

      assert "2028-09-14" in keys
    end
  end

  describe "faults" do
    test "a failing database keeps the scheduler alive and re-arms at the floor", ctx do
      faulting = :"temporal_faulting_repo_#{ctx.unique}"
      start_supervised!(%{id: faulting, start: {FaultingRepo, :start_link, [[name: faulting]]}})

      log =
        capture_log(fn ->
          scheduler = start_scheduler(ctx, repo: faulting, timer_enabled: true)
          :ok = Scheduler.tick(scheduler, now: @created_at)
          :ok = Scheduler.reconcile(scheduler, now: @created_at)

          remaining = Process.read_timer(sync(scheduler).due_timer)
          assert remaining > 4_000 and remaining <= 5_000
        end)

      assert log =~ "boot sweep failed"
      assert log =~ "due scan failed"
    end
  end

  describe "application tree" do
    test "the app-tree scheduler is dark under mix test", _ctx do
      state = :sys.get_state(Scheduler)

      refute state.enabled?
      assert is_nil(state.due_timer)
      assert is_nil(state.reconciliation_timer)
      assert state.monitors == %{}
    end
  end

  describe "no reasoning rail" do
    test "the delivery rail never references a provider, agent loop, or tool module", _ctx do
      forbidden = [
        "Elixir.FermixCore.Providers",
        "Elixir.FermixCore.Agents",
        "Elixir.FermixCore.Tools"
      ]

      for module <- [Scheduler, DeliverySupervisor, DeliveryWorker, Delivery, Renderer] do
        {:ok, {^module, [imports: imports]}} =
          module |> :code.which() |> :beam_lib.chunks([:imports])

        referenced =
          imports |> Enum.map(fn {mod, _fun, _arity} -> Atom.to_string(mod) end) |> Enum.uniq()

        for prefix <- forbidden do
          refute Enum.any?(referenced, &String.starts_with?(&1, prefix)),
                 "#{inspect(module)} references #{prefix}"
        end
      end
    end
  end
end
