defmodule FermixCore.Checklists.Telemetry do
  @moduledoc """
  The one emitter of the list events (MILESTONE_85 §04, §12), never with an
  item's words or a list's title.

  `[:fermix, :checklist, :read]`: one event per read. Measurements:
  `duration_us` (the store's read) and `lists` (how many lists it returned).
  `[:fermix, :checklist, :edit]`: one event per `checklist_edit` call, the
  one transaction it is. Measurements: `duration_us`, `lists` (the lists the
  call touched) and `ops`. Metadata on both: `component: "checklists"`,
  `made_via` (`chat | job`), `outcome` (`ok | refused | failed`), `error_code`
  (the refusal's tag, `Checklists.Registry.error_tag/1`, else nil), `scope`
  on a read (`list | folder | index`), and the caller's `session_id` when it
  has one.

  `Trace.TelemetryHandler` records them as `checklist_read` and
  `checklist_edit` agent events keyed on `component`, and the Opik exporter
  places each under its turn's trace as a point span
  (`FermixOpik.Mapper.checklist_span/4`).
  """

  alias FermixCore.Telemetry

  @read_event [:fermix, :checklist, :read]
  @edit_event [:fermix, :checklist, :edit]
  @outcomes [:ok, :refused, :failed]
  @scopes [:list, :folder, :index]

  @trace_event_definitions [
    %{
      event: @read_event,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "checklist_read"
    },
    %{
      event: @edit_event,
      trace_type: :agent_event,
      agent_field: :component,
      trace_event: "checklist_edit"
    }
  ]

  @doc "Event definitions `FermixCore.Trace.TelemetryHandler` routes into the JSONL trace."
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The read events and the edit events, in that order."
  @spec events() :: [[atom()]]
  def events, do: [@read_event, @edit_event]

  @spec emit_read(map(), map(), non_neg_integer()) :: :ok
  def emit_read(context, %{scope: scope, lists: lists} = read, duration_us)
      when is_map(context) and scope in @scopes and is_integer(lists) and
             is_integer(duration_us) and duration_us >= 0 do
    :telemetry.execute(
      @read_event,
      %{duration_us: duration_us, lists: lists},
      context |> metadata(read) |> Map.put(:scope, scope)
    )
  end

  @spec emit_edit(map(), map(), non_neg_integer()) :: :ok
  def emit_edit(context, %{lists: lists, ops: ops} = edit, duration_us)
      when is_map(context) and is_integer(lists) and is_integer(ops) and
             is_integer(duration_us) and duration_us >= 0 do
    :telemetry.execute(
      @edit_event,
      %{duration_us: duration_us, lists: lists, ops: ops},
      metadata(context, edit)
    )
  end

  defp metadata(context, %{outcome: outcome, made_via: made_via} = fields)
       when outcome in @outcomes and made_via in ["chat", "job"] do
    context
    |> Telemetry.correlation()
    |> Map.take([:session_id])
    |> Map.merge(%{
      component: "checklists",
      made_via: made_via,
      outcome: outcome,
      error_code: Map.get(fields, :error_code)
    })
  end
end
