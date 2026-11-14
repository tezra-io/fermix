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
    around the stop's day. The first result whose name holds the words, or
    whose name the words begin with ("Prado, Lisbon" takes "Prado"), as whole
    words without case or accents, is placed; a name that is only later words
    of them ("Dinner at Prado") is not. Results are read in order and one with
    no usable location is skipped (C6). Failing
    that, the first located result is offered, never applied: the caller names
    it with its link, which a later call gives in the link form.

  ## Around the day (D10, D11)

  A lookup's anchor, in order (`anchor/2`): the day's `near`; else the trip's
  `near`; else the day's placed stops, their middle searched at least 2 km
  about it and as far as the farthest of them, at most the search's 50 km;
  else the nearest day that has placed stops, the earlier on a tie (C5), the
  same way. A near wins over every placed stop (D11): a city's day spans
  districts, and searching around the first stop placed put a landmark 7 km
  off at a business of its name beside that stop. A `near` is a place's name
  the place search finds by its own named anchor and searches the region of
  (`{:location, near}`, as `place_search`'s `location`), so nothing here
  finds a place by name, and no result's distance is read. The near is the
  model's word for a town or city; nothing bounds its size, so a country given
  as one searches the whole country, and a near the search finds somewhere
  else misplaces as any wrong near would. "Placed" counts the stops this call
  places: lookups run in waves, the first alone and then four at a time (C4,
  C11), and with no near each wave searches around what the ones before it
  placed.

  With no anchor a lookup never places, whatever the name rule says: a generic
  name searched with nowhere to search lands wherever the search is. Its first
  located result is offered, as a result by another name is, with why
  (`:no_anchor`). A `near` the place search finds no place by
  (`invalid_location`) is no anchor either: the lookup searches its words
  alone once more and offers the same way (`{:unknown_near, near}`), and that
  near is not asked again in the call.

  ## Bounds

  At most 40 lookups a call, a place repeated on one day looked up once; a
  call that would need one more is refused before any lookup runs (C30). A
  link is no lookup. One rate limited answer stops every lookup not started
  (C11), and so does one saying the Brave Search API key's plan does not
  include place search, and, on a Mac of the home (M89 D13), one that cannot
  heal within the call: no such Mac online (`computer_away`), Apple Maps
  switched off there (`computer_off`), that Mac refusing it otherwise
  (`computer_refused`) or not answering in time (`computer_timed_out`); a
  busy Mac (`computer_busy`) stops nothing. The
  call's lookups have 45 s, and one not started or still running when they
  pass is stopped (C31). The place search in force is told how each may send
  (`PlaceSearch.lookup/3`): the time the call has left, and the call's one
  stop. On Brave a call's lookups queue for the home's one door to it: one
  whose turn would come after the 45 s sends nothing, and once an answer
  stops the call, the lookups queued behind it in its wave send nothing
  either. On a Mac of the home each lookup is one invocation bounded well
  inside the time left (`PlaceSearch.Computer`), so a Mac asleep with its
  session up spends one bound, not the call. A lookup that sent nothing is not counted in
  `lookups`; the result says what stopped the call (`stop_reason`) and the
  place search's own code for it (`stop_code`). With no place search set up
  here, every stop by words is left unplaced and the outcome says why (C28).
  A lookup emits no tool event of its own (`PlaceSearch.lookup/3`, C12).

  ## What comes back

  Per request, in order, `{ref, outcome}`: `{:placed, record}`,
  `{:offered, record}`, `{:offered, record, unanchored}` or `{:none, why}`, a
  record being the place search's own; and the records to add to the
  conversation (`ReplyBlocks.put_places/3`): the placed or offered record of
  each lookup, one each (C3); and `placed_by`, by request ref, the owner's
  words for what searched each stop a lookup placed ("Apple Maps on studio
  Mac"), never a stop its link placed. `heading/1` and `offered_heading/1` are the answer's words for each
  `why`, `link/1` the link a record is offered by.
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
  # What stops the lookups of a call that have not started.
  @stops [
    :rate_limited,
    :plan_excludes_place_search,
    :computer_away,
    :computer_off,
    :computer_refused,
    :computer_timed_out,
    :deadline
  ]

  @typedoc "A stop's place to resolve, the day it lands in, and the caller's ref for it."
  @type request :: %{
          required(:ref) => term(),
          required(:place) => String.t(),
          required(:day) => pos_integer()
        }

  @typedoc "The trip's placed stops' locations, by day position."
  @type placed :: %{optional(pos_integer()) => [Geo.point()]}

  @typedoc """
  Where a call's lookups search (D10): the trip's placed stops by day, each
  day's own `near` by its position, and the trip's `near`.
  """
  @type anchors :: %{
          required(:placed) => placed(),
          required(:day_near) => %{optional(pos_integer()) => String.t()},
          required(:trip_near) => String.t() | nil
        }

  @typedoc "Where one lookup searches: around a point, or near a place by its name."
  @type anchor :: {:coordinates, float(), float(), pos_integer()} | {:location, String.t()}

  @typedoc "Why a lookup had no anchor: none at all, or a near the place search finds no place by."
  @type unanchored :: :no_anchor | {:unknown_near, String.t()}

  @typedoc """
  One search of the place search in force (`PlaceSearch.lookup/3`), told how
  it may send; a context's `:place_lookup` stand-in takes the request alone.
  """
  @type search :: (Backend.request(), keyword() -> answer()) | (Backend.request() -> answer())

  @typedoc "What stopped a call's lookups, and so the ones after it."
  @type stop_reason ::
          :rate_limited
          | :plan_excludes_place_search
          | :computer_away
          | :computer_off
          | :computer_refused
          | :computer_timed_out
          | :deadline

  @typedoc "What one search answers."
  @type answer ::
          {:ok, [Backend.place()], Backend.trace_metadata()}
          | {:error, String.t(), Backend.trace_metadata()}

  @typedoc "Why a stop was not placed."
  @type why ::
          :not_found
          | :no_location
          | :rate_limited
          | :plan_excludes_place_search
          | :computer_away
          | :computer_off
          | :computer_refused
          | :computer_timed_out
          | :computer_busy
          | :deadline
          | {:failed, String.t()}
          | {:no_backend, String.t()}
          | {:unknown_near, String.t()}

  @type outcome ::
          {:placed, Backend.place()}
          | {:offered, Backend.place()}
          | {:offered, Backend.place(), unanchored()}
          | {:none, why()}

  @type result :: %{
          outcomes: [{term(), outcome()}],
          records: [Backend.place()],
          lookups: non_neg_integer(),
          stop_reason: stop_reason() | nil,
          stop_code: String.t() | nil,
          placed_by: %{optional(term()) => String.t()}
        }

  @doc "The most lookups one call runs."
  @spec max_lookups() :: pos_integer()
  def max_lookups, do: @max_lookups

  @doc "How long one call's lookups may take, in milliseconds."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc """
  The place search a call's lookups run, for a tool `context`: the backend
  in force, resolved once for the whole call (`backend/2`), told how each
  may send, or why no place search is set up here. A context's
  `:place_lookup` (a one-argument function) stands in for it, and any other
  `:place_lookup` raises.
  """
  @spec backend(map()) :: {:ok, search()} | {:error, String.t()}
  def backend(%{place_lookup: search}) when is_function(search, 1), do: {:ok, search}

  def backend(%{place_lookup: other}) do
    raise ArgumentError,
          "a context's :place_lookup takes the request alone (one argument), got: " <>
            inspect(other)
  end

  def backend(context) when is_map(context), do: backend(context, PlaceSearch.resolution(context))

  @doc """
  `backend/1` on `resolution`, the call's backend as it was resolved once
  (`PlaceSearch.resolution/1`): every lookup of the call searches it, so one
  call never splits between backends (`PlaceSearch.searcher/2`).
  """
  @spec backend(map(), Backend.resolution()) :: {:ok, search()} | {:error, String.t()}
  def backend(context, resolution) when is_map(context) and is_map(resolution),
    do: PlaceSearch.searcher(context, resolution)

  @doc """
  Resolves `requests` against the call's `anchors` (moduledoc). `opts`:
  `:backend` (`backend/1`'s answer) and `:conversation_key`, required;
  `:reply_blocks`, the holder links are read from (the application's by
  default); `:now_ms` and `:deadline_ms`, the clock and the call's deadline,
  for a test.
  """
  @spec resolve([request()], anchors(), keyword()) ::
          {:ok, result()} | {:error, :too_many_lookups | {:unknown_place_link, term()}}
  def resolve(requests, %{placed: placed, day_near: day_near} = anchors, opts)
      when is_list(requests) and is_map(placed) and is_map(day_near) and
             is_map_key(anchors, :trip_near) and is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    key = Keyword.fetch!(opts, :conversation_key)
    indexed = requests |> Enum.map(&checked/1) |> Enum.with_index()
    {links, words} = Enum.split_with(indexed, fn {request, _index} -> link?(request.place) end)
    lookups = words |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(&lookup_key/1)

    with :ok <- within_bound(lookups),
         {:ok, linked} <- resolve_links(links, Keyword.get(opts, :reply_blocks, ReplyBlocks), key) do
      state = run(lookups, add_linked(anchors, links, linked), backend, opts)
      {:ok, assemble(indexed, linked, state)}
    end
  end

  @doc """
  Whether a result's `name` is the stop's `words` (C6): the name holds the
  words as a whole-word run, or the words begin with the name's words,
  compared after accents are stripped, case folded and punctuation read as a
  space.
  """
  @spec words_match?(String.t(), String.t()) :: boolean()
  def words_match?(words, name) when is_binary(words) and is_binary(name) do
    said = fold(words)
    named = fold(name)
    said != [] and named != [] and (run?(named, said) or Enum.take(said, length(named)) == named)
  end

  @doc """
  Where a lookup for `day` searches, given the call's `anchors` (D10, D11):
  near the day's `near`, else near the trip's `near`, else around the day's
  placed stops, else around the nearest day with placed stops; nil for
  nowhere.
  """
  @spec anchor(anchors(), pos_integer()) :: anchor() | nil
  def anchor(%{placed: placed, day_near: day_near, trip_near: trip_near}, day)
      when is_map(placed) and is_map(day_near) and is_integer(day) and day > 0 do
    case Map.get(day_near, day, trip_near) do
      near when is_binary(near) -> {:location, near}
      nil -> placed_anchor(placed, day)
    end
  end

  defp placed_anchor(placed, day) do
    case Map.get(placed, day, []) do
      [_ | _] = own -> around(own)
      [] -> nearest(placed, day)
    end
  end

  defp nearest(placed, day) do
    nearest =
      placed
      |> Enum.reject(fn {_day, points} -> points == [] end)
      |> Enum.min_by(fn {near, _points} -> {abs(near - day), near} end, fn -> nil end)

    case nearest do
      {_day, points} -> around(points)
      nil -> nil
    end
  end

  @doc "The answer's words for why stops were not placed, before the stops it names."
  @spec heading(why()) :: String.t()
  def heading(:not_found), do: "No place found"
  def heading(:no_location), do: "Not placed, the search gave that place no location"
  def heading(:rate_limited), do: "Not looked up, the place search is rate limited"

  def heading(:plan_excludes_place_search) do
    "Not looked up, the Brave Search API key's plan does not include place search; add " <>
      "place search to that key's plan, or give each stop its link from the owner or a web " <>
      "search, never a made-up one"
  end

  def heading(:computer_away) do
    "Not looked up, no Mac that looks places up in Apple Maps is online, so these stops are " <>
      "saved without a place; ask again once it is online"
  end

  def heading(:computer_off) do
    "Not looked up, Apple Maps is switched off on the Mac that looks places up, so these " <>
      "stops are saved without a place; only someone at that Mac can switch it on"
  end

  def heading(:computer_refused) do
    "Not looked up, the Mac that looks places up in Apple Maps refused the search, so these " <>
      "stops are saved without a place"
  end

  def heading(:computer_timed_out) do
    "Not looked up, the Mac that looks places up in Apple Maps did not answer in time, so " <>
      "these stops are saved without a place; ask again in a moment"
  end

  def heading(:computer_busy) do
    "Not looked up, the Mac that looks places up in Apple Maps was busy; ask again in a moment"
  end

  def heading(:deadline),
    do: "Not looked up, the call's #{div(@deadline_ms, 1_000)} s for place lookups ran out"

  def heading({:failed, reason}) when is_binary(reason),
    do: "Not looked up, the place search failed (#{reason})"

  def heading({:no_backend, reason}) when is_binary(reason),
    do: "Not looked up, no place search is set up here (#{reason})"

  def heading({:unknown_near, near}) when is_binary(near) do
    "No place found, and the place search found no place #{Jason.encode!(near)} to search " <>
      "near; give its day a near it can find (a town and its country)"
  end

  @doc """
  The answer's words before the stops a lookup with no anchor offered a
  result for (D10): that the result is only the first anywhere, and to give
  the stop's day a `near`.
  """
  @spec offered_heading(unanchored()) :: String.t()
  def offered_heading(:no_anchor) do
    "Not placed, this trip has no place to search near, so each is only the first result " <>
      "anywhere: give its day a near (a town and its country) and the place again, or its " <>
      "link if that is the place meant"
  end

  def offered_heading({:unknown_near, near}) when is_binary(near) do
    "Not placed, the place search found no place #{Jason.encode!(near)} to search near, so " <>
      "each is only the first result anywhere: give its day a near it can find (a town and " <>
      "its country) and the place again, or its link if that is the place meant"
  end

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
  defp add_linked(anchors, links, linked) do
    Enum.reduce(links, anchors, fn {request, index}, acc ->
      case Map.fetch!(linked, index) do
        {:placed, place} -> add_point(acc, request.day, place)
        {:none, :no_location} -> acc
      end
    end)
  end

  defp add_point(%{placed: placed} = anchors, day, %{location: location}) do
    point = %{latitude: location.latitude, longitude: location.longitude}
    %{anchors | placed: Map.update(placed, day, [point], &(&1 ++ [point]))}
  end

  defp assemble(indexed, linked, state) do
    outcomes =
      Enum.map(indexed, fn {request, index} ->
        {request.ref,
         Map.get_lazy(linked, index, fn -> Map.fetch!(state.found, lookup_key(request)) end)}
      end)

    %{
      outcomes: outcomes,
      records: Enum.reverse(state.records),
      lookups: state.sent,
      stop_reason: state.stopped,
      stop_code: state.stop_code,
      placed_by: placed_by(indexed, linked, state.searched)
    }
  end

  # What searched each stop a lookup placed, by its request's ref.
  defp placed_by(indexed, linked, searched) do
    for {request, index} <- indexed,
        not Map.has_key?(linked, index),
        {:ok, words} <- [Map.fetch(searched, lookup_key(request))],
        into: %{},
        do: {request.ref, words}
  end

  # -- the lookups ---------------------------------------------------------------

  defp run(lookups, anchors, {:error, reason}, _opts) when is_binary(reason),
    do: stop_all(lookups, initial(anchors), {:no_backend, reason})

  defp run(lookups, anchors, {:ok, search}, opts)
       when is_function(search, 1) or is_function(search, 2) do
    now_ms = Keyword.get(opts, :now_ms, &monotonic_ms/0)
    deadline = now_ms.() + Keyword.get(opts, :deadline_ms, @deadline_ms)
    {first, rest} = Enum.split(lookups, 1)
    waves = Enum.reject([first | Enum.chunk_every(rest, @wave)], &(&1 == []))
    remaining = fn -> deadline - now_ms.() end
    run_waves(waves, initial(anchors), {search, send_terms(remaining)}, remaining)
  end

  # How a lookup may send, asked as it sends: the call's time left, and the
  # call's one stop. The place search sets the stop when an answer stops the
  # call, before its turn ends, and reads it before sending (C11); the first
  # to set it wins. It lives as long as the call's lookups.
  defp send_terms(remaining) do
    cell = :atomics.new(1, signed: false)
    stopped = fn -> stop_reason(:atomics.get(cell, 1)) end

    stop = fn why ->
      # 0 is no stop yet; a later stop leaves the first standing.
      _first = :atomics.compare_exchange(cell, 1, 0, stop_index(why))
      :ok
    end

    fn -> [send_within_ms: max(remaining.(), 0), stopped: stopped, stop: stop] end
  end

  defp stop_index(:rate_limited), do: 1
  defp stop_index(:plan_excludes_place_search), do: 2
  defp stop_index(:computer_away), do: 3
  defp stop_index(:computer_off), do: 4
  defp stop_index(:computer_refused), do: 5
  defp stop_index(:computer_timed_out), do: 6

  defp stop_reason(0), do: nil
  defp stop_reason(1), do: :rate_limited
  defp stop_reason(2), do: :plan_excludes_place_search
  defp stop_reason(3), do: :computer_away
  defp stop_reason(4), do: :computer_off
  defp stop_reason(5), do: :computer_refused
  defp stop_reason(6), do: :computer_timed_out

  # `unknown` holds the nears the place search found no place by in this call,
  # `sent` the lookups that reached the place search, and `searched` what
  # searched each lookup that placed, by its key.
  defp initial(anchors) do
    %{
      anchors: anchors,
      unknown: MapSet.new(),
      found: %{},
      records: [],
      sent: 0,
      stopped: nil,
      stop_code: nil,
      searched: %{}
    }
  end

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
          |> run_wave(state, search, left)
          |> Enum.reduce(state, &settle/2)

        run_waves(rest, settled, search, remaining)

      _passed ->
        run_waves([wave | rest], first_stop(state, :deadline, nil), search, remaining)
    end
  end

  defp run_wave(wave, state, timed_search, timeout_ms) do
    wave
    |> Enum.map(&plan(&1, state))
    |> Task.async_stream(&searched(&1, timed_search),
      max_concurrency: @wave,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip_with(wave, &judged/2)
  end

  # The request a lookup sends, and how it is anchored: `:anchored`, `{:near,
  # near}` until the place search answers, `:no_anchor`, or a near this call
  # already found unknown, whose words are searched alone. A near's region
  # bounds its search, never ranks it: the Apple Maps helper geocodes the near
  # and searches its region as required (`regionPriority = .required`), so no
  # result outside it comes back, and the first that passes the name rule is
  # placed, with no distance read here.
  defp plan(%{place: words, day: day}, state) do
    base = %{query: String.trim(words), count: @count}

    case anchor(state.anchors, day) do
      {:coordinates, lat, lon, radius} ->
        {Map.merge(base, %{anchor: {:coordinates, lat, lon}, radius_meters: radius}), :anchored}

      {:location, near} ->
        if MapSet.member?(state.unknown, near),
          do: {base, {:unknown_near, near}},
          else: {Map.put(base, :anchor, {:location, near}), {:near, near}}

      nil ->
        {base, :no_anchor}
    end
  end

  # A near the place search finds no place by is no anchor: its words are
  # searched alone, once, and what they find is only offered.
  defp searched({request, {:near, near}}, timed_search) do
    case call(timed_search, request) do
      {:error, "invalid_location" <> _rest, _trace} ->
        {{:unknown_near, near}, call(timed_search, Map.delete(request, :anchor))}

      answer ->
        {:anchored, answer}
    end
  end

  defp searched({request, mode}, timed_search), do: {mode, call(timed_search, request)}

  # The place search in force is told how it may send, as it sends.
  defp call({search, terms}, request) when is_function(search, 2),
    do: search.(request, terms.())

  defp call({search, _terms}, request) when is_function(search, 1), do: search.(request)

  defp judged({:ok, {mode, answer}}, lookup),
    do: {lookup, outcome(answer, lookup.place, mode), mode, facts(answer)}

  # Stopped while it ran, it may have sent.
  defp judged({:exit, :timeout}, lookup),
    do: {lookup, {:none, :deadline}, nil, %{sent?: true, code: nil, searched_with: nil}}

  # Whether the answer's search reached the place search (one that says it
  # sent nothing, `attempt: 0`, did not), the place search's own code, and
  # what searched, in the owner's words.
  defp facts({_ok_or_error, _answer, trace}) when is_map(trace),
    do: %{
      sent?: Map.get(trace, :attempt) != 0,
      code: Map.get(trace, :provider_code),
      searched_with: Map.get(trace, :searched_with)
    }

  defp outcome({:ok, places, _trace}, words, mode) when is_list(places),
    do: places |> Enum.filter(&located?/1) |> choose(words, mode)

  defp outcome({:error, reason, _trace}, _words, _mode) when is_binary(reason),
    do: {:none, failure(reason)}

  defp failure("rate_limited" <> _rest), do: :rate_limited
  defp failure("plan_excludes_place_search:" <> _rest), do: :plan_excludes_place_search
  defp failure("computer_away:" <> _rest), do: :computer_away
  defp failure("computer_off:" <> _rest), do: :computer_off
  defp failure("computer_refused:" <> _rest), do: :computer_refused
  defp failure("computer_timed_out:" <> _rest), do: :computer_timed_out
  defp failure("computer_busy:" <> _rest), do: :computer_busy
  defp failure("deadline:" <> _rest), do: :deadline
  defp failure(reason), do: {:failed, reason}

  defp choose(located, words, :anchored) do
    case Enum.find(located, &words_match?(words, &1.name)) do
      nil -> offer(located)
      place -> {:placed, place}
    end
  end

  # With no anchor nothing is placed (D10): the first located result is
  # offered, with why.
  defp choose([first | _rest], _words, why), do: {:offered, first, why}
  defp choose([], _words, :no_anchor), do: {:none, :not_found}
  defp choose([], _words, {:unknown_near, _near} = why), do: {:none, why}

  defp offer([]), do: {:none, :not_found}
  defp offer([first | _rest]), do: {:offered, first}

  # A lookup's outcome is kept, a placed stop anchors the waves after it, a
  # near found unknown is not asked again, and a rate limited answer, a key
  # whose plan has no place search, no Mac online to search on or the
  # deadline stops the rest.
  defp settle({lookup, outcome, mode, facts}, state) do
    found = Map.put(state.found, lookup_key(lookup), outcome)

    state = %{
      state
      | found: found,
        unknown: learned(state.unknown, mode),
        sent: state.sent + if(facts.sent?, do: 1, else: 0)
    }

    case outcome do
      {:placed, place} ->
        %{
          state
          | anchors: add_point(state.anchors, lookup.day, place),
            records: [place | state.records],
            searched: searched(state.searched, lookup, facts.searched_with)
        }

      {:offered, place} ->
        %{state | records: [place | state.records]}

      {:offered, place, _why} ->
        %{state | records: [place | state.records]}

      {:none, why} when why in @stops ->
        first_stop(state, why, facts.code)

      {:none, _why} ->
        state
    end
  end

  # The first stop stands, with the place search's code for it. Outcomes
  # settle in request order, so a lookup the stop left unsent (no code) may
  # come before the one whose answer stopped the call: that one's code fills in.
  defp first_stop(%{stopped: nil} = state, why, code),
    do: %{state | stopped: why, stop_code: code}

  defp first_stop(%{stopped: why, stop_code: nil} = state, why, code),
    do: %{state | stop_code: code}

  defp first_stop(state, _why, _code), do: state

  defp searched(searched, _lookup, nil), do: searched
  defp searched(searched, lookup, words), do: Map.put(searched, lookup_key(lookup), words)

  defp learned(unknown, {:unknown_near, near}), do: MapSet.put(unknown, near)
  defp learned(unknown, _mode), do: unknown

  defp stop_all(lookups, state, why) do
    found = Enum.reduce(lookups, state.found, &Map.put(&2, lookup_key(&1), {:none, why}))
    %{state | found: found}
  end

  # -- pure helpers -------------------------------------------------------------

  defp around(points) do
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
