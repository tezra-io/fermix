defmodule FermixCore.Watch.Session do
  @moduledoc """
  A supervised, per-conversation watch: it runs the observe→decide→(optional
  act)→report loop for a watch task and delivers updates back to the conversation
  that started it, until stopped or bounded.

  The loop lives here; the two EFFECTS are injected so this module is pure
  control-flow and fully testable without a model or a channel:

    * `decide.(%{task, cycle})` — run ONE observation+decision (in production, a
      bounded `AgentLoop.run/1` that looks at the watched target via
      computer_use/browser and returns what, if anything, to say). Returns
      `{:report, text}` (deliver it), `:quiet` (nothing relevant), or
      `{:error, reason}` (logged; the watch continues).
    * `deliver.(text)` — surface a report to the origin conversation (in
      production, `Jobs.Delivery`). Side effect only.

  Each cycle runs in a monitored Task so a blocking model call never wedges the
  session — `stop_watch`/teardown stays responsive mid-cycle. Bounded by
  max-duration, a max-cycle budget, and a cooldown between cycles.

  `restart: :temporary`: an on-demand per-conversation resource must not be
  resurrected by its `:one_for_one` supervisor (the `ComputerUse.Session` lesson).
  """

  use GenServer, restart: :temporary

  require Logger

  @default_max_duration_ms 30 * 60 * 1000
  @default_max_cycles 200
  # Floor gap between cycles so a fast-returning `decide` can't spin hot.
  @default_cooldown_ms 1_000
  # Stop + notify the user if this many decisions fail in a row — a persistent
  # failure (e.g. a non-vision main model that can't read a screenshot, or broken
  # delivery) must not silently spin for the whole cycle budget.
  @max_consecutive_errors 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Tear the watch down."
  @spec abort(GenServer.server()) :: :ok
  def abort(server), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    max_duration_ms = Keyword.get(opts, :max_duration_ms, @default_max_duration_ms)

    state = %{
      conversation_key: Keyword.fetch!(opts, :conversation_key),
      task: Keyword.fetch!(opts, :task),
      decide: Keyword.fetch!(opts, :decide),
      deliver: Keyword.fetch!(opts, :deliver),
      origin: Keyword.get(opts, :origin, :interactive),
      session_id: Keyword.get(opts, :session_id) || mint_session_id(),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      max_cycles: Keyword.get(opts, :max_cycles, @default_max_cycles),
      cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
      cycles: 0,
      consecutive_errors: 0,
      cycle_task: nil,
      max_duration_timer: Process.send_after(self(), :max_duration, max_duration_ms)
    }

    {:ok, state, {:continue, :cycle}}
  end

  @impl true
  def handle_continue(:cycle, state), do: begin_or_stop(state)

  @impl true
  def handle_info(:next_cycle, state), do: begin_or_stop(state)

  # The current cycle's decision came back.
  def handle_info({ref, result}, %{cycle_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | cycle_task: nil, cycles: state.cycles + 1}
    continue_or_stop(apply_decision(result, state))
  end

  # The cycle Task crashed — treat as a failed decision (bounded like any error).
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{cycle_task: %{ref: ref}} = state) do
    state = %{state | cycle_task: nil, cycles: state.cycles + 1}
    continue_or_stop(apply_decision({:error, {:cycle_crashed, reason}}, state))
  end

  def handle_info(:max_duration, state) do
    Logger.debug("watch #{state.session_id}: max duration reached; stopping")
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    Logger.debug("watch #{state.session_id}: ignoring #{inspect(message)}")
    {:noreply, state}
  end

  # Start a cycle if there's budget left; otherwise stop the watch.
  defp begin_or_stop(%{cycles: n, max_cycles: max} = state) when n >= max do
    Logger.debug("watch #{state.session_id}: cycle budget (#{max}) reached; stopping")
    {:stop, :normal, state}
  end

  defp begin_or_stop(state), do: {:noreply, start_cycle(state)}

  defp start_cycle(state) do
    decide = state.decide
    task = state.task
    cycle = state.cycles

    cycle_task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        decide.(%{task: task, cycle: cycle})
      end)

    %{state | cycle_task: cycle_task}
  end

  defp continue_or_stop({:continue, state}), do: {:noreply, schedule_next(state)}
  defp continue_or_stop({:stop, state}), do: {:stop, :normal, state}

  # A cycle's outcome. A report/quiet resets the failure streak; a failure (or an
  # unexpected result, or a crash) increments it and, past the cap, stops the
  # watch and tells the user rather than spinning silently to the cycle budget.
  defp apply_decision({:report, text}, state) when is_binary(text) do
    state.deliver.(text)
    {:continue, %{state | consecutive_errors: 0}}
  end

  defp apply_decision(:quiet, state), do: {:continue, %{state | consecutive_errors: 0}}

  # The watcher decided it cannot do this watch (e.g. it needs the host screen but
  # computer-use is off) — tell the user why and stop now, no retries.
  defp apply_decision({:stop_watch, reason}, state) when is_binary(reason) do
    message =
      if reason == "",
        do: "I've stopped watching — I can't do this watch.",
        else: "I've stopped watching — #{reason}"

    state.deliver.(message)
    {:stop, state}
  end

  defp apply_decision({:error, reason}, state) do
    Logger.warning("watch #{state.session_id}: decision failed #{inspect(reason)}")
    maybe_stop_on_errors(bump_errors(state), reason)
  end

  defp apply_decision(other, state) do
    Logger.warning("watch #{state.session_id}: unexpected decision #{inspect(other)}")
    maybe_stop_on_errors(bump_errors(state), other)
  end

  defp bump_errors(state), do: %{state | consecutive_errors: state.consecutive_errors + 1}

  defp maybe_stop_on_errors(%{consecutive_errors: n} = state, reason)
       when n >= @max_consecutive_errors do
    state.deliver.("I had to stop watching — the last #{n} checks failed (#{inspect(reason)}).")
    {:stop, state}
  end

  defp maybe_stop_on_errors(state, _reason), do: {:continue, state}

  defp schedule_next(state) do
    Process.send_after(self(), :next_cycle, state.cooldown_ms)
    state
  end

  defp mint_session_id do
    "watch_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
