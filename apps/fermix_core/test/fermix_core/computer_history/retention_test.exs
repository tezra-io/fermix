defmodule FermixCore.ComputerHistory.RetentionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Retention
  alias FermixCore.ComputerHistory.Spool
  alias FermixTestSupport.StalledRepo

  @hour 3_600_000

  # A store stuck behind a long operation must cost a sweep, not a restart: the
  # next tick sweeps again, and every sweep is idempotent. Both halves: this
  # machine's raw store and the home's notes.
  test "a tick whose stores do not answer is skipped and retention keeps running" do
    repo = start_supervised!(Supervisor.child_spec(StalledRepo, id: :stalled_repo))
    spool = start_supervised!(Supervisor.child_spec(StalledRepo, id: :stalled_spool))
    name = :"retention_stalled_#{System.unique_integer([:positive])}"

    {pid, log} =
      with_log(fn ->
        start_supervised!(
          {Retention,
           name: name, repo: repo, spool: spool, timer_enabled: false, repo_timeout_ms: 50}
        )

        pid = Process.whereis(name)
        send(pid, :tick)
        _state = :sys.get_state(pid)
        pid
      end)

    assert Process.whereis(name) == pid

    for site <- ["retention sweep", "byte-ceiling sweep"] do
      assert log =~ "computer_history #{site} failed: :spool_timeout"
    end

    for site <- ["access-audit cap", "interval prune"] do
      assert log =~ "computer_history #{site} failed: :repo_timeout"
    end
  end

  # A computer has no home store: its retention sweeps its own raw store alone.
  test "with no home store, a tick sweeps the machine's store and nothing else" do
    spool = start_supervised!(Supervisor.child_spec(StalledRepo, id: :stalled_spool))
    name = :"retention_device_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        start_supervised!(
          {Retention,
           name: name, repo: nil, spool: spool, timer_enabled: false, repo_timeout_ms: 50}
        )

        send(Process.whereis(name), :tick)
        _state = :sys.get_state(Process.whereis(name))
      end)

    assert log =~ "computer_history retention sweep failed: :spool_timeout"
    refute log =~ "access-audit cap"
    refute log =~ "interval prune"
  end

  describe "the 48-hour sweep of this machine's store" do
    setup do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("ch-retention")

      spool =
        start_supervised!({Spool, name: nil, path: Path.join([dir, "device", "history.db"])})

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
      %{spool: spool}
    end

    defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

    test "an expired event goes, and one never sent is counted", %{spool: spool} do
      now = 100 * @hour

      {:ok, 3} =
        Spool.insert_events(
          [event(1, now - 50 * @hour), event(2, now - 49 * @hour), event(3, now - @hour)],
          server: spool
        )

      # The first was sent to the home; the second never was.
      :ok = Spool.advance(1, DateTime.utc_now(), "summarized", server: spool)

      log =
        capture_log(fn ->
          assert {:ok, %{deleted: 2, unsent: 1}} =
                   Retention.sweep(now, 48 * @hour, server: spool)
        end)

      assert log =~ "1 of them never sent to the home"
      assert {:ok, 1} = Spool.count_events(server: spool)
      assert {:ok, %{expired_unsent: 1}} = Spool.link(server: spool)
    end

    test "a sweep with nothing expired deletes nothing", %{spool: spool} do
      now = 100 * @hour
      {:ok, 1} = Spool.insert_events([event(1, now - @hour)], server: spool)
      assert {:ok, %{deleted: 0}} = Retention.sweep(now, 48 * @hour, server: spool)
      assert {:ok, %{expired_unsent: 0}} = Spool.link(server: spool)
    end
  end
end
