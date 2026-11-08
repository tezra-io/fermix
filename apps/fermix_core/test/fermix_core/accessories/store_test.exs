defmodule FermixCore.Accessories.StoreTest do
  # The accessory pairing store under `<home>/accessories/` (M91 §07, D7, D14):
  # the host key and the enrolled accessories' records, owner-only, written
  # whole or not at all. Every test runs in a home of its own.
  use ExUnit.Case, async: true

  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Store
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("accessory-store")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp record(name \\ "StackChan") do
    {pk, _private} = P256.generate()

    %Record{
      accessory_id: P256.id(pk),
      accessory_pk: pk,
      kind: "stackchan",
      name: name,
      port_hint: "80:45:6B:54:87:FC",
      enrolled_at: ~U[2026-11-07 22:04:22Z]
    }
  end

  defp mode(path), do: path |> File.lstat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777)

  test "the host key is made once, owner-only, and loaded the same ever after", %{home: home} do
    assert :absent = Store.load_host_key(home)
    refute File.exists?(Store.dir(home))

    assert {:ok, %HostKey{} = key} = Store.ensure_host_key(home)
    assert mode(Store.dir(home)) == 0o700
    assert mode(Store.host_key_path(home)) == 0o600
    assert File.read!(Store.host_key_path(home)) == key.private
    assert key.id == P256.id(key.public)

    assert {:ok, ^key} = Store.ensure_host_key(home)
    assert {:ok, ^key} = Store.load_host_key(home)
  end

  test "a host key that is not owner-only, not a file, or not a key is refused, never replaced",
       %{home: home} do
    {:ok, key} = Store.ensure_host_key(home)
    path = Store.host_key_path(home)

    File.chmod!(path, 0o644)
    assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = Store.load_host_key(home)
    assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = Store.ensure_host_key(home)
    File.chmod!(path, 0o600)

    File.write!(path, <<0::256>>)
    assert {:error, {:invalid_host_key, ^path}} = Store.ensure_host_key(home)
    File.write!(path, "short")
    assert {:error, {:invalid_host_key, ^path}} = Store.load_host_key(home)

    target = Path.join(home, "elsewhere")
    File.write!(target, key.private)
    File.chmod!(target, 0o600)
    File.rename!(path, path <> ".moved")
    File.ln_s!(target, path)
    assert {:error, {:unsafe_file_type, ^path, :symlink, :regular}} = Store.ensure_host_key(home)
  end

  test "a host key another writer published first is the one loaded, and nothing is left behind",
       %{home: home} do
    {other_public, other_private} = P256.generate()

    first_writer = fn temp, path ->
      File.write!(path, other_private)
      File.chmod!(path, 0o600)
      assert File.exists?(temp)
      {:error, :eexist}
    end

    assert {:ok, %HostKey{public: ^other_public}} =
             Store.ensure_host_key(home, link: first_writer)

    assert File.ls!(Store.dir(home)) == ["host_key"]
  end

  test "a store directory others can read is refused", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    dir = Store.dir(home)
    File.chmod!(dir, 0o755)

    assert {:error, {:unsafe_permissions, ^dir, 0o755, 0o700}} = Store.load_host_key(home)
    assert {:error, {:unsafe_permissions, ^dir, 0o755, 0o700}} = Store.list(home)
  end

  test "records round-trip, owner-only, sorted, one per accessory", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    assert {:ok, []} = Store.list(home)

    first = record("Desk")
    second = record("Shelf")
    assert :ok = Store.put(home, first)
    assert :ok = Store.put(home, second)
    assert :ok = Store.put(home, %{first | name: "Desk, again"})

    assert {:ok, records} = Store.list(home)
    assert records == Enum.sort_by([%{first | name: "Desk, again"}, second], & &1.accessory_id)
    assert {:ok, %Record{name: "Shelf"}} = Store.fetch(home, second.accessory_id)
    assert mode(Store.records_path(home)) == 0o600

    on_disk = home |> Store.records_path() |> File.read!() |> Jason.decode!()
    assert on_disk["v"] == 1
    assert [%{"accessory_pk" => pk_hex} | _] = on_disk["accessories"]
    assert pk_hex =~ ~r/\A04[0-9a-f]{128}\z/

    assert :ok = Store.forget(home, first.accessory_id)
    assert {:error, :unknown_accessory} = Store.fetch(home, first.accessory_id)
    assert {:error, :unknown_accessory} = Store.forget(home, first.accessory_id)
    assert {:ok, [^second]} = Store.list(home)
  end

  test "a record needs the host key, its own key, and an ID that is that key's digest", %{
    home: home
  } do
    assert {:error, :no_host_key} = Store.put(home, record())

    {:ok, key} = Store.ensure_host_key(home)
    reuse = %{record() | accessory_pk: key.public, accessory_id: key.id}
    assert {:error, :host_key_reuse} = Store.put(home, reuse)

    mismatched = %{record() | accessory_id: String.duplicate("0", 64)}
    assert {:error, {:invalid_record, :accessory_id}} = Store.put(home, mismatched)
    assert {:ok, []} = Store.list(home)
  end

  test "a failed write leaves the old records whole and no temporary file", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    kept = record()
    :ok = Store.put(home, kept)
    before = File.read!(Store.records_path(home))

    failing = fn _from, _to -> {:error, :eio} end
    assert {:error, {:write_failed, _path, :eio}} = Store.put(home, record(), rename: failing)

    assert {:error, {:write_failed, _path, :eio}} =
             Store.forget(home, kept.accessory_id, rename: failing)

    assert File.read!(Store.records_path(home)) == before
    assert File.ls!(Store.dir(home)) |> Enum.sort() == ["accessories.json", "host_key"]
  end

  test "an interrupted write's leftover is not read, and an empty records file is an error",
       %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    kept = record()
    :ok = Store.put(home, kept)
    File.write!(Store.records_path(home) <> ".tmp.17", "{\"v\":1,\"acc")
    assert {:ok, [^kept]} = Store.list(home)

    File.write!(Store.records_path(home), "")
    path = Store.records_path(home)
    assert {:error, {:records_empty, ^path}} = Store.list(home)
  end

  test "records that are not the store's own are refused with the field that fails", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    :ok = Store.put(home, record())
    path = Store.records_path(home)
    good = path |> File.read!() |> Jason.decode!()

    for {broken, field} <- [
          {put_in(
             good,
             ["accessories", Access.at(0), "accessory_pk"],
             "04" <> String.duplicate("00", 64)
           ), :accessory_pk},
          {put_in(good, ["accessories", Access.at(0), "kind"], "Stack Chan"), :kind},
          {put_in(good, ["accessories", Access.at(0), "enrolled_at"], "yesterday"), :enrolled_at},
          {Map.put(good, "v", 2), :v}
        ] do
      File.write!(path, Jason.encode!(broken))
      assert {:error, {:invalid_records, ^path, ^field}} = Store.list(home), inspect(field)
    end
  end

  test "a home whose records outlived their host key does not get a new host key", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    :ok = Store.put(home, record())
    SafeRm.rm!(Store.host_key_path(home))

    path = Store.host_key_path(home)
    assert {:error, {:host_key_missing, ^path}} = Store.ensure_host_key(home)
    refute File.exists?(path)
  end

  test "the store holds a bounded number of accessories", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    for _ <- 1..Store.max_records(), do: :ok = Store.put(home, record())

    assert {:error, :records_full} = Store.put(home, record())
    assert {:ok, records} = Store.list(home)
    assert length(records) == Store.max_records()
  end

  # M91 §07: the voice device the owner chose, a file beside the records that
  # travels with the home; this Mac's own audio until an accessory is chosen.
  test "the voice device is this Mac until a paired accessory is chosen", %{home: home} do
    assert {:ok, :desktop} = Store.load_voice_device(home)
    refute File.exists?(Store.dir(home))

    {:ok, _key} = Store.ensure_host_key(home)
    robot = record()
    :ok = Store.put(home, robot)

    assert :ok = Store.put_voice_device(home, {:accessory, robot.accessory_id})
    assert {:ok, {:accessory, id}} = Store.load_voice_device(home)
    assert id == robot.accessory_id
    assert mode(Store.voice_device_path(home)) == 0o600

    assert :ok = Store.put_voice_device(home, :desktop)
    assert {:ok, :desktop} = Store.load_voice_device(home)
  end

  test "only a paired accessory can be the voice device", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    stranger = record()

    assert {:error, :unknown_accessory} =
             Store.put_voice_device(home, {:accessory, stranger.accessory_id})

    assert {:ok, :desktop} = Store.load_voice_device(home)
  end

  test "forgetting the voice device makes this Mac the voice device again", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    kept = record("Kept")
    forgotten = record("Forgotten")
    :ok = Store.put(home, kept)
    :ok = Store.put(home, forgotten)

    :ok = Store.put_voice_device(home, {:accessory, kept.accessory_id})
    :ok = Store.forget(home, forgotten.accessory_id)
    assert {:ok, {:accessory, kept_id}} = Store.load_voice_device(home)
    assert kept_id == kept.accessory_id

    :ok = Store.forget(home, kept.accessory_id)
    assert {:ok, :desktop} = Store.load_voice_device(home)
  end

  test "a voice device file that is not the store's own is refused by name", %{home: home} do
    {:ok, _key} = Store.ensure_host_key(home)
    path = Store.voice_device_path(home)
    File.write!(path, ~s({"v":1,"device":"phone:abc"}))
    File.chmod!(path, 0o600)

    assert {:error, {:invalid_voice_device, ^path}} = Store.load_voice_device(home)

    File.chmod!(path, 0o644)
    assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = Store.load_voice_device(home)
  end

  test "the store reads only the home it is given" do
    assert_raise FunctionClauseError, fn -> Store.list("") end
    assert_raise FunctionClauseError, fn -> Store.ensure_host_key(nil) end
  end
end
