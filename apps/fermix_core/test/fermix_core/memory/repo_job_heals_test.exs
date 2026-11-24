defmodule FermixCore.Memory.RepoJobHealsTest do
  # M106 §5.4: a failed run that is not retried opens a heal in its settle's
  # transaction, one per subject not closed; later failures of that subject
  # join it; an ok run closes it; the Scheduler claims one at a time under a
  # lease. Every time here is given, never read from a clock.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @created ~U[2026-11-20 06:00:00.000000Z]
  @first_run ~U[2026-11-20 07:00:00.000000Z]
  @lease_s 300

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heals-#{unique}.db")
    repo = :"memory_repo_job_heals_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  describe "the settle" do
    test "a failure of an operator's job that is not retried opens one heal", %{repo: repo} do
      job = create_job!(repo)
      run = claim!(repo, job, @first_run)

      assert {:ok, {_run, _job, settlement}} =
               fail(repo, run, {:failed, :other}, at(7, 10, 0), "time_limit",
                 failure_text: "wall-clock timeout after 600000ms"
               )

      assert %{disposition: :none, heal: {:opened, heal_id}, healed: []} = settlement
      assert {:ok, heal} = Repo.job_heals_call({:get, heal_id}, server: repo)

      assert %{
               subject_kind: "job",
               subject_id: subject_id,
               job_id: job_id,
               failure_kind: "time_limit",
               failure_text: "wall-clock timeout after 600000ms",
               state: "open",
               outcome: nil,
               run_count: 1,
               delivery_status: "pending",
               delivery_attempts: 0
             } = heal

      assert {subject_id, job_id} == {job.id, job.id}
      assert String.starts_with?(heal_id, "jhl_")
      assert DateTime.compare(heal.opened_at, at(7, 10, 0)) == :eq
      assert heal_runs(repo, heal_id) == [run.id]
    end

    test "a second failure of the job joins its heal, which counts it", %{repo: repo} do
      job = create_job!(repo)
      first = claim!(repo, job, @first_run)

      {:ok, {_r, _j, %{heal: {:opened, heal_id}}}} =
        fail(repo, first, {:failed, :other}, at(7, 10, 0))

      second = claim!(repo, job, at(8, 0, 0))

      assert {:ok, {_run, _job, %{heal: {:joined, ^heal_id}}}} =
               fail(repo, second, {:failed, :other}, at(8, 10, 0))

      assert {:ok, %{run_count: 2, state: "open"}} =
               Repo.job_heals_call({:get, heal_id}, server: repo)

      assert Enum.sort(heal_runs(repo, heal_id)) == Enum.sort([first.id, second.id])
    end

    test "a retried failure opens none, and the fourth in a row opens one", %{repo: repo} do
      job = create_job!(repo)
      run = claim!(repo, job, @first_run)

      assert {:ok, {_run, _job, %{disposition: :retry, heal: :none}}} =
               fail(repo, run, {:failed, :provider}, at(7, 0, 10), "provider_rate_limit",
                 provider: "openai"
               )

      run = retry_until_exhausted!(repo, job, at(7, 0, 40))

      assert {:ok, {_run, _job, %{disposition: :exhausted, heal: {:opened, heal_id}}}} =
               fail(repo, run, {:failed, :provider}, at(7, 20, 0), "provider_rate_limit",
                 provider: "openai"
               )

      assert {:ok, %{subject_kind: "provider", subject_id: "openai", job_id: nil}} =
               Repo.job_heals_call({:get, heal_id}, server: repo)
    end

    test "two jobs failing on one provider make one heal", %{repo: repo} do
      first_job = create_job!(repo)
      second_job = create_job!(repo)

      run = claim!(repo, first_job, @first_run)

      {:ok, {_r, _j, %{heal: {:opened, heal_id}}}} =
        fail(repo, run, {:failed, :other}, at(7, 10, 0), "provider_auth", provider: "anthropic")

      run = claim!(repo, second_job, @first_run)

      assert {:ok, {_run, _job, %{heal: {:joined, ^heal_id}}}} =
               fail(repo, run, {:failed, :other}, at(7, 12, 0), "provider_auth",
                 provider: "anthropic"
               )

      assert {:ok, %{run_count: 2}} = Repo.job_heals_call({:get, heal_id}, server: repo)
      assert open_heal_count(repo) == 1
    end

    test "a provider kind with no provider to name has the job for its subject", %{repo: repo} do
      job = create_job!(repo)
      run = claim!(repo, job, @first_run)

      {:ok, {_r, _j, %{heal: {:opened, heal_id}}}} =
        fail(repo, run, {:failed, :other}, at(7, 10, 0), "no_route", provider: nil)

      assert {:ok, %{subject_kind: "job", subject_id: subject}} =
               Repo.job_heals_call({:get, heal_id}, server: repo)

      assert subject == job.id
    end

    test "a guest's job opens none: its failure stays its own", %{repo: repo} do
      job = create_job!(repo, created_by_trust: "guest")
      run = claim!(repo, job, @first_run)

      assert {:ok, {_run, _job, %{heal: :out_of_scope}}} =
               fail(repo, run, {:failed, :other}, at(7, 10, 0))

      assert open_heal_count(repo) == 0
    end

    # The heal is the settle's last write: a heal that cannot be written takes
    # the run's final row and the job's release back with it.
    test "the settle and its heal roll back together", %{repo: repo, db_path: db_path} do
      job = create_job!(repo)
      run = claim!(repo, job, @first_run)
      seed_closed_heal(db_path, "jhl_seeded", "job", "job_other", "crashed", "healed", @first_run)

      raw(db_path, """
      INSERT INTO job_heal_runs (run_id, heal_id, job_id) VALUES ('#{run.id}', 'jhl_seeded', 'job_other');
      """)

      assert {:error, _reason} = fail(repo, run, {:failed, :other}, at(7, 10, 0))
      assert {:ok, %{status: "queued"}} = Repo.get_job_run(run.id, server: repo)
      assert {:ok, %{state: "running"}} = Repo.get_scheduled_job(job.id, server: repo)
      assert open_heal_count(repo) == 0
    end
  end

  describe "the quiet days" do
    test "a heal closed still failing, skipped or expired in the last 7 days keeps the same failure quiet",
         %{repo: repo, db_path: db_path} do
      for outcome <- ["expired", "skipped", "still_failing"] do
        job = create_job!(repo)

        seed_closed_heal(
          db_path,
          "jhl_#{outcome}",
          "job",
          job.id,
          "time_limit",
          outcome,
          at(7, 0, 0)
        )

        run = claim!(repo, job, @first_run)

        assert {:ok, {_run, _job, %{heal: :quiet}}} =
                 fail(
                   repo,
                   run,
                   {:failed, :other},
                   DateTime.add(at(7, 0, 0), 6 * 86_400, :second),
                   "time_limit"
                 )

        assert {outcome, open_heal_count(repo)} == {outcome, 0}
      end
    end

    test "another kind, an older close, or a heal closed healed opens as usual", %{
      repo: repo,
      db_path: db_path
    } do
      for {kind, outcome, closed_at} <- [
            {"crashed", "expired", at(7, 0, 0)},
            {"time_limit", "expired", DateTime.add(at(7, 0, 0), -8 * 86_400, :second)},
            {"time_limit", "healed", at(7, 0, 0)}
          ] do
        job = create_job!(repo)

        seed_closed_heal(
          db_path,
          "jhl_#{System.unique_integer([:positive])}",
          "job",
          job.id,
          kind,
          outcome,
          closed_at
        )

        run = claim!(repo, job, @first_run)

        assert {:ok, {_run, _job, %{heal: {:opened, _id}}}} =
                 fail(repo, run, {:failed, :other}, at(7, 30, 0), "time_limit")
      end
    end
  end

  describe "closing" do
    test "an ok run closes its job's heal and its provider's heal as healed", %{repo: repo} do
      job = create_job!(repo)
      other = create_job!(repo)

      run = claim!(repo, other, @first_run)

      {:ok, {_r, _j, %{heal: {:opened, provider_heal}}}} =
        fail(repo, run, {:failed, :other}, at(7, 10, 0), "provider_quota", provider: "openai")

      run = claim!(repo, job, @first_run)

      {:ok, {_r, _j, %{heal: {:opened, job_heal}}}} =
        fail(repo, run, {:failed, :other}, at(7, 10, 0))

      run = claim!(repo, job, at(8, 0, 0))
      attrs = finish(run, "ok", at(8, 5, 0)) |> Map.put(:heal_facts, %{provider: "openai"})

      assert {:ok, {_run, _job, %{heal: :none, healed: healed}}} =
               Repo.settle_job_run(attrs, :ok, server: repo)

      assert Enum.sort(healed) == Enum.sort([job_heal, provider_heal])

      for id <- [job_heal, provider_heal] do
        assert {:ok, %{state: "closed", outcome: "healed", closed_at: closed_at}} =
                 Repo.job_heals_call({:get, id}, server: repo)

        assert DateTime.compare(closed_at, at(8, 5, 0)) == :eq
      end
    end

    test "a heal waiting for 7 days closes as expired; a later one waits on", %{repo: repo} do
      [old, recent] =
        for minute <- [10, 20] do
          job = create_job!(repo)
          run = claim!(repo, job, @first_run)

          {:ok, {_r, _j, %{heal: {:opened, id}}}} =
            fail(repo, run, {:failed, :other}, at(7, minute, 0))

          id
        end

      for {id, delivered} <- [{old, at(7, 30, 0)}, {recent, at(9, 0, 0)}] do
        {:ok, %{id: ^id, lease_token: token}} = claim_heal(repo, delivered)
        assert :ok = Repo.job_heals_call({:delivered, id, token, delivered}, server: repo)
      end

      # Seven days after 8:00: the heal waiting since 7:30 has waited longer.
      seven_days_on = DateTime.add(at(8, 0, 0), 7 * 86_400, :second)

      assert {:ok, [%{id: ^old}]} =
               Repo.job_heals_call({:expire_waiting, seven_days_on}, server: repo)

      assert {:ok, %{state: "closed", outcome: "expired"}} =
               Repo.job_heals_call({:get, old}, server: repo)

      assert {:ok, %{state: "waiting"}} = Repo.job_heals_call({:get, recent}, server: repo)
    end
  end

  describe "the claim" do
    test "the oldest open heal whose delivery is due, moved to diagnosing under a lease", %{
      repo: repo
    } do
      [first, second] =
        for minute <- [10, 20] do
          job = create_job!(repo)
          run = claim!(repo, job, @first_run)

          {:ok, {_r, _j, %{heal: {:opened, id}}}} =
            fail(repo, run, {:failed, :other}, at(7, minute, 0))

          id
        end

      assert {:ok, %{id: ^first, state: "diagnosing", lease_token: token, lease_until: until}} =
               claim_heal(repo, at(7, 30, 0))

      assert is_binary(token)
      assert DateTime.compare(until, DateTime.add(at(7, 30, 0), @lease_s, :second)) == :eq
      assert {:ok, %{id: ^second}} = claim_heal(repo, at(7, 30, 0))
      assert {:ok, nil} = claim_heal(repo, at(7, 30, 0))
    end

    test "a lease that ran out is claimed again, and the old holder's writes land nowhere", %{
      repo: repo
    } do
      job = create_job!(repo)
      run = claim!(repo, job, @first_run)
      {:ok, {_r, _j, %{heal: {:opened, id}}}} = fail(repo, run, {:failed, :other}, at(7, 10, 0))

      {:ok, %{id: ^id, lease_token: old_token}} = claim_heal(repo, at(7, 30, 0))
      assert {:ok, nil} = claim_heal(repo, at(7, 34, 59))

      assert {:ok, %{id: ^id, lease_token: new_token}} =
               claim_heal(repo, DateTime.add(at(7, 30, 0), @lease_s, :second))

      refute new_token == old_token

      assert {:error, :lease_lost} =
               Repo.job_heals_call({:delivered, id, old_token, at(7, 36, 0)}, server: repo)

      assert {:ok, %{state: "diagnosing", delivery_status: "pending"}} =
               Repo.job_heals_call({:get, id}, server: repo)
    end

    test "a heal whose delivery backs off waits for its time", %{repo: repo} do
      job = create_job!(repo)
      run = claim!(repo, job, @first_run)
      {:ok, {_r, _j, %{heal: {:opened, id}}}} = fail(repo, run, {:failed, :other}, at(7, 10, 0))
      {:ok, %{lease_token: token}} = claim_heal(repo, at(7, 30, 0))

      failure = %{attempts: 1, next_delivery_at: at(7, 31, 0), error: "timeout"}

      assert :ok =
               Repo.job_heals_call({:delivery_failed, id, token, failure, at(7, 30, 30)},
                 server: repo
               )

      assert {:ok, %{state: "open", delivery_attempts: 1, last_delivery_error: "timeout"}} =
               Repo.job_heals_call({:get, id}, server: repo)

      assert {:ok, nil} = claim_heal(repo, at(7, 30, 59))
      assert {:ok, %{id: ^id}} = claim_heal(repo, at(7, 31, 0))
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

  # The claim moves the next run an hour on, as a due claim of this job would.
  defp claim!(repo, job, now) do
    patch = %{state: "running", next_run_at: DateTime.add(now, 3_600, :second), updated_at: now}

    {:ok, {_job, run}} =
      Repo.claim_job_now(job.id, patch, run_attrs(job, now, "manual"), server: repo)

    run
  end

  defp retry_until_exhausted!(repo, job, first_retry_at) do
    Enum.reduce(1..3, first_retry_at, fn attempt, retry_at ->
      {:ok, {_job, run}} =
        Repo.claim_retry_job(
          job.id,
          %{state: "running", updated_at: retry_at},
          run_attrs(job, retry_at, "retry"),
          retry_at,
          server: repo
        )

      if attempt == 3 do
        run
      else
        {:ok, {_r, _j, %{retry_at: next}}} =
          fail(repo, run, {:failed, :provider}, retry_at, "provider_rate_limit",
            provider: "openai"
          )

        next
      end
    end)
  end

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

  defp finish(run, status, at) do
    Map.merge(run, %{status: status, completed_at: at, updated_at: at})
  end

  defp fail(repo, run, settle_by, at, kind \\ "other", heal_facts \\ []) do
    attrs =
      run
      |> finish("error", at)
      |> Map.merge(%{error: "the run failed", failure_kind: kind})
      |> Map.put(
        :heal_facts,
        Map.merge(%{failure_text: "The run failed.", provider: nil}, Map.new(heal_facts))
      )

    Repo.settle_job_run(attrs, settle_by, server: repo)
  end

  defp claim_heal(repo, now),
    do: Repo.job_heals_call({:claim, now, DateTime.add(now, @lease_s, :second)}, server: repo)

  defp heal_runs(repo, heal_id) do
    {:ok, facts} = Repo.job_heals_call({:runs, heal_id}, server: repo)
    facts
  end

  defp open_heal_count(repo) do
    {:ok, open} = Repo.job_heals_call(:open_heals, server: repo)
    length(open)
  end

  defp seed_closed_heal(db_path, id, subject_kind, subject_id, kind, outcome, closed_at) do
    job_id = if subject_kind == "job", do: "'#{subject_id}'", else: "NULL"
    stamp = CuesSql.stamp(closed_at)

    raw(db_path, """
    PRAGMA foreign_keys = OFF;
    INSERT INTO job_heals (id, subject_kind, subject_id, job_id, failure_kind, failure_text,
      state, outcome, run_count, opened_at, updated_at, closed_at, delivery_status)
    VALUES ('#{id}', '#{subject_kind}', '#{subject_id}', #{job_id}, '#{kind}', 'The run failed.',
      'closed', '#{outcome}', 1, '#{stamp}', '#{stamp}', '#{stamp}', 'delivered');
    """)
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end
end
