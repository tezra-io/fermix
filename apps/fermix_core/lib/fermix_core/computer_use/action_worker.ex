defmodule FermixCore.ComputerUse.ActionWorker do
  @moduledoc """
  The one process that owns a computer-use session's driver — and therefore its
  Port to the sidecar — and runs one action at a time inside it (M42 slice 2 §6).

  **Why it is not the `Session`.** A single execute makes up to FOUR blocking
  driver calls (the courtesy idle probe, the micro-defer wait, the action, and the
  post-action check), each with a 30 s budget. While the `Session` owned the driver
  it sat inside those calls, so `/pause`, `paused?`, `action_count` and teardown
  all queued behind the very action they exist to interrupt. The Session now
  admits an action, hands it here, and answers its caller from `handle_info` when
  the outcome comes back.

  **The pipeline did not move.** `Session.run_pipeline/2` is the same linear code
  it always was; it is called here with the driver keys merged into the state
  snapshot the Session sent, and it returns the same `{:reply, …}` / `{:stop, …}`
  tuple the Session applies. Keeping it there keeps one reader's path through an
  action, and keeps this module to the one thing it is for: owning the driver.

  **Ownership.** `driver_mod.start/1` runs in `init/1`, so the Port is opened here
  and every `{port, …}` message and the sidecar's exit status arrive here. The
  worker traps exits, so a `Session` that dies — gracefully, on a poison reset, or
  killed outright — still leaves a process that runs `terminate/2` and stops the
  driver. That stop closes the Port AND kills the OS process, which is the
  difference between a clean teardown and a leaked sidecar wedging screen capture
  system-wide.
  """

  use GenServer, restart: :temporary

  alias FermixCore.ComputerUse.Session

  require Logger

  # How long `stop/1` waits for the worker to finish what it is doing before it
  # gives up waiting. The common case is microseconds (the worker is idle); the
  # only slow case is a driver call already under way, which cannot be interrupted
  # until the wire carries a control channel. Kept well under the supervisor's own
  # 5 s child shutdown so the `Session`'s lifecycle bookend is always emitted.
  @stop_grace_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Whether macOS is delivering this session's synthetic input, as answered by the
  one-time start-up probe. Read once by the `Session` at init; the probe itself is
  a driver call, so it runs where the driver is.
  """
  @spec input_control?(GenServer.server()) :: boolean()
  def input_control?(worker), do: GenServer.call(worker, :input_control?)

  @doc """
  Run one finalized request. `exec_state` is the slice of session state the
  pipeline reads and writes; the outcome is sent to the session that started this
  worker as `{:action_result, result}`. A cast, because the whole point is that
  the caller does not block on the sidecar.
  """
  @spec execute(GenServer.server(), map(), map()) :: :ok
  def execute(worker, request, exec_state) when is_map(request) and is_map(exec_state) do
    GenServer.cast(worker, {:execute, request, exec_state})
  end

  @doc """
  Stop the worker, which stops the driver. Bounded: if the worker is inside a
  driver call it is left to finish and stop itself — it already holds this exit
  signal, and its own `terminate/2` is what reaps the sidecar, so killing it here
  would trade a bounded wait for a leaked OS process.
  """
  @spec stop(pid()) :: :ok
  def stop(worker) when is_pid(worker) do
    ref = Process.monitor(worker)
    Process.exit(worker, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^worker, _reason} -> :ok
    after
      @stop_grace_ms ->
        Process.demonitor(ref, [:flush])
        Logger.warning("computer_use: action worker still busy at teardown; it stops on its own")
        :ok
    end
  end

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    {driver_mod, driver_opts} = Keyword.fetch!(opts, :driver)
    Process.flag(:trap_exit, true)

    case driver_mod.start(driver_opts) do
      {:ok, driver_state} ->
        {:ok,
         %{
           session: session,
           driver_mod: driver_mod,
           driver_state: driver_state,
           input_control?: probe_input_control(driver_mod, driver_state)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:input_control?, _from, state), do: {:reply, state.input_control?, state}

  @impl true
  def handle_cast({:execute, request, exec_state}, state) do
    result = Session.run_pipeline(request, with_driver(exec_state, state))
    send(state.session, {:action_result, drop_driver(result)})
    {:noreply, state}
  end

  # A late/stale sidecar response arriving after a prior call timed out. Responses
  # match by Port order (no request id today), so a stale one would desync onto the
  # next request — drop it. Matches only this driver's own port; a stub driver has
  # none, so its state simply never matches.
  @impl true
  def handle_info({port, {:data, _data}}, %{driver_state: %{port: port}} = state) do
    Logger.debug("computer_use: dropping stale sidecar response after a prior timeout")
    {:noreply, state}
  end

  # Reported as the raw status, not classified: the `Session` owns the meaning of
  # an exit status (75 is compux's designed capture-stall self-reap), because that
  # is where the capture-wedge counter and the lifecycle bookend read it.
  def handle_info({port, {:exit_status, status}}, %{driver_state: %{port: port}} = state) do
    Logger.warning("computer_use: sidecar exited (status #{status}); stopping the action worker")
    {:stop, {:shutdown, {:sidecar_exit_status, status}}, state}
  end

  # The session (the only process linked to this one) went away. Stop with its
  # reason so `terminate/2` releases the sidecar.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Logger.debug("computer_use: action worker ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state.driver_mod.stop(state.driver_state)
    :ok
  end

  # KNOWN GAP, left open deliberately: a probe that TIMED OUT (rather than answered
  # an error) leaves the Port desynchronised — pairing is positional, so its late
  # frame becomes the first action's reply — and this still logs and continues.
  # Refusing here would fail the session's init and re-design the fail-open gate in
  # `Session.check_input_control/2`, and the whole desync class disappears once the
  # wire carries request ids. Every driver call INSIDE an execute is routed to the
  # poison reset; this one start-up call is the exception, and it is so on purpose.
  defp probe_input_control(driver_mod, driver_state) do
    case driver_mod.execute(driver_state, %{"action" => "probe"}) do
      {:ok, %{"input_control" => false}} ->
        false

      {:ok, _probe} ->
        true

      {:error, reason} ->
        Logger.warning(
          "computer-use input-control probe failed (treated as granted): " <> inspect(reason)
        )

        true
    end
  end

  defp with_driver(exec_state, state) do
    Map.merge(exec_state, %{driver_mod: state.driver_mod, driver_state: state.driver_state})
  end

  # The driver handle never crosses back: the session holds no Port, and merging a
  # stale copy of one into its state is exactly the confusion this split removes.
  defp drop_driver({:reply, reply, exec_state}),
    do: {:reply, reply, Map.drop(exec_state, [:driver_mod, :driver_state])}

  defp drop_driver({:stop, reason, reply, exec_state}),
    do: {:stop, reason, reply, Map.drop(exec_state, [:driver_mod, :driver_state])}
end
