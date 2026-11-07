defmodule FermixCore.Realtime.CallLeaseTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.CallLease

  @robot {:accessory, "desk-robot"}

  setup do
    lease = :"call_lease_#{System.unique_integer([:positive])}"
    start_supervised!({CallLease, name: lease})
    %{lease: lease}
  end

  test "a lease names its holder: the endpoint, the engine and when it started", %{lease: lease} do
    before = DateTime.utc_now()
    holder = hold_in_process(lease, @robot, "openai_live")

    assert {:ok, %{endpoint: "accessory:desk-robot", engine: "openai_live", started_at: at}} =
             CallLease.holder(lease)

    assert DateTime.compare(at, before) in [:gt, :eq]
    assert Process.alive?(holder)
  end

  test "with no call up, nothing holds the lease", %{lease: lease} do
    assert CallLease.holder(lease) == :none
  end

  # One owner-voice call per home, whichever engine and endpoint ask: the
  # refusal says where the call is.
  test "a second call is refused while the first holds the lease, naming its endpoint", %{
    lease: lease
  } do
    _holder = hold_in_process(lease, @robot, "openai_live")

    assert CallLease.acquire(lease, :desktop, "openai_realtime") ==
             {:error, {:call_in_progress, "accessory:desk-robot"}}

    assert {:ok, %{endpoint: "accessory:desk-robot"}} = CallLease.holder(lease)
  end

  # Two endpoints starting a call at once: the lease is one `insert_new`, so
  # exactly one of them wins however their starts interleave.
  test "of many acquires racing, exactly one wins", %{lease: lease} do
    test_pid = self()

    for index <- 1..20 do
      endpoint = if rem(index, 2) == 0, do: :desktop, else: {:accessory, "robot-#{index}"}

      spawn(fn ->
        send(test_pid, {:acquired, CallLease.acquire(lease, endpoint, "openai_realtime")})
        hold(test_pid)
      end)
    end

    results = for _index <- 1..20, do: receive_acquired()

    assert Enum.count(results, &(&1 == :ok)) == 1
    {:ok, %{endpoint: winner}} = CallLease.holder(lease)
    assert Enum.count(results, &(&1 == {:error, {:call_in_progress, winner}})) == 19
  end

  test "the lease goes with its holder, however it ends", %{lease: lease} do
    holder = hold_in_process(lease, :desktop, "xai_realtime")
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

    assert CallLease.holder(lease) == :none
    assert CallLease.acquire(lease, @robot, "openai_realtime") == :ok
    assert {:ok, %{endpoint: "accessory:desk-robot"}} = CallLease.holder(lease)
  end

  test "an endpoint that is not one is refused before the lease is touched", %{lease: lease} do
    assert_raise ArgumentError, fn ->
      CallLease.acquire(lease, {:accessory, "desk robot"}, "openai_realtime")
    end

    assert CallLease.holder(lease) == :none
  end

  # A holder process that takes the lease and then waits, so the lease outlives
  # the call that took it.
  defp hold_in_process(lease, endpoint, engine) do
    test_pid = self()

    holder =
      spawn(fn ->
        send(test_pid, {:acquired, CallLease.acquire(lease, endpoint, engine)})
        hold(test_pid)
      end)

    assert receive_acquired() == :ok
    holder
  end

  # Holds until its test ends, so nothing outlives the test that started it,
  # and never past the bound.
  defp hold(test_pid) do
    test_ref = Process.monitor(test_pid)

    receive do
      {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> :ok
    after
      10_000 -> :ok
    end
  end

  defp receive_acquired do
    receive do
      {:acquired, result} -> result
    after
      10_000 -> flunk("an acquire never answered")
    end
  end
end
