defmodule FermixChannels.Mobile.Iroh.HintsTest do
  # The direct address hints an Always On server gives its desktops, and the
  # fixed port they name. Every interface list is the test's own: nothing
  # here reads this computer's interfaces.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.Hints
  alias FermixCore.Home.Candidate
  alias FermixTestSupport.SafeRm

  @up [:up, :broadcast, :running, :multicast]

  defp interfaces(list), do: fn -> {:ok, list} end

  # What `fermix home enroll` leaves on the machine it makes a candidate.
  defp mark_server!(home) do
    File.mkdir_p!(Path.dirname(Candidate.server_path(home)))
    File.write!(Candidate.server_path(home), ~s({"v":1}))
  end

  describe "tailnet/2" do
    test "names each tailnet address at the port, IPv4 before IPv6, and nothing else" do
      found =
        interfaces([
          {~c"lo0",
           [
             flags: [:up, :loopback, :running],
             addr: {127, 0, 0, 1},
             addr: {0, 0, 0, 0, 0, 0, 0, 1}
           ]},
          {~c"en0",
           [
             flags: @up,
             addr: {192, 168, 4, 20},
             netmask: {255, 255, 255, 0},
             addr: {0xFE80, 0, 0, 0, 0x1C2A, 0x3B4C, 0x5D6E, 0x7F80},
             addr: {203, 0, 113, 9}
           ]},
          {~c"tailscale0",
           [
             flags: [:up, :pointtopoint, :running, :multicast],
             addr: {0xFD7A, 0x115C, 0xA1E0, 0xAB12, 0x4843, 0xCD96, 0x6258, 0xB240},
             addr: {100, 101, 102, 103}
           ]}
        ])

      assert Hints.tailnet(found, 4033) == [
               "100.101.102.103:4033",
               "[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]:4033"
             ]
    end

    test "keeps only 100.64.0.0/10 and fd7a:115c:a1e0::/48" do
      found =
        interfaces([
          {~c"tailscale0",
           [
             flags: @up,
             addr: {100, 63, 255, 255},
             addr: {100, 64, 0, 1},
             addr: {100, 127, 255, 254},
             addr: {100, 128, 0, 1},
             addr: {0xFD7A, 0x115C, 0xA1E1, 0, 0, 0, 0, 1},
             addr: {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 7}
           ]}
        ])

      assert Hints.tailnet(found, 4033) == [
               "100.64.0.1:4033",
               "100.127.255.254:4033",
               "[fd7a:115c:a1e0::7]:4033"
             ]
    end

    test "an interface that is down or a loopback gives none, and an address is named once" do
      found =
        interfaces([
          {~c"tailscale0", [flags: [:broadcast], addr: {100, 70, 1, 2}]},
          {~c"lo9", [flags: [:up, :loopback], addr: {100, 70, 1, 3}]},
          {~c"utun4", [flags: @up, addr: {100, 70, 1, 4}]},
          {~c"utun5", [flags: @up, addr: {100, 70, 1, 4}]}
        ])

      assert Hints.tailnet(found, 4033) == ["100.70.1.4:4033"]
    end

    test "no tailnet is the normal case: no hints" do
      found = interfaces([{~c"eth0", [flags: @up, addr: {10, 0, 0, 5}, addr: {198, 51, 100, 7}]}])
      assert Hints.tailnet(found, 4033) == []
    end

    test "at most eight, the most a dial takes" do
      addrs = for n <- 1..12, do: {:addr, {100, 80, 0, n}}
      found = interfaces([{~c"tailscale0", [{:flags, @up} | addrs]}])

      hints = Hints.tailnet(found, 4033)
      assert length(hints) == 8
      assert hd(hints) == "100.80.0.1:4033"
    end

    test "interfaces that cannot be listed give no hints, and say why in the log" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Hints.tailnet(fn -> {:error, :eacces} end, 4033) == []
        end)

      assert log =~ "no address hints"
      assert log =~ "eacces"
    end
  end

  describe "bind_port/1" do
    setup do
      home = Path.join(System.tmp_dir!(), "fx-hints-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      SafeRm.mark!(home)
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      %{home: home}
    end

    test "an Always On server binds 4033", %{home: home} do
      mark_server!(home)

      assert Hints.bind_port(home) == 4033
      assert Hints.server_port() == 4033
    end

    test "any other engine keeps iroh's own port", %{home: home} do
      assert Hints.bind_port(home) == nil
    end
  end
end
