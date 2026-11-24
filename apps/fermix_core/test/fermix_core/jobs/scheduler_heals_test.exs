defmodule FermixCore.Jobs.SchedulerHealsTest do
  # M106 §5.4: the Scheduler starts the heal runs, one at a time, after its due
  # scan on every pass and when a run ends; a heal run that died is claimed
  # again once its lease runs out; and its reconcile pass closes a heal that
  # has waited seven days. Every time is given to the Scheduler.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Failure
  alias FermixCore.Jobs.HealRun
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @created ~U[2026-11-20 06:00:00.000000Z]
  @failed_at ~U[2026-11-20 07:10:00.000000Z]
  @now ~U[2026-11-20 07:30:00.000000Z]
  @lease_s 300

  # A heal run that labels itself as the real one does, reports, and waits for
  # the test to end it.
  defmodule HeldHealRun do
    @moduledoc false

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :heal).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      heal = Keyword.fetch!(opts, :heal)
      notify = Keyword.fetch!(opts, :notify)
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = HealRun.put_heal_id(heal.id)
          send(parent, {:labelled, self()})
          send(notify, {:heal_run, :started, heal.id, self()})

          receive do
            :finish -> :ok
          end
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      end
    end
  end

  # A runner that started a tool and died before it settled, so the
  # Scheduler's crash settle takes its run and no retry does.
  defmodule CrashAfterToolRunner do
    @moduledoc false

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
      repo = Keyword.fetch!(opts, :repo)

      pid =
        spawn_link(fn ->
          :ok = Repo.mark_job_run_tools_started(run.id, DateTime.utc_now(), server: repo)
          exit(:scheduled_runner_crashed)
        end)

      {:ok, pid}
    end
  end

  # A runner that publishes its run id as the real one does, reports, and
  # parks: a run that holds its slot until the test ends.
  defmodule ParkedRunner do
    @moduledoc false

    alias FermixCore.Jobs.Runner

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
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Runner.put_run_id(run.id)
          send(parent, {:labelled, self()})
          send(notify, {:job_runner, :started, run.id, run.job_id})

          receive do
            :never_sent -> :ok
          end
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      end
    end
  end

  defmodule ScriptedChannel do
    @moduledoc false

    def send_message(destination, text, _opts) do
      destination |> String.to_existing_atom() |> Agent.update(&[text | &1])
    end
  end

  # The model a real heal run's diagnosis (stage S3) is given here: it gives no
  # decision, so the message goes from Fermix's facts alone. No network.
  defmodule NoDecisionModel do
    @moduledoc false

    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts) do
      {:ok,
       %{
         content: "",
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "mock",
         provider_state: %{}
       }}
    end

    @impl true
    def continue(_state, _tool_results, opts), do: chat([], [], opts)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-scheduler-heals")
    repo = :"scheduler_heals_repo_#{unique}"
    runner_supervisor = :"scheduler_heals_runners_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({RunnerSupervisor, name: runner_supervisor})
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    %{repo: repo, runner_supervisor: runner_supervisor}
  end

  test "one heal run at a time: the second heal waits for the first run to end", ctx do
    first = open_heal!(ctx, @failed_at)
    second = open_heal!(ctx, DateTime.add(@failed_at, 60, :second))
    # The first heal's lease holds at every pass here.
    scheduler = start_scheduler(ctx, clock: fn -> @now end)

    assert :ok = Scheduler.tick(scheduler, now: @now)
    assert_receive {:heal_run, :started, ^first, first_pid}

    assert :ok = Scheduler.tick(scheduler, now: @now)
    refute_received {:heal_run, :started, _heal, _pid}
    assert {:ok, %{state: "open"}} = get_heal(ctx, second)

    send(first_pid, :finish)
    assert_receive {:heal_run, :started, ^second, _second_pid}
  end

  test "a heal run that died is claimed again once its lease runs out", ctx do
    heal = open_heal!(ctx, @failed_at)
    scheduler = start_scheduler(ctx, clock: fn -> @now end)

    assert :ok = Scheduler.tick(scheduler, now: @now)
    assert_receive {:heal_run, :started, ^heal, pid}
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # The pass the death set off found the lease still held.
    assert :ok = Scheduler.tick(scheduler, now: DateTime.add(@now, @lease_s - 1, :second))
    refute_received {:heal_run, :started, _heal, _pid}

    assert :ok = Scheduler.tick(scheduler, now: DateTime.add(@now, @lease_s, :second))
    assert_receive {:heal_run, :started, ^heal, _pid}
  end

  test "a run the Scheduler settles after its runner died opens a heal told by its kind", ctx do
    {:ok, job} = create_job(ctx)
    scheduler = start_scheduler(ctx, runner_module: CrashAfterToolRunner)

    {heal_id, _log} =
      with_log(fn ->
        assert {:ok, _run} = Scheduler.run_now(scheduler, job.id, now: @now)
        assert_receive {:heal_run, :started, heal_id, _pid}
        heal_id
      end)

    assert {:ok, %{subject_kind: "job", failure_kind: "crashed", failure_text: text}} =
             get_heal(ctx, heal_id)

    assert text == Failure.sentence(:crashed)
  end

  test "a heal open before the engine restarted is still sent", ctx do
    heal = open_heal!(ctx, @failed_at)
    channel = :"scheduler_heals_channel_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: channel,
      start: {Agent, :start_link, [fn -> [] end, [name: channel]]}
    })

    store = start_store!(ctx)
    caps = :"scheduler_heals_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: caps})

    scheduler =
      start_scheduler(ctx,
        heal_run_module: HealRun,
        adapter: NoDecisionModel,
        capability_registry: caps,
        delivery_adapter: ScriptedChannel,
        conversation_store: store,
        heal_inbox_opts: [
          jobs_config: [],
          configured_owners: %{"telegram" => Atom.to_string(channel)}
        ]
      )

    TelemetryCapture.attach([[:fermix, :job, :heal]], heal_id: heal)
    assert :ok = Scheduler.tick(scheduler, now: @now)

    assert_receive {:telemetry, [:fermix, :job, :heal], _measurements, %{phase: "delivered"}},
                   10_000

    assert {:ok, %{state: "waiting", delivery_status: "delivered"}} = get_heal(ctx, heal)
    assert [_text] = Agent.get(channel, & &1)
  end

  # A heal run is no run: it takes none of the run slots the ceiling counts,
  # and its own bound is one at a time.
  test "a heal run alone never makes a due job wait at the ceiling", ctx do
    heal = open_heal!(ctx, @failed_at)

    scheduler =
      start_scheduler(ctx, runner_module: ParkedRunner, max_active_runs: 1, clock: fn -> @now end)

    assert :ok = Scheduler.tick(scheduler, now: @now)
    assert_receive {:heal_run, :started, ^heal, _pid}

    {:ok, due} = create_job(ctx)
    due_id = due.id
    assert :ok = Scheduler.tick(scheduler, now: @now)
    assert_receive {:job_runner, :started, _run_id, ^due_id}
  end

  test "four runs and one heal run are live together", ctx do
    heal = open_heal!(ctx, @failed_at)
    scheduler = start_scheduler(ctx, runner_module: ParkedRunner, clock: fn -> @now end)

    assert :ok = Scheduler.tick(scheduler, now: @now)
    assert_receive {:heal_run, :started, ^heal, _pid}

    due_ids = for _ <- 1..4, do: elem(create_job(ctx), 1).id
    assert :ok = Scheduler.tick(scheduler, now: @now)

    started =
      for _ <- due_ids do
        assert_receive {:job_runner, :started, _run_id, job_id}
        job_id
      end

    assert Enum.sort(started) == Enum.sort(due_ids)
    assert DynamicSupervisor.count_children(ctx.runner_supervisor).active == 5
  end

  test "the reconcile pass closes a heal that has waited seven days, and only that one", ctx do
    old = open_heal!(ctx, @failed_at)
    recent = open_heal!(ctx, DateTime.add(@failed_at, 60, :second))

    for {id, at} <- [{old, @now}, {recent, DateTime.add(@now, 86_400, :second)}] do
      {:ok, %{id: ^id, lease_token: token}} = claim(ctx, at)
      :ok = Repo.job_heals_call({:delivered, id, token, at}, server: ctx.repo)
    end

    # init reconciles synchronously inside start_supervised!.
    _scheduler = start_scheduler(ctx, clock: fn -> DateTime.add(@now, 7 * 86_400, :second) end)

    assert {:ok, %{state: "closed", outcome: "expired"}} = get_heal(ctx, old)
    assert {:ok, %{state: "waiting"}} = get_heal(ctx, recent)
  end

  defp start_scheduler(ctx, opts) do
    name = :"scheduler_heals_#{System.unique_integer([:positive])}"

    child =
      {Scheduler,
       [
         name: name,
         repo: ctx.repo,
         runner_supervisor: ctx.runner_supervisor,
         scheduler_enabled: true,
         timer_enabled: false,
         runner_module: Keyword.get(opts, :runner_module, CrashAfterToolRunner),
         heal_run_module: Keyword.get(opts, :heal_run_module, HeldHealRun),
         runner_notify: self(),
         cues_running?: fn -> false end
       ] ++
         Keyword.take(opts, [
           :clock,
           :adapter,
           :capability_registry,
           :delivery_adapter,
           :conversation_store,
           :heal_inbox_opts,
           :max_active_runs
         ])}

    start_supervised!(child, id: name)
    name
  end

  defp start_store!(ctx) do
    tasks = :"scheduler_heals_tasks_#{System.unique_integer([:positive])}"
    store = :"scheduler_heals_store_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: tasks})

    start_supervised!(
      {ConversationStore, name: store, repo: ctx.repo, durable_task_supervisor: tasks}
    )

    store
  end

  defp create_job(ctx) do
    Registry.create_job(
      %{
        name: "Harbour tide table #{System.unique_integer([:positive])}",
        schedule: "every 1 hour",
        timezone: "UTC",
        task_prompt: "Fetch this morning's tides.",
        created_by_trust: "operator"
      },
      repo: ctx.repo,
      now: @created,
      scheduler: nil
    )
  end

  # A job of the owner's whose run failed at `failed_at`, its heal open.
  defp open_heal!(ctx, failed_at) do
    {:ok, job} = create_job(ctx)

    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_1",
      trigger: "manual",
      status: "queued",
      claimed_at: failed_at,
      delivery_status: "none",
      created_at: failed_at,
      updated_at: failed_at
    }

    # Its next run a day on, so no due scan here runs the job again.
    patch = %{
      state: "running",
      next_run_at: DateTime.add(failed_at, 86_400, :second),
      updated_at: failed_at
    }

    {:ok, {_job, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: ctx.repo)

    attrs =
      Map.merge(run, %{
        status: "timeout",
        error: "wall-clock timeout after 600000ms",
        failure_kind: "time_limit",
        completed_at: failed_at,
        updated_at: failed_at,
        heal_facts: %{failure_text: "wall-clock timeout after 600000ms", provider: nil}
      })

    {:ok, {_run, _job, %{heal: {:opened, id}}}} =
      Repo.settle_job_run(attrs, {:failed, :other}, server: ctx.repo)

    id
  end

  defp claim(ctx, now),
    do: Repo.job_heals_call({:claim, now, DateTime.add(now, @lease_s, :second)}, server: ctx.repo)

  defp get_heal(ctx, id), do: Repo.job_heals_call({:get, id}, server: ctx.repo)
end
