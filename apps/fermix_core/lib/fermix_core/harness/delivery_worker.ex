defmodule FermixCore.Harness.DeliveryWorker do
  @moduledoc """
  Permanent GenServer draining the harness pending-delivery outbox (design §9.1).

  Every tick (default 30s, self-rearming) it pulls up to `@max_rows_per_tick` due
  pending deliveries from `Ledger.pending_deliveries/2` (already excludes active
  rows and rows whose `next_delivery_at` is in the future), makes ONE bounded
  send attempt each through `Harness.Delivery.deliver/2`, and records the outcome
  durably:

    * success (`:sent` / `:skipped`) → `delivered`;
    * failure → `delivery_attempts + 1`, exponential-backoff `next_delivery_at`
      (base 30s, cap 30 min), `last_delivery_error`; a `{:rate_limited, ms}` error
      honors `ms` as the floor;
    * at `delivery_max_attempts` or past `delivery_max_age_hours` → `dead_letter`
      (surfaced by doctor and `list_coding_runs`).

  The immediate first attempt happens inline on terminalization (Manager); this
  worker owns every subsequent attempt — it naturally sees a row only because the
  Manager marks `delivered` only on success. A failing tick (e.g. the query
  itself errors) re-arms no sooner than `@min_rearm_ms` so the worker never
  hot-loops.

  Draining is **unconditional** (spec §5): the outbox is finished in-flight work,
  not a new admission, so `Config.enabled?` does NOT gate it — flipping the
  harness off must never strand pending deliveries with no owner (the at-least-
  once / dead-letter guarantee). Only `:timer_enabled` (a test seam, mirroring the
  Manager) governs whether ticks self-arm.
  """

  use GenServer

  require Logger

  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Delivery
  alias FermixCore.Harness.Ledger

  @default_interval_ms 30_000
  @min_rearm_ms 5_000
  @max_rows_per_tick 10
  @backoff_base_ms 30_000
  @backoff_cap_ms 1_800_000
  @error_max 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok, schedule_first_tick(build_state(opts))}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, rearm(run_tick(state))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- State --------------------------------------------------------------

  defp build_state(opts) do
    %{
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      repo: Keyword.get(opts, :repo, FermixCore.Memory.Repo),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_rows_per_tick: Keyword.get(opts, :max_rows_per_tick, @max_rows_per_tick),
      max_attempts: Keyword.get(opts, :max_attempts, Config.delivery_max_attempts()),
      max_age_hours: Keyword.get(opts, :max_age_hours, Config.delivery_max_age_hours()),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      timer: nil
    }
  end

  defp schedule_first_tick(%{timer_enabled?: true} = state) do
    %{state | timer: arm(state.interval_ms)}
  end

  defp schedule_first_tick(state), do: state

  defp rearm(%{timer_enabled?: true} = state) do
    %{state | timer: arm(max(state.interval_ms, @min_rearm_ms))}
  end

  defp rearm(state), do: state

  defp arm(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  # --- Tick ---------------------------------------------------------------

  defp run_tick(state) do
    now = state.now_fn.()

    case Ledger.pending_deliveries(now, server: state.repo) do
      {:ok, rows} -> drain(rows, state, now)
      {:error, reason} -> log_tick_error(reason, state)
    end
  end

  defp drain(rows, state, now) do
    rows
    |> Enum.take(state.max_rows_per_tick)
    |> Enum.each(&process_row(&1, state, now))

    state
  end

  defp process_row(row, state, now) do
    case Delivery.deliver(row, state.delivery_opts) do
      {:ok, _sent_or_skipped} -> mark_delivered(row, state, now)
      {:error, reason} -> handle_failure(row, state, now, reason)
    end
  end

  defp mark_delivered(row, state, now) do
    write_delivery(row, state, %{delivery_status: "delivered", delivered_at: now})
  end

  defp handle_failure(row, state, now, reason) do
    attempts = Map.get(row, :delivery_attempts, 0) + 1

    if dead?(row, attempts, state, now) do
      dead_letter(row, state, reason)
    else
      reschedule(row, attempts, state, now, reason)
    end
  end

  defp dead?(row, attempts, state, now) do
    attempts >= state.max_attempts or aged_out?(row, state, now)
  end

  defp aged_out?(row, state, now) do
    case Map.get(row, :created_at) do
      %DateTime{} = created_at ->
        DateTime.diff(now, created_at, :second) > state.max_age_hours * 3600

      _absent ->
        false
    end
  end

  defp dead_letter(row, state, reason) do
    write_delivery(row, state, %{
      delivery_status: "dead_letter",
      last_delivery_error: bounded_error(reason)
    })
  end

  defp reschedule(row, attempts, state, now, reason) do
    next_at = DateTime.add(now, backoff_ms(attempts, reason), :millisecond)

    write_delivery(row, state, %{
      delivery_attempts: attempts,
      next_delivery_at: next_at,
      last_delivery_error: bounded_error(reason)
    })
  end

  # Exponential backoff, base 30s, capped at 30 min. A rate-limited error honors
  # its retry-after `ms` as the floor (also capped). The shift is bounded so the
  # intermediate never overflows before the cap applies.
  defp backoff_ms(attempts, reason) do
    shift = min(attempts - 1, 20)
    base = min(@backoff_base_ms * Bitwise.bsl(1, shift), @backoff_cap_ms)

    case reason do
      {:rate_limited, ms} when is_integer(ms) and ms > 0 -> min(max(base, ms), @backoff_cap_ms)
      _other -> base
    end
  end

  defp write_delivery(row, state, fields) do
    case Ledger.mark_delivery(Map.get(row, :id), fields, server: state.repo) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "harness delivery update failed for #{Map.get(row, :id)}: #{inspect(reason)}"
        )
    end
  end

  defp bounded_error(reason) do
    reason
    |> inspect()
    |> String.slice(0, @error_max)
  end

  defp log_tick_error(reason, state) do
    Logger.warning("harness delivery worker tick failed: #{inspect(reason)}")
    state
  end
end
