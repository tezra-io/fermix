defmodule FermixCore.Browser.Handoff.Sweeper do
  @moduledoc """
  Deletes the cookies of expired browser hand-offs (M75 D18): every 60 s,
  `Browser.Handoff.sweep/1` takes each hand-off whose expiry has passed out of
  the owner profile's running Chrome and out of the ledger. With no Chrome
  running there is nothing to delete them from; they stay in the ledger until
  the next Chrome on the profile starts, which deletes them before it serves
  anything (`Browser.Handoff.purge_on_launch/2`).

  **Primary only** (`Home.Role`): a device stores no hand-off.

  The clock and the timer are injected (`:now`, `:timer`), so tests deliver a
  tick by hand; `timer_enabled: false` plans none (a test tree). A sweep that
  fails is logged with its reason and tried again at the next tick.
  """

  use GenServer

  alias FermixCore.Browser.Handoff

  require Logger

  @interval_ms 60_000

  @doc "How often the sweeper looks for expired hand-offs."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc """
  Starts the sweeper. `opts`: `:name`, `:timer_enabled`, `:timer` (a 2-arity
  `send_after`, given the message and the delay), and `:sweep_opts`, passed to
  every sweep (`:home`, `:now`, `:devtools`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      timer: timer(opts),
      sweep_opts: Keyword.get(opts, :sweep_opts, []),
      token: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info({:sweep, token}, %{token: token} = state) do
    case Handoff.sweep(state.sweep_opts) do
      {:ok, _deleted} ->
        :ok

      {:error, reason} ->
        Logger.error("browser hand-off: the expired cookies were not deleted: #{inspect(reason)}")
    end

    {:noreply, schedule(state)}
  end

  def handle_info({:sweep, _stale}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.warning("browser hand-off sweeper: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  defp schedule(%{timer: nil} = state), do: state

  defp schedule(state) do
    token = make_ref()
    state.timer.({:sweep, token}, @interval_ms)
    %{state | token: token}
  end

  defp timer(opts) do
    cond do
      Keyword.get(opts, :timer_enabled, true) == false -> nil
      timer = Keyword.get(opts, :timer) -> timer
      true -> &send_after/2
    end
  end

  defp send_after(message, delay), do: Process.send_after(self(), message, delay)
end
