defmodule FermixCore.ComputerUse.Telemetry do
  @moduledoc """
  Single emitter for `[:fermix, :computer_use, ...]` session lifecycle events.

  A computer-use session is a new run-type (docs/TELEMETRY_CONTRACT.md): it owns a
  long-lived OS-driver process and spans many actions across the agent loop, so it
  needs its own traceable lifecycle. Only the session lifecycle (which has no
  request/response analog) lives here — each ACTION is a tool call emitted through
  the shared `FermixCore.Tools.Telemetry` so it reuses the existing JSONL/Opik
  aggregation. Every event carries the session's `session_id` (`cua_<id>`) and,
  when spawned by a main turn, its `parent_session`, so a whole session reassembles
  into one nested trace.

  The matching `fermix_opik` aggregation for these event names lands with the
  registration/wiring increment (the run-type does not fire at runtime until the
  tool is registered).
  """

  alias FermixCore.Telemetry

  @type meta :: %{
          required(:session_id) => String.t(),
          required(:agent) => String.t(),
          required(:mode) => atom(),
          optional(:parent_session) => String.t() | nil,
          optional(:origin) => atom()
        }

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
