defmodule FermixCore.Trips.Towns do
  @moduledoc """
  The town each trip day shows on the owner's map (M89): the town in force
  for the day, its own `near` if it has one, else the trip's, found once for
  the near's exact words by the place search in force, given the words alone
  (`PlaceSearch.Backend.geocode/2`). No client geocodes.

  **Which nears** (`asked/3`). A `trip_edit` call that takes the lookup path
  (`Trips.Registry`) asks every near in force on its trip, as the call leaves
  it, that the store has no row for: those the call sets first, then any left
  unresolved before; at most #{20} a call, the rest left for later and said
  so (`:capped`). The trip placer asks the same of every live trip on each
  run it makes, at most #{20} a run, the trip changed last first
  (`Trips.Placer.Run`): twenty nears that fail for good on every run hold
  that window, and the nears after them wait for a trip's next change.

  **Later** (`later?/1`). A town left for a reason that heals by waiting
  (`Trips.Waiting.heals?/1`), or past the cap, is looked up again on its own
  30 min on (`Trips.Placer.towns_unresolved/0`, and a run that stored a town
  looks again while some remain); any other is looked up again only when
  Fermix starts, a Mac that looks places up connects, or the trip next
  changes.

  **The geocodes** (`resolve/3`) run after the call's stop lookups, inside
  the time the call has left of Lookup's #{45} s, in waves of #{4}. When the
  lookups stopped the call (`stop_reason`), the towns send nothing. A town's
  own answer that cannot heal within the call (the stop kinds of
  `Trips.Lookup`, an older Mac refusing the op among them) stops the towns
  after it and is the towns' own `stop_reason`, never the call's: a stop's
  lookup is never held back by a town.

  **What each comes to**: `{:found, town}`; `{:none, :not_found}` when the
  search found no place by the words or a place that names no town (a
  country, or one with no region of its own); else `{:unresolved, why}`,
  which the store keeps nothing for, so a later call or placer run asks
  again. The store keeps `found` and `none` (`kept/1`), by the words, until
  those words are no longer in force on the trip.
  """

  alias FermixCore.Tools.PlaceSearch.Backend
  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Waiting

  @max_per_call 20
  @wave 4

  @typedoc """
  Why a near's town was not found: a lookup's `why`, a backend that names no
  town, or a near past the call's cap.
  """
  @type why :: Lookup.why() | :unsupported | :capped

  @typedoc "What one near came to."
  @type outcome :: {:found, Backend.town()} | {:none, :not_found} | {:unresolved, why()}

  @typedoc "What the store keeps of a near: its town, or that none was found."
  @type kept :: {:found, Backend.town()} | :none

  @typedoc """
  One geocode of the place search in force, told how it may send; a
  context's `:town_lookup` stand-in takes the words alone.
  """
  @type geocoder ::
          (String.t(), keyword() -> answer()) | (String.t() -> answer())

  @typedoc "What one geocode answers."
  @type answer ::
          {:ok, Backend.town(), Backend.trace_metadata()}
          | {:error, String.t(), Backend.trace_metadata()}

  @type result :: %{
          towns: [{String.t(), outcome()}],
          sent: [String.t()],
          stop_reason: Lookup.stop_reason() | nil,
          stop_code: String.t() | nil
        }

  @doc "The most nears one call, or one placer run, asks."
  @spec max_per_call() :: pos_integer()
  def max_per_call, do: @max_per_call

  @doc "The nears in force on `trip` with its live `rows`: the trip's, then each day's own, each once."
  @spec in_force(map(), [map()]) :: [String.t()]
  def in_force(%{near: trip_near}, rows) when is_list(rows) do
    days = for %{kind: :day, near: near, removed_at: nil} <- rows, do: near
    distinct([trip_near | days])
  end

  @doc """
  The nears a call asks (the moduledoc), and those past the cap: those in
  force as the call's `anchors` (`Lookup.anchors()`) leave them, less those
  `known` holds a row for, the ones the call set (`own`, `set_by/1`) first,
  at most #{@max_per_call}.
  """
  @spec asked(Lookup.anchors(), %{optional(String.t()) => kept()}, [String.t()]) ::
          {[String.t()], [String.t()]}
  def asked(%{trip_near: trip_near, day_near: day_near}, known, own)
      when is_map(day_near) and is_map(known) and is_list(own) do
    days = day_near |> Enum.sort() |> Enum.map(&elem(&1, 1))
    in_force = distinct([trip_near | days])
    unresolved = Enum.reject(in_force, &Map.has_key?(known, &1))
    {first, rest} = Enum.split_with(unresolved, &(&1 in own))
    Enum.split(first ++ rest, @max_per_call)
  end

  @doc "The nears the ops of `call` set: a create's and each day op's, each once."
  @spec set_by(map()) :: [String.t()]
  def set_by(%{ops: ops}) when is_list(ops) do
    ops
    |> Enum.filter(&(&1.op in [:create, :day]))
    |> Enum.map(&Map.get(&1, :near))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  Whether a later run can find a town `towns` left: one left for a reason
  that heals by waiting, or past the cap.
  """
  @spec later?([{String.t(), outcome()}]) :: boolean()
  def later?(towns) when is_list(towns),
    do: Enum.any?(towns, fn {_words, outcome} -> later_outcome?(outcome) end)

  defp later_outcome?({:unresolved, :capped}), do: true
  defp later_outcome?({:unresolved, why}), do: Waiting.heals?(why)
  defp later_outcome?(_answered), do: false

  @doc """
  The towns of `words` (the moduledoc). `opts`: `:deadline_ms`, the time the
  call has left, required; `:stopped`, what stopped the call's lookups, or
  nil; `:now_ms`, the clock, for a test.
  """
  @spec resolve([String.t()], {:ok, geocoder()} | {:error, String.t()}, keyword()) :: result()
  def resolve(words, geocoder, opts) when is_list(words) and is_list(opts) do
    deadline_ms = Keyword.fetch!(opts, :deadline_ms)

    # A backend that names no town says so whatever stopped the lookups.
    case {words, geocoder, Keyword.get(opts, :stopped)} do
      {[], _geocoder, _stopped} -> unresolved([], nil)
      {_words, {:error, reason}, _stopped} -> unresolved(words, {:no_backend, reason})
      {_words, {:ok, _geocode}, why} when not is_nil(why) -> unresolved(words, why)
      {_words, {:ok, geocode}, nil} -> run(words, geocode, deadline_ms, opts)
    end
  end

  @doc "What the store keeps of a call's towns: each found town, and each none, by its words."
  @spec kept([{String.t(), outcome()}]) :: %{optional(String.t()) => kept()}
  def kept(towns) when is_list(towns) do
    for {words, outcome} <- towns, row = kept_of(outcome), row != nil, into: %{}, do: {words, row}
  end

  @doc "The counts an event carries: the geocodes sent, the towns found, the nears found to be none."
  @spec counts(result()) :: %{
          towns: non_neg_integer(),
          towns_found: non_neg_integer(),
          towns_not_found: non_neg_integer()
        }
  def counts(%{towns: towns, sent: sent}) do
    %{
      towns: length(sent),
      towns_found: Enum.count(towns, &match?({_words, {:found, _town}}, &1)),
      towns_not_found: Enum.count(towns, &match?({_words, {:none, :not_found}}, &1))
    }
  end

  # -- the geocodes ---------------------------------------------------------------

  defp kept_of({:found, town}), do: {:found, town}
  defp kept_of({:none, :not_found}), do: :none
  defp kept_of({:unresolved, _why}), do: nil

  defp unresolved(words, why) do
    %{
      towns: Enum.map(words, &{&1, {:unresolved, why}}),
      sent: [],
      stop_reason: nil,
      stop_code: nil
    }
  end

  defp run(words, geocode, deadline_ms, opts) do
    now_ms = Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    deadline = now_ms.() + deadline_ms
    remaining = fn -> deadline - now_ms.() end
    state = %{towns: [], sent: [], stop_reason: nil, stop_code: nil}
    # The towns' one stop, for every wave of the call.
    sending = {geocode, terms(remaining)}

    words
    |> Enum.chunk_every(@wave)
    |> Enum.reduce(state, &wave(&1, &2, sending, remaining))
    |> Map.update!(:towns, &Enum.reverse/1)
    |> Map.update!(:sent, &Enum.reverse/1)
  end

  # One wave at a time, at most five of them (20 nears, four at a time).
  defp wave(words, %{stop_reason: why} = state, _geocode, _remaining) when why != nil,
    do: settle_all(state, words, why)

  defp wave(words, state, geocode, remaining) do
    case remaining.() do
      left when left > 0 -> words |> geocode_wave(geocode, left) |> Enum.reduce(state, &settle/2)
      _passed -> settle_all(%{state | stop_reason: :deadline}, words, :deadline)
    end
  end

  defp geocode_wave(words, geocode, timeout_ms) do
    words
    |> Task.async_stream(&call(geocode, &1),
      max_concurrency: @wave,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip_with(words, &judged/2)
  end

  defp call({geocode, terms}, words) when is_function(geocode, 2), do: geocode.(words, terms.())
  defp call({geocode, _terms}, words) when is_function(geocode, 1), do: geocode.(words)

  # A geocode stopped while it ran may have sent.
  defp judged({:exit, :timeout}, words), do: {words, {:unresolved, :deadline}, true, nil}

  defp judged({:ok, {:ok, town, trace}}, words),
    do: {words, {:found, town}, reached?(trace), nil}

  defp judged({:ok, {:error, reason, trace}}, words) when is_binary(reason),
    do: {words, outcome(reason), reached?(trace), Map.get(trace, :provider_code)}

  defp reached?(trace) when is_map(trace), do: Map.get(trace, :attempt) != 0

  defp outcome("invalid_location" <> _rest), do: {:none, :not_found}
  defp outcome("not_a_town" <> _rest), do: {:none, :not_found}
  defp outcome("unsupported" <> _rest), do: {:unresolved, :unsupported}
  defp outcome(reason), do: {:unresolved, Lookup.why_failed(reason)}

  defp settle({words, outcome, sent?, code}, state) do
    state = %{
      state
      | towns: [{words, outcome} | state.towns],
        sent: if(sent?, do: [words | state.sent], else: state.sent)
    }

    case outcome do
      {:unresolved, why} -> first_stop(state, why, code)
      _answered -> state
    end
  end

  defp settle_all(state, words, why),
    do: %{state | towns: Enum.reverse(Enum.map(words, &{&1, {:unresolved, why}})) ++ state.towns}

  # The first answer that cannot heal within the call stops the towns after it.
  defp first_stop(%{stop_reason: nil} = state, why, code) do
    if why in Lookup.stop_reasons(),
      do: %{state | stop_reason: why, stop_code: code},
      else: state
  end

  defp first_stop(state, _why, _code), do: state

  # How a geocode may send, asked as it sends: the time left, and the towns'
  # own stop, which a Mac of the home reads and sets (`PlaceSearch.Computer`).
  defp terms(remaining) do
    cell = :atomics.new(1, signed: false)
    stops = Lookup.stop_reasons()
    stopped = fn -> stop_of(:atomics.get(cell, 1), stops) end

    stop = fn why ->
      _first = :atomics.compare_exchange(cell, 1, 0, index_of(why, stops))
      :ok
    end

    fn -> [send_within_ms: max(remaining.(), 0), stopped: stopped, stop: stop] end
  end

  defp stop_of(0, _stops), do: nil
  defp stop_of(index, stops), do: Enum.at(stops, index - 1)

  defp index_of(why, stops), do: Enum.find_index(stops, &(&1 == why)) + 1

  defp distinct(words), do: words |> Enum.reject(&is_nil/1) |> Enum.uniq()
end
