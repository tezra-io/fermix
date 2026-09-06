defmodule FermixCore.Meetings.SweepTest do
  # async: false — the "runs even when meetings are disabled" case establishes
  # the `:meetings` app env it depends on, and restores what was there.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Meetings.Store
  alias FermixCore.Meetings.Sweep
  alias FermixCore.Memory.Repo

  @created_at ~U[2026-08-17 09:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-meetings-sweep-#{unique}.db")
    repo_name = :"memory_repo_meetings_sweep_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "fails the rows a restart stranded and names them", %{repo: repo} do
    seed(repo, "mtg_00000000001", "capturing")
    seed(repo, "mtg_00000000002", "joining")
    seed(repo, "mtg_00000000003", "delivered")
    seed(repo, "mtg_00000000004", "denied")

    log = run_sweep(repo)

    assert {:ok, %{status: "failed", error: "daemon_restarted"} = swept} =
             Store.get("mtg_00000000001", server: repo)

    assert is_binary(swept.ended_at)

    assert {:ok, %{status: "failed", error: "daemon_restarted"}} =
             Store.get("mtg_00000000002", server: repo)

    assert {:ok, %{status: "delivered", error: nil}} = Store.get("mtg_00000000003", server: repo)
    assert {:ok, %{status: "denied", error: nil}} = Store.get("mtg_00000000004", server: repo)

    assert log =~ "mtg_00000000001"
    assert log =~ "mtg_00000000002"
    refute log =~ "mtg_00000000003"
  end

  test "says nothing when no meeting was interrupted", %{repo: repo} do
    seed(repo, "mtg_00000000005", "delivered")

    assert run_sweep(repo) == ""
    assert {:ok, %{status: "delivered"}} = Store.get("mtg_00000000005", server: repo)
  end

  test "runs even for an install whose meetings are now disabled", %{repo: repo} do
    # The sweep is deliberately not gated on the enable toggle: rows stranded by
    # an install that has since been turned off are the ones nobody returns for.
    prior = Application.get_env(:fermix_core, :meetings)
    Application.put_env(:fermix_core, :meetings, enabled: false)
    on_exit(fn -> restore_meetings(prior) end)

    seed(repo, "mtg_00000000006", "summarizing")
    run_sweep(repo)

    assert {:ok, %{status: "failed"}} = Store.get("mtg_00000000006", server: repo)
  end

  defp run_sweep(repo) do
    capture_log(fn ->
      {:ok, pid} = Sweep.start_link(store_opts: [server: repo])
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end)
  end

  defp seed(repo, id, status) do
    {:ok, _meeting} =
      Store.insert(
        %{
          id: id,
          platform: "meet",
          url: "https://meet.google.com/abc-defg-hij",
          title: nil,
          requested_by: "operator",
          origin_session_id: nil,
          created_at: @created_at
        },
        server: repo
      )

    {:ok, _row} = Store.update_status(id, status, %{}, server: repo)
  end

  defp restore_meetings(nil), do: Application.delete_env(:fermix_core, :meetings)
  defp restore_meetings(prior), do: Application.put_env(:fermix_core, :meetings, prior)
end
