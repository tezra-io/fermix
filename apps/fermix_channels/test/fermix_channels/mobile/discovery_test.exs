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

  # M51 §5.5: the listener serves only the address it binds, so a phone told
  # any other address is told a route that cannot answer.
  describe "the configured bind" do
    test "a wildcard bind keeps every candidate" do
      for bind <- ["0.0.0.0", {0, 0, 0, 0}, "::"] do
        assert {:ok, candidates} = Discovery.discover(bound_host() ++ [bind: bind])

        assert Enum.map(candidates, & &1.address) == [
                 "fermix-host.tail123.ts.net",
                 "100.64.0.1",
                 "100.64.0.2",
                 "192.168.1.8",
                 "10.0.0.5"
               ]
      end
    end

    test "a LAN address keeps only its own candidate, and looks up no tailnet name" do
      test_pid = self()

      lookup = fn address, timeout_ms ->
        send(test_pid, {:reverse_lookup, address})
        reverse_lookup(address, timeout_ms)
      end

      for bind <- ["192.168.1.8", {192, 168, 1, 8}] do
        assert {:ok, candidates} =
                 Discovery.discover(bound_host(reverse_lookup: lookup) ++ [bind: bind])

        assert candidates == [%{address: "192.168.1.8", interface: "en0", scope: :lan}]
      end

      refute_received {:reverse_lookup, _address}
    end

    test "a tailnet address keeps its own candidate and its MagicDNS name" do
      assert {:ok, candidates} = Discovery.discover(bound_host() ++ [bind: "100.64.0.1"])

      assert candidates == [
               %{address: "fermix-host.tail123.ts.net", interface: "utun4", scope: :tailnet},
               %{address: "100.64.0.1", interface: "utun4", scope: :tailnet}
             ]
    end

    test "a bind no interface holds yields no candidates" do
      for bind <- ["192.168.9.9", "127.0.0.1", "fd7a:115c:a1e0::1"] do
        assert Discovery.discover(bound_host() ++ [bind: bind]) == {:ok, []}
      end
    end

    test "a malformed bind is refused" do
      for bind <- ["0.0.0", "not-an-address", "", 4_031, {256, 0, 0, 1}] do
        assert_raise ArgumentError, ~r/:bind/, fn ->
          Discovery.discover(bound_host() ++ [bind: bind])
        end
      end
    end

    test "the cache enumerates for its bind, and refuses a malformed one at start" do
      cache = start_supervised!({Discovery, [name: nil, bind: "192.168.1.8"] ++ bound_host()})

      assert Discovery.candidates(cache) ==
               {:ok, [%{address: "192.168.1.8", interface: "en0", scope: :lan}]}

      assert_raise ArgumentError, ~r/:bind/, fn ->
        Discovery.init([name: nil, bind: "0.0.0"] ++ bound_host())
      end
    end
  end

  test "returns the interface enumeration failure" do
    assert Discovery.discover(getifaddrs: fn -> {:error, :eacces} end) == {:error, :eacces}
  end

  test "rejects invalid dependency injection" do
    assert_raise ArgumentError, fn -> Discovery.discover(getifaddrs: :not_a_function) end
  end

  # A host on a LAN with two tailnet addresses, one of which has a MagicDNS name.
  defp bound_host(overrides \\ []) do
    getifaddrs = fn ->
      {:ok,
       [
         {~c"utun4", [flags: [:up, :pointtopoint], addr: {100, 64, 0, 1}]},
         {~c"utun5", [flags: [:up, :pointtopoint], addr: {100, 64, 0, 2}]},
         {~c"en0", [flags: [:up, :broadcast], addr: {192, 168, 1, 8}]},
         {~c"en1", [flags: [:up, :broadcast], addr: {10, 0, 0, 5}]}
       ]}
    end

    Keyword.merge([getifaddrs: getifaddrs, reverse_lookup: &reverse_lookup/2], overrides)
  end

  defp reverse_lookup({100, 64, 0, 1} = address, 750),
    do: {:ok, {:hostent, ~c"fermix-host.tail123.ts.net.", [], :inet, 4, [address]}}

  defp reverse_lookup(_address, 750), do: {:error, :nxdomain}

  defp tailnet(count) do
    fn ->
      {:ok, Enum.map(1..count, &{~c"utun#{&1}", [flags: [:up], addr: {100, 64, 0, &1}]})}
    end
  end
end
