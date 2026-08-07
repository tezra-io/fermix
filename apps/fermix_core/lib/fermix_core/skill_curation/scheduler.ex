defmodule FermixCore.SkillCuration.Scheduler do
  @moduledoc """
  The skill-curation clock (MILESTONE_26_SKILL_CURATION §6.2): a deliberately
  tiny GenServer that ticks every six hours and fires `SkillCuration.run_cycle/1`
  when the cadence (or a state-enforced retry) is due. Missed ticks while the
  laptop slept simply run at the next tick — at a 15-day cadence there is no
  staleness-skip concept.

  All durable state lives in the `skill_curation_state` row; the claim inside
  `run_cycle/1` (with stale-claim recovery) is the concurrency gate, so a tick
  firing against an already-running cycle resolves to `:concurrent_run`
  harmlessly. The cycle Task is monitored inside `run_cycle/1` itself — this
  process never blocks on a cycle.
  """

  use GenServer

  require Logger

  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration

  @tick_interval_ms :timer.hours(6)
  # The first tick fires shortly after boot so the state row (and with it the
  # 15-day cadence anchor) exists from the first session — a host whose daemon
  # sessions never last a full interval must still start the clock (the
  # first-run-on-a-fresh-machine pitfall family).
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
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      tick_interval_ms: Keyword.get(opts, :tick_interval_ms, @tick_interval_ms),
      run_cycle_fun: Keyword.get(opts, :run_cycle_fun, &SkillCuration.run_cycle/1),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true)
    }

    # All repo work happens on ticks, never in init — boot stays decoupled
    # from memory.db availability.
    schedule_tick(state, @initial_tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    maybe_fire(state, DateTime.utc_now())
    schedule_tick(state, state.tick_interval_ms)
    {:noreply, state}
  end

  defp schedule_tick(%{timer_enabled?: false}, _delay_ms), do: :ok

  defp schedule_tick(_state, delay_ms) do
    Process.send_after(self(), :tick, delay_ms)
  end

  defp maybe_fire(state, now) do
    case Repo.ensure_skill_curation_state(now, server: state.repo) do
      {:ok, row} ->
        if due?(row, now), do: start_cycle(state)
        :ok

      {:error, reason} ->
        # The child only starts with memory enabled, so this is a genuine
        # storage fault worth surfacing — and the next tick retries.
        Logger.warning("skill_curation tick could not read state: #{inspect(reason)}")
        :ok
    end
  end

  defp due?(row, now) do
    cadence_due?(row.last_cycle_at, now) or retry_due?(row.retry_at, now)
  end

  defp cadence_due?(%DateTime{} = last_cycle_at, now) do
    DateTime.diff(now, last_cycle_at, :second) >= SkillCuration.cycle_days() * 86_400
  end

  defp cadence_due?(nil, _now), do: false

  defp retry_due?(%DateTime{} = retry_at, now), do: DateTime.compare(now, retry_at) != :lt
  defp retry_due?(nil, _now), do: false

  defp start_cycle(state) do
    run_cycle_fun = state.run_cycle_fun
    repo = state.repo
    task_supervisor = state.task_supervisor

    # Fire-and-forget: run_cycle/1 monitors its own pipeline Task and always
    # terminalizes state; the stale-claim sweep is the SIGKILL backstop.
    {:ok, _pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        [trigger: :scheduled, repo: repo, task_supervisor: task_supervisor]
        |> run_cycle_fun.()
        |> log_cycle_result()
      end)

    :ok
  end

  # run_cycle terminalizes its own state; this log is the only place a
  # pre-claim storage refusal (ensure/claim failing) becomes visible.
  defp log_cycle_result({:ok, _counts}), do: :ok
  defp log_cycle_result({:error, :concurrent_run}), do: :ok

  defp log_cycle_result({:error, reason}) do
    Logger.warning("skill_curation scheduled cycle refused: #{inspect(reason)}")
    :ok
  end
end
