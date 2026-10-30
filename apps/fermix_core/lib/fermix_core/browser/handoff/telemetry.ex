defmodule FermixCore.Browser.Handoff.Telemetry do
  @moduledoc """
  Emitter for `[:fermix, :browser, :handoff]`: one point event per browser
  hand-off operation (M75 D18). A hand-off runs no agent session (the owner
  starts it at a terminal, and the primary stores, wipes and expires its
  cookies on its own), so it carries no `session_id`: `Trace.TelemetryHandler`
  maps it to a `browser_handoff` row in `agent_event`, and the Opik exporter
  does not subscribe (no session to nest under). Registered per
  `docs/TELEMETRY_CONTRACT.md`; never hand-roll this event elsewhere.

  Measurements: `duration_ms` and `cookies` (how many cookies the operation
  moved, stored or deleted). Metadata, a fixed allowlist: `op` (`sent` on the
  desktop; `stored`, `wiped` and `expired` on the primary), `result` (`ok` or
  `failed`), `sites` (how many sites) and a derived `error_class` (the
  reason's atom, or a tagged tuple's atom head, else `unclassified`; nil when
  ok). Never a site's name, a cookie's name or its value.
  """

  @event [:fermix, :browser, :handoff]
  @ops [:sent, :stored, :wiped, :expired]

  @doc "The event name."
  @spec event() :: [atom()]
  def event, do: @event

  @doc """
  Emits one operation that started at `started_ms` (monotonic): `facts` names
  how many `sites` and `cookies` it covered.
  """
  @spec emit(atom(), :ok | {:failed, term()}, map(), integer()) :: :ok
  def emit(op, outcome, facts, started_ms)
      when op in @ops and is_map(facts) and is_integer(started_ms) do
    duration = System.monotonic_time(:millisecond) - started_ms

    :telemetry.execute(@event, %{duration_ms: duration, cookies: Map.get(facts, :cookies, 0)}, %{
      op: op,
      result: result(outcome),
      sites: Map.get(facts, :sites, 0),
      error_class: error_class(outcome)
    })
  end

  defp result(:ok), do: :ok
  defp result({:failed, _reason}), do: :failed

  defp error_class(:ok), do: nil
  defp error_class({:failed, reason}) when is_atom(reason), do: reason

  defp error_class({:failed, reason}) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp error_class({:failed, _reason}), do: :unclassified
end
