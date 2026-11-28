defmodule FermixCore.Jobs.HealDecisionVersionTest do
  # M106 §5.6, §5.7 (stage S4): the version of a job a heal's move or
  # proposal is drawn for is the job's definition: every field an owner's
  # edit, pause or resume can write, less the ones a run also writes. Owned
  # by one function (`HealDecision.job_version/1`) over one list, which this
  # test holds to the store's own list of owner-writable fields, so a new
  # editable field fails here until the version takes it. A run's claim and
  # settle move no version; an edit, a pause and a resume each do. Every
  # value is invented.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo

  @created ~U[2031-03-03 06:00:00.000000Z]
  @at ~U[2031-03-04 07:10:00.000000Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-heal-version-#{unique}.db")
    repo = :"memory_repo_heal_version_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    {:ok, job} =
      Registry.create_job(
        %{
          name: "Harbour tide table",
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

    %{repo: repo, job: job}
  end

  test "every field an owner's write can set is in the version, or is one a run writes too" do
    assert Enum.sort(Repo.owner_job_fields()) ==
             Enum.sort(HealDecision.version_fields() ++ HealDecision.run_written_fields())

    assert HealDecision.run_written_fields() == [:next_run_at, :state, :updated_at]
  end

  test "two reads of a job no write touched give one version", %{repo: repo, job: job} do
    {:ok, again} = Repo.get_scheduled_job(job.id, server: repo)
    assert HealDecision.job_version(again) == HealDecision.job_version(job)
  end

  test "a run's claim and settle move no version", %{repo: repo, job: job} do
    run_attrs = %{
      id: "run_version",
      job_id: job.id,
      session_id: "cron_#{job.id}_version",
      trigger: "schedule",
      status: "queued",
      claimed_at: @at,
      delivery_status: "none",
      created_at: @at,
      updated_at: @at
    }

    patch = %{state: "running", next_run_at: DateTime.add(@at, 3_600, :second), updated_at: @at}
    {:ok, {claimed, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: repo)
    assert HealDecision.job_version(claimed) == HealDecision.job_version(job)

    later = DateTime.add(@at, 60, :second)
    attrs = Map.merge(run, %{status: "ok", completed_at: later, updated_at: later})
    {:ok, {_run, settled, _settlement}} = Repo.settle_job_run(attrs, :ok, server: repo)

    assert settled.updated_at != job.updated_at
    assert HealDecision.job_version(settled) == HealDecision.job_version(job)
  end

  test "an edit, a pause and a resume each move it", %{repo: repo, job: job} do
    {:ok, paused} = Registry.pause_job(job.id, repo: repo, scheduler: nil)
    refute HealDecision.job_version(paused) == HealDecision.job_version(job)

    {:ok, resumed} = Registry.resume_job(job.id, repo: repo, scheduler: nil, now: @at)
    refute HealDecision.job_version(resumed) == HealDecision.job_version(paused)

    {:ok, edited} =
      Registry.update_job(job.id, %{timeout_seconds: 1_200}, repo: repo, scheduler: nil, now: @at)

    refute HealDecision.job_version(edited) == HealDecision.job_version(resumed)
  end

  test "each field of the version moves it", %{job: job} do
    for field <- HealDecision.version_fields() do
      moved = Map.update!(job, field, &other/1)
      refute HealDecision.job_version(moved) == HealDecision.job_version(job), "#{field}"
    end
  end

  defp other(value) when is_boolean(value), do: not value
  defp other(value) when is_integer(value), do: value + 1
  defp other(value) when is_list(value), do: ["tide_lookup" | value]
  defp other(nil), do: "set"
  defp other(value) when is_map(value), do: Map.put(value, "platform", "signal")
  defp other(value) when is_binary(value), do: value <> " moved"
end
