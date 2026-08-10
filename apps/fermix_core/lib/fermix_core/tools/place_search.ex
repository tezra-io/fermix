defmodule FermixCore.Tools.PlaceSearch do
  @moduledoc """
  Find places — businesses, landmarks, addresses — through one bounded Brave
  Place Search request (MILESTONE_31 §10).

  The tool owns the provider-visible schema (§10.1) and the anchor decision
  (§10.5); `PlaceSearch.Brave` owns the request, the parser, and the tagged
  failures (§10.2–§10.4). Nothing here falls back to web search, a browser, or
  another provider: a failure is returned with its tag.

  ## The anchor, in strict precedence

  1. explicit `latitude`/`longitude`;
  2. an explicit `location` string;
  3. otherwise the query travels unanchored — unless it is anchored to the
     user's own position ("near me"), which without an anchor is unanswerable
     and returns `location_required` rather than a search of the wrong place.

  A location NAME inside `query` is undetectable here, so the routing contract
  (§12, `when_to_use/0`) requires the model to pass a user-named place as an
  argument. The same contract owns "near me" with no named area (rev 4): the
  model fills `location` from an area the user has shared, in conversation or in
  remembered coarse profile facts. That is a model-supplied argument on the way
  in — nothing here reads memory or config, and knowing no area at all, the
  model asks which one to search.

  ## What the model sees, and what it never sees

  Model-visible output carries `search_anchor` — the anchor label and the anchor
  SOURCE; telemetry records `location_mode` (`query_only` / `named` /
  `explicit_coordinates`), never a location value (§13.2).

  ## Credential gating

  This is the first credential-gated built-in (§14.1). `advertise?/1` hides the
  tool from a daemon with no resolvable Brave key, and `execute/2` repeats the
  guard: advertisement is a readiness signal, never the only barrier.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Tools.PlaceSearch.Brave
  alias FermixCore.Tools.SearchCredential
  alias FermixCore.Tools.Support

  @backend "brave"
  @max_query_chars 400
  @max_location_chars 200
  @max_radius_meters 50_000
  @max_count 10
  @default_count 5
  @latitude_limit 90
  @longitude_limit 180
  @min_language_chars 2
  @max_language_chars 12
  @country_chars 2

  # Phrases that anchor a query to the CALLER's own position. Every one of them
  # is unsatisfiable without an anchor — unlike a place name, which the provider
  # resolves from the query text — so this list is a refusal trigger, not an
  # attempt to detect locations in prose (§10.1).
  @self_anchored_markers [
    "near me",
    "nearest to me",
    "nearby",
    "near here",
    "around me",
    "around here",
    "close to me",
    "closest to me",
    "close by",
    "in my area",
    "in my neighborhood",
    "in my neighbourhood",
    "walking distance",
    "walkable from here"
  ]

  @location_required "location_required: this query is anchored to the user's own " <>
                       "position, but no location was supplied. Ask which area to search, " <>
                       "then pass it as `location` or as `latitude`/`longitude`."

  @impl true
  @spec name() :: String.t()
  def name, do: "place_search"

  @impl true
  @spec description() :: String.t()
  def description do
    "Find places — businesses, landmarks, addresses — with hours, ratings, contact " <>
      "details, distance, and a source link per result. Pass a place the user names as " <>
      "`location` (or as `latitude`/`longitude`); do NOT leave it inside `query`. " <>
      "`radius_meters` biases ranking around explicit coordinates — it is not a hard geofence."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["query"],
      properties: %{
        query: %{type: "string", maxLength: @max_query_chars},
        location: %{type: "string", maxLength: @max_location_chars},
        latitude: %{type: "number", minimum: -@latitude_limit, maximum: @latitude_limit},
        longitude: %{type: "number", minimum: -@longitude_limit, maximum: @longitude_limit},
        radius_meters: %{type: "integer", minimum: 1, maximum: @max_radius_meters},
        count: %{type: "integer", minimum: 1, maximum: @max_count},
        country: %{type: "string", minLength: @country_chars, maxLength: @country_chars},
        language: %{
          type: "string",
          minLength: @min_language_chars,
          maxLength: @max_language_chars
        },
        units: %{type: "string", enum: ["metric", "imperial"]}
      },
      additionalProperties: false
    }
  end

  @impl true
  @spec when_to_use() :: String.t()
  def when_to_use do
    "The user wants businesses, landmarks, addresses, or local recommendations — not " <>
      "general web research (`web_search`) and not a live map, booking flow, or price " <>
      "check (`browser`). Whenever the user names an area, pass it as `location`; for " <>
      "\"near me\" with no named area, pass the area they have shared — this " <>
      "conversation first, then a coarse area you remember about them — and knowing " <>
      "neither, ask which area to search before calling. Say which area you searched, " <>
      "and keep each place's returned URL in the answer."
  end

  @impl true
  @spec examples() :: [map()]
  def examples do
    [
      %{
        args: %{"query" => "quiet coffee shops", "location" => "SoHo, New York"},
        note: "the user named the area — it travels as `location`, not inside `query`"
      },
      %{
        args: %{
          "query" => "ramen",
          "latitude" => 35.6812,
          "longitude" => 139.7671,
          "radius_meters" => 1500
        },
        note: "coordinates the user supplied; radius biases ranking around them"
      },
      %{
        args: %{"query" => "ramen", "location" => "Kreuzberg, Berlin"},
        note:
          "\"near me\" with no named area: the area the user shared earlier travels as `location`"
      }
    ]
  end

  @impl true
  @spec failure_modes() :: [map()]
  def failure_modes do
    [
      %{
        tag: "invalid_query",
        description: "query, count, country, language, or units is invalid"
      },
      %{
        tag: "invalid_location",
        description:
          "coordinates are incomplete/out of range, conflict with location, or radius has no coordinates"
      },
      %{
        tag: "location_required",
        description: "the query is anchored to the user's own position and no anchor is available"
      },
      %{tag: "auth_failed", description: "the Brave API key is missing or rejected"},
      %{tag: "rate_limited", description: "the place provider returned a rate limit"},
      %{
        tag: "provider_error",
        description: "the place provider returned an unexpected HTTP status"
      },
      %{
        tag: "parser_changed",
        description: "the place response no longer matches the known shape"
      },
      %{tag: "response_too_large", description: "the response exceeded the streaming byte cap"},
      %{tag: "network", description: "transport or HTTP failure"}
    ]
  end

  @impl true
  @spec requires_setup() :: map()
  def requires_setup do
    %{
      credential: "brave_api_key",
      config_path: "[fermix_core.tools.web_search] brave_api_key",
      description:
        "A Brave Search API key. One key serves both consumers: web_search's Brave " <>
          "backend and place_search. Brave does not have to be the active web backend, " <>
          "and each endpoint call is separately metered."
    }
  end

  @impl true
  @spec category() :: atom()
  def category, do: :web

  @doc """
  Advertise the tool only when the shared Brave credential resolves (§14.1).

  Discovered via `function_exported?` at `AgentLoop.build_state`. A daemon with
  no key never shows a tool whose every call would refuse; `execute/2` repeats
  the guard, so this is readiness, not the security barrier.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: match?({:ok, _key}, SearchCredential.brave())

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), Map.delete(context, :tool_trace), fn -> run(args, context) end)
  end

  # The credential is re-resolved on every call: advertisement can never be the
  # only readiness/security barrier (§14.1).
  defp run(args, context) do
    with {:ok, api_key} <- SearchCredential.brave(),
         {:ok, fields} <- validate(args),
         {:ok, anchor} <- anchor(fields) do
      search(fields, anchor, api_key, context)
    else
      {:error, reason} -> error_result(reason, %{})
    end
  end

  defp search(fields, anchor, api_key, context) do
    request = request(fields, anchor)

    case Brave.search(request, brave_api_key: api_key, context: context) do
      {:ok, places, trace} -> success(fields, anchor, places, trace)
      {:error, reason, trace} -> error_result(reason, Map.put(trace, :location_mode, anchor.mode))
    end
  end

  # Truncated to `count` BEFORE encoding: the provider may return more than it
  # was asked for, and the model must never be handed rows the caller capped out.
  defp success(fields, anchor, places, trace) do
    kept = Enum.take(places, fields.count)

    output = %{query: fields.query, search_anchor: anchor.search_anchor, places: kept}

    Support.success_json(output, metadata(anchor.mode, kept, trace))
  end

  defp metadata(location_mode, places, trace) do
    Map.merge(trace, %{
      backend: @backend,
      location_mode: location_mode,
      result_count: length(places),
      has_media_count: Enum.count(places, &(Map.get(&1, :media, []) != []))
    })
  end

  defp error_result(reason, metadata) do
    {:ok, result} = Support.error(reason)
    {:ok, result, Map.put(metadata, :backend, @backend)}
  end

  # -- validation (§10.1) ----------------------------------------------------

  defp validate(args) do
    with {:ok, query} <- query(args),
         {:ok, coordinates} <- coordinates(args),
         {:ok, location} <- location(args),
         :ok <- exclusive(location, coordinates),
         {:ok, radius} <- radius(args, coordinates),
         {:ok, count} <- count(args),
         {:ok, locale} <- locale(args) do
      {:ok,
       Map.merge(locale, %{
         query: query,
         coordinates: coordinates,
         location: location,
         radius: radius,
         count: count
       })}
    end
  end

  defp query(args) do
    case Map.get(args, "query") do
      value when is_binary(value) -> query_text(String.trim(value))
      nil -> {:error, "invalid_query: query is required"}
      _other -> {:error, "invalid_query: query must be a string"}
    end
  end

  defp query_text(""), do: {:error, "invalid_query: query must not be blank"}

  defp query_text(query) when byte_size(query) > 0 do
    if String.length(query) <= @max_query_chars do
      {:ok, query}
    else
      {:error, "invalid_query: query must be at most #{@max_query_chars} characters"}
    end
  end

  defp coordinates(args), do: pair(Map.get(args, "latitude"), Map.get(args, "longitude"))

  defp pair(nil, nil), do: {:ok, nil}

  defp pair(latitude, longitude) when is_number(latitude) and is_number(longitude),
    do: in_range(latitude, longitude)

  defp pair(_latitude, _longitude),
    do: {:error, "invalid_location: latitude and longitude must be supplied together as numbers"}

  # The out-of-range message never echoes the value: coordinates are the one
  # class of argument §13.2 keeps out of logs and traces, and an error string
  # rides both.
  defp in_range(latitude, longitude)
       when latitude >= -@latitude_limit and latitude <= @latitude_limit and
              longitude >= -@longitude_limit and longitude <= @longitude_limit,
       do: {:ok, {latitude, longitude}}

  defp in_range(_latitude, _longitude),
    do:
      {:error,
       "invalid_location: latitude must be -#{@latitude_limit}..#{@latitude_limit} and " <>
         "longitude -#{@longitude_limit}..#{@longitude_limit}"}

  defp location(args) do
    case Map.get(args, "location") do
      nil -> {:ok, nil}
      value when is_binary(value) -> location_text(String.trim(value))
      _other -> {:error, "invalid_location: location must be a string"}
    end
  end

  defp location_text(""), do: {:error, "invalid_location: location must not be blank"}

  defp location_text(location) when byte_size(location) > 0 do
    if String.length(location) <= @max_location_chars do
      {:ok, location}
    else
      {:error, "invalid_location: location must be at most #{@max_location_chars} characters"}
    end
  end

  defp exclusive(nil, _coordinates), do: :ok
  defp exclusive(_location, nil), do: :ok

  defp exclusive(_location, _coordinates),
    do:
      {:error,
       "invalid_location: location and latitude/longitude are mutually exclusive; pass one anchor"}

  defp radius(args, coordinates) do
    case Map.get(args, "radius_meters") do
      nil -> {:ok, nil}
      value -> radius_value(value, coordinates)
    end
  end

  defp radius_value(_value, nil),
    do: {:error, "invalid_location: radius_meters requires latitude and longitude"}

  defp radius_value(value, _coordinates)
       when is_integer(value) and value >= 1 and value <= @max_radius_meters,
       do: {:ok, value}

  defp radius_value(_value, _coordinates),
    do: {:error, "invalid_location: radius_meters must be an integer 1..#{@max_radius_meters}"}

  defp count(args) do
    case Map.get(args, "count", @default_count) do
      value when is_integer(value) and value >= 1 and value <= @max_count -> {:ok, value}
      _other -> {:error, "invalid_query: count must be an integer 1..#{@max_count}"}
    end
  end

  defp locale(args) do
    with {:ok, country} <- country(args),
         {:ok, language} <- language(args),
         {:ok, units} <- units(args) do
      {:ok, %{country: country, language: language, units: units}}
    end
  end

  defp country(args) do
    case Map.get(args, "country") do
      nil -> {:ok, nil}
      value when is_binary(value) -> country_code(String.trim(value))
      _other -> {:error, country_error()}
    end
  end

  # Case normalization happens only AFTER the length check (§10.1): normalizing
  # first would let a malformed value through wearing a tidier costume.
  defp country_code(country) do
    if String.length(country) == @country_chars do
      {:ok, String.upcase(country)}
    else
      {:error, country_error()}
    end
  end

  defp country_error, do: "invalid_query: country must be a #{@country_chars}-letter code"

  defp language(args) do
    case Map.get(args, "language") do
      nil -> {:ok, nil}
      value when is_binary(value) -> language_tag(String.trim(value))
      _other -> {:error, language_error()}
    end
  end

  defp language_tag(language) do
    length = String.length(language)

    if length >= @min_language_chars and length <= @max_language_chars do
      {:ok, String.downcase(language)}
    else
      {:error, language_error()}
    end
  end

  defp language_error,
    do:
      "invalid_query: language must be #{@min_language_chars}..#{@max_language_chars} characters"

  defp units(args) do
    case Map.get(args, "units") do
      nil -> {:ok, nil}
      "metric" -> {:ok, :metric}
      "imperial" -> {:ok, :imperial}
      _other -> {:error, ~s|invalid_query: units must be "metric" or "imperial"|}
    end
  end

  # -- anchor (§10.5) --------------------------------------------------------

  defp anchor(%{coordinates: {latitude, longitude}}) do
    {:ok,
     %{
       mode: "explicit_coordinates",
       request: {:coordinates, latitude, longitude},
       search_anchor: %{source: "explicit_coordinates"}
     }}
  end

  defp anchor(%{location: location}) when is_binary(location) do
    {:ok,
     %{
       mode: "named",
       request: {:location, location},
       search_anchor: %{label: location, source: "named"}
     }}
  end

  # No explicit anchor. A query anchored to the user's own position is
  # unanswerable from any context — the tool reads no memory, no profile, and no
  # config — so it refuses rather than searching somewhere the user never named;
  # anything else travels unanchored and the provider resolves the query text.
  defp anchor(fields) do
    if self_anchored?(fields.query) do
      {:error, @location_required}
    else
      {:ok, %{mode: "query_only", request: nil, search_anchor: %{source: "query_only"}}}
    end
  end

  defp self_anchored?(query) do
    downcased = String.downcase(query)

    Enum.any?(@self_anchored_markers, &String.contains?(downcased, &1))
  end

  defp request(fields, anchor) do
    %{query: fields.query, count: fields.count}
    |> put_present(:anchor, anchor.request)
    |> put_present(:radius_meters, fields.radius)
    |> put_present(:country, fields.country)
    |> put_present(:language, fields.language)
    |> put_present(:units, fields.units)
  end

  defp put_present(request, _key, nil), do: request
  defp put_present(request, key, value), do: Map.put(request, key, value)
end
