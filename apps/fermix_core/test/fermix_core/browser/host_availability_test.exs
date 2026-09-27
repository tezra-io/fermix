defmodule FermixCore.Browser.HostAvailabilityTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.HostAvailability

  @at ~U[2026-09-26 10:00:00Z]

  defp start_host do
    start_supervised!({HostAvailability, name: nil, clock: fn -> @at end}, id: make_ref())
  end

  defp endpoint do
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
    :ok = HostAvailability.listening(host, endpoint())
    :ok = HostAvailability.attached(host)

    attached = HostAvailability.current(host)
    assert attached.attached
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
    :ok = HostAvailability.listening(host, endpoint())
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, false, "the pane is closed")

    current = HostAvailability.current(host)
    refute HostAvailability.usable?(current)
    assert HostAvailability.unavailable_reason(current) == "the pane is closed"
  end

  test "a detach voids the last report and says why" do
    host = start_host()
    :ok = HostAvailability.listening(host, endpoint())
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, true, nil)
    :ok = HostAvailability.detached(host, "the app quit")

    current = HostAvailability.current(host)
    refute current.attached
    refute HostAvailability.usable?(current)
    assert current.updated_at == nil
    assert HostAvailability.unavailable_reason(current) == "the app quit"
  end

  test "a new attach is not usable on an earlier connection's report" do
    host = start_host()
    :ok = HostAvailability.listening(host, endpoint())
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, true, nil)
    :ok = HostAvailability.attached(host)

    refute HostAvailability.usable?(HostAvailability.current(host))
  end

  test "the endpoint's exit empties the report" do
    host = start_host()
    pid = endpoint()
    :ok = HostAvailability.listening(host, pid)
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, true, nil)

    Process.exit(pid, :kill)

    assert eventually_empty(host)
  end

  test "a host's reason is bounded" do
    host = start_host()
    :ok = HostAvailability.listening(host, endpoint())
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, false, String.duplicate("x", 5_000))

    assert String.length(HostAvailability.unavailable_reason(HostAvailability.current(host))) ==
             200
  end

  defp eventually_empty(host, attempts \\ 40) do
    cond do
      HostAvailability.current(host) == %HostAvailability{} -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually_empty(host, attempts - 1)
    end
  end
end
