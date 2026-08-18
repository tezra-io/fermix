defmodule FermixCore.ComputerHistory.PurgeTest do
  @moduledoc "MILESTONE_32 §12 — owner purge (inv. 9)."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-purge-#{unique}.db")
    repo_name = :"ch_purge_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp event(seq, ts), do: %{boot_id: "b1", source_seq: seq, ts: ts, type: "app.activated"}

  defp memory(from_ts, to_ts) do
    %{
      created_at: to_ts,
      provenance_from_ts: from_ts,
      provenance_to_ts: to_ts,
      summary: "worked in an app",
      model: "ollama",
      event_count: 1
    }
  end

  describe "parse_window/1" do
    test "accepts minutes, hours, and all" do
      assert Purge.parse_window("10m") == {:ok, {:last, 600_000}}
      assert Purge.parse_window("1h") == {:ok, {:last, 3_600_000}}
      assert Purge.parse_window("24h") == {:ok, {:last, 86_400_000}}
      assert Purge.parse_window("all") == {:ok, :all}
    end

    test "rejects anything else" do
      assert Purge.parse_window("yesterday") == {:error, :invalid_window}
      assert Purge.parse_window("10s") == {:error, :invalid_window}
      assert Purge.parse_window("") == {:error, :invalid_window}
    end
  end

  describe "purge/2" do
    test "removes in-window events + intersecting memories, keeps the rest, sets the watermark",
         %{repo: repo} do
      assert {:ok, 2} =
               Repo.computer_history_insert_events([event(1, 1_000), event(2, 5_000)],
                 server: repo
               )

      {:ok, _} = Repo.computer_history_insert_memory(memory(900, 1_100), server: repo)
      {:ok, _} = Repo.computer_history_insert_memory(memory(4_000, 6_000), server: repo)

      # Window [0, 2000]: catches the ts=1000 event and the [900,1100] memory.
      assert {:ok, %{events: 1, memories: 1, from_ts: 0, to_ts: 2_000}} =
               Purge.purge({:last, 2_000}, now: 2_000, repo: repo)

      assert {:ok, 1} = Repo.computer_history_count_events(server: repo)
      assert {:ok, 5_000} = Repo.computer_history_oldest_event_ts(server: repo)
      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo)

      {:ok, state} = Repo.computer_history_fetch_state(server: repo)
      assert state.purge_watermark_ts == 2_000
    end

    test "purge all clears everything", %{repo: repo} do
      assert {:ok, 3} =
               Repo.computer_history_insert_events(
                 [event(1, 1_000), event(2, 5_000), event(3, 9_000)],
                 server: repo
               )

      {:ok, _} = Repo.computer_history_insert_memory(memory(1_000, 2_000), server: repo)

      assert {:ok, %{events: 3, memories: 1}} = Purge.purge(:all, now: 10_000, repo: repo)
      assert {:ok, 0} = Repo.computer_history_count_events(server: repo)
      assert {:ok, 0} = Repo.computer_history_count_memories(server: repo)
    end
  end
end
