defmodule FermixChannels.Mobile.IdentityTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Identity

  setup do
    root = Path.join(System.tmp_dir!(), "fermix-mobile-identity-#{unique_id()}")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    %{root: root}
  end

  test "ensure creates one stable X25519 and P-256 TLS identity", %{root: root} do
    assert {:ok, first} = Identity.ensure(root: root)
    assert {:ok, second} = Identity.ensure(root: root)
    assert {:ok, loaded} = Identity.load(root: root)

    assert first.gateway_private_key == second.gateway_private_key
    assert first.gateway_public_key == loaded.gateway_public_key
    assert byte_size(first.gateway_private_key) == 32
    assert byte_size(first.gateway_public_key) == 32
    assert byte_size(first.tls_fingerprint) == 32

    assert {first.gateway_public_key, first.gateway_private_key} ==
             :crypto.generate_key(:ecdh, :x25519, first.gateway_private_key)

    assert X509.PublicKey.derive(first.tls_private_key) ==
             X509.Certificate.public_key(first.tls_certificate)

    assert :public_key.pkix_is_self_signed(first.tls_certificate)
  end

  test "identity artifacts use the required paths and permissions", %{root: root} do
    assert {:ok, identity} = Identity.ensure(root: root)
    mobile_dir = Path.join(root, "mobile")

    assert identity.tls_key_path == Path.join(mobile_dir, "tls.key")
    assert identity.tls_cert_path == Path.join(mobile_dir, "tls.crt")
    assert mode(mobile_dir) == 0o700
    assert mode(Path.join(mobile_dir, "gateway_key")) == 0o600
    assert mode(identity.tls_key_path) == 0o600
    assert mode(identity.tls_cert_path) == 0o600
    assert Path.wildcard(Path.join(mobile_dir, "*.tmp.*")) == []
  end

  test "ensure refuses an incomplete identity instead of rotating it", %{root: root} do
    mobile_dir = Path.join(root, "mobile")
    File.mkdir_p!(mobile_dir)
    File.chmod!(mobile_dir, 0o700)
    gateway_path = Path.join(mobile_dir, "gateway_key")
    File.write!(gateway_path, :crypto.strong_rand_bytes(32))
    File.chmod!(gateway_path, 0o600)

    assert {:error, {:identity_incomplete, missing}} = Identity.ensure(root: root)

    assert Enum.sort(missing) ==
             Enum.sort([Path.join(mobile_dir, "tls.crt"), Path.join(mobile_dir, "tls.key")])

    assert File.read!(gateway_path) |> byte_size() == 32
  end

  test "load rejects corrupt keys and never replaces them", %{root: root} do
    assert {:ok, identity} = Identity.ensure(root: root)
    gateway_path = Path.join(root, "mobile/gateway_key")
    File.write!(gateway_path, "not-an-x25519-key")

    assert {:error, {:invalid_gateway_key, ^gateway_path, :invalid_length}} =
             Identity.load(root: root)

    assert File.read!(gateway_path) == "not-an-x25519-key"
    assert File.exists?(identity.tls_key_path)
  end

  test "load rejects unsafe file permissions", %{root: root} do
    assert {:ok, identity} = Identity.ensure(root: root)
    File.chmod!(identity.tls_key_path, 0o644)

    assert {:error, {:unsafe_permissions, path, 0o644, 0o600}} = Identity.load(root: root)
    assert path == identity.tls_key_path
  end

  test "a failed multi-file publish rolls back every identity artifact", %{root: root} do
    Process.put(:identity_rename_count, 0)

    rename = fn source, target ->
      count = Process.get(:identity_rename_count) + 1
      Process.put(:identity_rename_count, count)
      if count == 3, do: {:error, :injected_publish_failure}, else: File.rename(source, target)
    end

    assert {:error, {:identity_write_failed, _path, :injected_publish_failure}} =
             Identity.ensure(root: root, rename: rename)

    {:ok, paths} = Identity.paths(root: root)
    refute File.exists?(paths.gateway_key)
    refute File.exists?(paths.tls_key)
    refute File.exists?(paths.tls_cert)
    refute File.exists?(paths.transaction)
    assert {:ok, _identity} = Identity.ensure(root: root)
  end

  test "ensure recovers a crash-marked partial first-pair transaction", %{root: root} do
    {:ok, paths} = Identity.paths(root: root)
    File.mkdir_p!(paths.dir)
    File.chmod!(paths.dir, 0o700)
    File.write!(paths.transaction, "v1\n")
    File.chmod!(paths.transaction, 0o600)
    File.write!(paths.gateway_key, :crypto.strong_rand_bytes(32))
    File.chmod!(paths.gateway_key, 0o600)

    assert {:ok, identity} = Identity.ensure(root: root)
    refute File.exists?(paths.transaction)
    assert byte_size(identity.gateway_public_key) == 32
    assert File.exists?(paths.tls_key)
    assert File.exists?(paths.tls_cert)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
  defp unique_id, do: System.unique_integer([:positive, :monotonic])
end
