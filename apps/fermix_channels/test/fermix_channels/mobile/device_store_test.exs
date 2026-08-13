defmodule FermixChannels.Mobile.DeviceStoreTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.DeviceStore.Device

  setup do
    root = Path.join(System.tmp_dir!(), "fermix-mobile-devices-#{unique_id()}")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    %{root: root}
  end

  test "add persists an array-of-tables record and reads it back", %{root: root} do
    attrs = device_attrs()

    assert {:ok, %Device{} = added} = DeviceStore.add(attrs, root: root)
    assert {:ok, ^added} = DeviceStore.fetch(attrs.device_id, root: root)
    assert {:ok, [^added]} = DeviceStore.list(root: root)

    path = Path.join(root, "mobile/devices.toml")
    assert File.read!(path) =~ "[[devices]]"
    assert mode(Path.dirname(path)) == 0o700
    assert mode(path) == 0o600
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "duplicate device id and Noise identity are rejected", %{root: root} do
    attrs = device_attrs()
    assert {:ok, _device} = DeviceStore.add(attrs, root: root)

    assert {:error, {:duplicate_device_id, attrs.device_id}} ==
             DeviceStore.add(%{attrs | noise_pk: :crypto.strong_rand_bytes(32)}, root: root)

    other = %{device_attrs() | noise_pk: attrs.noise_pk}

    assert {:error, {:duplicate_noise_identity, encoded}} =
             DeviceStore.add(other, root: root)

    assert encoded == Base.encode64(attrs.noise_pk)
    assert {:ok, [_only]} = DeviceStore.list(root: root)
  end

  test "update validates and atomically replaces mutable fields", %{root: root} do
    attrs = device_attrs()
    assert {:ok, original} = DeviceStore.add(attrs, root: root)
    seen_at = ~U[2026-08-12 18:30:00Z]

    assert {:ok, updated} =
             DeviceStore.update(
               original.device_id,
               %{name: "Sujeeth's iPhone", push_token: "0123abcd", last_seen: seen_at},
               root: root
             )

    assert updated.name == "Sujeeth's iPhone"
    assert updated.push_token == "0123abcd"
    assert updated.last_seen == seen_at
    assert updated.created_at == original.created_at
    assert {:ok, ^updated} = DeviceStore.fetch(original.device_id, root: root)
  end

  test "last_seen updates are monotonic and equal timestamps are idempotent", %{root: root} do
    attrs = device_attrs()
    assert {:ok, original} = DeviceStore.add(attrs, root: root)
    first_seen = ~U[2026-08-12 18:30:00Z]
    stale_seen = ~U[2026-08-12 18:29:59Z]

    assert {:ok, seen} =
             DeviceStore.update(original.device_id, %{last_seen: first_seen}, root: root)

    assert {:ok, ^seen} =
             DeviceStore.update(original.device_id, %{last_seen: first_seen}, root: root)

    assert {:error, {:last_seen_regression, ^first_seen, ^stale_seen}} =
             DeviceStore.update(original.device_id, %{last_seen: stale_seen}, root: root)

    assert {:error, {:last_seen_regression, ^first_seen, nil}} =
             DeviceStore.update(original.device_id, %{last_seen: nil}, root: root)

    assert {:ok, ^seen} = DeviceStore.fetch(original.device_id, root: root)
  end

  test "delete removes only the requested record", %{root: root} do
    first = device_attrs()
    second = device_attrs()
    assert {:ok, _device} = DeviceStore.add(first, root: root)
    assert {:ok, _device} = DeviceStore.add(second, root: root)

    assert :ok = DeviceStore.delete(first.device_id, root: root)

    assert {:error, {:device_not_found, first.device_id}} ==
             DeviceStore.fetch(first.device_id, root: root)

    assert {:ok, [%Device{device_id: id}]} = DeviceStore.list(root: root)
    assert id == second.device_id
  end

  test "find_by_noise_pk uses the authenticated raw public key", %{root: root} do
    attrs = device_attrs()
    assert {:ok, device} = DeviceStore.add(attrs, root: root)
    assert {:ok, ^device} = DeviceStore.find_by_noise_pk(attrs.noise_pk, root: root)

    unknown = :crypto.strong_rand_bytes(32)

    assert {:error, {:noise_identity_not_found, encoded}} =
             DeviceStore.find_by_noise_pk(unknown, root: root)

    assert encoded == Base.encode64(unknown)
  end

  test "malformed TOML and unsafe permissions fail loudly", %{root: root} do
    mobile_dir = Path.join(root, "mobile")
    path = Path.join(mobile_dir, "devices.toml")
    File.mkdir_p!(mobile_dir)
    File.chmod!(mobile_dir, 0o700)
    File.write!(path, "[[devices]\n")
    File.chmod!(path, 0o600)

    assert {:error, {:devices_decode_failed, ^path, _reason}} = DeviceStore.list(root: root)

    File.chmod!(path, 0o644)
    assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = DeviceStore.list(root: root)
  end

  test "invalid public input is rejected before any filesystem write", %{root: root} do
    attrs = %{device_attrs() | noise_pk: <<1, 2, 3>>}

    assert {:error, {:invalid_device, :noise_pk, :invalid_length}} =
             DeviceStore.add(attrs, root: root)

    refute File.exists?(Path.join(root, "mobile"))
  end

  test "the supervised facade serializes CRUD against its configured root", %{root: root} do
    name = Module.concat(__MODULE__, "Store#{unique_id()}")
    start_supervised!({DeviceStore, root: root, name: name})
    attrs = device_attrs()

    assert {:ok, added} = DeviceStore.add(name, attrs)
    assert {:ok, ^added} = DeviceStore.fetch(name, attrs.device_id)
    assert {:ok, [^added]} = DeviceStore.list(name)
    assert :ok = DeviceStore.delete(name, attrs.device_id)
    assert {:ok, []} = DeviceStore.list(name)
  end

  defp device_attrs do
    %{
      device_id: uuid(),
      name: "iPhone 16 Pro",
      model: "iPhone17,1",
      noise_pk: :crypto.strong_rand_bytes(32),
      push_token: nil,
      created_at: ~U[2026-08-12 18:00:00Z],
      last_seen: nil,
      apns_key_salt: :crypto.strong_rand_bytes(32)
    }
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
  defp unique_id, do: System.unique_integer([:positive, :monotonic])
end
