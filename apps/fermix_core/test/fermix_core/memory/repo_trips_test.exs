defmodule FermixCore.Memory.RepoTripsTest do
  # M89 §05: migration 63 adds the owner's trips beside the lists, rewrites
  # nothing and runs once; one call is one transaction; rows and trips removed
  # 30 days ago go; a device's edit is applied once by its client_msg_id, its
  # receipt in the table the lists' edits use, by kind.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Checklists.Registry, as: Checklists
  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.Registry

  @version 63
  # D10: where a trip, or one of its days, is: a column on each table.
  @near_version 64
  # Every title, stop and id here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @owner %{
    agent_name: "main",
    conversation_key: {"telegram", "40017", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }
  @inn %{"name" => "Marisco Inn", "location" => %{"latitude" => 41.2031, "longitude" => -8.4102}}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trips-repo-#{unique}.db")
    repo = :"trips_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
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

  defp objects(conn) do
    query!(
      conn,
      "SELECT type, name FROM sqlite_master " <>
        "WHERE tbl_name IN ('trips', 'trip_rows') AND name NOT LIKE 'sqlite_%' " <>
        "ORDER BY type, name"
    )
  end

  @objects [
    ["index", "idx_trip_rows_trip"],
    ["index", "idx_trips_live_title"],
    ["index", "idx_trips_owner"],
    ["table", "trip_rows"],
    ["table", "trips"]
  ]

  # The notifier is the test's own, so no connection anywhere hears of it.
  defp quiet(opts), do: [notifier: fn _changes -> :ok end] ++ opts

  defp edit(repo, trip, ops, now \\ @now) do
    Registry.edit(%{"trip" => trip, "ops" => ops}, @owner, quiet(repo: repo, now: now))
  end

  defp edit!(repo, trip, ops, now \\ @now) do
    assert {:ok, answer} = edit(repo, trip, ops, now)
    answer
  end

  defp device(repo, client_msg_id, params, now \\ @now) do
    Registry.device_edit(
      Map.put(params, "client_msg_id", client_msg_id),
      :independent,
      quiet(repo: repo, now: now)
    )
  end

  defp trip!(repo, ref) do
    assert {:ok, read} = Repo.trips_call({:read_trip, "default", "main", ref}, server: repo)
    read
  end

  defp varonne!(repo) do
    edit!(repo, "Varonne", [
      %{
        "op" => "create",
        "days" => 2,
        "starts_on" => "2031-07-04",
        "timezone" => "Europe/Lisbon"
      },
      %{"op" => "day", "day" => 1, "text" => "Harbour"},
      %{"op" => "add", "text" => "Fish market", "day" => 1, "time" => "08:30", "duration" => 45},
      %{
        "op" => "add",
        "text" => "Dinner at Corvo",
        "day" => 2,
        "fixed" => true,
        "note" => "Booked"
      }
    ])

    trip!(repo, "Varonne")
  end

  describe "the migration" do
    test "a fresh store gets both tables, their indexes and version 63", %{
      repo: repo,
      db_path: db_path
    } do
      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == @version)) == 1
      with_raw_conn(db_path, fn conn -> assert objects(conn) == @objects end)
      assert {:ok, []} = Repo.trips_call({:index, "default", "main"}, server: repo)
    end

    test "a store at version 62 gains the trips on open, its rows kept", %{
      repo: repo,
      db_path: db_path
    } do
      {:ok, _answer} =
        Checklists.edit(
          %{"changes" => [%{"list" => "Packing", "ops" => [%{"op" => "create"}]}]},
          @owner,
          quiet(repo: repo, now: @now)
        )

      :ok = stop_supervised(repo)

      with_raw_conn(db_path, fn conn ->
        :ok = Sqlite3.execute(conn, "DROP TABLE trip_rows")
        :ok = Sqlite3.execute(conn, "DROP TABLE trips")
        :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version >= #{@version}")
        assert [[62]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
        assert objects(conn) == []
      end)

      reopened = :"#{repo}_reopened"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == @version)) == 1

      with_raw_conn(db_path, fn conn ->
        assert objects(conn) == @objects
        assert [["Packing"]] = query!(conn, "SELECT title FROM checklists")
      end)
    end

    test "migrating again changes nothing", %{repo: repo} do
      %{trip: trip} = varonne!(repo)
      assert :ok = Repo.migrate(server: repo)
      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == @version)) == 1
      assert %{trip: ^trip} = trip!(repo, "Varonne")
    end

    test "64 gives a trip and a day row a near, once; a store at 63 gains it with its rows kept",
         %{repo: repo, db_path: db_path} do
      edit!(repo, "Two cities", [
        %{"op" => "create", "days" => 2, "near" => "Lisbon, Portugal"},
        %{"op" => "day", "day" => 2, "near" => "Porto, Portugal"}
      ])

      with_raw_conn(db_path, fn conn ->
        assert [["Lisbon, Portugal"]] = query!(conn, "SELECT near FROM trips")

        assert [[nil], ["Porto, Portugal"]] =
                 query!(conn, "SELECT near FROM trip_rows ORDER BY position")
      end)

      assert :ok = Repo.migrate(server: repo)
      assert {:ok, versions} = Repo.migration_versions(server: repo)
      assert Enum.count(versions, &(&1 == @near_version)) == 1
      assert %{trip: %{near: "Lisbon, Portugal"} = trip, rows: rows} = trip!(repo, "Two cities")

      # A store from before 64: both columns gone, as 63 made the tables.
      :ok = stop_supervised(repo)

      with_raw_conn(db_path, fn conn ->
        for table <- ["trips", "trip_rows"],
            do: :ok = Sqlite3.execute(conn, "ALTER TABLE #{table} DROP COLUMN near")

        :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = 64")
      end)

      reopened = :"#{repo}_at_63"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == @near_version)) == 1

      assert %{trip: %{near: nil, title: "Two cities", rev: rev}, rows: kept} =
               trip!(reopened, "Two cities")

      assert rev == trip.rev
      assert Enum.map(kept, & &1.id) == Enum.map(rows, & &1.id)
      assert Enum.all?(kept, &is_nil(&1.near))
    end

    test "a near belongs on a trip or a day: the store refuses one on a stop", %{
      repo: repo,
      db_path: db_path
    } do
      varonne!(repo)

      with_raw_conn(db_path, fn conn ->
        assert {:error, message} =
                 Sqlite3.execute(conn, "UPDATE trip_rows SET near = 'Ostrel' WHERE kind = 'stop'")

        assert message =~ "CHECK"

        assert :ok =
                 Sqlite3.execute(conn, "UPDATE trip_rows SET near = 'Ostrel' WHERE kind = 'day'")

        assert {:error, _empty} = Sqlite3.execute(conn, "UPDATE trips SET near = ''")
      end)
    end

    test "the live-title index refuses a second live title, case-blind; a removed one does not count",
         %{db_path: db_path} do
      insert = fn conn, id, title, removed_at ->
        Sqlite3.execute(
          conn,
          "INSERT INTO trips (id, title, position, created_at, updated_at, removed_at) " <>
            "VALUES ('#{id}', '#{title}', 1, 'x', 'x', #{removed_at})"
        )
      end

      with_raw_conn(db_path, fn conn ->
        assert :ok = insert.(conn, "tr_0000000001", "Varonne", "NULL")
        assert {:error, message} = insert.(conn, "tr_0000000002", "VARONNE", "NULL")
        assert message =~ "UNIQUE"
        assert :ok = insert.(conn, "tr_0000000003", "varonne", "'2031-06-01T00:00:00.000000Z'")
      end)
    end
  end

  describe "one call, one transaction" do
    test "a write that fails rolls the whole call back", %{repo: repo, db_path: db_path} do
      %{trip: trip, rows: rows} = varonne!(repo)

      with_raw_conn(db_path, fn conn ->
        :ok =
          Sqlite3.execute(conn, """
          CREATE TRIGGER refuse_ferry BEFORE INSERT ON trip_rows WHEN NEW.text = 'Ferry'
          BEGIN SELECT RAISE(ABORT, 'refused by the test'); END;
          """)
      end)

      assert {:error, reason} =
               edit(repo, "Varonne", [
                 %{"op" => "rename", "text" => "Varonne Coast"},
                 %{"op" => "add", "text" => "Clock tower", "day" => 1},
                 %{"op" => "add", "text" => "Ferry", "day" => 2}
               ])

      assert Registry.error_tag(reason) == "storage_failed"
      assert %{trip: ^trip, rows: ^rows} = trip!(repo, "Varonne")
    end

    test "reopen after restart: written, the Repo stopped and opened on the same file, it reads back whole",
         %{repo: repo, db_path: db_path} do
      %{trip: trip, rows: [%{id: day_id} | _rest]} = varonne!(repo)

      assert {:ok, %{made: made}} =
               device(repo, "mac-1", %{
                 "trip_id" => trip.id,
                 "op" => %{
                   "op" => "add",
                   "text" => "Back to the inn",
                   "day_id" => day_id,
                   "place" => @inn
                 }
               })

      before = trip!(repo, "Varonne")
      assert %{place: @inn, made_via: "mac"} = Enum.find(before.rows, &(&1.id == made))
      :ok = stop_supervised(repo)

      reopened = :"#{repo}_reopened"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

      assert trip!(reopened, "Varonne") == before

      assert {:ok, [%{id: id, title: "Varonne", days: 2, stops: 3}]} =
               Repo.trips_call({:index, "default", "main"}, server: reopened)

      assert id == trip.id
    end
  end

  describe "the 30 days" do
    test "removed rows go with the next edit after 30 days, removed trips at open", %{
      repo: repo,
      db_path: db_path
    } do
      long_ago = DateTime.add(@now, -31 * 86_400, :second)
      recently = DateTime.add(@now, -29 * 86_400, :second)
      # The store sweeps trips by its own clock when it opens, so the trip it
      # deletes was removed years before any clock this runs on, and the one it
      # keeps at the test's own instant, years after.
      years_ago = ~U[2020-01-06 09:00:00Z]

      edit!(
        repo,
        "Varonne",
        [
          %{"op" => "create"},
          %{"op" => "add", "text" => "Old stop", "day" => 1},
          %{"op" => "add", "text" => "Recent stop", "day" => 1},
          %{"op" => "add", "text" => "Kept stop", "day" => 1}
        ],
        long_ago
      )

      edit!(repo, "Varonne", [%{"op" => "remove", "n" => 2}], long_ago)
      edit!(repo, "Varonne", [%{"op" => "remove", "n" => 3}], recently)
      edit!(repo, "Gone Trip", [%{"op" => "create"}, %{"op" => "remove_trip"}], years_ago)
      edit!(repo, "Kept Trip", [%{"op" => "create"}, %{"op" => "remove_trip"}], recently)

      texts = fn conn ->
        query!(conn, "SELECT text FROM trip_rows WHERE kind = 'stop' ORDER BY n")
      end

      with_raw_conn(db_path, fn conn -> assert length(texts.(conn)) == 3 end)

      edit!(repo, "Varonne", [%{"op" => "add", "text" => "New stop", "day" => 1}])

      with_raw_conn(db_path, fn conn ->
        assert texts.(conn) == [["Recent stop"], ["Kept stop"], ["New stop"]]
        assert [[3]] = query!(conn, "SELECT COUNT(*) FROM trips")
      end)

      :ok = stop_supervised(repo)
      reopened = :"#{repo}_reopened"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: db_path})

      with_raw_conn(db_path, fn conn ->
        assert [["Kept Trip"], ["Varonne"]] =
                 query!(conn, "SELECT title FROM trips ORDER BY title")

        assert [[0]] =
                 query!(
                   conn,
                   "SELECT COUNT(*) FROM trip_rows WHERE trip_id NOT IN (SELECT id FROM trips)"
                 )
      end)
    end
  end

  describe "a device's edit, once" do
    test "a duplicate client_msg_id answers duplicate with what it made and changes nothing", %{
      repo: repo
    } do
      create = %{"op" => %{"op" => "create", "title" => "Varonne"}}

      assert {:ok, %{trip_id: trip_id, made: trip_id, duplicate: false}} =
               device(repo, "mac-1", create)

      before = trip!(repo, trip_id)

      assert device(repo, "mac-1", create) ==
               {:ok, %{trip_id: trip_id, made: trip_id, duplicate: true}}

      assert trip!(repo, trip_id) == before
    end

    test "a client_msg_id a list's edit used is never a trip's duplicate, and its edit changes nothing",
         %{repo: repo, db_path: db_path} do
      assert {:ok, %{duplicate: false}} =
               Checklists.device_edit(
                 %{"client_msg_id" => "mac-7", "op" => %{"op" => "create", "title" => "Packing"}},
                 :independent,
                 quiet(repo: repo, now: @now)
               )

      # The receipts' key is the owner's and the id's, not the kind's (S0), so
      # the trip's edit is refused whole rather than answered as the list's,
      # by its own refusal before anything runs (R3#10).
      assert {:error, reason} =
               device(repo, "mac-7", %{"op" => %{"op" => "create", "title" => "Varonne"}})

      assert Registry.error_tag(reason) == "client_msg_id_used"

      with_raw_conn(db_path, fn conn ->
        assert [] = query!(conn, "SELECT id FROM trips")
        assert [["checklist"]] = query!(conn, "SELECT kind FROM checklist_edits")
      end)
    end

    test "receipts over 30 days go with a later device edit", %{repo: repo, db_path: db_path} do
      old = DateTime.add(@now, -31 * 86_400, :second)
      recent = DateTime.add(@now, -29 * 86_400, :second)
      create = fn title -> %{"op" => %{"op" => "create", "title" => title}} end

      assert {:ok, _made} = device(repo, "mac-old", create.("Old"), old)
      assert {:ok, _made} = device(repo, "mac-recent", create.("Recent"), recent)
      assert {:ok, _made} = device(repo, "mac-now", create.("Now"), @now)

      with_raw_conn(db_path, fn conn ->
        assert [["mac-now", "trip"], ["mac-recent", "trip"]] =
                 query!(
                   conn,
                   "SELECT client_msg_id, kind FROM checklist_edits ORDER BY client_msg_id"
                 )
      end)
    end
  end
end
