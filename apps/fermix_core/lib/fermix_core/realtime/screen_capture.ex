defmodule FermixCore.Realtime.ScreenCapture do
  @moduledoc """
  Owns ONE compux driver instance dedicated to screen-feed capture, and nothing
  else. It makes no decision about cadence, change-gating, or health — it takes a
  capture request, blocks on the sidecar, and reports the result to its owner
  (`Realtime.ScreenFeed`).

  Three hard reasons this is its own process rather than a call into the
  per-conversation `ComputerUse.Session` or an inline call in `ScreenFeed`
  (M9.5 §4.1):

    * **Action budget.** Every `ComputerUse.Session` action increments the
      model's `max_actions` budget (80). A 2 s feed cadence would exhaust it in
      160 s of watching and then starve the model's own clicks.
    * **Contention.** That session serializes classify/execute, so a slow capture
      would delay actuation. Feed captures must never queue behind (or in front
      of) the model's actions.
    * **Port ownership + blocking receive.** `Compux.PortDriver.execute/2` waits
      for the reply IN THE CALLING PROCESS, and Port messages are delivered to
      the process that opened the Port. Keeping both here leaves `ScreenFeed`
      responsive to `stop` while a capture is stalled, and lets a wedged capture
      be killed without taking the feed — or the voice call — down.

  One capture at a time: requests are `cast`s and this process is busy while a
  capture is in flight, so the feed (which owns pacing) never issues a second.
  Stage C replaces the per-request `screenshot` with compux's streaming
  `watch_frames` on this same dedicated port — the one place that changes.
  """

  use GenServer, restart: :temporary

  alias Compux.Protocol

  require Logger

  @type result :: {:ok, %{mime_type: String.t(), data: binary()}} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Ask for one capture. The reply is sent to the owner as
  `{:screen_capture, seq, result}` — a cast, so a wedged sidecar can never block
  the caller's loop.
  """
  @spec request(GenServer.server(), non_neg_integer()) :: :ok
  def request(server, seq) when is_integer(seq) and seq >= 0 do
    GenServer.cast(server, {:capture, seq})
  end

  @doc "Stop the capture process, which stops the driver (killing the sidecar)."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  catch
    # Already gone (feed teardown races its own capture crash) — idempotent.
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    display = Keyword.fetch!(opts, :display)
    {driver_mod, driver_opts} = Keyword.fetch!(opts, :driver)

    case driver_mod.start(driver_opts) do
      {:ok, driver_state} ->
        Process.flag(:trap_exit, true)

        {:ok,
         %{
           owner: owner,
           display: display,
           driver_mod: driver_mod,
           driver_state: driver_state
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:capture, seq}, state) do
    send(state.owner, {:screen_capture, seq, capture(state)})
    {:noreply, state}
  end

  # A late sidecar response arriving after a prior capture timed out. Responses
  # match by Port order (no request ids in the protocol), so a stale one would
  # desync onto the next capture — drain it, exactly as `ComputerUse.Session` does.
  @impl true
  def handle_info({port, {:data, _data}}, %{driver_state: %{port: port}} = state) do
    Logger.debug("screen_capture: dropping stale sidecar response after a prior timeout")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{driver_state: %{port: port}} = state) do
    Logger.warning("screen_capture: sidecar exited (status #{status}); stopping capture")
    {:stop, {:shutdown, {:sidecar_exited, status}}, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(message, state) do
    Logger.debug("screen_capture: ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Always release the sidecar: compux's `stop/1` closes the Port AND SIGKILLs
    # the OS process, which is the difference between a clean teardown and a
    # leaked client wedging ScreenCaptureKit system-wide.
    state.driver_mod.stop(state.driver_state)
    :ok
  end

  defp capture(state) do
    with {:ok, request} <- Protocol.validate(screenshot_params(state.display)),
         {:ok, response} <- state.driver_mod.execute(state.driver_state, request) do
      decode_frame(response)
    end
  end

  # A read-only `screenshot`, encoded as JPEG. This is the load-bearing difference
  # between a feed and a freeze: compux's default PNG of a full desktop measured
  # 756 KB on a 3840x1080 display (≈1 MB base64), and pushing that through the
  # session's socket every couple of seconds stalled the call and then tore it
  # down. The same frame at quality 60 is ~58 KB — a 13x reduction — for a loss no
  # one can see at this cadence, since the feed exists to answer "what changed",
  # not to be read closely (a precision look is a `computer_use` screenshot).
  #
  # Only the ENCODING changes. Sent dimensions feed compux's `sent_scale`, the
  # inverse that maps a click back to the desktop, so a size cap here would
  # silently move every coordinate; frames stay in the same space as every other
  # capture.
  @jpeg_quality 60

  defp screenshot_params(display) do
    %{"action" => "screenshot", "display" => display, "jpeg_quality" => @jpeg_quality}
  end

  defp decode_frame(%{"data" => data, "mime" => mime}) when is_binary(data) and is_binary(mime) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, %{mime_type: mime, data: bytes}}
      :error -> {:error, :invalid_base64_frame}
    end
  end

  defp decode_frame(_response), do: {:error, :missing_frame_data}
end
