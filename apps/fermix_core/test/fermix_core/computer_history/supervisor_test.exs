defmodule FermixCore.ComputerHistory.SupervisorTest do
  @moduledoc """
  MILESTONE_32 §6.3 — the always-present, inert supervisor and its
  always-supervised Retention child. Retention sweeps regardless of the enable
  bit (inv. 16); the supervisor's structure is checked via `init/2` so it never
  collides with the singleton the app tree may already run on macOS.
  """
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Retention
  alias FermixCore.ComputerHistory.Supervisor, as: HistorySupervisor
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-retention-#{unique}.db")
    repo_name = :"ch_retention_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name, unique: unique}
  end

  defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

  describe "supervisor structure" do
    test "always supervises Retention + Controller and owns a DynamicSupervisor" do
      {:ok, {flags, children}} = HistorySupervisor.init(timer_enabled: false)

      # rest_for_one so a DynamicSupervisor crash restarts the Controller after it.
      assert flags.strategy == :rest_for_one

      ids = Enum.map(children, & &1.id)
      assert Retention in ids
      assert Controller in ids
      # The DynamicSupervisor child-spec id defaults to its :name.
      assert FermixCore.ComputerHistory.DynamicSupervisor in ids
      # Ordered DynamicSupervisor → Controller → Retention (rest_for_one dependency).
      assert ids == [FermixCore.ComputerHistory.DynamicSupervisor, Controller, Retention]
      assert length(children) == 3
    end

    test "exposes the DynamicSupervisor name" do
      assert HistorySupervisor.dynamic_supervisor() ==
               FermixCore.ComputerHistory.DynamicSupervisor
    end
  end

  describe "retention sweeps regardless of the enable bit (inv. 16)" do
    test "with history disabled, a sweep still evicts events past the window", %{repo: repo} do
      # The disabled posture — retention must still drain the spool.
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      on_exit(fn -> Application.delete_env(:fermix_core, :computer_history) end)

      now = 100_000
      window = 10_000

      assert {:ok, 2} =
               Repo.computer_history_insert_events(
                 [event(1, now - 20_000), event(2, now - 5_000)],
                 server: repo
               )

      # cutoff = now - window = 90_000; the ts=80_000 row goes, ts=95_000 stays.
      assert {:ok, 1} = Retention.sweep(repo, now, window)
      assert {:ok, 1} = Repo.computer_history_count_events(server: repo)
      assert {:ok, 95_000} = Repo.computer_history_oldest_event_ts(server: repo)
    end

    test "a disabled memory store is not a fault", %{unique: unique} do
      disabled_repo = :"ch_disabled_repo_#{unique}"

      start_supervised!(
        Supervisor.child_spec(
          {Repo, name: disabled_repo, enabled: false, database_path: ":memory:"},
          id: disabled_repo
        )
      )

      assert {:error, :disabled} = Retention.sweep(disabled_repo, 100_000, 10_000)
    end
  end

  describe "the tick path drives a sweep" do
    test "a :tick evicts expired events even while disabled (inv. 16)", %{
      repo: repo,
      unique: unique
    } do
      # The tick path must sweep regardless of the enable bit, not just the
      # directly-called sweep/3.
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      on_exit(fn -> Application.delete_env(:fermix_core, :computer_history) end)

      now = System.system_time(:millisecond)
      # One event well past a 1s window, one fresh.
      assert {:ok, 2} =
               Repo.computer_history_insert_events(
                 [event(1, now - 60_000), event(2, now)],
                 server: repo
               )

      name = :"ch_retention_gen_#{unique}"

      pid =
        start_supervised!(
          {Retention, name: name, repo: repo, window_ms: 1_000, timer_enabled: false}
        )

      send(pid, :tick)
      # Synchronize on the GenServer so the tick has been processed.
      _ = :sys.get_state(pid)

      assert {:ok, 1} = Repo.computer_history_count_events(server: repo)
    end
  end
end
