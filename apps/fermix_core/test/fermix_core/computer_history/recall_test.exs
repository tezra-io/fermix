defmodule FermixCore.ComputerHistory.RecallTest do
  @moduledoc "MILESTONE_32 §11 — recall reads derived summaries with tz-resolved windows."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Recall
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-recall-#{unique}.db")
    repo_name = :"ch_recall_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp memory(repo, from_ts, to_ts, attrs) do
    base = %{
      created_at: to_ts,
      provenance_from_ts: from_ts,
      provenance_to_ts: to_ts,
      summary: "worked on things",
      model: "ollama",
      event_count: 1
    }

    {:ok, _} = Repo.computer_history_insert_memory(Map.merge(base, attrs), server: repo)
  end

  @today ~U[2026-08-15 15:00:00Z]
  # Epoch ms inside 2026-08-15 (UTC).
  @today_from DateTime.to_unix(~U[2026-08-15 09:00:00Z], :millisecond)
  @today_to DateTime.to_unix(~U[2026-08-15 10:00:00Z], :millisecond)
  @last_week DateTime.to_unix(~U[2026-08-05 09:00:00Z], :millisecond)

  describe "recent_digest/1" do
    test "renders summary + structured artifacts, framed as untrusted data", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{
        summary: "read the quarterly report",
        titles: Jason.encode!(["Q3 Report — Docs"]),
        urls: Jason.encode!(["docs.google.com/x"])
      })

      digest = Recall.recent_digest(repo: repo)
      assert digest =~ "untrusted data"
      assert digest =~ "read the quarterly report"
      assert digest =~ "Q3 Report — Docs"
      assert digest =~ "docs.google.com/x"
    end

    test "returns nil when there is no activity", %{repo: repo} do
      assert Recall.recent_digest(repo: repo) == nil
    end
  end

  describe "access audit (§22.8)" do
    test "a non-empty digest read appends an access row; an empty one does not", %{repo: repo} do
      assert Recall.recent_digest(repo: repo) == nil
      assert {:ok, {0, nil}} = Repo.computer_history_access_stats(server: repo)

      memory(repo, @today_from, @today_to, %{summary: "wrote a design doc"})
      assert Recall.recent_digest(repo: repo) =~ "wrote a design doc"

      assert {:ok, {1, _last_ts}} = Repo.computer_history_access_stats(server: repo)
    end

    test "every successful query appends an access row, empty results included", %{repo: repo} do
      assert {:ok, "No recorded activity" <> _rest} =
               Recall.query("today", repo: repo, now: @today, timezone: "Etc/UTC")

      memory(repo, @today_from, @today_to, %{summary: "reviewed a PR"})

      assert {:ok, result} = Recall.query("today", repo: repo, now: @today, timezone: "Etc/UTC")
      assert result =~ "reviewed a PR"

      # One row for the empty read, one for the non-empty read.
      assert {:ok, {2, _last_ts}} = Repo.computer_history_access_stats(server: repo)
    end
  end

  describe "query/2 with tz-resolved windows" do
    test "today includes today's memory, excludes last week's", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "today's work"})
      memory(repo, @last_week, @last_week + 3_600_000, %{summary: "old work"})

      {:ok, result} = Recall.query("today", repo: repo, now: @today, timezone: "Etc/UTC")
      assert result =~ "today's work"
      refute result =~ "old work"
    end

    test "yesterday excludes today", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "today's work"})

      {:ok, result} = Recall.query("yesterday", repo: repo, now: @today, timezone: "Etc/UTC")
      refute result =~ "today's work"
      assert result =~ "No recorded activity"
    end

    test "an unrecognized window defaults to today", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "today's work"})
      {:ok, result} = Recall.query("gibberish", repo: repo, now: @today, timezone: "Etc/UTC")
      assert result =~ "today's work"
    end
  end
end
