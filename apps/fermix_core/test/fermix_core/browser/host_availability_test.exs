defmodule FermixCore.Browser.HostAvailabilityTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HostAvailability

  @at ~U[2026-09-26 10:00:00Z]

  defp start_host do
    start_supervised!({HostAvailability, name: nil, clock: fn -> @at end}, id: make_ref())
  end

  defp process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "it starts empty: nothing listening, nothing attached, nothing usable" do
    host = start_host()

    assert HostAvailability.current(host) == %HostAvailability{}
    refute HostAvailability.usable?(HostAvailability.current(host))

    assert HostAvailability.unavailable_reason(HostAvailability.current(host)) ==
             "nothing in this engine serves it"
  end

  test "a tree with no availability process answers the empty report" do
    assert HostAvailability.current(:no_such_host_availability) == %HostAvailability{}
  end

  test "an attached host is not usable until it reports its pane available" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    connection = process()
    :ok = HostAvailability.attached(host, connection, 1)

    attached = HostAvailability.current(host)
    assert attached.attached
    assert attached.connection == connection
    assert attached.connection_id == 1
    refute HostAvailability.reported?(attached)
    refute HostAvailability.usable?(attached)
    assert HostAvailability.unavailable_reason(attached) =~ "not reported"

    :ok = HostAvailability.report(host, true, nil)

    reported = HostAvailability.current(host)
    assert HostAvailability.usable?(reported)
    assert reported.updated_at == @at
  end

  test "a report that the pane is unavailable carries the host's reason" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    :ok = HostAvailability.attached(host, process(), 1)
    :ok = HostAvailability.report(host, false, "the pane is closed")

    current = HostAvailability.current(host)
    refute HostAvailability.usable?(current)
    assert HostAvailability.unavailable_reason(current) == "the pane is closed"
  end

  test "stopping on the attached connection ends availability and is final" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    connection = process()
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)

    :ok = HostAvailability.stopping(host, connection)

    stopping = HostAvailability.current(host)
    refute HostAvailability.usable?(stopping)
    assert stopping.stopping
    assert stopping.quit
    assert HostAvailability.unavailable_reason(stopping) == "the app is quitting"

    # BROWSER-5: a report that lands behind `host_stopping` (e.g. the screen
    # unlocking after the app already said it is quitting) never reopens it.
    :ok = HostAvailability.report(host, true, nil)
    refute HostAvailability.usable?(HostAvailability.current(host))

    assert HostAvailability.unavailable_reason(HostAvailability.current(host)) ==
             "the app is quitting"
  end

  test "stopping on a connection that is not the attached one changes nothing" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    connection = process()
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)

    :ok = HostAvailability.stopping(host, process())

    current = HostAvailability.current(host)
    assert HostAvailability.usable?(current)
    refute current.stopping
  end

  test "a new attach is not usable on an earlier connection's report, and clears stopping and quit" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    first = process()
    :ok = HostAvailability.attached(host, first, 1)
    :ok = HostAvailability.report(host, true, nil)
    :ok = HostAvailability.stopping(host, first)

    second = process()
    :ok = HostAvailability.attached(host, second, 2)

    fresh = HostAvailability.current(host)
    refute HostAvailability.usable?(fresh)
    refute fresh.stopping
    refute fresh.quit
    assert fresh.connection == second
    assert fresh.connection_id == 2
    assert is_nil(fresh.launch_until)
  end

  test "the connection's exit empties the report, and says the app disconnected" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    connection = process()
    ref = Process.monitor(connection)
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)

    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^ref, :process, ^connection, :killed}

    current = eventually(host, &(&1.attached == false))
    refute HostAvailability.usable?(current)
    assert HostAvailability.unavailable_reason(current) == "the app disconnected"
  end

  test "the connection's exit after stopping says the app quit" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    connection = process()
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)
    :ok = HostAvailability.stopping(host, connection)

    Process.exit(connection, :kill)

    current = eventually(host, &(&1.attached == false))
    assert HostAvailability.unavailable_reason(current) == "the app quit"
    assert current.quit
  end

  test "the endpoint's exit empties everything, including a live connection" do
    host = start_host()
    endpoint = process()
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host, process(), 1)
    :ok = HostAvailability.report(host, true, nil)

    Process.exit(endpoint, :kill)

    assert eventually(host, &(&1 == %HostAvailability{})) == %HostAvailability{}
  end

  test "launching records the deadline, and it does not survive a new attach" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    :ok = HostAvailability.launching(host, 5_000)

    assert HostAvailability.current(host).launch_until == 5_000

    :ok = HostAvailability.attached(host, process(), 1)
    assert is_nil(HostAvailability.current(host).launch_until)
  end

  test "a host's reason is bounded" do
    host = start_host()
    :ok = HostAvailability.listening(host, process())
    :ok = HostAvailability.attached(host, process(), 1)
    :ok = HostAvailability.report(host, false, String.duplicate("x", 5_000))

    assert String.length(HostAvailability.unavailable_reason(HostAvailability.current(host))) ==
             200
  end

  defp eventually(host, predicate, attempts \\ 40) do
    current = HostAvailability.current(host)

    cond do
      predicate.(current) ->
        current

      attempts == 0 ->
        current

      true ->
        Process.sleep(10)
        eventually(host, predicate, attempts - 1)
    end
  end
end
