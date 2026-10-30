defmodule FermixCore.Memory.RepoOpenLoopsTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.OpenLoopsSql
  alias FermixCore.OpenLoops.Defaults

  @tz "America/New_York"
  @open_loops_version 43
  @outside_content_version 49
  # Every migration after 49 but 51 can run again on a database that has it
  # (50 and 53 add IF NOT EXISTS objects, 52 rebuilds its table in the same
  # shape, 54 rebuilds the cue tables only while they lack its shape and makes
  # its own tables only if missing): a database at 48 or 49 lacks their version
  # rows too, and reapplying them changes nothing.
  @curiosity_version 51
  # The columns migration 43 made, in its order: what a 48 database holds.
  @columns_43 ~w(id agent_id owner_id dedupe_key intention why_it_matters matters_by_kind
                 matters_by_date matters_by_time matters_by_at timezone horizon_class said_at
                 source_channel source_chat_id source_thread_scope state touches next_touch_at
                 claimed_at last_touch_at last_touch_rung last_rung2_at last_answer plan_at
                 last_outcome last_outcome_at last_message delivery_platform
                 delivery_destination delivery_thread_scope closed_at close_reason revision
                 created_at updated_at)
  # What a 49 database holds: 43's columns and the stamp 49 added after them.
  @columns_49 @columns_43 ++ ~w(noted_after_outside_content)
  # Monday 2031-06-02, 10:00 EDT; June 2031 is EDT (UTC-4). Every value here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @m ~U[2031-06-11 04:00:00Z]
  # Saturday 2031-06-07, midnight EDT: the owner's local day the spends below fall in.
  @day_start ~U[2031-06-07 04:00:00Z]
  # Saturday 2031-06-07, 09:00 EDT: the medium loops' first touch.
  @now_due ~U[2031-06-07 13:00:00Z]

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
        noted_after_outside_content: false,
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

  # A check-in's spoken outcome on a live loop, its message written after
  # outside content when `after_outside?`.
  defp spoke(after_outside?) do
    %{
      last_outcome: "spoke",
      last_outcome_at: @now,
      last_message: "An invented check-in.",
      last_message_after_outside_content: after_outside?
    }
  end

  # A loop waited on: the owner's interview ends 17:00 EDT on Tuesday the 3rd,
  # and asking how it went first feels natural then.
  defp after_attrs(n, overrides \\ %{}) do
    attrs(
      n,
      Map.merge(
        %{
          anchor_kind: "ask_after",
          matters_by_source: nil,
          horizon_class: "after",
          matters_by_kind: "datetime",
          matters_by_date: ~D[2031-06-03],
          matters_by_time: ~T[17:00:00],
          matters_by_at: ~U[2031-06-03 21:00:00Z],
          next_touch_at: ~U[2031-06-03 21:00:00Z]
        },
        overrides
      )
    )
  end

  defp schema!(conn) do
    query!(
      conn,
      "SELECT type, name, tbl_name, sql FROM sqlite_master " <>
        "WHERE tbl_name IN ('open_loops', 'open_loop_reactions') ORDER BY type, name"
    )
  end

  defp execute!(conn, sql), do: :ok = Sqlite3.execute(conn, sql)

  defp rows_by_id(conn, columns) do
    conn
    |> query!("SELECT #{Enum.join(columns, ", ")} FROM open_loops ORDER BY id")
    |> Map.new(fn [id | _rest] = values -> {id, Enum.zip(columns, values) |> Map.new()} end)
  end

  # Puts the open_loops table back in migration 43's shape with its rows, drops
  # what 49 and 51 add, and forgets every version after 48: the database an
  # engine at version 48 left.
  defp downgrade_to_48!(conn) do
    downgrade_open_loops!(conn, @columns_43, [OpenLoopsSql.schema_sql()])

    execute!(
      conn,
      "DELETE FROM schema_migrations WHERE version > 48"
    )
  end

  # Puts the open_loops table back in migration 49's shape with its rows, the
  # stamp among them, drops what 51 adds, and forgets every version after 49:
  # the database an engine at version 49 left.
  defp downgrade_to_49!(conn) do
    downgrade_open_loops!(conn, @columns_49, [
      OpenLoopsSql.schema_sql(),
      OpenLoopsSql.outside_content_schema_sql()
    ])

    execute!(
      conn,
      "DELETE FROM schema_migrations WHERE version > 49"
    )
  end

  defp downgrade_open_loops!(conn, columns, schema) do
    columns = Enum.join(columns, ", ")
    execute!(conn, "CREATE TABLE open_loops_old_rows AS SELECT #{columns} FROM open_loops")
    execute!(conn, "DROP TABLE open_loops")
    execute!(conn, "DROP TABLE open_loop_reactions")
    Enum.each(schema, &execute!(conn, &1))

    execute!(
      conn,
      "INSERT INTO open_loops (#{columns}) SELECT #{columns} FROM open_loops_old_rows"
    )

    execute!(conn, "DROP TABLE open_loops_old_rows")
  end

  defp column_names(conn),
    do: conn |> query!("PRAGMA table_info(open_loops)") |> Enum.map(&Enum.at(&1, 1))

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
        :ok = Sqlite3.execute(conn, "DROP TABLE open_loop_reactions")
        :ok = Sqlite3.execute(conn, "ALTER TABLE cue_sources DROP COLUMN stop_reason")
        :ok = Sqlite3.execute(conn, "DROP TABLE harness_run_continuations")
        :ok = Sqlite3.execute(conn, "DROP TABLE cue_counts")
        :ok = Sqlite3.execute(conn, "ALTER TABLE cue_watchers DROP COLUMN listen_for")
        :ok = Sqlite3.execute(conn, "ALTER TABLE cue_watchers ADD COLUMN filter_provider TEXT")
        :ok = Sqlite3.execute(conn, "ALTER TABLE cue_watchers ADD COLUMN filter_model TEXT")
        :ok = Sqlite3.execute(conn, "DROP INDEX cues_payload_terminal_at")
        :ok = Sqlite3.execute(conn, "DROP INDEX cues_snapshot_received_at")
        :ok = Sqlite3.execute(conn, "DROP INDEX cues_unrouted_terminal_at")
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

  # The stamp of what the turn that noted a loop had read (M78 §08), a column
  # beside the loop's words: set when the loop is known to have been noted after
  # outside content. A row written before it is not known to have been, so it
  # reads as not stamped and keeps coming back as the owner's words.
  describe "migration 49" do
    test "a stamped loop and a clean one load back as they were written", %{repo: repo} do
      create!(repo, 1)
      create!(repo, 2, %{noted_after_outside_content: true})

      assert {:ok, %{noted_after_outside_content: false}} =
               Repo.get_open_loop(loop_id(1), server: repo)

      assert {:ok, %{noted_after_outside_content: true}} =
               Repo.get_open_loop(loop_id(2), server: repo)
    end

    test "a database at 48 gains the column, and its rows read as not stamped",
         %{repo: repo, db_path: db_path} do
      create!(repo, 1)
      :ok = stop_supervised(repo)

      with_raw_conn(db_path, fn conn ->
        downgrade_to_48!(conn)
        refute "noted_after_outside_content" in column_names(conn)
        assert [[48]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
      end)

      reopened = :"#{repo}_reopened"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == @outside_content_version)) == 1
      assert Enum.count(versions, &(&1 == @curiosity_version)) == 1

      assert {:ok, %{noted_after_outside_content: false}} =
               Repo.get_open_loop(loop_id(1), server: reopened)

      assert :ok = Repo.migrate(server: reopened)
      assert {:ok, ^versions} = Repo.migration_versions(server: reopened)
    end
  end

  describe "migration 51" do
    test "a fresh database gets the anchor, the reach, the window and the reactions table", %{
      repo: repo,
      db_path: db_path
    } do
      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert @curiosity_version in versions

      with_raw_conn(db_path, fn conn ->
        columns = column_names(conn)

        assert columns -- @columns_49 ==
                 ~w(anchor_kind matters_by_source reach rung1_until
                    last_message_after_outside_content)

        assert @columns_49 -- columns == []

        indexes = for ["index", name, _table, _sql] <- schema!(conn), do: name

        for index <- ~w(idx_open_loops_due idx_open_loops_live_dedupe idx_open_loops_rung2_day
                       idx_open_loop_reactions_raised idx_open_loop_reactions_conversation) do
          assert index in indexes
        end

        reaction_columns =
          conn |> query!("PRAGMA table_info(open_loop_reactions)") |> Enum.map(&Enum.at(&1, 1))

        assert reaction_columns ==
                 ~w(id owner_id agent_id open_loop_id rung raised_at session_id source_channel
                    source_chat_id source_thread_scope raised_with reply_text reply_at outcome
                    answer created_at updated_at raised_after_outside_content
                    raised_history_tainted)

        assert [] = query!(conn, "PRAGMA foreign_key_list(open_loop_reactions)")
      end)
    end

    test "a 48 database with live and closed loops upgrades through 49 and 51, and ends as a fresh one does",
         %{
           repo: repo,
           db_path: db_path
         } do
      create!(repo, 1)
      create!(repo, 2, %{next_touch_at: ~U[2031-06-09 13:00:00Z]})
      create!(repo, 3)

      create!(repo, 4, %{
        horizon_class: "imminent",
        matters_by_date: ~D[2031-06-08],
        matters_by_at: ~U[2031-06-09 04:00:00Z],
        next_touch_at: ~U[2031-06-07 13:00:00Z]
      })

      create!(repo, 5)
      {:ok, %{due: [_, _, _, _]}} = Repo.scan_due_open_loops(@now_due, 50, server: repo)
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _closed} = Repo.settle_open_loop(loop_id(3), done, server: repo, now: @now)
      expire = %{state: "expired", close_reason: "expired", closed_at: @now, next_touch_at: nil}
      {:ok, _expired} = Repo.settle_open_loop(loop_id(5), expire, server: repo, now: @now)
      :ok = stop_supervised(repo)

      {fresh, before} =
        with_raw_conn(db_path, fn conn ->
          fresh = schema!(conn)
          downgrade_to_48!(conn)
          columns = column_names(conn)
          refute "anchor_kind" in columns
          refute "noted_after_outside_content" in columns
          {fresh, rows_by_id(conn, @columns_43)}
        end)

      upgraded = :"#{repo}_upgraded"
      start_supervised!({Repo, name: upgraded, enabled: true, database_path: db_path})
      assert {:ok, versions} = Repo.migration_versions(server: upgraded)
      assert Enum.count(versions, &(&1 == @outside_content_version)) == 1
      assert Enum.count(versions, &(&1 == @curiosity_version)) == 1

      with_raw_conn(db_path, fn conn ->
        assert schema!(conn) == fresh
        assert rows_by_id(conn, @columns_43) == before

        added =
          rows_by_id(
            conn,
            ~w(id anchor_kind reach matters_by_source rung1_until noted_after_outside_content
               last_message_after_outside_content)
          )

        # A row from before 49 is not known to have been noted after outside
        # content, nor its last message written after it, so it reads as not
        # stamped.
        unstamped = %{
          "anchor_kind" => "matters_by",
          "reach" => "message",
          "matters_by_source" => "owner",
          "noted_after_outside_content" => 0,
          "last_message_after_outside_content" => 0
        }

        for {_id, row} <- added do
          assert Map.take(row, Map.keys(unstamped)) == unstamped
        end

        # A due loop keeps today's window: three hours on from its touch, or an
        # imminent one's date. Every other row has none.
        assert added[loop_id(1)]["rung1_until"] == "2031-06-07T16:00:00.000000Z"
        assert added[loop_id(4)]["rung1_until"] == "2031-06-09T04:00:00.000000Z"
        assert added[loop_id(2)]["rung1_until"] == nil
        assert added[loop_id(3)]["rung1_until"] == nil
        assert added[loop_id(5)]["rung1_until"] == nil
      end)

      # The rows read back whole, the live dedupe index still holds, and the
      # upgraded loops still reach the due note as they did.
      assert {:ok, %{state: "due", reach: "message"}} =
               Repo.get_open_loop(loop_id(1), server: upgraded)

      assert {:ok, {:existing, %{id: "loop_00000000001"}}} =
               Repo.create_open_loop(attrs(6, %{dedupe_key: attrs(1).dedupe_key}),
                 server: upgraded
               )

      assert {:ok, {:created, _row}} =
               Repo.create_open_loop(attrs(7, %{dedupe_key: attrs(3).dedupe_key}),
                 server: upgraded
               )

      assert {:ok, notes} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-07 15:59:59Z],
                 server: upgraded
               )

      assert Enum.map(notes, & &1.id) == [loop_id(4), loop_id(1)]
    end

    test "a 49 database with a stamped loop upgrades, keeps the stamp, and ends as a fresh one does",
         %{repo: repo, db_path: db_path} do
      create!(repo, 1, %{noted_after_outside_content: true})
      create!(repo, 2, %{next_touch_at: ~U[2031-06-09 13:00:00Z]})
      create!(repo, 3, %{noted_after_outside_content: true})
      {:ok, %{due: [_, _]}} = Repo.scan_due_open_loops(@now_due, 50, server: repo)
      done = %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil}
      {:ok, _closed} = Repo.settle_open_loop(loop_id(3), done, server: repo, now: @now)
      {:ok, _spoke} = Repo.settle_open_loop(loop_id(2), spoke(true), server: repo, now: @now)
      :ok = stop_supervised(repo)

      {fresh, before} =
        with_raw_conn(db_path, fn conn ->
          fresh = schema!(conn)
          downgrade_to_49!(conn)
          columns = column_names(conn)
          refute "anchor_kind" in columns
          assert List.last(columns) == "noted_after_outside_content"
          assert [[49]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
          {fresh, rows_by_id(conn, @columns_49)}
        end)

      assert Map.new(before, fn {id, row} -> {id, row["noted_after_outside_content"]} end) ==
               %{loop_id(1) => 1, loop_id(2) => 0, loop_id(3) => 1}

      upgraded = :"#{repo}_upgraded"
      start_supervised!({Repo, name: upgraded, enabled: true, database_path: db_path})
      assert {:ok, versions} = Repo.migration_versions(server: upgraded)
      assert Enum.count(versions, &(&1 == @outside_content_version)) == 1
      assert Enum.count(versions, &(&1 == @curiosity_version)) == 1

      with_raw_conn(db_path, fn conn ->
        assert schema!(conn) == fresh
        assert rows_by_id(conn, @columns_49) == before
      end)

      # A message sent before 51 is not known to have been written after
      # outside content, so it reads as not stamped, as its loop would.
      assert {:ok,
              %{last_message: "An invented check-in.", last_message_after_outside_content: false}} =
               Repo.get_open_loop(loop_id(2), server: upgraded)

      assert {:ok, %{state: "due", noted_after_outside_content: true}} =
               Repo.get_open_loop(loop_id(1), server: upgraded)

      assert {:ok, %{state: "closed", noted_after_outside_content: true}} =
               Repo.get_open_loop(loop_id(3), server: upgraded)

      assert {:ok, %{noted_after_outside_content: false}} =
               Repo.get_open_loop(loop_id(2), server: upgraded)
    end

    test "the table's checks hold the anchor, the source and the window together", %{
      repo: repo,
      db_path: db_path
    } do
      create!(repo, 1)
      {:ok, _} = Repo.create_open_loop(after_attrs(2), server: repo)

      with_raw_conn(db_path, fn conn ->
        for sql <- [
              "UPDATE open_loops SET horizon_class = 'after' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET anchor_kind = 'ask_after' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET matters_by_source = NULL WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET matters_by_source = 'owner' WHERE id = '#{loop_id(2)}'",
              "UPDATE open_loops SET matters_by_source = 'guess' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET reach = 'email' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET state = 'due' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET rung1_until = next_touch_at WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET last_answer = 'later' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET last_outcome = 'deferred' WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET noted_after_outside_content = 2 WHERE id = '#{loop_id(1)}'",
              "UPDATE open_loops SET last_message_after_outside_content = 2 " <>
                "WHERE id = '#{loop_id(1)}'"
            ] do
          assert {:error, message} = Sqlite3.execute(conn, sql), sql
          assert message =~ "CHECK constraint failed", sql
        end

        assert :ok =
                 Sqlite3.execute(
                   conn,
                   "UPDATE open_loops SET last_answer = 'moved' WHERE id = '#{loop_id(1)}'"
                 )

        assert :ok =
                 Sqlite3.execute(
                   conn,
                   "UPDATE open_loops SET last_outcome = 'later' WHERE id = '#{loop_id(1)}'"
                 )
      end)
    end

    test "a reaction row keeps its own vocabulary", %{db_path: db_path} do
      with_raw_conn(db_path, fn conn ->
        row = fn rung, outcome, answer ->
          "INSERT INTO open_loop_reactions (id, owner_id, agent_id, open_loop_id, rung, " <>
            "raised_at, source_channel, source_chat_id, outcome, answer, created_at, updated_at) " <>
            "VALUES ('reaction_#{System.unique_integer([:positive])}', 'default', 'main', " <>
            "'#{loop_id(1)}', #{rung}, '2031-06-03T22:00:00.000000Z', 'telegram', '40001', " <>
            "#{outcome}, #{answer}, '2031-06-03T22:00:00.000000Z', '2031-06-03T22:00:00.000000Z')"
        end

        assert :ok = Sqlite3.execute(conn, row.(1, "NULL", "NULL"))
        assert :ok = Sqlite3.execute(conn, row.(2, "'replied'", "'moved'"))
        assert :ok = Sqlite3.execute(conn, row.(1, "'no_reply'", "'reach'"))

        for bad <- [
              row.(3, "NULL", "NULL"),
              row.(1, "'ignored'", "NULL"),
              row.(1, "NULL", "'asked'")
            ] do
          assert {:error, message} = Sqlite3.execute(conn, bad)
          assert message =~ "CHECK constraint failed"
        end

        assert [["root"]] =
                 query!(conn, "SELECT DISTINCT source_thread_scope FROM open_loop_reactions")

        # A raise not known to have come after outside content reads as not.
        assert [[0]] =
                 query!(
                   conn,
                   "SELECT DISTINCT raised_after_outside_content FROM open_loop_reactions"
                 )

        stamped = fn value ->
          "INSERT INTO open_loop_reactions (id, owner_id, agent_id, open_loop_id, rung, " <>
            "raised_at, source_channel, source_chat_id, raised_after_outside_content, " <>
            "created_at, updated_at) VALUES ('reaction_#{System.unique_integer([:positive])}', " <>
            "'default', 'main', '#{loop_id(1)}', 1, '2031-06-03T22:00:00.000000Z', 'telegram', " <>
            "'40001', #{value}, '2031-06-03T22:00:00.000000Z', '2031-06-03T22:00:00.000000Z')"
        end

        assert :ok = Sqlite3.execute(conn, stamped.(1))
        assert {:error, message} = Sqlite3.execute(conn, stamped.(2))
        assert message =~ "CHECK constraint failed"

        # Words not known to come from a reply stamped with the owner's computer
        # activity read as not, and the mark is 0 or 1.
        assert [[0]] =
                 query!(conn, "SELECT DISTINCT raised_history_tainted FROM open_loop_reactions")

        tainted = fn value ->
          "INSERT INTO open_loop_reactions (id, owner_id, agent_id, open_loop_id, rung, " <>
            "raised_at, source_channel, source_chat_id, raised_history_tainted, " <>
            "created_at, updated_at) VALUES ('reaction_#{System.unique_integer([:positive])}', " <>
            "'default', 'main', '#{loop_id(1)}', 1, '2031-06-03T22:00:00.000000Z', 'telegram', " <>
            "'40001', #{value}, '2031-06-03T22:00:00.000000Z', '2031-06-03T22:00:00.000000Z')"
        end

        assert :ok = Sqlite3.execute(conn, tainted.(1))
        assert {:error, message} = Sqlite3.execute(conn, tainted.(2))
        assert message =~ "CHECK constraint failed"
      end)
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
               noted_after_outside_content: false,
               why_it_matters: "the foundation releases the second tranche on receipt",
               matters_by_kind: "datetime",
               matters_by_date: ~D[2031-06-10],
               matters_by_time: ~T[15:00:00],
               matters_by_at: utc(~U[2031-06-10 19:00:00Z]),
               anchor_kind: "matters_by",
               matters_by_source: "owner",
               reach: "message",
               timezone: @tz,
               horizon_class: "medium",
               said_at: utc(@now),
               source_channel: "telegram",
               source_chat_id: "40001",
               source_thread_scope: "root",
               state: "open",
               touches: 0,
               next_touch_at: utc(~U[2031-06-07 13:00:00Z]),
               rung1_until: nil,
               claimed_at: nil,
               last_touch_at: nil,
               last_touch_rung: nil,
               last_rung2_at: nil,
               last_answer: nil,
               plan_at: nil,
               last_outcome: nil,
               last_outcome_at: nil,
               last_message: nil,
               last_message_after_outside_content: false,
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
        last_message: "An invented check-in.",
        last_message_after_outside_content: true
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

      # What the noting turn had read is always stated, never assumed.
      for provenance <- [nil, "yes", 1] do
        assert {:error, {:invalid, :noted_after_outside_content, :not_a_boolean}} =
                 Repo.create_open_loop(attrs(1, %{noted_after_outside_content: provenance}),
                   server: repo
                 )
      end

      assert {:error, {:invalid, :noted_after_outside_content, :not_a_boolean}} =
               Repo.create_open_loop(Map.delete(attrs(1), :noted_after_outside_content),
                 server: repo
               )

      assert {:error, {:invalid, :last_message, :too_long}} =
               Repo.settle_open_loop(
                 loop_id(1),
                 %{
                   last_message: String.duplicate("b", 1_801),
                   last_message_after_outside_content: false
                 },
                 server: repo
               )

      # What the run that wrote a message had read is stated with the message,
      # always, and never without it.
      for provenance <- [nil, "yes", 1] do
        assert {:error, {:invalid, :last_message_after_outside_content, :not_a_boolean}} =
                 Repo.settle_open_loop(
                   loop_id(1),
                   %{last_message: "Sent.", last_message_after_outside_content: provenance},
                   server: repo
                 )
      end

      assert {:error, {:invalid, :last_message_after_outside_content, :apart_from_message}} =
               Repo.settle_open_loop(loop_id(1), %{last_message: "Sent."}, server: repo)

      assert {:error, {:invalid, :last_message_after_outside_content, :apart_from_message}} =
               Repo.settle_open_loop(loop_id(1), %{last_message_after_outside_content: true},
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
        last_message: "An invented check-in.",
        last_message_after_outside_content: false
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
    end

    test "the due note reads each loop's own window, not a shared one", %{repo: repo} do
      create!(repo, 1)
      create!(repo, 2, %{reach: "conversation"})
      {:ok, %{due: [_, _]}} = Repo.scan_due_open_loops(@now_due, 50, server: repo)

      # Past the message loop's three hours, inside the conversation loop's
      # window, which runs to its next slot, the 9th at 09:00 EDT.
      assert {:ok, [%{id: "loop_00000000002"}]} =
               Repo.due_open_loops_for_note("default", "main", ~U[2031-06-08 20:00:00Z],
                 server: repo
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

  describe "the rung 1 window and the anchor" do
    test "the scan writes each loop's window as it marks it due", %{repo: repo} do
      create!(repo, 1)
      create!(repo, 2, %{reach: "conversation"})
      create!(repo, 3, %{reach: "conversation", next_touch_at: ~U[2031-06-09 13:00:00Z]})

      create!(repo, 4, %{
        horizon_class: "imminent",
        matters_by_date: ~D[2031-06-08],
        matters_by_at: ~U[2031-06-09 04:00:00Z]
      })

      {:ok, _} = Repo.create_open_loop(after_attrs(5, %{reach: "conversation"}), server: repo)
      {:ok, _} = Repo.create_open_loop(after_attrs(6), server: repo)

      until = fn n ->
        {:ok, %{state: "due", rung1_until: at}} = Repo.get_open_loop(loop_id(n), server: repo)
        at
      end

      ids = fn rows -> rows |> Enum.map(& &1.id) |> Enum.sort() end

      # By message: three hours on. For conversation: the next slot, or the
      # date for the last one before it. Imminent: its date. Waited on, kept
      # for conversation: fourteen days from its touch.
      {:ok, %{due: waited}} = Repo.scan_due_open_loops(~U[2031-06-03 21:00:00Z], 50, server: repo)
      assert ids.(waited) == [loop_id(5), loop_id(6)]
      assert until.(5) == utc(~U[2031-06-17 21:00:00Z])
      assert until.(6) == utc(~U[2031-06-04 00:00:00Z])

      {:ok, %{due: dated}} = Repo.scan_due_open_loops(@now_due, 50, server: repo)
      assert ids.(dated) == [loop_id(1), loop_id(2), loop_id(4)]
      assert until.(1) == utc(~U[2031-06-07 16:00:00Z])
      assert until.(2) == utc(~U[2031-06-09 13:00:00Z])
      assert until.(4) == utc(~U[2031-06-09 04:00:00Z])

      {:ok, %{due: last}} = Repo.scan_due_open_loops(~U[2031-06-09 13:00:00Z], 50, server: repo)
      assert ids.(last) == [loop_id(3)]
      assert until.(3) == utc(@m)
    end

    test "a conversation window that closes unraised opens the next, then the date ends it", %{
      repo: repo
    } do
      create!(repo, 1, %{reach: "conversation"})
      {:ok, %{due: [_]}} = Repo.scan_due_open_loops(@now_due, 50, server: repo)

      assert {:ok, %{due: [], waiting: [lapsed]}} =
               Repo.scan_due_open_loops(~U[2031-06-09 13:00:00Z], 50, server: repo)

      assert %{state: "due", touches: 0, revision: 1} = lapsed
      assert lapsed.next_touch_at == utc(~U[2031-06-09 13:00:00Z])
      assert lapsed.rung1_until == utc(@m)

      assert {:ok, %{expired: [expired], skipped_to_handback: []}} =
               Repo.scan_due_open_loops(@m, 50, server: repo)

      assert %{state: "expired", rung1_until: nil, next_touch_at: nil} = expired
    end

    test "every write that moves a loop out of due clears its window", %{repo: repo} do
      for n <- 1..3, do: create!(repo, n)
      {:ok, %{due: [_, _, _]}} = Repo.scan_due_open_loops(@now_due, 50, server: repo)

      not_yet = %{state: "open", next_touch_at: ~U[2031-06-09 13:00:00Z], last_answer: "not_yet"}

      assert {:ok, %{state: "open", rung1_until: nil}} =
               Repo.settle_open_loop(loop_id(1), not_yet, server: repo, now: @now_due)

      {:ok, %{claimed_at: claimed_at}} =
        Repo.claim_open_loop_checkin(loop_id(2), ~U[2031-06-07 16:30:00Z], server: repo)

      silent = %{
        state: "open",
        next_touch_at: ~U[2031-06-09 13:00:00Z],
        last_outcome: "silent",
        last_outcome_at: ~U[2031-06-07 16:31:00Z]
      }

      assert {:ok, %{state: "open", rung1_until: nil}} =
               Repo.finalize_open_loop_checkin(loop_id(2), claimed_at, silent, server: repo)

      # A release keeps the loop due, and its window with it.
      {:ok, %{claimed_at: claim}} =
        Repo.claim_open_loop_checkin(loop_id(3), ~U[2031-06-07 16:30:00Z], server: repo)

      assert {:ok, %{state: "due", rung1_until: until}} =
               Repo.finalize_open_loop_checkin(loop_id(3), claim, %{state: "due"}, server: repo)

      assert until == utc(~U[2031-06-07 16:00:00Z])
    end

    test "a loop of the other timing with the same words is a kind conflict", %{repo: repo} do
      dated = create!(repo, 1)
      waited = after_attrs(2, %{dedupe_key: dated.dedupe_key})

      assert {:error, {:kind_conflict, "loop_00000000001"}} =
               Repo.create_open_loop(waited, server: repo)

      assert {:error, :not_found} = Repo.get_open_loop(loop_id(2), server: repo)

      assert {:ok, {:created, after_loop}} = Repo.create_open_loop(after_attrs(3), server: repo)

      assert {:ok, {:existing, ^after_loop}} =
               Repo.create_open_loop(after_attrs(4, %{dedupe_key: after_loop.dedupe_key}),
                 server: repo
               )
    end

    test "a loop waited on saves and loads with its anchor and no source", %{repo: repo} do
      assert {:ok, {:created, created}} =
               Repo.create_open_loop(after_attrs(1, %{reach: "conversation"}), server: repo)

      assert {:ok, ^created} = Repo.get_open_loop(loop_id(1), server: repo)

      assert %{
               anchor_kind: "ask_after",
               horizon_class: "after",
               matters_by_source: nil,
               reach: "conversation",
               matters_by_kind: "datetime",
               matters_by_time: ~T[17:00:00],
               rung1_until: nil
             } = created

      assert created.matters_by_at == utc(~U[2031-06-03 21:00:00Z])
    end

    test "the anchor's kind, class and source are checked together before the writer", %{
      repo: repo
    } do
      assert {:error, {:invalid, :horizon_class, :anchor_mismatch}} =
               Repo.create_open_loop(attrs(1, %{anchor_kind: "ask_after"}), server: repo)

      assert {:error, {:invalid, :horizon_class, :anchor_mismatch}} =
               Repo.create_open_loop(after_attrs(1, %{anchor_kind: "matters_by"}), server: repo)

      assert {:error, {:invalid, :matters_by_source, :ask_after}} =
               Repo.create_open_loop(after_attrs(1, %{matters_by_source: "owner"}), server: repo)

      assert {:error, {:invalid, :matters_by_source, :unsupported}} =
               Repo.create_open_loop(attrs(1, %{matters_by_source: "guess"}), server: repo)

      assert {:error, {:invalid, :reach, :unsupported}} =
               Repo.create_open_loop(attrs(1, %{reach: "email"}), server: repo)

      assert {:ok, {:created, %{matters_by_source: "lookup"}}} =
               Repo.create_open_loop(attrs(1, %{matters_by_source: "lookup"}), server: repo)
    end

    test "a moved date settles whole, with its class and source", %{repo: repo} do
      create!(repo, 1)

      moved = %{
        matters_by_kind: "datetime",
        matters_by_date: ~D[2031-06-24],
        matters_by_time: ~T[12:00:00],
        matters_by_at: ~U[2031-06-24 16:00:00Z],
        matters_by_source: "lookup",
        horizon_class: "long",
        state: "open",
        last_answer: "moved",
        next_touch_at: ~U[2031-06-17 13:00:00Z]
      }

      assert {:ok, settled} = Repo.settle_open_loop(loop_id(1), moved, server: repo, now: @now)

      assert %{
               matters_by_kind: "datetime",
               matters_by_date: ~D[2031-06-24],
               matters_by_time: ~T[12:00:00],
               matters_by_source: "lookup",
               horizon_class: "long",
               last_answer: "moved",
               anchor_kind: "matters_by"
             } = settled

      assert settled.matters_by_at == utc(~U[2031-06-24 16:00:00Z])

      assert {:error, {:invalid, :matters_by, :partial_move}} =
               Repo.settle_open_loop(loop_id(1), %{matters_by_at: ~U[2031-06-25 16:00:00Z]},
                 server: repo
               )

      assert {:error, {:invalid, :matters_by_time, :required}} =
               Repo.settle_open_loop(loop_id(1), %{moved | matters_by_time: nil}, server: repo)

      assert {:error, {:invalid, :horizon_class, :anchor_mismatch}} =
               Repo.settle_open_loop(loop_id(1), %{moved | horizon_class: "after"}, server: repo)

      assert {:ok, %{reach: "conversation"}} =
               Repo.settle_open_loop(loop_id(1), %{reach: "conversation"}, server: repo)
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
