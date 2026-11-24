defmodule FermixCore.Jobs.RetryTest do
  # M106 §5.3: whether a failed scheduled run is run again, decided by code at
  # its settle. Pure: the facts in, the settlement out, no store.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Retry

  @failed_at ~U[2026-11-20 06:00:10.000000Z]
  @next_run ~U[2026-11-20 07:00:00Z]

  @job %{
    schedule_kind: "interval",
    enabled?: true,
    state: "scheduled",
    next_run_at: @next_run,
    expires_at: nil
  }

  defp facts(overrides) do
    Map.merge(
      %{
        settle_by: {:failed, :provider},
        tools_started?: false,
        prior_attempts: 0,
        failed_at: @failed_at,
        job: @job
      },
      Map.new(overrides)
    )
  end

  defp after_s(seconds), do: DateTime.add(@failed_at, seconds, :second)

  test "a provider failure or a run the Scheduler settled, before any tool, is retried" do
    for settle_by <- [{:failed, :provider}, :scheduler] do
      assert Retry.decide(facts(settle_by: settle_by)) ==
               %{disposition: :retry, attempts: 1, retry_at: after_s(30)}
    end
  end

  test "the ladder: 30 s, 2 min, 10 min, then the fourth in a row is exhausted" do
    for {prior, settlement} <- [
          {0, %{disposition: :retry, attempts: 1, retry_at: after_s(30)}},
          {1, %{disposition: :retry, attempts: 2, retry_at: after_s(120)}},
          {2, %{disposition: :retry, attempts: 3, retry_at: after_s(600)}},
          {3, %{disposition: :exhausted, attempts: 4, retry_at: nil}}
        ] do
      assert Retry.decide(facts(prior_attempts: prior)) == settlement, "after #{prior} retries"
    end
  end

  test "a run that is not retried: an ok run, another failure, or one after its first tool" do
    for overrides <- [
          [settle_by: :ok],
          [settle_by: {:failed, :other}],
          [tools_started?: true],
          [tools_started?: true, settle_by: :scheduler],
          [tools_started?: true, prior_attempts: 3]
        ] do
      assert Retry.decide(facts(overrides)) == %{disposition: :none, attempts: 0, retry_at: nil},
             inspect(overrides)
    end
  end

  # Only a job the due scan runs again on its own is retried, and only while it
  # will run: a one-off is consumed, a cue task and a follow-up run on their
  # watcher, and a paused or disabled job does not run.
  test "a job that would not run again is not retried" do
    for job <- [
          %{@job | schedule_kind: "once", next_run_at: nil},
          %{@job | schedule_kind: "cue", next_run_at: nil},
          %{@job | schedule_kind: "watcher", next_run_at: nil},
          %{@job | enabled?: false, state: "paused"},
          %{@job | state: "disabled"}
        ] do
      assert Retry.decide(facts(job: job)).disposition == :none, inspect(job)
    end

    assert Retry.decide(facts(job: %{@job | schedule_kind: "cron"})).disposition == :retry
  end

  # Never past the next occurrence: the next scheduled run is the retry, and
  # the failure still counts toward the ladder.
  test "a retry at or after the next run sets no time, and still counts" do
    for next_run_at <- [after_s(30), after_s(20)] do
      assert Retry.decide(facts(job: %{@job | next_run_at: next_run_at})) ==
               %{disposition: :retry, attempts: 1, retry_at: nil}
    end

    assert Retry.decide(facts(job: %{@job | next_run_at: after_s(31)})).retry_at == after_s(30)
  end

  # A job that expires before both the retry and its next run never runs
  # again, so its failure is told, never kept quiet.
  test "a job that expires before the retry and before its next run is not retried" do
    expiring = %{@job | next_run_at: after_s(3_600), expires_at: after_s(25)}
    assert Retry.decide(facts(job: expiring)).disposition == :none

    later = %{@job | next_run_at: after_s(3_600), expires_at: after_s(31)}
    assert Retry.decide(facts(job: later)).retry_at == after_s(30)

    next_first = %{@job | next_run_at: after_s(20), expires_at: after_s(25)}

    assert Retry.decide(facts(job: next_first)) == %{
             disposition: :retry,
             attempts: 1,
             retry_at: nil
           }
  end

  test "facts that are not a settle's are refused" do
    assert_raise FunctionClauseError, fn -> Retry.decide(facts(settle_by: :acted)) end
    assert_raise FunctionClauseError, fn -> Retry.decide(facts(prior_attempts: -1)) end
  end
end
