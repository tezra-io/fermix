defmodule FermixCore.SkillCuration.SchedulerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration.Scheduler

  setup do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-sc-scheduler-#{suffix}.db")
    repo = :"sc_scheduler_repo_#{suffix}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    task_supervisor = :"sc_scheduler_tasks_#{suffix}"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, task_supervisor: task_supervisor, suffix: suffix}
  end

  defp start_scheduler!(ctx, opts) do
    test_pid = self()

    start_supervised!(
      {Scheduler,
       [
         name: :"sc_scheduler_#{ctx.suffix}",
         repo: ctx.repo,
         task_supervisor: ctx.task_supervisor,
         timer_enabled: false,
         run_cycle_fun: fn opts ->
           send(test_pid, {:cycle_fired, opts})
           {:ok, %{}}
         end
       ]
       |> Keyword.merge(opts)}
    )
  end

  test "first boot initializes the state row without firing", ctx do
    scheduler = start_scheduler!(ctx, [])

    send(scheduler, :tick)
    _sync = :sys.get_state(scheduler)

    refute_receive {:cycle_fired, _opts}, 100

    # The tick created the row: the first cycle is a full cadence period out.
    assert {:ok, state} = Repo.ensure_skill_curation_state(DateTime.utc_now(), server: ctx.repo)
    assert state.status == "idle"
    assert state.last_cycle_at != nil
  end

  test "fires when the cadence is due", ctx do
    stale = DateTime.add(DateTime.utc_now(), -16 * 86_400, :second)
    assert {:ok, _} = Repo.ensure_skill_curation_state(stale, server: ctx.repo)

    scheduler = start_scheduler!(ctx, [])
    send(scheduler, :tick)

    assert_receive {:cycle_fired, opts}, 1_000
    assert Keyword.get(opts, :trigger) == :scheduled
    assert Keyword.get(opts, :repo) == ctx.repo
  end

  test "fires when a retry is due even though the cadence is not", ctx do
    now = DateTime.utc_now()
    assert {:ok, _} = Repo.ensure_skill_curation_state(now, server: ctx.repo)

    assert {:ok, _} =
             Repo.update_skill_curation_state(
               %{retry_at: DateTime.add(now, -60, :second)},
               now,
               server: ctx.repo
             )

    scheduler = start_scheduler!(ctx, [])
    send(scheduler, :tick)

    assert_receive {:cycle_fired, _opts}, 1_000
  end

  test "does not fire inside the cadence period", ctx do
    recent = DateTime.add(DateTime.utc_now(), -86_400, :second)
    assert {:ok, _} = Repo.ensure_skill_curation_state(recent, server: ctx.repo)

    scheduler = start_scheduler!(ctx, [])
    send(scheduler, :tick)
    _sync = :sys.get_state(scheduler)

    refute_receive {:cycle_fired, _opts}, 100
  end
end
