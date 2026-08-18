defmodule FermixCore.ComputerHistory.Retention do
  @moduledoc """
  The 48-hour spool sweep (MILESTONE_32 §6.3, §12). A tiny always-supervised
  GenServer that, on its tick, deletes every `computer_history_events` row
  older than the retention window — **independent of `enabled?()`**, so a spool
  left behind by a disable still drains by the 48h horizon and never
  accumulates silently.

  Presence is unconditional; *work* is tick-gated (the TemporalScheduler /
  HarnessSupervisor "always present, timers flag-gated" precedent). All repo
  work happens on a tick, never in `init`, so boot stays decoupled from
  `memory.db` availability — the first sweep runs on the first tick, after
  `Repo` is guaranteed up. Sweep failure is **loud** (an error log), never
  silent accumulation.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo

  @retention_window_ms :timer.hours(48)
  @tick_interval_ms :timer.hours(1)
  # The first tick fires shortly after boot so a boot sweep runs promptly on a
  # daemon whose sessions never last a full interval (the fresh-machine family).
  @initial_tick_ms :timer.seconds(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.get(opts, :repo, Repo),
      window_ms: Keyword.get(opts, :window_ms, @retention_window_ms),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true)
    }

    schedule_tick(state, @initial_tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = sweep(state.repo, System.system_time(:millisecond), state.window_ms)
    schedule_tick(state, state.tick_interval_ms)
    {:noreply, state}
  end

  @doc """
  Delete spool events older than `now_ms - window_ms`. Public so a tick and a
  test drive the same code with an injected clock; returns the deleted count or
  logs and returns the error (loud, never swallowed).
  """
  @spec sweep(module() | pid(), integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sweep(repo, now_ms, window_ms \\ @retention_window_ms)
      when is_integer(now_ms) and is_integer(window_ms) do
    cutoff_ts = now_ms - window_ms

    case Repo.computer_history_sweep_expired_events(cutoff_ts, server: repo) do
      {:ok, 0} = ok ->
        ok

      {:ok, deleted} = ok ->
        Logger.debug("computer_history retention swept #{deleted} expired event(s)")
        ok

      {:error, :disabled} = disabled ->
        # Memory persistence off: no store to sweep. Not a fault.
        disabled

      {:error, reason} = error ->
        Logger.error("computer_history retention sweep failed: #{inspect(reason)}")
        error
    end
  end

  defp schedule_tick(%{timer_enabled?: false}, _delay_ms), do: :ok
  defp schedule_tick(_state, delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
