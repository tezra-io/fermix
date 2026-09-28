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

    assert {:ok, seen} =
             DeviceStore.update(original.device_id, %{last_seen: first_seen}, root: root)

    assert {:ok, ^seen} =
             DeviceStore.update(original.device_id, %{last_seen: first_seen}, root: root)

    assert {:ok, ^seen} = DeviceStore.fetch(original.device_id, root: root)
  end

  # last_seen is informational: a wall clock that steps backwards must never
  # refuse the update, because the socket's hello would fail with it (SEC-9).
  test "a last_seen earlier than the stored one keeps the later time and never fails",
       %{root: root} do
    assert {:ok, original} = DeviceStore.add(device_attrs(), root: root)
    later = ~U[2026-08-12 18:30:00Z]
    assert {:ok, _seen} = DeviceStore.update(original.device_id, %{last_seen: later}, root: root)

    for stepped_back <- [~U[2026-08-12 18:29:59Z], ~U[2020-01-01 00:00:00Z], nil] do
      assert {:ok, %Device{last_seen: ^later}} =
               DeviceStore.update(original.device_id, %{last_seen: stepped_back}, root: root)
    end

    assert {:ok, %Device{name: "Renamed", last_seen: ^later}} =
             DeviceStore.update(
               original.device_id,
               %{name: "Renamed", last_seen: ~U[2026-08-12 18:00:00Z]},
               root: root
             )
  end

  # Every hello records last_seen; rewriting the trust store for each one is a
  # needless fsync'd write on every reconnect (STB-15).
  test "a last_seen within five minutes of the stored one does not rewrite the store",
       %{root: root} do
    assert {:ok, original} = DeviceStore.add(device_attrs(), root: root)
    first = ~U[2026-08-12 18:30:00Z]
    assert {:ok, _seen} = DeviceStore.update(original.device_id, %{last_seen: first}, root: root)
    path = DeviceStore.store_path(root)
    %File.Stat{inode: inode} = File.lstat!(path)

    assert {:ok, %Device{last_seen: ^first}} =
             DeviceStore.update(original.device_id, %{last_seen: DateTime.add(first, 299)},
               root: root
             )

    assert File.lstat!(path).inode == inode

    moved_on = DateTime.add(first, 300)

    assert {:ok, %Device{last_seen: ^moved_on}} =
             DeviceStore.update(original.device_id, %{last_seen: moved_on}, root: root)

    refute File.lstat!(path).inode == inode
  end

  # A power loss after an unsynced rename can leave a zero-length file, which
  # used to load as "no paired devices" and silently unpair every phone.
  test "a zero-length store is refused, never read as an empty one", %{root: root} do
    assert {:ok, _device} = DeviceStore.add(device_attrs(), root: root)
    path = DeviceStore.store_path(root)
    File.write!(path, "")

    assert {:error, {:devices_store_empty, ^path}} = DeviceStore.list(root: root)
    assert {:error, {:devices_store_empty, ^path}} = DeviceStore.list(root: root)
  end

  test "an empty device list round-trips as an empty store, not a refusal", %{root: root} do
    attrs = device_attrs()
    assert {:ok, _device} = DeviceStore.add(attrs, root: root)
    assert :ok = DeviceStore.delete(attrs.device_id, root: root)
    assert File.read!(DeviceStore.store_path(root)) != ""
    assert {:ok, []} = DeviceStore.list(root: root)
  end

  test "a read never creates the mobile directory", %{root: root} do
    assert {:ok, []} = DeviceStore.list(root: root)

    assert {:error, {:device_not_found, _id}} =
             DeviceStore.delete("11111111-1111-4111-8111-111111111111", root: root)

    refute File.exists?(Path.join(root, "mobile"))
  end

  describe "the supervised store caches the parsed file" do
    setup %{root: root} do
      name = Module.concat(__MODULE__, "Cached#{unique_id()}")
      start_supervised!({DeviceStore, root: root, name: name})
      %{store: name}
    end

    test "an unchanged file is not read again", %{root: root, store: store} do
      attrs = device_attrs()
      assert {:ok, _added} = DeviceStore.add(store, attrs)
      assert {:ok, _device} = DeviceStore.fetch(store, attrs.device_id)

      # Same size, same inode, same times: only the bytes changed. A cached
      # store answers from memory; a store that re-read would refuse this.
      path = DeviceStore.store_path(root)
      stat = File.lstat!(path, time: :posix)
      File.write!(path, String.duplicate(" ", stat.size))
      File.touch!(path, stat.mtime)
      File.touch!(path, stat.mtime)
      assert %File.Stat{size: size, inode: inode} = File.lstat!(path, time: :posix)
      assert {size, inode} == {stat.size, stat.inode}

      assert {:ok, %Device{}} = DeviceStore.fetch(store, attrs.device_id)
    end

    test "its own delete is seen by the next fetch", %{store: store} do
      attrs = device_attrs()
      assert {:ok, _added} = DeviceStore.add(store, attrs)
      assert {:ok, _device} = DeviceStore.fetch(store, attrs.device_id)
      assert :ok = DeviceStore.delete(store, attrs.device_id)

      assert {:error, {:device_not_found, _id}} = DeviceStore.fetch(store, attrs.device_id)
    end

    # The per-frame revocation check depends on this: an operator who edits or
    # replaces the file by hand must be seen on the very next frame.
    test "a file replaced outside the daemon is re-read", %{root: root, store: store} do
      first = device_attrs()
      second = device_attrs()
      assert {:ok, _added} = DeviceStore.add(store, first)
      assert {:ok, [_one]} = DeviceStore.list(store)

      assert {:ok, _added} = DeviceStore.add(second, root: root)
      assert {:ok, [_one, _two]} = DeviceStore.list(store)

      assert :ok = DeviceStore.delete(first.device_id, root: root)
      assert {:error, {:device_not_found, _id}} = DeviceStore.fetch(store, first.device_id)
    end

    test "a file whose permissions changed is validated again", %{root: root, store: store} do
      assert {:ok, _added} = DeviceStore.add(store, device_attrs())
      assert {:ok, [_one]} = DeviceStore.list(store)
      path = DeviceStore.store_path(root)
      File.chmod!(path, 0o644)

      assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = DeviceStore.list(store)
    end
  end

  describe "add_approved/2" do
    # A phone whose `pair_approved` was lost never sent a hello, so its row is
    # an orphan the duplicate-key guard would otherwise hold forever (STB-13).
    test "replaces an earlier approval of the same phone that never said hello",
         %{root: root} do
      orphan = device_attrs()
      assert {:ok, _orphan} = DeviceStore.add(orphan, root: root)
      again = %{device_attrs() | noise_pk: orphan.noise_pk}

      assert {:ok, %Device{device_id: id}} = DeviceStore.add_approved(again, root: root)
      assert id == again.device_id
      assert {:ok, [%Device{device_id: ^id}]} = DeviceStore.list(root: root)
    end

    test "never replaces a phone that has connected", %{root: root} do
      paired = device_attrs()
      assert {:ok, _paired} = DeviceStore.add(paired, root: root)

      assert {:ok, _seen} =
               DeviceStore.update(paired.device_id, %{last_seen: ~U[2026-08-12 19:00:00Z]},
                 root: root
               )

      again = %{device_attrs() | noise_pk: paired.noise_pk}

      assert {:error, {:duplicate_noise_identity, _key}} =
               DeviceStore.add_approved(again, root: root)

      assert {:ok, [%Device{device_id: id}]} = DeviceStore.list(root: root)
      assert id == paired.device_id
    end

    test "the supervised facade admits a new phone like add/2", %{root: root} do
      name = Module.concat(__MODULE__, "Approved#{unique_id()}")
      start_supervised!({DeviceStore, root: root, name: name})
      attrs = device_attrs()

      assert {:ok, %Device{}} = DeviceStore.add_approved(name, attrs)
      assert {:ok, [_one]} = DeviceStore.list(name)
    end
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
