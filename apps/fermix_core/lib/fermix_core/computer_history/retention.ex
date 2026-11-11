defmodule FermixCore.ComputerHistory.Retention do
  @moduledoc """
  The 48-hour sweep (MILESTONE_32 §6.3, §12; M97 §8.1). A tiny always-supervised
  GenServer that, on its tick, keeps both halves of computer history bounded,
  **independent of `enabled?()`**, so a spool left behind by a disable still
  drains by the 48h horizon and never accumulates silently:

    * **this machine's raw spool** (`ComputerHistory.Spool`, `:spool`): every
      event older than the retention window goes, counting those never sent to
      the home, and the byte ceiling backs the time bound;
    * **the home's notes** (`Memory.Repo`, `:repo`, nil on an engine that is not
      the home): the read audit is row-capped, and the purge and pause intervals
      no machine can still hold a raw event for are pruned.

  Presence is unconditional; *work* is tick-gated (the TemporalScheduler /
  HarnessSupervisor "always present, timers flag-gated" precedent). All store
  work happens on a tick, never in `init`, so boot stays decoupled from either
  store's availability. Sweep failure is **loud** (an error log), never silent
  accumulation.
  """

  use GenServer

  require Logger

  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Memory.Repo
  alias FermixCore.Timeouts

  @retention_window_ms :timer.hours(48)
  @tick_interval_ms :timer.hours(1)
  # The first tick fires shortly after boot so a boot sweep runs promptly on a
  # daemon whose sessions never last a full interval (the fresh-machine family).
  @initial_tick_ms :timer.seconds(5)

  # Byte-ceiling backstop (§22.8): the spool is time-bounded by the 48h window,
  # but a pathological event source could still balloon it inside that window —
  # so a size bound backs the time bound. Estimated content bytes; deleting
  # under it is data loss inside the retention promise, so it logs a WARNING.
  @spool_byte_ceiling 64 * 1024 * 1024
  # The access audit (agent reads) has no time sweep — its value is depth — so
  # it is row-capped instead (Code Rule 2).
  @access_row_cap 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :repo_timeout_ms, Timeouts.repo_call())
    repo = Keyword.get(opts, :repo, Repo)
    spool = Keyword.get(opts, :spool, Spool)

    state = %{
      window_ms: Keyword.get(opts, :window_ms, @retention_window_ms),
      byte_ceiling: Keyword.get(opts, :byte_ceiling, @spool_byte_ceiling),
      access_row_cap: Keyword.get(opts, :access_row_cap, @access_row_cap),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      # A store that does not answer in time is an error each sweep logs; the next
      # tick sweeps again, and every sweep is idempotent.
      spool_opts: spool && [server: spool, on_timeout: :error, timeout: timeout],
      repo_opts: repo && Repo.periodic_opts(repo, timeout)
    }

    schedule_tick(state, @initial_tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now_ms = System.system_time(:millisecond)
    _ = sweep_machine(state, now_ms)
    _ = sweep_home(state, now_ms)
    schedule_tick(state, state.tick_interval_ms)
    {:noreply, state}
  end

  defp sweep_machine(%{spool_opts: nil}, _now_ms), do: :ok

  defp sweep_machine(state, now_ms) do
    _ = sweep(now_ms, state.window_ms, state.spool_opts)
    sweep_bytes(state.byte_ceiling, state.spool_opts)
  end

  defp sweep_home(%{repo_opts: nil}, _now_ms), do: :ok

  defp sweep_home(state, now_ms) do
    _ = cap_access(state.access_row_cap, state.repo_opts)
    prune_intervals(now_ms - state.window_ms, state.repo_opts)
  end

  @doc """
  Delete this machine's raw events older than `now_ms - window_ms`, counting
  those never sent. Public so a tick and a test drive the same code with an
  injected clock; `opts` are `Spool`'s (`server:`). Returns the counts or logs
  and returns the error (loud, never swallowed).
  """
  @spec sweep(integer(), non_neg_integer(), keyword()) ::
          {:ok, %{deleted: non_neg_integer(), unsent: non_neg_integer()}} | {:error, term()}
  def sweep(now_ms, window_ms \\ @retention_window_ms, opts \\ [])
      when is_integer(now_ms) and is_integer(window_ms) and is_list(opts) do
    case Spool.sweep_expired(now_ms - window_ms, opts) do
      {:ok, %{deleted: 0}} = ok ->
        ok

      {:ok, %{deleted: deleted, unsent: 0}} = ok ->
        Logger.debug("computer_history retention swept #{deleted} expired event(s)")
        ok

      {:ok, %{deleted: deleted, unsent: unsent}} = ok ->
        Logger.warning(
          "computer_history retention swept #{deleted} expired event(s), #{unsent} of them " <>
            "never sent to the home to be summarized"
        )

        ok

      {:error, reason} = error ->
        Logger.error("computer_history retention sweep failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  The byte-ceiling backstop: delete the oldest raw events beyond
  `ceiling_bytes` of estimated content. Firing is data loss inside the 48h
  retention promise, so a non-zero delete is a WARNING, never a debug line.
  """
  @spec sweep_bytes(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_bytes(ceiling_bytes \\ @spool_byte_ceiling, opts \\ [])
      when is_integer(ceiling_bytes) and ceiling_bytes > 0 and is_list(opts) do
    case Spool.sweep_over_bytes(ceiling_bytes, opts) do
      {:ok, 0} = ok ->
        ok

      {:ok, deleted} = ok ->
        Logger.warning(
          "computer_history spool exceeded the #{ceiling_bytes}-byte ceiling; " <>
            "dropped the oldest #{deleted} event(s) before their 48h retention"
        )

        ok

      {:error, reason} = error ->
        Logger.error("computer_history byte-ceiling sweep failed: #{inspect(reason)}")
        error
    end
  end

  # Bound the access audit to its newest rows. Quiet on success — capping audit
  # depth is expected housekeeping, not data loss inside a promise.
  defp cap_access(max_rows, opts) do
    case Repo.computer_history_cap_access_rows(max_rows, opts) do
      {:ok, _deleted} ->
        :ok

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.error("computer_history access-audit cap failed: #{inspect(reason)}")
        :ok
    end
  end

  # The home's purge and pause intervals that no machine can still hold a raw
  # event for: quiet on success, as the cap.
  defp prune_intervals(cutoff_ts, opts) do
    case Repo.computer_history_home(:prune_home_intervals, [cutoff_ts], opts) do
      {:ok, _pruned} ->
        :ok

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.error("computer_history interval prune failed: #{inspect(reason)}")
        :ok
    end
  end

  defp schedule_tick(%{timer_enabled?: false}, _delay_ms), do: :ok
  defp schedule_tick(_state, delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
