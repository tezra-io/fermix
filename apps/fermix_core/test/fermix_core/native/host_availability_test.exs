defmodule FermixCore.Native.HostAvailabilityTest do
  @moduledoc """
  The native host's last word (M76 §4.4, §4.6): whether anything serves the
  wire, which connection is attached, its grant report, a quit, and the one
  launch on demand; and `step/2`, the table a caller reads it by.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Native.HostAvailability

  @at ~U[2026-10-18 10:00:00Z]
  @cooldown_ms 300_000

  defp start_host do
    start_supervised!({HostAvailability, name: nil, clock: fn -> @at end}, id: make_ref())
  end

  defp process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp attached_host do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    connection = process()
    :ok = HostAvailability.attached(host, connection, 1, "0.6.0")
    {host, connection}
  end

  defp clock(now_ms, remaining_ms),
    do: %{now_ms: now_ms, remaining_ms: remaining_ms, cooldown_ms: @cooldown_ms}

  describe "the record" do
    test "it starts empty, and a tree with no availability process answers the same" do
      host = start_host()

      assert HostAvailability.current(host) == %HostAvailability{}
      assert HostAvailability.current(:no_such_native_host_availability) == %HostAvailability{}
    end

    test "an attach names the connection and the app's version; a report is its grant" do
      {host, connection} = attached_host()

      attached = HostAvailability.current(host)
      assert %{listening: true, attached: true, connection: ^connection} = attached
      assert %{connection_id: 1, host_version: "0.6.0", notifications: nil} = attached

      :ok = HostAvailability.report(host, "granted")
      assert %{notifications: "granted", updated_at: @at} = HostAvailability.current(host)
    end

    test "host_stopping is final for its connection: no later report reopens it" do
      {host, connection} = attached_host()
      :ok = HostAvailability.report(host, "granted")
      :ok = HostAvailability.stopping(host, connection)
      :ok = HostAvailability.report(host, "not_granted")

      assert %{stopping: true, notifications: "granted"} = HostAvailability.current(host)
    end

    test "a stop from another connection changes nothing" do
      {host, _connection} = attached_host()
      :ok = HostAvailability.stopping(host, process())

      refute HostAvailability.current(host).stopping
    end

    test "a connection that exits detaches, however it ended, and keeps a pending launch" do
      {host, connection} = attached_host()
      :ok = HostAvailability.launching(host, 9_000)
      :ok = HostAvailability.stopping(host, connection)
      ref = Process.monitor(connection)

      Process.exit(connection, :kill)
      assert_receive {:DOWN, ^ref, :process, ^connection, :killed}

      detached = await_current(host, &(not &1.attached))
      assert %{listening: true, stopping: false, connection: nil, launch_until: 9_000} = detached
    end

    test "an attach voids an earlier launch: the app is running" do
      host = start_host()
      :ok = HostAvailability.listening(host, process())
      :ok = HostAvailability.launching(host, 9_000)
      :ok = HostAvailability.attached(host, process(), 2, "0.6.0")

      assert %{launch_until: nil, connection_id: 2} = HostAvailability.current(host)
    end

    test "the endpoint's exit empties the record" do
      host = start_host()
      endpoint = process()
      :ok = HostAvailability.listening(host, endpoint)
      :ok = HostAvailability.attached(host, process(), 1, "0.6.0")

      Process.exit(endpoint, :kill)
      assert await_current(host, &(&1 == %HostAvailability{})) == %HostAvailability{}
    end
  end

  describe "step/2" do
    test "each row of the table" do
      connection = process()
      listening = %HostAvailability{listening: true}
      attached = %{listening | attached: true, connection: connection}

      rows = [
        {attached, clock(0, 3_000), {:attached, connection}},
        {%{attached | stopping: true}, clock(0, 3_000), {:unavailable, :stopping}},
        {%HostAvailability{}, clock(0, 3_000), {:unavailable, :not_served}},
        {listening, clock(0, 3_000), :launch},
        {listening, clock(0, 0), {:unavailable, :not_attached}},
        {%{listening | launch_until: 2_000}, clock(1_000, 1_000), {:wait, 2_000}},
        {%{listening | launch_until: 2_000}, clock(1_000, 0), {:unavailable, :not_attached}},
        {%{listening | launch_until: 2_000}, clock(2_000 + @cooldown_ms - 1, 3_000),
         {:unavailable, :not_attached}},
        {%{listening | launch_until: 2_000}, clock(2_000 + @cooldown_ms, 3_000), :launch}
      ]

      for {host, clock, step} <- rows do
        assert HostAvailability.step(host, clock) == step,
               "#{inspect(Map.take(host, [:listening, :attached, :stopping, :launch_until]))} " <>
                 "at #{inspect(clock)}"
      end
    end
  end

  describe "claim/3" do
    test "a launch is claimed in the read that decides it, so a second caller waits on it" do
      host = start_host()
      :ok = HostAvailability.listening(host, process())

      assert HostAvailability.claim(host, clock(0, 3_000), 3_000) == :launch
      assert HostAvailability.current(host).launch_until == 3_000
      assert HostAvailability.claim(host, clock(10, 3_000), 3_010) == {:wait, 3_000}
      assert HostAvailability.current(host).launch_until == 3_000
    end

    test "a claim that is not a launch records nothing" do
      {host, connection} = attached_host()

      assert HostAvailability.claim(host, clock(0, 3_000), 3_000) == {:attached, connection}
      assert HostAvailability.current(host).launch_until == nil
    end

    test "a tree with no availability process claims nothing: nothing serves the wire" do
      assert HostAvailability.claim(:no_such_native_host_availability, clock(0, 3_000), 3_000) ==
               {:unavailable, :not_served}
    end
  end

  # A record written by another process's exit has no reply to wait on, so the
  # read is repeated until it holds, bounded by a wall-clock deadline.
  defp await_current(host, predicate, deadline_ms \\ 10_000) do
    until = System.monotonic_time(:millisecond) + deadline_ms
    await_until(host, predicate, until)
  end

  defp await_until(host, predicate, until) do
    current = HostAvailability.current(host)

    cond do
      predicate.(current) ->
        current

      System.monotonic_time(:millisecond) >= until ->
        flunk("the record never held: #{inspect(current)}")

      true ->
        # sleep: one poll's interval, bounded by the deadline above
        Process.sleep(10)
        await_until(host, predicate, until)
    end
  end
end
