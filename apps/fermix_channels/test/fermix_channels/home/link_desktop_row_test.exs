defmodule FermixChannels.Home.LinkDesktopRowTest do
  # A return (Always On's move back) stages the server's home on the computer
  # it left, whose own desktop row is in that home's device list: the staging
  # drops it, so the computer never counts itself as its own desktop.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.Link
  alias FermixChannels.Mobile.DeviceStore
  alias FermixTestSupport.SafeRm

  setup do
    staging = SafeRm.make_tmp_dir!("link_desktop_row")
    on_exit(fn -> SafeRm.rm_rf!(staging) end)
    %{staging: staging}
  end

  test "drops the row of that key and keeps every other", %{staging: staging} do
    mac = row(:desktop, "orchard-mac")
    other = row(:desktop, "studio-mac")
    phone = row(:phone, "Pixel 9")
    for attrs <- [mac, other, phone], do: {:ok, _device} = DeviceStore.add(attrs, root: staging)

    assert :ok = Link.drop_desktop_row(staging, mac.noise_pk)

    assert {:ok, devices} = DeviceStore.list(root: staging)
    assert Enum.sort(Enum.map(devices, & &1.name)) == ["Pixel 9", "studio-mac"]
  end

  test "a list without that key, or no list at all, has nothing to drop", %{staging: staging} do
    assert :ok = Link.drop_desktop_row(staging, :crypto.strong_rand_bytes(32))
    refute File.exists?(DeviceStore.store_path(staging))

    {:ok, _device} = DeviceStore.add(row(:phone, "Pixel 9"), root: staging)
    assert :ok = Link.drop_desktop_row(staging, :crypto.strong_rand_bytes(32))
    assert {:ok, [%{name: "Pixel 9"}]} = DeviceStore.list(root: staging)
  end

  test "a phone's key is never dropped as a desktop's", %{staging: staging} do
    phone = row(:phone, "Pixel 9")
    {:ok, _device} = DeviceStore.add(phone, root: staging)

    assert {:error, {:not_a_desktop, _device_id}} = Link.drop_desktop_row(staging, phone.noise_pk)
    assert {:ok, [_phone]} = DeviceStore.list(root: staging)
  end

  test "a list that cannot be read is named", %{staging: staging} do
    File.mkdir_p!(Path.dirname(DeviceStore.store_path(staging)))
    File.write!(DeviceStore.store_path(staging), "not = [toml")

    assert {:error, _reason} = Link.drop_desktop_row(staging, :crypto.strong_rand_bytes(32))
  end

  defp row(:desktop, name),
    do: %{
      device_id: uuid(),
      name: name,
      model: "macos desktop",
      noise_pk: :crypto.strong_rand_bytes(32),
      created_at: ~U[2031-05-01 10:00:00Z],
      kind: :desktop
    }

  defp row(:phone, name),
    do: %{
      device_id: uuid(),
      name: name,
      model: "Pixel 9",
      noise_pk: :crypto.strong_rand_bytes(32),
      created_at: ~U[2031-05-01 10:00:00Z],
      push_token: nil,
      last_seen: nil,
      apns_key_salt: :crypto.strong_rand_bytes(32)
    }

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
