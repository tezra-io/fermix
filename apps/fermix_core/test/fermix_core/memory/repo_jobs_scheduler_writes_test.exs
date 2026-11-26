defmodule FermixCore.Memory.RepoJobsSchedulerWritesTest do
  # The Scheduler's own writes of a job (`Jobs.Scheduler`): a stale skip, an
  # expiry and a disable are each one guarded write of the columns it moves,
  # drawn from the job as the due scan read it. A write that landed first (an
  # owner's pause or edit, a run's claim or settle, a removal) keeps what it
  # wrote, and no write here ever inserts a job. Every time here is given.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  @created_at ~U[2031-04-07 05:00:00.000000Z]
  @stale_at ~U[2031-04-07 06:00:00.000000Z]
  @raced_at ~U[2031-04-07 08:59:30.000000Z]
  @now ~U[2031-04-07 09:00:00.000000Z]
  @next_run_at ~U[2031-04-07 10:00:00.000000Z]
  @lease_s 300
  @expiry_columns [:enabled?, :state, :next_run_at, :last_status, :last_error, :updated_at]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-jobs-scheduler-writes-#{unique}.db")
    repo = :"memory_repo_jobs_scheduler_writes_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  describe "advance_stale_scheduled_job/4" do
    test "moves only the next run of a job still due at the instant the scan read", %{repo: repo} do
      job = create_job!(repo, "lighthouse_log")

      assert {:ok, advanced} =
               Repo.advance_stale_scheduled_job(job, @next_run_at, @now, server: repo)

      assert advanced.next_run_at == @next_run_at
      assert advanced.updated_at == @now

      assert Map.drop(advanced, [:next_run_at, :updated_at]) ==
               Map.drop(job, [:next_run_at, :updated_at])

      assert {:ok, ^advanced} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing on a job the owner paused since the scan", %{repo: repo} do
      job = create_job!(repo, "paused_lighthouse")
      paused = pause!(repo, job)

      assert {:ok, :unchanged} =
               Repo.advance_stale_scheduled_job(job, @next_run_at, @now, server: repo)

      assert {:ok, ^paused} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing on a job whose next run an edit moved since the scan", %{repo: repo} do
      job = create_job!(repo, "edited_lighthouse")
      edited = edit_schedule!(repo, job, "every 2 hours", ~U[2031-04-07 11:00:00.000000Z])

      assert {:ok, :unchanged} =
               Repo.advance_stale_scheduled_job(job, @next_run_at, @now, server: repo)

      assert {:ok, ^edited} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing on a job that expired since the scan", %{repo: repo} do
      job = create_job!(repo, "expired_lighthouse", %{expires_at: @raced_at})
      assert {:ok, expired} = Repo.expire_scheduled_job(job.id, @raced_at, server: repo)

      assert {:ok, :unchanged} =
               Repo.advance_stale_scheduled_job(job, @next_run_at, @now, server: repo)

      assert {:ok, ^expired} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "never inserts a job removed since the scan", %{repo: repo} do
      job = create_job!(repo, "removed_lighthouse")
      assert :ok = Repo.delete_scheduled_job_if_idle(job.id, server: repo)

      assert {:ok, :unchanged} =
               Repo.advance_stale_scheduled_job(job, @next_run_at, @now, server: repo)

      assert {:error, :not_found} = Repo.get_scheduled_job(job.id, server: repo)
    end
  end

  describe "expire_scheduled_job/3" do
    test "completes a job still enabled and scheduled whose expiry has passed", %{repo: repo} do
      job = create_job!(repo, "ferry_notice", %{expires_at: @raced_at, last_error: "earlier"})

      assert {:ok, expired} = Repo.expire_scheduled_job(job.id, @now, server: repo)

      assert %{enabled?: false, state: "completed", next_run_at: nil} = expired
      assert %{last_status: "expired", last_error: nil, updated_at: @now} = expired
      assert Map.drop(expired, @expiry_columns) == Map.drop(job, @expiry_columns)
      assert {:ok, ^expired} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing before the job's expiry", %{repo: repo} do
      job = create_job!(repo, "early_ferry_notice", %{expires_at: @next_run_at})

      assert {:ok, :unchanged} = Repo.expire_scheduled_job(job.id, @now, server: repo)
      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: repo)
    end

    # An owner's expiry is stored to the second, the clock's `now` to the
    # microsecond: as text "…09:00:00Z" sorts after "…09:00:00.250000Z".
    test "compares the expiry and now as instants, whatever their digits", %{repo: repo} do
      job =
        create_job!(repo, "whole_second_ferry_notice", %{expires_at: ~U[2031-04-07 09:00:00Z]})

      assert {:ok, %{state: "completed"}} =
               Repo.expire_scheduled_job(job.id, ~U[2031-04-07 09:00:00.250000Z], server: repo)
    end

    test "changes nothing on a job the owner paused since the scan", %{repo: repo} do
      job = create_job!(repo, "paused_ferry_notice", %{expires_at: @raced_at})
      paused = pause!(repo, job)

      assert {:ok, :unchanged} = Repo.expire_scheduled_job(job.id, @now, server: repo)
      assert {:ok, ^paused} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "keeps an edit made since the scan and moves only its own columns", %{repo: repo} do
      job = create_job!(repo, "edited_ferry_notice", %{expires_at: @raced_at})

      {:ok, edited, []} =
        Repo.update_scheduled_job_fields(
          job.id,
          %{
            task_prompt: "Post the winter timetable.",
            description: "Winter",
            updated_at: @raced_at
          },
          server: repo
        )

      assert {:ok, expired} = Repo.expire_scheduled_job(job.id, @now, server: repo)
      assert expired.task_prompt == "Post the winter timetable."
      assert expired.description == "Winter"
      assert %{state: "completed", enabled?: false, last_status: "expired"} = expired
      assert Map.drop(expired, @expiry_columns) == Map.drop(edited, @expiry_columns)
    end

    test "changes nothing on a one-off a run completed since the scan", %{repo: repo} do
      job =
        create_job!(repo, "completed_ferry_notice", %{
          schedule_kind: "once",
          schedule_expr: "2031-04-07T06:00:00.000000Z",
          expires_at: @raced_at
        })

      completed = complete_by_run!(repo, job)

      assert {:ok, :unchanged} = Repo.expire_scheduled_job(job.id, @now, server: repo)
      assert {:ok, ^completed} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "never inserts a job removed since the scan", %{repo: repo} do
      job = create_job!(repo, "removed_ferry_notice", %{expires_at: @raced_at})
      assert :ok = Repo.delete_scheduled_job_if_idle(job.id, server: repo)

      assert {:ok, :unchanged} = Repo.expire_scheduled_job(job.id, @now, server: repo)
      assert {:error, :not_found} = Repo.get_scheduled_job(job.id, server: repo)
    end
  end

  describe "disable_scheduled_job/4" do
    @parse_error "schedule no longer parses: :not_cron"

    test "disables a job still carrying the schedule that failed to parse", %{repo: repo} do
      job = create_job!(repo, "tide_gauge", %{schedule_expr: "every blue moon"})

      assert {:ok, disabled} = Repo.disable_scheduled_job(job, @parse_error, @now, server: repo)

      assert %{state: "disabled", enabled?: false, last_error: @parse_error} = disabled
      assert disabled.updated_at == @now
      disable_columns = [:state, :enabled?, :last_error, :updated_at]
      assert Map.drop(disabled, disable_columns) == Map.drop(job, disable_columns)
      assert {:ok, ^disabled} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing on a job the owner paused since the scan", %{repo: repo} do
      job = create_job!(repo, "paused_tide_gauge", %{schedule_expr: "every blue moon"})
      paused = pause!(repo, job)

      assert {:ok, :unchanged} = Repo.disable_scheduled_job(job, @parse_error, @now, server: repo)
      assert {:ok, ^paused} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing on a job whose schedule an edit fixed since the scan", %{repo: repo} do
      job = create_job!(repo, "fixed_tide_gauge", %{schedule_expr: "every blue moon"})
      fixed = edit_schedule!(repo, job, "every 2 hours", ~U[2031-04-07 11:00:00.000000Z])

      assert {:ok, :unchanged} = Repo.disable_scheduled_job(job, @parse_error, @now, server: repo)
      assert {:ok, ^fixed} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "changes nothing on a job that expired since the scan", %{repo: repo} do
      job =
        create_job!(repo, "expired_tide_gauge", %{
          schedule_expr: "every blue moon",
          expires_at: @raced_at
        })

      assert {:ok, expired} = Repo.expire_scheduled_job(job.id, @raced_at, server: repo)

      assert {:ok, :unchanged} = Repo.disable_scheduled_job(job, @parse_error, @now, server: repo)
      assert {:ok, ^expired} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "never inserts a job removed since the scan", %{repo: repo} do
      job = create_job!(repo, "removed_tide_gauge", %{schedule_expr: "every blue moon"})
      assert :ok = Repo.delete_scheduled_job_if_idle(job.id, server: repo)

      assert {:ok, :unchanged} = Repo.disable_scheduled_job(job, @parse_error, @now, server: repo)
      assert {:error, :not_found} = Repo.get_scheduled_job(job.id, server: repo)
    end
  end

  # An owner's write marks the job's diagnosing heal written-under and
  # supersedes its waiting proposal (`update_scheduled_job_fields/3`); these
  # are the engine's moves, and do neither.
  describe "the engine's moves, not the owner's" do
    test "a stale skip and an expiry leave a diagnosing heal unmarked", %{repo: repo} do
      {job, heal} = diagnosing!(repo, %{expires_at: DateTime.add(@now, 7_200, :second)})

      assert {:ok, %{next_run_at: @next_run_at}} =
               Repo.advance_stale_scheduled_job(job, @next_run_at, @now, server: repo)

      assert {:ok, %{owner_wrote_at: nil, state: "diagnosing"}} = get_heal(repo, heal)

      expires_at = DateTime.add(@now, 7_200, :second)

      assert {:ok, %{state: "completed"}} =
               Repo.expire_scheduled_job(job.id, expires_at, server: repo)

      assert {:ok, %{owner_wrote_at: nil, state: "diagnosing"}} = get_heal(repo, heal)
    end

    test "a disable leaves a diagnosing heal unmarked", %{repo: repo} do
      {job, heal} = diagnosing!(repo, %{})

      assert {:ok, %{state: "disabled"}} =
               Repo.disable_scheduled_job(job, @parse_error, @now, server: repo)

      assert {:ok, %{owner_wrote_at: nil, state: "diagnosing"}} = get_heal(repo, heal)
    end

    test "an expiry supersedes no waiting proposal", %{repo: repo} do
      {job, heal} = diagnosing!(repo, %{expires_at: DateTime.add(@now, 7_200, :second)})
      plan = %{decision: "propose", note: nil, read_outside: true, change: nil}
      :ok = heals(repo, {:decided, heal.id, heal.lease_token, plan, @now})
      :ok = heals(repo, {:delivered, heal.id, heal.lease_token, @now})
      assert {:ok, %{state: "waiting"}} = get_heal(repo, heal)

      expires_at = DateTime.add(@now, 7_200, :second)

      assert {:ok, %{state: "completed"}} =
               Repo.expire_scheduled_job(job.id, expires_at, server: repo)

      assert {:ok, %{state: "waiting"}} = get_heal(repo, heal)
    end
  end

  # --- fixtures ------------------------------------------------------------------

  # A recurring job due at @stale_at, as the due scan reads it.
  defp create_job!(repo, id, attrs \\ %{}) do
    job_attrs =
      Map.merge(
        %{
          id: id,
          name: id,
          schedule_kind: "interval",
          schedule_expr: "every 1 hour",
          timezone: "UTC",
          next_run_at: @stale_at,
          task_prompt: "Log the lighthouse's lamp hours.",
          memory_source_id: "job:#{id}",
          created_by_agent_id: "main",
          created_by_channel: "cli",
          created_by_trust: "operator",
          created_at: @created_at,
          updated_at: @created_at
        },
        attrs
      )

    source_attrs = %{
      id: "job:#{id}",
      source_type: "scheduled_job",
      name: id,
      description: "test job",
      memory_scope: "job:#{id}",
      output_scope: "cron:#{id}"
    }

    {:ok, job} = Repo.create_job_with_source(job_attrs, source_attrs, server: repo)
    job
  end

  defp pause!(repo, job) do
    {:ok, paused, _superseded} =
      Repo.update_scheduled_job_fields(
        job.id,
        %{enabled?: false, state: "paused", updated_at: @raced_at},
        server: repo
      )

    paused
  end

  defp edit_schedule!(repo, job, schedule_expr, next_run_at) do
    {:ok, edited, _superseded} =
      Repo.update_scheduled_job_fields(
        job.id,
        %{schedule_expr: schedule_expr, next_run_at: next_run_at, updated_at: @raced_at},
        server: repo
      )

    edited
  end

  # A one-off's run, claimed and settled ok: the settle completes and
  # disables the job its claim consumed.
  defp complete_by_run!(repo, job) do
    run_attrs = %{
      id: "run_#{job.id}",
      job_id: job.id,
      session_id: "cron_#{job.id}_raced",
      trigger: "schedule",
      status: "queued",
      claimed_at: @raced_at,
      delivery_status: "none",
      created_at: @raced_at,
      updated_at: @raced_at
    }

    patch = %{state: "running", next_run_at: nil, updated_at: @raced_at}
    {:ok, {_claimed, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: repo)
    final = Map.merge(run, %{status: "ok", completed_at: @raced_at, updated_at: @raced_at})
    {:ok, {_run, completed, _settlement}} = Repo.settle_job_run(final, :ok, server: repo)
    %{state: "completed", enabled?: false} = completed
    completed
  end

  # A job whose run failed, its heal claimed by a heal run: `diagnosing`. The
  # failed run's settle releases the job scheduled, due at the claim's next run.
  defp diagnosing!(repo, attrs) do
    {:ok, job} =
      Registry.create_job(
        Map.merge(
          %{
            name: "Harbour tide table #{System.unique_integer([:positive])}",
            schedule: "every 1 hour",
            timezone: "UTC",
            task_prompt: "Fetch this morning's tides.",
            created_by_trust: "operator"
          },
          attrs
        ),
        repo: repo,
        now: @created_at,
        scheduler: nil
      )

    run_attrs = %{
      id: "run_#{job.id}",
      job_id: job.id,
      session_id: "cron_#{job.id}_failed",
      trigger: "manual",
      status: "queued",
      claimed_at: @stale_at,
      delivery_status: "none",
      created_at: @stale_at,
      updated_at: @stale_at
    }

    patch = %{state: "running", next_run_at: @stale_at, updated_at: @stale_at}
    {:ok, {_job, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: repo)
    text = "wall-clock timeout after 600000ms"

    failed =
      Map.merge(run, %{
        status: "error",
        error: text,
        failure_kind: "time_limit",
        completed_at: @stale_at,
        updated_at: @stale_at,
        heal_facts: %{failure_text: text, provider: nil}
      })

    {:ok, {_run, released, %{heal: {:opened, _id}}}} =
      Repo.settle_job_run(failed, {:failed, :other}, server: repo)

    {:ok, heal} = heals(repo, {:claim, @raced_at, DateTime.add(@raced_at, @lease_s, :second)})
    {released, heal}
  end

  defp heals(repo, request), do: Repo.job_heals_call(request, server: repo)
  defp get_heal(repo, heal), do: heals(repo, {:get, heal.id})
end
