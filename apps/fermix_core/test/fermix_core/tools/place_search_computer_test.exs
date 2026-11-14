defmodule FermixCore.Tools.PlaceSearch.ComputerTest do
  @moduledoc """
  Apple Maps on a Mac of the home (M89 D13 A): a server's place search asks
  a computer's `places` capability, with the link stood in for. The test
  plays the computer: it is told each `invoke_open` and answers through
  `Computers.Calls`, so nothing waits on a clock and nothing reaches a
  network. A Mac that is away is refused at once and nothing is sent; a
  trip's lookups stop on the first such answer.

  `async: false`: the tool's cases set the one global section `place_search`
  reads and restore it.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Store
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.PlaceSearch
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixCore.Tools.PlaceSearch.Computer
  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Placer.Run
  alias FermixCore.Trips.Registry
  alias FermixTestSupport.TelemetryCapture

  # Every name, place and id here is invented.
  @studio "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @loft "c4a71e93-2b5d-4f08-9e6a-3d7b1f0c5a82"
  @version "1.2.3"
  @linux %{profile: :linux_package_cli, os: :linux}
  @conversation {"companion", "main", :root}
  @places_on %{id: "places", state: :on, sentence: nil, detail: nil}
  @files_on %{id: "files", state: :on, sentence: nil, detail: nil}
  @prado %{
    name: "Prado",
    location: %{latitude: 41.1402, longitude: -8.6113},
    address: "12 Rua Inventada, Varonne",
    apple_place_id: "I12",
    source_url: "https://maps.apple.com/place?place-id=I12",
    categories: ["restaurant"],
    contact: %{telephone: "+351 555 0101"}
  }
  # What the Mac's helper prints for it, which the server makes into the record.
  @prado_raw %{
    "name" => "Prado",
    "latitude" => 41.1402,
    "longitude" => -8.6113,
    "identifier" => "I12",
    "phone" => "+351 555 0101",
    "category" => "MKPOICategoryRestaurant",
    "address" => "12 Rua Inventada\nVaronne"
  }
  @away "computer_away: no Mac that looks places up in Apple Maps for this home is online " <>
          "now, so nothing was searched; ask again once one is online"

  # A link that tells the test each request it was asked to send.
  defmodule Link do
    @moduledoc false
    @behaviour FermixCore.Computers.Transport

    @impl true
    def open(device_id, header, payload, part, opts) do
      send(Keyword.fetch!(opts, :test), {:opened, device_id, header, payload, part})
      :ok
    end

    @impl true
    def cancel(_device_id, _about, _opts), do: :ok

    @impl true
    def status(_device_id, _about, _opts), do: :ok
  end

  setup do
    calls = :"place_computer_calls_#{System.unique_integer([:positive])}"
    start_supervised!({Calls, name: calls})
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore(:tools, tools) end)
    Application.put_env(:fermix_core, :tools, web_search: [], place_search: [])
    session_id = "place-computer-#{System.unique_integer([:positive])}"
    %{calls: calls, session_id: session_id}
  end

  # -- the home's computers, as `Computers.list/1` joins them --------------------

  defp row(device_id, name, connected, last_seen) do
    %{
      device_id: device_id,
      name: name,
      platform: "macos",
      last_seen: last_seen,
      backups: true,
      connected: connected,
      since: if(connected, do: last_seen)
    }
  end

  # `macs`: `{device_id, name, connected?, last_seen, offers}` each.
  defp computers(macs) do
    rows = for {id, name, connected, seen, _offers} <- macs, do: row(id, name, connected, seen)

    live =
      for {id, _name, true, seen, offers} <- macs,
          into: %{},
          do: {id, %{offers: offers, path: :direct, since: seen}}

    records =
      for {id, _name, _connected, seen, offers} <- macs,
          into: %{},
          do: {id, %{engine_version: @version, seen_at: seen, offers: offers}}

    [role: :primary, rows: fn -> {:ok, rows} end, live: live, records: records, version: @version]
  end

  defp studio(connected, offers \\ [@files_on, @places_on]),
    do: {@studio, "studio Mac", connected, ~U[2031-06-02 09:00:00Z], offers}

  defp context(ctx, macs, more \\ %{}) do
    %{
      session_id: ctx.session_id,
      agent_name: "main",
      conversation_key: @conversation,
      source_trust: :operator,
      computer_use_origin: :interactive,
      host: @linux,
      computers_opts: computers(macs),
      computer_call_opts: [calls: ctx.calls, transport: {Link, [test: self()]}, epoch: 4]
    }
    |> Map.merge(more)
  end

  defp search_opts(context, more \\ []) do
    Keyword.merge([send_within_ms: 45_000, context: context] ++ context.computers_opts, more)
  end

  # The caller blocks, so it runs beside the test, which plays the computer.
  defp async(fun), do: Task.async(fun)

  defp answer(ctx, id, fields, payload \\ "{}"),
    do:
      Calls.deliver(
        ctx.calls,
        @studio,
        id,
        {Map.merge(%{"id" => id, "duration_ms" => 3}, fields), payload}
      )

  defp places_answer(ctx, id, raw),
    do: answer(ctx, id, %{"status" => "ok"}, Jason.encode!(%{"places" => raw}))

  defp told do
    test = self()

    stop = fn why ->
      send(test, {:stopped, why})
      :ok
    end

    {stop, fn -> nil end}
  end

  describe "a search on a Mac of the home" do
    test "asks the Mac connected now once, and reads its places back as the record", ctx do
      context = context(ctx, [studio(true)])
      request = %{query: "Prado", count: 5, anchor: {:location, "Varonne, Portugal"}}

      task = async(fn -> Computer.search(request, search_opts(context)) end)

      assert_receive {:opened, @studio, %{"id" => id} = header, payload, nil}

      assert Map.delete(header, "id") == %{
               "capability" => "places",
               "op" => "search",
               "deadline_ms" => 15_000,
               "epoch" => 4,
               "origin" => "chat",
               "turn" => %{"session_id" => ctx.session_id, "tool_call_id" => id}
             }

      assert Jason.decode!(payload) == %{
               "query" => "Prado",
               "count" => 5,
               "near" => "Varonne, Portugal"
             }

      :ok = places_answer(ctx, id, [@prado_raw])

      assert {:ok, [@prado], trace} = Task.await(task)
      assert trace.computer == @studio
      assert trace.invocation == id
      assert trace.attempt == 1
      assert trace.searched_with == "Apple Maps on studio Mac"
    end

    test "a Mac that is away is refused at once: nothing is sent, and the call stops", ctx do
      context = context(ctx, [studio(false)])
      {stop, stopped} = told()

      assert {:error, @away, %{attempt: 0, provider_code: nil}} =
               Computer.search(
                 %{query: "Prado"},
                 search_opts(context, stop: stop, stopped: stopped)
               )

      assert_received {:stopped, :computer_away}
      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "of the connected Macs that offer places, the one seen last is asked", ctx do
      loft = {@loft, "loft Mac", true, ~U[2031-06-02 10:00:00Z], [@files_on]}

      attic =
        {"0b8c2f61-7d4e-4a39-a5f2-e81c3d6b9047", "attic Mac", false, ~U[2031-06-02 11:00:00Z],
         [@places_on]}

      context = context(ctx, [studio(true), loft, attic])

      task = async(fn -> Computer.search(%{query: "Prado"}, search_opts(context)) end)

      # The loft offers no places, and the attic is away: the studio Mac.
      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = places_answer(ctx, id, [])
      assert {:ok, [], _trace} = Task.await(task)
    end

    test "the invocation is bounded well inside the time its caller has left", ctx do
      context = context(ctx, [studio(true)])

      task =
        async(fn ->
          Computer.search(%{query: "Prado"}, search_opts(context, send_within_ms: 10_000))
        end)

      # Less twice the link's 2 s allowance.
      assert_receive {:opened, @studio, %{"id" => id, "deadline_ms" => 6_000}, _payload, nil}
      :ok = places_answer(ctx, id, [])
      assert {:ok, [], _trace} = Task.await(task)

      assert {:error, "deadline: " <> _rest, %{attempt: 0}} =
               Computer.search(%{query: "Prado"}, search_opts(context, send_within_ms: 4_999))

      refute_received {:opened, _device, _header, _payload, _part}
    end

    # Away is only no Mac connected: a Mac that answers late, refuses or is
    # busy says so, each in its own kind, and only what cannot heal within
    # the call stops it, its refusal or status the stop's code.
    test "each way a Mac does not search is its own kind, and only what cannot heal stops",
         ctx do
      context = context(ctx, [studio(true)])

      cases = [
        {%{"status" => "timed_out"},
         "computer_timed_out: studio Mac did not finish within 15 seconds. No place came " <>
           "back from it in time; try again in a moment.", {:computer_timed_out, "timed_out"}},
        {%{"status" => "refused", "refusal" => "off", "message" => "Switched off on this Mac."},
         "computer_off: studio Mac has Apple Maps switched off. Only someone at studio Mac " <>
           "can switch it on.", {:computer_off, "off"}},
        {%{
           "status" => "refused",
           "refusal" => "unavailable",
           "message" => "Looking places up in Apple Maps needs the Fermix app on a Mac."
         },
         "computer_refused: studio Mac: Looking places up in Apple Maps needs the Fermix app " <>
           "on a Mac.", {:computer_refused, "unavailable"}},
        {%{"status" => "refused", "refusal" => "stale_epoch", "message" => "Older copy."},
         "computer_refused: studio Mac refused a request from an older copy of this Fermix.",
         {:computer_refused, "stale_epoch"}},
        {%{"status" => "refused", "refusal" => "busy", "message" => "Busy."},
         "computer_busy: studio Mac is running as much as it allows right now. Try again in a " <>
           "moment.", nil}
      ]

      for {fields, reason, stop} <- cases do
        {stopping, stopped} = told()

        task =
          async(fn ->
            Computer.search(
              %{query: "Prado"},
              search_opts(context, stop: stopping, stopped: stopped)
            )
          end)

        assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
        :ok = answer(ctx, id, fields)
        assert {:error, ^reason, trace} = Task.await(task)
        assert trace.attempt == 1

        case stop do
          {why, code} ->
            assert_received {:stopped, ^why}
            assert trace.provider_code == code

          nil ->
            refute_received {:stopped, _why}
        end
      end
    end

    test "a search that failed there keeps Apple Maps' own tag and names the Mac", ctx do
      context = context(ctx, [studio(true)])

      for {message, stop} <- [
            {"invalid_location: Apple Maps found no place by that name", nil},
            {"rate_limited: Apple Maps is throttling searches from this Mac", :rate_limited}
          ] do
        {stopping, stopped} = told()

        task =
          async(fn ->
            Computer.search(
              %{query: "Prado", anchor: {:location, "Nowhere"}},
              search_opts(context, stop: stopping, stopped: stopped)
            )
          end)

        assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
        :ok = answer(ctx, id, %{"status" => "failed", "message" => message})
        [tag, words] = String.split(message, ": ", parts: 2)
        named = "#{tag}: on studio Mac, #{words}"
        assert {:error, ^named, %{attempt: 1}} = Task.await(task)

        if stop,
          do: assert_received({:stopped, ^stop}),
          else: refute_received({:stopped, _why})
      end
    end

    # Whichever search of the call set the stop, another backend's
    # included, the search is left unsent with its tag, and nothing raises.
    test "once the call is stopped, by any stop, nothing is sent", ctx do
      context = context(ctx, [studio(true)])

      for why <- [:computer_away, :computer_off, :plan_excludes_place_search, :deadline] do
        tag = Atom.to_string(why)

        assert {:error, reason, %{attempt: 0}} =
                 Computer.search(%{query: "Prado"}, search_opts(context, stopped: fn -> why end))

        assert reason ==
                 "#{tag}: an earlier search of the same call stopped it, so this one was not sent"
      end

      refute_received {:opened, _device, _header, _payload, _part}
    end

    # The local parser's own checks (`AppleMaps.places/2`): an HTTP site is
    # dropped, text sanitized, Apple's page made from the identifier, a place
    # with no page or no name dropped.
    test "the Mac's places are made into the record by the local code", ctx do
      context = context(ctx, [studio(true)])
      request = %{query: "Prado", count: 5}

      raw = [
        Map.merge(@prado_raw, %{"name" => "<b>Prado</b>", "url" => "http://prado.example"}),
        %{"name" => "No page", "latitude" => 41.0, "longitude" => -8.0},
        Map.put(@prado_raw, "name", "   "),
        Map.put(@prado_raw, "url", "https://prado.example/")
      ]

      task = async(fn -> Computer.search(request, search_opts(context)) end)
      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = places_answer(ctx, id, raw)

      assert {:ok, places, _trace} = Task.await(task)
      assert {:ok, ^places} = AppleMaps.places(raw, request)
      assert [first, second] = places
      assert first.name == "Prado"
      refute Map.has_key?(first, :canonical_url)
      assert first.source_url == "https://maps.apple.com/place?place-id=I12"
      assert first.address == "12 Rua Inventada, Varonne"
      assert second.canonical_url == "https://prado.example/"

      too_many = List.duplicate(@prado_raw, 33)
      task = async(fn -> Computer.search(request, search_opts(context)) end)
      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = places_answer(ctx, id, too_many)
      assert {:error, "parser_changed: on studio Mac, " <> _rest, _trace} = Task.await(task)
    end
  end

  describe "the place_search tool on a Mac of the home" do
    test "searches there, in one tool event that names the backend and no computer", ctx do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: ctx.session_id)
      holder = holder()
      context = context(ctx, [studio(true)], %{reply_blocks: holder})

      assert PlaceSearch.resolution(context).name == :computer
      assert PlaceSearch.advertise?(context)

      task =
        async(fn ->
          PlaceSearch.execute(%{"query" => "Prado", "location" => "Varonne, Portugal"}, context)
        end)

      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = places_answer(ctx, id, [@prado_raw])

      assert {:ok, %{success: true, output: output}} = Task.await(task)
      assert [%{"name" => "Prado", "apple_place_id" => "I12"}] = Jason.decode!(output)["places"]

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.backend == "computer"
      assert metadata.computer == @studio
      refute Map.has_key?(metadata, :searched_with)
      assert [%{name: "Prado"}] = ReplyBlocks.take(holder, @conversation)
    end

    test "a Mac that is away answers a sentence at once, and never Brave", ctx do
      test = self()

      Req.Test.stub(:place_computer_brave, fn conn ->
        send(test, :brave_request)
        Plug.Conn.resp(conn, 200, ~s({"results":[]}))
      end)

      context =
        context(ctx, [studio(false)], %{req_options: [plug: {Req.Test, :place_computer_brave}]})

      assert PlaceSearch.advertise?(context)

      assert {:ok, %{success: false, error: error}} =
               PlaceSearch.execute(%{"query" => "Prado", "location" => "Varonne"}, context)

      assert error =~ @away
      refute_received :brave_request
      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "country and language are Brave's, so a Mac's Apple Maps neither publishes nor takes them",
         ctx do
      context = context(ctx, [studio(true)])
      refute Map.has_key?(PlaceSearch.dynamic_parameters(context).properties, :country)

      assert {:ok, %{success: false, error: error}} =
               PlaceSearch.execute(%{"query" => "Prado", "country" => "PT"}, context)

      assert error =~ "invalid_query: country and language are options of the Brave"
      refute_received {:opened, _device, _header, _payload, _part}
    end
  end

  describe "a trip's lookups on a Mac of the home" do
    test "the first away answer stops every lookup of the call, and none is sent", ctx do
      context = context(ctx, [studio(false)])
      requests = Enum.map(1..6, &%{ref: &1, place: "Spot #{&1}", day: &1})

      assert {:ok, found} = resolve(requests, context, holder())

      assert %{lookups: 0, stop_reason: :computer_away, stop_code: nil, placed_by: %{}} = found
      assert Enum.map(found.outcomes, &elem(&1, 1)) == List.duplicate({:none, :computer_away}, 6)
      refute_received {:opened, _device, _header, _payload, _part}

      assert Lookup.heading(:computer_away) ==
               "Not looked up yet, no Mac that looks places up in Apple Maps is online; these " <>
                 "stops are saved and will be placed if one comes online within a week"
    end

    test "a Mac that does not answer the first lookup in time stops the rest", ctx do
      context = context(ctx, [studio(true)])
      requests = Enum.map(1..3, &%{ref: &1, place: "Spot #{&1}", day: &1})
      holder = holder()

      task = async(fn -> resolve(requests, context, holder) end)

      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = answer(ctx, id, %{"status" => "timed_out"})

      assert {:ok,
              %{lookups: 1, stop_reason: :computer_timed_out, stop_code: "timed_out"} = found} =
               Task.await(task)

      assert Enum.map(found.outcomes, &elem(&1, 1)) ==
               List.duplicate({:none, :computer_timed_out}, 3)

      refute_received {:opened, _device, _header, _payload, _part}
    end

    # The call's backend is resolved once: a Mac unlinked between two of its
    # lookups leaves the rest refused as away, never sent to Brave, whose key
    # is set here.
    test "a call whose computers change mid-call stays on the Mac it resolved to", ctx do
      test = self()

      Application.put_env(:fermix_core, :tools,
        web_search: [brave_api_key: "k"],
        place_search: []
      )

      Req.Test.stub(:place_computer_mid_call, fn conn ->
        send(test, :brave_request)
        Plug.Conn.resp(conn, 200, ~s({"results":[]}))
      end)

      rows = start_supervised!({Agent, fn -> computers([studio(true)]) end})
      seams = Keyword.put(Agent.get(rows, & &1), :rows, fn -> Agent.get(rows, & &1)[:rows].() end)

      context =
        context(ctx, [studio(true)], %{
          computers_opts: seams,
          req_options: [plug: {Req.Test, :place_computer_mid_call}]
        })

      requests = Enum.map(1..3, &%{ref: &1, place: "Prado", day: &1})
      holder = holder()
      task = async(fn -> resolve(requests, context, holder) end)

      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      Agent.update(rows, fn opts -> Keyword.put(opts, :rows, fn -> {:ok, []} end) end)
      :ok = places_answer(ctx, id, [@prado_raw])

      assert {:ok, found} = Task.await(task)

      assert [{1, {:placed, @prado}}, {2, {:none, :computer_away}}, {3, {:none, :computer_away}}] =
               found.outcomes

      assert found.stop_reason == :computer_away
      refute_received :brave_request
    end

    # Computers that cannot be read are never read as none: the resolver
    # refuses by name, and nothing turns to Brave.
    test "a home whose computer records cannot be read refuses by name, never Brave", ctx do
      home = FermixTestSupport.SafeRm.make_tmp_dir!("place-computer-unread")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      dir = Store.dir(home)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{@studio}.json"), "not a record")
      seams = computers([studio(true)]) |> Keyword.delete(:records) |> Keyword.put(:home, home)
      context = context(ctx, [studio(true)], %{computers_opts: seams})

      assert %{name: :computer, source: :computers_unknown} = PlaceSearch.resolution(context)
      refute PlaceSearch.advertise?(context)
      assert {:error, reason} = Lookup.backend(context)

      assert reason ==
               "provider_error: Fermix cannot tell whether a Mac of yours looks places up, since " <>
                 "this home's computers could not be read (#{@studio}.json is no record Fermix " <>
                 "wrote); see the daemon log, or set [fermix_core.tools.place_search] backend = " <>
                 ~s("brave" to search through Brave)

      assert {:ok, %{success: false, error: error}} =
               PlaceSearch.execute(%{"query" => "Prado"}, context)

      assert error == reason
      refute_received {:opened, _device, _header, _payload, _part}
    end

    # One view: the resolver and the choice read the same computers, the
    # link's rows on the primary, so a record with no row, or a home that is
    # no primary, offers nothing to either.
    test "a record with no row, or a home that is no primary, is no Mac that offers places",
         ctx do
      for seams <- [
            Keyword.put(computers([studio(true)]), :rows, fn -> {:ok, []} end),
            Keyword.put(computers([studio(true)]), :role, :device)
          ] do
        assert Computer.offered(seams) == {:ok, false}
        assert Computer.computers(seams) == {:ok, []}
        context = context(ctx, [studio(true)], %{computers_opts: seams})
        assert %{name: :brave, source: :build_default} = PlaceSearch.resolution(context)

        assert {:error, @away, %{attempt: 0}} =
                 Computer.search(%{query: "Prado"}, search_opts(context))
      end

      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "the places a Mac placed say what placed them", ctx do
      context = context(ctx, [studio(true)])
      requests = [%{ref: 1, place: "Prado", day: 1}]
      holder = holder()

      task = async(fn -> resolve(requests, context, holder) end)

      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = places_answer(ctx, id, [@prado_raw])

      assert {:ok, %{outcomes: [{1, {:placed, @prado}}], placed_by: placed_by}} =
               Task.await(task)

      assert placed_by == %{1 => "Apple Maps on studio Mac"}
    end
  end

  # M89 D13: one model call, through the trips' own registry and store: what
  # the answer says, and what its one trip event carries under the turn.
  describe "a trip_edit call on a Mac of the home" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-trips-computer-#{unique}.db")
      repo = :"trips_computer_repo_#{unique}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      %{repo: repo}
    end

    defp edit(ctx, context, ops, holder) do
      opts = [repo: ctx.repo, now: ~U[2031-06-02 14:00:00Z], reply_blocks: holder]
      opts = Keyword.merge(opts, notifier: fn _change -> :ok end, placer: fn -> :ok end)
      Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts)
    end

    defp ops,
      do: [
        %{"op" => "create", "days" => 2, "near" => "Varonne, Portugal"},
        %{"op" => "add", "text" => "Lunch", "day" => 1, "place" => "Prado"}
      ]

    test "its answer says the Mac placed the stops, and its event names the backend", ctx do
      TelemetryCapture.attach([[:fermix, :trip, :edit]], session_id: ctx.session_id)

      context =
        context(ctx, [studio(true)], %{chat_type: "private", outside_sources: MapSet.new()})

      holder = holder()

      task = async(fn -> edit(ctx, context, ops(), holder) end)
      assert_receive {:opened, @studio, %{"id" => id}, _payload, nil}
      :ok = places_answer(ctx, id, [@prado_raw])

      assert {:ok, %{text: text}} = Task.await(task)
      assert text =~ ~s([3] "Lunch": "Prado, 12 Rua Inventada, Varonne"\n)
      assert text =~ "\nPlaced with Apple Maps on studio Mac: [3]."

      assert_receive {:telemetry, [:fermix, :trip, :edit], %{lookups: 1, placed: 1}, metadata}
      assert %{backend: "computer", stop_reason: nil, outcome: :ok} = metadata
    end

    test "with the Mac away, the stops are saved unplaced and the event says why", ctx do
      TelemetryCapture.attach([[:fermix, :trip, :edit]], session_id: ctx.session_id)

      context =
        context(ctx, [studio(false)], %{chat_type: "private", outside_sources: MapSet.new()})

      assert {:ok, %{text: text}} = edit(ctx, context, ops(), holder())

      assert text =~
               "Not looked up yet, no Mac that looks places up in Apple Maps is online; these " <>
                 "stops are saved and will be placed if one comes online within a week: " <>
                 ~s([3] "Lunch".)

      refute text =~ "Placed with"
      refute_received {:opened, _device, _header, _payload, _part}

      assert_receive {:telemetry, [:fermix, :trip, :edit], %{lookups: 0, not_looked_up: 1},
                      metadata}

      assert %{backend: "computer", stop_reason: :computer_away, stop_code: nil} = metadata
    end

    # M89 D13 B: a stop saved while the Mac was away waits, and the trip
    # placer places it once a Mac that offers places is online, through the
    # home's own backend and the Mac's own search: one write, the devices'
    # push, and the stop's place from the Mac's answer.
    test "a stop that waited for the Mac is placed by the trip placer once the Mac is online",
         ctx do
      away = context(ctx, [studio(false)], %{chat_type: "private", outside_sources: MapSet.new()})
      assert {:ok, _answer} = edit(ctx, away, ops(), holder())
      test = self()

      # What the run reads of the home: its computers, how to call them, and the build.
      home = Map.take(context(ctx, [studio(true)]), [:host, :computers_opts, :computer_call_opts])

      run_opts = [
        repo: ctx.repo,
        now: fn -> ~U[2031-06-02 15:00:00Z] end,
        context: home,
        notifier: fn changes -> send(test, {:notified, changes}) && :ok end
      ]

      task = async(fn -> Run.run(:computer, run_opts) end)

      assert_receive {:opened, @studio, %{"id" => id} = header, payload, nil}
      assert %{"origin" => "background", "turn" => %{"session_id" => "trip_place:" <> _}} = header

      assert Jason.decode!(payload) == %{
               "query" => "Prado",
               "count" => 5,
               "near" => "Varonne, Portugal"
             }

      :ok = places_answer(ctx, id, [@prado_raw])
      assert %{next_ms: nil} = Task.await(task)
      assert_receive {:notified, %{trips: [%{rev: 2}]}}

      assert {:ok, %{rows: rows}} =
               Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: ctx.repo)

      assert %{place: %{"name" => "Prado"}} = Enum.find(rows, &(&1.n == 3))
    end
  end

  defp holder,
    do: start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: make_ref()))

  # A trip near the invented town, so each lookup has somewhere to search.
  defp resolve(requests, context, holder) do
    Lookup.resolve(requests, %{placed: %{}, day_near: %{}, trip_near: "Varonne, Portugal"},
      backend: Lookup.backend(context),
      reply_blocks: holder,
      conversation_key: @conversation
    )
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
