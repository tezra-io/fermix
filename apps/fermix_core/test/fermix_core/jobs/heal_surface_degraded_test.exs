defmodule FermixCore.Jobs.HealSurfaceDegradedTest do
  # M106 §6, §5.8 (stage S5): what the owner's assistant can see of a run that
  # ended ok without working. `list_jobs` shows a plugin's heal on each job
  # that joined it, as it shows a provider's, with the plugin and the tool;
  # `get_job_run` shows a run's tool tally as names and numbers, and never the
  # tool's words, which reach a model only inside a heal run's frame.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.ListJobRuns
  alias FermixCore.Tools.ListJobs
  alias FermixTestSupport.SafeRm

  @created ~U[2031-03-03 06:00:00.000000Z]
  @words "needs reconnection: words-marker-8L"

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-heal-surface-degraded")
    repo = :"heal_surface_degraded_repo_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{repo: repo}
  end

  test "list_jobs shows a plugin's heal on each job that joined it, with the plugin and the tool",
       ctx do
    first = create_job!(ctx, "Harbour tide table")
    second = create_job!(ctx, "Morning brief")
    untouched = create_job!(ctx, "Anchor watch")
    trip!(ctx, first)
    trip!(ctx, second)

    jobs = list_jobs(ctx)

    for job <- [first, second] do
      assert %{
               "subject" => "plugin",
               "plugin" => "harbour_id",
               "tool" => "whoami",
               "failure_kind" => "tool_never_succeeded",
               "state" => "open"
             } = jobs[job.id]["heal"]
    end

    assert jobs[untouched.id]["heal"] == nil
  end

  test "get_job_run shows the run's tally as names and numbers, never its words", ctx do
    job = create_job!(ctx, "Harbour tide table")
    [tripped | _earlier] = trip!(ctx, job)

    output = execute(GetJobRun, %{"run_id" => tripped.id}, ctx)

    assert %{"tools" => [tool]} = Jason.decode!(output)

    assert tool == %{
             "name" => "whoami",
             "plugin" => "harbour_id",
             "succeeded" => 0,
             "failed" => 3,
             "unfinished" => 0
           }

    for tool <- [GetJobRun, ListJobRuns, ListJobs] do
      args = if tool == GetJobRun, do: %{"run_id" => tripped.id}, else: %{"job_id" => job.id}
      refute execute(tool, args, ctx) =~ "words-marker-8L"
    end
  end

  # Design §9: inside a heal run, a run's text someone else could have written
  # reaches the model only framed; every other caller sees it as before.
  test "inside a heal run the job tools frame a run's reply, error and prompt; elsewhere they do not",
       ctx do
    job = create_job!(ctx, "Harbour tide table")
    run = failed_run!(ctx, job)
    frame = ~s(<untrusted_tool_result source="job_run">)

    heal_run = %{
      memory_repo: ctx.repo,
      job_heal: %{id: "jhl_surface", job_id: job.id, reply_to: self(), ref: make_ref()}
    }

    owner_turn = %{memory_repo: ctx.repo}

    for {tool, args, pick} <- [
          {GetJobRun, %{"run_id" => run.id}, & &1},
          {ListJobRuns, %{"job_id" => job.id}, &hd(&1["runs"])}
        ] do
      framed = tool |> execute_in(args, heal_run) |> Jason.decode!() |> pick.()
      plain = tool |> execute_in(args, owner_turn) |> Jason.decode!() |> pick.()

      for field <- ["final_response", "error"] do
        assert String.starts_with?(framed[field], frame), "#{inspect(tool)} #{field}"
        assert plain[field] == run |> Map.fetch!(String.to_existing_atom(field))
      end

      assert framed["error"] =~ "error-marker-2Q"
      assert framed["final_response"] =~ "reply-marker-6W"
    end

    assert String.starts_with?(
             execute_in(GetJobRun, %{"run_id" => run.id}, heal_run)
             |> Jason.decode!()
             |> Map.fetch!("prompt_snapshot"),
             frame
           )
  end

  defp failed_run!(ctx, job) do
    at = %{@created | day: 4, hour: 6}
    run = claim_run!(ctx.repo, job.id, at)
    done = DateTime.add(at, 300, :second)

    attrs =
      Map.merge(run, %{
        status: "error",
        completed_at: done,
        updated_at: done,
        prompt_snapshot: "SYSTEM:\nCheck the harbour account.",
        final_response: "Partial answer, reply-marker-6W.",
        error: "The page said: error-marker-2Q",
        failure_kind: "other",
        heal_facts: %{failure_text: "The run failed.", provider: nil}
      })

    {:ok, {settled, _job, _settlement}} =
      Repo.settle_job_run(attrs, {:failed, :other}, server: ctx.repo)

    settled
  end

  defp execute_in(tool, args, context) do
    {:ok, %{success: true, output: output}} = tool.execute(args, context)
    output
  end

  # Three ok runs in which the plugin's `whoami` never succeeded, newest first.
  defp trip!(ctx, job) do
    for {hour, failed} <- [{6, 1}, {7, 2}, {8, 3}] do
      at = %{@created | day: 4, hour: hour}

      entry = %{
        "name" => "whoami",
        "plugin" => "harbour_id",
        "ok" => 0,
        "error" => failed,
        "unfinished" => 0,
        "last_error" => @words
      }

      run = claim_run!(ctx.repo, job.id, at)
      done = DateTime.add(at, 300, :second)

      attrs =
        Map.merge(run, %{
          status: "ok",
          completed_at: done,
          updated_at: done,
          final_response: "Checked.",
          tool_tally: [entry],
          heal_facts: %{provider: "anthropic"}
        })

      {:ok, {settled, _job, _settlement}} = Repo.settle_job_run(attrs, :ok, server: ctx.repo)
      settled
    end
    |> Enum.reverse()
  end

  defp create_job!(ctx, name) do
    attrs = %{
      name: name,
      schedule: "every 1 hour",
      timezone: "UTC",
      task_prompt: "Check which harbour account the job acts as.",
      created_by_trust: "operator"
    }

    {:ok, job} = Registry.create_job(attrs, repo: ctx.repo, now: @created, scheduler: nil)
    job
  end

  defp claim_run!(repo, job_id, at) do
    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job_id,
      session_id: "cron_#{job_id}_#{System.unique_integer([:positive])}",
      trigger: "schedule",
      status: "queued",
      claimed_at: at,
      started_at: at,
      delivery_status: "none",
      created_at: at,
      updated_at: at
    }

    patch = %{state: "running", updated_at: at}
    {:ok, {_job, run}} = Repo.claim_job_now(job_id, patch, run_attrs, server: repo)
    run
  end

  defp list_jobs(ctx) do
    execute(ListJobs, %{}, ctx)
    |> Jason.decode!()
    |> Map.fetch!("jobs")
    |> Map.new(&{&1["id"], &1})
  end

  defp execute(tool, args, ctx) do
    {:ok, %{success: true, output: output}} = tool.execute(args, %{memory_repo: ctx.repo})
    output
  end
end
