defmodule FermixCore.Realtime.DeviceIdentityTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.DeviceIdentity

  test "ensure_device_id creates a stable opaque UUID under the realtime directory" do
    dir = Path.join(System.tmp_dir!(), "fermix-device-#{System.unique_integer([:positive])}")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    assert {:ok, first} = DeviceIdentity.ensure_device_id(dir)
    assert {:ok, second} = DeviceIdentity.ensure_device_id(dir)

    assert first == second
    assert String.match?(first, ~r/^[0-9a-f-]{36}$/)
    assert File.read!(Path.join(dir, "device_id")) == first
    assert Bitwise.band(File.stat!(Path.join(dir, "device_id")).mode, 0o777) == 0o600
  end

  test "safety_identifier is deterministic and does not expose raw owner or device IDs" do
    owner_id = "owner@example.com"
    device_id = "0f37659e-7a57-4c31-b0c1-650c95dd80bd"

    first = DeviceIdentity.safety_identifier(owner_id, device_id)
    second = DeviceIdentity.safety_identifier(owner_id, device_id)

    assert first == second
    assert byte_size(first) == 32
    refute first =~ owner_id
    refute first =~ device_id
  end
end
