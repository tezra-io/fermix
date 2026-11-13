defmodule FermixCore.Trips.Lookup do
  @moduledoc """
  Where a stop's place comes from (M89 §04): the one function that resolves a
  `trip_edit` call's `place` fields before its transaction opens. It reads no
  trip and writes no op; `trip_edit` composes it with the store.

  A request is a stop's `place` with the day it lands in and a `ref` the
  caller reads its outcome back by (an op's position, or a stop's `[n]`). A
  `place` is one of two forms:

  - **A link**, `http(s)`: the `source_url` or `canonical_url` of a place a
    search in this conversation put in the last 30 minutes
    (`ReplyBlocks.place_by_url/3`, C2). The stop gets that record. A link no
    search returned refuses the whole call, `{:unknown_place_link, ref}`,
    before any lookup.
  - **Words**, the place's own name: one search of the place search in force
    around the stop's day. The first result whose name is in the words or
    holds them, as whole words without case or accents, is placed; results are
    read in order and one with no usable location is skipped (C6). Failing
    that, the first located result is offered, never applied: the caller names
    it with its link, which a later call gives in the link form.

  ## Around the day

  The middle of the day's placed stops, searched at least 2 km about it and as
  far as the farthest of them, at most the search's 50 km. A day with none
  takes the nearest day that has some, the earlier on a tie (C5), and a trip
  with none searches the words alone. "Placed" counts the stops this call
  places: lookups run in waves, the first alone and then four at a time (C4,
  C11), each wave around what the ones before it placed. Every placed stop is
  on a day, so the nearest day that has placed stops is the trip's nearest
  anchor: no anchor of the trip's whole is ever reached after it.

  ## Bounds

  At most 40 lookups a call, a place repeated on one day looked up once; a
  call that would need one more is refused before any lookup runs (C30). A
  link is no lookup. One rate limited answer stops every lookup not started
  (C11); the call's lookups have 45 s, and one not started or still running
  when they pass is stopped (C31). With no place search set up here, every
  stop by words is left unplaced and the outcome says why (C28). A lookup
  emits no tool event of its own (`PlaceSearch.lookup/2`, C12).

  ## What comes back

  Per request, in order, `{ref, outcome}`: `{:placed, record}`,
  `{:offered, record}` or `{:none, why}`, a record being the place search's
  own; and the records to add to the conversation (`ReplyBlocks.put_places/3`):
  the placed or offered record of each lookup, one each (C3). `heading/1` is
  the answer's words for each `why`, `link/1` the link a record is offered by.
  """

  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.PlaceSearch
  alias FermixCore.Tools.PlaceSearch.Backend
  alias FermixCore.Trips.Geo

  @max_lookups 40
  @wave 4
  @deadline_ms 45_000
  @count 5
  @min_radius_m 2_000
  @max_radius_m 50_000
  @link ~r{\Ahttps?://}i
  @mark ~r/\p{Mn}/u
  @not_word ~r/[^\p{L}\p{N}]+/u

  @typedoc "A stop's place to resolve, the day it lands in, and the caller's ref for it."
  @type request :: %{
          required(:ref) => term(),
          required(:place) => String.t(),
          required(:day) => pos_integer()
        }

  @typedoc "The trip's placed stops' locations, by day position."
  @type placed :: %{optional(pos_integer()) => [Geo.point()]}

  @typedoc "One search of the place search in force (`PlaceSearch.lookup/2`)."
  @type search ::
          (Backend.request() ->
             {:ok, [Backend.place()], Backend.trace_metadata()}
             | {:error, String.t(), Backend.trace_metadata()})

  @typedoc "Why a stop was not placed."
  @type why ::
          :not_found
          | :no_location
          | :rate_limited
          | :deadline
          | {:failed, String.t()}
          | {:no_backend, String.t()}

  @type outcome :: {:placed, Backend.place()} | {:offered, Backend.place()} | {:none, why()}

  @type result :: %{
          outcomes: [{term(), outcome()}],
          records: [Backend.place()],
          lookups: non_neg_integer()
        }

  @doc "The most lookups one call runs."
  @spec max_lookups() :: pos_integer()
  def max_lookups, do: @max_lookups

  @doc "How long one call's lookups may take, in milliseconds."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc """
  The place search a call's lookups run, for a tool `context`: the backend
  in force while it is ready, or why no place search is set up here. A
  context's `:place_lookup` (a one-argument function) stands in for it.
  """
  @spec backend(map()) :: {:ok, search()} | {:error, String.t()}
  def backend(%{place_lookup: search}) when is_function(search, 1), do: {:ok, search}

  def backend(context) when is_map(context) do
    case PlaceSearch.readiness(context) do
      :ok -> {:ok, &PlaceSearch.lookup(&1, context)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves `requests` against the trip's `placed` stops (moduledoc). `opts`:
  `:backend` (`backend/1`'s answer) and `:conversation_key`, required;
  `:reply_blocks`, the holder links are read from (the application's by
  default); `:now_ms` and `:deadline_ms`, the clock and the call's deadline,
  for a test.
  """
  @spec resolve([request()], placed(), keyword()) ::
          {:ok, result()} | {:error, :too_many_lookups | {:unknown_place_link, term()}}
  def resolve(requests, placed, opts)
      when is_list(requests) and is_map(placed) and is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    key = Keyword.fetch!(opts, :conversation_key)
    indexed = requests |> Enum.map(&checked/1) |> Enum.with_index()
    {links, words} = Enum.split_with(indexed, fn {request, _index} -> link?(request.place) end)
    lookups = words |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(&lookup_key/1)

    with :ok <- within_bound(lookups),
         {:ok, linked} <- resolve_links(links, Keyword.get(opts, :reply_blocks, ReplyBlocks), key) do
      state = run(lookups, add_linked(placed, links, linked), backend, opts)
      {:ok, assemble(indexed, linked, state)}
    end
  end

  @doc """
  Whether a result's `name` is the stop's `words` (C6): its words a whole-word
  run of them, or holding them as one, compared after accents are stripped,
  case folded and punctuation read as a space.
  """
  @spec words_match?(String.t(), String.t()) :: boolean()
  def words_match?(words, name) when is_binary(words) and is_binary(name) do
    said = fold(words)
    named = fold(name)
    said != [] and named != [] and (run?(said, named) or run?(named, said))
  end

  @doc """
  Where a lookup for `day` searches around, given the `placed` stops by day:
  `{:coordinates, latitude, longitude, radius_m}`, or nil for the words alone.
  """
  @spec anchor(placed(), pos_integer()) :: {:coordinates, float(), float(), pos_integer()} | nil
  def anchor(placed, day) when is_map(placed) and is_integer(day) and day > 0 do
    placed
    |> Enum.reject(fn {_day, points} -> points == [] end)
    |> Enum.min_by(fn {near, _points} -> {abs(near - day), near} end, fn -> nil end)
    |> around()
  end

  @doc "The answer's words for why stops were not placed, before the stops it names."
  @spec heading(why()) :: String.t()
  def heading(:not_found), do: "No place found"
  def heading(:no_location), do: "Not placed, the search gave that place no location"
  def heading(:rate_limited), do: "Not looked up, the place search is rate limited"

  def heading(:deadline),
    do: "Not looked up, the call's #{div(@deadline_ms, 1_000)} s for place lookups ran out"

  def heading({:failed, reason}) when is_binary(reason),
    do: "Not looked up, the place search failed (#{reason})"

  def heading({:no_backend, reason}) when is_binary(reason),
    do: "Not looked up, no place search is set up here (#{reason})"

  @doc """
  The link a place is offered by, which the link form takes back: the search's
  page for it, else the place's own site.
  """
  @spec link(Backend.place()) :: String.t()
  def link(%{source_url: url}) when is_binary(url) and url != "", do: url
  def link(%{canonical_url: url}) when is_binary(url) and url != "", do: url

  # -- the call ----------------------------------------------------------------

  defp checked(%{ref: _ref, place: place, day: day} = request)
       when is_binary(place) and place != "" and is_integer(day) and day > 0,
       do: request

  defp link?(place), do: Regex.match?(@link, String.trim(place))

  defp lookup_key(%{place: words, day: day}), do: {fold(words), day}

  defp within_bound(lookups) when length(lookups) <= @max_lookups, do: :ok
  defp within_bound(_lookups), do: {:error, :too_many_lookups}

  defp resolve_links(links, server, key) do
    Enum.reduce_while(links, {:ok, %{}}, fn {request, index}, {:ok, linked} ->
      case ReplyBlocks.place_by_url(server, key, String.trim(request.place)) do
        {:ok, place} -> {:cont, {:ok, Map.put(linked, index, linked_outcome(place))}}
        :error -> {:halt, {:error, {:unknown_place_link, request.ref}}}
      end
    end)
  end

  defp linked_outcome(place),
    do: if(located?(place), do: {:placed, place}, else: {:none, :no_location})

  # A stop placed by its link anchors the lookups as one placed before them.
  defp add_linked(placed, links, linked) do
    Enum.reduce(links, placed, fn {request, index}, acc ->
      case Map.fetch!(linked, index) do
        {:placed, place} -> add_point(acc, request.day, place)
        {:none, :no_location} -> acc
      end
    end)
  end

  defp add_point(placed, day, %{location: %{latitude: latitude, longitude: longitude}}) do
    point = %{latitude: latitude, longitude: longitude}
    Map.update(placed, day, [point], &(&1 ++ [point]))
  end

  defp assemble(indexed, linked, state) do
    outcomes =
      Enum.map(indexed, fn {request, index} ->
        {request.ref,
         Map.get_lazy(linked, index, fn -> Map.fetch!(state.found, lookup_key(request)) end)}
      end)

    %{outcomes: outcomes, records: Enum.reverse(state.records), lookups: state.started}
  end

  # -- the lookups ---------------------------------------------------------------

  defp run(lookups, placed, {:error, reason}, _opts) when is_binary(reason),
    do: stop_all(lookups, initial(placed), {:no_backend, reason})

  defp run(lookups, placed, {:ok, search}, opts) when is_function(search, 1) do
    now_ms = Keyword.get(opts, :now_ms, &monotonic_ms/0)
    deadline = now_ms.() + Keyword.get(opts, :deadline_ms, @deadline_ms)
    {first, rest} = Enum.split(lookups, 1)
    waves = Enum.reject([first | Enum.chunk_every(rest, @wave)], &(&1 == []))
    run_waves(waves, initial(placed), search, fn -> deadline - now_ms.() end)
  end

  defp initial(placed), do: %{placed: placed, found: %{}, records: [], started: 0, stopped: nil}

  # One wave at a time, at most eleven of them (one, then 39 four at a time):
  # the list shrinks each step.
  defp run_waves([], state, _search, _remaining), do: state

  defp run_waves(waves, %{stopped: why} = state, _search, _remaining) when why != nil,
    do: stop_all(List.flatten(waves), state, why)

  defp run_waves([wave | rest], state, search, remaining) do
    case remaining.() do
      left when left > 0 ->
        settled =
          wave
          |> run_wave(state.placed, search, left)
          |> Enum.reduce(%{state | started: state.started + length(wave)}, &settle/2)

        run_waves(rest, settled, search, remaining)

      _passed ->
        run_waves([wave | rest], %{state | stopped: :deadline}, search, remaining)
    end
  end

  defp run_wave(wave, placed, search, timeout_ms) do
    requests = Enum.map(wave, &request(&1, placed))

    requests
    |> Task.async_stream(search,
      max_concurrency: @wave,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip_with(wave, fn answer, lookup -> {lookup, outcome(answer, lookup.place)} end)
  end

  defp request(%{place: words, day: day}, placed) do
    base = %{query: String.trim(words), count: @count}

    case anchor(placed, day) do
      nil ->
        base

      {:coordinates, lat, lon, radius} ->
        Map.merge(base, %{anchor: {:coordinates, lat, lon}, radius_meters: radius})
    end
  end

  defp outcome({:ok, {:ok, places, _trace}}, words) when is_list(places),
    do: choose(places, words)

  defp outcome({:ok, {:error, reason, _trace}}, _words) when is_binary(reason),
    do: {:none, failure(reason)}

  defp outcome({:exit, :timeout}, _words), do: {:none, :deadline}

  defp failure("rate_limited" <> _rest), do: :rate_limited
  defp failure(reason), do: {:failed, reason}

  defp choose(places, words) do
    located = Enum.filter(places, &located?/1)

    case Enum.find(located, &words_match?(words, &1.name)) do
      nil -> offer(located)
      place -> {:placed, place}
    end
  end

  defp offer([]), do: {:none, :not_found}
  defp offer([first | _rest]), do: {:offered, first}

  # A lookup's outcome is kept, a placed stop anchors the waves after it, and
  # a rate limited answer or the deadline stops the rest.
  defp settle({lookup, outcome}, state) do
    state = %{state | found: Map.put(state.found, lookup_key(lookup), outcome)}

    case outcome do
      {:placed, place} ->
        %{
          state
          | placed: add_point(state.placed, lookup.day, place),
            records: [place | state.records]
        }

      {:offered, place} ->
        %{state | records: [place | state.records]}

      {:none, why} when why in [:rate_limited, :deadline] ->
        %{state | stopped: state.stopped || why}

      {:none, _why} ->
        state
    end
  end

  defp stop_all(lookups, state, why) do
    found = Enum.reduce(lookups, state.found, &Map.put(&2, lookup_key(&1), {:none, why}))
    %{state | found: found}
  end

  # -- pure helpers -------------------------------------------------------------

  defp around(nil), do: nil

  defp around({_day, points}) do
    middle = Geo.centroid(points)
    radius = middle |> Geo.spread_m(points) |> max(@min_radius_m) |> min(@max_radius_m)
    {:coordinates, middle.latitude, middle.longitude, radius}
  end

  defp located?(%{name: name, location: %{latitude: latitude, longitude: longitude}})
       when is_binary(name) and name != "" and is_number(latitude) and latitude >= -90 and
              latitude <= 90 and is_number(longitude) and longitude >= -180 and longitude <= 180,
       do: true

  defp located?(_place), do: false

  defp fold(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(@mark, "")
    |> String.downcase()
    |> String.split(@not_word, trim: true)
  end

  defp run?(words, run),
    do: words |> Enum.chunk_every(length(run), 1, :discard) |> Enum.member?(run)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
