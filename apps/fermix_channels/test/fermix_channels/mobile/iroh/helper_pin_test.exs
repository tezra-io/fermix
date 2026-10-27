defmodule FermixChannels.Mobile.Iroh.HelperPinTest do
  # M62 stage 5 (B1): the helper the release trees carry must pass the rail's
  # `hello` check, which compares exactly these two values. A pin bump to a
  # helper this engine would refuse fails here, not on every host's rail.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.HelperProtocol
  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixCore.Release.IrohHelper

  test "the pinned helper speaks the protocol the rail speaks" do
    assert IrohHelper.read_pin!()["protocol_version"] == HelperProtocol.protocol_version()
  end

  test "the pinned helper runs the iroh the current relays run" do
    assert IrohHelper.read_pin!()["iroh_version"] == Relays.current().iroh
  end
end
