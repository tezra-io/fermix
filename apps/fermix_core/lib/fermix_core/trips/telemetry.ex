defmodule FermixCore.Trips.Telemetry do
  @moduledoc """
  The one emitter of the trip events (M89 §04, §14), never with a title, a
  stop's words, a place or a coordinate.

  `[:fermix, :trip, :read]`: one event per read. Measurements: `duration_us`
  (the store's read) and `trips` (how many trips it returned).
  `[:fermix, :trip, :edit]`: one event per `trip_edit` call or device edit,
  the one transaction it is. Measurements: `duration_us`, `trips` (the trips
  it touched), `ops`, and what the place lookup did for it: `lookups`,
  `placed`, `offered`, `not_found`, `not_looked_up`. Metadata on both:
  `component: "trips"`, `made_via` (`chat | job | mac | phone`, and
  `trip_place` for the trip placer's write), `outcome`
  (`ok | refused | failed`), `error_code` (the refusal's tag,
  `Trips.Registry.error_tag/1`, else nil) and the caller's `session_id` when
  it has one; `scope` on a read (`index | trip | days | outline | share`);
  `backend` (the place search's, else nil), `rate_limited`, and what stopped
  the lookups on an edit: `stop_reason` (`rate_limited |
  plan_excludes_place_search | computer_away | computer_off | computer_refused
  | computer_timed_out | deadline`, else nil) and `stop_code`, the place
  search's own code for it (Brave's `OPTION_NOT_IN_PLAN`; for a Mac of the
  home, how its invocation ended: `timed_out`, or its refusal such as `off`,
  `unavailable` or `stale_epoch`, nil when no Mac was online to ask), else
  nil. `backend` is `brave`, `apple_maps` or
  `computer`.
  `lookups` counts the lookups that reached the place search.

  `Trace.TelemetryHandler` records them as `trip_read` and `trip_edit` agent
  events keyed on `component`, and the Opik exporter places each under its
  turn's trace as a point span (`FermixOpik.Mapper.trip_span/4`).

  **The trip placer's run** (D13 B, `Trips.Placer.Run`) is a run kind of its
  own: one session a run, `trip_place:<16 hex>` (`place_session_id/0`), a
  root with no `parent_session`, bracketed by
  `[:fermix, :trip_place, :run_start]` (measurements `waiting`, the stops
  waiting when it began, and `expired`, the ones the age cap ended then;
  metadata `trigger`: `boot | computer | timer`) and one closer:
  `[:fermix, :trip_place, :run_complete]` (measurements `duration_us`,
  `placed`, `waiting` (still waiting when it ended), `stopped_waiting` (ended
  unplaced, for any reason), `expired` (of those, by the tries or the age
  cap), `superseded` (a newer change ended them first), `lookups`, `trips`
  (whose rev moved) and `failed` (a trip it could not read or write);
  metadata `trigger`, `backend`, `skipped` (`no_mac | brave_spent |
  no_backend | computers_unread` when the place search could not run, so it
  looked nothing up, else nil), `stop_reason` and `stop_code`, as an edit's)
  or `[:fermix, :trip_place, :run_error]` (`duration_us`; `error_code`: the
  store's refusal when the run could not read the waits, or `crashed` or
  `overran` when `Trips.Placer` closes a run that raised or was stopped at
  its 120 s bound, under the session it named for the run before starting
  it; `reason`, the kind of what ended it, never its words). Each trip it writes is
  one `[:fermix, :trip, :edit]` under its `session_id`, `made_via:
  "trip_place"`. All carry `component: "trips"`, and no words, place or
  coordinate; the Opik exporter opens and closes the run's root
  (`FermixOpik.Aggregation`, kind `:trip_place`) and nests the edits under it.
  """

  alias FermixCore.Telemetry

  @read_event [:fermix, :trip, :read]
  @edit_event [:fermix, :trip, :edit]
  @place_start [:fermix, :trip_place, :run_start]
  @place_complete [:fermix, :trip_place, :run_complete]
  @place_error [:fermix, :trip_place, :run_error]
  @place_prefix "trip_place:"
  @outcomes [:ok, :refused, :failed]
  @scopes [:index, :trip, :days, :outline, :share]
  @made_via ["chat", "job", "mac", "phone", "trip_place"]
  @triggers [:boot, :computer, :timer]
  @skips [nil, :no_mac, :brave_spent, :no_backend, :computers_unread]
  @place_counts [
    :placed,
    :waiting,
    :stopped_waiting,
    :expired,
    :superseded,
    :lookups,
    :trips,
    :failed
  ]
  @lookup_counts [:lookups, :placed, :offered, :not_found, :not_looked_up]
  @stop_reasons [
    nil,
    :rate_limited,
    :plan_excludes_place_search,
    :computer_away,
    :computer_off,
    :computer_refused,
    :computer_timed_out,
    :deadline
  ]

  @trace_event_definitions [
    %{
      event: @read_event,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "trip_read"
    },
    %{
      event: @edit_event,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "trip_edit"
    },
    %{
      event: @place_start,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "trip_place_run_start"
    },
    %{
      event: @place_complete,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "trip_place_run_complete"
    },
    %{
      event: @place_error,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "trip_place_run_error"
    }
  ]

  @doc "Event definitions `FermixCore.Trace.TelemetryHandler` routes into the JSONL trace."
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The read events and the edit events, in that order."
  @spec events() :: [[atom()]]
  def events, do: [@read_event, @edit_event]

  @doc "The trip placer's run bookends: its start, its end and its failure."
  @spec place_events() :: [[atom()]]
  def place_events, do: [@place_start, @place_complete, @place_error]

  @doc "A new trip placer run's own session id, `trip_place:<16 hex>`."
  @spec place_session_id() :: String.t()
  def place_session_id,
    do: @place_prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "Opens a placer run: its trigger, the stops waiting and those the age cap ended."
  @spec emit_place_start(map(), %{waiting: non_neg_integer(), expired: non_neg_integer()}) ::
          :ok
  def emit_place_start(run, %{waiting: waiting, expired: expired})
      when is_integer(waiting) and waiting >= 0 and is_integer(expired) and expired >= 0 do
    :telemetry.execute(@place_start, %{waiting: waiting, expired: expired}, place_meta(run))
  end

  @doc "Closes a placer run with what it placed, what still waits and what stopped waiting."
  @spec emit_place_complete(map(), map(), non_neg_integer()) :: :ok
  def emit_place_complete(run, %{skipped: skipped} = summary, duration_us)
      when skipped in @skips and is_integer(duration_us) and duration_us >= 0 do
    counts = Map.new(@place_counts, &{&1, lookup_count(summary, &1)})

    :telemetry.execute(
      @place_complete,
      Map.put(counts, :duration_us, duration_us),
      run
      |> place_meta()
      |> Map.merge(%{backend: backend(summary), skipped: skipped})
      |> Map.merge(stop(summary))
    )
  end

  @doc """
  Closes a placer run that did not finish: `error_code` is the store's
  refusal when it could not read the waits, `crashed` or `overran` when the
  placer closes a run that raised or passed its bound; `reason` is the kind
  of what ended it (an exception's module, an exit's word), never its words.
  """
  @spec emit_place_error(map(), String.t(), String.t() | nil, non_neg_integer()) :: :ok
  def emit_place_error(run, error_code, reason, duration_us)
      when is_binary(error_code) and (is_binary(reason) or is_nil(reason)) and
             is_integer(duration_us) and duration_us >= 0 do
    :telemetry.execute(
      @place_error,
      %{duration_us: duration_us},
      Map.merge(place_meta(run), %{error_code: error_code, reason: reason})
    )
  end

  defp place_meta(%{session_id: @place_prefix <> _hex = session_id, trigger: trigger})
       when trigger in @triggers,
       do: %{session_id: session_id, component: "trips", trigger: trigger}

  @doc "One read: its `scope`, how many `trips` it returned, its outcome and caller."
  @spec emit_read(map(), map(), non_neg_integer()) :: :ok
  def emit_read(context, %{scope: scope, trips: trips} = read, duration_us)
      when is_map(context) and scope in @scopes and is_integer(trips) and trips >= 0 and
             is_integer(duration_us) and duration_us >= 0 do
    :telemetry.execute(
      @read_event,
      %{duration_us: duration_us, trips: trips},
      context |> metadata(read) |> Map.put(:scope, scope)
    )
  end

  @doc "One edit: the `trips` it touched, its `ops`, what its lookups did, its outcome and caller."
  @spec emit_edit(map(), map(), non_neg_integer()) :: :ok
  def emit_edit(context, %{trips: trips, ops: ops} = edit, duration_us)
      when is_map(context) and is_integer(trips) and trips >= 0 and is_integer(ops) and
             ops >= 0 and is_integer(duration_us) and duration_us >= 0 do
    counts = Map.new(@lookup_counts, &{&1, lookup_count(edit, &1)})

    :telemetry.execute(
      @edit_event,
      Map.merge(%{duration_us: duration_us, trips: trips, ops: ops}, counts),
      context
      |> metadata(edit)
      |> Map.merge(%{backend: backend(edit), rate_limited: Map.fetch!(edit, :rate_limited)})
      |> Map.merge(stop(edit))
    )
  end

  defp stop(%{stop_reason: reason, stop_code: code})
       when reason in @stop_reasons and (is_nil(code) or is_binary(code)),
       do: %{stop_reason: reason, stop_code: code}

  defp lookup_count(edit, key) do
    case Map.fetch!(edit, key) do
      count when is_integer(count) and count >= 0 -> count
    end
  end

  defp backend(%{backend: nil}), do: nil
  defp backend(%{backend: backend}) when is_binary(backend), do: backend

  defp metadata(context, %{outcome: outcome, made_via: made_via} = fields)
       when outcome in @outcomes and made_via in @made_via do
    context
    |> Telemetry.correlation()
    |> Map.take([:session_id])
    |> Map.merge(%{
      component: "trips",
      made_via: made_via,
      outcome: outcome,
      error_code: Map.get(fields, :error_code)
    })
  end
end
