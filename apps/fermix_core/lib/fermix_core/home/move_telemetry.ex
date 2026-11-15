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

  Between the bookends each phase of each side logs one info line
  (`phase/4`, `phase_ended/3`), so an owner, or Doctor, can tell the
  transfer from the archiving: the source's `capture`, `send`, `staging`
  (waiting for the candidate to restore the stream) and `commit`, and the
  candidate's `receive`, `staging` and `activation`. The line names the move
  id, the side, the phase and how it ended, when it started and ended by the
  side's clock, how long it took, and the bytes it captured, sent or
  received; never a path, a secret or a reason, which the warnings and the
  phase file carry.
  """

  require Logger

  @event [:fermix, :home, :move]

  @type side :: :source | :candidate
  @typedoc "A phase under way: what `phase_ended/3` logs, and when it started."
  @type phase :: %{
          side: side(),
          name: String.t(),
          move_id: String.t(),
          clock: (-> DateTime.t()),
          at: DateTime.t(),
          ms: integer()
        }
  @type moved :: {String.t(), non_neg_integer()} | nil

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

  @doc """
  The phase `name` of `side`'s move `move_id` starts now, by `clock` (a
  0-arity `DateTime` reader, the side's own).
  """
  @spec phase(side(), String.t(), String.t(), (-> DateTime.t())) :: phase()
  def phase(side, name, move_id, clock)
      when side in [:source, :candidate] and is_binary(name) and is_binary(move_id) and
             is_function(clock, 0) do
    %{
      side: side,
      name: name,
      move_id: move_id,
      clock: clock,
      at: clock.(),
      ms: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Logs `phase`'s one line now that it ended, `:done`, `:reused` (a capture an
  earlier attempt wrote) or `:failed`, with the bytes it moved (`{"captured" |
  "sent" | "received", count}`), or nil for none.
  """
  @spec phase_ended(phase(), :done | :reused | :failed, moved()) :: :ok
  def phase_ended(%{side: side, name: name, move_id: move_id} = phase, outcome, moved)
      when outcome in [:done, :reused, :failed] do
    took = (System.monotonic_time(:millisecond) - phase.ms) / 1_000

    Logger.info(
      "move #{move_id} #{side}: #{name} #{outcome}, #{iso(phase.at)} to " <>
        "#{iso(phase.clock.())} (#{:erlang.float_to_binary(took, decimals: 1)} s)" <>
        moved_text(moved)
    )
  end

  defp moved_text(nil), do: ""

  defp moved_text({how, bytes})
       when how in ~w(captured sent received) and is_integer(bytes) and bytes >= 0,
       do: ", #{bytes} bytes #{how}"

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp result(:done), do: :done
  defp result({:aborted, _reason}), do: :aborted
  defp result({:failed, _reason}), do: :failed

  defp error_class(:done), do: nil
  defp error_class({_ended, reason}) when is_atom(reason), do: reason

  defp error_class({_ended, reason}) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp error_class({_ended, _reason}), do: :unclassified
end
