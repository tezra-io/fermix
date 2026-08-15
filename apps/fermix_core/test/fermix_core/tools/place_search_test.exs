defmodule FermixCore.Tools.PlaceSearchTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Tools.PlaceSearch

  @key "brave-secret"

  # This suite drives the one global config section `place_search` reads — the
  # Brave credential — so it establishes it in `setup` and restores the prior
  # value in `on_exit` (CLAUDE.md: a test never depends on, or leaks, host/global
  # state). `async: false` for the same reason.
  setup do
    tools = Application.get_env(:fermix_core, :tools)

    on_exit(fn -> restore(:tools, tools) end)

    put_brave_key(@key)
    :ok
  end

  describe "provider-visible schema (§10.1)" do
    test "is the M31 contract, bounded and closed" do
      schema = PlaceSearch.parameters()

      assert schema.type == "object"
      assert schema.required == ["query"]
      assert schema.additionalProperties == false

      assert schema.properties.query == %{type: "string", maxLength: 400}
      assert schema.properties.location == %{type: "string", maxLength: 200}
      assert schema.properties.latitude == %{type: "number", minimum: -90, maximum: 90}
      assert schema.properties.longitude == %{type: "number", minimum: -180, maximum: 180}
      assert schema.properties.radius_meters == %{type: "integer", minimum: 1, maximum: 50_000}
      assert schema.properties.count == %{type: "integer", minimum: 1, maximum: 10}
      assert schema.properties.country == %{type: "string", minLength: 2, maxLength: 2}
      assert schema.properties.language == %{type: "string", minLength: 2, maxLength: 12}
      assert schema.properties.units == %{type: "string", enum: ["metric", "imperial"]}

      assert Map.keys(schema.properties) |> Enum.sort() == [
               :count,
               :country,
               :language,
               :latitude,
               :location,
               :longitude,
               :query,
               :radius_meters,
               :units
             ]
    end

    test "the tool is a :web built-in whose failure modes name every §10.4 tag" do
      assert PlaceSearch.name() == "place_search"
      assert PlaceSearch.category() == :web

      tags = Enum.map(PlaceSearch.failure_modes(), & &1.tag)

      assert Enum.sort(tags) == [
               "auth_failed",
               "invalid_location",
               "invalid_query",
               "location_required",
               "network",
               "parser_changed",
               "provider_error",
               "rate_limited",
               "response_too_large"
             ]
    end
  end

  describe "validation beyond the schema (§10.1)" do
    test "a missing query is refused before any request" do
      assert_refused(no_request(%{}), "invalid_query")
    end

    test "a query that is blank after trimming is refused" do
      assert_refused(no_request(%{"query" => "   "}), "invalid_query")
    end

    test "a query over 400 characters is refused" do
      assert_refused(no_request(%{"query" => String.duplicate("x", 401)}), "invalid_query")
    end

    test "a non-string query is refused" do
      assert_refused(no_request(%{"query" => 42}), "invalid_query")
    end

    test "latitude without longitude is refused" do
      assert_refused(no_request(%{"query" => "coffee", "latitude" => 40.7}), "invalid_location")
    end

    test "longitude without latitude is refused" do
      assert_refused(no_request(%{"query" => "coffee", "longitude" => -74.0}), "invalid_location")
    end

    test "an out-of-range coordinate is refused without echoing it" do
      result = no_request(%{"query" => "coffee", "latitude" => 91.0, "longitude" => -74.003})

      assert_refused(result, "invalid_location")
      {:ok, %{error: error}} = result
      refute error =~ "74.003"
    end

    test "a location string and coordinates together are refused as mutually exclusive" do
      result =
        no_request(%{
          "query" => "coffee",
          "location" => "SoHo",
          "latitude" => 40.7233,
          "longitude" => -74.003
        })

      assert_refused(result, "invalid_location")
      {:ok, %{error: error}} = result
      assert error =~ "mutually exclusive"
    end

    test "a blank or over-long location string is refused" do
      assert_refused(no_request(%{"query" => "coffee", "location" => " "}), "invalid_location")

      assert_refused(
        no_request(%{"query" => "coffee", "location" => String.duplicate("x", 201)}),
        "invalid_location"
      )
    end

    test "radius_meters without coordinates is refused" do
      result =
        no_request(%{"query" => "coffee", "location" => "SoHo", "radius_meters" => 500})

      assert_refused(result, "invalid_location")
      {:ok, %{error: error}} = result
      assert error =~ "latitude"
    end

    test "an out-of-range radius is refused even with coordinates" do
      for radius <- [0, 50_001, 1.5] do
        result =
          no_request(%{
            "query" => "coffee",
            "latitude" => 40.7233,
            "longitude" => -74.003,
            "radius_meters" => radius
          })

        assert_refused(result, "invalid_location")
      end
    end

    test "an out-of-range or non-integer count is refused" do
      for count <- [0, 11, "5", 2.0] do
        assert_refused(no_request(%{"query" => "coffee", "count" => count}), "invalid_query")
      end
    end

    test "a country that is not exactly two characters is refused" do
      for country <- ["u", "usa", 12] do
        assert_refused(no_request(%{"query" => "coffee", "country" => country}), "invalid_query")
      end
    end

    test "a language outside 2..12 characters is refused" do
      for language <- ["e", String.duplicate("x", 13)] do
        assert_refused(
          no_request(%{"query" => "coffee", "language" => language}),
          "invalid_query"
        )
      end
    end

    test "a units value outside the enum is refused" do
      assert_refused(no_request(%{"query" => "coffee", "units" => "km"}), "invalid_query")
    end

    test "country is uppercased and language lowercased only after validation" do
      {:ok, %{success: true}} =
        execute(
          %{"query" => "coffee", "country" => " us ", "language" => "EN-GB"},
          fn conn ->
            query = URI.decode_query(conn.query_string)

            assert query["country"] == "US"
            assert query["search_lang"] == "en-gb"

            json(conn, %{"results" => []})
          end
        )
    end

    test "count defaults to 5 and safesearch is fixed strict inside the adapter" do
      {:ok, %{success: true}} =
        execute(%{"query" => "coffee"}, fn conn ->
          query = URI.decode_query(conn.query_string)

          assert query["count"] == "5"
          assert query["safesearch"] == "strict"

          json(conn, %{"results" => []})
        end)
    end

    test "the trimmed query is what reaches the provider and the model-visible output" do
      {:ok, %{success: true, output: output}} =
        execute(%{"query" => "  quiet coffee shops  "}, fn conn ->
          assert URI.decode_query(conn.query_string)["q"] == "quiet coffee shops"
          json(conn, %{"results" => []})
        end)

      assert Jason.decode!(output)["query"] == "quiet coffee shops"
    end
  end

  describe "anchor precedence (§10.5)" do
    test "explicit coordinates anchor the request and bias its radius" do
      {:ok, %{success: true, output: output}} =
        execute(
          %{
            "query" => "ramen",
            "latitude" => 35.6812,
            "longitude" => 139.7671,
            "radius_meters" => 1500
          },
          fn conn ->
            query = URI.decode_query(conn.query_string)

            assert query["latitude"] == "35.6812"
            assert query["longitude"] == "139.7671"
            assert query["radius"] == "1500"

            json(conn, %{"results" => []})
          end,
          attended()
        )

      assert Jason.decode!(output)["search_anchor"] == %{"source" => "explicit_coordinates"}
    end

    test "an explicit location string anchors the request" do
      {:ok, %{success: true, output: output}} =
        execute(
          %{"query" => "coffee", "location" => "Kreuzberg, Berlin"},
          fn conn ->
            query = URI.decode_query(conn.query_string)

            assert query["location"] == "Kreuzberg, Berlin"
            refute Map.has_key?(query, "latitude")
            refute Map.has_key?(query, "longitude")

            json(conn, %{"results" => []})
          end,
          attended()
        )

      assert Jason.decode!(output)["search_anchor"] == %{
               "label" => "Kreuzberg, Berlin",
               "source" => "named"
             }
    end

    test "an explicit anchor searches from any context, attended or not" do
      for context <- [attended() | unattended_contexts()] do
        {:ok, %{success: true, output: output}} =
          execute(
            %{"query" => "coffee shops near me", "location" => "Lisbon"},
            fn conn ->
              query = URI.decode_query(conn.query_string)

              assert query["location"] == "Lisbon"
              refute Map.has_key?(query, "latitude")

              json(conn, %{"results" => []})
            end,
            context
          )

        assert Jason.decode!(output)["search_anchor"]["source"] == "named"
      end
    end

    # The tool reads no memory, no profile, and no config, so a query anchored to
    # the user's own position with no argument is unanswerable in EVERY context,
    # attended owner turn included. The model answers `location_required` by
    # asking which area to search (§12, `when_to_use/0`).
    test "a self-anchored query with no anchor is refused from any context" do
      for context <- [attended() | unattended_contexts()] do
        result = no_request(%{"query" => "best coffee near me"}, context)

        assert_refused(result, "location_required")
        {:ok, %{error: error}} = result
        assert error =~ "location"
      end
    end

    # A marker is a whole PHRASE, not a substring: "near me" also sits inside
    # "near memphis", and "nearby" inside "nearbyville". A plainly named city has
    # to search — refusing it asserts something false about the user's query.
    test "a named place that merely starts with a marker's tail is not self-anchored" do
      for query <- [
            "restaurants near memphis",
            "cafes near melbourne",
            "hotels near merida",
            "bars near mexico city",
            "coffee closest to melrose",
            "bakeries nearbyville"
          ] do
        {:ok, result} =
          execute(
            %{"query" => query},
            fn conn ->
              refute Map.has_key?(URI.decode_query(conn.query_string), "location")
              json(conn, %{"results" => []})
            end,
            attended()
          )

        assert result.success == true
        assert Jason.decode!(result.output)["search_anchor"] == %{"source" => "query_only"}
      end
    end

    # The boundary rule must not blunt the trigger: a genuine marker still
    # refuses bare, mid-query, and at the very end of the query, in any case.
    test "a genuine self-anchoring phrase is still refused wherever it sits" do
      for query <- [
            "near me",
            "anything NEAR ME open late",
            "pharmacies in my neighbourhood",
            "bars within walking distance",
            "sushi around here"
          ] do
        assert_refused(no_request(%{"query" => query}, attended()), "location_required")
      end
    end

    test "a query that is not anchored to the user's own position searches unanchored" do
      {:ok, %{success: true, output: output}} =
        execute(
          %{"query" => "coffee shops in Kreuzberg Berlin"},
          fn conn ->
            query = URI.decode_query(conn.query_string)

            refute Map.has_key?(query, "location")
            refute Map.has_key?(query, "latitude")

            json(conn, %{"results" => []})
          end,
          attended()
        )

      assert Jason.decode!(output)["search_anchor"] == %{"source" => "query_only"}
    end
  end

  describe "location privacy (§13.2)" do
    # §13.2 names logs alongside prompt, output, and telemetry. The only line this
    # call can write is `Net.HttpClient`'s stale-socket retry warning, so the
    # assertion has to run that path — a success logs nothing and would pass
    # vacuously. Explicit coordinates ride in the query string, so a label or an
    # exception message that grew a URL would put them in every operator's log.
    test "a coordinate anchor never reaches the log, on the one path that logs" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, %{success: false}} =
            execute(
              %{"query" => "coffee", "latitude" => 40.7233, "longitude" => -74.003},
              fn conn -> Req.Test.transport_error(conn, :closed) end,
              attended()
            )
        end)

      # Guard the guard: the warning did fire, so the refutes below mean something.
      assert log =~ "place_search api.search.brave.com"
      refute log =~ "40.7233"
      refute log =~ "74.003"
    end

    test "location_mode names the anchor source for every mode" do
      assert location_mode(%{"query" => "coffee in Lisbon"}, attended()) == "query_only"
      assert location_mode(%{"query" => "coffee", "location" => "Lisbon"}, attended()) == "named"

      assert location_mode(
               %{"query" => "coffee", "latitude" => 38.72, "longitude" => -9.14},
               attended()
             ) == "explicit_coordinates"
    end
  end

  describe "output (§10.2)" do
    test "carries the query, the anchor, and the normalized places" do
      {:ok, %{success: true, output: output}} =
        execute(%{"query" => "coffee", "location" => "SoHo"}, fn conn ->
          json(conn, %{"results" => [place_fixture()]})
        end)

      decoded = Jason.decode!(output)

      assert decoded["query"] == "coffee"
      assert decoded["search_anchor"] == %{"label" => "SoHo", "source" => "named"}
      assert [place] = decoded["places"]
      assert place["name"] == "Blue Bottle Coffee"
      assert place["canonical_url"] == "https://bluebottlecoffee.example/hayes"
      assert place["source_url"] == "https://search.brave.com/local/place/abc123"
    end

    test "truncates to count before encoding" do
      results = Enum.map(1..8, &%{"title" => "Cafe #{&1}", "url" => "https://cafe#{&1}.example/"})
      handler = attach_tool_telemetry()

      {:ok, %{success: true, output: output}} =
        execute(%{"query" => "coffee", "count" => 3}, fn conn ->
          assert URI.decode_query(conn.query_string)["count"] == "3"
          json(conn, %{"results" => results})
        end)

      assert length(Jason.decode!(output)["places"]) == 3
      refute output =~ "Cafe 4"

      assert_receive {:telemetry, _measurements, %{result_count: 3}}
      :telemetry.detach(handler)
    end

    test "the default count bounds an over-returning provider" do
      results = Enum.map(1..8, &%{"title" => "Cafe #{&1}", "url" => "https://cafe#{&1}.example/"})

      {:ok, %{success: true, output: output}} =
        execute(%{"query" => "coffee"}, fn conn -> json(conn, %{"results" => results}) end)

      assert length(Jason.decode!(output)["places"]) == 5
    end

    test "output is external content: the :network class keeps the untrusted frame" do
      capability = Builtin.from_tool_module(PlaceSearch)

      assert capability.policy_class == :network
      assert UntrustedContent.external?(capability)
    end
  end

  describe "advertisement — the first credential-gated built-in (§14.1)" do
    test "no resolvable key: advertise? is false and the seeded catalog hides it" do
      put_brave_key(nil)
      advertised = advertised_names(attended_context())

      refute PlaceSearch.advertise?(attended_context())
      refute "place_search" in advertised
      # The keyless sibling stays: the credential gate hides one tool, not the
      # whole web category.
      assert "web_search" in advertised
    end

    test "a @keyring sentinel that never materialized is not a credential" do
      put_brave_key("@keyring")

      refute PlaceSearch.advertise?(attended_context())
      refute "place_search" in advertised_names(attended_context())
    end

    test "a resolvable key: advertise? is true and the catalog offers it" do
      assert PlaceSearch.advertise?(attended_context())
      assert "place_search" in advertised_names(attended_context())
    end

    test "a guest turn is still offered the tool — the key is the only gate" do
      assert PlaceSearch.advertise?(%{source_trust: :guest})
    end

    test "execution re-guards: without a key the call is refused, not attempted" do
      put_brave_key(nil)

      result = no_request(%{"query" => "coffee", "location" => "SoHo"}, attended())

      assert_refused(result, "auth_failed")
    end

    # §18 row "Advertisement", prompt half: the runtime prompt is built from the
    # unfiltered capability list, so hiding the tool from the wire is only half
    # the gate. Naming a tool the model cannot call is the dead end the harness
    # category already removed — and here it would also steer local intent off
    # `web_search`, which still owns addresses and lookups without a key.
    test "no resolvable key: the runtime prompt names the tool nowhere" do
      put_brave_key(nil)

      prompt = runtime_prompt()

      refute prompt =~ "place_search"
      # The gate covers the WHOLE rule, not just the tool name: the near-me
      # ordering and the anchor-disclosure line are the same credential-gated
      # block, and a keyless daemon must not carry either.
      refute prompt =~ "search_anchor"
      refute prompt =~ "with no named area"
      # The keyless sibling still owns local intent in the routing block.
      assert prompt =~ "`web_search` for static facts"
    end

    test "a resolvable key: the prompt carries the catalog entry and the routing rule" do
      prompt = runtime_prompt()

      assert prompt =~ "- `place_search` — The user wants businesses"
      assert prompt =~ "`place_search` for businesses, landmarks, addresses"
      assert prompt =~ "pass it as `location` (or coordinates) instead of leaving it inside"
    end

    # Rev 4: the "near me" path is conversational — the MODEL fills `location`
    # from an area the user has shared, and asks when it knows none. The tool
    # reads nothing itself, so the ordering only exists if the prompt states it.
    test "a resolvable key: the prompt states the near-me ordering and the disclosure" do
      prompt = runtime_prompt()

      assert prompt =~ "with no named area, fill `location` from the area the user has shared"
      assert prompt =~ "this conversation first, then a coarse area you remember"
      assert prompt =~ "knowing neither, ask which area to search before calling"
      assert prompt =~ "Name the area you actually searched"
    end

    test "requires_setup names the shared Brave credential and its config path" do
      setup_requirement = PlaceSearch.requires_setup()

      assert setup_requirement.credential == "brave_api_key"
      assert setup_requirement.config_path == "[fermix_core.tools.web_search] brave_api_key"
      assert setup_requirement.description =~ "Brave"
      assert setup_requirement.description =~ "web_search"

      assert Builtin.from_tool_module(PlaceSearch).metadata.requires_setup == setup_requirement
    end
  end

  describe "telemetry (§16)" do
    test "one tool event per invocation, with the bounded search metadata" do
      handler = attach_tool_telemetry()

      {:ok, %{success: true}} =
        execute(
          %{"query" => "coffee", "location" => "SoHo"},
          fn conn -> json(conn, %{"results" => [place_fixture(), sparse_place_fixture()]}) end,
          %{tool_trace: %{request_headers: [%{name: "stale", value: "not-from-backend"}]}}
        )

      assert_receive {:telemetry, _measurements, metadata}

      assert metadata.tool == "place_search"
      assert metadata.success == true
      assert metadata.backend == "brave"
      assert metadata.result_count == 2
      assert metadata.has_media_count == 1
      assert metadata.location_mode == "named"
      assert %{name: "x-subscription-token", value: "***REDACTED***"} in metadata.request_headers
      refute inspect(metadata.request_headers) =~ @key
      refute inspect(metadata.request_headers) =~ "not-from-backend"

      refute_received {:telemetry, _more_measurements, _more_metadata}
      :telemetry.detach(handler)
    end

    test "a provider failure emits the same one event carrying the named tag" do
      handler = attach_tool_telemetry()

      {:ok, %{success: false, error: error}} =
        execute(%{"query" => "coffee"}, fn conn ->
          Plug.Conn.resp(conn, 429, "slow down")
        end)

      assert error =~ "rate_limited"

      assert_receive {:telemetry, _measurements, metadata}
      assert metadata.success == false
      assert metadata.backend == "brave"
      assert metadata.location_mode == "query_only"
      assert metadata.error =~ "rate_limited"

      refute_received {:telemetry, _more_measurements, _more_metadata}
      :telemetry.detach(handler)
    end

    test "a validation refusal emits one event and never reaches the provider" do
      handler = attach_tool_telemetry()

      assert_refused(no_request(%{"query" => "   "}), "invalid_query")

      assert_receive {:telemetry, _measurements, metadata}
      assert metadata.success == false
      assert metadata.backend == "brave"
      assert metadata.error =~ "invalid_query"

      refute_received {:telemetry, _more_measurements, _more_metadata}
      :telemetry.detach(handler)
    end
  end

  describe "routing guidance (§12)" do
    test "the tool tells the model to pass a named location as an argument" do
      guidance = PlaceSearch.description() <> " " <> PlaceSearch.when_to_use()

      assert guidance =~ "`location`"
      assert guidance =~ "`query`"
      # §10.1: radius is a ranking bias, and the description has to say so.
      assert PlaceSearch.description() =~ "ranking"
      assert PlaceSearch.description() =~ "geofence"
    end

    # Rev 4: the tool's own guidance carries the same near-me ordering as the
    # runtime rule — an area shared in conversation, then a remembered coarse
    # one, then ask — plus the obligation to name what was used.
    test "when_to_use carries the conversational near-me ordering" do
      guidance = PlaceSearch.when_to_use()

      assert guidance =~ "the area they have shared"
      assert guidance =~ "this conversation first, then a coarse area you remember"
      assert guidance =~ "ask which area to search before calling"
      assert guidance =~ "Say which area you searched"
    end

    test "an example shows the named-location call" do
      assert Enum.any?(PlaceSearch.examples(), &Map.has_key?(&1.args, "location"))
      assert Enum.all?(PlaceSearch.examples(), &(is_map(&1.args) and is_binary(&1.note)))
    end

    test "an example shows near-me filled from what the user shared" do
      assert Enum.any?(PlaceSearch.examples(), &(&1.note =~ "shared earlier"))
    end
  end

  describe "registration" do
    test "place_search is a seeded built-in" do
      assert PlaceSearch in BuiltinSeeder.builtin_tool_modules()
      assert "place_search" in Builtin.classified_names()
      assert Builtin.owner_only_declared?("place_search")
      refute Builtin.from_tool_module(PlaceSearch).owner_only?
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp assert_refused({:ok, result}, tag) do
    assert result.success == false
    assert result.error =~ tag
  end

  defp execute(args, handler, overrides \\ %{}) do
    test_id = unique_id()
    Req.Test.stub(test_id, handler)
    PlaceSearch.execute(args, context(test_id, overrides))
  end

  defp no_request(args, overrides \\ %{}) do
    test_pid = self()

    result =
      execute(
        args,
        fn conn ->
          send(test_pid, :unexpected_request)
          json(conn, %{"results" => []})
        end,
        overrides
      )

    refute_received :unexpected_request
    result
  end

  defp location_mode(args, overrides) do
    handler = attach_tool_telemetry()

    {:ok, %{success: true}} =
      execute(args, fn conn -> json(conn, %{"results" => []}) end, overrides)

    assert_receive {:telemetry, _measurements, %{location_mode: mode}}
    :telemetry.detach(handler)
    mode
  end

  defp context(test_id, overrides) do
    %{
      agent_name: "test_agent",
      conversation_key: :test,
      req_options: [plug: {Req.Test, test_id}],
      net_resolver: public_resolver()
    }
    |> Map.merge(overrides)
  end

  defp attended, do: %{source_trust: :operator, computer_use_origin: :interactive}

  defp attended_context, do: Map.merge(%{agent_name: "test_agent"}, attended())

  # Guest, background, delegated, coding-continuation, and scheduled (no origin
  # marker at all): the anchor decision is context-blind, so every one of them
  # answers exactly as an attended owner turn does.
  defp unattended_contexts do
    [
      %{source_trust: :guest, computer_use_origin: :interactive},
      %{source_trust: :operator, computer_use_origin: :unattended},
      %{source_trust: :operator, computer_use_origin: :interactive, subagent_depth: 1},
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        harness_continuation_depth: 1
      },
      %{source_trust: :operator}
    ]
  end

  defp advertised_names(context) do
    seeded_capabilities()
    |> Advertisement.prepare(context)
    |> Enum.map(& &1.name)
  end

  defp seeded_capabilities do
    registry_name = :"place_search_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry_name})
    BuiltinSeeder.start_link(capability_registry: registry_name)

    Registry.list(registry_name, kind: :builtin)
  end

  # The prompt is built from the FULL trust-filtered list (M10 §3.2), so it is
  # a second surface that has to answer the credential gate — this is what
  # `Agents.RuntimeContext.build_profile/4` hands `RuntimeSections`.
  defp runtime_prompt do
    RuntimeSections.build([], capabilities: seeded_capabilities())
  end

  defp put_brave_key(nil), do: Application.put_env(:fermix_core, :tools, web_search: [])

  defp put_brave_key(key),
    do: Application.put_env(:fermix_core, :tools, web_search: [brave_api_key: key])

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp attach_tool_telemetry do
    handler_id = "test-place-search-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn _event, measurements, metadata, _config ->
        if self() == test_pid and metadata.tool == "place_search" do
          send(test_pid, {:telemetry, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end

  defp public_resolver do
    fn "api.search.brave.com" -> {:ok, [{93, 184, 216, 34}]} end
  end

  defp unique_id, do: :"place_search_tool_#{System.unique_integer([:positive])}"

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp place_fixture do
    %{
      "type" => "location_result",
      "id" => "ChIJ-ephemeral-poi-id",
      "title" => "<strong>Blue Bottle</strong> Coffee",
      "url" => "https://bluebottlecoffee.example/hayes",
      "provider_url" => "https://search.brave.com/local/place/abc123",
      "rating" => %{"ratingValue" => 4.6, "bestRating" => 5, "reviewCount" => 321},
      "thumbnail" => %{"src" => "https://imgs.search.brave.com/thumb/abc.jpg"}
    }
  end

  defp sparse_place_fixture do
    %{"title" => "Sparse Cafe", "url" => "https://sparse.example/"}
  end
end
