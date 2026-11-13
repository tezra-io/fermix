defmodule FermixCore.Trips.RegistryTest do
  # M89 §04, §06, §14: a trip_edit call checked before the store, one
  # transaction, the answer and every refusal's sentence; a device's ops by
  # row id, applied once, what they made reaching the notifier; and who may
  # reach a trip at all. Against a real store in a temp file.
  use ExUnit.Case, async: true

  alias FermixCore.Checklists.Registry, as: ChecklistRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Registry
  alias FermixCore.Trips.Wire
  alias FermixTestSupport.TelemetryCapture

  # Every title, stop, place and id here is invented.
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
    db_path = Path.join(System.tmp_dir!(), "fermix-trips-#{unique}.db")
    repo = :"trips_registry_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  # Every call names its own notifier, which tells the test what it heard.
  defp opts(repo, extra \\ []) do
    test = self()

    notifier = fn changes ->
      send(test, {:announced, changes})
      :ok
    end

    [repo: repo, now: @now, notifier: notifier] ++ extra
  end

  defp edit(repo, trip, ops, context \\ @owner),
    do: Registry.edit(%{"trip" => trip, "ops" => ops}, context, opts(repo))

  defp edit!(repo, trip, ops, context \\ @owner) do
    assert {:ok, answer} = edit(repo, trip, ops, context)
    answer
  end

  defp device(repo, client_msg_id, params, extra \\ []) do
    params = Map.put(params, "client_msg_id", client_msg_id)
    Registry.device_edit(params, :independent, opts(repo, extra))
  end

  defp refusal(result) do
    assert {:error, reason} = result
    Registry.describe_error(reason)
  end

  defp read!(repo, trip_id) do
    assert {:ok, read} = Registry.device_trip(trip_id, true, :independent, repo: repo)
    read
  end

  defp varonne!(repo) do
    edit!(repo, "Varonne", [
      %{"op" => "create", "days" => 2, "starts_on" => "2031-07-04"},
      %{"op" => "day", "day" => 1, "text" => "Harbour"},
      %{"op" => "add", "text" => "Fish market", "day" => 1, "time" => "08:30"},
      %{"op" => "add", "text" => "Dinner at Corvo", "day" => 2, "fixed" => true}
    ])
  end

  describe "a model's call" do
    test "the answer is one line, and touched names the trip with the rows it added", %{
      repo: repo
    } do
      answer = varonne!(repo)

      assert answer.text ==
               "Varonne · rev 1 · created; named Day 1 \"Harbour\"; 2 stops added · 2 days, 2 stops"

      assert [%{trip_id: "tr_" <> _ = trip_id, title: "Varonne", rows: [_day, _fish, _dinner]}] =
               answer.touched

      assert_received {:announced,
                       %{owner_id: "default", trips: [%{id: ^trip_id, rev: 1, made: made}]}}

      assert made == %{}

      assert edit!(repo, "Varonne", [%{"op" => "remove_trip"}]).text ==
               "Varonne · removed; it can be restored from the Fermix app for 30 days"
    end

    test "over 100 ops is refused before the store", %{repo: _repo} do
      ops = for i <- 1..101, do: %{"op" => "add", "text" => "Stop #{i}", "day" => 1}
      unused = :"no_repo_#{System.unique_integer([:positive])}"

      assert refusal(edit(unused, "Varonne", ops)) ==
               "One call carries at most 100 ops; split the rest into another call."
    end

    test "texts, HH:MM, minutes and IANA zones are checked", %{repo: repo} do
      varonne!(repo)

      cases = [
        {%{"op" => "add", "text" => "Ferry", "day" => 1, "time" => "25:00"},
         "time must be a time of day as HH:MM, 00:00 to 23:59."},
        {%{"op" => "add", "text" => "Ferry", "day" => 1, "duration" => 1_441},
         "duration must be whole minutes, 1 to 1440, or 0 to clear it."},
        {%{"op" => "day", "day" => 1, "timezone" => "Mars/Olympus"},
         "\"Mars/Olympus\" is not a time zone; give an IANA zone such as Europe/Lisbon."},
        {%{"op" => "add", "text" => String.duplicate("w", 201), "day" => 1},
         "The text is over 200 characters."},
        {%{"op" => "add", "text" => "Fish\nmarket", "day" => 1},
         "The text must be words on one line, with no control characters."},
        {%{"op" => "dates", "starts_on" => "2031-02-30"}, "starts_on must be a date, YYYY-MM-DD."}
      ]

      for {op, sentence} <- cases do
        assert refusal(edit(repo, "Varonne", [%{"op" => "rename", "text" => "Other"}, op])) ==
                 sentence <> " Nothing in this call was changed (op 2)."
      end

      assert {:ok, %{trip: %{title: "Varonne"}}} =
               Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: repo)
    end

    test "a live title is refused with the lists' sentence, and the call changes nothing", %{
      repo: repo
    } do
      varonne!(repo)
      edit!(repo, "Ostrel", [%{"op" => "create"}])

      assert refusal(edit(repo, "VARONNE", [%{"op" => "create"}])) ==
               "A trip named \"VARONNE\" already exists; name another, or change that one. " <>
                 "Nothing in this call was changed (op 1)."

      assert refusal(
               edit(repo, "Ostrel", [
                 %{"op" => "add", "text" => "Lighthouse", "day" => 1},
                 %{"op" => "rename", "text" => "varonne"}
               ])
             ) =~ "A trip named \"varonne\" already exists"

      assert {:ok, %{rows: [%{kind: :day}]}} =
               Repo.trips_call({:read_trip, "default", "main", "Ostrel"}, server: repo)
    end

    # R2#3: the guard measures what a pull with the removed rows sends, so the
    # store hands it the trip's removed rows, those older than 30 days aside.
    test "the size guard counts the removed rows a pull carries while the store keeps them", %{
      repo: repo
    } do
      big = fn i ->
        %{
          "op" => "add",
          "text" => "#{i} " <> String.duplicate("€", 190),
          "note" => String.duplicate("€", 1_000),
          "day" => 1
        }
      end

      call = fn title, ops, now ->
        Registry.edit(
          %{"trip" => title, "ops" => ops},
          @owner,
          Keyword.put(opts(repo), :now, now)
        )
      end

      batch = fn title, from, now -> call.(title, Enum.map(from..(from + 19), big), now) end
      earlier = DateTime.add(@now, -31 * 86_400, :second)

      for {title, removed_on, refused?} <- [{"Varonne", @now, true}, {"Ostrel", earlier, false}] do
        assert {:ok, %{touched: [%{trip_id: id}]}} =
                 call.(title, [%{"op" => "create"}], removed_on)

        for k <- 0..4, do: assert({:ok, _answer} = batch.(title, k * 20 + 1, removed_on))
        removes = for n <- 2..101, do: %{"op" => "remove", "n" => n}
        assert {:ok, _answer} = call.(title, removes, removed_on)

        for k <- 0..4, do: assert({:ok, _answer} = batch.(title, 200 + k * 20, @now))
        sixth = batch.(title, 300, @now)
        assert match?({:error, {:trip_too_large, ^title}}, sixth) == refused?

        read = read!(repo, id)
        assert Wire.bytes(read.trip, read.rows, read.removed_rows) <= Ops.max_wire_bytes()
      end
    end

    test "the row cap, the size guard, the only day and an unknown trip each say so", %{
      repo: repo
    } do
      assert Registry.describe_error({:trip_full, "Varonne"}) ==
               "A trip holds at most 1000 days and stops together; remove some, or make the " <>
                 "rest another trip."

      assert Registry.describe_error({:trip_too_large, "Varonne"}) ==
               "That would make \"Varonne\" too large to send to the owner's devices; shorten " <>
                 "its notes, or make the rest another trip."

      varonne!(repo)

      assert refusal(edit(repo, "Nowhere", [%{"op" => "remove_trip"}])) ==
               ~s(No trip is named "Nowhere"; the trips are "Varonne". To make one, start the ) <>
                 "call with a create op, and only when the owner names a new trip."

      assert refusal(
               edit(repo, "Varonne", [
                 %{"op" => "remove", "n" => 1},
                 %{"op" => "remove", "n" => 2}
               ])
             ) ==
               "A trip keeps at least one day; remove the trip instead. " <>
                 "Nothing in this call was changed (op 2)."
    end

    test "a fixed stop whose date moved is named in the answer", %{repo: repo} do
      varonne!(repo)

      assert edit!(repo, "Varonne", [%{"op" => "move", "n" => 1, "day" => 2}]).text ==
               "Varonne · rev 2 · moved Day 1 to Day 2 · 2 days, 2 stops\n" <>
                 "Dates moved: [4] \"Dinner at Corvo\" (fixed) is now Fri 4 Jul 2031."
    end
  end

  describe "the owner's devices" do
    test "every device op by row id; a row another edit removed is refused with pull-again", %{
      repo: repo
    } do
      assert {:ok, %{trip_id: trip_id, made: trip_id, duplicate: false}} =
               device(repo, "mac-1", %{"op" => %{"op" => "create", "title" => "Kyoto Hills"}})

      [%{id: day_id}] = read!(repo, trip_id).rows
      on = fn op -> %{"trip_id" => trip_id, "op" => op} end

      assert {:ok, %{made: stop_id}} =
               device(
                 repo,
                 "mac-2",
                 on.(%{"op" => "add", "text" => "Temple", "day_id" => day_id, "place" => @inn})
               )

      assert {:ok, %{made: day_two}} =
               device(repo, "mac-3", on.(%{"op" => "day", "text" => "Lake"}))

      assert {:ok, _} =
               device(
                 repo,
                 "mac-4",
                 on.(%{"op" => "edit", "row_id" => stop_id, "time" => "10:00"})
               )

      assert {:ok, _} =
               device(
                 repo,
                 "mac-5",
                 on.(%{"op" => "move", "row_id" => stop_id, "day_id" => day_two})
               )

      assert {:ok, _} = device(repo, "mac-6", on.(%{"op" => "move", "row_id" => day_two}))
      assert {:ok, _} = device(repo, "mac-7", on.(%{"op" => "rename", "text" => "Kyoto"}))

      assert {:ok, _} =
               device(repo, "mac-8", on.(%{"op" => "dates", "starts_on" => "2031-10-01"}))

      assert {:ok, _} = device(repo, "mac-9", on.(%{"op" => "remove", "row_id" => stop_id}))
      assert {:ok, _} = device(repo, "mac-10", on.(%{"op" => "restore", "row_id" => stop_id}))

      read = read!(repo, trip_id)
      assert %{title: "Kyoto", starts_on: ~D[2031-10-01], rev: 10} = read.trip

      assert [{:day, "Lake"}, {:stop, "Temple"}, {:day, ""}] ==
               Enum.map(read.rows, &{&1.kind, &1.text})

      assert {:ok, _} = device(repo, "mac-11", on.(%{"op" => "remove", "row_id" => stop_id}))

      assert refusal(
               device(repo, "mac-12", on.(%{"op" => "edit", "row_id" => stop_id, "text" => "x"}))
             ) ==
               "That row is not in this trip any more; pull the trip again."

      assert {:ok, _} = device(repo, "mac-13", on.(%{"op" => "remove_trip"}))

      assert refusal(device(repo, "mac-14", on.(%{"op" => "rename", "text" => "Again"}))) ==
               "No trip has that id; it may have been removed more than 30 days ago."

      assert {:ok, _} = device(repo, "mac-15", on.(%{"op" => "restore"}))
      assert %{removed_rows: [%{id: ^stop_id}]} = read!(repo, trip_id)
    end

    test "made reaches the notifier by client_msg_id", %{repo: repo} do
      assert {:ok, %{trip_id: trip_id}} =
               device(repo, "mac-1", %{"op" => %{"op" => "create", "title" => "Kyoto"}})

      assert_received {:announced,
                       %{owner_id: "default", trips: [%{id: ^trip_id, rev: 1, made: made}]}}

      assert made == %{"mac-1" => trip_id}

      [%{id: day_id}] = read!(repo, trip_id).rows

      add = %{
        "trip_id" => trip_id,
        "op" => %{"op" => "add", "text" => "Temple", "day_id" => day_id}
      }

      assert {:ok, %{made: stop_id}} = device(repo, "phone-1", add, made_via: "phone")

      assert_received {:announced,
                       %{trips: [%{id: ^trip_id, rev: 2, made: %{"phone-1" => ^stop_id}}]}}

      assert %{made_via: "phone"} = Enum.find(read!(repo, trip_id).rows, &(&1.id == stop_id))
    end

    # R3#10: a client_msg_id names one edit of any kind; one a list's edit used
    # refuses a trip's with its own sentence, never the store's words.
    test "a client_msg_id a list's edit used refuses the trip's edit with its own sentence", %{
      repo: repo
    } do
      packing = %{"client_msg_id" => "once-1", "op" => %{"op" => "create", "title" => "Packing"}}
      assert {:ok, _made} = ChecklistRegistry.device_edit(packing, :independent, opts(repo))

      assert {:error, reason} =
               device(repo, "once-1", %{"op" => %{"op" => "create", "title" => "Varonne"}})

      assert Registry.describe_error(reason) ==
               "That client_msg_id already named another edit, so nothing changed; send each " <>
                 "edit with an id of its own."

      assert Registry.error_tag(reason) == "client_msg_id_used"
      assert {:ok, []} = Registry.device_index(:independent, repo: repo)
    end

    test "a duplicate announces nothing", %{repo: repo} do
      create = %{"op" => %{"op" => "create", "title" => "Kyoto"}}
      assert {:ok, %{duplicate: false}} = device(repo, "mac-1", create)
      assert_received {:announced, _changes}

      assert {:ok, %{duplicate: true}} = device(repo, "mac-1", create)
      refute_received {:announced, _changes}
    end

    test "the index and a trip are read by id, and only by the owner's own app", %{repo: repo} do
      %{touched: [%{trip_id: trip_id}]} = varonne!(repo)

      assert {:ok,
              [%{id: ^trip_id, title: "Varonne", days: 2, stops: 2, starts_on: ~D[2031-07-04]}]} =
               Registry.device_index(:independent, repo: repo)

      assert {:ok, %{trip: %{id: ^trip_id}, rows: [_, _, _, _], removed_rows: []}} =
               Registry.device_trip(trip_id, false, :independent, repo: repo)

      for caller <- [:started, :detached, nil] do
        assert Registry.device_index(caller, repo: repo) == {:error, :not_owner}
        assert Registry.device_trip(trip_id, false, caller, repo: repo) == {:error, :not_owner}
      end

      assert Registry.describe_error(:not_owner) ==
               "Only the owner's own Fermix app can read or change the owner's trips."

      assert {:error, :not_owner} =
               Registry.device_edit(
                 %{"client_msg_id" => "x-2", "op" => %{"op" => "create", "title" => "Y"}},
                 :started,
                 opts(repo)
               )
    end

    test "a device's edit says so in its telemetry", %{repo: repo} do
      TelemetryCapture.attach([[:fermix, :trip, :edit]], :emitter)

      assert {:ok, _} = device(repo, "mac-1", %{"op" => %{"op" => "create", "title" => "Kyoto"}})

      assert_receive {:telemetry, [:fermix, :trip, :edit], %{trips: 1, ops: 1, lookups: 0},
                      %{component: "trips", outcome: :ok, made_via: "mac", error_code: nil}}

      assert {:error, _} =
               device(repo, "mac-2", %{"op" => %{"op" => "create", "title" => "kyoto"}})

      assert_receive {:telemetry, [:fermix, :trip, :edit], %{trips: 0, ops: 1},
                      %{outcome: :refused, made_via: "mac", error_code: "title_taken"}}
    end
  end

  describe "trust (§14)" do
    test "only the owner's private turn or call, or a job naming the tool, reaches a trip", %{
      repo: repo
    } do
      for context <- [
            Map.put(@owner, :chat_type, "group"),
            Map.put(@owner, :source_trust, :guest),
            Map.put(@owner, :subagent_depth, 1)
          ] do
        assert refusal(edit(repo, "Varonne", [%{"op" => "create"}], context)) ==
                 "trip_edit is available only on the owner's own turn in a private chat or a " <>
                   "voice call, or in a scheduled job set up there that names it; group chats " <>
                   "and guest, delegated and other runs cannot read or change the owner's trips."
      end

      job = %{
        agent_name: "scheduled:job_1",
        conversation_key: {:scheduled_job, "job_1", "run_1"},
        source_trust: :operator,
        effective_trust: :operator,
        effective_allowed_tools: ["trip_read"],
        outside_sources: MapSet.new()
      }

      assert {:error, {:not_permitted, "trip_edit"}} =
               edit(repo, "Varonne", [%{"op" => "create"}], job)

      named = %{job | effective_allowed_tools: ["trip_edit"]}
      edit!(repo, "Varonne", [%{"op" => "create"}], named)

      assert {:ok, %{rows: [%{made_via: "job"}]}} =
               Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: repo)
    end

    # D9: a turn that read outside content changes a trip as any owner turn
    # does, through the store; what a stop's words or note then say is stamped.
    test "after outside content every op lands, a stop added or reworded stamped", %{repo: repo} do
      varonne!(repo)
      tainted = %{@owner | outside_sources: MapSet.new([{:tool, "web_fetch"}])}

      edit!(repo, "Pellmoor", [%{"op" => "create", "days" => 2}], tainted)

      # Fish market [3], Dinner at Corvo [4]; Day 3 and Day 4 are made [5] and [6].
      for op <- [
            %{"op" => "add", "text" => "Night market", "day" => 4},
            %{"op" => "edit", "n" => 3, "text" => "Fish auction"},
            %{"op" => "edit", "n" => 4, "note" => "Table by the window"},
            %{"op" => "move", "n" => 7, "day" => 1},
            %{"op" => "day", "day" => 2, "text" => "Old town"},
            %{"op" => "remove", "n" => 6},
            %{"op" => "dates", "starts_on" => "2031-08-01"},
            %{"op" => "rename", "text" => "Varonne coast"}
          ] do
        edit!(repo, "Varonne", [op], tainted)
      end

      assert {:ok, %{trip: trip, rows: rows}} =
               Repo.trips_call({:read_trip, "default", "main", "Varonne coast"}, server: repo)

      assert trip.starts_on == ~D[2031-08-01]
      assert Enum.map(Ops.days(rows), & &1.row.text) == ["Harbour", "Old town", ""]

      assert rows |> Enum.filter(& &1.stamped) |> Enum.map(& &1.text) |> Enum.sort() ==
               ["Dinner at Corvo", "Fish auction", "Night market"]

      edit!(repo, "Varonne coast", [%{"op" => "remove_trip"}], tainted)
      assert {:ok, [%{title: "Pellmoor"}]} = Registry.names(@owner, repo: repo)
    end

    test "an edit's telemetry carries counts and the caller's session, never a title", %{
      repo: repo
    } do
      session = "main-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach([[:fermix, :trip, :edit]], session_id: session)

      edit!(repo, "Varonne", [%{"op" => "create"}], Map.put(@owner, :session_id, session))

      assert_receive {:telemetry, [:fermix, :trip, :edit], measurements, metadata}

      assert measurements == %{
               duration_us: measurements.duration_us,
               trips: 1,
               ops: 1,
               lookups: 0,
               placed: 0,
               offered: 0,
               not_found: 0,
               not_looked_up: 0
             }

      assert %{component: "trips", made_via: "chat", outcome: :ok, session_id: ^session} =
               metadata

      refute inspect(metadata) =~ "Varonne"
    end
  end
end
