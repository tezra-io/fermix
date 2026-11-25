defmodule FermixCore.Tools.UpdateJobTimeLimitTest do
  # M106 §5.6: `update_job` gains a time limit for the owner's own turns, with
  # the check `schedule_job` applies to one (a positive whole number of
  # seconds), and `list_jobs` shows a job's heal with what its diagnosis
  # decided, its note and a stored proposal, so the owner's assistant can
  # answer from the record.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.ListJobs
  alias FermixCore.Tools.UpdateJob

  @created ~U[2031-03-03 06:00:00.000000Z]
  @failed_at ~U[2031-03-04 07:10:00.000000Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-update-job-limit-#{unique}.db")
    repo = :"update_job_limit_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    context = %{
      agent_name: "main",
      memory_repo: repo,
      memory_agent_id: "main",
      conversation_key: {"telegram", "40017", :root},
      session_id: "telegram:40017:root",
      source_trust: :operator,
      computer_use_origin: :interactive,
      chat_type: "private",
      outside_sources: MapSet.new(),
      scheduler: nil
    }

    %{repo: repo, context: context}
  end

  describe "update_job's time limit" do
    test "sets a job's limit in seconds", %{repo: repo, context: context} do
      job = create_job!(repo)

      assert {:ok, %{success: true, output: output}} =
               UpdateJob.execute(%{"job_id" => job.id, "timeout_seconds" => 1_200}, context)

      assert Jason.decode!(output)["timeout_seconds"] == 1_200
      assert {:ok, %{timeout_seconds: 1_200}} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "refuses what schedule_job refuses, and changes nothing", %{repo: repo, context: context} do
      job = create_job!(repo)

      for bad <- [0, -5, "an hour", 1.5] do
        assert {:ok, %{success: false, error: error}} =
                 UpdateJob.execute(%{"job_id" => job.id, "timeout_seconds" => bad}, context)

        assert error =~ "timeout_seconds"
      end

      assert {:ok, %{timeout_seconds: 600}} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "the registry takes it, and refuses a limit that is not positive", %{repo: repo} do
      job = create_job!(repo)

      assert {:ok, %{timeout_seconds: 900}} =
               Registry.update_job(job.id, %{timeout_seconds: 900}, repo: repo, scheduler: nil)

      assert {:error, _reason} =
               Registry.update_job(job.id, %{timeout_seconds: 0}, repo: repo, scheduler: nil)
    end

    test "the registry checks an edit without writing it", %{repo: repo} do
      job = create_job!(repo)

      assert {:ok, %{schedule_expr: "every 2 hours"}} =
               Registry.check_update(job.id, %{schedule: "every 2 hours"}, repo: repo)

      assert {:error, _reason} =
               Registry.check_update(job.id, %{schedule: "whenever it suits"}, repo: repo)

      assert {:ok, %{schedule_expr: "every 1 hour"}} =
               Repo.get_scheduled_job(job.id, server: repo)
    end
  end

  # The note's text is read only through `get_job_run`, as outside content
  # (M106 S4, round two): `list_jobs` says that one exists.
  test "list_jobs shows a heal's decision, that it has a note, and a stored proposal", %{
    repo: repo,
    context: context
  } do
    job = create_job!(repo)
    heal_id = open_heal!(repo, job)
    {:ok, %{lease_token: token}} = claim(repo, DateTime.add(@failed_at, 1_200, :second))

    plan = %{
      decision: "propose",
      note: "Point the task at the new harbour page.",
      read_outside: true,
      change: %{
        "task" => %{"from" => job.task_prompt, "to" => "Fetch the tides from the new page."},
        "schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"}
      },
      change_job_version: job.updated_at
    }

    at = DateTime.add(@failed_at, 1_260, :second)
    :ok = Repo.job_heals_call({:decided, heal_id, token, plan, at}, server: repo)
    :ok = Repo.job_heals_call({:delivered, heal_id, token, at}, server: repo)

    assert {:ok, %{success: true, output: output}} = ListJobs.execute(%{}, context)
    [listed] = Jason.decode!(output)["jobs"]

    refute output =~ "new harbour page"

    assert %{
             "state" => "waiting",
             "decision" => "propose",
             "has_note" => true,
             "proposal" => %{
               "task" => "Fetch the tides from the new page.",
               "schedule" => "every 2 hours"
             }
           } = listed["heal"]
  end

  defp create_job!(repo) do
    {:ok, job} =
      Registry.create_job(
        %{
          name: "Harbour tide table #{System.unique_integer([:positive])}",
          schedule: "every 1 hour",
          timezone: "UTC",
          task_prompt: "Fetch this morning's tides.",
          timeout_seconds: 600,
          created_by_trust: "operator"
        },
        repo: repo,
        now: @created,
        scheduler: nil
      )

    job
  end

  defp open_heal!(repo, job) do
    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_20310304_071000_a1b2c3",
      trigger: "schedule",
      status: "queued",
      claimed_at: @failed_at,
      delivery_status: "none",
      created_at: @failed_at,
      updated_at: @failed_at
    }

    {:ok, {_job, run}} =
      Repo.claim_job_now(job.id, %{state: "running", updated_at: @failed_at}, run_attrs,
        server: repo
      )

    attrs =
      Map.merge(run, %{
        status: "timeout",
        error: "wall-clock timeout after 600000ms",
        failure_kind: "time_limit",
        completed_at: @failed_at,
        updated_at: @failed_at,
        heal_facts: %{failure_text: "wall-clock timeout after 600000ms", provider: nil}
      })

    {:ok, {_run, _job, %{heal: {:opened, heal_id}}}} =
      Repo.settle_job_run(attrs, {:failed, :other}, server: repo)

    heal_id
  end

  defp claim(repo, now),
    do: Repo.job_heals_call({:claim, now, DateTime.add(now, 300, :second)}, server: repo)
end
