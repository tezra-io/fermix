defmodule FermixCore.Tools.TripToolsTest do
  # M89 §04, §06, §14: trip_read and trip_edit as the model calls them: one
  # model call is one tool event under its name, the place lookups inside a
  # call none of their own; every trip a call read or changed is kept for the
  # reply's block; a turn that was not told how its channel shows a trip has
  # the channel's line after the answer; a framed stop taints the turn and the
  # engine's own lookups do not; trip_edit says a trip is made before any
  # search in the turn; and both schemas stay inside their budget.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.TripEdit
  alias FermixCore.Tools.TripRead
  alias FermixTestSupport.TelemetryCapture

  # Every title, stop, place and id here is invented.
  @conversation {"telegram", "40017", :root}
  @quay %{latitude: 41.1408, longitude: -8.6142}
  @offered %{
    name: "Harbour Rooms",
    location: @quay,
    address: "9 Rua Inventada, Varonne",
    source_url: "https://maps.apple.com/place?place-id=I9"
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-tools-#{unique}.db")
    repo = :"trip_tools_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: :holder))

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    context = %{
      agent_name: "main",
      conversation_key: @conversation,
      source_trust: :operator,
      computer_use_origin: :interactive,
      chat_type: "private",
      channel: "telegram",
      outside_sources: MapSet.new(),
      memory_repo: repo,
      reply_blocks: holder,
      session_id: "main-#{unique}",
      place_lookup: fn %{query: "Check in"} -> {:ok, [@offered], %{backend: "apple_maps"}} end
    }

    %{context: context, holder: holder}
  end

  defp create!(context, trip \\ "Varonne") do
    ops = [
      %{"op" => "create", "days" => 2, "starts_on" => "2031-07-04"},
      %{"op" => "add", "text" => "Check in", "day" => 1, "place" => "Check in"}
    ]

    assert {:ok, %{success: true} = result} =
             TripEdit.execute(%{"trip" => trip, "ops" => ops}, context)

    result
  end

  test "one call is one tool event under its name; a lookup inside it is none", %{
    context: context
  } do
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: context.session_id)
    create!(context)

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, %{tool: "trip_edit"}}
    refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}

    {:ok, %{success: true}} = TripRead.execute(%{"trip" => "Varonne"}, context)
    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, %{tool: "trip_read"}}

    {:ok, %{success: false}} = TripRead.execute(%{"trip" => "Nowhere"}, context)

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                    %{tool: "trip_read", success: false, error_code: "no_trip"}}
  end

  test "every trip a call read or changed is kept for the reply's block", %{
    context: context,
    holder: holder
  } do
    create!(context)
    {:ok, %{success: true}} = TripRead.execute(%{"trip" => "Varonne", "day" => "1"}, context)
    {:ok, %{success: true}} = TripRead.execute(%{}, context)

    records = ReplyBlocks.take(holder, @conversation)
    assert [%{"type" => "trips", "trips" => [trip]}] = ReplyBlocks.trips(records)
    assert %{"title" => "Varonne", "rows" => [_stop]} = trip
    assert Enum.count(records, &match?({:trip, _touch}, &1)) == 2
    assert Enum.any?(records, &match?(%{name: "Harbour Rooms"}, &1))
  end

  test "a turn not told how its channel shows a trip has the channel's line after the answer",
       %{context: context} do
    written = "No trip is drawn here: write out the days that changed"
    drawn = "A trip you read or change is drawn under your reply, live"

    assert create!(context).output =~ "\n\n" <> written

    {:ok, read} = TripRead.execute(%{"trip" => "Varonne"}, context)
    assert read.output =~ written

    {:ok, index} = TripRead.execute(%{}, context)
    refute index.output =~ written

    told = Map.put(context, :trips_told, true)
    {:ok, read} = TripRead.execute(%{"trip" => "Varonne"}, told)
    refute read.output =~ written

    mac = %{context | channel: "companion"} |> Map.put(:draws_trips, true)
    {:ok, read} = TripRead.execute(%{"trip" => "Varonne"}, mac)
    assert read.output =~ drawn
    refute read.output =~ written
  end

  test "a read that shows a stop added after outside content taints the turn; a lookup does not",
       %{context: context} do
    edit = Builtin.from_tool_module(TripEdit)
    read = Builtin.from_tool_module(TripRead)

    offered = create!(context)
    assert offered.output =~ ~s("Harbour Rooms, 9 Rua Inventada, Varonne")
    assert UntrustedContent.outside_source(edit, %{}, offered.output) == nil

    {:ok, clean} = TripRead.execute(%{"trip" => "Varonne"}, context)
    assert UntrustedContent.outside_source(read, %{}, clean.output) == nil

    tainted = %{context | outside_sources: MapSet.new([{:tool, "web_fetch"}])}
    add = [%{"op" => "add", "text" => "Night market", "day" => 2}]
    {:ok, added} = TripEdit.execute(%{"trip" => "Varonne", "ops" => add}, tainted)
    assert added.success
    assert UntrustedContent.outside_source(edit, %{}, added.output) == nil

    {:ok, framed} = TripRead.execute(%{"trip" => "Varonne"}, context)
    assert framed.output =~ ~s{(added after outside content) "Night market"}

    assert UntrustedContent.outside_source(read, %{}, framed.output) ==
             UntrustedContent.trip_source()

    {:ok, shared} = TripRead.execute(%{"trip" => "Varonne", "as" => "share"}, context)

    assert UntrustedContent.outside_source(read, %{}, shared.output) ==
             UntrustedContent.trip_source()
  end

  test "trip_edit's description says a trip is made before any search in the turn" do
    assert TripEdit.description() =~
             "Make a trip with what is known before any search in the turn; after a search, " <>
               "only adding stops runs."
  end

  test "the two tool schemas stay inside their measured budget" do
    encoded =
      [TripRead, TripEdit]
      |> Enum.map(&%{name: &1.name(), description: &1.description(), parameters: &1.parameters()})
      |> Jason.encode!()

    # Measured at 471 tokens with o200k_base (M89 §15, C9), 1,843 bytes: 448
    # tokens and 1,741 bytes, plus 23 tokens and 102 bytes for trip_edit's
    # clause that a trip is made before any search in the turn. The bound is
    # the old 1,750 raised by that clause's 102 bytes.
    assert byte_size(encoded) <= 1_852
  end
end
