defmodule FermixCore.Trips.Placer.Run do
  @moduledoc """
  One run of the trip placer (M89 D13 B): the stops a trip keeps waiting
  (`Trips.Waiting`) looked up again with the code a `trip_edit` call uses,
  in the process `Trips.Placer` gave it, never the placer's own.

  A run, in order:

    1. **takes** the oldest 20 waits that are due, of every owner, every wait
       7 days old ending first unlooked-up (`Registry.take_waits/3`); with
       none due and none ended, it is no run at all, with no event, and
       answers only when the next wait comes due;
    2. **opens** its session (`:session_id`, which the placer names before it
       starts the run, else `trip_place:<16 hex>`), a root of its own
       (`Trips.Telemetry.emit_place_start/2`);
    3. **resolves** the home's place search once (`PlaceSearch.resolution/1`,
       `Lookup.backend/2`), as a call does, and asks whether it can run now:
       on a Mac of the home, whether one that offers places is connected
       (`Computers.Choice.places_computer/1`; computers that cannot be read
       are logged and are no Mac); on Brave, whether the key is spent
       (`Brave.Pacer.spent_ms/1`); Apple Maps here always can. When it
       cannot, nothing is looked up and no try is spent;
    4. **looks up** each trip's waiting stops in turn, oldest first, with
       `Trips.Lookup.resolve/3` on the trip as it now stands
       (`Waiting.requests/3`), every trip within the run's one 45 s, and
       none started with under 10 s left. A trip whose lookups were
       stopped (a rate limit, no Mac online, ...) stops the run: the trips
       after it are not tried. Only a lookup that reached the place search
       and failed spends a try (`Waiting.settle/3`), and puts its wait off
       (30 min, then 3 h), so a burst of wakes, or a restart, spends
       nothing more;
    5. **writes** each trip once (`Registry.place_waiting/4`): the stops the
       name rule placed, the trip's rev once, its devices told, its edit
       event under the run's session, said in no chat;
    6. **closes** with its counts (`Trips.Telemetry.emit_place_complete/3`)
       and answers when to look next (`next_ms`): none while nothing waits;
       while waits are due still, Brave's reset when the key is spent, 6 h
       when no Mac that offers places is online (one connecting wakes the
       placer first) or no place search is set up, else 5 min; and never
       later than the next wait comes due.

  A store that cannot be read ends the run with `run_error`, its duration
  and `failed: true`; a trip that cannot be read or written is logged and
  counted (`failed`), its waits as they were, and the run answers `failed:
  true` too. The placer backs off on either (`Trips.Placer`).

  A stop the owner moves to another day while its lookup runs is placed by
  the words looked up around the day it was on when the run read the trip;
  the next lookup of any stop reads the trip as it then stands.

  `opts`: `:repo`, `:timeout` (each store call's), `:now` (0-arity, the wall
  clock), `:now_ms` (the monotonic clock the lookups' deadline reads),
  `:notifier`, `:session_id`, `:context` (fields the lookups' context adds:
  `:host`, `:computers_opts`, `:computer_call_opts`, `:place_search_pacer`, a
  `:place_lookup` stand-in) and `:backend`, a test's stand-in for the home's
  resolved place search (`backend/0`).
  """

  require Logger

  alias FermixCore.Computers.Choice
  alias FermixCore.Tools.PlaceSearch
  alias FermixCore.Tools.PlaceSearch.Brave.Pacer
  alias FermixCore.Tools.PlaceSearch.Computer
  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Registry
  alias FermixCore.Trips.Telemetry
  alias FermixCore.Trips.Waiting

  @max_stops 20
  @soon_ms 5 * 60_000
  @idle_ms 6 * 3_600_000
  @min_lookup_ms 10_000
  @triggers [:boot, :computer, :timer]

  @typedoc "What woke the run."
  @type trigger :: :boot | :computer | :timer

  @typedoc "Why the place search cannot run now."
  @type later :: :no_mac | {:brave_spent, pos_integer()} | :no_backend | :computers_unread

  @typedoc """
  The home's place search for a run: its name for the events, the search
  (`Lookup.backend/2`'s answer) and whether it can run now, asked as needed.
  """
  @type backend :: %{
          name: String.t() | nil,
          search: {:ok, Lookup.search()} | {:error, String.t()},
          ready: (-> :ok | {:later, later()})
        }

  @typedoc "What a run answers: when to look next, and whether it met a fault."
  @type answer :: %{required(:next_ms) => non_neg_integer() | nil, optional(:failed) => true}

  @doc "The most waiting stops one run looks up."
  @spec max_stops() :: pos_integer()
  def max_stops, do: @max_stops

  @doc """
  One run, woken by `trigger` (the moduledoc): `next_ms`, how long until the
  placer should look again (nil when nothing waits), and `failed: true` when
  it met a fault the placer backs off from.
  """
  @spec run(trigger(), keyword()) :: answer()
  def run(trigger, opts) when trigger in @triggers and is_list(opts) do
    start = System.monotonic_time(:microsecond)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    case Registry.take_waits(now, @max_stops, store_opts(opts)) do
      {:ok, %{expired: 0, waits: []} = taken} -> %{next_ms: due_in(taken.next_due_at, now)}
      {:ok, taken} -> started(trigger, taken, now, opts)
      {:error, :disabled} -> %{next_ms: nil}
      {:error, reason} -> unread(run_of(trigger, opts), reason, start)
    end
  end

  @doc """
  Whether the home's place search `name` can run now, for a lookup context:
  a Mac that offers places connected, Brave's key not spent, or Apple Maps
  on this build.
  """
  @spec ready(:computer | :brave | :apple_maps, map()) :: :ok | {:later, later()}
  def ready(:computer, context) when is_map(context) do
    case Computer.computers(Map.get(context, :computers_opts, [])) do
      {:ok, computers} ->
        if Choice.places_computer(computers) == :none, do: {:later, :no_mac}, else: :ok

      {:error, reason} ->
        Logger.error("trips: the placer could not read the home's computers: #{inspect(reason)}")
        {:later, :computers_unread}
    end
  end

  def ready(:brave, context) when is_map(context) do
    case Pacer.spent_ms(Map.get(context, :place_search_pacer, Pacer)) do
      nil -> :ok
      spent_ms -> {:later, {:brave_spent, spent_ms}}
    end
  end

  def ready(:apple_maps, context) when is_map(context), do: :ok

  # -- the run -------------------------------------------------------------------

  defp run_of(trigger, opts),
    do: %{
      session_id: Keyword.get_lazy(opts, :session_id, &Telemetry.place_session_id/0),
      trigger: trigger
    }

  defp started(trigger, taken, now, opts) do
    start = System.monotonic_time(:microsecond)
    run = run_of(trigger, opts)
    :ok = Telemetry.emit_place_start(run, %{waiting: taken.total, expired: taken.expired})

    context = Map.merge(Keyword.get(opts, :context, %{}), %{session_id: run.session_id})
    backend = backend(context, opts)
    env = %{run: run, now: now, backend: backend, opts: opts}
    summary = summary(taken, env)

    :ok = Telemetry.emit_place_complete(run, summary, elapsed(start))
    answer(summary, backend, now)
  end

  defp summary(%{waits: []} = taken, env), do: base(taken, env.backend)

  defp summary(taken, env) do
    acc = base(taken, env.backend)

    case readiness(env.backend) do
      :ok -> place_trips(taken.waits, env, acc)
      {:later, why} -> untried(%{acc | skipped: skip(why)}, taken.waits)
    end
  end

  # Waits past the run's cap, or not yet due, are untouched and still wait;
  # the age cap's ended at the take. `due_left` is what is due and was not
  # looked up, and `next_due_at` the soonest wait put off; neither is counted
  # in the event.
  defp base(taken, backend) do
    %{
      backend: backend.name,
      skipped: nil,
      stop_reason: nil,
      stop_code: nil,
      placed: 0,
      waiting: taken.total - length(taken.waits),
      stopped_waiting: taken.expired,
      expired: taken.expired,
      superseded: 0,
      lookups: 0,
      trips: 0,
      failed: 0,
      due_left: taken.due - length(taken.waits),
      next_due_at: taken.next_due_at
    }
  end

  defp untried(acc, waits),
    do: %{acc | waiting: acc.waiting + length(waits), due_left: acc.due_left + length(waits)}

  defp skip(:no_mac), do: :no_mac
  defp skip({:brave_spent, _ms}), do: :brave_spent
  defp skip(:no_backend), do: :no_backend
  defp skip(:computers_unread), do: :computers_unread

  defp readiness(%{search: {:error, _reason}}), do: {:later, :no_backend}
  defp readiness(%{ready: ready}), do: ready.()

  # One trip at a time, oldest first, within the run's one deadline; once a
  # trip's lookups were stopped, or too little time is left, the rest wait.
  # Bounded: at most `@max_stops` trips.
  defp place_trips(waits, env, acc) do
    now_ms = Keyword.get(env.opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    deadline = now_ms.() + Lookup.deadline_ms()

    Enum.reduce(by_trip(waits), acc, fn {owner, trip_waits}, acc ->
      left_ms = deadline - now_ms.()

      if acc.stop_reason != nil or left_ms < @min_lookup_ms,
        do: untried(acc, trip_waits),
        else: place_trip(owner, trip_waits, Map.put(env, :left_ms, left_ms), acc)
    end)
  end

  # Each trip's waits, the trip of the oldest first.
  defp by_trip(waits) do
    grouped = Enum.group_by(waits, & &1.trip_id)

    waits
    |> Enum.map(& &1.trip_id)
    |> Enum.uniq()
    |> Enum.map(fn id ->
      [first | _rest] = trip_waits = Map.fetch!(grouped, id)
      {%{trip_id: id, owner_id: first.owner_id, agent_id: first.agent_id}, trip_waits}
    end)
  end

  defp place_trip(owner, waits, env, acc) do
    case Registry.waiting_trip(owner, store_opts(env.opts)) do
      {:ok, %{trip: trip, rows: rows}} -> looked_up(owner, {trip, rows, waits}, env, acc)
      {:error, reason} -> failed(acc, waits, "read", reason)
    end
  end

  defp looked_up(owner, {trip, rows, waits}, env, acc) do
    {requests, anchors} = Waiting.requests(trip, rows, waits)
    found = resolve(requests, anchors, env)
    results = Waiting.settle(waits, found, env.now)
    looked = %{found: found, backend: env.backend.name}

    case Registry.place_waiting(owner, results, looked, write_opts(env)) do
      {:ok, done} -> counted(acc, done, {waits, results}, found)
      {:error, reason} -> failed(acc, waits, "write", reason)
    end
  end

  defp resolve([], _anchors, _env),
    do: %{outcomes: [], sent: [], lookups: 0, stop_reason: nil, stop_code: nil}

  defp resolve(requests, anchors, env) do
    lookup_opts =
      [
        backend: env.backend.search,
        conversation_key: env.run.session_id,
        deadline_ms: env.left_ms
      ] ++ Keyword.take(env.opts, [:now_ms])

    case Lookup.resolve(requests, anchors, lookup_opts) do
      {:ok, found} -> found
      {:error, reason} -> refused(requests, reason)
    end
  end

  # A trip's waits the lookup refused whole (a waiting stop's words are no
  # link, and one run asks for at most 20, so this is a fault): each ends,
  # and the log says why.
  defp refused(requests, reason) do
    Logger.error("trips: the placer's lookups were refused: #{inspect(reason)}")
    failure = {:none, {:failed, "refused: #{inspect(reason)}"}}

    %{
      outcomes: Enum.map(requests, &{&1.ref, failure}),
      sent: [],
      lookups: 0,
      stop_reason: nil,
      stop_code: nil
    }
  end

  defp counted(acc, done, {waits, results}, found) do
    by_row = Map.new(results, &{&1.row_id, &1.action})
    kept = Enum.map(done.waiting, &Map.fetch!(by_row, &1))
    gave_up = Enum.count(done.stopped, &(Map.get(by_row, &1) == {:stop, :gave_up}))

    %{
      acc
      | placed: acc.placed + length(done.placed),
        waiting: acc.waiting + length(done.waiting),
        stopped_waiting: acc.stopped_waiting + length(done.stopped),
        expired: acc.expired + gave_up,
        superseded: acc.superseded + done.superseded + length(waits) - length(results),
        lookups: acc.lookups + found.lookups,
        trips: acc.trips + if(done.changed?, do: 1, else: 0),
        stop_reason: acc.stop_reason || found.stop_reason,
        stop_code: if(acc.stop_reason, do: acc.stop_code, else: found.stop_code),
        due_left: acc.due_left + Enum.count(kept, &match?({:wait, _r, _t, nil}, &1)),
        next_due_at: soonest([acc.next_due_at | for({:wait, _r, _t, at} <- kept, do: at)])
    }
  end

  defp failed(acc, waits, what, reason) do
    Logger.error(
      "trips: the placer could not #{what} a trip of waiting stops: #{inspect(reason)}"
    )

    %{untried(acc, waits) | failed: acc.failed + 1}
  end

  # -- when to look next -------------------------------------------------------------

  defp answer(summary, backend, now) do
    next_ms = [due_now_ms(summary, backend), due_in(summary.next_due_at, now)]

    case {Enum.reject(next_ms, &is_nil/1), summary.failed} do
      {[], 0} -> %{next_ms: nil}
      {[], _failed} -> %{next_ms: nil, failed: true}
      {delays, 0} -> %{next_ms: Enum.min(delays)}
      {delays, _failed} -> %{next_ms: Enum.min(delays), failed: true}
    end
  end

  defp due_now_ms(%{due_left: 0}, _backend), do: nil

  defp due_now_ms(_summary, backend) do
    case readiness(backend) do
      :ok -> @soon_ms
      {:later, {:brave_spent, spent_ms}} -> spent_ms
      {:later, _why} -> @idle_ms
    end
  end

  defp due_in(nil, _now), do: nil
  defp due_in(%DateTime{} = at, now), do: max(DateTime.diff(at, now, :millisecond), 0)

  defp soonest(stamps) do
    case Enum.reject(stamps, &is_nil/1) do
      [] -> nil
      stamps -> Enum.min(stamps, DateTime)
    end
  end

  defp unread(run, reason, start) do
    Logger.error("trips: the placer could not read the waiting stops: #{inspect(reason)}")
    :ok = Telemetry.emit_place_error(run, Registry.error_tag(reason), nil, elapsed(start))
    %{next_ms: @soon_ms, failed: true}
  end

  # -- the home's place search ---------------------------------------------------

  defp backend(context, opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} when is_function(backend, 1) -> backend.(context)
      :error -> resolved(context)
    end
  end

  defp resolved(%{place_lookup: _search} = context),
    do: %{name: nil, search: Lookup.backend(context), ready: fn -> :ok end}

  defp resolved(context) do
    resolution = PlaceSearch.resolution(context)

    %{
      name: Atom.to_string(resolution.name),
      search: Lookup.backend(context, resolution),
      ready: fn -> ready(resolution.name, context) end
    }
  end

  defp store_opts(opts), do: Keyword.take(opts, [:repo, :timeout]) ++ [on_timeout: :error]

  defp write_opts(env) do
    store_opts(env.opts) ++
      Keyword.take(env.opts, [:notifier]) ++
      [now: env.now, session_id: env.run.session_id]
  end

  defp elapsed(start), do: max(System.monotonic_time(:microsecond) - start, 0)
end
