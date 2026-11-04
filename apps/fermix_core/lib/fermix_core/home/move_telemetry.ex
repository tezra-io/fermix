defmodule FermixCore.Home.MoveTelemetry do
  @moduledoc """
  Emitter for `[:fermix, :home, :move]` (M75 §17): a move's two lifecycle
  bookends on each side, `:started` and `:finished`. A move has no agent
  session (the owner starts it, and no model is called), so like a snapshot
  run it carries no `session_id`: `Trace.TelemetryHandler` records each as a
  `home_move` row in `agent_event`, keyed on the side, and the Opik exporter
  does not subscribe. The move id is the correlation id both sides share.
  Registered per `docs/TELEMETRY_CONTRACT.md`; never hand-roll this event.

  Measurements: `duration_ms` (since the side's own start, 0 on `:started`).
  Metadata, a fixed allowlist: `phase` (`:started`, `:finished`), `side`
  (`:source`, `:candidate`), `move_id`, `epoch` (the epoch the move left or
  reached, nil when unknown), `result` (`:done`, `:aborted` or `:failed` on
  `:finished`, nil on `:started`) and a derived `error_class` (the reason's
  atom, or a tagged tuple's atom head, else `:unclassified`; nil unless
  failed or aborted). The reason never rides: the phase file holds the
  sentence the owner reads.
  """

  @event [:fermix, :home, :move]

  @type side :: :source | :candidate

  @doc "The event name."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "A side's move started; answers the monotonic start for `finished/5`."
  @spec started(side(), String.t(), pos_integer() | nil) :: integer()
  def started(side, move_id, epoch) when side in [:source, :candidate] and is_binary(move_id) do
    :telemetry.execute(@event, %{duration_ms: 0}, %{
      phase: :started,
      side: side,
      move_id: move_id,
      epoch: epoch,
      result: nil,
      error_class: nil
    })

    System.monotonic_time(:millisecond)
  end

  @doc "A side's move ended: `:done`, or `{:aborted, reason}` / `{:failed, reason}`."
  @spec finished(side(), String.t(), pos_integer() | nil, term(), integer()) :: :ok
  def finished(side, move_id, epoch, outcome, started_ms)
      when side in [:source, :candidate] and is_binary(move_id) and is_integer(started_ms) do
    :telemetry.execute(
      @event,
      %{duration_ms: System.monotonic_time(:millisecond) - started_ms},
      %{
        phase: :finished,
        side: side,
        move_id: move_id,
        epoch: epoch,
        result: result(outcome),
        error_class: error_class(outcome)
      }
    )
  end

  defp result(:done), do: :done
  defp result({:aborted, _reason}), do: :aborted
  defp result({:failed, _reason}), do: :failed

  defp error_class(:done), do: nil
  defp error_class({_ended, reason}) when is_atom(reason), do: reason

  defp error_class({_ended, reason}) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp error_class({_ended, _reason}), do: :unclassified
end
