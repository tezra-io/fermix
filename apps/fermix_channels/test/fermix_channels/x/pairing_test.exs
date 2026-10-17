defmodule FermixChannels.X.PairingTest do
  # The instance key and the pairing record (priv/connect/PROTOCOL.md §1),
  # under a home of the test's own: never FERMIX_HOME.
  use ExUnit.Case, async: true

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Pairing
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("x-pairing")
    on_exit(fn -> SafeRm.rm_rf(home) end)
    %{opts: [root: home], home: home}
  end

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o777)

  defp record_for(opts) do
    {:ok, public_key} = Pairing.ensure_key(opts)
    {connect_public, _seed} = Fixtures.connect_key()
    Fixtures.record(connect_public, %{key_id: Pairing.key_id(public_key)})
  end

  test "the paths are the home's x directory", %{opts: opts, home: home} do
    assert Pairing.root(opts) == Path.expand(home)
    assert Pairing.key_path(opts) == Path.join([home, "x", "instance_key"])
    assert Pairing.record_path(opts) == Path.join([home, "x", "pairing.json"])
  end

  test "the key is created once, 0600 in a 0700 directory, and then only loaded", %{opts: opts} do
    assert {:error, {:missing, _path}} = Pairing.public_key(opts)

    assert {:ok, <<_::256>> = public_key} = Pairing.ensure_key(opts)
    assert mode(Pairing.key_path(opts)) == 0o600
    assert mode(Path.dirname(Pairing.key_path(opts))) == 0o700
    assert byte_size(File.read!(Pairing.key_path(opts))) == 32

    assert {:ok, ^public_key} = Pairing.ensure_key(opts)
    assert {:ok, ^public_key} = Pairing.public_key(opts)
    assert Path.wildcard(Pairing.key_path(opts) <> ".tmp.*") == []
  end

  test "a key of the wrong mode or length is refused, never replaced", %{opts: opts} do
    {:ok, _public_key} = Pairing.ensure_key(opts)
    path = Pairing.key_path(opts)

    File.chmod!(path, 0o644)
    assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = Pairing.ensure_key(opts)

    File.chmod!(path, 0o600)
    File.write!(path, "short")
    assert {:error, {:invalid_key, ^path, :invalid_length}} = Pairing.ensure_key(opts)
    assert File.read!(path) == "short"
  end

  test "a directory of the wrong mode is refused", %{opts: opts} do
    dir = Path.dirname(Pairing.key_path(opts))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)

    assert {:error, {:unsafe_permissions, ^dir, 0o755, 0o700}} = Pairing.ensure_key(opts)
  end

  test "key_id and fingerprint have the contract's shapes" do
    public_key = :binary.copy(<<7>>, 32)
    hex = :sha256 |> :crypto.hash(public_key) |> Base.encode16(case: :lower)

    assert Pairing.key_id(public_key) == "k" <> binary_part(hex, 0, 16)
    assert Regex.match?(~r/\Ak[0-9a-f]{16}\z/, Pairing.key_id(public_key))

    fingerprint = Pairing.fingerprint(public_key)
    assert Regex.match?(~r/\A[0-9a-f]{4}( [0-9a-f]{4}){15}\z/, fingerprint)
    assert String.replace(fingerprint, " ", "") == hex
  end

  test "sign and verify round-trip with the instance key", %{opts: opts} do
    assert {:error, {:missing, _path}} = Pairing.sign("hello", opts)
    {:ok, public_key} = Pairing.ensure_key(opts)

    assert {:ok, signature} = Pairing.sign("fermix-connect-session|x", opts)
    assert byte_size(signature) == 64
    assert Pairing.verify("fermix-connect-session|x", signature, public_key)
    refute Pairing.verify("fermix-connect-session|y", signature, public_key)
    refute Pairing.verify("fermix-connect-session|x", "short", public_key)
    refute Pairing.verify("fermix-connect-session|x", signature, "not a key")
  end

  test "no record is :unpaired; a saved record loads back as written", %{opts: opts} do
    assert {:error, :unpaired} = Pairing.load(opts)

    record = record_for(opts)
    assert :ok = Pairing.save(record, opts)
    assert mode(Pairing.record_path(opts)) == 0o600
    assert {:ok, ^record} = Pairing.load(opts)

    document = opts |> Pairing.record_path() |> File.read!() |> Jason.decode!()

    assert Map.keys(document) |> Enum.sort() ==
             Enum.sort(Map.keys(Map.from_struct(record)) |> Enum.map(&Atom.to_string/1))
  end

  test "a record is written once and never replaced", %{opts: opts} do
    record = record_for(opts)
    assert :ok = Pairing.save(record, opts)

    assert {:error, :already_paired} =
             Pairing.save(%{record | handle: "@someone_else"}, opts)

    assert {:ok, ^record} = Pairing.load(opts)
  end

  test "a record that breaks the contract is refused with its reason", %{opts: opts} do
    record = record_for(opts)
    :ok = Pairing.save(record, opts)
    path = Pairing.record_path(opts)

    rewrite = fn change ->
      document = path |> File.read!() |> Jason.decode!() |> change.()
      File.chmod!(path, 0o600)
      File.write!(path, Jason.encode!(document))
    end

    rewrite.(&Map.put(&1, "origin", "http://connect.fermix.example"))
    assert {:error, {:invalid_record, {:origin, :invalid_format}}} = Pairing.load(opts)

    rewrite.(&Map.put(&1, "origin", "https://connect.fermix.example"))
    rewrite.(&Map.put(&1, "tenant_generation", 0))

    assert {:error, {:invalid_record, {:tenant_generation, :not_a_generation}}} =
             Pairing.load(opts)

    rewrite.(&Map.merge(&1, %{"tenant_generation" => 1, "extra" => true}))
    assert {:error, {:invalid_record, {:unknown_fields, ["extra"]}}} = Pairing.load(opts)

    File.write!(path, "not json")
    assert {:error, {:invalid_record, :not_json}} = Pairing.load(opts)

    File.chmod!(path, 0o644)

    assert {:error, {:invalid_record, {:unsafe_permissions, ^path, 0o644, 0o600}}} =
             Pairing.load(opts)

    assert File.read!(path) == "not json"
  end

  test "an invalid record is not saved", %{opts: opts} do
    record = %{record_for(opts) | connect_public_key: "too-short"}
    assert {:error, {:connect_public_key, :not_a_public_key}} = Pairing.save(record, opts)
    assert {:error, :unpaired} = Pairing.load(opts)
  end

  test "delete removes the record and the key; nothing there is fine", %{opts: opts} do
    :ok = Pairing.save(record_for(opts), opts)

    assert :ok = Pairing.delete(opts)
    refute File.exists?(Pairing.record_path(opts))
    refute File.exists?(Pairing.key_path(opts))
    assert :ok = Pairing.delete(opts)
  end
end
