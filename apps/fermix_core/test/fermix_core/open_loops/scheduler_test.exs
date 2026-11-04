defmodule FermixCore.OpenLoops.SchedulerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.CheckInSupervisor
  alias FermixCore.OpenLoops.Scheduler
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @tz "America/New_York"
  # Every value here is invented. June 2031 is EDT (UTC-4); with no owner
  # messages the active hours are the default 09:00-21:00 local, 13:00Z-01:00Z.
  @said_at ~U[2031-06-02 14:00:00Z]
  @due_at ~U[2031-06-07 13:00:00Z]
  # Past the 3-hour rung 1 window (16:00Z), inside active hours.
  @now ~U[2031-06-07 17:00:00Z]

  @skipped [:fermix, :open_loop, :skipped]
  @settled [:fermix, :open_loop, :settled]
  @error [:fermix, :open_loop, :checkin, :error]
  @fault [:fermix, :open_loop, :fault]

  # A check-in that parks: it holds its slot and its claim, so capacity, racing
  # ticks and the one-run-per-owner rule can be observed.
  defmodule ParkedCheckIn do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.loop.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(args) do
      pid =
        spawn_link(fn ->
          send(args.notify, {:checkin_started, args.loop.id, self(), args})

          receive do
            :never_sent -> :ok
          end
        end)

      {:ok, pid}
    end
  end

  # A check-in that dies without settling its claimed loop.
  defmodule CrashingCheckIn do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.loop.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(args) do
      pid =
        spawn_link(fn ->
          send(args.notify, {:checkin_started, args.loop.id, self(), args})
          exit(:open_loop_checkin_crashed)
        end)

      {:ok, pid}
    end
  end

  # A start the supervisor refuses after the claim already landed: the race a
  # capacity precheck cannot close.
  defmodule RefusedCheckIn do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.loop.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(_args), do: {:error, :max_children}
  end

  # A start that fails for a reason other than capacity.
  defmodule FailingCheckIn do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.loop.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(_args), do: {:error, :checkin_start_refused}
  end

  # A repo server that faults on every operation.
  defmodule FaultingRepo do
    @moduledoc false

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :db_down}, state}
  end

  # A repo server in front of the test's real one that faults only the requests
  # named in `faults`, each with this test's own reason, and forwards the rest.
  # The reason is unique to the test, so its derived `error_class` pins the
  # fault events of a scheduler that names no loop.
  defmodule SelectiveFaultingRepo do
    @moduledoc false

    use GenServer

    alias FermixCore.Timeouts

    def start_link(opts) do
      {name, opts} = Keyword.pop!(opts, :name)
      GenServer.start_link(__MODULE__, Map.new(opts), name: name)
    end

    @impl true
    def init(%{real: real, faults: [_ | _] = faults, reason: reason}) when is_atom(reason) do
      {:ok, %{real: real, faults: faults, reason: reason}}
    end

    @impl true
    def handle_call(request, _from, state) do
      if request_name(request) in state.faults do
        {:reply, {:error, state.reason}, state}
      else
        {:reply, GenServer.call(state.real, request, Timeouts.repo_call()), state}
      end
    end

    defp request_name(request) when is_tuple(request), do: elem(request, 0)
    defp request_name(request) when is_atom(request), do: request
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("open-loops-scheduler")
    repo = :"open_loops_sched_repo_#{unique}"
    supervisor = :"open_loops_sched_sup_#{unique}"
    clock = :"open_loops_sched_clock_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({CheckInSupervisor, name: supervisor})

    start_supervised!(%{
      id: {:clock, clock},
      start: {Agent, :start_link, [fn -> @now end, [name: clock]]},
      restart: :temporary
    })

    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{repo: repo, supervisor: supervisor, clock: clock, unique: unique}
  end

  defp set_now(ctx, %DateTime{} = now), do: Agent.update(ctx.clock, fn _old -> now end)

  defp start_scheduler(ctx, opts \\ []) do
    name = :"open_loops_scheduler_#{ctx.unique}_#{System.unique_integer([:positive])}"
    clock = ctx.clock

    start_supervised!(
      {Scheduler,
       Keyword.merge(
         [
           name: name,
           repo: ctx.repo,
           checkin_supervisor: ctx.supervisor,
           checkin_module: ParkedCheckIn,
           checkin_args: %{delivery_opts: [], notify: self()},
           now_fn: fn -> Agent.get(clock, & &1) end,
           timer_enabled: false
         ],
         opts
       )},
      id: name
    )

    name
  end

  # `:sys.get_state/1` is a round trip through the scheduler's own mailbox.
  defp sync(scheduler), do: :sys.get_state(scheduler)

  defp loop_id do
    "loop_" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  # A medium loop: the 10th, slots the 7th, 9th and 11th at 09:00 EDT.
  defp create!(ctx, overrides \\ %{}) do
    id = loop_id()

    attrs =
      Map.merge(
        %{
          id: id,
          agent_id: "main",
          owner_id: "owner_#{ctx.unique}",
          dedupe_key: "send the harbourview grant report #{id}",
          intention: "Send the Harbourview grant report",
          noted_after_outside_content: false,
          why_it_matters: nil,
          matters_by_kind: "date",
          matters_by_date: ~D[2031-06-10],
          matters_by_time: nil,
          matters_by_at: ~U[2031-06-11 04:00:00Z],
          timezone: @tz,
          horizon_class: "medium",
          said_at: @said_at,
          source_channel: "telegram",
          source_chat_id: "40001",
          source_thread_scope: "root",
          next_touch_at: @due_at,
          delivery_platform: "telegram",
          delivery_destination: "40001",
          delivery_thread_scope: "root",
          created_at: @said_at
        },
        overrides
      )

    {:ok, {:created, row}} = Repo.create_open_loop(attrs, server: ctx.repo)
    row
  end

  # Something waited on, asked about from `anchor`.
  defp waited_on(%DateTime{} = anchor) do
    %{
      anchor_kind: "ask_after",
      matters_by_source: nil,
      horizon_class: "after",
      matters_by_kind: "datetime",
      matters_by_date: DateTime.to_date(anchor),
      matters_by_time: ~T[17:00:00],
      matters_by_at: anchor,
      next_touch_at: anchor
    }
  end

  defp due!(ctx, overrides \\ %{}) do
    row = create!(ctx, overrides)
    {:ok, _scan} = Repo.scan_due_open_loops(row.next_touch_at, 50, server: ctx.repo)
    row
  end

  # A due loop whose check-in claimed it and spent the owner's day at `at`.
  defp spent!(ctx, %DateTime{} = at) do
    row = due!(ctx)
    {:ok, claimed} = Repo.claim_open_loop_checkin(row.id, at, server: ctx.repo)
    since = ActiveHours.day_start(at, @tz)

    {:ok, spent} =
      Repo.spend_open_loop_budget(row.id, claimed.claimed_at, since, at, server: ctx.repo)

    spent
  end

  defp stored(ctx, id) do
    {:ok, row} = Repo.get_open_loop(id, server: ctx.repo)
    row
  end

  defp park_slot(ctx) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(ctx.supervisor, %{
        id: {:parked, System.unique_integer([:positive])},
        start: {Agent, :start_link, [fn -> :parked end]},
        restart: :temporary
      })
  end

  defp capture(row, events \\ [@skipped, @settled, @error]) do
    TelemetryCapture.attach(events, open_loop_id: row.id)
  end

  # Starts a repo that faults `faults` with this test's own reason; returns the
  # repo's name and the error class every fault it causes carries.
  defp selective_faults(ctx, faults) do
    name = :"open_loops_selective_repo_#{ctx.unique}"
    reason = :"open_loops_fault_#{ctx.unique}"

    start_supervised!(
      {SelectiveFaultingRepo, name: name, real: ctx.repo, faults: faults, reason: reason}
    )

    {name, Atom.to_string(reason)}
  end

  describe "the boot sweep" do
    test "returns a claim no run survived", ctx do
      row = due!(ctx)

      {:ok, %{claimed_at: %DateTime{}}} =
        Repo.claim_open_loop_checkin(row.id, @now, server: ctx.repo)

      {_scheduler, log} = with_log(fn -> start_scheduler(ctx) end)

      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
      assert log =~ "returned 1 stranded check-in claims"
    end
  end

  describe "due ticks" do
    test "a due loop past its window is claimed once across two racing ticks", ctx do
      row = due!(ctx)
      scheduler = start_scheduler(ctx)

      :ok = Scheduler.tick(scheduler, now: @now)
      :ok = Scheduler.tick(scheduler, now: @now)

      id = row.id
      assert_receive {:checkin_started, ^id, _pid, args}
      assert args.touch == 1 and args.rung == 2
      assert DateTime.compare(args.claimed_at, @now) == :eq
      assert args.active_hours.source == :default

      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      assert %{state: "due", claimed_at: %DateTime{}} = stored(ctx, row.id)
      assert map_size(sync(scheduler).runs) == 1
    end

    test "a loop inside its rung 1 window starts nothing and traces nothing", ctx do
      row = due!(ctx)
      capture(row)
      scheduler = start_scheduler(ctx)

      inside = ~U[2031-06-07 15:00:00Z]
      set_now(ctx, inside)
      :ok = Scheduler.tick(scheduler, now: inside)

      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      refute_received {:telemetry, @skipped, _measurements, _metadata}
      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
    end

    test "an imminent loop never starts a run", ctx do
      row =
        due!(ctx, %{
          horizon_class: "imminent",
          matters_by_date: ~D[2031-06-08],
          matters_by_at: ~U[2031-06-09 04:00:00Z],
          said_at: @due_at,
          next_touch_at: @due_at
        })

      capture(row)
      scheduler = start_scheduler(ctx)
      :ok = Scheduler.tick(scheduler, now: @now)

      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      refute_received {:telemetry, @skipped, _measurements, _metadata}
      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
    end

    test "a spent day's budget is a traced budget skip, once", ctx do
      # Another loop's check-in spent the day at 10:00 EDT, then its send failed:
      # no touch is recorded, and the budget is still spent.
      failed = spent!(ctx, ~U[2031-06-07 14:00:00Z])

      {:ok, _row} =
        Repo.finalize_open_loop_checkin(
          failed.id,
          failed.claimed_at,
          %{
            state: "open",
            next_touch_at: ~U[2031-06-08 13:00:00Z],
            last_outcome: "delivery_failed",
            last_outcome_at: ~U[2031-06-07 14:00:00Z]
          },
          server: ctx.repo
        )

      row = due!(ctx)
      capture(row)
      scheduler = start_scheduler(ctx)

      :ok = Scheduler.tick(scheduler, now: @now)
      :ok = Scheduler.reconcile(scheduler, now: @now)

      id = row.id
      assert_receive {:telemetry, @skipped, _measurements, %{reason: "budget", open_loop_id: ^id}}
      sync(scheduler)
      refute_received {:telemetry, @skipped, _measurements, _metadata}
      refute_received {:checkin_started, _id, _pid, _args}
      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
    end

    test "a rung 1 raise after the day's rung 2 still blocks a second rung 2", ctx do
      # 10:00 EDT: one loop's check-in spends the day and is sent; 12:30 EDT:
      # the owner chats inside that loop's rung 1 window and the main agent
      # raises it, which rewrites its touch columns.
      spoken = spent!(ctx, ~U[2031-06-07 14:00:00Z])

      {:ok, _row} =
        Repo.finalize_open_loop_checkin(
          spoken.id,
          spoken.claimed_at,
          %{
            state: "asked",
            touches: 1,
            next_touch_at: ~U[2031-06-07 16:00:00Z],
            last_touch_at: ~U[2031-06-07 14:00:00Z],
            last_touch_rung: 2,
            last_outcome: "spoke",
            last_outcome_at: ~U[2031-06-07 14:00:00Z],
            last_message: "An invented check-in.",
            last_message_after_outside_content: false
          },
          server: ctx.repo
        )

      {:ok, _row} =
        Repo.settle_open_loop(
          spoken.id,
          %{
            touches: 2,
            next_touch_at: ~U[2031-06-09 13:00:00Z],
            last_touch_at: ~U[2031-06-07 16:30:00Z],
            last_touch_rung: 1
          },
          server: ctx.repo
        )

      row = due!(ctx)
      capture(row)
      scheduler = start_scheduler(ctx)

      :ok = Scheduler.tick(scheduler, now: @now)

      id = row.id
      assert_receive {:telemetry, @skipped, _measurements, %{reason: "budget", open_loop_id: ^id}}
      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
    end

    test "outside active hours is a traced skip and waits for the next start", ctx do
      row = due!(ctx)
      capture(row)
      # 22:00 EDT on the 7th: after the default 21:00 finish.
      night = ~U[2031-06-08 02:00:00Z]
      set_now(ctx, night)
      scheduler = start_scheduler(ctx, timer_enabled: true)

      :ok = Scheduler.tick(scheduler, now: night)

      id = row.id

      assert_receive {:telemetry, @skipped, _measurements,
                      %{reason: "active_hours", open_loop_id: ^id}}

      refute_received {:checkin_started, _id, _pid, _args}
      # 09:00 EDT on the 8th, eleven hours on.
      assert sync(scheduler).due_delay_ms == 11 * 3_600_000
    end

    test "a full supervisor is a traced max_children skip, claims nothing, retries at the floor",
         ctx do
      row = due!(ctx)
      capture(row)
      park_slot(ctx)
      park_slot(ctx)
      scheduler = start_scheduler(ctx, timer_enabled: true)

      :ok = Scheduler.tick(scheduler, now: @now)

      id = row.id

      assert_receive {:telemetry, @skipped, _measurements,
                      %{reason: "max_children", open_loop_id: ^id}}

      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
      assert sync(scheduler).due_delay_ms == 5_000
    end

    test "a start refused after the claim landed releases the claim", ctx do
      row = due!(ctx)
      capture(row)
      scheduler = start_scheduler(ctx, checkin_module: RefusedCheckIn)

      :ok = Scheduler.tick(scheduler, now: @now)

      id = row.id

      assert_receive {:telemetry, @skipped, _measurements,
                      %{reason: "max_children", open_loop_id: ^id}}

      assert %{state: "due", claimed_at: nil, last_outcome: nil, touches: 0} = stored(ctx, row.id)
    end

    test "the nearest date wins, and one owner never has two runs at once", ctx do
      later =
        due!(ctx, %{matters_by_date: ~D[2031-06-12], matters_by_at: ~U[2031-06-13 04:00:00Z]})

      nearer = due!(ctx)
      scheduler = start_scheduler(ctx)

      :ok = Scheduler.tick(scheduler, now: @now)

      id = nearer.id
      assert_receive {:checkin_started, ^id, _pid, _args}
      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      assert %{claimed_at: nil} = stored(ctx, later.id)
    end

    test "a loop kept for conversation never starts a run and traces no skip", ctx do
      row = due!(ctx, %{reach: "conversation"})
      capture(row)
      scheduler = start_scheduler(ctx)
      :ok = Scheduler.tick(scheduler, now: @now)

      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      refute_received {:telemetry, @skipped, _measurements, _metadata}
      assert %{state: "due", claimed_at: nil, reach: "conversation"} = stored(ctx, row.id)
    end

    # A deadline loses its value after its date; "how did it go" keeps a day.
    test "a dated loop takes the day's message before a loop waited on", ctx do
      waited = due!(ctx, waited_on(~U[2031-06-06 21:00:00Z]))
      dated = due!(ctx)
      scheduler = start_scheduler(ctx)
      :ok = Scheduler.tick(scheduler, now: @now)

      id = dated.id
      assert_receive {:checkin_started, ^id, _pid, %{touch: 1, rung: 2}}
      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      assert %{state: "due", claimed_at: nil} = stored(ctx, waited.id)
    end

    test "among loops waited on, the oldest anchor goes first", ctx do
      newer = due!(ctx, waited_on(~U[2031-06-06 21:00:00Z]))
      older = due!(ctx, waited_on(~U[2031-06-05 21:00:00Z]))
      scheduler = start_scheduler(ctx)
      :ok = Scheduler.tick(scheduler, now: @now)

      id = older.id
      assert_receive {:checkin_started, ^id, _pid, %{touch: 1, rung: 2}}
      sync(scheduler)
      refute_received {:checkin_started, _id, _pid, _args}
      assert %{state: "due", claimed_at: nil} = stored(ctx, newer.id)
    end

    test "a conversation loop's closed window moves on to the next at the tick", ctx do
      row = due!(ctx, %{reach: "conversation"})
      assert DateTime.compare(stored(ctx, row.id).rung1_until, ~U[2031-06-09 13:00:00Z]) == :eq
      scheduler = start_scheduler(ctx)

      next_slot = ~U[2031-06-09 13:00:00Z]
      set_now(ctx, next_slot)
      :ok = Scheduler.tick(scheduler, now: next_slot)

      moved_on = stored(ctx, row.id)
      assert %{state: "due", touches: 0, claimed_at: nil} = moved_on
      assert DateTime.compare(moved_on.next_touch_at, next_slot) == :eq
      assert DateTime.compare(moved_on.rung1_until, ~U[2031-06-11 04:00:00Z]) == :eq
    end

    test "an expiry is traced as settled by the scheduler", ctx do
      row = create!(ctx)
      capture(row)
      scheduler = start_scheduler(ctx)

      # The daemon slept past the date with the loop never asked.
      asleep = ~U[2031-06-11 10:00:00Z]
      set_now(ctx, asleep)
      :ok = Scheduler.tick(scheduler, now: asleep)

      id = row.id

      assert_receive {:telemetry, @settled, _measurements,
                      %{open_loop_id: ^id, from: "open", to: "expired", by: "scheduler"} = meta}

      refute Map.has_key?(meta, :session_id)
      assert %{state: "expired"} = stored(ctx, row.id)
    end
  end

  describe "check-in exits" do
    test "a check-in that dies holding its claim re-arms the loop as an error", ctx do
      row = due!(ctx)
      capture(row)
      scheduler = start_scheduler(ctx, checkin_module: CrashingCheckIn)

      {_result, _log} =
        with_log(fn ->
          :ok = Scheduler.tick(scheduler, now: @now)
          id = row.id
          session_id = "open_loop_#{id}_1"

          assert_receive {:telemetry, @error, _measurements,
                          %{status: "error", session_id: ^session_id}},
                         10_000
        end)

      stored = stored(ctx, row.id)
      assert %{state: "open", claimed_at: nil, last_outcome: "error", touches: 0} = stored
      # The retry waits for the next active-hours start, 09:00 EDT on the 8th.
      assert DateTime.compare(stored.next_touch_at, ~U[2031-06-08 13:00:00Z]) == :eq
      assert sync(scheduler).runs == %{}
    end
  end

  describe "timers" do
    test "loop_changed arms one timer at the next touch", ctx do
      set_now(ctx, ~U[2031-06-07 12:30:00Z])
      scheduler = start_scheduler(ctx, timer_enabled: true)
      assert is_nil(sync(scheduler).due_timer)

      create!(ctx)
      :ok = Scheduler.loop_changed(scheduler)

      state = sync(scheduler)
      assert is_reference(state.due_timer)
      assert state.due_delay_ms == 1_800_000
    end

    test "a due loop's timer is its own window: three hours from when it came due", ctx do
      create!(ctx)
      late = ~U[2031-06-07 14:00:00Z]
      {:ok, %{due: [_]}} = Repo.scan_due_open_loops(late, 50, server: ctx.repo)
      set_now(ctx, late)

      scheduler = start_scheduler(ctx, timer_enabled: true)
      assert sync(scheduler).due_delay_ms == 3 * 3_600_000
    end

    test "a loop kept for conversation wakes when its window closes, not at its date", ctx do
      due!(ctx, %{reach: "conversation"})
      set_now(ctx, ~U[2031-06-08 14:00:00Z])

      scheduler = start_scheduler(ctx, timer_enabled: true)
      assert sync(scheduler).due_delay_ms == 23 * 3_600_000
    end

    test "a touch weeks out arms a bounded recheck, never a weeks-long timer", ctx do
      create!(ctx, %{
        matters_by_date: ~D[2031-07-10],
        matters_by_at: ~U[2031-07-11 04:00:00Z],
        horizon_class: "long",
        next_touch_at: ~U[2031-07-03 13:00:00Z]
      })

      scheduler = start_scheduler(ctx, timer_enabled: true)
      assert sync(scheduler).due_delay_ms == 86_400_000
    end

    test "a faulting repo re-arms at the five-second floor", ctx do
      faulting = :"open_loops_faulting_repo_#{ctx.unique}"
      start_supervised!({FaultingRepo, name: faulting})

      {scheduler, _log} =
        with_log(fn -> start_scheduler(ctx, repo: faulting, timer_enabled: true) end)

      assert sync(scheduler).due_delay_ms == 5_000

      {_result, log} = with_log(fn -> :ok = Scheduler.tick(scheduler, now: @now) end)
      assert log =~ "Open-loop due scan failed"
      assert sync(scheduler).due_delay_ms == 5_000
    end
  end

  # Every fault is logged and traced as one sessionless `fault` event naming its
  # stage, the loop when there is one, and only the reason's derived class.
  describe "fault telemetry" do
    test "a failed boot sweep is a traced sweep fault", ctx do
      {repo, class} = selective_faults(ctx, [:sweep_open_loop_claims])
      TelemetryCapture.attach([@fault], error_class: class)

      {_scheduler, log} = with_log(fn -> start_scheduler(ctx, repo: repo) end)

      assert_receive {:telemetry, @fault, %{count: 1}, meta}
      assert meta == %{stage: "sweep", component: "open_loop_scheduler", error_class: class}
      assert log =~ "Open-loop boot sweep failed"
    end

    test "a failed due scan is a traced scan fault and still retries at the floor", ctx do
      row = due!(ctx)
      {repo, class} = selective_faults(ctx, [:scan_due_open_loops])
      TelemetryCapture.attach([@fault], error_class: class)
      scheduler = start_scheduler(ctx, repo: repo, timer_enabled: true)

      {_result, log} = with_log(fn -> :ok = Scheduler.tick(scheduler, now: @now) end)

      assert_receive {:telemetry, @fault, %{count: 1}, meta}
      assert meta == %{stage: "scan", component: "open_loop_scheduler", error_class: class}
      assert log =~ "Open-loop due scan failed"
      assert sync(scheduler).due_delay_ms == 5_000
      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
    end

    test "a failed timer read is a traced timer fault and arms the floor", ctx do
      {repo, class} = selective_faults(ctx, [:next_open_loop_touch_at])
      TelemetryCapture.attach([@fault], error_class: class)

      {scheduler, log} =
        with_log(fn -> start_scheduler(ctx, repo: repo, timer_enabled: true) end)

      assert_receive {:telemetry, @fault, %{count: 1}, meta}
      assert meta == %{stage: "timer", component: "open_loop_scheduler", error_class: class}
      assert log =~ "Open-loop timer lookup failed"
      assert sync(scheduler).due_delay_ms == 5_000
    end

    test "a failed claim is a traced claim fault naming its loop", ctx do
      row = due!(ctx)
      {repo, class} = selective_faults(ctx, [:claim_open_loop_checkin])
      TelemetryCapture.attach([@fault], open_loop_id: row.id)
      scheduler = start_scheduler(ctx, repo: repo, timer_enabled: true)

      {_result, log} = with_log(fn -> :ok = Scheduler.tick(scheduler, now: @now) end)

      id = row.id
      assert_receive {:telemetry, @fault, %{count: 1}, meta}

      assert meta == %{
               stage: "claim",
               open_loop_id: id,
               component: "open_loop_scheduler",
               error_class: class
             }

      assert log =~ "Open-loop #{id} claim failed"
      # The claim never landed, so its release finds nothing and is no fault.
      sync(scheduler)
      refute_received {:telemetry, @fault, _measurements, _metadata}
      refute_received {:checkin_started, _id, _pid, _args}
      assert sync(scheduler).due_delay_ms == 5_000
    end

    test "a check-in that cannot start is a traced start_checkin fault, its claim released",
         ctx do
      row = due!(ctx)
      TelemetryCapture.attach([@fault], open_loop_id: row.id)
      scheduler = start_scheduler(ctx, checkin_module: FailingCheckIn)

      {_result, log} = with_log(fn -> :ok = Scheduler.tick(scheduler, now: @now) end)

      id = row.id
      assert_receive {:telemetry, @fault, %{count: 1}, meta}

      assert meta == %{
               stage: "start_checkin",
               open_loop_id: id,
               component: "open_loop_scheduler",
               error_class: "checkin_start_refused"
             }

      assert log =~ "Open-loop #{id} check-in failed to start"
      assert %{state: "due", claimed_at: nil} = stored(ctx, row.id)
    end

    test "a claim that cannot be released is a traced release fault", ctx do
      row = due!(ctx)
      {repo, class} = selective_faults(ctx, [:finalize_open_loop_checkin])
      TelemetryCapture.attach([@fault], open_loop_id: row.id)
      scheduler = start_scheduler(ctx, repo: repo, checkin_module: FailingCheckIn)

      {_result, log} = with_log(fn -> :ok = Scheduler.tick(scheduler, now: @now) end)

      id = row.id

      assert_receive {:telemetry, @fault, _measurements,
                      %{stage: "release", open_loop_id: ^id, error_class: ^class}}

      assert_receive {:telemetry, @fault, _measurements,
                      %{stage: "start_checkin", open_loop_id: ^id}}

      assert log =~ "Open-loop #{id} claim release failed"
    end

    test "a dead run whose claim cannot be recovered is a traced release fault", ctx do
      row = due!(ctx)
      {repo, class} = selective_faults(ctx, [:finalize_open_loop_checkin])
      TelemetryCapture.attach([@fault], open_loop_id: row.id)
      scheduler = start_scheduler(ctx, repo: repo, checkin_module: CrashingCheckIn)

      {_result, log} =
        with_log(fn ->
          :ok = Scheduler.tick(scheduler, now: @now)
          id = row.id

          assert_receive {:telemetry, @fault, %{count: 1},
                          %{stage: "release", open_loop_id: ^id, error_class: ^class}},
                         10_000
        end)

      assert log =~ "Open-loop #{row.id} recovery failed"
    end

    test "a failed rung 2 read is a traced scan fault naming its loop and the read", ctx do
      row = due!(ctx)
      {repo, _class} = selective_faults(ctx, [:open_loop_budget_spent_since])
      TelemetryCapture.attach([@fault], open_loop_id: row.id)
      scheduler = start_scheduler(ctx, repo: repo, timer_enabled: true)

      {_result, log} = with_log(fn -> :ok = Scheduler.tick(scheduler, now: @now) end)

      id = row.id
      assert_receive {:telemetry, @fault, %{count: 1}, meta}

      assert meta == %{
               stage: "scan",
               open_loop_id: id,
               component: "open_loop_scheduler",
               error_class: "budget"
             }

      assert log =~ "Open-loop #{id} rung 2 check failed"
      refute_received {:checkin_started, _id, _pid, _args}
      assert sync(scheduler).due_delay_ms == 5_000
    end
  end
end
