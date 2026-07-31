defmodule FermixCore.Realtime.ScreenFeed do
  @moduledoc """
  Continuous screen perception for one realtime voice call (M9.5 §4.1): it paces
  capture, drops frames that show nothing new, and hands the survivors to its
  owning `SessionServer`, which appends them to the live provider session as
  passive context.

  **Why this is not the reverted `watch` construct.** Watch ran a bounded
  `AgentLoop.run` per cycle — perception through agent TURNS, which exhausted
  max-iterations within a minute. Here a frame is context, not a turn: the
  streaming session has no iteration cap, images never trigger a response by
  themselves, and the user's own next utterance is the free trigger that makes
  the newest frames matter. This process therefore never calls a model.

  It owns the three gates the naive design conflated:

    * **capture gate** — a paced pull (never a busy loop) with at most ONE
      capture in flight; a tick that fires mid-capture coalesces instead of
      queueing, and an identical frame (SHA-256 of the raw bytes) is dropped, so
      a static screen costs zero tokens.
    * **transport gate** — adaptive cadence (faster while the user speaks, slower
      once the screen has been still) under a hard frames-per-minute ceiling.
    * **health gate** — the global `ComputerUse.CaptureHealth` breaker is
      consulted BEFORE every capture and fed the typed outcome of every capture,
      so a wedged host stops receiving fresh sidecars. Only a real frame clears a
      strike; a wedge that persists past `@wedge_grace_ms` stops the feed loudly
      rather than retrying forever.

  Every bound is an internal constant, not a config knob (M9.5 §7): these are
  implementation truths, not operator decisions, and the one operator-facing
  setting is `[fermix_core.realtime] screen_share`.
  """

  use GenServer, restart: :temporary

  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.Realtime.ScreenCapture

  require Logger

  # Cadence. 2 s is the practical provider-side ceiling for pushed stills (a
  # faster feed buys context the model cannot use before the next turn); 1 s while
  # the user is mid-utterance so the frame they are talking ABOUT is current; 6 s
  # once the screen has held still, which keeps a quiet desktop near-free in CPU.
  @base_interval_ms 2_000
  @speaking_interval_ms 1_000
  @idle_interval_ms 6_000
  @idle_after_unchanged 3

  # Hard ceilings. `@max_frames_per_min` bounds token spend even if the screen
  # changes constantly (video, animation); `@max_capture_strikes` bounds the
  # feed's own retries; `@wedge_grace_ms` bounds how long it will wait out an open
  # breaker before giving up audibly.
  @max_frames_per_min 20
  @max_capture_strikes 3
  @wedge_grace_ms 30_000
  @minute_ms 60_000

  @type stop_reason ::
          :requested
          | {:capture_unavailable, term()}
          | {:capture_failed, term()}
          | {:capture_wedged, term()}
          | :cost

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Tell the feed whether the user is currently speaking, so it can tighten cadence
  while they talk. A cast — the session must never block on the feed.
  """
  @spec set_speaking(GenServer.server(), boolean()) :: :ok
  def set_speaking(server, speaking?) when is_boolean(speaking?) do
    GenServer.cast(server, {:speaking, speaking?})
  end

  @doc """
  Tell the feed whether the model is mid-action (a tool call in flight). While
  acting, its precision view comes from the action's own check images, so ambient
  frames of the same screen are pure token cost — capture pauses, and the flip
  back to false triggers an immediate catch-up frame. A cast, like `set_speaking`.
  """
  @spec set_acting(GenServer.server(), boolean()) :: :ok
  def set_acting(server, acting?) when is_boolean(acting?) do
    GenServer.cast(server, {:acting, acting?})
  end

  @doc "Stop the feed for `reason`, releasing the capture sidecar."
  @spec stop(GenServer.server(), stop_reason()) :: :ok
  def stop(server, reason \\ :requested) do
    GenServer.stop(server, {:shutdown, reason})
  catch
    # Already gone (a teardown racing the feed's own stop) — idempotent.
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    display = Keyword.fetch!(opts, :display)
    # Before any capture is linked, so a capture that dies the instant it starts
    # arrives as a trapped EXIT (one strike) instead of killing the feed.
    Process.flag(:trap_exit, true)

    state = %{
      owner: owner,
      display: display,
      # Injected by tests; production resolves the installed sidecar the same way
      # every other driver owner does.
      driver: Keyword.get(opts, :driver),
      capture_module: Keyword.get(opts, :capture_module, ScreenCapture),
      # A test seam, not an operator surface (same shape as the injected driver
      # and capture module): production always runs the constants above.
      intervals:
        Keyword.get(opts, :intervals, %{
          base: @base_interval_ms,
          speaking: @speaking_interval_ms,
          idle: @idle_interval_ms
        }),
      minute_ms: Keyword.get(opts, :minute_ms, @minute_ms),
      capture: nil,
      seq: 0,
      in_flight: nil,
      pending_tick?: false,
      last_hash: nil,
      unchanged_streak: 0,
      gated_out: 0,
      speaking?: false,
      acting?: false,
      strikes: 0,
      frames_sent: 0,
      minute_started_ms: now_ms(),
      minute_frames: 0,
      wedged_since: nil,
      timer: nil
    }

    # The first capture runs in a continue, NOT in init: starting the sidecar
    # includes a handshake round-trip, and `start_link/1` is called from the
    # SessionServer's own loop, which must not block on it.
    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: tick(state)

  @impl true
  def handle_cast({:speaking, speaking?}, state) do
    {:noreply, %{state | speaking?: speaking?}}
  end

  # Resuming reschedules an immediate tick so the model's first look after an
  # action sequence is fresh, not up to an idle interval stale.
  def handle_cast({:acting, false}, %{acting?: true} = state) do
    {:noreply, schedule_tick(%{state | acting?: false}, 0)}
  end

  def handle_cast({:acting, acting?}, state) do
    {:noreply, %{state | acting?: acting?}}
  end

  @impl true
  def handle_info(:tick, state), do: tick(%{state | timer: nil})

  def handle_info({:screen_capture, seq, result}, %{in_flight: seq} = state) do
    state = %{state | in_flight: nil}

    case result do
      {:ok, frame} -> capture_succeeded(frame, seq, state)
      {:error, reason} -> capture_failed(reason, state)
    end
  end

  # A result for a capture we are no longer waiting on (a restarted capture
  # process answering late). Dropping it is correct: the pacing loop owns what
  # happens next, and a stale frame must never reset the change gate.
  def handle_info({:screen_capture, _seq, _result}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{capture: pid} = state) do
    # The capture process died (sidecar exited, or it was stopped under us). Count
    # it as a capture failure so strikes + the breaker apply, then let the next
    # tick decide whether to start a fresh one.
    capture_failed(reason, %{state | capture: nil, in_flight: nil})
  end

  # The call is over. This process traps exits, so the link to the owner does NOT
  # kill it on its own — it must stand down explicitly, or a feed (and its
  # sidecar) would outlive the voice session that is the whole reason it exists.
  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state) do
    {:stop, {:shutdown, :requested}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("screen_feed: ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Always release the sidecar. `stop/1` is graceful (the capture's own
    # terminate SIGKILLs the OS process); a brutal `Process.exit(feed, :kill)`
    # skips this, the same pre-existing exposure `ComputerUse.Session` carries.
    if is_pid(state.capture), do: state.capture_module.stop(state.capture)
    report_stopped(state, stop_reason(reason))
    :ok
  end

  # ---------------------------------------------------------------- capture loop

  # Mid-action the model's eyes are its own check images; don't spend captures
  # (or budget) on ambient frames of the same screen. Keep ticking so the pause
  # ends itself even if the resume cast were ever missed.
  defp tick(%{acting?: true} = state) do
    {:noreply, schedule_tick(state, state.intervals.base)}
  end

  defp tick(state) do
    case CaptureHealth.status() do
      :ok -> capture_now(%{state | wedged_since: nil})
      {:error, {:capture_wedged, retry_in_ms}} -> wait_out_breaker(state, retry_in_ms)
    end
  end

  defp capture_now(%{in_flight: seq} = state) when is_integer(seq) do
    # One capture at a time: coalesce the tick instead of queueing work behind a
    # capture that may be stalled.
    {:noreply, %{state | pending_tick?: true}}
  end

  defp capture_now(state) do
    case ensure_capture(state) do
      {:ok, state} -> request_capture(state)
      {:error, reason} -> {:stop, {:shutdown, {:capture_unavailable, reason}}, state}
    end
  end

  defp ensure_capture(%{capture: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_capture(state) do
    with {:ok, driver} <- resolve_driver(state),
         {:ok, pid} <-
           state.capture_module.start_link(owner: self(), display: state.display, driver: driver) do
      {:ok, %{state | capture: pid}}
    end
  end

  defp resolve_driver(%{driver: nil}), do: ComputerUse.driver_spec()
  defp resolve_driver(%{driver: driver}), do: {:ok, driver}

  defp request_capture(state) do
    seq = state.seq + 1
    state.capture_module.request(state.capture, seq)
    {:noreply, %{state | seq: seq, in_flight: seq}}
  end

  # The breaker is open. A SHORT backoff is worth waiting out — the screen is
  # still there when it clears. A long one is not: sitting silently blind while
  # the model believes it is watching is the worst state to be in, so the feed
  # gives up as soon as waiting would exceed the grace window and says so.
  defp wait_out_breaker(state, retry_in_ms) do
    since = state.wedged_since || now_ms()
    waited = now_ms() - since

    if waited + retry_in_ms >= @wedge_grace_ms do
      {:stop, {:shutdown, {:capture_wedged, :grace_expired}}, state}
    else
      {:noreply, schedule_tick(%{state | wedged_since: since}, retry_in_ms + 50)}
    end
  end

  # ------------------------------------------------------------ capture outcomes

  defp capture_succeeded(frame, seq, state) do
    CaptureHealth.record_success()
    hash = :crypto.hash(:sha256, frame.data)

    state =
      %{state | strikes: 0}
      |> deliver_or_gate(frame, hash, seq)
      |> continue_after_capture()

    {:noreply, state}
  end

  defp deliver_or_gate(state, frame, hash, seq) do
    cond do
      hash == state.last_hash -> gate_unchanged(state, hash)
      rate_limited?(state) -> gate_rate_limited(state)
      true -> send_frame(state, frame, hash, seq)
    end
  end

  # Unchanged: count it and let the cadence relax. `last_hash` advances so a
  # screen that changes then holds still settles.
  defp gate_unchanged(state, hash) do
    %{
      state
      | last_hash: hash,
        gated_out: state.gated_out + 1,
        unchanged_streak: state.unchanged_streak + 1
    }
  end

  # Over the per-minute ceiling but CHANGED: count it, keep the cadence engaged,
  # and — critically — leave `last_hash` alone. Advancing it here made the feed
  # permanently blind to a change that happened during the blackout and then held
  # still (a chess opponent's move): the first capture after the window reopened
  # hashed equal and was gated as "unchanged" forever.
  defp gate_rate_limited(state) do
    %{state | gated_out: state.gated_out + 1, unchanged_streak: 0}
  end

  defp send_frame(state, frame, hash, seq) do
    send(
      state.owner,
      {:screen_feed,
       {:frame,
        %{
          mime_type: frame.mime_type,
          data: frame.data,
          bytes: byte_size(frame.data),
          gated_out: state.gated_out,
          seq: seq
        }}}
    )

    state
    |> count_minute_frame()
    |> Map.merge(%{
      last_hash: hash,
      gated_out: 0,
      unchanged_streak: 0,
      frames_sent: state.frames_sent + 1
    })
  end

  defp capture_failed(reason, state) do
    if wedge?(reason), do: CaptureHealth.record_wedge(reason)
    strikes = state.strikes + 1

    if strikes >= @max_capture_strikes do
      {:stop, {:shutdown, {:capture_failed, reason}}, state}
    else
      Logger.warning(
        "screen_feed: capture failed " <>
          "(#{strikes}/#{@max_capture_strikes}): #{inspect(reason)}"
      )

      {:noreply, continue_after_capture(%{state | strikes: strikes})}
    end
  end

  # A wedge is specifically a capture STALL — compux's EX_TEMPFAIL self-reap or a
  # sidecar-action timeout. Every other failure (asleep display, malformed reply,
  # missing binary) is a strike but NOT evidence the host's capture path is stuck,
  # and must not open a breaker that refuses the model's own screenshots too.
  defp wedge?({:timeout, :cu_sidecar_action, _ms}), do: true
  defp wedge?({:timeout, _ms}), do: true
  defp wedge?({:sidecar_exited, 75}), do: true
  defp wedge?({:shutdown, {:sidecar_exited, 75}}), do: true
  defp wedge?(_reason), do: false

  # After every capture: honor a coalesced tick immediately, else pace the next one.
  defp continue_after_capture(%{pending_tick?: true} = state) do
    schedule_tick(%{state | pending_tick?: false}, 0)
  end

  defp continue_after_capture(state), do: schedule_tick(state, next_interval(state))

  # Once half the minute budget is spent, the cadence floor rises to the
  # sustainable rate (window / ceiling): the remaining budget spreads across the
  # remaining window instead of burning in a burst followed by a blind spell.
  # Early in the window the speaking cadence stays tight, which is what the burst
  # capacity is FOR.
  defp next_interval(state) do
    interval = raw_interval(state)

    if state.minute_frames >= div(@max_frames_per_min, 2) and within_minute?(state),
      do: max(interval, div(state.minute_ms, @max_frames_per_min)),
      else: interval
  end

  defp raw_interval(%{speaking?: true, intervals: intervals}), do: intervals.speaking

  defp raw_interval(%{unchanged_streak: streak, intervals: intervals})
       when streak >= @idle_after_unchanged,
       do: intervals.idle

  defp raw_interval(%{intervals: intervals}), do: intervals.base

  defp schedule_tick(%{timer: timer} = state, delay) when is_reference(timer) do
    Process.cancel_timer(timer)
    schedule_tick(%{state | timer: nil}, delay)
  end

  defp schedule_tick(state, delay) do
    %{state | timer: Process.send_after(self(), :tick, delay)}
  end

  # ------------------------------------------------------------------ rate limit

  defp rate_limited?(state) do
    state.minute_frames >= @max_frames_per_min and within_minute?(state)
  end

  defp count_minute_frame(state) do
    if within_minute?(state),
      do: %{state | minute_frames: state.minute_frames + 1},
      else: %{state | minute_started_ms: now_ms(), minute_frames: 1}
  end

  defp within_minute?(state), do: now_ms() - state.minute_started_ms < state.minute_ms

  # ---------------------------------------------------------------------- report

  defp report_stopped(state, reason) do
    send(state.owner, {:screen_feed, {:stopped, reason, %{frames: state.frames_sent}}})
  end

  defp stop_reason({:shutdown, reason}), do: reason
  defp stop_reason(:normal), do: :requested
  defp stop_reason(:shutdown), do: :requested
  defp stop_reason(reason), do: {:capture_failed, reason}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
