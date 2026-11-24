defmodule FermixCore.Memory.RepoJobHealsMovesTest do
  # M106 §5.5, §5.9 (stage S3) at the store: a heal run records its decision
  # under its lease; its concluding write takes the heal where the decision
  # says (watching after a move Fermix made, waiting otherwise), and a fix
  # that did not hold is concluded a second time by the same claim, lease and
  # outbox, then closed still failing. Every time here is given.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  @created ~U[2031-03-03 06:00:00.000000Z]
  @lease_s 300

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heal-moves-#{unique}.db")
    repo = :"memory_repo_job_heal_moves_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  describe "the decision, under the lease" do
    test "is recorded with its note, its change and what the run read", %{repo: repo} do
      {_job, heal} = claimed!(repo, at(7, 10))

      plan = %{
        decision: "propose",
        note: "Point the task at the new page.",
        read_outside: true,
        change: %{"schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"}},
        change_job_version: at(7, 0)
      }

      assert :ok = call(repo, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})

      assert {:ok, stored} = call(repo, {:get, heal.id})
      assert %{decision: "propose", note: "Point the task at the new page."} = stored
      assert stored.read_outside == true
      assert stored.change == plan.change
      assert DateTime.compare(stored.change_job_version, at(7, 0)) == :eq
      assert stored.state == "diagnosing"
    end

    test "a run that lost its lease records nothing and holds nothing", %{repo: repo} do
      {_job, heal} = claimed!(repo, at(7, 10))
      {:ok, _retaken} = claim(repo, DateTime.add(at(7, 30), @lease_s, :second))
      plan = %{decision: "pause", note: "Pause it.", read_outside: true, change: nil}

      assert {:error, :lease_lost} =
               call(repo, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})

      assert {:error, :lease_lost} = call(repo, {:hold, heal.id, heal.lease_token, at(7, 31)})
      assert {:ok, %{decision: nil}} = call(repo, {:get, heal.id})
    end
  end

  describe "the concluding write follows the decision" do
    for {decision, state} <- [
          {"rerun", "watching"},
          {"raise_limit", "watching"},
          {"pause", "waiting"},
          {"propose", "waiting"},
          {"tell", "waiting"},
          {"none", "waiting"}
        ] do
      test "#{decision} leaves the heal #{state}", %{repo: repo} do
        {_job, heal} = claimed!(repo, at(7, 10))
        plan = %{decision: unquote(decision), note: nil, read_outside: true, change: nil}
        :ok = call(repo, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})

        assert :ok = call(repo, {:delivered, heal.id, heal.lease_token, at(7, 32)})

        assert {:ok, %{state: unquote(state), lease_token: nil} = stored} =
                 call(repo, {:get, heal.id})

        assert DateTime.compare(stored.waiting_since, at(7, 32)) == :eq
        assert stored.rerun_at != nil == (unquote(decision) == "rerun")
      end
    end

    test "a dead letter follows it too", %{repo: repo} do
      {_job, heal} = claimed!(repo, at(7, 10))
      plan = %{decision: "raise_limit", note: nil, read_outside: true, change: nil}
      :ok = call(repo, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})

      failure = %{attempts: 1, error: "{:permanent, :invalid_destination}"}
      assert :ok = call(repo, {:dead_letter, heal.id, heal.lease_token, failure, at(7, 32)})

      assert {:ok, %{state: "watching", delivery_status: "dead_letter"}} =
               call(repo, {:get, heal.id})
    end
  end

  describe "the verdict" do
    test "a failure of a watching heal's job concludes it again, and its message closes it",
         %{repo: repo} do
      {job, heal} = watching!(repo, at(7, 10), "rerun")
      run = claim_run!(repo, job, at(8, 0))

      assert {:ok, {_run, _job, %{heal: {:verdict, heal_id}}}} =
               fail(repo, run, at(8, 5), "crashed", "The run stopped before it finished.")

      assert heal_id == heal.id

      assert {:ok, reopened} = call(repo, {:get, heal.id})

      assert %{
               state: "open",
               conclusion: "verdict",
               failure_kind: "crashed",
               failure_text: "The run stopped before it finished.",
               message: nil,
               delivery_status: "pending",
               delivery_attempts: 0,
               decision: "rerun",
               run_count: 2
             } = reopened

      assert {:ok, %{id: ^heal_id, lease_token: token}} = claim(repo, at(8, 6))
      assert :ok = call(repo, {:put_message, heal.id, token, "Still failing.", at(8, 6)})
      assert :ok = call(repo, {:delivered, heal.id, token, at(8, 7)})

      assert {:ok, %{state: "closed", outcome: "still_failing", delivery_status: "delivered"}} =
               call(repo, {:get, heal.id})
    end

    test "a third failure, of the same kind, opens nothing and joins nothing", %{repo: repo} do
      {job, heal} = watching!(repo, at(7, 10), "raise_limit")
      {:ok, _} = fail(repo, claim_run!(repo, job, at(8, 0)), at(8, 5), "time_limit", "Again.")
      {:ok, %{lease_token: token}} = claim(repo, at(8, 6))
      :ok = call(repo, {:put_message, heal.id, token, "Still failing.", at(8, 6)})
      :ok = call(repo, {:delivered, heal.id, token, at(8, 7)})

      assert {:ok, {_run, _job, %{heal: :quiet}}} =
               fail(repo, claim_run!(repo, job, at(9, 0)), at(9, 5), "time_limit", "Third.")

      assert {:ok, nil} = claim(repo, at(9, 6))
      assert {:ok, %{state: "closed", run_count: 2}} = call(repo, {:get, heal.id})
    end

    test "an ok run of a watching heal's job closes it healed, and nothing is due", %{repo: repo} do
      {job, heal} = watching!(repo, at(7, 10), "rerun")
      run = claim_run!(repo, job, at(8, 0))
      ok = Map.merge(run, %{status: "ok", completed_at: at(8, 2), updated_at: at(8, 2)})

      assert {:ok, {_run, _job, %{healed: [healed]}}} = Repo.settle_job_run(ok, :ok, server: repo)
      assert healed == heal.id
      assert {:ok, %{state: "closed", outcome: "healed"}} = call(repo, {:get, heal.id})
      assert {:ok, nil} = claim(repo, at(8, 3))
    end

    test "a failure of a waiting heal's job only joins it, as before", %{repo: repo} do
      {job, heal} = concluded!(repo, at(7, 10), "tell")
      run = claim_run!(repo, job, at(8, 0))

      assert {:ok, {_run, _job, %{heal: {:joined, joined}}}} =
               fail(repo, run, at(8, 5), "time_limit", "Again.")

      assert joined == heal.id
      assert {:ok, %{state: "waiting", conclusion: "first"}} = call(repo, {:get, heal.id})
    end
  end

  describe "what came of a rerun" do
    for outcome <- ["started", "running", "unanswered"] do
      test "#{outcome} is recorded, and the heal keeps watching", %{repo: repo} do
        {_job, heal} = watching!(repo, at(7, 10), "rerun")

        assert :ok = call(repo, {:rerun_outcome, heal.id, unquote(outcome), at(7, 33)})

        assert {:ok, %{state: "watching", rerun_outcome: unquote(outcome)}} =
                 call(repo, {:get, heal.id})
      end
    end

    test "refused takes the watching heal to waiting, from then on", %{repo: repo} do
      {_job, heal} = watching!(repo, at(7, 10), "rerun")

      assert :ok = call(repo, {:rerun_outcome, heal.id, "refused", at(7, 33)})

      assert {:ok, %{state: "waiting", rerun_outcome: "refused"} = stored} =
               call(repo, {:get, heal.id})

      assert DateTime.compare(stored.waiting_since, at(7, 33)) == :eq
    end

    test "is recorded once: a second outcome changes nothing", %{repo: repo} do
      {_job, heal} = watching!(repo, at(7, 10), "rerun")
      :ok = call(repo, {:rerun_outcome, heal.id, "started", at(7, 33)})

      assert {:error, :not_recorded} =
               call(repo, {:rerun_outcome, heal.id, "refused", at(7, 34)})

      assert {:ok, %{state: "watching", rerun_outcome: "started"}} = call(repo, {:get, heal.id})
    end

    # The rerun's own run can settle before its outcome is written; a refusal
    # then moves no heal the settle already moved.
    test "a heal the job's run already moved keeps where the run put it", %{repo: repo} do
      {job, heal} = watching!(repo, at(7, 10), "rerun")
      {:ok, _} = fail(repo, claim_run!(repo, job, at(7, 40)), at(7, 41), "crashed", "Again.")

      assert :ok = call(repo, {:rerun_outcome, heal.id, "refused", at(7, 42)})

      assert {:ok, %{state: "open", conclusion: "verdict", rerun_outcome: "refused"}} =
               call(repo, {:get, heal.id})
    end

    test "a heal that decided no rerun takes no outcome", %{repo: repo} do
      {_job, heal} = watching!(repo, at(7, 10), "raise_limit")

      assert {:error, :not_recorded} =
               call(repo, {:rerun_outcome, heal.id, "started", at(7, 33)})
    end
  end

  test "a heal watching seven days with no run of its job closes as expired", %{repo: repo} do
    {_job, heal} = watching!(repo, at(7, 10), "raise_limit")
    seven_days_on = DateTime.add(at(7, 32), 7 * 86_400, :second)

    assert {:ok, [%{id: id}]} = call(repo, {:expire_waiting, seven_days_on})
    assert id == heal.id
    assert {:ok, %{state: "closed", outcome: "expired"}} = call(repo, {:get, heal.id})
  end

  test "each job's heal carries its decision, its note and its change", %{repo: repo} do
    {job, heal} = claimed!(repo, at(7, 10))

    plan = %{
      decision: "propose",
      note: "Point the task at the new page.",
      read_outside: true,
      change: %{"task" => %{"from" => "Old.", "to" => "New."}},
      change_job_version: at(7, 0)
    }

    :ok = call(repo, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})
    :ok = call(repo, {:delivered, heal.id, heal.lease_token, at(7, 32)})

    assert {:ok, by_job} = call(repo, :open_by_job)

    assert %{decision: "propose", note: "Point the task at the new page.", change: change} =
             Map.fetch!(by_job, job.id)

    assert change == plan.change
  end

  # --- fixtures ------------------------------------------------------------------

  defp at(hour, minute), do: DateTime.new!(~D[2031-03-04], Time.new!(hour, minute, 0, {0, 6}))

  defp call(repo, request), do: Repo.job_heals_call(request, server: repo)

  defp claim(repo, now), do: call(repo, {:claim, now, DateTime.add(now, @lease_s, :second)})

  # A job whose run failed at `failed_at`, its heal claimed twenty minutes on.
  defp claimed!(repo, failed_at) do
    job = create_job!(repo)

    {:ok, {_run, _job, %{heal: {:opened, _id}}}} =
      fail(
        repo,
        claim_run!(repo, job, DateTime.add(failed_at, -60, :second)),
        failed_at,
        "time_limit",
        "wall-clock timeout after 600000ms"
      )

    {:ok, heal} = claim(repo, DateTime.add(failed_at, 1_200, :second))
    {job, heal}
  end

  defp concluded!(repo, failed_at, decision) do
    {job, heal} = claimed!(repo, failed_at)
    plan = %{decision: decision, note: nil, read_outside: true, change: nil}
    :ok = call(repo, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})
    :ok = call(repo, {:delivered, heal.id, heal.lease_token, at(7, 32)})
    {job, heal}
  end

  defp watching!(repo, failed_at, decision) do
    {job, heal} = concluded!(repo, failed_at, decision)
    {:ok, %{state: "watching"}} = call(repo, {:get, heal.id})
    {job, heal}
  end

  defp create_job!(repo) do
    {:ok, job} =
      Registry.create_job(
        %{
          name: "Harbour tide table #{System.unique_integer([:positive])}",
          schedule: "every 1 hour",
          timezone: "UTC",
          task_prompt: "Fetch this morning's tides.",
          created_by_trust: "operator"
        },
        repo: repo,
        now: @created,
        scheduler: nil
      )

    job
  end

  defp claim_run!(repo, job, now) do
    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{System.unique_integer([:positive])}",
      trigger: "manual",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }

    patch = %{state: "running", next_run_at: DateTime.add(now, 86_400, :second), updated_at: now}
    {:ok, {_job, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: repo)
    run
  end

  defp fail(repo, run, at, kind, text) do
    attrs =
      Map.merge(run, %{
        status: "error",
        error: text,
        failure_kind: kind,
        completed_at: at,
        updated_at: at,
        heal_facts: %{failure_text: text, provider: nil}
      })

    Repo.settle_job_run(attrs, {:failed, :other}, server: repo)
  end
end
