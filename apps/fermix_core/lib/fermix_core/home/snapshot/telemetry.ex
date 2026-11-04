defmodule FermixCore.Home.Snapshot.Telemetry do
  @moduledoc """
  Emitter for `[:fermix, :home, :snapshot]`: one point event per target per
  snapshot run, with its outcome. A run has no agent session (the scheduler
  starts it, or the owner's `home.snapshots.run`), so it carries no
  `session_id`, like a plugin distribution op: `Trace.TelemetryHandler` maps it
  to a `home_snapshot` row in `agent_event`, and the Opik exporter does not
  subscribe (no session to nest under). Registered per
  `docs/TELEMETRY_CONTRACT.md`; never hand-roll this event elsewhere.

  Measurements: `duration_ms` (the whole run, capture included) and `bytes`
  (the encrypted snapshot, 0 when the capture failed). Metadata, a fixed
  allowlist: `target` (`s3`), `result` (`verified`, `failed`, or `waiting`
  for a target that will take it at a later run), `epoch` (nil when the
  capture failed), and a derived `error_class` (the reason's atom, or a tagged
  tuple's atom head, else `unclassified`; nil when verified). The reason itself never rides: a vendor's answer can carry
  anything, and the status file holds the sentence.
  """

  @event [:fermix, :home, :snapshot]

  @doc "The event name."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "Emits one target's outcome of a run that started at `started_ms` (monotonic)."
  @spec emit(String.t(), :verified | {:failed | :waiting, term()}, map(), integer()) :: :ok
  def emit(target, outcome, facts, started_ms)
      when is_binary(target) and is_map(facts) and is_integer(started_ms) do
    duration = System.monotonic_time(:millisecond) - started_ms

    :telemetry.execute(@event, %{duration_ms: duration, bytes: Map.get(facts, :size) || 0}, %{
      target: target,
      result: result(outcome),
      epoch: Map.get(facts, :epoch),
      error_class: error_class(outcome)
    })
  end

  defp result(:verified), do: :verified
  defp result({:failed, _reason}), do: :failed
  defp result({:waiting, _reason}), do: :waiting

  defp error_class(:verified), do: nil
  defp error_class({_kind, reason}) when is_atom(reason), do: reason

  defp error_class({_kind, reason}) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp error_class({_kind, _reason}), do: :unclassified
end
