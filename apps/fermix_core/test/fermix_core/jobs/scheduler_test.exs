defmodule FermixCore.Jobs.SchedulerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo

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

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-jobs-scheduler-#{unique}.db")
    repo = :"jobs_scheduler_repo_#{unique}"
    runner_supervisor = :"jobs_runner_supervisor_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({RunnerSupervisor, name: runner_supervisor})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
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
                 name: "Slow Check",
                 schedule: "every 15 minutes",
                 task_prompt: "Check slowly."
               },
               repo: repo,
               now: ~U[2026-05-02 14:00:00Z]
             )

    scheduler = start_scheduler(repo, runner_supervisor, runner_delay_ms: 200)
    job_id = job.id

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Scheduler.tick(scheduler, now: ~U[2026-05-02 14:15:00Z])
    duration_ms = System.monotonic_time(:millisecond) - started_at

    assert duration_ms < 100
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
         runner_delay_ms: Keyword.get(opts, :runner_delay_ms, 0)
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
