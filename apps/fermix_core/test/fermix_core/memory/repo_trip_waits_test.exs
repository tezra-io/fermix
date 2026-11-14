defmodule FermixCore.Memory.RepoTripWaitsTest do
  # M89 D13 B: migration 65 keeps, beside a stop, the place words a trip_edit
  # could not look up for a reason that heals by waiting (`trip_waits`, in
  # memory.db alone), in the same transaction as the edit; any later change
  # that sets or clears the stop's place, edits its words or removes it ends
  # the wait, whoever makes it; the placer's own write checks each wait still
  # stands before it places, so it never overwrites a newer choice.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Trips.Registry
  alias FermixCore.Trips.Waiting

  @version 65
  # Every title, stop, place and id here is invented.
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
  @town "Varonne, Portugal"
  @tower %{latitude: 41.1402, longitude: -8.6113}
  @away {:error, "computer_away: no Mac that looks places up is online", %{attempt: 0}}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-waits-#{unique}.db")
    repo = :"trip_waits_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: :holder))

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path, holder: holder}
  end

  defp place(name, id) do
    %{
      name: name,
      location: @tower,
      address: "#{id} Rua Inventada, Varonne",
      apple_place_id: "I#{id}",
      source_url: "https://maps.apple.com/place?place-id=I#{id}"
    }
  end

  defp opts(ctx) do
    test = self()

    [
      repo: ctx.repo,
      now: @now,
      reply_blocks: ctx.holder,
      notifier: fn _changes -> :ok end,
      placer: fn -> send(test, :placer_told) && :ok end
    ]
  end

  defp edit!(ctx, ops, answers \\ %{}) do
    context = Map.put(@owner, :place_lookup, fn %{query: query} -> Map.fetch!(answers, query) end)
    assert {:ok, answer} = Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts(ctx))
    answer
  end

  defp device!(ctx, id, trip_id, op) do
    params = %{"client_msg_id" => id, "trip_id" => trip_id, "op" => op}
    assert {:ok, %{duplicate: false}} = Registry.device_edit(params, :independent, opts(ctx))
  end

  defp create!(ctx), do: edit!(ctx, [%{"op" => "create", "days" => 2, "near" => @town}])

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

  defp waits(ctx) do
    with_raw_conn(ctx.db_path, fn conn ->
      query!(
        conn,
        "SELECT r.n, w.words, w.reason, w.tries FROM trip_waits AS w " <>
          "JOIN trip_rows AS r ON r.id = w.row_id ORDER BY r.n"
      )
    end)
  end

  defp trip!(ctx) do
    assert {:ok, read} =
             Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: ctx.repo)

    read
  end

  defp stop!(ctx, n), do: Enum.find(trip!(ctx).rows, &(&1.n == n))

  describe "the migration" do
    test "a fresh store gets the waits table and version 65 once", ctx do
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == @version)) == 1
      assert :ok = Repo.migrate(server: ctx.repo)
      assert {:ok, versions} = Repo.migration_versions(server: ctx.repo)
      assert Enum.count(versions, &(&1 == @version)) == 1

      with_raw_conn(ctx.db_path, fn conn ->
        assert [["trip_waits"]] =
                 query!(conn, "SELECT name FROM sqlite_master WHERE name = 'trip_waits'")
      end)
    end

    test "a store at 64 with trips gains it on open, every trip and row kept", ctx do
      create!(ctx)

      edit!(ctx, [%{"op" => "add", "text" => "Lunch", "day" => 1, "place" => "Prado"}], %{
        "Prado" => @away
      })

      %{trip: trip, rows: rows} = trip!(ctx)
      :ok = stop_supervised(ctx.repo)

      with_raw_conn(ctx.db_path, fn conn ->
        :ok = Sqlite3.execute(conn, "DROP TABLE trip_waits")
        :ok = Sqlite3.execute(conn, "DELETE FROM schema_migrations WHERE version = #{@version}")
        assert [[64]] = query!(conn, "SELECT MAX(version) FROM schema_migrations")
      end)

      reopened = :"#{ctx.repo}_at_64"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path})
      assert {:ok, versions} = Repo.migration_versions(server: reopened)
      assert Enum.count(versions, &(&1 == @version)) == 1

      assert {:ok, %{trip: ^trip, rows: ^rows}} =
               Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: reopened)

      # A stop from before 65 waits for nothing: its words were never kept.
      assert waits(ctx) == []
    end
  end

  describe "what waits" do
    test "a stop waits only when its lookup could not run for a reason that heals", ctx do
      create!(ctx)

      answers = [
        {"Away", @away, "computer_away"},
        {"Slow", {:error, "computer_timed_out: no answer", %{attempt: 1}}, "computer_timed_out"},
        {"Busy", {:error, "computer_busy: busy", %{attempt: 1}}, "computer_busy"},
        {"Paced", {:error, "rate_limited: spent for 3 days", %{attempt: 1}}, "rate_limited"},
        {"Late", {:error, "deadline: busy", %{attempt: 0}}, "deadline"},
        {"Plan", {:error, "plan_excludes_place_search: no plan", %{attempt: 1}}, nil},
        {"Off", {:error, "computer_off: switched off", %{attempt: 1}}, nil},
        {"Refused", {:error, "computer_refused: no", %{attempt: 1}}, nil},
        {"Broken", {:error, "network: unreachable", %{attempt: 1}}, nil},
        {"Nothing", {:ok, [], %{}}, nil},
        {"Elsewhere", {:ok, [place("Harbour Rooms", 9)], %{}}, nil}
      ]

      for {words, answer, _waits} <- answers do
        edit!(ctx, [%{"op" => "add", "text" => words, "day" => 1, "place" => words}], %{
          words => answer
        })
      end

      expected =
        for {{words, _answer, reason}, n} <- Enum.with_index(answers, 3),
            reason != nil,
            do: [n, words, reason, 0]

      assert waits(ctx) == expected
    end

    test "an edit's words that wait keep its place, and wait to replace it", ctx do
      create!(ctx)
      prado = place("Prado", 1)

      edit!(ctx, [%{"op" => "add", "text" => "Lunch", "day" => 1, "place" => "Prado"}], %{
        "Prado" => {:ok, [prado], %{}}
      })

      answer =
        edit!(ctx, [%{"op" => "edit", "n" => 3, "place" => "Cais Velho"}], %{
          "Cais Velho" => @away
        })

      assert answer.text =~ ~S|[3] "Lunch" (place unchanged)|
      assert %{place: %{"name" => "Prado"}} = stop!(ctx, 3)
      assert waits(ctx) == [[3, "Cais Velho", "computer_away", 0]]
    end

    test "a wait records whether its call had read outside content", ctx do
      create!(ctx)
      outside = Map.put(@owner, :outside_sources, MapSet.new([:web_fetch]))

      for {context, words} <- [{@owner, "Clean"}, {outside, "Read"}] do
        context = Map.put(context, :place_lookup, fn _request -> @away end)
        ops = [%{"op" => "add", "text" => words, "day" => 1, "place" => words}]

        assert {:ok, _answer} =
                 Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts(ctx))
      end

      flags =
        with_raw_conn(ctx.db_path, fn conn ->
          query!(conn, "SELECT words, outside FROM trip_waits ORDER BY words")
        end)

      assert flags == [["Clean", 0], ["Read", 1]]
    end

    test "a call that saves a wait tells the placer; one that saves none does not", ctx do
      create!(ctx)
      refute_received :placer_told

      edit!(ctx, [%{"op" => "add", "text" => "Lunch", "day" => 1, "place" => "Prado"}], %{
        "Prado" => {:ok, [], %{}}
      })

      refute_received :placer_told

      edit!(ctx, [%{"op" => "add", "text" => "Quay", "day" => 1, "place" => "Cais"}], %{
        "Cais" => @away
      })

      assert_received :placer_told
    end
  end

  describe "a newer choice ends the wait, whoever makes it" do
    setup ctx do
      create!(ctx)

      ops =
        for {text, day} <- [{"A", 1}, {"B", 1}, {"C", 1}, {"D", 2}, {"E", 2}, {"F", 2}],
            do: %{"op" => "add", "text" => text, "day" => day, "place" => "Spot " <> text}

      answers = Map.new(~w(A B C D E F), &{"Spot " <> &1, @away})
      edit!(ctx, ops, answers)
      # Days are [1] and [2]; the stops are [3]..[8], A to F.
      assert length(waits(ctx)) == 6
      :ok
    end

    test "the model's words, place or cleared place; never its time, note or move", ctx do
      edit!(ctx, [
        %{"op" => "edit", "n" => 3, "time" => "10:00", "note" => "Early"},
        %{"op" => "move", "n" => 4, "day" => 2},
        %{"op" => "edit", "n" => 5, "text" => "C at noon"},
        %{"op" => "edit", "n" => 6, "place" => ""}
      ])

      assert Enum.map(waits(ctx), &hd/1) == [3, 4, 7, 8]

      edit!(ctx, [%{"op" => "edit", "n" => 7, "place" => "Torre"}], %{
        "Torre" => {:ok, [place("Torre", 2)], %{}}
      })

      assert Enum.map(waits(ctx), &hd/1) == [3, 4, 8]
    end

    # The blocker: newer place words end the old wait whatever they come to,
    # so the placer never places the old words over them; words of their own
    # that heal wait in its place, alone.
    test "the model's newer place words end the wait though they place nothing", ctx do
      answers = [
        {3, "Tasca do Zé", {:ok, [], %{}}},
        {4, "Harbour", {:ok, [place("Harbour Rooms", 9)], %{}}},
        {5, "Plan", {:error, "plan_excludes_place_search: no plan", %{attempt: 1}}},
        {6, "Off", {:error, "computer_off: switched off", %{attempt: 1}}},
        {7, "Refused", {:error, "computer_refused: no", %{attempt: 1}}}
      ]

      for {n, words, answer} <- answers do
        edit!(ctx, [%{"op" => "edit", "n" => n, "place" => words}], %{words => answer})
      end

      assert Enum.map(waits(ctx), &hd/1) == [8]

      edit!(ctx, [%{"op" => "edit", "n" => 8, "place" => "Ribeira"}], %{"Ribeira" => @away})
      assert waits(ctx) == [[8, "Ribeira", "computer_away", 0]]
    end

    test "a device's place or words", ctx do
      [_d1, a, b | _rest] = trip!(ctx).rows
      device!(ctx, "dev-1", a.trip_id, %{"op" => "edit", "row_id" => a.id, "text" => "A2"})

      device!(ctx, "dev-2", b.trip_id, %{
        "op" => "edit",
        "row_id" => b.id,
        "place" => %{"name" => "Quay", "location" => %{"latitude" => 41.1, "longitude" => -8.6}}
      })

      assert Enum.map(waits(ctx), &hd/1) == [5, 6, 7, 8]
    end

    test "a stop or a day removed, and a restore brings back no wait", ctx do
      edit!(ctx, [%{"op" => "remove", "n" => 3}, %{"op" => "remove", "n" => 2}])
      assert Enum.map(waits(ctx), &hd/1) == [4, 5]

      %{trip: trip} = trip!(ctx)

      {:ok, %{removed_rows: removed}} =
        Registry.device_trip(trip.id, true, :independent, opts(ctx))

      a = Enum.find(removed, &(&1.n == 3))
      device!(ctx, "dev-3", trip.id, %{"op" => "restore", "row_id" => a.id})

      assert %{n: 3} = stop!(ctx, 3)
      assert Enum.map(waits(ctx), &hd/1) == [4, 5]
    end

    test "the trip removed: every wait of it", ctx do
      edit!(ctx, [%{"op" => "remove_trip"}])
      assert waits(ctx) == []
    end
  end

  describe "the placer's write" do
    setup ctx do
      create!(ctx)

      edit!(ctx, [%{"op" => "add", "text" => "Lunch", "day" => 1, "place" => "Prado"}], %{
        "Prado" => @away
      })

      %{trip: trip, rows: rows} = trip!(ctx)
      stop = Enum.find(rows, &(&1.n == 3))
      owner = %{trip_id: trip.id, owner_id: "default", agent_id: "main"}
      %{trip: trip, stop: stop, owner: owner}
    end

    defp placer_opts(ctx, test) do
      [
        repo: ctx.repo,
        now: @now,
        session_id: "trip_place:test",
        notifier: fn changes -> send(test, {:notified, changes}) && :ok end
      ]
    end

    defp found, do: %{outcomes: [], sent: [], lookups: 1, stop_reason: nil, stop_code: nil}

    test "a wait a newer edit replaced is left as the edit left it", ctx do
      {:ok, %{waits: [wait]}} = Registry.take_waits(@now, 20, opts(ctx))
      found = %{outcomes: [{ctx.stop.id, {:placed, place("Prado", 1)}}], sent: [ctx.stop.id]}
      [result] = Waiting.settle([wait], found, @now)

      # The owner picks a place on their Mac first.
      device!(ctx, "dev-4", ctx.trip.id, %{
        "op" => "edit",
        "row_id" => ctx.stop.id,
        "place" => %{"name" => "Pick", "location" => %{"latitude" => 41.1, "longitude" => -8.6}}
      })

      %{trip: %{rev: rev}} = trip!(ctx)

      assert {:ok, %{changed?: false, placed: [], superseded: 1}} =
               Registry.place_waiting(
                 ctx.owner,
                 [result],
                 %{found: found(), backend: "computer"},
                 placer_opts(ctx, self())
               )

      refute_received {:notified, _changes}
      assert %{trip: %{rev: ^rev}} = trip!(ctx)
      assert %{place: %{"name" => "Pick"}} = stop!(ctx, 3)
    end

    test "a wait older than seven days is taken away, not looked up", ctx do
      later = DateTime.add(@now, 8 * 86_400, :second)

      assert {:ok, %{expired: 1, waits: [], total: 0}} = Registry.take_waits(later, 20, opts(ctx))

      assert waits(ctx) == []
      assert %{place: nil} = stop!(ctx, 3)
    end
  end
end
