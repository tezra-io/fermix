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
  `component: "trips"`, `made_via` (`chat | job | mac | phone`), `outcome`
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
  """

  alias FermixCore.Telemetry

  @read_event [:fermix, :trip, :read]
  @edit_event [:fermix, :trip, :edit]
  @outcomes [:ok, :refused, :failed]
  @scopes [:index, :trip, :days, :outline, :share]
  @made_via ["chat", "job", "mac", "phone"]
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
    }
  ]

  @doc "Event definitions `FermixCore.Trace.TelemetryHandler` routes into the JSONL trace."
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The read events and the edit events, in that order."
  @spec events() :: [[atom()]]
  def events, do: [@read_event, @edit_event]

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
