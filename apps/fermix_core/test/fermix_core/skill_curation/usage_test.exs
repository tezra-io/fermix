defmodule FermixCore.SkillCuration.UsageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration.Usage

  # Answers the Repo protocol just enough to accept the enabled? probe and then
  # fail the usage upsert, so the log-and-continue posture is observable.
  defmodule FailingRepo do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(:enabled?, _from, state), do: {:reply, true, state}

    def handle_call({:record_skill_usage, _name, _kind, _now}, _from, state) do
      {:reply, {:error, :disk_full}, state}
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-usage-#{suffix}.db")
    repo = :"usage_repo_#{suffix}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, suffix: suffix}
  end

  test "record_view and record_run upsert counters", %{repo: repo} do
    assert :ok = Usage.record_view("alpha", repo: repo)
    assert :ok = Usage.record_run("alpha", repo: repo)
    assert :ok = Usage.record_run("alpha", repo: repo)

    assert {:ok, usage} = Repo.get_skill_usage("alpha", server: repo)
    assert usage.views == 1
    assert usage.runs == 2
  end

  test "a failed upsert logs a warning and returns :ok", %{suffix: suffix} do
    failing = :"failing_usage_repo_#{suffix}"
    start_supervised!({FailingRepo, name: failing})

    log =
      capture_log(fn ->
        assert :ok = Usage.record_run("alpha", repo: failing)
      end)

    assert log =~ "skill_usage upsert failed for alpha (run)"
    assert log =~ "disk_full"
  end

  test "a disabled repo is a quiet no-op" do
    disabled = :"disabled_usage_repo_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: disabled, enabled: false, database_path: ":memory:"},
        id: :disabled_usage_repo
      )
    )

    log =
      capture_log(fn ->
        assert :ok = Usage.record_view("alpha", repo: disabled)
      end)

    refute log =~ "skill_usage"
  end

  test "an absent repo process is a quiet no-op" do
    assert :ok = Usage.record_view("alpha", repo: :usage_repo_never_started)
  end
end
