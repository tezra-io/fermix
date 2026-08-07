defmodule FermixCore.Jobs.SchedulerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.RunJobNow

  defmodule TerminalAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      case Keyword.get(opts, :sleep_ms, 0) do
        ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
        _ms -> :ok
      end

      {:ok,
       %{
         content:
           Keyword.get(
             opts,
             :response,
             "Fake scheduled job run completed for Frequent Check."
           ),
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "mock"
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defmodule CrashingRunner do
    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :run).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(_opts) do
      pid = spawn_link(fn -> exit(:scheduled_runner_crashed) end)
      {:ok, pid}
    end
  end

  defmodule CrashAfterPendingDeliveryRunner do
    alias FermixCore.Memory.Repo

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :run).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      pid =
        spawn_link(fn ->
          repo = Keyword.fetch!(opts, :repo)
          run = Keyword.fetch!(opts, :run)
          notify = Keyword.fetch!(opts, :notify)
          now = DateTime.utc_now()

          {:ok, _run} =
            Repo.upsert_job_run(
              Map.merge(run, %{
                status: "ok",
                completed_at: now,
                final_response: "Completed before delivery.",
                delivery_status: "pending",
                updated_at: now
              }),
              server: repo
            )

          send(notify, {:job_runner, :pending_delivery, run.id, run.job_id})
          exit(:after_pending_delivery)
        end)

      {:ok, pid}
    end
  end

  defmodule LiveRunner do
    @moduledoc false
    # A runner that is still executing: it publishes its run id the way the real
    # Runner does (in the start call, before the pid reaches the supervisor's
    # caller) and then parks. Used to prove a surviving run is adopted, not
    # reaped, when the scheduler alone restarts.
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
          Process.sleep(:infinity)
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      after
        1_000 -> {:error, :label_timeout}
      end
    end
  end

  defmodule RecordingRepo do
    @moduledoc false
    # A transparent proxy in front of the real Repo GenServer that reports every
    # request to the test process before forwarding it. Lets a test assert on the
    # arguments the scheduler passes (here: the reconciliation scan's bound)
    # without reaching into scheduler internals.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{real: Keyword.fetch!(opts, :real), notify: Keyword.fetch!(opts, :notify)}}
    end

    @impl true
    def handle_call(request, _from, %{real: real, notify: notify} = state) do
      send(notify, {:repo_request, request})
      {:reply, GenServer.call(real, request), state}
    end
  end

  defmodule FaultRepo do
    @moduledoc false
    # A transparent proxy in front of the real Repo GenServer that injects a
    # `{:error, :injected_fault}` reply for exactly one request tag and forwards
    # everything else. Lets a scheduler tick fail on a chosen path (scan, expiry
    # lookup, stale-skip store, claim) with no host-state mutation.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok, %{real: Keyword.fetch!(opts, :real), fail: Keyword.fetch!(opts, :fail)}}
    end

    @impl true
    def handle_call(request, _from, %{fail: fail, real: real} = state) do
      if request_tag(request) == fail do
        {:reply, {:error, :injected_fault}, state}
      else
        {:reply, GenServer.call(real, request), state}
      end
    end

    defp request_tag(request) when is_tuple(request), do: elem(request, 0)
    defp request_tag(request) when is_atom(request), do: request
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-jobs-scheduler-#{unique}.db")
    repo = :"jobs_scheduler_repo_#{unique}"
    runner_supervisor = :"jobs_runner_supervisor_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({RunnerSupervisor, name: runner_supervisor})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, runner_supervisor: runner_supervisor}
  end

  test "tick claims a due recurring job and fake runner completes it", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Frequent Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check project status."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)
    job_id = job.id

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])

    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000
    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000

    assert {:ok, [run]} = Repo.list_job_runs(%{job_id: job.id}, server: repo)
    assert run.id == run_id
    assert run.status == "ok"
    assert run.trigger == "schedule"
    assert run.session_id =~ "cron_#{job.id}_"
    assert run.final_response == "Fake scheduled job run completed for Frequent Check."

    assert {:ok, updated_job} = Registry.get_job(job.id, repo: repo)
    assert updated_job.state == "scheduled"
    assert updated_job.enabled? == true
    assert updated_job.last_status == "ok"
    assert updated_job.next_run_at == ~U[2026-05-02 14:30:00Z]

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.last_status == "ok"
    assert source.status == "enabled"
  end

  test "duplicate ticks while a run is active do not create duplicate runs", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Slow Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check slowly."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 200)
    job_id = job.id

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])

    # `tick` dispatches the run and returns; it never waits for the runner. The
    # invariant is "tick returned while the run was still in flight", and the
    # absence of the completion message proves exactly that — the runner is held
    # for `runner_delay_ms`, so a `tick` that blocked on it could not get here
    # first. This used to assert a wall-clock budget (`duration_ms < 100`), which
    # only PROXIED for that invariant and made a loaded host indistinguishable
    # from a `tick` that blocks.
    refute_received {:job_runner, :completed, _run_id, _job_id}

    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
    assert {:ok, [run]} = Repo.list_job_runs(%{job_id: job.id}, server: repo)
    assert run.id == run_id
    assert run.status == "running"

    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000
  end

  test "runner finalization preserves edits and pauses made during the run", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Editable Check",
                 description: "Original description",
                 schedule: "every 15 minutes",
                 task_prompt: "Check and preserve edits.",
                 allowed_tools: ["memory_recall"]
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 200)
    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
    assert_receive {:job_runner, :started, run_id, job_id}, 1_000
    assert job_id == job.id

    assert {:ok, paused} = Registry.pause_job(job.id, repo: repo)

    assert {:ok, _edited} =
             Repo.upsert_scheduled_job(
               %{paused | description: "Edited while running", allowed_tools: ["github"]},
               server: repo
             )

    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000

    assert {:ok, updated_job} = Registry.get_job(job.id, repo: repo)
    assert updated_job.state == "paused"
    assert updated_job.enabled? == false
    assert updated_job.description == "Edited while running"
    assert updated_job.allowed_tools == ["github"]
    assert updated_job.last_status == "ok"

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.status == "paused"
    assert source.last_status == "ok"
  end

  test "tick expires a job without starting a runner when expires_at has passed", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Temporary Quote",
                 schedule: "every 15 minutes",
                 task_prompt: "Send a temporary quote.",
                 expires_at: ~U[2026-05-02 14:10:00Z]
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert job.next_run_at == ~U[2026-05-02 14:15:00Z]

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:10:00Z])
    refute_receive {:job_runner, :started, _run_id, _job_id}, 100

    assert {:ok, []} = Repo.list_job_runs(%{job_id: job.id}, server: repo)
    assert {:ok, expired_job} = Registry.get_job(job.id, repo: repo)
    assert expired_job.state == "completed"
    assert expired_job.enabled? == false
    assert expired_job.next_run_at == nil
    assert expired_job.last_status == "expired"

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.status == "expired"
    assert source.last_status == "expired"
  end

  test "crashed runner marks the run errored so future ticks are not blocked", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Crashy Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Crash during the fake runner."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler =
      start_scheduler(repo, runner_supervisor,
        runner_module: CrashingRunner,
        runner_delay_ms: 0
      )

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
    assert eventually(fn -> active_run_count(repo, job.id) == 0 end)

    assert {:ok, [first_run]} = Repo.list_job_runs(%{job_id: job.id}, server: repo)
    assert first_run.status == "error"
    assert first_run.error =~ "runner crashed"

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:30:00Z])

    assert eventually(fn ->
             run_count(repo, job.id) == 2 and active_run_count(repo, job.id) == 0
           end)
  end

  test "crashed runner after completion marks pending delivery failed without failing the run", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Pending Delivery Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Complete, then crash before delivery.",
                 delivery_mode: "channel",
                 delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler =
      start_scheduler(repo, runner_supervisor,
        runner_module: CrashAfterPendingDeliveryRunner,
        runner_delay_ms: 0
      )

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
    assert_receive {:job_runner, :pending_delivery, run_id, job_id}, 1_000
    assert job_id == job.id

    assert eventually(fn ->
             {:ok, run} = Repo.get_job_run(run_id, server: repo)
             run.delivery_status == "failed"
           end)

    assert {:ok, run} = Repo.get_job_run(run_id, server: repo)
    assert run.status == "ok"
    assert run.delivery_status == "failed"
    assert run.delivery_error =~ "runner crashed"

    # The reaper writes the run's failed delivery and then the job's reset
    # (running -> scheduled) as two separate Repo writes; the delivery wait
    # above only gates on the first. Wait for the job write too, or this races
    # and reads "running" on a slow runner.
    assert eventually(fn ->
             {:ok, current} = Registry.get_job(job.id, repo: repo)
             current.state == "scheduled"
           end)

    assert {:ok, updated_job} = Registry.get_job(job.id, repo: repo)
    assert updated_job.state == "scheduled"
    assert updated_job.last_status == "ok"
    assert updated_job.last_error == nil
  end

  test "nearest-job timer starts a due job without waiting for reconciliation", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    start_at = DateTime.utc_now()
    run_at = DateTime.add(start_at, 100, :millisecond)

    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Soon Reminder",
                 schedule: DateTime.to_iso8601(run_at),
                 task_prompt: "Run soon."
               },
               repo: repo
             )

    _scheduler =
      start_scheduler(repo, runner_supervisor,
        timer_enabled: true,
        reconciliation_interval_ms: 10_000,
        runner_delay_ms: 1
      )

    assert_receive {:job_runner, :completed, _run_id, job_id}, 1_000
    assert job_id == job.id

    assert {:ok, completed_job} = Registry.get_job(job.id, repo: repo)
    assert completed_job.state == "completed"
    assert completed_job.enabled? == false
    assert completed_job.next_run_at == nil
  end

  test "a stale recurring job is skipped and its schedule advanced without a run", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Stale Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check after a long sleep."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert job.next_run_at == ~U[2026-05-02 14:15:00Z]

    scheduler =
      start_scheduler(repo, runner_supervisor,
        runner_delay_ms: 1,
        run_freshness_window_seconds: 3600
      )

    # The daemon "wakes" two hours late; the 14:15 occurrence is 105 min stale
    # (> the 1h window) so it is skipped, not fired, and the schedule advances.
    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 16:00:00Z])
    refute_receive {:job_runner, :started, _run_id, _job_id}, 100

    assert {:ok, []} = Repo.list_job_runs(%{job_id: job.id}, server: repo)

    assert {:ok, advanced} = Registry.get_job(job.id, repo: repo)
    assert advanced.state == "scheduled"
    assert advanced.enabled? == true
    assert advanced.next_run_at == ~U[2026-05-02 16:15:00Z]
    assert advanced.last_status == job.last_status
  end

  test "a recurring job within the freshness window still runs to catch up", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Recent Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check shortly after the due time."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler =
      start_scheduler(repo, runner_supervisor,
        runner_delay_ms: 1,
        run_freshness_window_seconds: 3600
      )

    job_id = job.id

    # Five minutes late is inside the 1h window, so the missed occurrence runs.
    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:20:00Z])
    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000
    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000
  end

  test "a stale job past its expiry expires rather than being skipped", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Stale Temporary Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check until expiry.",
                 expires_at: ~U[2026-05-02 14:30:00Z]
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler =
      start_scheduler(repo, runner_supervisor,
        runner_delay_ms: 1,
        run_freshness_window_seconds: 3600
      )

    # Stale and past expiry at once: expiry wins over the freshness skip.
    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 18:00:00Z])
    refute_receive {:job_runner, :started, _run_id, _job_id}, 100

    assert {:ok, []} = Repo.list_job_runs(%{job_id: job.id}, server: repo)

    assert {:ok, expired_job} = Registry.get_job(job.id, repo: repo)
    assert expired_job.state == "completed"
    assert expired_job.enabled? == false
    assert expired_job.next_run_at == nil
    assert expired_job.last_status == "expired"
  end

  test "a stale one-off job still runs late rather than being skipped", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Late One-off",
                 schedule: DateTime.to_iso8601(~U[2026-05-02 14:00:00Z]),
                 task_prompt: "Fire even if the daemon was asleep."
               },
               repo: repo,
               now: ~U[2026-05-02 13:00:00Z]
             )

    assert job.schedule_kind == "once"

    scheduler =
      start_scheduler(repo, runner_supervisor,
        runner_delay_ms: 1,
        run_freshness_window_seconds: 3600
      )

    job_id = job.id

    # Three hours past the window — but a one-off has no next occurrence, so it
    # runs late instead of being silently dropped.
    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 17:00:00Z])
    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000
    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000
  end

  test "run_now claims an out-of-band manual run without advancing the schedule", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "On Demand",
                 schedule: "every 15 minutes",
                 task_prompt: "Run when asked."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert job.next_run_at == ~U[2026-05-02 14:15:00Z]

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)
    job_id = job.id

    assert {:ok, run} = Scheduler.run_now(scheduler, job_id, now: ~U[2026-05-02 14:03:00Z])
    assert run.trigger == "manual"

    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000
    assert run_id == run.id
    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000

    assert {:ok, [stored]} = Repo.list_job_runs(%{job_id: job_id}, server: repo)
    assert stored.id == run_id
    assert stored.trigger == "manual"
    assert stored.status == "ok"

    # The timed cadence is undisturbed by a manual run.
    assert {:ok, updated_job} = Registry.get_job(job_id, repo: repo)
    assert updated_job.next_run_at == ~U[2026-05-02 14:15:00Z]
    assert updated_job.state == "scheduled"
  end

  test "run_now rejects a job that already has an active run", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Busy Job",
                 schedule: "every 15 minutes",
                 task_prompt: "Run slowly."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 200)
    job_id = job.id

    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000

    assert {:error, :already_running} = Scheduler.run_now(scheduler, job_id)

    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000
  end

  test "run_now rejects a paused job", %{repo: repo, runner_supervisor: runner_supervisor} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Paused Job",
                 schedule: "every 15 minutes",
                 task_prompt: "Should not run while paused."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    assert {:ok, _paused} = Registry.pause_job(job.id, repo: repo)

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)

    assert {:error, :not_runnable} = Scheduler.run_now(scheduler, job.id)
    refute_receive {:job_runner, :started, _run_id, _job_id}, 100
    assert {:ok, []} = Repo.list_job_runs(%{job_id: job.id}, server: repo)
  end

  test "run_now rejects an expired job", %{repo: repo, runner_supervisor: runner_supervisor} do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Expired Job",
                 schedule: "every 15 minutes",
                 task_prompt: "Should not run past expiry.",
                 expires_at: ~U[2026-05-02 14:30:00Z]
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)

    assert {:error, :expired} =
             Scheduler.run_now(scheduler, job.id, now: ~U[2026-05-02 15:00:00Z])

    refute_receive {:job_runner, :started, _run_id, _job_id}, 100
  end

  test "run_now reports a missing job", %{repo: repo, runner_supervisor: runner_supervisor} do
    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)
    assert {:error, :not_found} = Scheduler.run_now(scheduler, "ghost_job")
  end

  test "run_job_now tool triggers a manual run through the scheduler", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    assert {:ok, job} =
             Registry.create_job(
               %{
                 created_by_trust: "operator",
                 name: "Tool Triggered",
                 schedule: "every 15 minutes",
                 task_prompt: "Run from the tool."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)
    job_id = job.id

    context = %{
      agent_name: "test_agent",
      memory_repo: repo,
      session_id: "telegram:chat-1:root",
      scheduler: scheduler
    }

    assert {:ok, result} = RunJobNow.execute(%{"job_id" => job_id}, context)
    assert result.success == true
    payload = Jason.decode!(result.output)
    assert payload["job_id"] == job_id
    assert payload["trigger"] == "manual"

    assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000
    assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000
  end

  test "run_job_now tool reports a missing job", %{
    repo: repo,
    runner_supervisor: runner_supervisor
  } do
    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)

    context = %{
      agent_name: "test_agent",
      memory_repo: repo,
      session_id: "telegram:chat-1:root",
      scheduler: scheduler
    }

    assert {:ok, result} = RunJobNow.execute(%{"job_id" => "ghost_job"}, context)
    assert result.success == false
    assert result.error =~ "Not found"
  end

  describe "terminal disabled state on unparseable schedules" do
    test "disables a due job whose schedule no longer parses (claim branch)", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      broken = seed_broken_schedule_job(repo, next_run_at: ~U[2026-05-02 14:10:00Z])

      scheduler =
        start_scheduler(repo, runner_supervisor,
          runner_delay_ms: 1,
          run_freshness_window_seconds: 3600
        )

      # Five minutes late: due and inside the freshness window, so it reaches the
      # claim branch (not stale). The claim patch can't parse the schedule.
      assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
      refute_receive {:job_runner, :started, _run_id, _job_id}, 100

      assert {:ok, disabled} = Registry.get_job(broken.id, repo: repo)
      assert disabled.state == "disabled"
      assert disabled.enabled? == false
      assert disabled.last_error =~ "schedule no longer parses"

      # Terminal: the disabled job never appears in the due scan again.
      assert {:ok, due} = Repo.due_scheduled_jobs(~U[2026-05-02 14:20:00Z], server: repo)
      refute Enum.any?(due, &(&1.id == broken.id))
    end

    test "disables a stale recurring job whose schedule no longer parses (stale-skip branch)", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      broken = seed_broken_schedule_job(repo, next_run_at: ~U[2026-05-02 14:00:00Z])

      scheduler =
        start_scheduler(repo, runner_supervisor,
          runner_delay_ms: 1,
          run_freshness_window_seconds: 3600
        )

      # Two hours late: past the freshness window, so it reaches the stale-skip
      # recompute — which parses the same broken expression.
      assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 16:00:00Z])
      refute_receive {:job_runner, :started, _run_id, _job_id}, 100

      assert {:ok, disabled} = Registry.get_job(broken.id, repo: repo)
      assert disabled.state == "disabled"
      assert disabled.enabled? == false
      assert disabled.last_error =~ "schedule no longer parses"
    end

    test "resume of a still-broken disabled job fails loudly", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      broken = seed_broken_schedule_job(repo, next_run_at: ~U[2026-05-02 14:10:00Z])

      scheduler =
        start_scheduler(repo, runner_supervisor,
          runner_delay_ms: 1,
          run_freshness_window_seconds: 3600
        )

      assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
      assert {:ok, %{state: "disabled"}} = Registry.get_job(broken.id, repo: repo)

      # Resume re-parses the schedule; still broken, so it fails loudly and the
      # job stays disabled (edit first, then resume).
      assert {:error, _reason} = Registry.resume_job(broken.id, repo: repo, scheduler: nil)
      assert {:ok, still} = Registry.get_job(broken.id, repo: repo)
      assert still.state == "disabled"
    end
  end

  # These assert the timer re-arm, which reads the wall clock (Process.send_after
  # + Process.read_timer), so the due times are real-clock-relative: the seeded
  # job is genuinely past-due now. That keeps the scheduler's own init auto-tick
  # (fired at the real now) and the explicit tick on the SAME branch, so every
  # tick errors and floors the next timer at @due_error_backoff_ms.
  describe "due-tick failure backoff" do
    test "a scan failure re-arms the due timer at the backoff floor", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      # No job seeded: the scan itself faults, so nothing else runs this tick.
      fault = start_fault_repo(repo, :due_scheduled_jobs)
      scheduler = start_scheduler(fault, runner_supervisor, timer_enabled: true)

      assert :ok = Scheduler.tick(scheduler, now: DateTime.utc_now())
      assert_due_timer_backoff(scheduler)
    end

    test "an expiry-lookup failure re-arms the due timer at the backoff floor", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      now = DateTime.utc_now()
      seed_due_job(repo, name: "Expiry Fault", expires_at: DateTime.add(now, -60, :second))
      fault = start_fault_repo(repo, :get_scheduled_job)
      scheduler = start_scheduler(fault, runner_supervisor, timer_enabled: true)

      assert :ok = Scheduler.tick(scheduler, now: DateTime.utc_now())
      assert_due_timer_backoff(scheduler)
    end

    test "a stale-skip store failure re-arms the due timer at the backoff floor", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      now = DateTime.utc_now()
      # Two hours past due → stale-skip branch; the advance store faults.
      seed_due_job(repo, name: "Stale Fault", due_at: DateTime.add(now, -7200, :second))
      fault = start_fault_repo(repo, :upsert_scheduled_job)

      scheduler =
        start_scheduler(fault, runner_supervisor,
          timer_enabled: true,
          run_freshness_window_seconds: 3600
        )

      assert :ok = Scheduler.tick(scheduler, now: DateTime.utc_now())
      assert_due_timer_backoff(scheduler)
    end

    test "a claim failure re-arms the due timer at the backoff floor", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      now = DateTime.utc_now()
      # Five minutes past due → inside the freshness window (claim branch, not
      # stale-skip); the atomic claim faults.
      seed_due_job(repo, name: "Claim Fault", due_at: DateTime.add(now, -300, :second))
      fault = start_fault_repo(repo, :claim_due_job)

      scheduler =
        start_scheduler(fault, runner_supervisor,
          timer_enabled: true,
          run_freshness_window_seconds: 3600
        )

      assert :ok = Scheduler.tick(scheduler, now: DateTime.utc_now())
      assert_due_timer_backoff(scheduler)
    end
  end

  describe "admission control" do
    test "at max_active_runs the tick claims nothing; a freed slot lets the job run", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      {:ok, job_a} = seed_recurring_job(repo, "Admission A")
      {:ok, job_b} = seed_recurring_job(repo, "Admission B")

      scheduler =
        start_scheduler(repo, runner_supervisor,
          runner_delay_ms: 300,
          max_active_runs: 1
        )

      # Both are due, but the cap is 1: exactly one claims, the other is deferred
      # and stays scheduled (no run row).
      assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
      assert_receive {:job_runner, :started, run_id1, _job1}, 1_000
      refute_receive {:job_runner, :started, _run_id, _job2}, 150
      assert total_runs(repo, [job_a.id, job_b.id]) == 1

      # Let the slot free, then a later tick claims the deferred job. The Runner
      # sends :completed before it exits, and the DynamicSupervisor removes the
      # child asynchronously after that exit — so gate the second tick on the
      # supervisor actually reporting a free slot (the same occupancy source
      # at_capacity? reads), never on :completed alone.
      assert_receive {:job_runner, :completed, ^run_id1, _job1}, 1_000
      assert eventually(fn -> DynamicSupervisor.count_children(runner_supervisor).active == 0 end)
      assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
      assert_receive {:job_runner, :started, run_id2, _job2}, 1_000
      assert run_id2 != run_id1
      assert_receive {:job_runner, :completed, ^run_id2, _job2}, 1_000
      assert total_runs(repo, [job_a.id, job_b.id]) == 2
    end
  end

  describe "far-future due timers" do
    test "a wakeup beyond the OTP timer ceiling arms a clamped timer instead of crashing", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      # 60 days out — what `every 60 days` or a distant cron match produces. The
      # armed delay must be the scheduler's own ceiling, not the raw distance:
      # unclamped it hands `Process.send_after/3` a months-long delay and the
      # scheduler goes dark on a single timer until it fires.
      far_future = DateTime.add(DateTime.utc_now(), 60 * 24 * 3600, :second)
      seed_due_job(repo, name: "Far Future", due_at: far_future)

      scheduler = start_scheduler(repo, runner_supervisor, timer_enabled: true)

      assert scheduler |> Process.whereis() |> Process.alive?()

      state = :sys.get_state(scheduler)
      assert is_reference(state.due_timer)
      remaining = Process.read_timer(state.due_timer)
      assert is_integer(remaining)
      assert remaining <= 86_400_000
      assert remaining > 86_000_000
    end
  end

  describe "active-run reconciliation" do
    test "a run orphaned by a daemon restart is reaped and its job becomes claimable", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      {:ok, job} = seed_recurring_job(repo, "Wedged Check")
      stuck = seed_stuck_run(repo, job)

      # A daemon restart leaves no runner behind, only the active row.
      assert DynamicSupervisor.which_children(runner_supervisor) == []

      scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 1)

      assert {:ok, reaped} = Repo.get_job_run(stuck.id, server: repo)
      assert reaped.status == "error"
      assert reaped.error =~ "no live runner"

      assert {:ok, recovered} = Registry.get_job(job.id, repo: repo)
      assert recovered.state == "scheduled"
      assert recovered.last_status == "error"

      job_id = job.id
      assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
      assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000
      assert run_id != stuck.id
      assert_receive {:job_runner, :completed, ^run_id, ^job_id}, 1_000
    end

    test "a run with a surviving runner is adopted, and its later crash is still marked", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      {:ok, job} = seed_recurring_job(repo, "Surviving Check")
      job_id = job.id

      first = start_scheduler(repo, runner_supervisor, runner_module: LiveRunner)
      assert :ok = Scheduler.tick(first, now: ~U[2026-05-02 14:15:00Z])
      assert_receive {:job_runner, :started, run_id, ^job_id}, 1_000

      # Scheduler-only restart: :rest_for_one starts the runner supervisor first,
      # so the runner subtree outlives the scheduler.
      stop_supervised!(Scheduler)
      _second = start_scheduler(repo, runner_supervisor, runner_module: LiveRunner)

      assert {:ok, live} = Repo.get_job_run(run_id, server: repo)
      assert live.status == "queued"

      assert [{_id, pid, _type, _modules}] = DynamicSupervisor.which_children(runner_supervisor)
      Process.exit(pid, :kill)

      assert eventually(fn ->
               {:ok, run} = Repo.get_job_run(run_id, server: repo)
               run.status == "error"
             end)

      assert {:ok, crashed} = Repo.get_job_run(run_id, server: repo)
      assert crashed.error =~ "runner crashed"

      assert eventually(fn ->
               {:ok, current} = Registry.get_job(job_id, repo: repo)
               current.state == "scheduled"
             end)
    end

    test "every reconciliation pass scans active runs under a bounded limit", %{
      repo: repo,
      runner_supervisor: runner_supervisor
    } do
      {:ok, job} = seed_recurring_job(repo, "Bounded Check")
      _stuck = seed_stuck_run(repo, job)

      recording = start_recording_repo(repo, self())
      scheduler = start_scheduler(recording, runner_supervisor, runner_delay_ms: 1)

      assert_receive {:repo_request, {:active_job_runs, limit}}, 1_000
      assert is_integer(limit)
      assert limit > 0 and limit <= 50

      # The periodic pass is bounded the same way, not just the init pass.
      send(scheduler, :reconcile_tick)
      assert_receive {:repo_request, {:active_job_runs, ^limit}}, 1_000
    end
  end

  defp seed_broken_schedule_job(repo, opts) do
    {:ok, job} =
      Registry.create_job(
        %{
          created_by_trust: "operator",
          name: "Broken Schedule",
          schedule: "every 15 minutes",
          task_prompt: "Runs on a schedule that later breaks."
        },
        repo: repo,
        now: ~U[2026-05-02 13:00:00Z]
      )

    # Corrupt the stored expression to one that no longer parses, keeping the job
    # scheduled/enabled and due (a config only reachable by a direct write — the
    # registry validates schedules on create/update).
    {:ok, broken} =
      Repo.upsert_scheduled_job(
        Map.merge(job, %{
          schedule_expr: "not a real schedule",
          next_run_at: Keyword.fetch!(opts, :next_run_at),
          state: "scheduled",
          enabled?: true
        }),
        server: repo
      )

    broken
  end

  # A recurring job forced past-due via a direct next_run_at write (the registry
  # always parses "every 15 minutes" into a FUTURE next_run_at). `due_at`/
  # `expires_at` are real-clock-relative so the scheduler's init auto-tick agrees
  # with the explicit tick.
  defp seed_due_job(repo, opts) do
    now = DateTime.utc_now()
    due_at = Keyword.get(opts, :due_at, DateTime.add(now, -60, :second))

    {:ok, job} =
      Registry.create_job(
        %{
          created_by_trust: "operator",
          name: Keyword.fetch!(opts, :name),
          schedule: "every 15 minutes",
          task_prompt: "Run."
        },
        repo: repo,
        now: now
      )

    merged =
      job
      |> Map.merge(%{next_run_at: due_at, state: "scheduled", enabled?: true})
      |> maybe_put(:expires_at, Keyword.get(opts, :expires_at))

    {:ok, seeded} = Repo.upsert_scheduled_job(merged, server: repo)
    seeded
  end

  defp seed_recurring_job(repo, name) do
    Registry.create_job(
      %{
        created_by_trust: "operator",
        name: name,
        schedule: "every 15 minutes",
        task_prompt: "Run."
      },
      repo: repo,
      now: ~U[2026-05-02 14:00:00Z]
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A job left mid-run by a daemon that died: the job row still says "running"
  # and its run row is still active — exactly the pair that makes
  # `ensure_no_active_job_run` refuse every future claim for that job.
  defp seed_stuck_run(repo, job, opts \\ []) do
    now = Keyword.get(opts, :now, ~U[2026-05-02 14:15:00Z])

    {:ok, _running_job} =
      Repo.upsert_scheduled_job(%{job | state: "running", updated_at: now}, server: repo)

    {:ok, run} =
      Repo.upsert_job_run(
        %{
          id: "run_stuck_#{System.unique_integer([:positive])}",
          job_id: job.id,
          session_id: "cron_#{job.id}_stuck",
          trigger: "schedule",
          status: "running",
          claimed_at: now,
          started_at: now,
          delivery_status: "none",
          created_at: now,
          updated_at: now
        },
        server: repo
      )

    run
  end

  defp start_fault_repo(real, fail) do
    {:ok, pid} = start_supervised({FaultRepo, real: real, fail: fail})
    pid
  end

  defp start_recording_repo(real, notify) do
    {:ok, pid} = start_supervised({RecordingRepo, real: real, notify: notify})
    pid
  end

  defp assert_due_timer_backoff(scheduler) do
    state = :sys.get_state(scheduler)
    assert is_reference(state.due_timer)
    remaining = Process.read_timer(state.due_timer)
    assert is_integer(remaining)
    assert remaining > 4_000 and remaining <= 5_000
  end

  defp total_runs(repo, job_ids) do
    Enum.reduce(job_ids, 0, fn job_id, acc -> acc + run_count(repo, job_id) end)
  end

  defp start_scheduler(repo, runner_supervisor, opts) do
    name = :"jobs_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         repo: repo,
         runner_supervisor: runner_supervisor,
         scheduler_enabled: true,
         timer_enabled: Keyword.get(opts, :timer_enabled, false),
         run_freshness_window_seconds: Keyword.get(opts, :run_freshness_window_seconds, 3600),
         reconciliation_interval_ms: Keyword.get(opts, :reconciliation_interval_ms, 60_000),
         runner_module: Keyword.get(opts, :runner_module, FermixCore.Jobs.Runner),
         adapter: Keyword.get(opts, :adapter, TerminalAdapter),
         adapter_opts: [
           sleep_ms: Keyword.get(opts, :runner_delay_ms, 0),
           response:
             Keyword.get(
               opts,
               :response,
               "Fake scheduled job run completed for Frequent Check."
             )
         ],
         runner_notify: self(),
         runner_delay_ms: Keyword.get(opts, :runner_delay_ms, 0),
         max_active_runs: Keyword.get(opts, :max_active_runs, 4)
       ]}
    )

    name
  end

  defp active_run_count(repo, job_id) do
    {:ok, queued} = Repo.list_job_runs(%{job_id: job_id, status: "queued"}, server: repo)
    {:ok, running} = Repo.list_job_runs(%{job_id: job_id, status: "running"}, server: repo)
    length(queued) + length(running)
  end

  defp run_count(repo, job_id) do
    {:ok, runs} = Repo.list_job_runs(%{job_id: job_id}, server: repo)
    length(runs)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
