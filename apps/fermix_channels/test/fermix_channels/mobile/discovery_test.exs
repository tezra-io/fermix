defmodule FermixChannels.Mobile.DiscoveryTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Discovery

  test "returns only usable interface addresses and classifies tailnet and LAN candidates" do
    getifaddrs = fn ->
      {:ok,
       [
         {~c"lo0", [flags: [:up, :loopback], addr: {127, 0, 0, 1}]},
         {~c"down0", [flags: [:broadcast], addr: {192, 168, 1, 9}]},
         {~c"en0", [flags: [:up, :broadcast], addr: {192, 168, 1, 8}]},
         {~c"utun4", [flags: [:up, :pointtopoint], addr: {100, 93, 2, 7}]},
         {~c"en0", [flags: [:up], addr: {0, 0, 0, 0}]}
       ]}
    end

    reverse_lookup = fn _address, 750 -> {:error, :nxdomain} end

    assert {:ok, candidates} =
             Discovery.discover(getifaddrs: getifaddrs, reverse_lookup: reverse_lookup)

    assert candidates == [
             %{address: "100.93.2.7", interface: "utun4", scope: :tailnet},
             %{address: "192.168.1.8", interface: "en0", scope: :lan}
           ]
  end

  test "adds bounded resolvable MagicDNS hostnames ahead of tailnet and LAN addresses" do
    getifaddrs = fn ->
      tailnet =
        Enum.map(1..10, fn last ->
          {~c"utun#{last}", [flags: [:up], addr: {100, 64, 0, last}]}
        end)

      {:ok, tailnet ++ [{~c"en0", [flags: [:up], addr: {192, 168, 1, 8}]}]}
    end

    test_pid = self()

    reverse_lookup = fn address, timeout_ms ->
      send(test_pid, {:reverse_lookup, address, timeout_ms})

      case address do
        {100, 64, 0, 1} ->
          {:ok, {:hostent, ~c"fermix-host.tail123.ts.net.", [], :inet, 4, [{100, 64, 0, 1}]}}

        _address ->
          {:error, :nxdomain}
      end
    end

    assert {:ok, candidates} =
             Discovery.discover(getifaddrs: getifaddrs, reverse_lookup: reverse_lookup)

    assert hd(candidates) == %{
             address: "fermix-host.tail123.ts.net",
             interface: "utun1",
             scope: :tailnet
           }

    assert Enum.at(candidates, 1).address == "100.64.0.1"
    assert List.last(candidates).address == "192.168.1.8"
    assert_receive {:reverse_lookup, {100, 64, 0, 1}, 750}
    assert_receive {:reverse_lookup, {100, 64, 0, 8}, 750}
    # Discovery has returned, so every lookup it made has already reported.
    refute_received {:reverse_lookup, {100, 64, 0, 9}, 750}
  end

  test "tailnet reverse lookups run concurrently, not one after another" do
    test_pid = self()

    # Every lookup parks until the test has seen all eight start, which only
    # happens if they are in flight at the same time.
    reverse_lookup = fn address, 750 ->
      send(test_pid, {:lookup_started, address, self()})

      receive do
        :answer -> {:error, :nxdomain}
      end
    end

    discovery =
      Task.async(fn ->
        Discovery.discover(getifaddrs: tailnet(8), reverse_lookup: reverse_lookup)
      end)

    lookups =
      for _index <- 1..8 do
        assert_receive {:lookup_started, _address, lookup}, 500
        lookup
      end

    Enum.each(lookups, &send(&1, :answer))
    assert {:ok, candidates} = Task.await(discovery)
    assert length(candidates) == 8
  end

  # The lookups run at once (above), so their shared deadline is the whole
  # cost. A lookup that never answers is abandoned at it, and discovery still
  # answers with the numeric candidates. The deadline is passed in, so nothing
  # here waits on the wall clock.
  test "unanswerable lookups are abandoned at the deadline, and numeric candidates still ship" do
    never_answers = fn _address, 25 ->
      receive do
        :never -> {:error, :nxdomain}
      end
    end

    assert {:ok, candidates} =
             Discovery.discover(
               getifaddrs: tailnet(8),
               reverse_lookup: never_answers,
               lookup_timeout_ms: 25
             )

    assert Enum.map(candidates, & &1.address) == Enum.map(1..8, &"100.64.0.#{&1}")
  end

  test "the lookup deadline defaults to 750 ms and must be positive" do
    test_pid = self()

    reverse_lookup = fn _address, timeout_ms ->
      send(test_pid, {:lookup_timeout, timeout_ms})
      {:error, :nxdomain}
    end

    assert {:ok, _candidates} =
             Discovery.discover(getifaddrs: tailnet(1), reverse_lookup: reverse_lookup)

    assert_received {:lookup_timeout, 750}

    assert_raise ArgumentError, fn ->
      Discovery.discover(getifaddrs: tailnet(1), lookup_timeout_ms: 0)
    end
  end

  test "the cache answers from memory until its answer is a minute old" do
    test_pid = self()
    now = :counters.new(1, [])

    discover = fn ->
      send(test_pid, :enumerated)
      {:ok, [%{address: "10.0.0.#{:counters.get(now, 1)}", interface: "en0", scope: :lan}]}
    end

    cache =
      start_supervised!(
        {Discovery, name: nil, discover: discover, clock: fn -> :counters.get(now, 1) end}
      )

    assert {:ok, [%{address: "10.0.0.0"}]} = Discovery.candidates(cache)
    :counters.put(now, 1, 59_999)
    assert {:ok, [%{address: "10.0.0.0"}]} = Discovery.candidates(cache)
    assert_received :enumerated
    refute_received :enumerated

    :counters.put(now, 1, 60_000)
    assert {:ok, [%{address: "10.0.0.60000"}]} = Discovery.candidates(cache)
    assert_received :enumerated
  end

  test "a failed enumeration is answered but never cached" do
    test_pid = self()

    discover = fn ->
      send(test_pid, :enumerated)
      {:error, :eacces}
    end

    cache = start_supervised!({Discovery, name: nil, discover: discover})

    assert {:error, :eacces} = Discovery.candidates(cache)
    assert {:error, :eacces} = Discovery.candidates(cache)
    assert_received :enumerated
    assert_received :enumerated
  end

  test "returns the interface enumeration failure" do
    assert Discovery.discover(getifaddrs: fn -> {:error, :eacces} end) == {:error, :eacces}
  end

  test "rejects invalid dependency injection" do
    assert_raise ArgumentError, fn -> Discovery.discover(getifaddrs: :not_a_function) end
  end

  defp tailnet(count) do
    fn ->
      {:ok, Enum.map(1..count, &{~c"utun#{&1}", [flags: [:up], addr: {100, 64, 0, &1}]})}
    end
  end
end
