defmodule FermixChannels.Companion.ConnectionTripsTest do
  @moduledoc """
  M89 §06, companion protocol 8, end to end over a real 0600 Unix socket and
  a throwaway repo: the lists' family again for the owner's trips. The
  owner's Mac pulls the index and its trips, holds at most 16 apart from its
  lists, edits by row id through the same transaction the model uses, once
  per `client_msg_id`, asks for a trip's shared form, and every holder hears
  each committed change as the whole trip, at most once per window of the
  trips' own, whoever made it. A connection the daemon started reads and
  changes nothing, a version 7 connection has no trip event, and a turn says
  it draws trips only when its connection pulled the trips index.

  Most tests deliver the coalescing window's end by hand (`flush!/1`), so no
  assertion races a clock; one keeps the real 100 ms window.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.ChecklistNotifier
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Checklists.Registry, as: ChecklistRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.Geo
  alias FermixCore.Trips.Registry, as: TripRegistry
  alias FermixTestSupport.ParentProcess

  # A line's arrival over the socket on a loaded runner.
  @arrival_ms 10_000
  # A window no test outlives: its end comes from `flush!/1`.
  @manual_window_ms 600_000

  @owner_turn %{
    agent_name: "main",
    conversation_key: {"companion", "main", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    channel: "companion",
    outside_sources: MapSet.new()
  }

  # Every title, stop, place and address here is invented.
  @tower %{
    "name" => "Torre de Vale Escuro",
    "location" => %{"latitude" => 38.5412, "longitude" => -27.2105},
    "address" => "Rua da Torre 4, Varonne"
  }
  @tavern %{
    "name" => "Tasca Pedra Negra",
    "location" => %{"latitude" => 38.544, "longitude" => -27.2071},
    "canonical_url" => "https://pedranegra.example/"
  }

  @trip_events [
    %{"type" => "trips_pull", "profile_id" => "main"},
    %{"type" => "trip_pull", "profile_id" => "main", "trip_id" => "tr_4q8m2x7v1d"},
    %{
      "type" => "trip_edit",
      "client_msg_id" => "v7-1",
      "profile_id" => "main",
      "op" => %{"op" => "create", "title" => "Orvenne"}
    },
    %{
      "type" => "trip_share",
      "client_msg_id" => "v7-2",
      "profile_id" => "main",
      "trip_id" => "tr_4q8m2x7v1d"
    }
  ]

  defmodule GatewayStub do
    def ingest([message], opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, message})
      :ok
    end
  end

  setup do
    test_pid = self()
    unique = System.unique_integer([:positive])
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("companion-trips")
    repo = :"companion_trips_repo_#{unique}"
    registry = :"companion_trips_registry_#{unique}"
    connections = :"companion_trips_sup_#{unique}"
    socket_path = Path.join(System.tmp_dir!(), "fermix-ctrips-#{unique}.sock")

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(dir)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    queue_owner = start_supervised!({Task, fn -> forward(test_pid) end}, id: :queue_owner)

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Registry, keys: :duplicate, name: registry})
    store_opts = [repo: repo, agent_id: "agent-t", owner_id: "owner-t"]

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil,
         boot_epoch: "boot-trips",
         store_opts: [transport: "companion"] ++ store_opts,
         recover?: false}
      )

    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         schedule: fn _message, _delay -> make_ref() end,
         announce: fn _profile, _card, _transport -> :ok end}
      )

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    kept_opts = [repo: repo, notifier: &ChecklistNotifier.changed(&1, registry)]

    endpoint_opts = [
      name: :"companion_trips_endpoint_#{unique}",
      socket_path: socket_path,
      max_clients: 4,
      connection_supervisor: connections,
      connection_opts: [
        registry: registry,
        approvals: approvals,
        checklist_opts: kept_opts,
        checklist_window_ms: @manual_window_ms,
        trip_opts: kept_opts,
        trip_window_ms: @manual_window_ms,
        request_opts: [
          store_opts: store_opts,
          request_coordinator: coordinator,
          gateway: GatewayStub,
          agent_server: queue_owner,
          engine_role: %{role: :primary, primary: nil}
        ],
        primary_epoch: fn -> {:ok, 2} end
      ]
    ]

    start_supervised!({Endpoint, endpoint_opts})

    %{
      socket_path: socket_path,
      registry: registry,
      trip_opts: kept_opts,
      endpoint_opts: endpoint_opts
    }
  end

  # --- what the model makes and the device reads -------------------------------------

  defp model_trip!(ctx, params) do
    {:ok, _answer} = TripRegistry.edit(params, @owner_turn, ctx.trip_opts)
  end

  # Two days from Saturday 5 July 2031: the old town, then the harbour.
  defp varonne!(ctx) do
    model_trip!(ctx, %{
      "trip" => "Varonne weekend",
      "ops" => [
        %{"op" => "create", "starts_on" => "2031-07-05", "days" => 2},
        %{"op" => "day", "day" => 1, "text" => "Old town"},
        %{"op" => "add", "text" => "Torre de Vale Escuro", "day" => 1, "time" => "10:00"},
        %{"op" => "add", "text" => "Coffee by the walls", "day" => 1},
        %{
          "op" => "add",
          "text" => "Dinner at Pedra Negra",
          "day" => 1,
          "time" => "20:00",
          "fixed" => true,
          "note" => "Table for two"
        },
        %{"op" => "add", "text" => "Boat to the lighthouse", "day" => 2, "time" => "11:30"}
      ]
    })

    {:ok, [trip]} = TripRegistry.device_index(:independent, ctx.trip_opts)
    trip.id
  end

  defp pull_index(client) do
    send_line(client, %{"type" => "trips_pull", "profile_id" => "main"})
    assert %{"type" => "trips", "profile_id" => "main", "trips" => trips} = recv(client)
    trips
  end

  defp pull(client, trip_id, removed \\ nil) do
    pull = %{"type" => "trip_pull", "profile_id" => "main", "trip_id" => trip_id}
    send_line(client, if(removed, do: Map.put(pull, "removed", true), else: pull))
    assert %{"type" => "trip", "profile_id" => "main", "trip" => trip} = recv(client)
    trip
  end

  defp edit(client, id, trip_id, op) do
    payload = %{"type" => "trip_edit", "client_msg_id" => id, "profile_id" => "main", "op" => op}
    send_line(client, if(trip_id, do: Map.put(payload, "trip_id", trip_id), else: payload))
  end

  defp accepted!(client, id, duplicate \\ false) do
    assert %{"type" => "accepted", "client_msg_id" => ^id, "duplicate" => ^duplicate} =
             recv(client)
  end

  defp refused!(client, id) do
    assert %{"type" => "error", "reason" => "request_failed", "client_msg_id" => ^id} =
             refusal = recv(client)

    refusal["message"]
  end

  defp row_id(trip, text), do: Enum.find(trip["rows"], &(&1["text"] == text))["row_id"]
  defp row(trip, id), do: Enum.find(trip["rows"], &(&1["row_id"] == id))

  # The trips' window's end, delivered to every connection of this test.
  defp flush!(registry) do
    for {pid, _version} <- Registry.lookup(registry, "main"), do: send(pid, :trips_flush)
    :ok
  end

  # --- pulling ---------------------------------------------------------------------

  test "the owner's version 8 connection pulls the index and a whole trip with its dates", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)

    assert pull_index(mac) == [
             %{
               "trip_id" => trip_id,
               "title" => "Varonne weekend",
               "days" => 2,
               "stops" => 4,
               "rev" => 1,
               "starts_on" => "2031-07-05",
               "ends_on" => "2031-07-06"
             }
           ]

    trip = pull(mac, trip_id)
    assert %{"trip_id" => ^trip_id, "title" => "Varonne weekend", "rev" => 1} = trip
    assert trip["starts_on"] == "2031-07-05"

    assert [
             %{"kind" => "day", "text" => "Old town", "date" => "2031-07-05"},
             %{"kind" => "stop", "text" => "Torre de Vale Escuro", "time" => "10:00"},
             %{"kind" => "stop", "text" => "Coffee by the walls"} = coffee,
             %{"kind" => "stop", "fixed" => true, "note" => "Table for two"},
             %{"kind" => "day", "date" => "2031-07-06"} = harbour,
             %{"kind" => "stop", "text" => "Boat to the lighthouse"}
           ] = trip["rows"]

    refute Map.has_key?(harbour, "text")
    assert Map.keys(coffee) |> Enum.sort() == ~w(kind row_id text)
    refute Map.has_key?(trip, "removed")
  end

  # C7: a placed stop's leg is the straight line from the placed stop before
  # it in its day, passing over an unplaced one.
  test "places a device gives its stops are drawn with the leg between them", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)
    trip = pull(mac, trip_id)
    tower = row_id(trip, "Torre de Vale Escuro")
    dinner = row_id(trip, "Dinner at Pedra Negra")

    edit(mac, "place-1", trip_id, %{"op" => "edit", "row_id" => tower, "place" => @tower})
    accepted!(mac, "place-1")
    edit(mac, "place-2", trip_id, %{"op" => "edit", "row_id" => dinner, "place" => @tavern})
    accepted!(mac, "place-2")
    flush!(ctx.registry)

    assert %{"type" => "trip", "trip" => %{"rev" => 3} = pushed} = recv(mac)
    assert %{"place" => @tower} = placed = row(pushed, tower)
    refute Map.has_key?(placed, "leg_m")
    refute Map.has_key?(row(pushed, row_id(pushed, "Coffee by the walls")), "leg_m")

    leg = Geo.distance_m(point(@tower), point(@tavern))
    assert %{"place" => @tavern, "leg_m" => ^leg} = row(pushed, dinner)
    assert leg == 429
  end

  # --- what version 7 never has ----------------------------------------------------

  test "a version 7 connection is refused every trip event, and is sent none", ctx do
    for %{"type" => type} = event <- @trip_events do
      old = hello(ctx.socket_path, 7)
      send_line(old, event)
      assert %{"type" => "error", "reason" => "unknown_event", "event" => ^type} = recv(old)
      assert {:error, :closed} = :gen_tcp.recv(old, 0, @arrival_ms)
    end

    old = hello(ctx.socket_path, 7)
    _trip_id = varonne!(ctx)
    flush!(ctx.registry)

    # Nothing of the trip came first: the next line answers the next request.
    send_line(old, %{"type" => "checklists_pull", "profile_id" => "main"})
    assert %{"type" => "checklists", "lists" => []} = recv(old)
  end

  test "a reply's trips block reaches a version 8 connection, never a version 7 one", ctx do
    old = hello(ctx.socket_path, 7)
    new = hello(ctx.socket_path, 8)
    ref = %{"trip_id" => "tr_4q8m2x7v1d", "title" => "Varonne weekend", "rows" => []}
    trips = %{"type" => "trips", "trips" => [ref]}
    done = %{"t" => "text_done", "turn_id" => "turn-t", "server_seq" => 5, "text" => "Planned."}

    :ok = Companion.broadcast("main", Map.put(done, "blocks", [trips]), ctx.registry)

    assert %{"type" => "text_done", "blocks" => [^trips]} = recv(new)
    assert %{"type" => "text_done", "server_seq" => 5} = line = recv(old)
    refute Map.has_key?(line, "blocks")
  end

  # --- one edit, every holder --------------------------------------------------------

  test "a device's create holds the trip, and a push names what a create, an add and a day made",
       ctx do
    mac = hello(ctx.socket_path, 8)

    edit(mac, "make-1", nil, %{"op" => "create", "title" => "Orvenne"})
    accepted!(mac, "make-1")
    flush!(ctx.registry)

    assert %{"type" => "trip", "trip" => trip, "made" => %{"make-1" => trip_id}} = recv(mac)
    assert %{"trip_id" => ^trip_id, "title" => "Orvenne", "rows" => [day]} = trip
    assert day == %{"row_id" => day["row_id"], "kind" => "day"}

    edit(mac, "add-1", trip_id, %{"op" => "add", "text" => "Lake walk", "day_id" => day["row_id"]})

    accepted!(mac, "add-1")
    edit(mac, "day-1", trip_id, %{"op" => "day", "text" => "Rest"})
    accepted!(mac, "day-1")
    flush!(ctx.registry)

    # Two edits in one window are one push, at the rev the second left.
    assert %{"type" => "trip", "trip" => %{"rev" => 3} = trip, "made" => made} = recv(mac)
    assert made == %{"add-1" => row_id(trip, "Lake walk"), "day-1" => row_id(trip, "Rest")}

    {:ok, %{rows: rows}} = TripRegistry.device_trip(trip_id, false, :independent, ctx.trip_opts)
    assert Enum.all?(rows, &(&1.made_via == "mac"))
  end

  test "an edit sent again by its client_msg_id is a duplicate that changes nothing", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)
    harbour = mac |> pull(trip_id) |> Map.fetch!("rows") |> Enum.at(4) |> Map.fetch!("row_id")
    op = %{"op" => "add", "text" => "Fish market", "day_id" => harbour}

    edit(mac, "dup-1", trip_id, op)
    accepted!(mac, "dup-1")
    flush!(ctx.registry)
    assert %{"type" => "trip", "trip" => %{"rev" => 2} = trip, "made" => made} = recv(mac)
    assert made == %{"dup-1" => row_id(trip, "Fish market")}

    # A reconnect replays its outbox.
    again = hello(ctx.socket_path, 8)
    _ = pull(again, trip_id)
    edit(again, "dup-1", trip_id, op)
    accepted!(again, "dup-1", true)
    flush!(ctx.registry)

    assert %{"type" => "trip", "trip" => %{"rev" => 2, "rows" => rows}, "made" => ^made} =
             recv(again)

    assert Enum.count(rows, &(&1["text"] == "Fish market")) == 1
  end

  test "a model's edit reaches the connection that holds the trip, then the index", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)
    _ = pull(mac, trip_id)
    _ = pull_index(mac)

    model_trip!(ctx, %{
      "trip" => "Varonne weekend",
      "ops" => [%{"op" => "add", "text" => "Fish market", "day" => 2}]
    })

    flush!(ctx.registry)

    assert %{"type" => "trip", "trip" => %{"rev" => 2, "rows" => rows}} = pushed = recv(mac)
    assert Enum.any?(rows, &(&1["text"] == "Fish market"))
    refute Map.has_key?(pushed, "made")
    assert %{"type" => "trips", "trips" => [%{"stops" => 5, "rev" => 2}]} = recv(mac)
  end

  test "the real window pushes a trip change once it ends", ctx do
    trip_id = varonne!(ctx)
    restart_endpoint(ctx, trip_window_ms: 100)
    mac = hello(ctx.socket_path, 8)
    _ = pull(mac, trip_id)

    edit(mac, "name-1", trip_id, %{"op" => "rename", "text" => "Varonne, long weekend"})
    accepted!(mac, "name-1")

    assert %{"type" => "trip", "trip" => %{"rev" => 2, "title" => "Varonne, long weekend"}} =
             recv(mac)
  end

  # The trips keep a window of their own beside the lists'.
  test "a list's window and a trip's window end apart", ctx do
    trip_id = varonne!(ctx)
    {:ok, _answer} = ChecklistRegistry.edit(groceries(), @owner_turn, ctx.trip_opts)
    {:ok, [list]} = ChecklistRegistry.device_index(:independent, ctx.trip_opts)
    mac = hello(ctx.socket_path, 8)
    _ = pull(mac, trip_id)
    send_line(mac, %{"type" => "checklist_pull", "profile_id" => "main", "list_id" => list.id})
    assert %{"type" => "checklist"} = recv(mac)

    edit(mac, "name-2", trip_id, %{"op" => "rename", "text" => "Varonne again"})
    accepted!(mac, "name-2")

    send_line(mac, %{
      "type" => "checklist_edit",
      "client_msg_id" => "list-2",
      "profile_id" => "main",
      "list_id" => list.id,
      "op" => %{"op" => "rename", "text" => "Shopping"}
    })

    accepted!(mac, "list-2")

    for {pid, _version} <- Registry.lookup(ctx.registry, "main"), do: send(pid, :checklists_flush)
    assert %{"type" => "checklist", "list" => %{"title" => "Shopping"}} = recv(mac)
    assert [_trip] = pull_index(mac)

    flush!(ctx.registry)
    assert %{"type" => "trip", "trip" => %{"title" => "Varonne again"}} = recv(mac)
  end

  # --- holding ---------------------------------------------------------------------

  test "a connection holds at most 16 trips, letting the oldest go", ctx do
    for i <- 1..17,
        do: model_trip!(ctx, %{"trip" => "Trip #{i}", "ops" => [%{"op" => "create"}]})

    {:ok, trips} = TripRegistry.device_index(:independent, ctx.trip_opts)
    ids = Enum.map(trips, & &1.id)
    mac = hello(ctx.socket_path, 8)
    for id <- ids, do: pull(mac, id)

    for i <- [1, 17] do
      model_trip!(ctx, %{"trip" => "Trip #{i}", "ops" => [%{"op" => "rename", "text" => "T#{i}"}]})
    end

    flush!(ctx.registry)
    held = List.last(ids)
    assert %{"type" => "trip", "trip" => %{"trip_id" => ^held}} = recv(mac)
    assert length(pull_index(mac)) == 17
  end

  # --- the ops only a device sends, and refusals ---------------------------------------

  test "removed rows and a removed trip still answer, and restore brings them back", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)
    coffee = mac |> pull(trip_id) |> row_id("Coffee by the walls")

    edit(mac, "rm-1", trip_id, %{"op" => "remove", "row_id" => coffee})
    accepted!(mac, "rm-1")
    assert %{"removed" => [gone]} = pull(mac, trip_id, true)
    assert %{"row_id" => ^coffee, "kind" => "stop", "removed_at" => "20" <> _} = gone

    edit(mac, "back-1", trip_id, %{"op" => "restore", "row_id" => coffee})
    accepted!(mac, "back-1")
    assert %{"rows" => rows} = restored = pull(mac, trip_id)
    assert row(restored, coffee)
    assert length(rows) == 6

    edit(mac, "rm-trip", trip_id, %{"op" => "remove_trip"})
    accepted!(mac, "rm-trip")
    assert %{"removed_at" => "20" <> _} = pull(mac, trip_id)
    edit(mac, "new-trip", nil, %{"op" => "create", "title" => "varonne weekend"})
    accepted!(mac, "new-trip")

    edit(mac, "back-2", trip_id, %{"op" => "restore"})

    assert refused!(mac, "back-2") ==
             ~s(Another trip is named "Varonne weekend" now, so this one cannot come back ) <>
               "under that name; restore it with a new title, or rename the other trip first."

    edit(mac, "back-3", trip_id, %{"op" => "restore", "title" => "Varonne, the first"})
    accepted!(mac, "back-3")

    titles = mac |> pull_index() |> Enum.map(& &1["title"]) |> Enum.sort()
    assert titles == ["Varonne, the first", "varonne weekend"]
  end

  test "a refused edit is request_failed with the engine's sentence, the connection kept", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)
    [day, stop | _rows] = pull(mac, trip_id)["rows"]

    for {id, target, op, sentence} <- [
          {"gone-row", trip_id, %{"op" => "remove", "row_id" => "ti_0000000000"},
           "That row is not in this trip any more; pull the trip again."},
          {"gone-trip", "tr_0000000000", %{"op" => "remove_trip"},
           "No trip has that id; it may have been removed more than 30 days ago."},
          {"nowhere", trip_id, %{"op" => "move", "row_id" => stop["row_id"]},
           "Moving a stop needs a day_id or an after_id."},
          {"both", trip_id,
           %{
             "op" => "add",
             "text" => "Fish",
             "day_id" => day["row_id"],
             "after_id" => stop["row_id"]
           }, "Give day_id or after_id, not both."},
          {"unplace", trip_id,
           %{"op" => "edit", "row_id" => stop["row_id"], "place" => @tower, "unplace" => true},
           "Give place or unplace, not both."}
        ] do
      edit(mac, id, target, op)
      assert refused!(mac, id) == sentence
    end

    assert [%{"rev" => 1}] = pull_index(mac)
  end

  # Decisions, owed by E3: the device receipts are keyed without their kind,
  # so an id a list's edit used refuses a trip's edit, which changes nothing.
  test "a client_msg_id names one edit of any kind", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)

    send_line(mac, %{
      "type" => "checklist_edit",
      "client_msg_id" => "once-1",
      "profile_id" => "main",
      "op" => %{"op" => "create", "title" => "Packing"}
    })

    accepted!(mac, "once-1")
    edit(mac, "once-1", trip_id, %{"op" => "rename", "text" => "Varonne again"})

    assert refused!(mac, "once-1") ==
             "That client_msg_id already named another edit, so nothing changed; send each " <>
               "edit with an id of its own."

    assert [%{"title" => "Varonne weekend", "rev" => 1}] = pull_index(mac)
  end

  # --- the shared form ----------------------------------------------------------------

  test "a share is answered trip_shared, the engine's own text at the trip's rev", ctx do
    trip_id = varonne!(ctx)
    mac = hello(ctx.socket_path, 8)
    {:ok, shared} = TripRegistry.device_share(trip_id, :independent, ctx.trip_opts)

    share(mac, "share-1", trip_id)

    assert recv(mac) == %{
             "type" => "trip_shared",
             "profile_id" => "main",
             "client_msg_id" => "share-1",
             "trip_id" => trip_id,
             "rev" => 1,
             "text" => shared.text
           }

    assert shared.text =~ "Varonne weekend, Sat 5 to Sun 6 Jul 2031"
    refute shared.text =~ "Table for two"

    edit(mac, "rm-trip", trip_id, %{"op" => "remove_trip"})
    accepted!(mac, "rm-trip")

    for target <- [trip_id, "tr_0000000000"] do
      share(mac, "share-2", target)

      assert refused!(mac, "share-2") ==
               "No trip has that id; it may have been removed more than 30 days ago."
    end
  end

  # --- who may --------------------------------------------------------------------

  test "a connection the daemon started reads, changes and shares no trip", ctx do
    trip_id = varonne!(ctx)
    restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())
    agent = hello(ctx.socket_path, 8)
    sentence = "Only the owner's own Fermix app can read or change the owner's trips."
    refusal = %{"type" => "error", "reason" => "request_failed", "message" => sentence}

    send_line(agent, %{"type" => "trips_pull", "profile_id" => "main"})
    assert recv(agent) == refusal
    send_line(agent, %{"type" => "trip_pull", "profile_id" => "main", "trip_id" => trip_id})
    assert recv(agent) == refusal

    edit(agent, "agent-1", trip_id, %{"op" => "remove_trip"})
    assert recv(agent) == Map.put(refusal, "client_msg_id", "agent-1")
    share(agent, "agent-2", trip_id)
    assert recv(agent) == Map.put(refusal, "client_msg_id", "agent-2")

    assert {:ok, [%{removed_at: nil}]} = TripRegistry.device_index(:independent, ctx.trip_opts)
  end

  # M75: a device-role engine runs a retired copy of a moved home and opens no
  # database: an edit and a share are refused by their ids, the pulls by name.
  test "a device-role engine refuses an edit and a share by their ids, and the pulls by name",
       ctx do
    trip_id = varonne!(ctx)
    request_opts = ctx.endpoint_opts[:connection_opts][:request_opts]
    role = %{role: :device, primary: "vm.example.test"}
    restart_endpoint(ctx, request_opts: Keyword.put(request_opts, :engine_role, role))
    mac = hello(ctx.socket_path, 8)

    refusal = %{
      "type" => "error",
      "reason" => "request_failed",
      "message" => "This engine runs in the device role; the primary is vm.example.test."
    }

    edit(mac, "device-1", trip_id, %{"op" => "remove_trip"})
    assert recv(mac) == Map.put(refusal, "client_msg_id", "device-1")
    share(mac, "device-2", trip_id)
    assert recv(mac) == Map.put(refusal, "client_msg_id", "device-2")

    send_line(mac, %{"type" => "trips_pull", "profile_id" => "main"})
    assert recv(mac) == refusal
    send_line(mac, %{"type" => "trip_pull", "profile_id" => "main", "trip_id" => trip_id})
    assert recv(mac) == refusal
  end

  # --- the card line --------------------------------------------------------------

  # One answer decides what a connection draws (`ReplyBlocks.drawn_types/3`):
  # trips once it pulled their index, lists once it pulled theirs.
  test "a turn draws trips only when its connection pulled the trips index", ctx do
    _ = varonne!(ctx)
    trips = hello(ctx.socket_path, 8)
    _ = pull_index(trips)
    plain = hello(ctx.socket_path, 8)
    lists = hello(ctx.socket_path, 8)
    send_line(lists, %{"type" => "checklists_pull", "profile_id" => "main"})
    assert %{"type" => "checklists"} = recv(lists)

    for {client, id} <- [{trips, "trips-1"}, {plain, "plain-1"}, {lists, "lists-1"}] do
      send_line(client, %{
        "type" => "msg",
        "client_msg_id" => id,
        "profile_id" => "main",
        "text" => "hi",
        "attach_ids" => []
      })

      {_rows, accepted} = until_frame(client, "accepted")
      assert %{"client_msg_id" => ^id} = accepted
    end

    messages =
      for _n <- 1..3 do
        assert_receive {:gateway_ingest, message}, @arrival_ms
        {message.id, message.metadata[:draws_trips], message.metadata[:draws_lists]}
      end

    assert Enum.sort(messages) == [
             {"lists-1", nil, true},
             {"plain-1", nil, nil},
             {"trips-1", true, nil}
           ]
  end

  # --- a phone's list channel (M89 §06) ---------------------------------------------

  # The connection a phone's list channel runs (`Desktop.CompanionPump`): the
  # lists scope, its edits made via the phone, and the session it serves told
  # once it draws each kind.
  defp phone_channel!(ctx),
    do: restart_endpoint(ctx, scope: :lists, made_via: "phone", draws_to: self())

  # The trips' window's end, delivered to every phone channel of this test.
  defp flush_phones!(registry) do
    for {pid, _version} <- Registry.lookup(registry, {:lists, "main"}),
        do: send(pid, :trips_flush)

    :ok
  end

  describe "a phone's list channel" do
    test "pulls the trips index and a trip at version 8, its edits made via the phone", ctx do
      trip_id = varonne!(ctx)
      phone_channel!(ctx)
      phone = hello(ctx.socket_path, 8)

      assert [%{"trip_id" => ^trip_id}] = pull_index(phone)
      assert [%{"kind" => "day", "row_id" => day} | _rows] = pull(phone, trip_id)["rows"]

      edit(phone, "phone-1", trip_id, %{"op" => "add", "text" => "Fish market", "day_id" => day})
      accepted!(phone, "phone-1")

      {:ok, %{rows: rows}} = TripRegistry.device_trip(trip_id, false, :independent, ctx.trip_opts)
      assert %{id: made, made_via: "phone"} = Enum.find(rows, &(&1.text == "Fish market"))
      assert %{made_via: "chat"} = Enum.find(rows, &(&1.text == "Coffee by the walls"))

      flush_phones!(ctx.registry)
      assert %{"type" => "trip", "trip" => %{"rev" => 2}, "made" => made_by} = recv(phone)
      assert made_by == %{"phone-1" => made}
      assert %{"type" => "trips", "trips" => [%{"rev" => 2}]} = recv(phone)
    end

    test "says it draws trips once, at its first trips index, apart from the lists", ctx do
      trip_id = varonne!(ctx)
      phone_channel!(ctx)
      phone = hello(ctx.socket_path, 8)

      _ = pull(phone, trip_id)
      send_line(phone, %{"type" => "checklists_pull", "profile_id" => "main"})
      assert %{"type" => "checklists"} = recv(phone)
      assert_receive :list_channel_draws
      refute_received :trip_channel_draws

      _ = pull_index(phone)
      assert_receive :trip_channel_draws
      _ = pull_index(phone)
      refute_received :trip_channel_draws
    end

    test "at version 7 is refused every trip event as unknown, and closes", ctx do
      phone_channel!(ctx)

      for %{"type" => type} = event <- @trip_events do
        phone = hello(ctx.socket_path, 7)
        send_line(phone, event)
        assert %{"type" => "error", "reason" => "unknown_event", "event" => ^type} = recv(phone)
        assert {:error, :closed} = :gen_tcp.recv(phone, 0, @arrival_ms)
      end
    end
  end

  # --- plumbing -------------------------------------------------------------------

  defp groceries do
    %{"changes" => [%{"list" => "Groceries", "ops" => [%{"op" => "create"}]}]}
  end

  defp share(client, id, trip_id) do
    send_line(client, %{
      "type" => "trip_share",
      "client_msg_id" => id,
      "profile_id" => "main",
      "trip_id" => trip_id
    })
  end

  defp point(%{"location" => %{"latitude" => latitude, "longitude" => longitude}}),
    do: %{latitude: latitude, longitude: longitude}

  # Every line up to the first of `type`, and that one: a turn's rows reach
  # every connection, so another's can come first.
  defp until_frame(client, type, seen \\ []) when length(seen) < 20 do
    case recv(client) do
      %{"type" => ^type} = frame -> {Enum.reverse(seen), frame}
      line -> until_frame(client, type, [line | seen])
    end
  end

  defp restart_endpoint(ctx, connection_opts) do
    stop_supervised!(Endpoint)

    ctx.endpoint_opts
    |> Keyword.update!(:connection_opts, &Keyword.merge(&1, connection_opts))
    |> then(&start_supervised!({Endpoint, &1}))
  end

  defp forward(test_pid) do
    receive do
      message -> send(test_pid, message)
    end

    forward(test_pid)
  end

  defp hello(path, version) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => version})
    assert %{"type" => "server_hello"} = recv(client)
    client
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 256 * 1_024
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end
end
