defmodule FermixOpik.Aggregator do
  @moduledoc """
  GenServer that drives `FermixOpik.Aggregation` for live telemetry.

  The `Reporter` casts raw events here (cheap, off the emitting process). This
  server folds them into the session/trace tree and, whenever a top-level run
  finishes, hands the assembled trace to the `Sender`. A periodic sweep
  force-flushes traces whose root never signalled completion, and a queue-length
  guard on the `Sender` keeps a stalled Opik from ever building unbounded state.
  """

  use GenServer

  require Logger

  alias FermixOpik.Aggregation
  alias FermixOpik.Sender

  @sweep_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Fold one telemetry event (called from the Reporter)."
  @spec record(GenServer.server(), [atom()], map(), map(), DateTime.t()) :: :ok
  def record(server \\ __MODULE__, event, measurements, metadata, at) do
    GenServer.cast(server, {:event, event, measurements, metadata, at})
  end

  @impl true
  def init(opts) do
    state = %{
      agg:
        Aggregation.new(
          project: Keyword.fetch!(opts, :project),
          ttl_ms: Keyword.get(opts, :ttl_ms, 120_000)
        ),
      sender: Keyword.get(opts, :sender, Sender),
      max_queue: Keyword.get(opts, :max_queue, 500)
    }

    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_cast({:event, event, measurements, metadata, at}, state) do
    {agg, closed} =
      Aggregation.apply_event(state.agg, event, measurements, metadata, %{
        at: at,
        mono: System.monotonic_time(:microsecond)
      })

    deliver_all(closed, state)
    {:noreply, %{state | agg: agg}}
  end

  @impl true
  def handle_info(:sweep, state) do
    {agg, closed} = Aggregation.sweep(state.agg, System.monotonic_time(:microsecond))
    deliver_all(closed, state)
    schedule_sweep()
    {:noreply, %{state | agg: agg}}
  end

  @impl true
  def terminate(_reason, state) do
    {_agg, closed} = Aggregation.drain(state.agg)
    deliver_all(closed, state)
    :ok
  end

  defp deliver_all(closed, state), do: Enum.each(closed, &deliver(&1, state))

  defp deliver(closed, state) do
    if backed_up?(state.sender, state.max_queue) do
      Logger.warning("FermixOpik sender backlog over #{state.max_queue}; dropping a trace")
    else
      Sender.deliver(state.sender, closed)
    end
  end

  defp backed_up?(sender, max_queue) do
    case GenServer.whereis(sender) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} -> len > max_queue
          _nil -> false
        end

      _missing ->
        true
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
