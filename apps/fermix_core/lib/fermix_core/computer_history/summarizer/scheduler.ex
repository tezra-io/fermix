defmodule FermixCore.ComputerHistory.Summarizer.Scheduler do
  @moduledoc """
  Periodic driver for the on-device summarizer (MILESTONE_32 §10), cloned from
  `SkillCuration.Scheduler`: a tiny GenServer ticking on a fixed interval, first
  tick shortly after boot, a monitored Task per cycle, and an atomic
  singleton-claim with stale-claim recovery. All repo work happens on ticks,
  never in `init`.

  It is the DynamicSupervisor's runtime child, started when history is enabled
  and a summarization path exists (the enable controller). A cycle that pauses
  or errors still releases the claim, so a held claim never wedges the loop; a
  daemon killed mid-cycle is recovered by the stale-claim window on the next
  tick.
  """

  use GenServer

  require Logger

  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.Memory.Repo

  @tick_interval_ms :timer.minutes(30)
  @initial_tick_ms :timer.seconds(10)
  @claim_stale_after_ms :timer.minutes(30)
  @cycle_timeout_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.get(opts, :repo, Repo),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      claim_stale_after_ms: Keyword.get(opts, :claim_stale_after_ms, @claim_stale_after_ms),
      cycle_timeout_ms: Keyword.get(opts, :cycle_timeout_ms, @cycle_timeout_ms),
      run_cycle_fun: Keyword.get(opts, :run_cycle_fun, &Summarizer.run_cycle/1),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true)
    }

    schedule_tick(state, @initial_tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    maybe_fire(state, DateTime.utc_now())
    schedule_tick(state, state.tick_interval_ms)
    {:noreply, state}
  end

  defp maybe_fire(state, now) do
    case Repo.computer_history_claim_cycle(now, state.claim_stale_after_ms, server: state.repo) do
      {:ok, _claimed} ->
        run_and_release(state)

      {:error, :concurrent_run} ->
        :ok

      {:error, reason} ->
        Logger.warning("computer_history summarizer claim failed: #{inspect(reason)}")
        :ok
    end
  end

  defp run_and_release(state) do
    result = run_monitored(state)
    _ = Repo.computer_history_release_claim(DateTime.utc_now(), server: state.repo)
    log_result(result)
  end

  # Monitored Task bounded by the cycle timeout, so a crash or hang becomes a
  # terminal error the claim release still recovers from (the SkillCuration shape).
  defp run_monitored(state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        state.run_cycle_fun.(repo: state.repo)
      end)

    case Task.yield(task, state.cycle_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crash, reason}}
      nil -> {:error, {:crash, :cycle_timeout}}
    end
  end

  defp log_result({:ok, %{memory_written: written?, events: events}}),
    do: Logger.debug("computer_history summarizer cycle: #{events} events, memory=#{written?}")

  defp log_result({:paused, reason}),
    do: Logger.info("computer_history summarizer paused: #{inspect(reason)}")

  defp log_result({:error, reason}),
    do: Logger.warning("computer_history summarizer cycle error: #{inspect(reason)}")

  defp schedule_tick(%{timer_enabled?: false}, _delay_ms), do: :ok
  defp schedule_tick(_state, delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
