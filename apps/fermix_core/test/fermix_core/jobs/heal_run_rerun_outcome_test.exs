defmodule FermixCore.Jobs.HealRunRerunOutcomeTest do
  # M106 §5.5 (stage S3): what a heal records of its rerun's "run now" is
  # what the engine can support. `refused` only for what proves no run will
  # come of the ask: a reply that the job cannot run now (expired, paused or
  # disabled, gone, or a store that keeps nothing), a call that reached no
  # Scheduler, or a run never asked for because the check before it failed.
  # Everything that leaves a run possible (a call out of time, a Scheduler
  # that stopped while holding it, a store that timed out or was busy under
  # the claim, any reply it does not know) is `unanswered`, and the heal keeps
  # watching. Pure.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealRun

  @call {GenServer, :call,
         [:jobs_scheduler, {:run_now, "job_tides", ~U[2031-03-04 07:30:00Z]}, 50]}

  for {label, result, outcome} <- [
        {"a run started", {:ok, %{id: "run_7f3a"}}, "started"},
        {"a run already holds the job", {:error, :already_running}, "running"},
        {"the Scheduler answered not runnable", {:error, :not_runnable}, "refused"},
        {"the Scheduler answered expired", {:error, :expired}, "refused"},
        {"the job is gone", {:error, :not_found}, "refused"},
        {"the store keeps nothing", {:error, :disabled}, "refused"},
        {"the store timed out under the claim", {:error, :repo_timeout}, "unanswered"},
        {"the store was busy under the claim", {:error, :busy}, "unanswered"},
        {"a store error the Scheduler passed on", {:error, {:sqlite, "disk I/O error"}},
         "unanswered"},
        {"a reply of no known kind", {:error, "something else"}, "unanswered"},
        {"never asked: the cue rule refused it", {:not_asked, "This job runs on cues."},
         "refused"},
        {"never asked: the job is gone", {:not_asked, :not_found}, "refused"},
        {"never asked: the check's read timed out",
         {:not_asked,
          {:exit, {:timeout, {GenServer, :call, [:repo, {:get_scheduled_job, "j"}, 5]}}}},
         "refused"},
        {"never asked: the check's store was not there",
         {:not_asked,
          {:exit, {:noproc, {GenServer, :call, [:repo, {:get_scheduled_job, "j"}, 5]}}}},
         "refused"},
        {"no Scheduler under the name", {:exit, {:noproc, @call}}, "refused"},
        {"the call ran out of time", {:exit, {:timeout, @call}}, "unanswered"},
        {"the Scheduler was killed holding it", {:exit, {:killed, @call}}, "unanswered"},
        {"the Scheduler shut down holding it", {:exit, {:shutdown, @call}}, "unanswered"},
        {"the Scheduler restarted holding it", {:exit, {{:shutdown, :restart}, @call}},
         "unanswered"},
        {"the Scheduler stopped normally holding it", {:exit, {:normal, @call}}, "unanswered"},
        {"the Scheduler crashed holding it",
         {:exit, {{%RuntimeError{message: "boom"}, []}, @call}}, "unanswered"},
        {"an exit of no known shape", {:exit, :something_else}, "unanswered"}
      ] do
    test "#{label}: #{outcome}" do
      assert {unquote(outcome), facts} =
               HealRun.rerun_outcome(unquote(Macro.escape(result)), 50)

      assert is_map(facts)
    end
  end

  test "a started run names its run, and nothing else does" do
    assert {"started", %{run_id: "run_7f3a"}} =
             HealRun.rerun_outcome({:ok, %{id: "run_7f3a"}}, 50)

    for result <- [{:error, :not_runnable}, {:exit, {:timeout, @call}}, {:exit, {:killed, @call}}] do
      {_outcome, facts} = HealRun.rerun_outcome(result, 50)
      refute Map.has_key?(facts, :run_id)
    end
  end

  test "each unanswered call says which it was: out of time, or the Scheduler stopped" do
    assert {"unanswered", %{error: timed_out}} =
             HealRun.rerun_outcome({:exit, {:timeout, @call}}, 50)

    assert timed_out =~ "within 50ms"

    assert {"unanswered", %{error: stopped}} =
             HealRun.rerun_outcome({:exit, {{:shutdown, :restart}, @call}}, 50)

    assert stopped =~ "stopped while it held the request"
    assert stopped =~ "may still start"
  end

  test "a reply that cannot tell whether a run was claimed says so" do
    assert {"unanswered", %{error: error}} = HealRun.rerun_outcome({:error, :repo_timeout}, 50)
    assert error =~ "repo_timeout"
    assert error =~ "may still start"
  end

  test "a run never asked for says why, and that it was never asked" do
    reason = {:exit, {:timeout, {GenServer, :call, [:repo, {:get_scheduled_job, "j"}, 5]}}}

    assert {"refused", %{error: {:not_asked, ^reason}}} =
             HealRun.rerun_outcome({:not_asked, reason}, 50)
  end

  test "a call that reached no Scheduler says so" do
    assert {"refused", %{error: error}} = HealRun.rerun_outcome({:exit, {:noproc, @call}}, 50)
    assert inspect(error) =~ "noproc"
  end
end
