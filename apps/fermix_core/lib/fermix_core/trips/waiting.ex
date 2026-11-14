defmodule FermixCore.Trips.Waiting do
  @moduledoc """
  A stop that waits for its place (M89 D13 B): the rules, pure. When a
  `trip_edit` call gives a stop a place by words and its lookup could not run
  for a reason that heals by waiting (`reasons/0`: no Mac that looks places up
  online, that Mac not answering in time or busy, the place search rate
  limited, a Brave key's spent quota included, or the call's 45 s spent), the
  store keeps those words beside the stop (`trip_waits` in memory.db, never on
  a device's wire), with when the stop began waiting, how many times the
  trip placer has tried it, the reason, and whether the call had read
  outside content. `Trips.Placer` looks it up again once the place search
  can run, and a stop placed from words given after outside content is
  marked then as the call would have marked it (D9); one whose call read
  nothing keeps the mark it has.

  A refusal that cannot heal by waiting keeps nothing: a Brave key whose plan
  has no place search (it heals only when the key, its plan or the backend
  changes, and nothing the engine sees says when, so the answer tells the
  owner what to change and a later call looks the stop up again), Apple Maps
  switched off on the Mac or the Mac refusing, and no place search set up
  here. Nor does an answer: a result by another name, none found, a place
  with no location, a near the place search does not know. A stop placed by
  its link never waits.

  **What ends a wait** (`cleared/4`), in the store's transaction, whoever makes
  the change (the model, a device or the placer): an edit that gives the stop
  words or any place, a cleared one included, and an edit that gave it place
  words or a link whatever they came to (`given/1`, read from the call as it
  was given, before its lookups: words that placed nothing leave the op
  keeping the place it had), so the placer never places older words over
  newer ones; newer words that heal wait in their place. The stop removed,
  alone or with its day; the trip removed, which ends all of its waits. A time, a length, a
  note, a fixed mark or a move ends none: the placer reads the stop's day as
  the trip then stands. A restored row comes back without its wait, which
  ended when it was removed.

  **What a later lookup is** (`requests/3`): each waiting stop's words on its
  day as the trip stands now, anchored as a call's lookups are
  (`Trips.Lookup.anchor/2`): the day's `near`, the trip's, else the day's
  other placed stops; a waiting stop's own place (an edit's stop keeps the
  one it had) anchors nothing, since the words are to replace it.

  **What an answer does** (`settle/3`): a result the name rule places is the
  place (`Trips.Place.from_search/1`); anything that is not a healing reason
  ends the wait. A healing answer to a lookup that reached the place search
  (`Lookup`'s `sent`) spends a try and is not due again for 30 min after the
  first and 3 h after the second (`retry_in_s/1`); the third ends the wait and
  the stop stays unplaced. A healing answer to a lookup that was never sent
  (the call stopped before it, or it said it sent nothing) spends nothing and
  stays due. A wait 7 days old ends without another lookup (`cutoff/1`). The
  caps and the waits are constants, not configuration.
  """

  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Place
  alias FermixCore.Trips.Placing

  @reasons [:computer_away, :computer_timed_out, :computer_busy, :rate_limited, :deadline]
  @max_tries 3
  @max_age_s 7 * 86_400

  @typedoc "Why a stop waits: a reason that heals by waiting."
  @type reason ::
          :computer_away | :computer_timed_out | :computer_busy | :rate_limited | :deadline

  @typedoc "What a call's lookups leave waiting, by the op (the request's ref) that gave the words."
  @type asked :: %{ref: pos_integer(), words: String.t(), reason: reason()}

  @typedoc "One waiting stop, as the store keeps it, with its trip's owner."
  @type wait :: %{
          row_id: String.t(),
          trip_id: String.t(),
          owner_id: String.t(),
          agent_id: String.t(),
          words: String.t(),
          reason: reason(),
          since: DateTime.t(),
          tries: non_neg_integer(),
          outside: boolean(),
          due_at: DateTime.t() | nil
        }

  @typedoc """
  What a lookup's answer does to a wait: place the stop, wait again with the
  new reason and try count, or stop waiting, by an answer or by the tries cap.
  """
  @type action ::
          {:place, Place.t()}
          | {:wait, reason(), non_neg_integer(), DateTime.t() | nil}
          | {:stop, :answered | :gave_up}

  @typedoc "One wait's action, with the words and since the store checks still stand."
  @type result :: %{
          row_id: String.t(),
          words: String.t(),
          since: DateTime.t(),
          action: action()
        }

  @doc "The reasons a stop waits for, each one that heals by waiting."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "Whether a lookup's `why` heals by waiting."
  @spec heals?(term()) :: boolean()
  def heals?(why), do: why in @reasons

  @doc "The most times the placer tries one waiting stop."
  @spec max_tries() :: pos_integer()
  def max_tries, do: @max_tries

  @doc "How long a wait tried `tries` times is not due again: 30 min after one, 3 h after two."
  @spec retry_in_s(pos_integer()) :: pos_integer()
  def retry_in_s(1), do: 30 * 60
  def retry_in_s(2), do: 3 * 3_600

  @doc """
  The ops of `call`, as it was given and before its lookups, that gave a
  stop place words or a link, by position from 1: each ends that stop's
  wait whatever its lookup came to.
  """
  @spec given(map()) :: [pos_integer()]
  def given(%{ops: ops}) when is_list(ops) do
    for {%{place: {kind, value}}, index} <- Enum.with_index(ops, 1),
        kind in [:words, :link] and is_binary(value),
        do: index
  end

  @doc "The first moment a wait still stands at `now`: one begun before it is 7 days old."
  @spec cutoff(DateTime.t()) :: DateTime.t()
  def cutoff(%DateTime{} = now), do: DateTime.add(now, -@max_age_s, :second)

  @doc """
  What a call's lookups leave waiting (`Trips.Lookup.resolve/3`'s requests and
  outcomes): each request whose outcome is a reason that heals, with its words.
  """
  @spec asked([Lookup.request()], [{term(), Lookup.outcome()}]) :: [asked()]
  def asked(requests, outcomes) when is_list(requests) and is_list(outcomes) do
    by_ref = Map.new(outcomes)

    for %{ref: ref, place: words} <- requests,
        {:none, why} <- [Map.get(by_ref, ref)],
        heals?(why),
        do: %{ref: ref, words: words, reason: why}
  end

  @doc """
  The waits `call` saves once the store applied it (`result`, `Trips.Ops`'s):
  each `asked` by an op whose stop is live after the call, by its row
  (`Trips.Placing.placements/3`); none when the call removed the trip.
  """
  @spec saved(map(), map(), [asked()]) :: [
          %{row_id: String.t(), words: String.t(), reason: reason()}
        ]
  def saved(_call, %{trip: %{removed_at: %DateTime{}}}, asked) when is_list(asked), do: []
  def saved(_call, _result, []), do: []

  def saved(call, result, asked) when is_list(asked) do
    by_ref = Map.new(asked, &{&1.ref, &1})
    outcomes = Enum.map(asked, &{&1.ref, {:none, &1.reason}})

    for %{row: row, ref: ref} <- Placing.placements(call, result, outcomes) do
      %{words: words, reason: reason} = Map.fetch!(by_ref, ref)
      %{row_id: row.id, words: words, reason: reason}
    end
  end

  @doc """
  The rows whose wait `call` ends (the moduledoc), from the live rows the
  store loaded (`before`), what it applied (`result`) and the ops that gave
  place words or a link as the call was given (`given`, `given/1`): `:all`
  when the call removed the trip.
  """
  @spec cleared(map(), [map()], map(), [pos_integer()]) :: :all | [String.t()]
  def cleared(_call, before, %{trip: %{removed_at: %DateTime{}}}, given)
      when is_list(before) and is_list(given),
      do: :all

  def cleared(%{ops: ops}, before, %{rows: rows} = result, given)
      when is_list(before) and is_list(given) do
    live = MapSet.new(rows, & &1.id)
    gone = for %{kind: :stop, id: id} <- before, not MapSet.member?(live, id), do: id
    known = before ++ rows ++ Map.get(result, :removed_rows, [])

    named =
      for {op, index} <- Enum.with_index(ops, 1),
          named?(op, index in given),
          id <- ids_of(op.n, known),
          do: id

    Enum.uniq(gone ++ named)
  end

  # An edit that gives the stop words or any place, or gave it place words
  # or a link, named by its number (the model's) or its id (a device's, the
  # placer's).
  defp named?(%{op: :edit} = op, given?), do: given? or is_binary(op.text) or op.place != :keep
  defp named?(_op, _given?), do: false

  defp ids_of({:id, id}, _known), do: [id]

  defp ids_of(n, known),
    do: known |> Enum.filter(&(&1.n == n)) |> Enum.map(& &1.id) |> Enum.uniq()

  @doc """
  The lookups for a trip's `waits` as the trip (`trip`, its live `rows`) now
  stands (the moduledoc): one request a waiting stop that is still live, by
  its row id and on its day, and the anchors they search around.
  """
  @spec requests(map(), [map()], [wait()]) :: {[Lookup.request()], Lookup.anchors()}
  def requests(%{near: trip_near}, rows, waits) when is_list(rows) and is_list(waits) do
    by_row = Map.new(waits, &{&1.row_id, &1})
    days = Ops.days(rows)

    requests =
      for %{stops: stops, position: k} <- days,
          %{id: id} <- stops,
          %{words: words} <- [Map.get(by_row, id)],
          do: %{ref: id, place: words, day: k}

    {requests, %{placed: placed(days, by_row), day_near: day_near(days), trip_near: trip_near}}
  end

  defp placed(days, by_row) do
    for %{stops: stops, position: k} <- days,
        points = for(stop <- stops, anchors?(stop, by_row), do: Place.point(stop.place)),
        points != [],
        into: %{},
        do: {k, points}
  end

  defp anchors?(%{place: nil}, _by_row), do: false
  defp anchors?(%{id: id}, by_row), do: not Map.has_key?(by_row, id)

  defp day_near(days),
    do: for(%{row: %{near: near}, position: k} <- days, is_binary(near), into: %{}, do: {k, near})

  @doc """
  What each wait's lookup answer does at `now` (`found`, `Lookup`'s
  `outcomes` and `sent`, by row id): one result a wait that was looked up, in
  the order of `waits`; a wait with no answer (its stop no longer live) has
  none.
  """
  @spec settle([wait()], map(), DateTime.t()) :: [result()]
  def settle(waits, %{outcomes: outcomes, sent: sent}, %DateTime{} = now)
      when is_list(waits) and is_list(outcomes) and is_list(sent) do
    by_row = Map.new(outcomes)
    sent = MapSet.new(sent)

    for %{row_id: id} = wait <- waits,
        {:ok, outcome} <- [Map.fetch(by_row, id)],
        do: %{
          row_id: id,
          words: wait.words,
          since: wait.since,
          action: action(wait, outcome, {MapSet.member?(sent, id), now})
        }
  end

  defp action(_wait, {:placed, record}, _sent_at) do
    case Place.from_search(record) do
      {:ok, place} -> {:place, place}
      {:error, {:invalid_place, _field}} -> {:stop, :answered}
    end
  end

  defp action(%{tries: tries}, {:none, why}, {false, _now}) when why in @reasons,
    do: {:wait, why, tries, nil}

  defp action(%{tries: tries}, {:none, why}, {true, now}) when why in @reasons do
    if tries + 1 >= @max_tries,
      do: {:stop, :gave_up},
      else: {:wait, why, tries + 1, DateTime.add(now, retry_in_s(tries + 1), :second)}
  end

  defp action(_wait, _offered_or_none, _sent_at), do: {:stop, :answered}
end
