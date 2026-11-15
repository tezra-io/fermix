defmodule FermixCore.ComputerHistory.PurgeFenceLogTest do
  @moduledoc """
  CH-2: the spool insert's purge fence is never silent. A row it refuses only
  lowers `written`, so the refused count is logged (counts only, §15.1).
  """
  # async: false — the case lowers ComputerHistorySql's Logger module level
  # (global VM state) to see its :info line, which the store process emits;
  # config/test.exs pins the level to :warning.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("ch-fence-log")
    repo_name = :"ch_fence_log_repo_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Repo, name: repo_name, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    spool = start_supervised!({Spool, name: nil, path: Path.join([dir, "device", "history.db"])})

    previous = Logger.get_module_level(ComputerHistorySql)
    Logger.put_module_level(ComputerHistorySql, :info)

    on_exit(fn ->
      restore_module_level(previous)
      FermixTestSupport.SafeRm.rm_rf(dir)
    end)

    %{repo: repo_name, spool: spool}
  end

  defp restore_module_level([{ComputerHistorySql, level}]),
    do: Logger.put_module_level(ComputerHistorySql, level)

  defp restore_module_level([]), do: Logger.delete_module_level(ComputerHistorySql)

  defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

  test "fenced rows are counted in the log, and a batch with none logs nothing",
       %{repo: repo, spool: spool} do
    assert {:ok, _purged} = Purge.purge({:last, 2_000}, now: 2_000, repo: repo, spool: spool)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, 1} =
                 Spool.insert_events(
                   [event(1, 1_000), event(2, 1_500), event(3, 3_000)],
                   server: spool
                 )
      end)

    assert log =~ "computer_history spool insert fenced 2 event(s) stamped inside a purged window"

    quiet =
      capture_log([level: :info], fn ->
        assert {:ok, 1} = Spool.insert_events([event(4, 4_000)], server: spool)
      end)

    refute quiet =~ "fenced"
  end
end
