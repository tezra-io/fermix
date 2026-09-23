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

  **Ownership.** `driver_mod.start/1` runs in `init/1`, so this process is the
  driver's owner, and the sidecar's death is reported here as
  `{:compux_sidecar_exit, transport, status}`. That message is load-bearing: the
  capture-stall self-reap flushes its response and only THEN exits 75, so the exit
  arrives with nothing outstanding and no reply could ever have carried it. The
  worker traps exits, so a `Session` that dies — gracefully, on a poison reset, or
  killed outright — still leaves a process that runs `terminate/2` and stops the
  driver. That stop closes the Port AND kills the OS process, which is the
  difference between a clean teardown and a leaked sidecar wedging screen capture
  system-wide.
  """

  use GenServer, restart: :temporary

  alias FermixCore.ComputerUse.Capabilities
  alias FermixCore.ComputerUse.Session

  require Logger

  # What the on-screen indicator's buttons arrive as (M42 slice 5 §3.3). The
  # helper has ALREADY applied each one to its own gate before it tells us, so
  # these are notifications of a hold that is in place, never requests to install
  # one.
  @operator_events %{
    "operator_pause" => :pause,
    "operator_resume" => :resume,
    "operator_stop" => :stop
  }

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
  The `{driver_module, driver_state}` a caller needs to send a CONTROL while this
  worker is blocked inside an action.

  Read once, by the `Session`, while this worker is still idle at start-up. It is
  sound to copy because a `Compux.Driver` handle is opaque and immutable by
  contract — every `execute/2`, `control/2` and `stop/1` takes the same term
  `start/1` returned, and for the production driver it is the transport's pid.
  Sending the control from the Session rather than through here is the whole
  point: a Pause that has to queue behind the action it is pausing is not a pause.
  """
  @spec control_handle(GenServer.server()) :: {module(), Compux.Driver.state()}
  def control_handle(worker), do: GenServer.call(worker, :control_handle)

  @doc """
  What the helper this worker is talking to says it can do, from the `hello` it
  answered at the handshake.

  Asked by the `Session` at start, and only where a surface that depends on the
  answer is switched on: a capability the model is about to be offered has to be
  a fact about THIS helper. The transport answers a second `hello` from its
  cached identity, so this costs no round trip, and a helper that will not answer
  is read as advertising nothing.
  """
  @spec capabilities(GenServer.server()) :: Capabilities.t()
  def capabilities(worker), do: GenServer.call(worker, :capabilities)

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

  def handle_call(:control_handle, _from, state),
    do: {:reply, {state.driver_mod, state.driver_state}, state}

  def handle_call(:capabilities, _from, state),
    do: {:reply, read_capabilities(state.driver_mod, state.driver_state), state}

  @impl true
  def handle_cast({:execute, request, exec_state}, state) do
    result = Session.run_pipeline(request, with_driver(exec_state, state))
    send(state.session, {:action_result, drop_driver(result)})
    {:noreply, state}
  end

  # The sidecar ended. The transport sends this once, after completing everything
  # outstanding, so a caller waiting on an action already has its reply. Reported
  # onward as the raw status rather than classified: the `Session` owns what an
  # exit status MEANS (75 is compux's designed capture-stall self-reap), because
  # that is where the capture-wedge counter and the lifecycle bookend read it.
  @impl true
  def handle_info({:compux_sidecar_exit, _transport, status}, state) do
    Logger.warning("computer_use: sidecar ended (#{inspect(status)}); stopping the action worker")
    {:stop, {:shutdown, {:sidecar_exit_status, status}}, state}
  end

  # The on-screen indicator's buttons (M42 slice 5 §3.3), decoded and forwarded by
  # the transport. Handed to the `Session`, which owns what a pause, a resume and
  # a stop MEAN — the same place the chat commands reach, so one hold has one
  # implementation whichever surface asked for it.
  #
  # Delivered here whether this worker is idle or inside an action, exactly like
  # the exit notice, and for the same reason it is safe: the helper applied the
  # hold to its own gate BEFORE sending this, so nothing is being driven while
  # the message waits. An action already under way therefore answers its caller
  # first and the hold lands behind it, which is the order slice 2 audited.
  def handle_info({:compux_session_event, _transport, %{"kind" => "indicator"} = event}, state) do
    case Map.fetch(@operator_events, event["event"]) do
      {:ok, control} ->
        send(state.session, {:operator_control, control})

      :error ->
        # Loud rather than silent: a dropped Stop is a person pressing a button
        # and watching nothing happen, which is the one failure this family
        # exists to prevent.
        Logger.warning("computer_use: unknown indicator event #{inspect(event["event"])}")
    end

    {:noreply, state}
  end

  # Another family the sidecar speaks unasked (`request_deferred` is the one that
  # exists today). Named rather than left to the catch-all, so the log says what
  # arrived instead of "unexpected message".
  def handle_info({:compux_session_event, _transport, event}, state) do
    Logger.debug("computer_use: ignoring a sidecar session event (#{inspect(event["kind"])})")
    {:noreply, state}
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

  # Absent or failed probe reads as GRANTED: only the explicit denied state is
  # refused, so a driver that predates the probe keeps working and a broken probe
  # cannot brick looking. A probe that times out is no longer a hazard beyond that
  # — the wire correlates a reply to the request that asked for it, so its late
  # frame is dropped by id and can never answer the first action.
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

  # A helper that would not answer `hello` advertises nothing: the conservative
  # reading is the same shape as a real one (`Capabilities.none/0`), so every
  # consumer reads one map rather than remembering a `nil`. A driver double that
  # predates the handshake lands here too, which is right — a double proves
  # nothing about what the shipped helper can do.
  defp read_capabilities(driver_mod, driver_state) do
    case driver_mod.execute(driver_state, %{"action" => "hello"}) do
      {:ok, identity} when is_map(identity) ->
        Capabilities.from_identity(identity)

      other ->
        Logger.warning(
          "computer-use helper did not report its capabilities (none assumed): " <> inspect(other)
        )

        Capabilities.none()
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
