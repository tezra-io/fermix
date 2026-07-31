defmodule FermixCore.ComputerUse.CaptureHealthTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.CaptureHealth

  setup do
    # The real singleton name: every caller (the CU session, the realtime feed)
    # reads the global breaker, so the test drives that exact process.
    start_supervised!(CaptureHealth)
    :ok
  end

  test "a healthy breaker allows capture" do
    assert :ok = CaptureHealth.status()
  end

  test "one wedge is a hiccup, not a pattern" do
    CaptureHealth.record_wedge({:shutdown, {:sidecar_exited, 75}})
    assert :ok = CaptureHealth.status()
  end

  test "two wedges inside the window open the breaker" do
    CaptureHealth.record_wedge({:shutdown, {:sidecar_exited, 75}})
    CaptureHealth.record_wedge({:shutdown, :sidecar_timeout})

    assert {:error, {:capture_wedged, retry_in_ms}} = CaptureHealth.status()
    assert retry_in_ms > 0
  end

  # The exact bug that defeated the reverted watch construct's strike counter:
  # anything-that-is-not-a-wedge must NOT read as health.
  test "only a successful capture clears the breaker" do
    CaptureHealth.record_wedge(:a)
    CaptureHealth.record_wedge(:b)
    assert {:error, {:capture_wedged, _}} = CaptureHealth.status()

    CaptureHealth.record_success()
    assert :ok = CaptureHealth.status()
  end

  test "backoff escalates per open and only a success resets the escalation" do
    open_breaker = fn ->
      CaptureHealth.record_wedge(:a)
      CaptureHealth.record_wedge(:b)
      {:error, {:capture_wedged, ms}} = CaptureHealth.status()
      ms
    end

    first = open_breaker.()
    second = open_breaker.()

    assert second > first, "a host that keeps wedging must back off harder"

    CaptureHealth.record_success()
    assert :ok = CaptureHealth.status()
    # `status` returns clock-derived REMAINING time (`until - now`), so equality
    # with the first reading flakes on a millisecond tick under suite load. The
    # property is the TIER: a post-reset open backs off at tier #1 again — far
    # below the escalated second reading.
    assert open_breaker.() < second, "a healthy capture resets the escalation to the first tier"
  end

  test "with no CU tree there is no history, so capture is not blocked by the breaker" do
    stop_supervised!(CaptureHealth)

    # Computer-use disabled means this process does not exist. `status/0` must be a
    # clean :ok (readiness is gated separately by ComputerUse.ready?/0), never a
    # crash in a caller that only wanted to check health.
    assert :ok = CaptureHealth.status()
    assert :ok = CaptureHealth.record_wedge(:no_owner)
    assert :ok = CaptureHealth.record_success()
  end
end
