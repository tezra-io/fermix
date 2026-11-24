defmodule FermixCore.Memory.RepoJobRetriesTest do
  # M106 §5.3: a failed scheduled run's retry is decided in its settle's
  # transaction and kept beside the job (`job_retries`), and the due scan
  # claims a passed retry through the claim every run takes. Every time here
  # is given, never read from a clock.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  # Microsecond precision, as every clock reading the engine stores has.
  @created ~U[2026-11-20 06:00:00.000000Z]
  @first_run ~U[2026-11-20 07:00:00.000000Z]
  @next_run ~U[2026-11-20 08:00:00.000000Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-retries-#{unique}.db")
    repo = :"memory_repo_job_retries_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  test "a provider failure before any tool sets the first retry, 30 s on", %{repo: repo} do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)

    assert {:ok, {settled, released, settlement}} =
             settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert retry(settlement) == %{disposition: :retry, attempts: 1, retry_at: at(7, 0, 40)}
    assert {:ok, %{attempts: 1, retry_at: retry_at}} = Repo.get_job_retry(job.id, server: repo)
    assert retry_at == at(7, 0, 40)

    # The rows still say what happened.
    assert settled.status == "error"
    assert released.state == "scheduled"
    assert released.last_status == "error"
    assert released.next_run_at == @next_run
  end

  test "the ladder: 30 s, 2 min, 10 min, then the fourth is exhausted and the count reset", %{
    repo: repo
  } do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)

    assert {:ok, {_run, _job, %{disposition: :retry, attempts: 1, retry_at: retry_1}}} =
             settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert retry_1 == at(7, 0, 40)

    run = claim_retry!(repo, job, retry_1)

    assert {:ok, {_run, _job, %{disposition: :retry, attempts: 2, retry_at: retry_2}}} =
             settle(repo, run, {:failed, :provider}, at(7, 0, 50))

    assert retry_2 == at(7, 2, 50)

    run = claim_retry!(repo, job, retry_2)

    assert {:ok, {_run, _job, %{disposition: :retry, attempts: 3, retry_at: retry_3}}} =
             settle(repo, run, {:failed, :provider}, at(7, 3, 0))

    assert retry_3 == at(7, 13, 0)

    run = claim_retry!(repo, job, retry_3)

    assert {:ok, {_run, _job, settlement}} =
             settle(repo, run, {:failed, :provider}, at(7, 13, 10))

    assert retry(settlement) == %{disposition: :exhausted, attempts: 4, retry_at: nil}
    assert {:ok, nil} = Repo.get_job_retry(job.id, server: repo)
  end

  test "a passed retry is claimed as a retry: its next run and count kept, its time cleared", %{
    repo: repo
  } do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)
    {:ok, _settled} = settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert {:ok, []} = Repo.due_scheduled_jobs(at(7, 0, 39), server: repo)
    assert {:ok, [due]} = Repo.due_scheduled_jobs(at(7, 0, 40), server: repo)
    assert due.id == job.id
    assert due.retry_at == at(7, 0, 40)
    assert due.next_run_at == @next_run

    # The timer's read names the earliest wakeup, the retry here.
    assert {:ok, %{id: id, retry_at: next_retry}} = Repo.next_scheduled_job(server: repo)
    assert {id, next_retry} == {job.id, at(7, 0, 40)}

    assert {:error, :not_due} =
             Repo.claim_retry_job(
               job.id,
               running(at(7, 0, 39)),
               retry_run(job, at(7, 0, 39)),
               at(7, 0, 39),
               server: repo
             )

    retried = claim_retry!(repo, job, at(7, 0, 40))
    assert retried.trigger == "retry"

    assert {:ok, %{next_run_at: @next_run, state: "running"}} =
             Repo.get_scheduled_job(job.id, server: repo)

    assert {:ok, %{attempts: 1, retry_at: nil}} = Repo.get_job_retry(job.id, server: repo)
    assert {:ok, []} = Repo.due_scheduled_jobs(at(7, 1, 0), server: repo)
  end

  # Never past the next occurrence: the next scheduled run is the retry, and it
  # counts as the next attempt.
  test "a retry at or after the next run sets no time, and the next run is the next attempt", %{
    repo: repo
  } do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)

    assert {:ok, {_run, _job, settlement}} =
             settle(repo, run, {:failed, :provider}, at(7, 59, 45))

    assert retry(settlement) == %{disposition: :retry, attempts: 1, retry_at: nil}
    assert {:ok, []} = Repo.due_scheduled_jobs(at(7, 59, 59), server: repo)

    run = claim_due!(repo, job, @next_run)
    assert run.trigger == "schedule"
    assert {:ok, %{attempts: 1, retry_at: nil}} = Repo.get_job_retry(job.id, server: repo)

    assert {:ok, {_run, _job, %{disposition: :retry, attempts: 2, retry_at: retry_at}}} =
             settle(repo, run, {:failed, :provider}, at(8, 0, 10))

    assert retry_at == at(8, 2, 10)
  end

  test "a due claim of a job whose retry has also passed is one run, and clears the retry", %{
    repo: repo
  } do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)
    {:ok, _settled} = settle(repo, run, {:failed, :provider}, at(7, 59, 0))

    assert {:ok, [due]} = Repo.due_scheduled_jobs(@next_run, server: repo)
    assert due.retry_at == at(7, 59, 30)

    run = claim_due!(repo, job, @next_run)
    assert run.trigger == "schedule"
    assert {:ok, %{attempts: 1, retry_at: nil}} = Repo.get_job_retry(job.id, server: repo)
    assert {:ok, []} = Repo.due_scheduled_jobs(@next_run, server: repo)
  end

  test "an ok run, a failure not the provider's, and a failure after a tool reset the count", %{
    repo: repo
  } do
    for {settle_by, status, tools_started?} <- [
          {:ok, "ok", false},
          {{:failed, :other}, "error", false},
          {{:failed, :provider}, "error", true},
          {:scheduler, "error", true}
        ] do
      job = create_job!(repo)
      run = claim_due!(repo, job, @first_run)
      {:ok, _settled} = settle(repo, run, {:failed, :provider}, at(7, 0, 10))
      run = claim_retry!(repo, job, at(7, 0, 40))

      if tools_started? do
        :ok = Repo.mark_job_run_tools_started(run.id, at(7, 0, 41), server: repo)
      end

      assert {:ok, {_run, _job, settlement}} =
               settle(repo, run, settle_by, at(7, 0, 50), status)

      assert {settle_by, tools_started?, retry(settlement)} ==
               {settle_by, tools_started?, %{disposition: :none, attempts: 0, retry_at: nil}}

      assert {:ok, nil} = Repo.get_job_retry(job.id, server: repo)
    end
  end

  test "a run the Scheduler settles before any tool is retried", %{repo: repo} do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)

    assert {:ok, {_run, _job, %{disposition: :retry, attempts: 1}}} =
             settle(repo, run, :scheduler, at(7, 0, 10))
  end

  test "a one-off job and a job paused mid-run are not retried", %{repo: repo} do
    once = create_job!(repo, schedule: DateTime.to_iso8601(@first_run))
    run = claim_due!(repo, once, @first_run, next_run_at: nil)

    assert {:ok, {_run, released, %{disposition: :none}}} =
             settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert released.state == "completed"

    paused = create_job!(repo)
    run = claim_due!(repo, paused, @first_run)
    {:ok, _paused} = Registry.pause_job(paused.id, repo: repo, scheduler: nil)

    assert {:ok, {_run, %{state: "paused"}, %{disposition: :none}}} =
             settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert {:ok, nil} = Repo.get_job_retry(paused.id, server: repo)
  end

  # Each of the owner's actions leaves the job with no retry, in its own
  # transaction, so a paused job's old retry never fires on resume.
  test "pause, resume, an edit and run now each clear a pending retry", %{repo: repo} do
    actions = [
      pause: fn job -> Registry.pause_job(job.id, repo: repo, scheduler: nil) end,
      resume: fn job ->
        Registry.resume_job(job.id, repo: repo, scheduler: nil, now: @first_run)
      end,
      edit: fn job ->
        Registry.update_job(job.id, %{task_prompt: "Fetch the evening tides."},
          repo: repo,
          scheduler: nil,
          now: @first_run
        )
      end,
      run_now: fn job ->
        Repo.claim_job_now(job.id, running(at(7, 0, 20)), manual_run(job, at(7, 0, 20)),
          server: repo
        )
      end
    ]

    for {name, action} <- actions do
      job = create_job!(repo)
      run = claim_due!(repo, job, @first_run)
      {:ok, _settled} = settle(repo, run, {:failed, :provider}, at(7, 0, 10))
      assert {:ok, %{attempts: 1}} = Repo.get_job_retry(job.id, server: repo)

      assert {:ok, _done} = action.(job)
      assert {name, Repo.get_job_retry(job.id, server: repo)} == {name, {:ok, nil}}
    end
  end

  test "a removed job takes its retry with it", %{repo: repo} do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)
    {:ok, _settled} = settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert :ok = Repo.delete_scheduled_job_if_idle(job.id, server: repo)
    assert {:ok, nil} = Repo.get_job_retry(job.id, server: repo)
  end

  test "a stale retry is dropped and keeps its count; a fresher one is kept", %{repo: repo} do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)
    {:ok, _settled} = settle(repo, run, {:failed, :provider}, at(7, 0, 10))

    assert :ok = Repo.drop_stale_job_retry(job.id, at(7, 0, 39), server: repo)
    assert {:ok, %{attempts: 1, retry_at: kept}} = Repo.get_job_retry(job.id, server: repo)
    assert kept == at(7, 0, 40)

    assert :ok = Repo.drop_stale_job_retry(job.id, at(7, 0, 40), server: repo)
    assert {:ok, %{attempts: 1, retry_at: nil}} = Repo.get_job_retry(job.id, server: repo)
  end

  test "a settle told nothing a settle can be is refused", %{repo: repo} do
    job = create_job!(repo)
    run = claim_due!(repo, job, @first_run)
    attrs = Map.merge(run, %{status: "error", completed_at: @first_run, updated_at: @first_run})

    assert_raise FunctionClauseError, fn -> Repo.settle_job_run(attrs, :acted, server: repo) end
    assert_raise FunctionClauseError, fn -> Repo.settle_job_run(attrs, :ok, server: repo) end

    # A failure carries its kind and what a heal is told of it (M106 §5.4).
    assert_raise FunctionClauseError, fn ->
      Repo.settle_job_run(Map.put(attrs, :failure_kind, "other"), {:failed, :other}, server: repo)
    end

    ok_attrs = %{attrs | status: "ok"}

    assert_raise FunctionClauseError, fn ->
      Repo.settle_job_run(ok_attrs, {:failed, :provider}, server: repo)
    end
  end

  defp at(hour, minute, second), do: %{@first_run | hour: hour, minute: minute, second: second}

  defp create_job!(repo, attrs \\ []) do
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
          Map.new(attrs)
        ),
        repo: repo,
        now: @created,
        scheduler: nil
      )

    job
  end

  defp claim_due!(repo, job, now, opts \\ []) do
    next_run_at = Keyword.get(opts, :next_run_at, DateTime.add(now, 3_600, :second))
    patch = %{state: "running", next_run_at: next_run_at, updated_at: now}

    {:ok, {_job, run}} =
      Repo.claim_due_job(job.id, patch, run_attrs(job, now, "schedule"), now, server: repo)

    run
  end

  defp claim_retry!(repo, job, now) do
    {:ok, {_job, run}} =
      Repo.claim_retry_job(job.id, running(now), retry_run(job, now), now, server: repo)

    run
  end

  defp running(now), do: %{state: "running", updated_at: now}
  defp retry_run(job, now), do: run_attrs(job, now, "retry")
  defp manual_run(job, now), do: run_attrs(job, now, "manual")

  defp run_attrs(job, now, trigger) do
    %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{System.unique_integer([:positive])}",
      trigger: trigger,
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }
  end

  defp settle(repo, run, settle_by, at, status \\ "error") do
    attrs =
      run
      |> Map.merge(%{status: status, completed_at: at, updated_at: at})
      |> Map.merge(failure(status))

    Repo.settle_job_run(attrs, settle_by, server: repo)
  end

  defp failure("ok"), do: %{error: nil}

  defp failure(_status) do
    %{
      error: "the provider refused",
      failure_kind: "provider_rate_limit",
      heal_facts: %{failure_text: "OpenAI rate-limited this request.", provider: "openai"}
    }
  end

  # The retry's part of a settlement; what the heals made of it is
  # `RepoJobHealsTest`'s.
  defp retry(settlement), do: Map.take(settlement, [:disposition, :attempts, :retry_at])
end
