defmodule FermixOpik.Sender do
  @moduledoc """
  Serializes trace deliveries to Opik off the agent's hot path.

  Closed traces are cast here and shipped one at a time. The `Aggregator` checks
  this process's mailbox length before casting and drops (with a log) once it
  exceeds `max_queue`, so a slow or unreachable Opik can never apply backpressure
  to Fermix — observability must not degrade the thing it observes.
  """

  use GenServer

  require Logger

  alias FermixOpik.Client

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec deliver(GenServer.server(), %{trace: map(), spans: [map()]}) :: :ok
  def deliver(server \\ __MODULE__, closed), do: GenServer.cast(server, {:deliver, closed})

  @impl true
  def init(opts) do
    {:ok, %{config: Keyword.fetch!(opts, :config), client: Keyword.get(opts, :client, Client)}}
  end

  @impl true
  def handle_cast({:deliver, closed}, state) do
    try do
      _result = state.client.send_trace(state.config, closed)
    rescue
      e ->
        Logger.warning("FermixOpik.Sender: dropping trace — #{Exception.message(e)}")
    end

    {:noreply, state}
  end
end
