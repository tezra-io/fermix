defmodule FermixCore.ComputerHistory.PurgeFenceLogTest do
  @moduledoc """
  CH-2: the spool insert's purge fence is never silent. A row it refuses only
  lowers `written`, so the refused count is logged (counts only, §15.1).
  """
  # async: false — the case lowers ComputerHistorySql's Logger module level
  # (global VM state) to see its :info line, which the Repo process emits;
  # config/test.exs pins the level to :warning.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-fence-log-#{unique}.db")
    repo_name = :"ch_fence_log_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    previous = Logger.get_module_level(ComputerHistorySql)
    Logger.put_module_level(ComputerHistorySql, :info)

    on_exit(fn ->
      restore_module_level(previous)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp restore_module_level([{ComputerHistorySql, level}]),
    do: Logger.put_module_level(ComputerHistorySql, level)

  defp restore_module_level([]), do: Logger.delete_module_level(ComputerHistorySql)

  defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

  test "fenced rows are counted in the log, and a batch with none logs nothing", %{repo: repo} do
    assert {:ok, _purged} = Purge.purge({:last, 2_000}, now: 2_000, repo: repo)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, 1} =
                 Repo.computer_history_insert_events(
                   [event(1, 1_000), event(2, 1_500), event(3, 3_000)],
                   server: repo
                 )
      end)

    assert log =~ "computer_history spool insert fenced 2 event(s) stamped inside a purged window"

    quiet =
      capture_log([level: :info], fn ->
        assert {:ok, 1} = Repo.computer_history_insert_events([event(4, 4_000)], server: repo)
      end)

    refute quiet =~ "fenced"
  end
end
