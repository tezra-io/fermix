defmodule FermixCore.ComputerUse.CaptureHealth do
  @moduledoc """
  The screen-capture circuit breaker (`WATCH_HARDENING.md` §3, Option A).

  A wedged macOS ScreenCaptureKit is a SYSTEM-WIDE condition — one stuck client
  makes every later capture stall — so this state is GLOBAL and deliberately
  lives outside any session: it is a child of `ComputerUse.Supervisor`, so it
  outlives the `:temporary` sessions that record into it.

  Why it has to exist: a caller that captures on a timer (the realtime
  `Realtime.ScreenFeed`) would otherwise respawn a sidecar into a still-wedged
  host forever — the exact amplification that reverted the `watch` construct (200
  cycles, a fresh sidecar per cycle, into a host that could not capture).

  Policy, all bounded: `@wedges_to_open` wedges inside `@wedge_window_ms` opens
  the breaker for an escalating `@backoff_ms` step, and `open?`-ness is a
  deadline, not a countdown. **Only a successful capture clears it** — a narrated
  or unrelated error must never read as health, because "anything that isn't a
  wedge resets the counter" is precisely the bug that defeated the watch
  construct's 3-strike counter (§2.3).

  Not running (computer-use disabled, so no CU tree) means NO HISTORY, so
  `status/0` is `:ok`. That is not a degraded capture path: whether capture is
  possible at all is gated separately by `ComputerUse.ready?/0`, which is false
  in exactly that state.
  """

  use GenServer

  require Logger

  # Two wedges inside a minute is a pattern, not a hiccup: a single stall can be
  # a transient SCK re-consent or a sleeping display, so one wedge only arms the
  # window. Backoff escalates per OPEN (not per wedge) and never resets on time
  # alone — a host that keeps wedging gets progressively longer refusals.
  @wedge_window_ms 60_000
  @wedges_to_open 2
  @backoff_ms [5_000, 30_000, 120_000]

  @type status :: :ok | {:error, {:capture_wedged, non_neg_integer()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether capture may be attempted right now: `:ok`, or
  `{:error, {:capture_wedged, retry_in_ms}}` while the breaker is open.

  Callers must treat the error as a refusal to START capture (no session, no
  sidecar), never as a capture failure to retry immediately.
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    # No CU tree (computer-use disabled) => no history. Documented above; the
    # same shape `SessionManager` uses for its absent-registry backstop.
    :exit, _reason -> :ok
  end

  @doc "Record a capture wedge (sidecar capture stall / EX_TEMPFAIL exit)."
  @spec record_wedge(term(), GenServer.server()) :: :ok
  def record_wedge(reason, server \\ __MODULE__) do
    GenServer.cast(server, {:wedge, reason})
  end

  @doc "Record a successful capture — the ONLY thing that clears the breaker."
  @spec record_success(GenServer.server()) :: :ok
  def record_success(server \\ __MODULE__) do
    GenServer.cast(server, :success)
  end

  @impl true
  def init(_opts) do
    {:ok, %{wedges: [], opens: 0, opened_until: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, current_status(state, now_ms()), state}
  end

  @impl true
  def handle_cast({:wedge, reason}, state) do
    {:noreply, add_wedge(state, reason, now_ms())}
  end

  def handle_cast(:success, _state) do
    {:noreply, %{wedges: [], opens: 0, opened_until: nil}}
  end

  defp current_status(%{opened_until: nil}, _now), do: :ok

  defp current_status(%{opened_until: until}, now) when now < until do
    {:error, {:capture_wedged, until - now}}
  end

  defp current_status(_state, _now), do: :ok

  defp add_wedge(state, reason, now) do
    wedges = [now | prune(state.wedges, now)]

    if length(wedges) >= @wedges_to_open,
      do: open_breaker(state, reason, now),
      else: %{state | wedges: wedges}
  end

  # Opening clears the window: the next open needs a fresh pattern, and the
  # escalation lives in `opens` (cleared only by a success).
  defp open_breaker(state, reason, now) do
    opens = min(state.opens + 1, length(@backoff_ms))
    backoff = Enum.at(@backoff_ms, opens - 1)

    Logger.warning(
      "computer_use: capture breaker OPEN for #{backoff}ms after #{@wedges_to_open} wedges " <>
        "(open ##{opens}, last: #{inspect(reason)})"
    )

    %{wedges: [], opens: opens, opened_until: now + backoff}
  end

  defp prune(wedges, now), do: Enum.filter(wedges, &(now - &1 < @wedge_window_ms))

  defp now_ms, do: System.monotonic_time(:millisecond)
end
