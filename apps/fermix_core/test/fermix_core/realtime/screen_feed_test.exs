defmodule FermixCore.Realtime.ScreenFeedTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.Realtime.ScreenFeed

  # Production cadence is seconds; the pacing RULES are what these tests assert,
  # not the wall-clock values, so they run the same code paths at test speed.
  @fast_intervals %{base: 10, speaking: 5, idle: 30}

  # A fake capture process: it never opens a Port, so the whole feed — pacing,
  # change gate, strikes, breaker grace — is exercised with no sidecar, no TCC
  # grant, and no host state (the hermetic-tests rule).
  defmodule FakeCapture do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def request(server, seq), do: GenServer.cast(server, {:capture, seq})

    def stop(server) do
      GenServer.stop(server, :normal)
    catch
      :exit, _reason -> :ok
    end

    @doc "Queue what the next captures return, oldest first; the last entry repeats."
    def script(results), do: :persistent_term.put({__MODULE__, :script}, results)

    def requests, do: :persistent_term.get({__MODULE__, :requests}, 0)

    def reset do
      :persistent_term.put({__MODULE__, :script}, [])
      :persistent_term.put({__MODULE__, :requests}, 0)
    end

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_cast({:capture, seq}, state) do
      :persistent_term.put({__MODULE__, :requests}, requests() + 1)
      send(state.owner, {:screen_capture, seq, next_result()})
      {:noreply, state}
    end

    defp next_result do
      case :persistent_term.get({__MODULE__, :script}, []) do
        [] -> {:ok, %{mime_type: "image/png", data: "frame"}}
        [only] -> only
        [head | rest] -> :persistent_term.put({__MODULE__, :script}, rest) && head
      end
    end
  end

  setup do
    start_supervised!(CaptureHealth)
    FakeCapture.reset()
    on_exit(&FakeCapture.reset/0)
    :ok
  end

  defp start_feed(script \\ []) do
    FakeCapture.script(script)

    # Linked to the test process, exactly as the SessionServer links it, so the
    # feed's owner-EXIT teardown path is the one under test too. Unlinked +
    # stopped on exit so a feed can never tick on into the NEXT test and pollute
    # the shared breaker (the leak that made this file's first run non-hermetic).
    {:ok, feed} =
      ScreenFeed.start_link(
        owner: self(),
        display: 0,
        capture_module: FakeCapture,
        driver: {:unused, []},
        intervals: @fast_intervals
      )

    on_exit(fn ->
      if Process.alive?(feed), do: ScreenFeed.stop(feed, :requested)
    end)

    feed
  end

  # `stop/2` exits the feed with `{:shutdown, reason}`, which propagates over the
  # link. Production is safe (the SessionServer traps exits); a test process does
  # not, so it unlinks first — the same thing the feed's own teardown tests assert.
  defp detach(feed) do
    Process.unlink(feed)
    feed
  end

  # Bounded wait on REAL state, never a sleep: the condition here (the breaker
  # opening) is produced asynchronously by the feed, and its status decays with
  # the backoff clock, so polling it is the honest assertion.
  defp wait_until(fun, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> poll_until(fun, deadline)
    end
  end

  test "a changed screen produces a frame with its byte size" do
    start_feed([{:ok, %{mime_type: "image/png", data: "pixels"}}])

    assert_receive {:screen_feed, {:frame, frame}}, 1_000
    assert frame.mime_type == "image/png"
    assert frame.data == "pixels"
    assert frame.bytes == byte_size("pixels")
    assert frame.gated_out == 0
  end

  # The token-cost floor: a static screen must cost NOTHING, so identical bytes
  # are never sent twice — and the gate count rides on the next real frame.
  test "an unchanged screen sends no further frames, and reports what it gated" do
    same = {:ok, %{mime_type: "image/png", data: "same"}}
    start_feed([same, same, same, {:ok, %{mime_type: "image/png", data: "different"}}])

    assert_receive {:screen_feed, {:frame, %{data: "same"}}}, 1_000
    assert_receive {:screen_feed, {:frame, %{data: "different", gated_out: gated}}}, 30_000
    assert gated >= 2, "the identical captures in between must have been dropped, not sent"

    refute_received {:screen_feed, {:frame, %{data: "same"}}}
  end

  test "capture failures strike out and stop the feed with a typed reason" do
    feed = detach(start_feed([{:error, :boom}]))
    ref = Process.monitor(feed)

    assert_receive {:screen_feed, {:stopped, {:capture_failed, :boom}, %{frames: 0}}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^feed, _reason}, 1_000
  end

  test "a capture stall is recorded as a wedge on the shared breaker" do
    # One wedge already on the record, so the feed's own stall is the second and
    # opens the breaker. Asserted by waiting on the real state (never a sleep, and
    # never on a value that decays with the backoff clock).
    CaptureHealth.record_wedge(:earlier_stall)
    detach(start_feed([{:error, {:timeout, 30_000}}]))

    assert wait_until(fn -> match?({:error, {:capture_wedged, _}}, CaptureHealth.status()) end),
           "a capture stall must be recorded as a wedge, not merely counted as a strike"
  end

  test "a non-stall failure is a strike but never opens the breaker" do
    detach(start_feed([{:error, :display_asleep}]))

    assert_receive {:screen_feed, {:stopped, {:capture_failed, :display_asleep}, _}}, 10_000

    assert :ok = CaptureHealth.status(),
           "a non-capture-stall error must not refuse the model's own screenshots"
  end

  test "an open breaker defers capture instead of respawning into a wedged host" do
    CaptureHealth.record_wedge(:a)
    CaptureHealth.record_wedge(:b)
    assert {:error, {:capture_wedged, _}} = CaptureHealth.status()

    feed = detach(start_feed())

    refute_receive {:screen_feed, {:frame, _}}, 300
    assert FakeCapture.requests() == 0, "no capture may be attempted while the breaker is open"
    assert Process.alive?(feed), "a short backoff is waited out, not treated as fatal"
  end

  test "the feed stands down when its owning call ends" do
    parent = self()

    # Started INSIDE the owner so the link is owner→feed, exactly as the
    # SessionServer does it. The feed traps exits, so this is the path that proves
    # it stands down deliberately rather than surviving its dead call.
    owner =
      spawn(fn ->
        {:ok, feed} =
          ScreenFeed.start_link(
            owner: self(),
            display: 0,
            capture_module: FakeCapture,
            driver: {:unused, []}
          )

        send(parent, {:feed, feed})
        receive do: (:die -> :ok)
      end)

    assert_receive {:feed, feed}, 1_000
    ref = Process.monitor(feed)
    send(owner, :die)

    assert_receive {:DOWN, ^ref, :process, ^feed, _reason}, 1_000
  end

  test "stop/2 is idempotent and reports the operator's own reason" do
    feed = detach(start_feed())
    assert :ok = ScreenFeed.stop(feed, :requested)
    assert :ok = ScreenFeed.stop(feed, :requested)
    assert_received {:screen_feed, {:stopped, :requested, _}}
  end

  test "speaking state is accepted without blocking the caller" do
    feed = start_feed()
    assert :ok = ScreenFeed.set_speaking(feed, true)
    assert :ok = ScreenFeed.set_speaking(feed, false)
    assert Process.alive?(feed)
  end
end
