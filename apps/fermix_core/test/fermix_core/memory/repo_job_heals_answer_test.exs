defmodule FermixCore.Memory.RepoJobHealsAnswerTest do
  # M106 §5.6, §5.7 and decision D5 (stage S4) at the store: a job write that
  # belongs to a heal is one operation (`Repo.heal_job_write/5`), in one
  # transaction, fenced on the caller's right to the heal (a heal run's lease,
  # or the owner's answer to a waiting proposal, which records where it came
  # from) and on the job being the version the move or change was drawn for;
  # it writes the job as an owner's edit does and the heal (the heal run's
  # decision, or the answer and the move to watching), both or neither. A
  # leave closes the heal skipped, quiet for seven days; an edit, a pause or a
  # resume while a proposal waits closes it superseded in its own write, and a
  # run moves no version. An owner's write while a heal run diagnoses marks
  # the heal, and its move then writes nothing (JOB-12). Every time is given
  # and every value invented.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  @created ~U[2031-03-03 06:00:00.000000Z]
  @lease_s 300
  @change %{"task" => %{"from" => "Fetch this morning's tides.", "to" => "Fetch the tides."}}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heal-answer-#{unique}.db")
    repo = :"memory_repo_job_heal_answer_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  describe "an apply" do
    test "writes exactly the fields and moves the heal to watching, with the answer", ctx do
      {job, heal} = waiting!(ctx)

      assert {:ok, {:written, applied, moved}} =
               apply_change(ctx, heal, job, %{task_prompt: "Fetch the tides."}, at(9, 0))

      assert applied.task_prompt == "Fetch the tides."
      assert applied.schedule_expr == job.schedule_expr
      assert %{state: "watching", answer: "apply", decided_from: "mobile:quay-phone"} = moved
      assert DateTime.compare(moved.answered_at, at(9, 0)) == :eq
      assert DateTime.compare(moved.applied_at, at(9, 0)) == :eq
      assert DateTime.compare(moved.waiting_since, at(9, 0)) == :eq

      assert {:ok, ^moved} = call(ctx, {:get, heal.id})
      assert {:ok, ^applied} = Repo.get_scheduled_job(job.id, server: ctx.repo)
    end

    test "a second apply finds nothing waiting and writes nothing", ctx do
      {job, heal} = waiting!(ctx)
      {:ok, {:written, applied, _moved}} = apply_change(ctx, heal, job, task(), at(9, 0))

      assert {:error, :not_waiting} =
               apply_change(ctx, heal, job, %{task_prompt: "Something else."}, at(9, 5))

      assert {:ok, ^applied} = Repo.get_scheduled_job(job.id, server: ctx.repo)
    end

    test "the job's change and the heal's move roll back together", ctx do
      for {trigger, table} <- [
            {"fail_heal_move", "job_heals"},
            {"fail_job_write", "scheduled_jobs"}
          ] do
        {job, heal} = waiting!(ctx)
        refuse_updates!(ctx, trigger, table)

        assert {:error, _reason} = apply_change(ctx, heal, job, task(), at(9, 0))

        assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: ctx.repo)

        assert {:ok, %{state: "waiting", answer: nil, applied_at: nil}} =
                 call(ctx, {:get, heal.id})

        drop_trigger!(ctx, trigger)
      end
    end

    test "for a job whose definition moved, applies nothing and closes the heal superseded",
         ctx do
      {job, heal} = waiting!(ctx)
      # A write no edit's own path made: the version the apply is fenced on.
      raw!(ctx, "UPDATE scheduled_jobs SET schedule_expr = 'every 3 hours' WHERE id = ?", [job.id])

      assert {:ok, {:moved_on, closed}} = apply_change(ctx, heal, job, task(), at(9, 0))

      assert %{state: "closed", outcome: "superseded", answer: "apply", applied_at: nil} = closed
      assert DateTime.compare(closed.closed_at, at(9, 0)) == :eq
      assert {:ok, %{task_prompt: "Fetch this morning's tides."}} = get_job(ctx, job.id)
    end

    test "a proposal stored with no version is never applied", ctx do
      {job, heal} = waiting!(ctx)
      raw!(ctx, "UPDATE job_heals SET change_job_digest = NULL WHERE id = ?", [heal.id])

      assert {:ok, {:moved_on, _closed}} = apply_change(ctx, heal, job, task(), at(9, 0))
      assert {:ok, %{task_prompt: "Fetch this morning's tides."}} = get_job(ctx, job.id)
    end

    test "a heal that is not this job's waiting proposal is refused", ctx do
      {job, heal} = waiting!(ctx)
      {other, _other_heal} = waiting!(ctx)

      assert {:error, :not_waiting} = apply_change(ctx, heal, other, task(), at(9, 0))

      assert {:error, :not_waiting} =
               apply_change(ctx, %{heal | id: "jhl_none"}, job, task(), at(9, 0))

      assert {:ok, %{state: "waiting"}} = call(ctx, {:get, heal.id})
    end
  end

  describe "a leave" do
    test "closes the heal skipped, writes nothing to the job, and keeps the same failure quiet",
         ctx do
      {job, heal} = waiting!(ctx)

      assert {:ok, %{state: "closed", outcome: "skipped", answer: "leave"} = closed} =
               call(ctx, {:leave, heal.id, answer(at(9, 0))})

      assert DateTime.compare(closed.answered_at, at(9, 0)) == :eq
      assert closed.applied_at == nil
      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: ctx.repo)
      assert {:error, :not_waiting} = call(ctx, {:leave, heal.id, answer(at(9, 5))})

      six_days_on = DateTime.add(at(9, 0), 6 * 86_400, :second)
      assert {:ok, {_run, _job, %{heal: :quiet}}} = fail!(ctx, job, six_days_on)

      eight_days_on = DateTime.add(at(9, 0), 8 * 86_400, :second)
      assert {:ok, {_run, _job, %{heal: {:opened, _id}}}} = fail!(ctx, job, eight_days_on)
    end
  end

  describe "an edit while a proposal waits" do
    test "closes it superseded in the edit's own write, and says which", ctx do
      {job, heal} = waiting!(ctx)

      assert {:ok, edited, [id]} =
               Repo.update_scheduled_job_fields(
                 job.id,
                 %{schedule_expr: "every 3 hours", updated_at: at(9, 0)},
                 server: ctx.repo
               )

      assert id == heal.id
      assert edited.schedule_expr == "every 3 hours"

      assert {:ok, %{state: "closed", outcome: "superseded", answer: nil} = closed} =
               call(ctx, {:get, heal.id})

      assert DateTime.compare(closed.closed_at, at(9, 0)) == :eq
    end

    test "an edit whose supersede fails writes nothing", ctx do
      {job, heal} = waiting!(ctx)
      refuse_updates!(ctx, "fail_heal_close", "job_heals")

      assert {:error, _reason} =
               Repo.update_scheduled_job_fields(
                 job.id,
                 %{schedule_expr: "every 3 hours", updated_at: at(9, 0)},
                 server: ctx.repo
               )

      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: ctx.repo)
      assert {:ok, %{state: "waiting"}} = call(ctx, {:get, heal.id})
    end

    test "a run's claim and settle move no version: the apply still applies", ctx do
      {job, heal} = waiting!(ctx)

      # A failing run joins the waiting heal; its claim and settle rewrite the
      # job's state and times, never its definition.
      assert {:ok, {_run, _job, %{heal: {:joined, _id}}}} = fail!(ctx, job, at(8, 10))
      assert {:ok, %{state: "waiting"}} = call(ctx, {:get, heal.id})
      assert {:ok, {:written, _job, _heal}} = apply_change(ctx, heal, job, task(), at(9, 0))
    end

    test "a pause closes it superseded", ctx do
      {job, heal} = waiting!(ctx)

      assert {:ok, _paused, [id]} =
               Repo.update_scheduled_job_fields(
                 job.id,
                 %{enabled?: false, state: "paused", updated_at: at(8, 20)},
                 server: ctx.repo
               )

      assert id == heal.id
      assert {:ok, %{state: "closed", outcome: "superseded"}} = call(ctx, {:get, heal.id})
    end

    test "a resume closes it superseded", ctx do
      {job, heal} = waiting!(ctx, paused: true)

      assert {:ok, _resumed, [id]} =
               Repo.update_scheduled_job_fields(
                 job.id,
                 %{
                   enabled?: true,
                   state: "scheduled",
                   next_run_at: at(10, 0),
                   updated_at: at(8, 30)
                 },
                 server: ctx.repo
               )

      assert id == heal.id
      assert {:ok, %{state: "closed", outcome: "superseded"}} = call(ctx, {:get, heal.id})
    end
  end

  describe "a heal run's move" do
    test "writes the job and records the decision under the lease, together", ctx do
      {job, heal} = claimed!(ctx)
      record = move_record(job, "raise_limit")

      assert {:ok, {:written, moved_job, held}} =
               heal_move(ctx, heal, job, %{timeout_seconds: 1_200}, record)

      assert moved_job.timeout_seconds == 1_200
      assert %{state: "diagnosing", decision: "raise_limit", lease_token: token} = held
      assert token == heal.lease_token
      assert held.change == record.change
    end

    test "for a job that moved while the diagnosis ran, writes nothing at all", ctx do
      {job, heal} = claimed!(ctx)
      record = move_record(job, "raise_limit")
      raw!(ctx, "UPDATE scheduled_jobs SET timeout_seconds = 2700 WHERE id = ?", [job.id])

      assert {:ok, {:moved_on, %{decision: nil}}} =
               heal_move(ctx, heal, job, %{timeout_seconds: 1_200}, record)

      assert {:ok, %{timeout_seconds: 2_700}} = get_job(ctx, job.id)
      assert {:ok, %{decision: nil, state: "diagnosing"}} = call(ctx, {:get, heal.id})
    end

    test "the job's change and the decision's record roll back together", ctx do
      {job, heal} = claimed!(ctx)
      refuse_updates!(ctx, "fail_decision_record", "job_heals")

      assert {:error, _reason} =
               heal_move(
                 ctx,
                 heal,
                 job,
                 %{timeout_seconds: 1_200},
                 move_record(job, "raise_limit")
               )

      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: ctx.repo)
      drop_trigger!(ctx, "fail_decision_record")
      assert {:ok, %{decision: nil}} = call(ctx, {:get, heal.id})
    end

    # JOB-12: a compare by value cannot see A -> B -> A. An owner's write to the
    # job while its heal is diagnosing is seen when it happens, whatever value
    # it leaves, and the heal run's move then writes nothing.
    test "an owner's write during the diagnosis that leaves the value as read still blocks",
         ctx do
      {job, heal} = claimed!(ctx)
      record = move_record(job, "pause")

      {:ok, _paused, []} =
        Repo.update_scheduled_job_fields(
          job.id,
          %{enabled?: false, state: "paused", updated_at: at(7, 35)},
          server: ctx.repo
        )

      {:ok, resumed, []} =
        Repo.update_scheduled_job_fields(
          job.id,
          %{enabled?: true, state: "scheduled", updated_at: at(7, 36)},
          server: ctx.repo
        )

      assert HealDecision.job_version(resumed) == record.change_job_digest

      assert {:ok, {:moved_on, %{decision: nil}}} =
               heal_move(ctx, heal, job, %{enabled?: false, state: "paused"}, record)

      assert {:ok, %{enabled?: true, state: "scheduled"}} = get_job(ctx, job.id)
      assert {:ok, %{decision: nil, state: "diagnosing"}} = call(ctx, {:get, heal.id})
    end

    test "an owner's write before the claim does not block the move", ctx do
      job = create_job!(ctx.repo)
      {:ok, {_run, _job, %{heal: {:opened, _id}}}} = fail!(ctx, job, at(7, 10))

      {:ok, _edited, []} =
        Repo.update_scheduled_job_fields(
          job.id,
          %{description: "Tides for the quay.", updated_at: at(7, 20)},
          server: ctx.repo
        )

      {:ok, heal} = call(ctx, {:claim, at(7, 30), DateTime.add(at(7, 30), @lease_s, :second)})
      {:ok, job} = Repo.get_scheduled_job(job.id, server: ctx.repo)

      assert {:ok, {:written, %{timeout_seconds: 1_200}, _held}} =
               heal_move(
                 ctx,
                 heal,
                 job,
                 %{timeout_seconds: 1_200},
                 move_record(job, "raise_limit")
               )
    end

    test "the mark does not survive into the next claim", ctx do
      {job, heal} = claimed!(ctx)

      {:ok, _edited, []} =
        Repo.update_scheduled_job_fields(
          job.id,
          %{description: "Tides for the quay.", updated_at: at(7, 35)},
          server: ctx.repo
        )

      assert {:ok, %{owner_wrote_at: %DateTime{}}} = call(ctx, {:get, heal.id})

      later = DateTime.add(at(7, 30), @lease_s, :second)
      {:ok, retaken} = call(ctx, {:claim, later, DateTime.add(later, @lease_s, :second)})
      assert retaken.owner_wrote_at == nil
      {:ok, job} = Repo.get_scheduled_job(job.id, server: ctx.repo)

      assert {:ok, {:written, %{timeout_seconds: 1_200}, _held}} =
               heal_move(
                 ctx,
                 retaken,
                 job,
                 %{timeout_seconds: 1_200},
                 move_record(job, "raise_limit")
               )
    end

    test "a lease lost before the write leaves the job as it was", ctx do
      {job, heal} = claimed!(ctx)
      later = DateTime.add(at(7, 30), @lease_s, :second)

      {:ok, %{lease_token: retaken}} =
        call(ctx, {:claim, later, DateTime.add(later, @lease_s, :second)})

      assert retaken != heal.lease_token

      assert {:error, :lease_lost} =
               heal_move(
                 ctx,
                 heal,
                 job,
                 %{enabled?: false, state: "paused"},
                 move_record(job, "pause")
               )

      assert {:ok, ^job} = Repo.get_scheduled_job(job.id, server: ctx.repo)
    end
  end

  describe "after an apply" do
    test "the next clean run closes the heal healed", ctx do
      {job, heal} = waiting!(ctx)
      {:ok, {:written, _job, _moved}} = apply_change(ctx, heal, job, task(), at(9, 0))

      assert {:ok, {_run, _job, %{healed: [id]}}} = settle_ok!(ctx, job, at(10, 0))
      assert id == heal.id

      assert {:ok, %{state: "closed", outcome: "healed", answer: "apply"}} =
               call(ctx, {:get, heal.id})
    end

    test "the next failure reopens it once as the verdict, its change kept", ctx do
      {job, heal} = waiting!(ctx)
      {:ok, {:written, _job, _moved}} = apply_change(ctx, heal, job, task(), at(9, 0))

      assert {:ok, {_run, _job, %{heal: {:verdict, id}}}} = fail!(ctx, job, at(10, 0))
      assert id == heal.id

      assert {:ok, %{state: "open", conclusion: "verdict", decision: "propose", change: @change}} =
               call(ctx, {:get, heal.id})

      assert {:error, :not_waiting} = call(ctx, {:leave, heal.id, answer(at(10, 5))})
    end
  end

  describe "what list_jobs reads" do
    test "a waiting proposal, and after an answer what became of it", ctx do
      {applied_job, applied_heal} = waiting!(ctx)
      {left_job, left_heal} = waiting!(ctx)
      {edited_job, edited_heal} = waiting!(ctx)
      {waiting_job, waiting_heal} = waiting!(ctx)

      {:ok, {:written, _job, _heal}} =
        apply_change(ctx, applied_heal, applied_job, task(), at(9, 0))

      {:ok, _left} = call(ctx, {:leave, left_heal.id, answer(at(9, 0))})

      {:ok, _edited, [_id]} =
        Repo.update_scheduled_job_fields(
          edited_job.id,
          %{schedule_expr: "every 3 hours", updated_at: at(9, 0)},
          server: ctx.repo
        )

      assert {:ok, %{open: open, proposals: by_job}} = call(ctx, {:listed_by_job, at(9, 30)})

      assert %{state: "waiting", decision: "propose", answer: nil, change: @change} =
               by_job[waiting_job.id]

      assert by_job[waiting_job.id].id == waiting_heal.id
      assert open[waiting_job.id].id == waiting_heal.id

      assert %{state: "watching", answer: "apply", applied_at: %DateTime{}} =
               by_job[applied_job.id]

      assert %{state: "closed", outcome: "skipped", answer: "leave"} = by_job[left_job.id]
      assert by_job[left_job.id].id == left_heal.id
      assert %{state: "closed", outcome: "superseded", answer: nil} = by_job[edited_job.id]
      assert by_job[edited_job.id].id == edited_heal.id
      refute Map.has_key?(open, left_job.id)
      refute Map.has_key?(open, edited_job.id)

      # A closed proposal is shown for the seven days its quiet lasts, no longer.
      assert {:ok, %{proposals: later}} =
               call(ctx, {:listed_by_job, DateTime.add(at(9, 30), 8 * 86_400, :second)})

      refute Map.has_key?(later, left_job.id)
      assert Map.has_key?(later, applied_job.id)
    end

    test "a stored change this engine cannot read is shown as none, never raised on", ctx do
      {job, heal} = waiting!(ctx)
      raw!(ctx, "UPDATE job_heals SET change_json = '{not json' WHERE id = ?", [heal.id])

      assert {:ok, %{change: nil}} = call(ctx, {:get, heal.id})
      assert {:ok, %{open: open, proposals: by_job}} = call(ctx, {:listed_by_job, at(9, 30)})
      assert %{change: nil} = by_job[job.id]
      assert %{change: nil} = open[job.id]
    end
  end

  # --- fixtures ------------------------------------------------------------------

  defp at(hour, minute), do: DateTime.new!(~D[2031-03-04], Time.new!(hour, minute, 0, {0, 6}))

  defp task, do: %{task_prompt: "Fetch the tides."}

  defp answer(at), do: %{decided_from: "mobile:quay-phone", at: at}

  defp call(ctx, request), do: Repo.job_heals_call(request, server: ctx.repo)

  defp get_job(ctx, id), do: Repo.get_scheduled_job(id, server: ctx.repo)

  defp apply_change(ctx, heal, job, fields, now) do
    Repo.heal_job_write(
      heal.id,
      job.id,
      Map.put(fields, :updated_at, now),
      {:answer, answer(now)},
      server: ctx.repo
    )
  end

  defp heal_move(ctx, heal, job, fields, record) do
    now = at(7, 31)

    Repo.heal_job_write(
      heal.id,
      job.id,
      Map.put(fields, :updated_at, now),
      {:heal_run, heal.lease_token, record, now},
      server: ctx.repo
    )
  end

  # What a heal run records with a move it makes, drawn for `job` as read.
  defp move_record(job, decision) do
    change =
      if decision == "raise_limit",
        do: %{"timeout_seconds" => %{"from" => job.timeout_seconds, "to" => 1_200}}

    %{
      decision: decision,
      note: "Each run waits on the harbour page until the limit ends it.",
      read_outside: true,
      change: change,
      change_job_version: job.updated_at,
      change_job_digest: HealDecision.job_version(job)
    }
  end

  # A job of the owner's whose run failed, its heal claimed by a heal run.
  defp claimed!(ctx) do
    job = create_job!(ctx.repo)
    {:ok, {_run, _job, %{heal: {:opened, _id}}}} = fail!(ctx, job, at(7, 10))
    {:ok, heal} = call(ctx, {:claim, at(7, 30), DateTime.add(at(7, 30), @lease_s, :second)})
    {:ok, job} = Repo.get_scheduled_job(job.id, server: ctx.repo)
    {job, heal}
  end

  # A job of the owner's whose run failed, its heal diagnosed with a proposal
  # drawn for the job as it stood (paused first when `paused: true`), and its
  # message delivered: waiting.
  defp waiting!(ctx, opts \\ []) do
    {job, heal} = claimed!(ctx)

    if Keyword.get(opts, :paused, false),
      do:
        raw!(ctx, "UPDATE scheduled_jobs SET enabled = 0, state = 'paused' WHERE id = ?", [job.id])

    {:ok, job} = Repo.get_scheduled_job(job.id, server: ctx.repo)

    plan = %{
      decision: "propose",
      note: "Point the task at the new page.",
      read_outside: true,
      change: @change,
      change_job_version: job.updated_at,
      change_job_digest: HealDecision.job_version(job)
    }

    :ok = call(ctx, {:decided, heal.id, heal.lease_token, plan, at(7, 31)})
    :ok = call(ctx, {:delivered, heal.id, heal.lease_token, at(7, 32)})
    {:ok, %{state: "waiting"} = heal} = call(ctx, {:get, heal.id})
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

  defp fail!(ctx, job, at) do
    run = claim_run!(ctx.repo, job, DateTime.add(at, -60, :second))
    text = "wall-clock timeout after 600000ms"

    attrs =
      Map.merge(run, %{
        status: "timeout",
        error: text,
        failure_kind: "time_limit",
        completed_at: at,
        updated_at: at,
        heal_facts: %{failure_text: text, provider: nil}
      })

    Repo.settle_job_run(attrs, {:failed, :other}, server: ctx.repo)
  end

  defp settle_ok!(ctx, job, at) do
    run = claim_run!(ctx.repo, job, DateTime.add(at, -60, :second))

    attrs =
      Map.merge(run, %{status: "ok", completed_at: at, updated_at: at, final_response: "ok"})

    Repo.settle_job_run(attrs, :ok, server: ctx.repo)
  end

  # A trigger that aborts every update of `table`, so the transaction holding
  # that update has to roll back whatever it wrote before it.
  defp refuse_updates!(ctx, name, table) do
    raw!(
      ctx,
      "CREATE TRIGGER #{name} BEFORE UPDATE ON #{table} BEGIN " <>
        "SELECT RAISE(ABORT, 'refused by the test'); END",
      []
    )
  end

  defp drop_trigger!(ctx, name), do: raw!(ctx, "DROP TRIGGER #{name}", [])

  defp raw!(ctx, sql, params) do
    {:ok, conn} = Sqlite3.open(ctx.db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000;")
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, params)
      :done = Sqlite3.step(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)
    after
      Sqlite3.close(conn)
    end
  end
end
