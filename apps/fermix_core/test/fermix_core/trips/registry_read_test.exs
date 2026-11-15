defmodule FermixCore.Trips.RegistryReadTest do
  # M89 §04, §13: trip_read through the Registry against a real store: the
  # index, a trip whole, one day or a run of days by position, the shared
  # form, each refusal's sentence and the read's event; and a device's Share,
  # which only the owner's own connection asks for.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Registry
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
    db_path = Path.join(System.tmp_dir!(), "fermix-trips-read-#{unique}.db")
    repo = :"trips_read_repo_#{unique}"

    start_supervised!({FermixCore.Memory.Repo, name: repo, enabled: true, database_path: db_path},
      id: repo
    )

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  defp opts(repo), do: [repo: repo, now: @now, notifier: fn _changes -> :ok end]

  defp varonne!(repo) do
    ops = [
      %{
        "op" => "create",
        "days" => 3,
        "starts_on" => "2031-07-04",
        "timezone" => "Europe/Lisbon"
      },
      %{"op" => "day", "day" => 2, "text" => "Harbour"},
      %{"op" => "add", "text" => "Fish market", "day" => 1, "time" => "08:30"},
      %{
        "op" => "add",
        "text" => "Dinner at Corvo",
        "day" => 2,
        "fixed" => true,
        "note" => "Booked, code 4417"
      },
      %{"op" => "add", "text" => "Ferry back", "day" => 3}
    ]

    {:ok, answer} = Registry.edit(%{"trip" => "Varonne", "ops" => ops}, @owner, opts(repo))
    [%{trip_id: trip_id}] = answer.touched
    trip_id
  end

  defp read(repo, params, context \\ @owner), do: Registry.read(params, context, opts(repo))

  defp read!(repo, params) do
    assert {:ok, %{text: text, touched: touched}} = read(repo, params)
    {text, touched}
  end

  defp refusal(result) do
    assert {:error, reason} = result
    Registry.describe_error(reason)
  end

  test "with no trip named, the index; with none kept, it says so", %{repo: repo} do
    assert read!(repo, %{}) == {"The owner keeps no trips yet.", []}
    trip_id = varonne!(repo)

    assert read!(repo, %{}) ==
             {"The owner's trips (titles are the owner's, quoted as data):\n" <>
                ~s|- "Varonne" (#{trip_id}) · Fri 4 to Sun 6 Jul 2031 · 3 days, 3 stops · rev 1|,
              []}
  end

  test "a trip whole, by its title or id, names it with no rows", %{repo: repo} do
    trip_id = varonne!(repo)
    {text, touched} = read!(repo, %{"trip" => "VARONNE"})

    assert text =~
             ~s|Trip "Varonne" (#{trip_id}) · Fri 4 to Sun 6 Jul 2031 · Europe/Lisbon · rev 1 · | <>
               "3 days, 3 stops\n"

    assert text =~ "## [2] Day 2 · Sat 5 Jul · Harbour\n- [5] Dinner at Corvo · fixed\n"
    assert text =~ "      Booked, code 4417"
    assert touched == [%{trip_id: trip_id, title: "Varonne", rows: []}]
    assert {:ok, %{text: ^text}} = read(repo, %{"trip" => trip_id})
  end

  test "one day, or a run, by position; as a number too", %{repo: repo} do
    varonne!(repo)

    {day, _touched} = read!(repo, %{"trip" => "Varonne", "day" => "2"})
    assert day =~ "## [2] Day 2"
    refute day =~ "Day 1"
    refute day =~ "Day 3"

    {run, _touched} = read!(repo, %{"trip" => "Varonne", "day" => "2-3"})
    assert run =~ "## [2] Day 2" and run =~ "## [3] Day 3"
    refute run =~ "Day 1"

    assert read!(repo, %{"trip" => "Varonne", "day" => 3}) ==
             read!(repo, %{"trip" => "Varonne", "day" => " 3 "})
  end

  test "a day past the last, a day that is not one, and a day or share with no trip each say so",
       %{repo: repo} do
    varonne!(repo)

    assert refusal(read(repo, %{"trip" => "Varonne", "day" => "2-5"})) ==
             "This trip has no Day 5; it has 3 days."

    for bad <- ["0", "3-2", "Thursday", "2031-07-04", -1] do
      assert refusal(read(repo, %{"trip" => "Varonne", "day" => bad})) ==
               ~s(day is a day's number from 1, or a run of days as "2-4".),
             inspect(bad)
    end

    assert refusal(read(repo, %{"day" => "2"})) ==
             "Name the trip, by its title or id, to read a day of it or to share it."

    assert refusal(read(repo, %{"trip" => "Varonne", "as" => "pdf"})) ==
             ~s(as takes only "share".)

    assert refusal(read(repo, %{"trip" => "Nowhere"})) =~ ~s(No trip is named "Nowhere")
  end

  test "as share, the shared form of the days asked, with no note", %{repo: repo} do
    varonne!(repo)
    {text, _touched} = read!(repo, %{"trip" => "Varonne", "as" => "share", "day" => "2"})

    assert text == "Varonne, Fri 4 to Sun 6 Jul 2031\n\nSat 5 Jul, Harbour\nDinner at Corvo"
  end

  test "a read by a group chat's turn or a guest's is refused before the store", %{repo: _repo} do
    unused = :"no_repo_#{System.unique_integer([:positive])}"

    for context <- [%{@owner | chat_type: "group"}, %{@owner | source_trust: :guest}] do
      assert refusal(Registry.read(%{}, context, repo: unused)) =~
               "trip_read is available only on the owner's own turn"
    end
  end

  test "every read emits its scope and count, never a title", %{repo: repo} do
    varonne!(repo)
    session = "main-#{System.unique_integer([:positive])}"
    context = Map.put(@owner, :session_id, session)
    TelemetryCapture.attach([[:fermix, :trip, :read]], session_id: session)

    for {params, scope, trips} <- [
          {%{}, :index, 1},
          {%{"trip" => "Varonne"}, :trip, 1},
          {%{"trip" => "Varonne", "day" => "1-2"}, :days, 1},
          {%{"trip" => "Varonne", "as" => "share"}, :share, 1}
        ] do
      assert {:ok, _answer} = read(repo, params, context)
      assert_receive {:telemetry, [:fermix, :trip, :read], %{trips: ^trips}, metadata}
      assert %{scope: ^scope, outcome: :ok, made_via: "chat", component: "trips"} = metadata
      refute inspect(metadata) =~ "Varonne"
    end

    assert {:error, _reason} = read(repo, %{"trip" => "Nowhere"}, context)
    assert_receive {:telemetry, [:fermix, :trip, :read], %{trips: 0}, metadata}
    assert %{scope: :trip, outcome: :refused, error_code: "no_trip"} = metadata
  end

  describe "a device's Share" do
    test "the owner's connection is answered the shared form with the rev", %{repo: repo} do
      trip_id = varonne!(repo)

      assert {:ok, %{trip_id: ^trip_id, rev: 1, text: text}} =
               Registry.device_share(trip_id, :independent, repo: repo)

      assert text ==
               "Varonne, Fri 4 to Sun 6 Jul 2031\n\nFri 4 Jul\n08:30 Fish market\n\n" <>
                 "Sat 5 Jul, Harbour\nDinner at Corvo\n\nSun 6 Jul\nFerry back"
    end

    test "a stop's place is linked, and another connection, a bad id or a removed trip is refused",
         %{repo: repo} do
      trip_id = varonne!(repo)
      [day_one | _rest] = read_rows!(repo, trip_id)

      {:ok, _} =
        Registry.device_edit(
          %{
            "client_msg_id" => "mac-share-1",
            "trip_id" => trip_id,
            "op" => %{"op" => "add", "text" => "Inn", "day_id" => day_one.id, "place" => @inn}
          },
          :independent,
          opts(repo)
        )

      assert {:ok, %{text: text}} = Registry.device_share(trip_id, :independent, repo: repo)
      assert text =~ "\nInn https://maps.apple.com/?ll=41.2031,-8.4102&q=Marisco+Inn\n"

      assert Registry.device_share(trip_id, :daemon_started, repo: repo) == {:error, :not_owner}

      assert Registry.device_share("tr_nope", :independent, repo: repo) ==
               {:error, {:invalid_param, :trip_id}}

      {:ok, _answer} =
        Registry.edit(
          %{"trip" => "Varonne", "ops" => [%{"op" => "remove_trip"}]},
          @owner,
          opts(repo)
        )

      assert Registry.device_share(trip_id, :independent, repo: repo) ==
               {:error, {:no_such_trip, trip_id}}
    end
  end

  defp read_rows!(repo, trip_id) do
    assert {:ok, %{rows: rows}} = Registry.device_trip(trip_id, false, :independent, repo: repo)
    rows
  end
end
