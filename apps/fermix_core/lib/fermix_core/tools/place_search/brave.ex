defmodule FermixCore.Tools.PlaceSearch.Brave do
  @moduledoc """
  Brave Place Search adapter: one bounded request, one normalized place list
  (MILESTONE_31 §10.2–§10.4).

  The endpoint is a compile-time constant. The model supplies query parameters,
  never a URL, and `Net.Guard` validates the fixed endpoint before every call.

  Transport rules, all of them deliberate:

    * `Net.HttpClient` on the shared `FermixCore.Finch` pool, so the family's
      single stale-socket retry is the *only* retry — Req-level retry is off;
    * `redirect: false`, forced after the caller's test options merge: a 3xx is
      an error, never a hop that carries `x-subscription-token` somewhere else;
    * the response is byte-capped **while streaming** into an `:into` collector
      (the `web_fetch` pattern), not truncated after a provider has already made
      the daemon allocate it;
    * because `:into` is set, Req skips its decompress step — so this adapter
      sends no `accept-encoding` header (Req also skips adding its own).
      Asking for gzip here would hand `Jason` a compressed body and report
      `parser_changed` for a healthy response. Req's *decode* step does still
      run on a collected body, so `decode_body: false` keeps decoding here,
      where a malformed payload is a tagged `parser_changed` rather than a
      `Jason.DecodeError` surfacing as a transport failure;
    * the key travels only as `x-subscription-token`, redacted in trace
      metadata.

  One invocation is one provider call. There is no `/local/pois` or
  `/local/descriptions` follow-up, and no fallback to any other provider, tool,
  or cached shape: every failure is returned as a tagged reason (§10.4). The
  only repeat that can occur is `Net.HttpClient` re-issuing *the same* call once
  when a pooled socket was already dead — the family's stale-socket retry, not a
  second query.

  This is not a `PlaceSearch.Backend` behaviour and must not become one — §21.6
  rejects a shared callback while there is exactly one approved raw provider.

  `opts` is the resolved `[fermix_core.tools.web_search]` keyword (the one Brave
  credential, §8.1) plus `:context` — the same shape the `web_search` Brave
  backend receives. The caller owns provider-visible schema validation (§10.1);
  the request contract below is re-checked here because a malformed outbound
  request must fail locally rather than buy a metered 4xx.
  """

  alias FermixCore.Net.Guard
  alias FermixCore.Net.HttpClient
  alias FermixCore.Tools.SearchCredential
  alias FermixCore.Tools.SnippetSanitizer

  @endpoint "https://api.search.brave.com/res/v1/local/place_search"
  @request_label "place_search #{URI.parse(@endpoint).host}"

  # Place payloads are small (ten records of short strings). One MiB — the
  # `web_fetch` cap — is orders of magnitude of headroom while still bounding
  # what a hostile or broken provider can make the daemon hold.
  @max_body_bytes 1_048_576
  @receive_timeout_ms 15_000

  @max_query_chars 400
  @max_radius_meters 50_000
  @default_count 5
  @max_places 10
  @max_categories 5
  @max_cuisines 5
  @max_days 7
  # Not a §10.2 cap: a day is one string, and this bounds the ranges joined
  # into it so a pathological payload cannot build an unbounded label.
  @max_day_ranges 8

  @type anchor :: {:location, String.t()} | {:coordinates, number(), number()}

  @type request :: %{
          required(:query) => String.t(),
          optional(:anchor) => anchor(),
          optional(:radius_meters) => pos_integer(),
          optional(:count) => pos_integer(),
          optional(:country) => String.t(),
          optional(:language) => String.t(),
          optional(:units) => :metric | :imperial
        }

  @type place :: %{required(:name) => String.t(), optional(atom()) => term()}
  @type trace_metadata :: %{optional(atom()) => term()}

  @doc """
  Runs one place search.

  Returns the normalized places (at most #{@max_places}) with the trace
  metadata for the tool event, or a tagged reason string from §10.4:
  `invalid_query`, `invalid_location`, `auth_failed`, `rate_limited`,
  `provider_error`, `parser_changed`, `response_too_large`, `network`.
  """
  @spec search(request(), keyword()) ::
          {:ok, [place()], trace_metadata()} | {:error, String.t(), trace_metadata()}
  def search(request, opts) when is_map(request) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, params} <- params(request),
         {:ok, api_key} <- SearchCredential.brave(opts) do
      request_options = request_options(context, params, api_key)
      trace_metadata = trace_metadata(request_options)

      case run(request_options, context) do
        {:ok, places} -> {:ok, places, trace_metadata}
        {:error, reason} -> {:error, error_string(reason), trace_metadata}
      end
    else
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  # -- request ---------------------------------------------------------------

  defp params(request) do
    with {:ok, query} <- query_param(request),
         {:ok, anchor} <- anchor_params(request),
         {:ok, radius} <- radius_params(request),
         {:ok, count} <- count_param(request),
         {:ok, locale} <- locale_params(request) do
      {:ok, [q: query] ++ anchor ++ radius ++ [count: count, safesearch: "strict"] ++ locale}
    end
  end

  defp query_param(%{query: query}) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" -> {:error, "invalid_query: query must not be blank"}
      String.length(trimmed) > @max_query_chars -> {:error, query_too_long()}
      true -> {:ok, trimmed}
    end
  end

  defp query_param(_request), do: {:error, "invalid_query: query must be a string"}

  defp query_too_long, do: "invalid_query: query max #{@max_query_chars} characters"

  # Error text never echoes an anchor: a saved center is the one value §13.2
  # keeps out of logs, traces, and model-visible text.
  defp anchor_params(%{anchor: {:location, location}}) when is_binary(location) do
    case String.trim(location) do
      "" -> {:error, "invalid_location: location must not be blank"}
      trimmed -> {:ok, [location: trimmed]}
    end
  end

  defp anchor_params(%{anchor: {:coordinates, latitude, longitude}})
       when is_number(latitude) and is_number(longitude) do
    if latitude >= -90 and latitude <= 90 and longitude >= -180 and longitude <= 180 do
      {:ok, [latitude: latitude, longitude: longitude]}
    else
      {:error, "invalid_location: latitude must be -90..90 and longitude -180..180"}
    end
  end

  defp anchor_params(%{anchor: _anchor}),
    do:
      {:error, "invalid_location: anchor must be {:location, string} or {:coordinates, lat, lng}"}

  defp anchor_params(_request), do: {:ok, []}

  defp radius_params(%{radius_meters: radius, anchor: {:coordinates, _lat, _lng}})
       when is_integer(radius) and radius >= 1 and radius <= @max_radius_meters do
    {:ok, [radius: radius]}
  end

  defp radius_params(%{radius_meters: _radius, anchor: {:coordinates, _lat, _lng}}) do
    {:error, "invalid_location: radius_meters must be an integer 1..#{@max_radius_meters}"}
  end

  defp radius_params(%{radius_meters: _radius}) do
    {:error, "invalid_location: radius_meters requires latitude and longitude"}
  end

  defp radius_params(_request), do: {:ok, []}

  defp count_param(%{count: count})
       when is_integer(count) and count >= 1 and count <= @max_places,
       do: {:ok, count}

  defp count_param(%{count: _count}),
    do: {:error, "invalid_query: count must be an integer 1..#{@max_places}"}

  defp count_param(_request), do: {:ok, @default_count}

  defp locale_params(request) do
    with {:ok, country} <- string_param(request, :country, :country),
         {:ok, language} <- string_param(request, :language, :search_lang),
         {:ok, units} <- units_param(request) do
      {:ok, country ++ language ++ units}
    end
  end

  defp string_param(request, key, param) do
    case Map.get(request, key) do
      nil -> {:ok, []}
      value when is_binary(value) -> non_blank_param(String.trim(value), key, param)
      _other -> {:error, "invalid_query: #{key} must be a string"}
    end
  end

  defp non_blank_param("", key, _param), do: {:error, "invalid_query: #{key} must not be blank"}
  defp non_blank_param(value, _key, param), do: {:ok, [{param, value}]}

  defp units_param(%{units: units}) when units in [:metric, :imperial],
    do: {:ok, [units: Atom.to_string(units)]}

  defp units_param(%{units: _units}),
    do: {:error, "invalid_query: units must be :metric or :imperial"}

  defp units_param(_request), do: {:ok, []}

  defp request_options(context, params, api_key) do
    [
      retry: false,
      receive_timeout: @receive_timeout_ms,
      headers: [{"accept", "application/json"}, {"x-subscription-token", api_key}],
      params: params
    ]
    |> Keyword.merge(Map.get(context, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Keyword.put(:into, &collect_capped/2)
    |> Keyword.put(:decode_body, false)
  end

  defp trace_metadata(request_options) do
    request_headers =
      request_options
      |> Keyword.get(:headers, [])
      |> Guard.redact_headers_for_trace()

    %{request_headers: request_headers}
  end

  # -- transport -------------------------------------------------------------

  defp run(request_options, context) do
    with :ok <- Guard.validate(@endpoint, resolver: resolver(context)),
         {:ok, response} <- request(request_options),
         {:ok, body} <- response_json(response) do
      parse(body)
    end
  end

  defp request(request_options) do
    req = Req.new([method: :get, url: @endpoint] ++ request_options)

    case HttpClient.request(req, @request_label) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, "network: #{inspect(exception)}"}
    end
  end

  # The cap is enforced on the wire: the over-cap chunk is never appended and
  # the stream is halted, so the daemon holds at most @max_body_bytes.
  defp collect_capped({:data, data}, {req, %{body: body} = response})
       when is_binary(data) and is_binary(body) do
    if byte_size(body) + byte_size(data) > @max_body_bytes do
      {:halt, {req, Req.Response.put_private(response, :fermix_body_cap, :too_large)}}
    else
      {:cont, {req, %{response | body: body <> data}}}
    end
  end

  # Status first: on a 4xx/5xx the status is the actionable fact, and the body
  # is the provider's error page rather than a place list.
  defp response_json(%{status: status} = response) when status in 200..299 do
    with :ok <- within_cap(response), do: decode_body(response.body)
  end

  defp response_json(%{status: status}) when status in 300..399 do
    {:error, "provider_error: HTTP #{status} redirect refused (place search never follows one)"}
  end

  defp response_json(%{status: status}) when status in [401, 403],
    do: {:error, "auth_failed: HTTP #{status}"}

  defp response_json(%{status: 429}), do: {:error, "rate_limited: HTTP 429"}
  defp response_json(%{status: status}), do: {:error, "provider_error: HTTP #{status}"}

  defp within_cap(%{private: %{fermix_body_cap: :too_large}}),
    do: {:error, "response_too_large: body exceeded #{@max_body_bytes} bytes"}

  defp within_cap(_response), do: :ok

  # `Jason.DecodeError` carries the RAW body in `:data`, so inspecting it would
  # put kilobytes of provider bytes into the model-visible error, the tool's
  # telemetry metadata, and the Opik export — outside the untrusted-content frame
  # a failed tool result never gets, and against §16 ("errors include the
  # normalized tag and backend, not response bodies"). A 200 carrying a CDN
  # challenge page is the ordinary way here. The byte offset is the whole
  # diagnosis that is safe to keep.
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, "parser_changed: non-object JSON response"}
      {:error, %Jason.DecodeError{position: position}} -> {:error, decode_failed(position)}
    end
  end

  defp decode_body(_body), do: {:error, "parser_changed: non-binary response body"}

  defp decode_failed(position),
    do: "parser_changed: response body is not JSON (first bad byte at #{position})"

  defp error_string(reason) when is_binary(reason), do: reason
  defp error_string(reason), do: "network: #{inspect(reason)}"

  defp resolver(context), do: Map.get(context, :net_resolver, nil)

  # -- normalization (§10.2) -------------------------------------------------

  defp parse(%{"results" => results}) when is_list(results) do
    results
    |> Enum.take(@max_places)
    |> parse_places()
  end

  defp parse(%{"results" => _results}), do: {:error, parser_changed("results", "an array")}
  defp parse(_body), do: {:error, parser_changed("results", "present")}

  defp parse_places(results) do
    results
    |> Enum.reduce_while({:ok, []}, &collect_place/2)
    |> finish_places()
  end

  defp collect_place(result, {:ok, places}) do
    case place(result) do
      {:ok, nil} -> {:cont, {:ok, places}}
      {:ok, place} -> {:cont, {:ok, [place | places]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finish_places({:ok, places}), do: {:ok, Enum.reverse(places)}
  defp finish_places({:error, reason}), do: {:error, reason}

  defp place(%{} = result) do
    with {:ok, name} <- text(result, "title"),
         {:ok, canonical_url} <- https_url(result, "url"),
         {:ok, source_url} <- https_url(result, "provider_url"),
         {:ok, fields} <- optional_fields(result, source_url) do
      {:ok, retain(name, canonical_url, source_url, fields)}
    end
  end

  defp place(_result), do: {:error, parser_changed("results[]", "an object")}

  # A place with no name, or with no HTTPS page a reader can open, is dropped —
  # not an error. The ephemeral POI id, pictures, and profiles are never read.
  defp retain(nil, _canonical_url, _source_url, _fields), do: nil
  defp retain(_name, nil, nil, _fields), do: nil

  defp retain(name, canonical_url, source_url, fields) do
    %{name: name}
    |> put_present(:canonical_url, canonical_url)
    |> put_present(:source_url, source_url)
    |> Map.merge(fields)
  end

  defp optional_fields(result, source_url) do
    with {:ok, description} <- text(result, "description"),
         {:ok, location} <- coordinates(result),
         {:ok, address} <- address(result),
         {:ok, opening_hours} <- opening_hours(result),
         {:ok, contact} <- contact(result),
         {:ok, rating} <- rating(result),
         {:ok, price_range} <- text(result, "price_range"),
         {:ok, distance} <- distance(result),
         {:ok, categories} <- strings(result, "categories", @max_categories),
         {:ok, cuisines} <- strings(result, "serves_cuisine", @max_cuisines),
         {:ok, media} <- media(result, source_url) do
      {:ok,
       present_fields(
         description: description,
         location: location,
         address: address,
         opening_hours: opening_hours,
         contact: contact,
         rating: rating,
         price_range: price_range,
         distance: distance,
         categories: categories,
         cuisines: cuisines,
         media: media
       )}
    end
  end

  defp coordinates(result) do
    case Map.get(result, "coordinates") do
      nil -> {:ok, nil}
      [lat, lng] when is_number(lat) and is_number(lng) -> {:ok, %{latitude: lat, longitude: lng}}
      _other -> {:error, parser_changed("coordinates", "[latitude, longitude] numbers")}
    end
  end

  defp address(result) do
    case Map.get(result, "postal_address") do
      nil -> {:ok, nil}
      %{} = postal_address -> text(postal_address, "displayAddress")
      _other -> {:error, parser_changed("postal_address", "an object")}
    end
  end

  defp contact(result) do
    case Map.get(result, "contact") do
      nil -> {:ok, nil}
      %{} = contact -> contact_fields(contact)
      _other -> {:error, parser_changed("contact", "an object")}
    end
  end

  defp contact_fields(contact) do
    with {:ok, telephone} <- text(contact, "telephone"),
         {:ok, email} <- text(contact, "email") do
      {:ok, present_fields(telephone: telephone, email: email)}
    end
  end

  defp rating(result) do
    case Map.get(result, "rating") do
      nil -> {:ok, nil}
      %{} = rating -> rating_fields(rating)
      _other -> {:error, parser_changed("rating", "an object")}
    end
  end

  defp rating_fields(rating) do
    with {:ok, value} <- number(rating, "ratingValue"),
         {:ok, best} <- number(rating, "bestRating"),
         {:ok, count} <- number(rating, "reviewCount") do
      {:ok, present_fields(value: value, best: best, count: count)}
    end
  end

  defp distance(result) do
    case Map.get(result, "distance") do
      nil -> {:ok, nil}
      %{} = distance -> distance_fields(distance)
      _other -> {:error, parser_changed("distance", "an object")}
    end
  end

  defp distance_fields(distance) do
    with {:ok, value} <- number(distance, "value"),
         {:ok, units} <- text(distance, "units") do
      {:ok, present_fields(value: value, units: units)}
    end
  end

  defp opening_hours(result) do
    case Map.get(result, "opening_hours") do
      nil -> {:ok, nil}
      %{} = hours -> hours_fields(hours)
      _other -> {:error, parser_changed("opening_hours", "an object")}
    end
  end

  defp hours_fields(hours) do
    with {:ok, current_day} <- current_day(Map.get(hours, "current_day")),
         {:ok, days} <- days(Map.get(hours, "days")) do
      {:ok, present_fields(current_day: current_day, days: days)}
    end
  end

  defp current_day(nil), do: {:ok, nil}

  defp current_day(entries) when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      {:ok, blank_to_nil(day_string(entries))}
    else
      {:error, parser_changed("opening_hours.current_day", "an array of objects")}
    end
  end

  defp current_day(_entries),
    do: {:error, parser_changed("opening_hours.current_day", "an array")}

  defp days(nil), do: {:ok, []}

  defp days(entries) when is_list(entries) do
    taken = Enum.take(entries, @max_days)

    if Enum.all?(taken, &day_shaped?/1) do
      {:ok, taken |> Enum.map(&day_string/1) |> Enum.reject(&(&1 == ""))}
    else
      {:error, parser_changed("opening_hours.days", "an array of day arrays")}
    end
  end

  defp days(_entries), do: {:error, parser_changed("opening_hours.days", "an array")}

  defp day_shaped?(entry), do: is_list(entry) and Enum.all?(entry, &is_map/1)

  defp day_string(entries) do
    ranges =
      entries
      |> Enum.take(@max_day_ranges)
      |> Enum.map(&day_range/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    label_ranges(day_label(entries), ranges)
  end

  defp day_label([%{"full_name" => name} | _rest]) when is_binary(name),
    do: SnippetSanitizer.sanitize(name)

  defp day_label([%{"abbr_name" => name} | _rest]) when is_binary(name),
    do: SnippetSanitizer.sanitize(name)

  defp day_label(_entries), do: ""

  defp day_range(%{"opens" => opens, "closes" => closes})
       when is_binary(opens) and is_binary(closes) do
    SnippetSanitizer.sanitize(opens) <> "-" <> SnippetSanitizer.sanitize(closes)
  end

  defp day_range(_entry), do: ""

  defp label_ranges(_label, ""), do: ""
  defp label_ranges("", ranges), do: ranges
  defp label_ranges(label, ranges), do: label <> " " <> ranges

  # One thumbnail, never fetched. `src` only: `original` is a second URL for the
  # same picture, and choosing it when `src` is unusable would be a fallback.
  # Without a provider page there is no source to attribute the image to, so the
  # media entry is dropped rather than pointed at the business's own site.
  defp media(_result, nil), do: {:ok, []}

  defp media(result, source_url) do
    case Map.get(result, "thumbnail") do
      nil -> {:ok, []}
      %{} = thumbnail -> thumbnail_media(thumbnail, source_url)
      _other -> {:error, parser_changed("thumbnail", "an object")}
    end
  end

  defp thumbnail_media(thumbnail, source_url) do
    case https_url(thumbnail, "src") do
      {:ok, nil} -> {:ok, []}
      {:ok, url} -> {:ok, [%{kind: "thumbnail", url: url, source_url: source_url}]}
      {:error, _reason} -> {:error, parser_changed("thumbnail.src", "a string")}
    end
  end

  # -- field readers ---------------------------------------------------------

  defp text(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(SnippetSanitizer.sanitize(value))}
      _other -> {:error, parser_changed(key, "a string")}
    end
  end

  defp number(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_number(value) -> {:ok, value}
      _other -> {:error, parser_changed(key, "a number")}
    end
  end

  defp strings(result, key, limit) do
    case Map.get(result, key) do
      nil -> {:ok, []}
      values when is_list(values) -> take_strings(values, key, limit)
      _other -> {:error, parser_changed(key, "an array of strings")}
    end
  end

  defp take_strings(values, key, limit) do
    taken = Enum.take(values, limit)

    if Enum.all?(taken, &is_binary/1) do
      {:ok, taken |> Enum.map(&SnippetSanitizer.sanitize/1) |> Enum.reject(&(&1 == ""))}
    else
      {:error, parser_changed(key, "an array of strings")}
    end
  end

  # A URL is emitted exactly as returned (§9.5) or not at all: HTTP, a missing
  # host, or an unparseable value is absent, never rewritten into HTTPS.
  defp https_url(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, valid_https(String.trim(value))}
      _other -> {:error, parser_changed(key, "a string")}
    end
  end

  defp valid_https(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> url
      _other -> nil
    end
  end

  defp present_fields(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp parser_changed(field, expected), do: "parser_changed: #{field} must be #{expected}"
end
