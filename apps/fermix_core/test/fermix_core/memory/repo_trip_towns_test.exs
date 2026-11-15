defmodule FermixCore.Memory.RepoTripTownsTest do
  # M89: migration 66 keeps, beside a trip, the town each near in force names,
  # by the near's exact words: `found` with the geocoder's own town, or
  # `none`, and nothing at all for a near not resolved. The edit that sets a
  # near writes its town in the same transaction and clears the words no
  # longer in force on the trip; the placer's write moves the trip's rev once
  # when only towns changed, so the owner's devices are told.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Trips.Registry

  @version 66
  # Every title, town, place and number here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @conversation {"telegram", "40017", :root}
  @owner %{
    agent_name: "main",
    conversation_key: @conversation,
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }
  @varonne %{
    name: "Varonne, Ostrel, Varonia",
    latitude: 41.14,
    longitude: -8.61,
    radius_meters: 5_210
  }
  @brisa %{name: "Brisa, Ostrel, Varonia", latitude: 41.3, longitude: -8.7, radius_meters: 3_100}
  @away {:error, "computer_away: no Mac that looks places up is online", %{attempt: 0}}
  @nowhere {:error, "invalid_location: Apple Maps found no place by that name", %{attempt: 1}}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-towns-#{unique}.db")
    repo = :"trip_towns_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: :holder))

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path, holder: holder}
  end

  defp opts(ctx) do
    test = self()

    [
      repo: ctx.repo,
      now: @now,
      reply_blocks: ctx.holder,
      notifier: fn changes -> send(test, {:notified, changes}) && :ok end,
      placer: fn -> :ok end,
      town_placer: fn -> send(test, :town_placer_told) && :ok end,
      day_turn: fn -> :ok end
    ]
  end

  # A turn whose place search answers each near from `towns`, telling the
  # test each one asked.
  defp context(towns) do
    test = self()

    Map.merge(@owner, %{
      place_lookup: fn %{query: query} -> raise "no stop is looked up here: #{query}" end,
      town_lookup: fn words ->
        send(test, {:asked, words})
        Map.fetch!(towns, words)
      end
    })
  end

  defp edit!(ctx, ops, towns \\ %{}) do
    assert {:ok, answer} =
             Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context(towns), opts(ctx))

    answer
  end

  defp create!(ctx, towns \\ %{"Varonne" => {:ok, @varonne, %{attempt: 1}}}),
    do: edit!(ctx, [%{"op" => "create", "days" => 2, "near" => "Varonne"}], towns)

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

  defp towns(ctx) do
    with_raw_conn(ctx.db_path, fn conn ->
      query!(conn, "SELECT words, state, name FROM trip_towns ORDER BY words")
    end)
  end

  defp trip!(ctx) do
    assert {:ok, read} =
             Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: ctx.repo)

    read
  end

  defp device_trip!(ctx) do
    assert {:ok, snapshot} =
             Registry.device_trip(trip!(ctx).trip.id, true, :independent, opts(ctx))

    snapshot
  end

  defp asked do
    receive do
      {:asked, words} -> [words | asked()]
    after
      0 -> []
    end
  end

  describe "the migration" do
    test "a fresh store gets the towns table and version 66 once", ctx do
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == @version)) == 1
      assert :ok = Repo.migrate(server: ctx.repo)
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == @version)) == 1
    end

    test "a row is found with its town, or none with nothing else", ctx do
      create!(ctx)
      %{trip: %{id: id}} = trip!(ctx)

      with_raw_conn(ctx.db_path, fn conn ->
        for {state, fields} <- [
              {"found", "NULL, 1.0, 2.0, 3"},
              {"none", "'Brisa', NULL, NULL, NULL"},
              {"waiting", "NULL, NULL, NULL, NULL"},
              {"found", "'Brisa', 91.0, 2.0, 3"},
              {"found", "'Brisa', 1.0, 2.0, 0"},
              {"found", "x'4272697361', 1.0, 2.0, 3"}
            ] do
          sql =
            "INSERT INTO trip_towns (trip_id, words, state, name, latitude, longitude, " <>
              "radius_meters) VALUES ('#{id}', 'Kestrin', '#{state}', #{fields})"

          assert {:error, _reason} = Sqlite3.execute(conn, sql), "#{state} #{fields} was kept"
        end
      end)
    end

    test "a store at 65 with trips gains it on open, every trip kept, no near resolved", ctx do
      create!(ctx)
      %{trip: trip, rows: rows} = trip!(ctx)
      :ok = stop_supervised(ctx.repo)

      with_raw_conn(ctx.db_path, fn conn ->
        :ok = Sqlite3.execute(conn, "DROP TABLE trip_towns")
        :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = #{@version}")
      end)

      reopened = :"#{ctx.repo}_at_65"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path})
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == @version)) == 1

      assert {:ok, %{trip: ^trip, rows: ^rows, towns: towns}} =
               Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: reopened)

      assert towns == %{}
    end
  end

  describe "what an edit keeps" do
    test "a create's near is found in the call and kept with the trip, its rev moved once", ctx do
      answer = create!(ctx)

      assert asked() == ["Varonne"]
      assert towns(ctx) == [["Varonne", "found", "Varonne, Ostrel, Varonia"]]
      assert answer.text =~ ~s(Near "Varonne" found as "Varonne, Ostrel, Varonia".)
      assert trip!(ctx).towns == %{"Varonne" => {:found, @varonne}}
      assert device_trip!(ctx).towns == %{"Varonne" => @varonne}
      assert trip!(ctx).trip.rev == 1
    end

    test "a near found to be nothing is none, kept and never asked again for those words", ctx do
      create!(ctx, %{"Varonne" => @nowhere})
      assert towns(ctx) == [["Varonne", "none", nil]]
      assert asked() == ["Varonne"]

      edit!(ctx, [%{"op" => "rename", "text" => "Varonne"}])
      assert asked() == []
    end

    test "a near not resolved keeps nothing; the next call that changes the trip asks again",
         ctx do
      create!(ctx, %{"Varonne" => @away})
      assert towns(ctx) == []
      assert asked() == ["Varonne"]

      # A call that changes nothing does not ask.
      edit!(ctx, [%{"op" => "day", "day" => 1}])
      assert asked() == []

      edit!(ctx, [%{"op" => "day", "day" => 1, "text" => "Old town"}], %{
        "Varonne" => {:ok, @varonne, %{attempt: 1}}
      })

      assert asked() == ["Varonne"]
      assert towns(ctx) == [["Varonne", "found", "Varonne, Ostrel, Varonia"]]
    end

    test "a day's changed near is found in the call, and words no longer in force go with it",
         ctx do
      create!(ctx)
      _ = asked()

      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => "Kestrin"}], %{"Kestrin" => @nowhere})

      assert towns(ctx) == [
               ["Kestrin", "none", nil],
               ["Varonne", "found", "Varonne, Ostrel, Varonia"]
             ]

      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => "Brisa"}], %{
        "Brisa" => {:ok, @brisa, %{attempt: 1}}
      })

      assert asked() == ["Kestrin", "Brisa"]

      assert towns(ctx) == [
               ["Brisa", "found", "Brisa, Ostrel, Varonia"],
               ["Varonne", "found", "Varonne, Ostrel, Varonia"]
             ]

      # A cleared day near goes back to the trip's town, which stays.
      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => ""}])
      assert towns(ctx) == [["Varonne", "found", "Varonne, Ostrel, Varonia"]]
    end

    test "a removed day keeps its town while it can be restored", ctx do
      create!(ctx)

      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => "Brisa"}], %{
        "Brisa" => {:ok, @brisa, %{}}
      })

      day_two = Enum.find(trip!(ctx).rows, &(&1.near == "Brisa"))

      params = %{
        "client_msg_id" => "mac-1",
        "trip_id" => day_two.trip_id,
        "op" => %{"op" => "remove", "row_id" => day_two.id}
      }

      assert {:ok, %{duplicate: false}} = Registry.device_edit(params, :independent, opts(ctx))

      assert Enum.any?(towns(ctx), &(hd(&1) == "Brisa"))
    end
  end

  # A town a call could not look up for a reason that heals is looked up
  # again later: the placer is told, once, and only then.
  describe "a town left for later" do
    test "a near left for a reason that heals tells the placer; one answered or refused does not",
         ctx do
      create!(ctx, %{
        "Varonne" => {:error, "rate_limited: Apple Maps is throttling", %{attempt: 1}}
      })

      assert_received :town_placer_told

      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => "Brisa"}], %{
        "Varonne" => @nowhere,
        "Brisa" => @nowhere
      })

      refute_received :town_placer_told

      refused = {:error, "computer_refused: studio Mac: no", %{attempt: 1}}
      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => "Kestrin"}], %{"Kestrin" => refused})
      refute_received :town_placer_told
    end

    test "a call asks the nears it set first; the rest past 20 are left for later, and said so",
         ctx do
      edit!(ctx, [%{"op" => "create", "days" => 25}])
      days = for k <- 1..24, do: %{"op" => "day", "day" => k, "near" => "Town #{k}"}
      # A busy Mac stops no geocode, so every near the call asks is sent.
      busy = {:error, "computer_busy: busy", %{attempt: 1}}
      later = Map.new(1..24, &{"Town #{&1}", busy})
      edit!(ctx, days, later)
      _ = asked()

      answer =
        edit!(
          ctx,
          [%{"op" => "day", "day" => 25, "near" => "Kestrin"}],
          Map.put(later, "Kestrin", @nowhere)
        )

      asked = asked()
      assert length(asked) == 20 and "Kestrin" in asked
      assert answer.text =~ ~s(No town found for near "Kestrin")
      assert answer.text =~ ~s("Town 24") and answer.text =~ "Towns not looked up yet:"
      assert_received :town_placer_told
    end
  end

  # Nothing the store is handed raises in its own process: a town of another
  # shape is a refusal, and the Repo answers the next call.
  describe "a town of the wrong shape" do
    test "is refused, never a crash of the store", ctx do
      create!(ctx, %{"Varonne" => @away})
      %{trip: %{id: id}} = trip!(ctx)
      owner = %{trip_id: id, owner_id: "default", agent_id: "main"}

      assert {:error, {:invalid_town, "Varonne"}} =
               Registry.settle_towns(
                 owner,
                 %{"Varonne" => {:found, %{name: "Varonne"}}},
                 %{backend: nil, towns: 1},
                 opts(ctx)
               )

      assert %{towns: %{}} = trip!(ctx)
    end
  end

  describe "the placer's towns" do
    test "the nears in force with no row, across live trips, at most the limit", ctx do
      create!(ctx, %{"Varonne" => @away})

      edit!(ctx, [%{"op" => "day", "day" => 2, "near" => "Brisa"}], %{
        "Varonne" => @away,
        "Brisa" => @away
      })

      %{trip: trip} = trip!(ctx)

      assert {:ok, unresolved} = Registry.unresolved_towns(20, opts(ctx))

      assert Enum.sort_by(unresolved, & &1.words) == [
               %{trip_id: trip.id, owner_id: "default", agent_id: "main", words: "Brisa"},
               %{trip_id: trip.id, owner_id: "default", agent_id: "main", words: "Varonne"}
             ]

      assert {:ok, [_one]} = Registry.unresolved_towns(1, opts(ctx))
    end

    test "a towns-only write keeps the towns in force, moves the rev once and tells devices",
         ctx do
      create!(ctx, %{"Varonne" => @away})
      %{trip: %{id: id, rev: rev}} = trip!(ctx)
      _ = receive do: ({:notified, _changes} -> :ok), after: (0 -> :ok)
      owner = %{trip_id: id, owner_id: "default", agent_id: "main"}

      kept = %{"Varonne" => {:found, @varonne}, "Gone" => {:found, @brisa}}

      assert {:ok, %{changed?: true}} =
               Registry.settle_towns(owner, kept, %{backend: nil, towns: 2}, opts(ctx))

      assert towns(ctx) == [["Varonne", "found", "Varonne, Ostrel, Varonia"]]
      assert trip!(ctx).trip.rev == rev + 1
      assert_received {:notified, %{trips: [%{id: ^id, rev: new_rev}]}}
      assert new_rev == rev + 1

      # Nothing new to keep moves nothing and tells no one.
      assert {:ok, %{changed?: false}} =
               Registry.settle_towns(owner, kept, %{backend: nil, towns: 2}, opts(ctx))

      assert trip!(ctx).trip.rev == rev + 1
      refute_received {:notified, _changes}
    end
  end
end
