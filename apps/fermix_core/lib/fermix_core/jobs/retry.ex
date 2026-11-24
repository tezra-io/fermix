defmodule FermixCore.Jobs.Retry do
  @moduledoc """
  Whether a failed scheduled run is run again (M106 §5.3), decided by code at
  the run's settle, from facts the settle's transaction read. Pure: the
  store keeps the result (`Memory.Repo.JobRetriesSql`).

  A run is retried only when both hold: no tool had started in it (a second
  run after a tool ran would repeat what the tool did), and its failure is one
  waiting can clear: the provider's (`Jobs.Failure.provider_failure?/1`, which
  the runner reads as `{:failed, :provider}`) or a run the Scheduler settled
  after its runner died or was never found (`:scheduler`).

  The delays are the cue run's: 30 s after the first such failure in a row,
  2 min after the second, 10 min after the third; the fourth is `:exhausted`.
  The count is of the job's consecutive retried failures, and an ok run,
  any other failure and `:exhausted` reset it.

  Only a job the due scan runs again on its own is retried (`interval` and
  `cron`), and only while it will run: enabled and `scheduled` once its run
  released it. A retry is never set at or after the job's next run, which is
  then the retry (the failure still counts), and a job that expires before
  both is not retried, so its failure is told.

  A one-off is left out: its claim consumes its instant and its release
  completes it in the same transaction, so a retry would need a one-off kept
  `scheduled` with no instant, which every path that ends a retry would then
  have to complete.
  """

  @delays_s [30, 120, 600]
  @max_retries length(@delays_s)
  @retried_kinds ["interval", "cron"]
  @settle_bys [:ok, {:failed, :provider}, {:failed, :other}, :scheduler]
  @retried_by [{:failed, :provider}, :scheduler]

  @typedoc "What a scheduled run's settle is told about how it ended."
  @type settle_by :: :ok | {:failed, :provider} | {:failed, :other} | :scheduler

  @type disposition :: :none | :retry | :exhausted

  @typedoc """
  The decision: `attempts` is the run's place in the job's run of retried
  failures (0 for `:none`), `retry_at` the time a `:retry` runs again, or nil
  when the job's next run is the retry.
  """
  @type settlement :: %{
          disposition: disposition(),
          attempts: non_neg_integer(),
          retry_at: DateTime.t() | nil
        }

  @type facts :: %{
          settle_by: settle_by(),
          tools_started?: boolean(),
          prior_attempts: non_neg_integer(),
          failed_at: DateTime.t(),
          job: %{
            schedule_kind: String.t(),
            enabled?: boolean(),
            state: String.t(),
            next_run_at: DateTime.t() | nil,
            expires_at: DateTime.t() | nil
          }
        }

  @doc "Every `settle_by` a scheduled run's settle takes."
  @spec settle_bys() :: [settle_by()]
  def settle_bys, do: @settle_bys

  @doc "The settlement for a failed or finished run's facts."
  @spec decide(facts()) :: settlement()
  def decide(
        %{
          settle_by: settle_by,
          tools_started?: started?,
          prior_attempts: prior,
          failed_at: %DateTime{}
        } = facts
      )
      when settle_by in @settle_bys and is_boolean(started?) and is_integer(prior) and prior >= 0 do
    cond do
      not retried?(facts) -> none()
      prior >= @max_retries -> %{disposition: :exhausted, attempts: prior + 1, retry_at: nil}
      true -> retry(facts)
    end
  end

  defp retried?(%{settle_by: settle_by, tools_started?: started?, job: job}),
    do: settle_by in @retried_by and not started? and runs_again?(job)

  defp runs_again?(job),
    do: job.schedule_kind in @retried_kinds and job.enabled? and job.state == "scheduled"

  defp retry(%{prior_attempts: prior, failed_at: failed_at, job: job}) do
    attempts = prior + 1
    retry_at = DateTime.add(failed_at, Enum.at(@delays_s, prior), :second)

    cond do
      before?(retry_at, job.next_run_at) and before?(retry_at, job.expires_at) ->
        %{disposition: :retry, attempts: attempts, retry_at: retry_at}

      next_run_before_expiry?(job) ->
        %{disposition: :retry, attempts: attempts, retry_at: nil}

      true ->
        none()
    end
  end

  defp before?(_at, nil), do: true
  defp before?(at, bound), do: DateTime.compare(at, bound) == :lt

  defp next_run_before_expiry?(%{next_run_at: nil}), do: false

  defp next_run_before_expiry?(%{next_run_at: next, expires_at: expires}),
    do: before?(next, expires)

  defp none, do: %{disposition: :none, attempts: 0, retry_at: nil}
end
