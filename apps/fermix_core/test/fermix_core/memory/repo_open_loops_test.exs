defmodule FermixCore.Memory.RepoOpenLoopsTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Defaults

  @tz "America/New_York"
  @open_loops_version 43
  # Monday 2031-06-02, 10:00 EDT; June 2031 is EDT (UTC-4). Every value here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @m ~U[2031-06-11 04:00:00Z]
  # Saturday 2031-06-07, midnight EDT: the owner's local day the spends below fall in.
  @day_start ~U[2031-06-07 04:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-open-loops-repo-#{unique}.db")
    repo = :"open_loops_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path, unique: unique}
  end

  defp loop_id(n), do: "loop_" <> String.pad_leading(Integer.to_string(n), 11, "0")

  # Stored instants come back at the fixed-width microsecond precision.
  defp utc(%DateTime{microsecond: {value, _precision}} = at), do: %{at | microsecond: {value, 6}}

  # A medium loop (the 10th; slots the 7th, 9th and 11th at 09:00 EDT) in the
  # normalised shapes the Registry hands the Repo.
  defp attrs(n, overrides \\ %{}) do
    Map.merge(
      %{
        id: loop_id(n),
        agent_id: "main",
        owner_id: "default",
        dedupe_key: "send the harbourview grant report #{n}",
        intention: "Send the Harbourview grant report #{n}",
        why_it_matters: "the foundation releases the second tranche on receipt",
        matters_by_kind: "date",
        matters_by_date: ~D[2031-06-10],
        matters_by_time: nil,
        matters_by_at: @m,
        timezone: @tz,
        horizon_class: "medium",
        said_at: @now,
        source_channel: "telegram",
        source_chat_id: "40001",
        source_thread_scope: "root",
        next_touch_at: ~U[2031-06-07 13:00:00Z],
        delivery_platform: "telegram",
        delivery_destination: "40001",
        delivery_thread_scope: "root",
        created_at: @now
      },
      overrides
    )
  end

  defp create!(repo, n, overrides \\ %{}) do
    {:ok, {:created, row}} = Repo.create_open_loop(attrs(n, overrides), server: repo)
    row
  end

  # A due row claimed past its rung 1 window, as the scheduler claims it.
  defp claim!(repo, n) do
    {:ok, claimed} =
      Repo.claim_open_loop_checkin(loop_id(n), ~U[2031-06-07 16:30:00Z], server: repo)

    claimed
  end

  defp with_raw_conn(db_path, fun) do
    {:ok, conn} = Sqlite3.open(db_path)

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp query!(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  describe "migration 43" do
    test "a fresh database gets the table, its three indexes and the version", %{
      repo: repo,
      db_path: db_path
    } do
      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert @open_loops_version in versions

      with_raw_conn(db_path, fn conn ->
        indexes =
          conn
          |> query!(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'open_loops'"
          )
          |> List.flatten()

        for index <- ~w(idx_open_loops_due idx_open_loops_live_dedupe idx_open_loops_rung2_day) do
          assert index in indexes
        end

        refute "idx_open_loops_touch_day" in indexes

        columns = conn |> query!("PRAGMA table_info(open_loops)") |> Enum.map(&Enum.at(&1, 1))
        rung = Enum.find_index(columns, &(&1 == "last_touch_rung"))
        assert Enum.slice(columns, rung, 3) == ["last_touch_rung", "last_rung2_at", "last_answer"]
      end)
    end

    test "a database an engine at version 42 wrote gains the table on the next open", %{
      repo: repo,
      db_path: db_path
    } do
      :ok = stop_supervised(repo)

      with_raw_conn(db_path, fn conn ->
        :ok = Sqlite3.execute(conn, "DROP TABLE open_loops")
        :ok = Sqlite3.execute(conn, "ALTER TABLE cue_sources DROP COLUMN stop_reason")
        :ok = Sqlite3.execute(conn, "DROP TABLE harness_run_continuations")
        :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version > 42")
        assert [[42]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
      end)

      reopened = :"#{repo}_reopened"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert @open_loops_version in versions
      assert length(versions) == length(Enum.uniq(versions))
      assert {:ok, {:created, _row}} = Repo.create_open_loop(attrs(1), server: reopened)
    end

    test "opening the same database twice and migrating again changes nothing", %{
      repo: repo,
      db_path: db_path
    } do
      create!(repo, 1)
      :ok = stop_supervised(repo)

      again = :"#{repo}_again"
      start_supervised!({Repo, name: again, enabled: true, database_path: db_path})
      assert :ok = Repo.migrate(server: again)

      assert {:ok, versions} = Repo.migration_versions(server: again)
      assert Enum.count(versions, &(&1 == @open_loops_version)) == 1
      assert {:ok, %{id: "loop_00000000001"}} = Repo.get_open_loop(loop_id(1), server: again)
    end
  end

  describe "create and load" do
    test "a row saved from normalised shapes loads back with every column", %{repo: repo} do
      input = attrs(1, %{matters_by_kind: "datetime", matters_by_time: ~T[15:00:00]})
      input = %{input | matters_by_at: ~U[2031-06-10 19:00:00Z]}

      assert {:ok, {:created, created}} = Repo.create_open_loop(input, server: repo)
      assert {:ok, loaded} = Repo.get_open_loop(loop_id(1), server: repo)
      assert loaded == created

      assert loaded == %{
               id: "loop_00000000001",
               agent_id: "main",
               owner_id: "default",
               dedupe_key: "send the harbourview grant report 1",
               intention: "Send the Harbourview grant report 1",
               why_it_matters: "the foundation releases the second tranche on receipt",
               matters_by_kind: "datetime",
               matters_by_date: ~D[2031-06-10],
               matters_by_time: ~T[15:00:00],
               matters_by_at: utc(~U[2031-06-10 19:00:00Z]),
               timezone: @tz,
               horizon_class: "medium",
               said_at: utc(@now),
               source_channel: "telegram",
               source_chat_id: "40001",
               source_thread_scope: "root",
               state: "open",
               touches: 0,
               next_touch_at: utc(~U[2031-06-07 13:00:00Z]),
               claimed_at: nil,
               last_touch_at: nil,
               last_touch_rung: nil,
               last_rung2_at: nil,
               last_answer: nil,
               plan_at: nil,
               last_outcome: nil,
               last_outcome_at: nil,
               last_message: nil,
               delivery_platform: "telegram",
               delivery_destination: "40001",
               delivery_thread_scope: "root",
               closed_at: nil,
               close_reason: nil,
               revision: 1,
               created_at: utc(@now),
               updated_at: utc(@now)
             }
    end

    test "every settled column round-trips in its stored shape", %{repo: repo} do
      create!(repo, 1)

      changes = %{
        state: "asked",
        touches: 1,
        next_touch_at: ~U[2031-06-09 13:00:00Z],
        last_touch_at: ~U[2031-06-07 17:00:00Z],
        last_touch_rung: 2,
        last_outcome: "spoke",
        last_outcome_at: ~U[2031-06-07 17:00:00Z],
        last_message: "An invented check-in."
      }

      assert {:ok, settled} =
               Repo.settle_open_loop(loop_id(1), changes,
                 server: repo,
                 now: ~U[2031-06-07 17:00:01Z]
               )

      assert {:ok, ^settled} = Repo.get_open_loop(loop_id(1), server: repo)

      assert Map.take(settled, Map.keys(changes)) ==
               Map.new(changes, fn
                 {key, %DateTime{} = at} -> {key, utc(at)}
                 pair -> pair
               end)

      assert settled.revision == 2
      assert settled.updated_at == utc(~U[2031-06-07 17:00:01Z])
    end

    test "the same intention on a live loop returns the stored row and writes nothing", %{
      repo: repo
    } do
      first = create!(repo, 1)

      restated = attrs(2, %{dedupe_key: first.dedupe_key, intention: "Something said again"})
      assert {:ok, {:existing, existing}} = Repo.create_open_loop(restated, server: repo)
      assert existing == first

      assert {:error, :not_found} = Repo.get_open_loop(loop_id(2), server: repo)
      assert {:ok, 1} = Repo.count_live_open_loops("default", server: repo)
    end

    test "a closed loop's intention can be stated again as a new loop", %{repo: repo} do
      first = create!(repo, 1)
      closing = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _closed} = Repo.settle_open_loop(first.id, closing, server: repo, now: @now)

      assert {:ok, {:created, %{id: "loop_00000000002"}}} =
               Repo.create_open_loop(attrs(2, %{dedupe_key: first.dedupe_key}), server: repo)
    end

    test "the 21st live loop is refused", %{repo: repo} do
      for n <- 1..Defaults.max_live_loops(), do: create!(repo, n)

      assert {:error, :too_many_loops} = Repo.create_open_loop(attrs(21), server: repo)
      assert {:ok, 20} = Repo.count_live_open_loops("default", server: repo)

      # A restatement at the cap is still recognised, not refused.
      assert {:ok, {:existing, %{id: "loop_00000000003"}}} =
               Repo.create_open_loop(attrs(21, %{dedupe_key: attrs(3).dedupe_key}),
                 server: repo
               )

      # The cap is per owner.
      assert {:ok, {:created, _row}} =
               Repo.create_open_loop(attrs(22, %{owner_id: "another_owner"}), server: repo)
    end

    test "bounds and shapes are refused before the single writer", %{repo: repo} do
      too_long = String.duplicate("a", 501)

      assert {:error, {:invalid, :intention, :too_long}} =
               Repo.create_open_loop(attrs(1, %{intention: too_long}), server: repo)

      assert {:error, {:invalid, :horizon_class, :unsupported}} =
               Repo.create_open_loop(attrs(1, %{horizon_class: "weekly"}), server: repo)

      assert {:error, {:invalid, :id, :malformed}} =
               Repo.create_open_loop(attrs(1, %{id: "evt_1"}), server: repo)

      assert {:error, {:invalid, :matters_by_time, :required}} =
               Repo.create_open_loop(attrs(1, %{matters_by_kind: "datetime"}), server: repo)

      assert {:error, {:invalid, :last_message, :too_long}} =
               Repo.settle_open_loop(loop_id(1), %{last_message: String.duplicate("b", 1_801)},
                 server: repo
               )

      assert {:error, {:unknown_field, :owner_words}} =
               Repo.settle_open_loop(loop_id(1), %{owner_words: "done"}, server: repo)
    end
  end

  describe "settle_open_loop/3" do
    test "it bumps the revision, clears a claim, and is refused for a missing row", %{
      repo: repo
    } do
      create!(repo, 1)
      {:ok, _} = Repo.scan_due_open_loops(~U[2031-06-07 16:30:00Z], 50, server: repo)

      {:ok, claimed} =
        Repo.claim_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:30:00Z], server: repo)

      assert claimed.claimed_at == utc(~U[2031-06-07 16:30:00Z])

      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      assert {:ok, settled} = Repo.settle_open_loop(loop_id(1), done, server: repo, now: @now)
      assert settled.claimed_at == nil
      assert settled.revision == 2

      assert {:error, :not_found} =
               Repo.settle_open_loop(loop_id(9), done, server: repo, now: @now)
    end

    test "a closed or expired loop never reopens", %{repo: repo} do
      create!(repo, 1)
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, closed} = Repo.settle_open_loop(loop_id(1), done, server: repo, now: @now)

      reopen = %{state: "open", next_touch_at: ~U[2031-06-09 13:00:00Z]}
      assert {:error, :not_live} = Repo.settle_open_loop(loop_id(1), reopen, server: repo)
      assert {:ok, ^closed} = Repo.get_open_loop(loop_id(1), server: repo)

      create!(repo, 2)

      {:ok, %{expired: [_]}} =
        Repo.scan_due_open_loops(~U[2031-06-12 13:00:00Z], 50, server: repo)

      assert {:ok, %{state: "expired"}} = Repo.get_open_loop(loop_id(2), server: repo)
      assert {:error, :not_live} = Repo.settle_open_loop(loop_id(2), reopen, server: repo)
    end
  end

  describe "the check-in claim" do
    setup %{repo: repo} do
      create!(repo, 1)
      {:ok, %{due: [_]}} = Repo.scan_due_open_loops(~U[2031-06-07 16:30:00Z], 50, server: repo)
      :ok
    end

    test "only a due, unclaimed row can be claimed, once", %{repo: repo} do
      at = ~U[2031-06-07 16:30:00Z]

      assert {:ok, %{state: "due", claimed_at: claimed_at}} =
               Repo.claim_open_loop_checkin(loop_id(1), at, server: repo)

      assert claimed_at == utc(at)

      assert {:error, :not_claimable} =
               Repo.claim_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:31:00Z], server: repo)

      create!(repo, 2)

      assert {:error, :not_claimable} =
               Repo.claim_open_loop_checkin(loop_id(2), at, server: repo)
    end

    test "finalize writes only while the claim it holds still stands", %{repo: repo} do
      {:ok, %{claimed_at: claimed_at}} =
        Repo.claim_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:30:00Z], server: repo)

      silent = %{
        state: "open",
        next_touch_at: ~U[2031-06-09 13:00:00Z],
        last_outcome: "silent",
        last_outcome_at: ~U[2031-06-07 16:31:00Z]
      }

      assert {:error, :closed_meanwhile} =
               Repo.finalize_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:29:00Z], silent,
                 server: repo
               )

      assert {:ok, row} =
               Repo.finalize_open_loop_checkin(loop_id(1), claimed_at, silent,
                 server: repo,
                 now: ~U[2031-06-07 16:31:00Z]
               )

      assert %{state: "open", claimed_at: nil, last_outcome: "silent", revision: 2} = row
    end

    test "an owner's answer during the run makes the run's write closed_meanwhile", %{
      repo: repo
    } do
      {:ok, %{claimed_at: claimed_at}} =
        Repo.claim_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:30:00Z], server: repo)

      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _closed} = Repo.settle_open_loop(loop_id(1), done, server: repo, now: @now)

      spoke = %{
        state: "asked",
        touches: 1,
        next_touch_at: ~U[2031-06-09 13:00:00Z],
        last_touch_at: ~U[2031-06-07 16:31:00Z],
        last_touch_rung: 2,
        last_outcome: "spoke",
        last_outcome_at: ~U[2031-06-07 16:31:00Z],
        last_message: "An invented check-in."
      }

      assert {:error, :closed_meanwhile} =
               Repo.finalize_open_loop_checkin(loop_id(1), claimed_at, spoke, server: repo)

      assert {:ok, %{state: "closed", touches: 0}} = Repo.get_open_loop(loop_id(1), server: repo)
    end

    test "the boot sweep returns every stranded claim", %{repo: repo} do
      {:ok, _row} =
        Repo.claim_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:30:00Z], server: repo)

      assert {:ok, ["loop_00000000001"]} = Repo.sweep_open_loop_claims(server: repo)

      assert {:ok, %{state: "due", claimed_at: nil}} =
               Repo.get_open_loop(loop_id(1), server: repo)

      assert {:ok, []} = Repo.sweep_open_loop_claims(server: repo)
    end
  end

  describe "scan_due_open_loops/3" do
    test "arrived rows become due, passed slots skip or expire, the rest wait", %{repo: repo} do
      create!(repo, 1)
      create!(repo, 2, %{next_touch_at: ~U[2031-06-09 13:00:00Z]})
      asked = create!(repo, 3)
      create!(repo, 4)

      asked_once = %{
        state: "asked",
        touches: 1,
        next_touch_at: ~U[2031-06-09 13:00:00Z],
        last_touch_at: ~U[2031-06-07 13:30:00Z],
        last_touch_rung: 1
      }

      {:ok, _} = Repo.settle_open_loop(asked.id, asked_once, server: repo, now: @now)

      awaiting_handback = %{
        asked_once
        | touches: 2,
          next_touch_at: ~U[2031-06-11 13:00:00Z],
          last_touch_at: ~U[2031-06-09 13:30:00Z]
      }

      {:ok, _} = Repo.settle_open_loop(loop_id(4), awaiting_handback, server: repo, now: @now)

      # The daemon slept from the 2nd to 10:00 UTC on the 11th: the date has passed.
      now = ~U[2031-06-11 10:00:00Z]
      assert {:ok, result} = Repo.scan_due_open_loops(now, 50, server: repo)

      assert Enum.map(result.expired, & &1.id) |> Enum.sort() ==
               ["loop_00000000001", "loop_00000000002"]

      assert [%{id: "loop_00000000003", next_touch_at: handback}] = result.skipped_to_handback
      assert handback == utc(~U[2031-06-11 13:00:00Z])
      assert result.due == []

      for expired <- result.expired do
        assert %{state: "expired", close_reason: "expired", next_touch_at: nil} = expired
        assert expired.closed_at == utc(now)
      end

      assert {:ok, %{state: "asked", touches: 2}} = Repo.get_open_loop(loop_id(4), server: repo)
    end

    test "a skipped row comes due at its hand-back", %{repo: repo} do
      asked = create!(repo, 1)

      {:ok, _} =
        Repo.settle_open_loop(
          asked.id,
          %{
            state: "asked",
            touches: 1,
            next_touch_at: ~U[2031-06-09 13:00:00Z],
            last_touch_at: ~U[2031-06-07 13:30:00Z],
            last_touch_rung: 1
          },
          server: repo,
          now: @now
        )

      {:ok, %{skipped_to_handback: [_]}} =
        Repo.scan_due_open_loops(~U[2031-06-11 10:00:00Z], 50, server: repo)

      assert {:ok, %{due: [], expired: [], skipped_to_handback: []}} =
               Repo.scan_due_open_loops(~U[2031-06-11 12:00:00Z], 50, server: repo)

      assert {:ok, %{due: [%{id: "loop_00000000001", state: "due"}]}} =
               Repo.scan_due_open_loops(~U[2031-06-11 13:00:00Z], 50, server: repo)
    end

    test "the scan returns the due rows it left waiting and each expired row's prior state", %{
      repo: repo
    } do
      create!(repo, 1)
      create!(repo, 3, %{next_touch_at: ~U[2031-06-09 13:00:00Z]})
      {:ok, %{due: [_]}} = Repo.scan_due_open_loops(~U[2031-06-07 13:00:00Z], 50, server: repo)

      # Past the rung 1 window: the row is still due, so a rung 2 claim can see it.
      assert {:ok, %{due: [], waiting: [%{id: "loop_00000000001", state: "due"}]}} =
               Repo.scan_due_open_loops(~U[2031-06-07 17:00:00Z], 50, server: repo)

      # The daemon slept past the date: one due row and one open row expire.
      assert {:ok, result} = Repo.scan_due_open_loops(~U[2031-06-11 10:00:00Z], 50, server: repo)
      assert Enum.map(result.expired, & &1.id) |> Enum.sort() == [loop_id(1), loop_id(3)]
      assert result.expired_from == %{loop_id(1) => "due", loop_id(3) => "open"}
      assert result.waiting == []
    end

    test "a claimed row is left to its check-in", %{repo: repo} do
      create!(repo, 1)
      {:ok, %{due: [_]}} = Repo.scan_due_open_loops(~U[2031-06-07 16:30:00Z], 50, server: repo)

      {:ok, _row} =
        Repo.claim_open_loop_checkin(loop_id(1), ~U[2031-06-07 16:30:00Z], server: repo)

      assert {:ok, %{due: [], expired: [], skipped_to_handback: [], waiting: []}} =
               Repo.scan_due_open_loops(~U[2031-06-12 13:00:00Z], 50, server: repo)
    end
  end

  describe "the scheduler's reads" do
    test "next_open_loop_touch_at is the earliest moment a live row can move", %{repo: repo} do
      assert {:ok, nil} = Repo.next_open_loop_touch_at(@now, server: repo)

      create!(repo, 1)
      create!(repo, 2, %{next_touch_at: ~U[2031-06-09 13:00:00Z]})

      assert {:ok, at} = Repo.next_open_loop_touch_at(@now, server: repo)
      assert at == utc(~U[2031-06-07 13:00:00Z])

      {:ok, _} = Repo.scan_due_open_loops(~U[2031-06-07 13:00:00Z], 50, server: repo)

      # The due row's window closes at 16:00; that is earlier than row 2's touch.
      assert {:ok, at} = Repo.next_open_loop_touch_at(~U[2031-06-07 14:00:00Z], server: repo)
      assert at == utc(~U[2031-06-07 16:00:00Z])
    end

    test "the due note sees due rows inside their window, for this owner and agent", %{
      repo: repo
    } do
      create!(repo, 1)
      create!(repo, 2, %{owner_id: "another_owner"})
      create!(repo, 3, %{agent_id: "other_agent"})
      {:ok, %{due: due}} = Repo.scan_due_open_loops(~U[2031-06-07 13:00:00Z], 50, server: repo)
      assert length(due) == 3

      assert {:ok, [%{id: "loop_00000000001"}]} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-07 15:59:59Z],
                 server: repo
               )

      assert {:ok, []} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-07 16:00:00Z],
                 server: repo
               )

      assert {:ok, [_]} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-07 16:30:00Z],
                 server: repo,
                 window_ms: 4 * 60 * 60 * 1000
               )
    end

    test "an imminent loop carries the due note until its date", %{repo: repo} do
      create!(repo, 1, %{
        horizon_class: "imminent",
        matters_by_date: ~D[2031-06-03],
        matters_by_at: ~U[2031-06-04 04:00:00Z],
        next_touch_at: @now
      })

      {:ok, %{due: [_]}} = Repo.scan_due_open_loops(@now, 50, server: repo)

      assert {:ok, [_]} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-04 03:59:59Z],
                 server: repo
               )

      assert {:ok, []} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-04 04:00:00Z],
                 server: repo
               )
    end

    test "list_open_loops reads live, closed or both, for one owner", %{repo: repo} do
      create!(repo, 1)
      create!(repo, 2, %{matters_by_at: ~U[2031-06-09 04:00:00Z]})
      create!(repo, 3)
      create!(repo, 4, %{owner_id: "another_owner"})
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _} = Repo.settle_open_loop(loop_id(3), done, server: repo, now: @now)

      assert {:ok, live} =
               Repo.list_open_loops(%{owner_id: "default", state: "live"}, server: repo)

      assert Enum.map(live, & &1.id) == ["loop_00000000002", "loop_00000000001"]

      assert {:ok, [%{id: "loop_00000000003"}]} =
               Repo.list_open_loops(%{owner_id: "default", state: "closed"}, server: repo)

      assert {:ok, any} = Repo.list_open_loops(%{owner_id: "default", state: "any"}, server: repo)
      assert length(any) == 3

      assert {:error, {:invalid, :state, :unsupported}} =
               Repo.list_open_loops(%{owner_id: "default", state: "due"}, server: repo)
    end
  end

  describe "the day's rung 2 budget" do
    setup %{repo: repo} do
      create!(repo, 1)
      create!(repo, 2)
      {:ok, %{due: [_, _]}} = Repo.scan_due_open_loops(~U[2031-06-07 13:00:00Z], 50, server: repo)
      :ok
    end

    test "the spend stamps the budget on the run's own claim and moves nothing else", %{
      repo: repo
    } do
      claimed = claim!(repo, 1)
      at = ~U[2031-06-07 16:31:00Z]

      assert {:error, :closed_meanwhile} =
               Repo.spend_open_loop_budget(
                 loop_id(1),
                 ~U[2031-06-07 16:29:00Z],
                 @day_start,
                 at,
                 server: repo
               )

      assert {:ok, spent} =
               Repo.spend_open_loop_budget(loop_id(1), claimed.claimed_at, @day_start, at,
                 server: repo
               )

      assert spent.last_rung2_at == utc(at)
      assert spent.updated_at == utc(at)
      # Still due, still claimed by the same run, the same revision: the spend
      # records no answer and no outcome.
      assert Map.drop(spent, [:last_rung2_at, :updated_at]) ==
               Map.drop(claimed, [:last_rung2_at, :updated_at])

      assert {:ok, ^spent} = Repo.get_open_loop(loop_id(1), server: repo)
    end

    test "the spend is refused once the run's claim no longer stands", %{repo: repo} do
      at = ~U[2031-06-07 16:31:00Z]

      assert {:error, :closed_meanwhile} =
               Repo.spend_open_loop_budget(
                 loop_id(1),
                 ~U[2031-06-07 16:30:00Z],
                 @day_start,
                 at,
                 server: repo
               )

      %{claimed_at: claimed_at} = claim!(repo, 1)
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _closed} = Repo.settle_open_loop(loop_id(1), done, server: repo, now: @now)

      assert {:error, :closed_meanwhile} =
               Repo.spend_open_loop_budget(loop_id(1), claimed_at, @day_start, at, server: repo)

      assert {:ok, %{state: "closed", last_rung2_at: nil}} =
               Repo.get_open_loop(loop_id(1), server: repo)

      assert {:error, :closed_meanwhile} =
               Repo.spend_open_loop_budget(loop_id(9), claimed_at, @day_start, at, server: repo)
    end

    test "the spend refuses a day another of the owner's loops already spent", %{repo: repo} do
      first = claim!(repo, 1)
      second = claim!(repo, 2)
      at = ~U[2031-06-07 16:31:00Z]

      assert {:ok, _spent} =
               Repo.spend_open_loop_budget(loop_id(1), first.claimed_at, @day_start, at,
                 server: repo
               )

      # Another loop, its own claim held, the same local day: refused, and the
      # row exactly as it was. The scheduler's one-run-per-owner rule is the
      # layer above; the single writer holds the day's invariant itself.
      assert {:error, :budget_spent} =
               Repo.spend_open_loop_budget(loop_id(2), second.claimed_at, @day_start, at,
                 server: repo
               )

      assert {:ok, ^second} = Repo.get_open_loop(loop_id(2), server: repo)

      # The next local day is unspent.
      next_day = ~U[2031-06-08 04:00:00Z]
      next_at = ~U[2031-06-08 16:31:00Z]

      assert {:ok, %{last_rung2_at: stamped}} =
               Repo.spend_open_loop_budget(loop_id(2), second.claimed_at, next_day, next_at,
                 server: repo
               )

      assert stamped == utc(next_at)

      # A claim that no longer stands is the first word, whatever the budget says.
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _closed} = Repo.settle_open_loop(loop_id(2), done, server: repo, now: @now)

      assert {:error, :closed_meanwhile} =
               Repo.spend_open_loop_budget(loop_id(2), second.claimed_at, next_day, next_at,
                 server: repo
               )
    end

    test "the budget is the owner's latest spend, whatever became of the loop", %{repo: repo} do
      day_start = ~U[2031-06-07 04:00:00Z]
      assert {:ok, false} = Repo.open_loop_budget_spent_since("default", day_start, server: repo)

      # A touch recorded at rung 2 is not the budget; only the spend before a send is.
      touched = %{
        state: "asked",
        touches: 1,
        next_touch_at: ~U[2031-06-09 13:00:00Z],
        last_touch_at: ~U[2031-06-07 13:30:00Z],
        last_touch_rung: 2
      }

      {:ok, _} = Repo.settle_open_loop(loop_id(2), touched, server: repo, now: @now)
      assert {:ok, false} = Repo.open_loop_budget_spent_since("default", day_start, server: repo)

      %{claimed_at: claimed_at} = claim!(repo, 1)
      sent_at = ~U[2031-06-07 16:31:00Z]

      {:ok, _} =
        Repo.spend_open_loop_budget(loop_id(1), claimed_at, day_start, sent_at, server: repo)

      assert {:ok, true} = Repo.open_loop_budget_spent_since("default", day_start, server: repo)

      spoke = %{
        touched
        | last_touch_at: sent_at,
          next_touch_at: ~U[2031-06-07 20:00:00Z]
      }

      {:ok, _} = Repo.finalize_open_loop_checkin(loop_id(1), claimed_at, spoke, server: repo)

      # A rung 1 raise later the same day rewrites the touch columns, never the spend.
      raised = %{touches: 2, last_touch_at: ~U[2031-06-07 20:30:00Z], last_touch_rung: 1}
      {:ok, _} = Repo.settle_open_loop(loop_id(1), raised, server: repo, now: @now)
      assert {:ok, true} = Repo.open_loop_budget_spent_since("default", day_start, server: repo)

      # Closing the loop does not refund the day's budget.
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _} = Repo.settle_open_loop(loop_id(1), done, server: repo, now: @now)
      assert {:ok, true} = Repo.open_loop_budget_spent_since("default", day_start, server: repo)

      next_day = ~U[2031-06-08 04:00:00Z]
      assert {:ok, false} = Repo.open_loop_budget_spent_since("default", next_day, server: repo)

      assert {:ok, false} =
               Repo.open_loop_budget_spent_since("another_owner", day_start, server: repo)
    end

    test "a settle can clear the budget but never stamp it", %{repo: repo} do
      %{claimed_at: claimed_at} = claim!(repo, 1)
      sent_at = ~U[2031-06-07 16:31:00Z]

      {:ok, _} =
        Repo.spend_open_loop_budget(loop_id(1), claimed_at, @day_start, sent_at, server: repo)

      assert {:error, {:invalid, :last_rung2_at, :unsupported}} =
               Repo.settle_open_loop(loop_id(2), %{last_rung2_at: sent_at}, server: repo)

      assert {:error, {:invalid, :last_rung2_at, :unsupported}} =
               Repo.finalize_open_loop_checkin(
                 loop_id(1),
                 claimed_at,
                 %{state: "due", last_rung2_at: sent_at},
                 server: repo
               )

      reset = %{
        state: "closed",
        close_reason: "dropped",
        closed_at: @now,
        next_touch_at: nil,
        last_rung2_at: nil
      }

      assert {:ok, %{last_rung2_at: nil}} =
               Repo.settle_open_loop(loop_id(1), reset, server: repo, now: @now)

      assert {:ok, false} =
               Repo.open_loop_budget_spent_since("default", ~U[2031-06-07 04:00:00Z],
                 server: repo
               )
    end

    test "the budget read from the touch columns is gone" do
      Code.ensure_loaded!(Repo)
      refute function_exported?(Repo, :open_loop_rung2_sent_since, 2)
      refute function_exported?(Repo, :open_loop_rung2_sent_since, 3)
    end
  end
end
