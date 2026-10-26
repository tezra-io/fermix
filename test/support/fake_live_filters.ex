defmodule FermixTestSupport.FakeLiveFilters do
  @moduledoc """
  A stand-in `Cues.LiveFilters` for the stream worker's tests: it takes the
  casts `Cues.LiveFilters.watchers/3` and `offer/3` send and tells the test
  (the `:test` start option) what the stream handed it, judging nothing:
  `{:live_watchers, source_ref, specs}` and `{:live_offer, source_ref,
  offers}`. Start it with `start_supervised!/1` and pass its pid as `live:`.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test))
  end

  @impl true
  def init(test) when is_pid(test), do: {:ok, test}

  @impl true
  def handle_cast({:watchers, source_ref, specs}, test) do
    send(test, {:live_watchers, source_ref, specs})
    {:noreply, test}
  end

  def handle_cast({:offer, source_ref, offers}, test) do
    send(test, {:live_offer, source_ref, offers})
    {:noreply, test}
  end
end
