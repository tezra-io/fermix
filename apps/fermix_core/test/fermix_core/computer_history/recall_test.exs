defmodule FermixCore.ComputerHistory.RecallTest do
  @moduledoc """
  MILESTONE_32 §11 — recall reads derived summaries with tz-resolved windows,
  dates every entry, spends its budget in whole entries, and says out loud when
  older entries were omitted.
  """
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

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)

  @today ~U[2026-08-15 15:00:00Z]
  # Epoch ms inside 2026-08-15 (UTC), within the 24h digest horizon of @today.
  @today_from DateTime.to_unix(~U[2026-08-15 09:00:00Z], :millisecond)
  @today_to DateTime.to_unix(~U[2026-08-15 10:00:00Z], :millisecond)
  @last_week DateTime.to_unix(~U[2026-08-05 09:00:00Z], :millisecond)

  defp digest(repo, opts \\ []) do
    Recall.recent_digest(opts ++ [repo: repo, now: @today, timezone: "Etc/UTC"])
  end

  defp query(repo, window, opts \\ []) do
    Recall.query(window, opts ++ [repo: repo, now: @today, timezone: "Etc/UTC"])
  end

  describe "recent_digest/1" do
    test "renders a dated summary and its pages, framed as untrusted data", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{
        summary: "read the quarterly report",
        titles: Jason.encode!(["Q3 Report — Docs"]),
        urls: Jason.encode!(["docs.google.com/x"])
      })

      text = digest(repo)
      assert text =~ "untrusted data"
      assert text =~ "Times are in Etc/UTC."
      assert text =~ "- [Aug 15 09:00–10:00] read the quarterly report"
      assert text =~ "(pages: Q3 Report — Docs)"
      # Apps and URLs belong to the explicit tool; the section carries pages only.
      refute text =~ "docs.google.com/x"
    end

    test "returns nil when there is no activity", %{repo: repo} do
      assert digest(repo) == nil
    end

    test "stale_recent: the only memory is older than the 24h horizon", %{repo: repo} do
      old = ms(~U[2020-01-02 03:04:05Z])
      memory(repo, old, old + 60_000, %{summary: "ancient work"})

      assert digest(repo) == nil
    end

    test "a window crossing local midnight names both days", %{repo: repo} do
      memory(repo, ms(~U[2026-08-14 23:50:00Z]), ms(~U[2026-08-15 00:20:00Z]), %{
        summary: "late night edits"
      })

      assert digest(repo) =~ "- [Aug 14 23:50–Aug 15 00:20] late night edits"
    end

    test "times render in the operator timezone, stated once", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "tz check"})

      text = digest(repo, timezone: "America/New_York")
      assert text =~ "Times are in America/New_York."
      assert text =~ "- [Aug 15 05:00–06:00] tz check"
    end

    test "an unusable timezone renders in UTC and the frame says so", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "tz typo"})

      # A space instead of an underscore: not an IANA zone.
      text = digest(repo, timezone: "America/New York")
      assert text =~ "Times are in Etc/UTC."
      refute text =~ "America/New York"
      assert text =~ "- [Aug 15 09:00–10:00] tz typo"
    end

    test "at most three pages, each clipped, and the summary intact", %{repo: repo} do
      titles = Enum.map(1..5, fn index -> "#{index}#{String.duplicate("t", 200)}" end)
      summary = String.duplicate("x", 900)
      memory(repo, @today_from, @today_to, %{summary: summary, titles: Jason.encode!(titles)})

      text = digest(repo)
      # A maximal entry (900-char summary + 3 clipped titles) fits the budget whole.
      assert text =~ summary
      assert text =~ "1#{String.duplicate("t", 79)}…"
      assert text =~ "3#{String.duplicate("t", 79)}…"
      refute text =~ "4t"
    end

    test "the budget drops the oldest entry instead of cutting one", %{repo: repo} do
      for index <- 1..3 do
        from = @today_from + index * 60_000
        memory(repo, from, from + 1_000, %{summary: "entry-#{index}. #{fat_summary()}"})
      end

      text = digest(repo)
      # Two ~640-char entries fit the 1,500-char cap; the oldest is dropped whole.
      assert text =~ "entry-3."
      assert text =~ "entry-2."
      refute text =~ "entry-1."
      # Nothing was cut inside an entry.
      refute text =~ "…"
    end

    test "an entry too wide for the budget is skipped, not the section", %{repo: repo} do
      # The newest row is a pre-cap legacy summary that cannot be shown whole;
      # the older ones behind it still can.
      memory(repo, @today_from + 3_000, @today_to + 3_000, %{
        summary: String.duplicate("o", 2_000)
      })

      memory(repo, @today_from + 2_000, @today_to + 2_000, %{summary: "second newest note"})
      memory(repo, @today_from + 1_000, @today_to + 1_000, %{summary: "third note"})

      text = digest(repo)
      assert text =~ "second newest note"
      assert text =~ "third note"
      refute text =~ String.duplicate("o", 100)
    end

    test "a stored summary wider than the whole section budget yields no section", %{repo: repo} do
      # A row written before the summary cap existed cannot be shown whole, and a
      # framed empty section is worse than none.
      memory(repo, @today_from, @today_to, %{summary: String.duplicate("o", 2_000)})

      assert digest(repo) == nil
      assert {:ok, {0, nil}} = Repo.computer_history_access_stats(server: repo)
    end

    defp fat_summary, do: String.duplicate("s", 600)
  end

  describe "access audit (§22.8)" do
    test "a non-empty digest read appends an access row; an empty one does not", %{repo: repo} do
      assert digest(repo) == nil
      assert {:ok, {0, nil}} = Repo.computer_history_access_stats(server: repo)

      memory(repo, @today_from, @today_to, %{summary: "wrote a design doc"})
      assert digest(repo) =~ "wrote a design doc"

      assert {:ok, {1, _last_ts}} = Repo.computer_history_access_stats(server: repo)
    end

    test "every successful query appends an access row, empty results included", %{repo: repo} do
      assert {:ok, "No recorded activity" <> _rest} = query(repo, "today")

      memory(repo, @today_from, @today_to, %{summary: "reviewed a PR"})

      assert {:ok, result} = query(repo, "today")
      assert result =~ "reviewed a PR"

      # One row for the empty read, one for the non-empty read.
      assert {:ok, {2, _last_ts}} = Repo.computer_history_access_stats(server: repo)
    end
  end

  describe "query/2 with tz-resolved windows" do
    test "today includes today's memory, excludes last week's", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "today's work"})
      memory(repo, @last_week, @last_week + 3_600_000, %{summary: "old work"})

      {:ok, result} = query(repo, "today")
      assert result =~ "today's work"
      refute result =~ "old work"
    end

    test "yesterday excludes today", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "today's work"})

      {:ok, result} = query(repo, "yesterday")
      refute result =~ "today's work"
      assert result =~ "No recorded activity"
    end

    test "an unrecognized window defaults to today", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{summary: "today's work"})
      {:ok, result} = query(repo, "gibberish")
      assert result =~ "today's work"
    end
  end

  describe "query/2 completeness" do
    test "each entry is dated and carries its apps, pages and urls", %{repo: repo} do
      memory(repo, @today_from, @today_to, %{
        summary: "reviewed a PR",
        apps: Jason.encode!(["com.apple.Safari"]),
        titles: Jason.encode!(["PR #12 — GitHub"]),
        urls: Jason.encode!(["github.com/x/y/pull/12"])
      })

      {:ok, result} = query(repo, "today")
      assert result =~ "Activity for today (1 entries):"

      assert result =~
               "- [Aug 15 09:00–10:00] reviewed a PR (apps: com.apple.Safari) " <>
                 "(pages: PR #12 — GitHub) (urls: github.com/x/y/pull/12)"
    end

    test "weekly_limit: the header names the true count and the newest shown", %{repo: repo} do
      base = ms(~U[2026-08-10 09:00:00Z])

      for index <- 1..41 do
        from = base + index * 60_000
        memory(repo, from, from + 1_000, %{summary: "entry-#{index}."})
      end

      {:ok, result} = query(repo, "this_week")

      assert result =~
               "Activity for this_week (41 entries; showing 40 — " <>
                 "ask for a narrower window for the rest):"

      assert result =~ "entry-41."
      refute result =~ "entry-1."

      {:ok, narrowed} = query(repo, "this_week", limit: 3)
      assert narrowed =~ "(41 entries; showing 3 —"
      assert narrowed =~ "entry-41."
      refute narrowed =~ "entry-38."
    end

    test "an oversized entry is skipped and the header counts what is shown", %{repo: repo} do
      memory(repo, @today_from + 3_000, @today_to + 3_000, %{
        summary: String.duplicate("o", 7_000)
      })

      memory(repo, @today_from + 2_000, @today_to + 2_000, %{summary: "second newest note"})
      memory(repo, @today_from + 1_000, @today_to + 1_000, %{summary: "third note"})

      {:ok, result} = query(repo, "today")
      assert result =~ "Activity for today (3 entries; showing 2 — "
      assert result =~ "second newest note"
      assert result =~ "third note"
      refute result =~ String.duplicate("o", 100)
    end

    test "the response budget drops whole entries, never part of one", %{repo: repo} do
      base = ms(~U[2026-08-15 08:00:00Z])

      for index <- 1..12 do
        from = base + index * 60_000
        memory(repo, from, from + 1_000, %{summary: "entry-#{index}. #{fat_summary()}"})
      end

      {:ok, result} = query(repo, "today")
      # 12 entries in the window, ~640 chars each: only the newest 9 fit 6,000.
      assert result =~ "(12 entries; showing 9 —"
      assert result =~ "entry-12."
      refute result =~ "entry-3."
      refute result =~ "…"
    end
  end
end
