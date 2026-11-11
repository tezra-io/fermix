defmodule FermixCore.ComputerHistory.Summarizer.Scheduler do
  @moduledoc """
  The periodic driver of computer history's two halves (MILESTONE_32 §10; M97
  §8.1), cloned from `SkillCuration.Scheduler`: a tiny GenServer ticking on a
  fixed interval, first tick shortly after boot, a monitored Task per cycle.

  - **Where this engine records** (`:uplink` given and `:recording_fun` true):
    `ComputerHistory.Sittings` sends each closed sitting to the home, under an
    atomic claim in this machine's store with stale-claim recovery, so two
    daemons on one machine never send the same sitting at once.
  - **Where this engine is the home** (`:repo` given): the daily roll-up across
    every machine (`Summarizer.run_rollup/1`), and telling each connected
    computer of the purges and pauses from chat it has not applied
    (`ComputerHistory.Delivery`), which is how one that was away gets them.

  A Mac that is its own home runs both; a computer whose home is a server runs
  the first; the server runs the second. A cycle that pauses or errors still
  releases the claim, so a held claim never wedges the loop. Every store call
  happens on ticks, never in `init`.
  """

  use GenServer

  require Logger

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Delivery
  alias FermixCore.ComputerHistory.Sittings
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.Memory.Repo

  # Sittings are sent when they CLOSE, not on the clock (§24.2), so the tick is
  # only a poll: cheap when nothing closed, and five minutes is what makes
  # "summarized when I stopped" feel immediate.
  @tick_interval_ms :timer.minutes(5)
  @initial_tick_ms :timer.seconds(10)
  @claim_stale_after_ms :timer.minutes(30)
  # A cycle is bounded work: up to six sittings, each one send and one answer
  # (the home's summary call included), plus at most one roll-up call. Well
  # under the stale-claim window, so a wedged cycle cannot outlive its claim.
  @cycle_timeout_ms :timer.minutes(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      spool: Keyword.get(opts, :spool, Spool),
      repo: Keyword.get(opts, :repo, Repo),
      uplink: Keyword.get(opts, :uplink),
      recording_fun: Keyword.get(opts, :recording_fun, &ComputerHistory.operative?/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      claim_stale_after_ms: Keyword.get(opts, :claim_stale_after_ms, @claim_stale_after_ms),
      cycle_timeout_ms: Keyword.get(opts, :cycle_timeout_ms, @cycle_timeout_ms),
      run_sittings_fun: Keyword.get(opts, :run_sittings_fun, &Sittings.run/1),
      run_rollup_fun: Keyword.get(opts, :run_rollup_fun, &Summarizer.run_rollup/1),
      deliver_fun: Keyword.get(opts, :deliver_fun, &Delivery.deliver/1),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true)
    }

    schedule_tick(state, @initial_tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    maybe_send(state, DateTime.utc_now())
    maybe_roll_up(state)
    schedule_tick(state, state.tick_interval_ms)
    {:noreply, state}
  end

  # -- the machine's half ------------------------------------------------------------

  defp maybe_send(%{uplink: nil}, _now), do: :ok

  defp maybe_send(state, now) do
    if state.recording_fun.(), do: claim_and_send(state, now), else: :ok
  end

  defp claim_and_send(state, now) do
    case Spool.claim(now, state.claim_stale_after_ms, server: state.spool) do
      {:ok, _claimed} ->
        result = run_monitored(state, fn -> state.run_sittings_fun.(sittings_opts(state)) end)
        _ = Spool.release(DateTime.utc_now(), server: state.spool)
        log_sittings(result)

      {:error, :concurrent_run} ->
        :ok

      {:error, reason} ->
        Logger.warning("computer_history sending claim failed: #{inspect(reason)}")
    end
  end

  defp sittings_opts(state), do: [uplink: state.uplink, spool: state.spool]

  # -- the home's half ---------------------------------------------------------------

  defp maybe_roll_up(%{repo: nil}), do: :ok

  defp maybe_roll_up(state) do
    spool = if state.uplink && state.recording_fun.(), do: state.spool, else: nil
    result = run_monitored(state, fn -> state.run_rollup_fun.(repo: state.repo, spool: spool) end)
    log_rollup(result)
    log_delivery(run_monitored(state, fn -> state.deliver_fun.(repo: state.repo) end))
  end

  # Monitored Task bounded by the cycle timeout, so a crash or hang becomes a
  # terminal error the claim release still recovers from.
  defp run_monitored(state, fun) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, fun)

    case Task.yield(task, state.cycle_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crash, reason}}
      nil -> {:error, {:crash, :cycle_timeout}}
    end
  end

  defp log_sittings({:ok, %{} = cycle}),
    do:
      Logger.debug(
        "computer_history sending cycle: #{cycle.sittings} sitting(s), #{cycle.sent} sent, " <>
          "#{cycle.notes} note(s), #{cycle.events} event(s)"
      )

  defp log_sittings({:held, reason}),
    do: Logger.info("computer_history sending held: #{inspect(reason)}")

  defp log_sittings({:error, reason}),
    do: Logger.warning("computer_history sending cycle error: #{inspect(reason)}")

  defp log_rollup(result) when result in [:ok, :skipped], do: :ok

  defp log_rollup({:paused, reason}),
    do: Logger.info("computer_history roll-up paused: #{inspect(reason)}")

  defp log_rollup({:error, reason}),
    do: Logger.warning("computer_history roll-up error: #{inspect(reason)}")

  defp log_delivery(%{failed: []}), do: :ok

  defp log_delivery(%{failed: failed}),
    do:
      Logger.info(
        "computer_history: not yet told of a purge or pause: #{Enum.join(failed, ", ")}"
      )

  defp log_delivery({:error, reason}),
    do: Logger.warning("computer_history delivery error: #{inspect(reason)}")

  defp schedule_tick(%{timer_enabled?: false}, _delay_ms), do: :ok
  defp schedule_tick(_state, delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
