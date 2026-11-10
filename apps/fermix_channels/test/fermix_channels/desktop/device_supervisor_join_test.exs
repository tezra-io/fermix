defmodule FermixChannels.Desktop.DeviceSupervisorJoinTest do
  # M97 §3.1: a computer joining a home dials it from the dial subtree, after
  # the helper it dials through, until it has a link of its own.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.DeviceSupervisor
  alias FermixChannels.Desktop.Join, as: Joiner
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Join

  test "the joiner runs while the join is here and no link is" do
    root = DesktopRail.root!("fx-dsj")
    assert DeviceSupervisor.dial_children(root) == []

    File.mkdir_p!(Path.join(root, "device"))
    File.write!(Join.path(root), "{}")

    assert [{Helper, _helper}, {Joiner, opts}] = DeviceSupervisor.dial_children(root)
    assert opts[:home] == root
    assert opts[:helper] == DeviceSupervisor.helper()

    File.write!(DesktopLink.path(root), "{}")
    refute Enum.any?(DeviceSupervisor.dial_children(root), &match?({Joiner, _opts}, &1))
  end
end
