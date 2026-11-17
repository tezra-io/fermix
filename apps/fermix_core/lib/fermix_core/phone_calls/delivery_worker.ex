defmodule FermixCore.PhoneCalls.DeliveryWorker do
  @moduledoc """
  Permanent GenServer owning every report attempt after a call's hand-off
  (M94 §09, §10), mirroring `Harness.DeliveryWorker` narrowly.

  Every tick (default 30 s, self-rearming, never sooner than `@min_rearm_ms`)
  it reads up to `@max_rows_per_tick` terminal rows whose report is pending and
  due (`Ledger.pending_reports/3`: a backoff, or the Manager's hand-off lease,
  keeps a row out until it ends), makes ONE bounded send each
  (`PhoneCalls.Delivery.deliver/2`) and records the result on the row:

    * sent → `written`;
    * failed → `delivery_attempts + 1`, an exponential backoff (base 30 s, cap
      30 min, `backoff_ms/1`) and the error's words;
    * the failure that reaches `Limits.max_report_delivery_attempts/0` (the
      hand-off's inline send counts as the first) → `delivery_unconfirmed`,
      the row's visible end state; nothing sends it again.

  It only ever sends text: a report is never retried by dialing again. It
  serves no calls, so its bounded sends may block its own ticks. Draining is
  unconditional: turning phone calls off strands no report.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.Timeouts

  @default_interval_ms 30_000
  @min_rearm_ms 5_000
  @max_rows_per_tick 10
  @backoff_base_ms 30_000
  @backoff_cap_ms 1_800_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The wait before attempt `attempts + 1`: 30 s doubling, capped at 30 min."
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(attempts) when is_integer(attempts) and attempts >= 1 do
    shift = min(attempts - 1, 20)
    min(@backoff_base_ms * Bitwise.bsl(1, shift), @backoff_cap_ms)
  end

  @impl true
  def init(opts) do
    {:ok, schedule(build_state(opts))}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, state |> run_tick() |> rearm()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- state ---------------------------------------------------------------------

  defp build_state(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    %{
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      repo_opts:
        Repo.periodic_opts(repo, Keyword.get(opts, :repo_timeout_ms, Timeouts.repo_call())),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_attempts: Limits.max_report_delivery_attempts(),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0)
    }
  end

  defp schedule(%{timer_enabled?: true} = state) do
    Process.send_after(self(), :tick, state.interval_ms)
    state
  end

  defp schedule(state), do: state

  defp rearm(%{timer_enabled?: true} = state) do
    Process.send_after(self(), :tick, max(state.interval_ms, @min_rearm_ms))
    state
  end

  defp rearm(state), do: state

  # --- tick ----------------------------------------------------------------------

  defp run_tick(state) do
    now = state.now_fn.()

    case Ledger.pending_reports(now, @max_rows_per_tick, state.repo_opts) do
      {:ok, rows} ->
        Enum.each(rows, &attempt(&1, state, now))
        state

      {:error, reason} ->
        Logger.warning("phone call delivery tick failed: #{inspect(reason)}")
        state
    end
  end

  defp attempt(row, state, now) do
    case Delivery.deliver(row, state.delivery_opts) do
      {:ok, :sent} -> write(row, state, %{report_status: "written", delivered_at: now})
      {:error, reason} -> failed(row, state, now, reason)
    end
  end

  defp failed(row, state, now, reason) do
    attempts = (Map.get(row, :delivery_attempts) || 0) + 1
    error = Delivery.bounded_error(reason)

    if attempts >= state.max_attempts do
      Logger.warning("phone call #{row.id} report unconfirmed after #{attempts} attempts")

      write(row, state, %{
        report_status: "delivery_unconfirmed",
        delivery_attempts: attempts,
        last_delivery_error: error
      })
    else
      write(row, state, %{
        delivery_attempts: attempts,
        next_delivery_at: DateTime.add(now, backoff_ms(attempts), :millisecond),
        last_delivery_error: error
      })
    end
  end

  defp write(row, state, fields) do
    case Ledger.mark_report(row.id, fields, state.repo_opts) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("phone call #{row.id} report state not recorded: #{inspect(reason)}")
    end
  end
end
