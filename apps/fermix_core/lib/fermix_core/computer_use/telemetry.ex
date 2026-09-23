defmodule FermixCore.ComputerUse.Telemetry do
  @moduledoc """
  Single emitter for `[:fermix, :computer_use, ...]` session lifecycle events.

  A computer-use session is a new run-type (docs/TELEMETRY_CONTRACT.md): it owns a
  long-lived OS-driver process and spans many actions across the agent loop, so it
  needs its own traceable lifecycle. Only the session lifecycle (which has no
  request/response analog) lives here — each ACTION is a tool call emitted through
  the shared `FermixCore.Tools.Telemetry` so it reuses the existing JSONL/Opik
  aggregation. Every event carries the session's `session_id` (`cua_<id>`) and,
  when spawned by a main turn, its `parent_session`, so a whole session
  reassembles into one trace correlated to the turn that opened it.

  The family is wired end to end: `trace_event_definitions/0` below is what
  `FermixCore.Trace.TelemetryHandler` appends to reach the JSONL stream, and
  `FermixOpik` subscribes to the same five events — the run opens its OWN ROOT
  trace on `session_start`, closes it on `session_complete`/`session_error`, and
  records pause and resume as phase spans inside it. The run is never nested:
  the session is keyed by conversation and outlives the turn, so `parent_session`
  is correlation only (see docs/TELEMETRY_CONTRACT.md).
  """

  alias FermixCore.Telemetry

  @trace_event_definitions [
    %{
      event: [:fermix, :computer_use, :session_start],
      trace_event: "computer_use_session_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: [:fermix, :computer_use, :session_complete],
      trace_event: "computer_use_session_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: [:fermix, :computer_use, :session_error],
      trace_event: "computer_use_session_error",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: [:fermix, :computer_use, :session_pause],
      trace_event: "computer_use_session_pause",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: [:fermix, :computer_use, :session_resume],
      trace_event: "computer_use_session_resume",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @type meta :: %{
          required(:session_id) => String.t(),
          required(:agent) => String.t(),
          required(:mode) => atom(),
          optional(:parent_session) => String.t() | nil,
          optional(:origin) => atom()
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @spec session_start(meta()) :: :ok
  def session_start(meta) when is_map(meta), do: emit(:session_start, %{}, base(meta))

  @spec session_complete(meta(), %{actions: non_neg_integer(), duration_ms: non_neg_integer()}) ::
          :ok
  def session_complete(meta, measurements) when is_map(meta) and is_map(measurements) do
    emit(:session_complete, measurements, base(meta))
  end

  @spec session_error(meta(), term()) :: :ok
  def session_error(meta, reason) when is_map(meta) do
    emit(:session_error, %{}, Map.put(base(meta), :reason, Telemetry.preview(reason)))
  end

  # Pause and resume are part of the lifecycle, not actions: the operator took
  # the seat back, or gave it up again, and a trace that shows only start and
  # complete cannot say why nothing was dispatched in between.
  @spec session_pause(meta()) :: :ok
  def session_pause(meta) when is_map(meta), do: emit(:session_pause, %{}, base(meta))

  @spec session_resume(meta()) :: :ok
  def session_resume(meta) when is_map(meta), do: emit(:session_resume, %{}, base(meta))

  defp base(meta) do
    %{
      agent: Map.get(meta, :agent, "computer_use"),
      session_id: Map.fetch!(meta, :session_id),
      mode: Map.get(meta, :mode)
    }
    |> maybe_put(:parent_session, Map.get(meta, :parent_session))
    |> maybe_put(:origin, Map.get(meta, :origin))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(name, measurements, metadata) do
    :telemetry.execute([:fermix, :computer_use, name], measurements, metadata)
  end
end
