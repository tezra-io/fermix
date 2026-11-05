defmodule FermixCore.Home.DesktopLinkTest do
  # M75 §3, §6: the two files that make a device-role engine a desktop of its
  # primary, as the move worker writes them and the relay reads them.
  use ExUnit.Case, async: true

  alias FermixCore.Home.DesktopLink
  alias FermixTestSupport.SafeRm

  @link %{
    device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
    primary: %{
      name: "fermix-vm",
      gateway_pk: <<7::256>>,
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      addrs: ["100.101.102.103:4033", "[fd7a:115c:a1e0::9]:4033"]
    },
    epoch: 4
  }

  setup do
    home = SafeRm.make_tmp_dir!("desktop-link")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "the link round-trips, owner-only, in a device folder of its own", %{home: home} do
    assert :ok = DesktopLink.write(home, @link)
    assert {:ok, @link} = DesktopLink.read(home)

    assert {:ok, %{mode: mode}} = File.stat(DesktopLink.path(home))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, %{mode: dir_mode}} = File.stat(Path.dirname(DesktopLink.path(home)))
    assert Bitwise.band(dir_mode, 0o777) == 0o700

    on_disk = home |> DesktopLink.path() |> File.read!() |> Jason.decode!()
    assert on_disk["v"] == 1
    assert on_disk["primary_epoch"] == 4
    assert on_disk["primary"]["gateway_pk"] == Base.encode64(<<7::256>>)
  end

  test "a file that is not one Fermix wrote is refused, naming the field", %{home: home} do
    assert :ok = DesktopLink.write(home, @link)
    path = DesktopLink.path(home)
    good = path |> File.read!() |> Jason.decode!()

    for {field, broken} <- [
          {:v, Map.put(good, "v", 2)},
          {:device_id, Map.put(good, "device_id", "desk")},
          {:primary_epoch, Map.put(good, "primary_epoch", 0)},
          {:node_id, put_in(good, ["primary", "node_id"], "AB")},
          {:gateway_pk, put_in(good, ["primary", "gateway_pk"], "short")},
          {:relays, put_in(good, ["primary", "relays"], [%{"url" => "http://x/"}])},
          {:name, put_in(good, ["primary", "name"], "two\nlines")},
          {:addrs, put_in(good, ["primary", "addrs"], ["100.101.102.103"])},
          {:addrs, put_in(good, ["primary", "addrs"], ["100.101.102.103:0"])},
          {:addrs, put_in(good, ["primary", "addrs"], ["fd7a:115c:a1e0::9:4033"])},
          {:addrs, put_in(good, ["primary", "addrs"], ["fermix-vm.ts.net:4033"])},
          {:addrs, put_in(good, ["primary", "addrs"], List.duplicate("100.64.0.1:4033", 9))},
          {:addrs, put_in(good, ["primary", "addrs"], nil)}
        ] do
      File.write!(path, Jason.encode!(broken))
      assert {:error, {:invalid_link, ^path, ^field}} = DesktopLink.read(home)
    end

    File.write!(path, "not json")
    assert {:error, {:invalid_link, ^path, :json}} = DesktopLink.read(home)

    assert {:error, {:invalid_link, _path, :device_id}} =
             DesktopLink.write(home, %{@link | device_id: "x"})
  end

  test "the epoch only rises, and a new route is kept", %{home: home} do
    assert :ok = DesktopLink.write(home, @link)
    assert {:ok, %{epoch: 4}} = DesktopLink.record_epoch(home, @link, 3)
    assert {:ok, %{epoch: 4}} = DesktopLink.read(home)

    assert {:ok, raised} = DesktopLink.record_epoch(home, @link, 5)
    assert {:ok, ^raised} = DesktopLink.read(home)

    relays = [%{"url" => "https://two.invalid/", "quic_port" => 7843}]
    addrs = ["100.64.7.8:4033"]

    assert {:ok, routed} =
             DesktopLink.record_route(home, raised, {relays, "fedcba9876543210", addrs})

    assert {:ok, %{primary: %{relays: ^relays, relays_rev: "fedcba9876543210", addrs: ^addrs}}} =
             DesktopLink.read(home)

    assert {:ok, ^routed} =
             DesktopLink.record_route(home, routed, {relays, "fedcba9876543210", addrs})

    # A server that has no hints now (its Tailscale went away) has none kept.
    assert {:ok, %{primary: %{addrs: []}}} =
             DesktopLink.record_route(home, routed, {relays, "fedcba9876543210", []})

    assert {:ok, %{primary: %{addrs: []}}} = DesktopLink.read(home)
  end

  test "a link written without hints holds none", %{home: home} do
    plain = %{@link | primary: Map.delete(@link.primary, :addrs)}
    assert :ok = DesktopLink.write(home, plain)
    assert {:ok, %{primary: %{addrs: []}}} = DesktopLink.read(home)

    # One from before hints were kept reads as none.
    path = DesktopLink.path(home)

    older =
      path |> File.read!() |> Jason.decode!() |> update_in(["primary"], &Map.delete(&1, "addrs"))

    File.write!(path, Jason.encode!(older))
    assert {:ok, %{primary: %{addrs: []}}} = DesktopLink.read(home)
  end

  test "a hint is an IPv4 address or a bracketed IPv6 one, with its port" do
    for hint <- ["100.64.0.1:4033", "[fd7a:115c:a1e0::1]:4033", "127.0.0.1:1"],
        do: assert(DesktopLink.hint?(hint), hint)

    for hint <- [
          "100.64.0.1",
          "fd7a::1:4033",
          "[fd7a::1]",
          "[fd7a::1]:65536",
          "a.ts.net:4033",
          4033,
          ""
        ],
        do: refute(DesktopLink.hint?(hint), inspect(hint))
  end

  test "the key is read only at 0600, and a looser mode is refused by name", %{home: home} do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    assert :ok = DesktopLink.write_key(home, private)
    assert {:ok, %{private: ^private, public: ^public}} = DesktopLink.read_key(home)

    path = DesktopLink.key_path(home)
    File.chmod!(path, 0o644)
    assert {:error, {:key_mode, ^path, 0o644}} = DesktopLink.read_key(home)

    assert DesktopLink.error_sentence({:key_mode, path, 0o644}) ==
             "The desktop key file is mode 0644, readable by others; Fermix uses it only at 0600."

    File.chmod!(path, 0o600)
    File.write!(path, "short")
    assert {:error, {:invalid_key, ^path, :length}} = DesktopLink.read_key(home)
  end

  test "linked only in the device role with the link present", %{home: home} do
    refute DesktopLink.linked?(%{role: :device, primary: nil}, home)
    assert :ok = DesktopLink.write(home, @link)
    assert DesktopLink.linked?(%{role: :device, primary: "fermix-vm"}, home)
    refute DesktopLink.linked?(%{role: :primary, primary: nil}, home)
  end
end
