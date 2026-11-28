defmodule FermixCore.PhoneCalls.DeliveryWorker do
  @moduledoc """
  Permanent GenServer owning every report attempt after a call's hand-off
  (M94 §09, §10), mirroring `Harness.DeliveryWorker` narrowly.

  Every tick (`Limits.delivery_tick_ms/0`, self-rearming, never sooner than
  `Limits.delivery_min_rearm_ms/0`) it reads up to
  `Limits.max_reports_per_tick/0` terminal rows whose report is pending and
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

  A home with durable memory off has no ledger to drain: that is decided once,
  as the worker starts (the Repo's own answer, which holds for the life of
  this subtree), and no tick is ever armed; it is said once. A tick whose
  read fails is logged once when ticks start failing and once when they work
  again (the "Cascade roots" rule), never on every tick.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Call.Printable
  alias FermixCore.PhoneCalls.Delivery
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.Timeouts

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The wait before attempt `attempts + 1`: `Limits.delivery_backoff_ms/0`
  doubling, capped at `Limits.delivery_backoff_cap_ms/0`.
  """
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(attempts) when is_integer(attempts) and attempts >= 1 do
    shift = min(attempts - 1, 20)
    min(Limits.delivery_backoff_ms() * Bitwise.bsl(1, shift), Limits.delivery_backoff_cap_ms())
  end

  @impl true
  def init(opts) do
    {:ok, schedule(build_state(opts))}
  end

  @impl true
  def handle_info(:tick, %{store?: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    {:noreply, state |> run_tick() |> rearm()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A crash report prints the reason: a tick's exception can quote the report
  # row it was sending (the destination, the brief, what was said), so it
  # prints as its codes (`Call.Printable.reason/1`). The state and the `:tick`
  # message hold no call's words. OTP reports the crash's stack past this
  # callback, with the top frame's arguments of a function clause it fails.
  @impl true
  def format_status(status) when is_map(status),
    do: Map.replace_lazy(status, :reason, &Printable.reason/1)

  # --- state ---------------------------------------------------------------------

  defp build_state(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    %{
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      store?: Repo.enabled?(server: repo),
      timer: nil,
      failed_ticks: 0,
      repo_opts:
        Repo.periodic_opts(repo, Keyword.get(opts, :repo_timeout_ms, Timeouts.repo_call())),
      interval_ms: Keyword.get(opts, :interval_ms, Limits.delivery_tick_ms()),
      max_attempts: Limits.max_report_delivery_attempts(),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0)
    }
  end

  defp schedule(%{timer_enabled?: true, store?: false} = state) do
    Logger.info("phone call reports: durable memory is off, so there are none to deliver")
    state
  end

  defp schedule(%{timer_enabled?: true} = state),
    do: %{state | timer: Process.send_after(self(), :tick, state.interval_ms)}

  defp schedule(state), do: state

  defp rearm(%{timer_enabled?: true} = state),
    do: %{
      state
      | timer:
          Process.send_after(
            self(),
            :tick,
            max(state.interval_ms, Limits.delivery_min_rearm_ms())
          )
    }

  defp rearm(state), do: state

  # --- tick ----------------------------------------------------------------------

  defp run_tick(state) do
    now = state.now_fn.()

    case Ledger.pending_reports(now, Limits.max_reports_per_tick(), state.repo_opts) do
      {:ok, rows} ->
        Enum.each(rows, &attempt(&1, state, now))
        tick_works(state)

      {:error, reason} ->
        tick_failed(reason, state)
    end
  end

  defp tick_failed(reason, %{failed_ticks: 0} = state) do
    Logger.warning("phone call delivery ticks are failing: #{inspect(reason)}")
    %{state | failed_ticks: 1}
  end

  defp tick_failed(_reason, state), do: %{state | failed_ticks: state.failed_ticks + 1}

  defp tick_works(%{failed_ticks: 0} = state), do: state

  defp tick_works(state) do
    Logger.info("phone call delivery ticks work again after #{state.failed_ticks} failed ticks")
    %{state | failed_ticks: 0}
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
