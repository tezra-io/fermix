defmodule FermixCore.Computers.Capabilities.Places do
  @moduledoc """
  `places` (M89 D13 D, M97 §6.4): looking places up in Apple Maps on a Mac of
  the home, for its server's place search (`Tools.PlaceSearch.Computer`). One
  op, `search`, which only reads: it runs this computer's own Apple Maps
  helper (`PlaceSearch.AppleMaps.raw_search/2`, the search a Mac's own place
  search makes) and answers what the helper printed, at most #{32} places
  (`{"places": [...]}`). The server makes the record of them with the same
  code a Mac's own search does (`places/2`, `AppleMaps.places/2`), so a place
  from a Mac passes the same checks: an HTTPS site only, sanitized text,
  Apple's page derived from its identifier, one with no page dropped, one
  with no name dropped.

  Its args (`validate/2`, built by `args/1` from a place search's request):
  `query`, 1 to #{400} characters; at most one anchor, `near` (a place's
  name, 1 to #{200} characters) or `latitude` and `longitude`, with
  `radius_meters` (1 to #{50_000}) beside them only; `count` (1 to #{10}) and
  `units` (`metric` or `imperial`), each optional; no other key.

  Its `places` offer gates it (`Computers.Offers.Places`): its own switch at
  this computer, under the master switch and the review
  (`Computers.Switches.on?/2`). It runs
  only where this build carries the Apple Maps helper (`admit/3`, the fact
  the offer rests on), and the helper's bound sits inside the deadline the
  Mac was given (`helper_timeout_ms/1`: #{1_500} ms less, never past Apple
  Maps' own #{15} s), so a slow Apple Maps answers as Apple Maps' own
  `network`, never as this Mac's deadline. Its target in the journal is "Apple Maps", never the
  query. A search that fails is `failed` with Apple Maps' own tagged reason
  (`invalid_location`, `rate_limited`, `network`, `provider_error`,
  `parser_changed`, `response_too_large`), which the server reads as it
  would its own.

  A capability's code reads this computer's facts from the context it is
  handed: `:host` (`BootProfile.host/0`'s shape) and `:apple_maps` (the
  helper's options, `AppleMaps.search/2`'s) only where a test names them.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.BootProfile
  alias FermixCore.Computers.Offers.Places, as: PlacesOffer
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixCore.Tools.PlaceSearch.Backend

  @max_query_chars 400
  @max_near_chars 200
  @max_radius_meters 50_000
  @max_count 10
  @search_ms 15_000
  @result_bytes 64 * 1_024
  # What answering takes beside the search, inside the request's deadline.
  @answer_margin_ms 1_500
  @max_raw 32
  @keys ~w(query near latitude longitude radius_meters count units)
  @point ["latitude", "longitude", "radius_meters"]
  @units %{"metric" => :metric, "imperial" => :imperial}

  @impl true
  def id, do: :places

  @impl true
  def offer, do: :places

  @impl true
  def ops, do: ["search"]

  @impl true
  def label, do: PlacesOffer.label()

  @impl true
  def op_label("search"), do: "look up places"

  @impl true
  def effect?("search"), do: false

  @impl true
  def long_lived?("search"), do: false

  @impl true
  def bounds("search"), do: %{result_bytes: @result_bytes, part_bytes: 0}

  @impl true
  def target("search", _args), do: "Apple Maps"

  @impl true
  def validate("search", args) when is_map(args) do
    with :ok <- known_keys(args),
         :ok <- query(args["query"]),
         :ok <- anchor(args),
         :ok <- count(Map.get(args, "count")) do
      units(Map.get(args, "units"))
    end
  end

  @impl true
  def admit("search", _args, context) when is_map(context) do
    host = Map.get_lazy(context, :host, &BootProfile.host/0)

    if Backend.carries_helper?(host),
      do: :ok,
      else: {:refused, :unavailable, PlacesOffer.needs_mac_app_sentence()}
  end

  @impl true
  def run("search", args, nil, %{deadline_ms: deadline} = context) do
    opts =
      Keyword.put(Map.get(context, :apple_maps, []), :timeout_ms, helper_timeout_ms(deadline))

    case AppleMaps.raw_search(request(args), opts) do
      {:ok, raw} -> {:ok, %{"places" => Enum.take(raw, @max_raw)}, nil}
      {:error, reason} -> {:failed, reason}
    end
  end

  def run("search", _args, _part, _context), do: {:failed, "Looking places up takes no file."}

  @doc """
  The helper's bound for a request given `deadline_ms` on this Mac: the
  deadline less what answering takes, at most Apple Maps' own #{15} s and at
  least 1 ms.
  """
  @spec helper_timeout_ms(pos_integer()) :: pos_integer()
  def helper_timeout_ms(deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0,
    do: deadline_ms |> Kernel.-(@answer_margin_ms) |> min(@search_ms) |> max(1)

  @doc """
  The records a Mac's answer carries, for `request`, the place search's own
  (`args/1` made the Mac's from it): the helper's raw places normalized by
  `AppleMaps.places/2`, as a search on this server's own helper would be. An
  answer that is no list of at most #{@max_raw} is `parser_changed`.
  """
  @spec places(map(), Backend.request()) :: {:ok, [Backend.place()]} | {:error, String.t()}
  def places(%{"places" => raw}, request) when is_list(raw) and length(raw) <= @max_raw,
    do: AppleMaps.places(raw, request)

  def places(_result, _request),
    do: {:error, "parser_changed: the computer's answer must carry at most #{@max_raw} places"}

  @doc """
  The args of the `search` op for a place search's request
  (`PlaceSearch.Backend.request()`): its query, its anchor, radius, count and
  units. Brave's `country` and `language` are no Apple Maps option and do not
  travel.
  """
  @spec args(Backend.request()) :: map()
  def args(%{query: query} = request) when is_binary(query) do
    %{"query" => query}
    |> Map.merge(anchor_args(Map.get(request, :anchor)))
    |> put_some("radius_meters", Map.get(request, :radius_meters))
    |> put_some("count", Map.get(request, :count))
    |> put_some("units", request |> Map.get(:units) |> units_word())
  end

  defp anchor_args({:location, near}) when is_binary(near), do: %{"near" => near}

  defp anchor_args({:coordinates, latitude, longitude}),
    do: %{"latitude" => latitude, "longitude" => longitude}

  defp anchor_args(nil), do: %{}

  defp units_word(nil), do: nil
  defp units_word(units) when units in [:metric, :imperial], do: Atom.to_string(units)

  @doc "The Apple Maps request the args of `search` stand for (`args/1`'s inverse)."
  @spec request(map()) :: Backend.request()
  def request(%{"query" => query} = args) when is_binary(query) do
    %{query: String.trim(query)}
    |> put_some(:anchor, request_anchor(args))
    |> put_some(:radius_meters, Map.get(args, "radius_meters"))
    |> put_some(:count, Map.get(args, "count"))
    |> put_some(:units, Map.get(@units, Map.get(args, "units")))
  end

  defp request_anchor(%{"near" => near}), do: {:location, String.trim(near)}

  defp request_anchor(%{"latitude" => latitude, "longitude" => longitude}),
    do: {:coordinates, latitude, longitude}

  defp request_anchor(_args), do: nil

  # -- the args ------------------------------------------------------------------

  defp known_keys(args) do
    case Map.keys(args) -- @keys do
      [] -> :ok
      _unknown -> {:error, "Looking places up takes #{Enum.join(@keys, ", ")}, and no other key."}
    end
  end

  defp query(query) when is_binary(query) do
    length = query |> String.trim() |> String.length()

    if length in 1..@max_query_chars,
      do: :ok,
      else: {:error, "A place search's query is 1 to #{@max_query_chars} characters."}
  end

  defp query(_query), do: {:error, "A place search needs its query."}

  defp anchor(args) do
    case {Map.fetch(args, "near"), Enum.any?(@point, &Map.has_key?(args, &1))} do
      {{:ok, _near}, true} ->
        {:error, "A place search is near a place or around a point, not both."}

      {{:ok, near}, false} ->
        near(near)

      {:error, true} ->
        point(args)

      {:error, false} ->
        :ok
    end
  end

  defp near(near) do
    if is_binary(near) and String.length(String.trim(near)) in 1..@max_near_chars,
      do: :ok,
      else: {:error, "A place to search near is 1 to #{@max_near_chars} characters."}
  end

  defp point(%{"latitude" => latitude, "longitude" => longitude} = args)
       when is_number(latitude) and latitude >= -90 and latitude <= 90 and
              is_number(longitude) and longitude >= -180 and longitude <= 180,
       do: radius(Map.get(args, "radius_meters"))

  defp point(_args),
    do:
      {:error,
       "A place search's point is a latitude from -90 to 90 and a longitude from -180 to 180, " <>
         "with its radius beside them only."}

  defp radius(nil), do: :ok
  defp radius(meters) when is_integer(meters) and meters in 1..@max_radius_meters, do: :ok

  defp radius(_meters),
    do:
      {:error, "A place search's radius is a whole number of meters, 1 to #{@max_radius_meters}."}

  defp count(nil), do: :ok
  defp count(count) when is_integer(count) and count in 1..@max_count, do: :ok
  defp count(_count), do: {:error, "A place search finds 1 to #{@max_count} places."}

  defp units(nil), do: :ok
  defp units(units) when is_map_key(@units, units), do: :ok
  defp units(_units), do: {:error, "A place search's units are metric or imperial."}

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
