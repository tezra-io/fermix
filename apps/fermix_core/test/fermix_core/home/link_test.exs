defmodule FermixCore.Home.LinkTest do
  # Always On setup §7: one function says how this engine reaches its server,
  # decided from the booted role and the desktop link, for the daemon, the
  # watch and the setup page alike.
  use ExUnit.Case, async: true

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Link
  alias FermixTestSupport.SafeRm

  @link %{
    device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
    primary: %{
      name: "fermix-vm",
      gateway_pk: <<7::256>>,
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef"
    },
    epoch: 4
  }

  setup do
    home = SafeRm.make_tmp_dir!("home-link")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "a linked desktop reaches its server through the rail", %{home: home} do
    :ok = DesktopLink.write(home, @link)

    assert Link.forwarding(%{role: :device, primary: "fermix-vm"}, home) == [
             primary_forward: Function.capture(Link.impl(), :forward, 2)
           ]
  end

  test "any other engine reaches no server", %{home: home} do
    assert Link.forwarding(%{role: :device, primary: "fermix-vm"}, home) == []

    :ok = DesktopLink.write(home, @link)

    for role <- [:primary, :candidate] do
      assert Link.forwarding(%{role: role, primary: nil}, home) == []
    end
  end
end
