defmodule FermixCore.Tools.PlaceSearchLookupTest do
  # The place search a trip's lookup runs (M89 §04, C12): the backend in force,
  # with no tool event of its own, since one model call is one tool event and
  # the lookups run inside a `trip_edit` call.
  #
  # It drives the global config section `place_search` reads (the backend and
  # the Brave key), so it establishes it in `setup`, restores it in `on_exit`,
  # and runs `async: false`, as `PlaceSearchTest` does.
  use ExUnit.Case, async: false

  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.PlaceSearch
  alias FermixCore.Tools.PlaceSearch.Brave.Pacer
  alias FermixCore.Trips.Lookup
  alias FermixTestSupport.TelemetryCapture

  @key "brave-secret"
  @conversation {"test", "place-lookup", :root}
  # What a search is told as it sends: a trip's lookup passes what its call
  # has left, here the whole of it.
  @send [send_within_ms: 45_000]

  setup do
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore(:tools, tools) end)
    put_tools(@key)
    session_id = "place-lookup-#{System.unique_integer([:positive])}"
    %{session_id: session_id}
  end

  # The call's search, its backend resolved once (`PlaceSearch.searcher/2`).
  defp lookup(request, context) do
    {:ok, search} = PlaceSearch.searcher(context, PlaceSearch.resolution(context))
    search.(request, @send)
  end

  describe "PlaceSearch.searcher/2" do
    test "searches the backend in force with the request as given", %{session_id: session_id} do
      test_pid = self()

      context =
        stub(session_id, fn conn ->
          send(test_pid, {:query, URI.decode_query(conn.query_string)})
          json(conn, %{"results" => [brave_place("Prado", 38.7101, -9.1335)]})
        end)

      request = %{
        query: "Prado",
        count: 5,
        anchor: {:coordinates, 38.7111, -9.1311},
        radius_meters: 2_000
      }

      assert {:ok, [place], trace} = lookup(request, context)
      assert place.name == "Prado"
      assert place.location == %{latitude: 38.7101, longitude: -9.1335}
      assert trace.backend == "brave"

      assert_received {:query, query}
      assert query["q"] == "Prado"
      assert query["count"] == "5"
      assert query["latitude"] == "38.7111"
      assert query["longitude"] == "-9.1311"
      assert query["radius"] == "2000"
    end

    test "emits no tool event and keeps nothing for a reply", %{session_id: session_id} do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session_id)
      holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: make_ref()))

      context =
        session_id
        |> stub(fn conn -> json(conn, %{"results" => [brave_place("Prado", 38.71, -9.13)]}) end)
        |> Map.put(:reply_blocks, holder)

      # The pin catches the tool's own event, so its absence below means something.
      {:ok, %{success: true}} = PlaceSearch.execute(%{"query" => "Prado"}, context)
      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, %{tool: "place_search"}}
      assert [%{name: "Prado"}] = ReplyBlocks.take(holder, @conversation)

      # A holder of its own, since the tool's search above indexed the place.
      quiet = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: make_ref()))

      assert {:ok, [%{name: "Prado"}], _trace} =
               lookup(%{query: "Prado", count: 5}, %{context | reply_blocks: quiet})

      refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}
      assert ReplyBlocks.take(quiet, @conversation) == []
      assert ReplyBlocks.place_by_url(quiet, @conversation, "https://prado.example/") == :error
    end

    test "a backend that is not ready refuses with its reason before any request",
         %{session_id: session_id} do
      put_tools(nil)
      test_pid = self()

      context =
        stub(session_id, fn conn ->
          send(test_pid, :unexpected_request)
          json(conn, %{"results" => []})
        end)

      assert {:error, "auth_failed: missing Brave API key"} =
               PlaceSearch.searcher(context, PlaceSearch.resolution(context))

      refute_received :unexpected_request
    end

    test "a failed search comes back with its own tag", %{session_id: session_id} do
      context = stub(session_id, fn conn -> Plug.Conn.resp(conn, 429, "") end)

      assert {:error, "rate_limited: HTTP 429" <> _rest, %{backend: "brave"}} =
               lookup(%{query: "Prado", count: 5}, context)
    end
  end

  describe "Trips.Lookup.backend/1" do
    test "is the place search in force while it is ready", %{session_id: session_id} do
      context =
        stub(session_id, fn conn ->
          json(conn, %{"results" => [brave_place("Prado", 38.71, -9.13)]})
        end)

      assert {:ok, search} = Lookup.backend(context)

      assert {:ok, [%{name: "Prado"}], %{backend: "brave"}} =
               search.(%{query: "Prado", count: 5}, @send)
    end

    test "says why when no place search is set up here", %{session_id: session_id} do
      put_tools(nil)
      context = stub(session_id, fn conn -> json(conn, %{"results" => []}) end)

      assert Lookup.backend(context) == {:error, "auth_failed: missing Brave API key"}
    end

    test "the context's place_lookup stands in for the place search" do
      put_tools(nil)
      search = fn _request -> {:ok, [], %{}} end

      assert Lookup.backend(%{place_lookup: search}) == {:ok, search}
    end

    test "a stand-in that takes more than the request is refused, never passed over" do
      put_tools(nil)
      timed = fn _request, _send -> {:ok, [], %{}} end

      assert_raise ArgumentError, ~r/place_lookup/, fn ->
        Lookup.backend(%{place_lookup: timed})
      end
    end

    test "a trip's lookups through the place search emit no tool event",
         %{session_id: session_id} do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session_id)
      holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: make_ref()))

      context =
        stub(session_id, fn conn ->
          words = URI.decode_query(conn.query_string)["q"]
          json(conn, %{"results" => [brave_place(words, 38.71, -9.13)]})
        end)

      requests = Enum.map(1..6, &%{ref: &1, place: "Spot #{&1}", day: 1})

      assert {:ok, %{outcomes: outcomes, lookups: 6}} =
               Lookup.resolve(
                 requests,
                 %{placed: %{}, day_near: %{}, trip_near: "Lisbon, Portugal"},
                 backend: Lookup.backend(context),
                 reply_blocks: holder,
                 conversation_key: @conversation
               )

      assert Enum.all?(outcomes, &match?({_ref, {:placed, _place}}, &1))
      refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp stub(session_id, handler) do
    test_id = :"place_lookup_#{System.unique_integer([:positive])}"
    Req.Test.stub(test_id, handler)

    # A pacer of the test's own, on a clock that never moves, whose waits are
    # never slept (`BravePacingTest` asserts the pacing).
    %{
      agent_name: "test_agent",
      session_id: session_id,
      conversation_key: @conversation,
      req_options: [plug: {Req.Test, test_id}],
      net_resolver: fn "api.search.brave.com" -> {:ok, [{93, 184, 216, 34}]} end,
      place_search_pacer:
        start_supervised!(
          Supervisor.child_spec({Pacer, name: nil, now_ms: fn -> 0 end}, id: make_ref())
        ),
      place_search_sleep: fn _ms -> :ok end
    }
  end

  defp brave_place(name, latitude, longitude) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    %{
      "type" => "location_result",
      "title" => name,
      "url" => "https://#{slug}.example/",
      "provider_url" => "https://search.brave.com/local/place/#{slug}",
      "coordinates" => [latitude, longitude]
    }
  end

  defp put_tools(key) do
    web_search = if key, do: [brave_api_key: key], else: []

    Application.put_env(:fermix_core, :tools,
      web_search: web_search,
      place_search: [backend: "brave"]
    )
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
