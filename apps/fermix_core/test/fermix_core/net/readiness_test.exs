defmodule FermixCore.Net.ReadinessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Net.Readiness

  test "returns :ready immediately when the first probe succeeds (no wait)" do
    parent = self()

    probe = fn _host, _port, _timeout ->
      send(parent, :probe)
      :ok
    end

    delay = fn _ms -> send(parent, :delayed) end

    assert :ready = Readiness.await("api.test", 443, probe_fn: probe, delay_fn: delay)

    assert_received :probe
    refute_received :probe
    refute_received :delayed
  end

  test "waits and recovers once the network comes back" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    probe = fn _host, _port, _timeout ->
      n = Agent.get_and_update(counter, fn x -> {x + 1, x + 1} end)
      send(parent, {:probe, n})
      if n >= 3, do: :ok, else: {:error, :ehostunreach}
    end

    delay = fn _ms -> send(parent, :delayed) end

    assert :ready =
             Readiness.await("api.test", 443,
               probe_fn: probe,
               delay_fn: delay,
               interval_ms: 10,
               budget_ms: 10_000
             )

    assert_received {:probe, 1}
    assert_received {:probe, 2}
    assert_received {:probe, 3}
    # Two failed probes -> two backoff delays; the third succeeds immediately.
    assert_received :delayed
    assert_received :delayed
    refute_received :delayed
  end

  test "gives up with :unready after a bounded budget and proceeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    probe = fn _host, _port, _timeout ->
      Agent.update(counter, &(&1 + 1))
      {:error, :timeout}
    end

    log =
      capture_log(fn ->
        assert :unready =
                 Readiness.await("api.test", 443,
                   probe_fn: probe,
                   delay_fn: fn _ms -> :ok end,
                   interval_ms: 10,
                   budget_ms: 30
                 )
      end)

    # budget 30ms / interval 10ms -> bounded: probes at waited 0, 10, 20, then
    # 30 + 10 > 30 stops. Exactly 4 probes, never unbounded.
    assert Agent.get(counter, & &1) == 4
    assert log =~ "Network readiness probe"
    assert log =~ "proceeding anyway"
  end
end
