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
    refute_receive {:reverse_lookup, {100, 64, 0, 9}, 750}
  end

  test "returns the interface enumeration failure" do
    assert Discovery.discover(getifaddrs: fn -> {:error, :eacces} end) == {:error, :eacces}
  end

  test "rejects invalid dependency injection" do
    assert_raise ArgumentError, fn -> Discovery.discover(getifaddrs: :not_a_function) end
  end
end
