defmodule FermixTestSupport.HealCards do
  @moduledoc """
  A heal's proposal waiting on its card (M106 §5.7, D5), made through the
  store's own requests, as a heal run makes it: a failed run of one of the
  owner's jobs opens the heal, a claim takes it, the decision `propose` is
  recorded with its change against the job's version, the card is bound to a
  chat under a token the caller holds, and its send is marked delivered. No
  model and no channel. Every name and time is invented.
  """

  alias FermixCore.Cues.Proposals
  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  @created ~U[2031-03-03 06:00:00.000000Z]
  @failed_at ~U[2031-03-04 07:10:00.000000Z]
  @claimed_at ~U[2031-03-04 07:30:00.000000Z]
  @lease_s 300

  @doc "When the fixture's card was delivered: the time an answer may follow."
  @spec delivered_at() :: DateTime.t()
  def delivered_at, do: @claimed_at

  @doc """
  A job of the owner's and its heal's proposal, its card bound to `origin`
  (`%{platform, chat_id, user_id}`) and delivered. `opts`: `:change`
  (default a schedule change), `:job_name`, `:delivered` (false leaves the
  send pending, the token held). Returns `%{job, heal, token}`.
  """
  @spec waiting_card!(GenServer.server(), map(), keyword()) :: %{
          job: map(),
          heal: map(),
          token: String.t()
        }
  def waiting_card!(repo, origin, opts \\ []) do
    name =
      Keyword.get(opts, :job_name, "Harbour tide table #{System.unique_integer([:positive])}")

    job = create_job!(repo, name)
    {:ok, {_run, _job, %{heal: {:opened, _id}}}} = fail!(repo, job, @failed_at)

    {:ok, heal} =
      Repo.job_heals_call(
        {:claim, @claimed_at, DateTime.add(@claimed_at, @lease_s, :second)},
        server: repo
      )

    {:ok, job} = Repo.get_scheduled_job(job.id, server: repo)
    change = Keyword.get(opts, :change, schedule_change())

    plan = %{
      decision: "propose",
      note: "The harbour page moved, so each fetch waits until the limit ends it.",
      read_outside: true,
      change: change,
      change_job_version: job.updated_at,
      change_job_digest: HealDecision.job_version(job)
    }

    :ok =
      Repo.job_heals_call({:decided, heal.id, heal.lease_token, plan, @claimed_at}, server: repo)

    token = Proposals.new_token()
    card = %{token: token, digest: Proposals.digest(token), origin: origin}

    {:ok, ^token} =
      Repo.job_heals_call({:bind_card, heal.id, heal.lease_token, card, @claimed_at},
        server: repo
      )

    if Keyword.get(opts, :delivered, true) do
      :ok =
        Repo.job_heals_call({:delivered, heal.id, heal.lease_token, @claimed_at}, server: repo)
    end

    {:ok, heal} = Repo.job_heals_call({:get, heal.id}, server: repo)
    %{job: job, heal: heal, token: token}
  end

  @doc "The fixture's change: the schedule, every hour to every two."
  @spec schedule_change() :: map()
  def schedule_change, do: %{"schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"}}

  @doc "A failed run of `job` settled at `at`, as a scheduled run's timeout is."
  @spec fail!(GenServer.server(), map(), DateTime.t()) :: term()
  def fail!(repo, job, at) do
    run = claim_run!(repo, job, DateTime.add(at, -60, :second))
    text = "The run stopped at its 10-minute time limit."

    attrs =
      Map.merge(run, %{
        status: "timeout",
        error: text,
        failure_kind: "time_limit",
        completed_at: at,
        updated_at: at,
        heal_facts: %{failure_text: text, provider: nil}
      })

    Repo.settle_job_run(attrs, {:failed, :other}, server: repo)
  end

  @doc "A clean run of `job` settled at `at`."
  @spec settle_ok!(GenServer.server(), map(), DateTime.t()) :: term()
  def settle_ok!(repo, job, at) do
    run = claim_run!(repo, job, DateTime.add(at, -60, :second))

    attrs =
      Map.merge(run, %{status: "ok", completed_at: at, updated_at: at, final_response: "ok"})

    Repo.settle_job_run(attrs, :ok, server: repo)
  end

  defp create_job!(repo, name) do
    {:ok, job} =
      Registry.create_job(
        %{
          name: name,
          schedule: "every 1 hour",
          timezone: "UTC",
          task_prompt: "Read harbour.example/old and list each high tide.",
          timeout_seconds: 600,
          created_by_trust: "operator"
        },
        repo: repo,
        now: @created,
        scheduler: nil
      )

    job
  end

  defp claim_run!(repo, job, at) do
    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{System.unique_integer([:positive])}",
      trigger: "schedule",
      status: "queued",
      claimed_at: at,
      started_at: at,
      delivery_status: "none",
      created_at: at,
      updated_at: at
    }

    {:ok, {_job, run}} =
      Repo.claim_job_now(job.id, %{state: "running", updated_at: at}, run_attrs, server: repo)

    run
  end
end
