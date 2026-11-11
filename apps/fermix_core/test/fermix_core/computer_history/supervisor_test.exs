defmodule FermixCore.ComputerHistory.SupervisorTest do
  @moduledoc """
  MILESTONE_32 §6.3; M97 §8.1 — the always-present, inert supervisor, its
  machine store and its always-supervised Retention child. Retention sweeps
  regardless of the enable bit (inv. 16); the supervisor's structure is checked
  via `init/1` so it never collides with the one the app tree already runs.
  """
  # async: false — two cases write the global `:fermix_core, :computer_history`
  # app env, which async siblings read live through `Config.current/0`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Retention
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Supervisor, as: HistorySupervisor
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("ch-supervisor")
    spool = start_supervised!({Spool, name: nil, path: Path.join([dir, "device", "history.db"])})
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)

    %{spool: spool, unique: unique}
  end

  defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

  defp restore_history(nil), do: Application.delete_env(:fermix_core, :computer_history)
  defp restore_history(value), do: Application.put_env(:fermix_core, :computer_history, value)

  defp child(children, id), do: Enum.find(children, &(&1.id == id))

  describe "supervisor structure" do
    test "supervises the machine store first, then the runtime children and Retention" do
      {:ok, {flags, children}} =
        HistorySupervisor.init(timer_enabled: false, engine_role: :primary)

      # rest_for_one so a DynamicSupervisor crash restarts the Controller after it,
      # and a store crash restarts everything that reads it.
      assert flags.strategy == :rest_for_one

      # The DynamicSupervisor child-spec id defaults to its :name.
      assert Enum.map(children, & &1.id) == [
               Spool,
               FermixCore.ComputerHistory.DynamicSupervisor,
               Controller,
               Retention
             ]
    end

    test "on the home, Retention sweeps the home's notes too" do
      {:ok, {_flags, children}} =
        HistorySupervisor.init(timer_enabled: false, engine_role: :primary)

      %{start: {Retention, :start_link, [opts]}} = child(children, Retention)
      assert Keyword.fetch!(opts, :repo) == Repo
    end

    # M97 §8.1: a computer records and sends, so it runs the same four children;
    # it keeps no notes, so its Retention has no home store.
    test "on a computer, the same children run and Retention has no home store" do
      {:ok, {_flags, children}} =
        HistorySupervisor.init(timer_enabled: false, engine_role: :device)

      assert length(children) == 4
      %{start: {Retention, :start_link, [opts]}} = child(children, Retention)
      assert Keyword.fetch!(opts, :repo) == nil
    end

    test "the machine store opens where it is told" do
      {:ok, {_flags, children}} =
        HistorySupervisor.init(
          timer_enabled: false,
          engine_role: :primary,
          spool_path: "/elsewhere/device/history.db"
        )

      assert %{start: {Spool, :start_link, [[path: "/elsewhere/device/history.db"]]}} =
               child(children, Spool)
    end

    test "exposes the DynamicSupervisor name" do
      assert HistorySupervisor.dynamic_supervisor() ==
               FermixCore.ComputerHistory.DynamicSupervisor
    end
  end

  describe "retention sweeps regardless of the enable bit (inv. 16)" do
    test "with history disabled, a sweep still evicts events past the window", %{spool: spool} do
      # The disabled posture — retention must still drain the spool. Restore the
      # previous value exactly: deleting turns a configured key into an absent
      # one for every later module in the VM.
      previous = Application.get_env(:fermix_core, :computer_history)
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      on_exit(fn -> restore_history(previous) end)

      now = 100_000
      window = 10_000

      assert {:ok, 2} =
               Spool.insert_events([event(1, now - 20_000), event(2, now - 5_000)],
                 server: spool
               )

      # cutoff = now - window = 90_000; the ts=80_000 row goes, ts=95_000 stays.
      assert {:ok, %{deleted: 1}} = Retention.sweep(now, window, server: spool)
      assert {:ok, 1} = Spool.count_events(server: spool)
      assert {:ok, 95_000} = Spool.oldest_event_ts(server: spool)
    end

    test "a disabled memory store is not a fault for the home's half", %{
      spool: spool,
      unique: unique
    } do
      disabled_repo = :"ch_disabled_repo_#{unique}"

      start_supervised!(
        Supervisor.child_spec(
          {Repo, name: disabled_repo, enabled: false, database_path: ":memory:"},
          id: disabled_repo
        )
      )

      name = :"ch_retention_disabled_#{unique}"

      log =
        capture_log(fn ->
          pid =
            start_supervised!(
              {Retention, name: name, repo: disabled_repo, spool: spool, timer_enabled: false}
            )

          send(pid, :tick)
          _ = :sys.get_state(pid)
        end)

      refute log =~ "failed"
    end
  end

  describe "the tick path drives a sweep" do
    test "a :tick evicts expired events even while disabled (inv. 16)", %{
      spool: spool,
      unique: unique
    } do
      # The tick path must sweep regardless of the enable bit, not just the
      # directly-called sweep/3.
      previous = Application.get_env(:fermix_core, :computer_history)
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      on_exit(fn -> restore_history(previous) end)

      now = System.system_time(:millisecond)
      # One event well past a 1s window, one fresh.
      assert {:ok, 2} =
               Spool.insert_events([event(1, now - 60_000), event(2, now)], server: spool)

      name = :"ch_retention_gen_#{unique}"

      pid =
        start_supervised!(
          {Retention, name: name, repo: nil, spool: spool, window_ms: 1_000, timer_enabled: false}
        )

      send(pid, :tick)
      # Synchronize on the GenServer so the tick has been processed.
      _ = :sys.get_state(pid)

      assert {:ok, 1} = Spool.count_events(server: spool)
    end
  end
end
