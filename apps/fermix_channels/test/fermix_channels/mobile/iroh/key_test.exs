defmodule FermixChannels.Mobile.Iroh.KeyTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.Key

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "mobile"))
    File.chmod!(Path.join(root, "mobile"), 0o700)
    %{root: root, key: Key.path(root)}
  end

  test "creates the key once, 0600, and loads the same key afterwards", ctx do
    assert {:ok, %{path: path, endpoint_id: id}} = Key.ensure(ctx.root)
    assert path == ctx.key
    assert %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert byte_size(File.read!(path)) == 32
    assert id =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, %{endpoint_id: ^id}} = Key.ensure(ctx.root)
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "the endpoint id is the Ed25519 public key of the secret, as iroh shows it" do
    secret = :binary.list_to_bin(Enum.to_list(1..32))

    assert Key.endpoint_id(secret) ==
             "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  end

  test "a key of the wrong size or mode is refused, never replaced", ctx do
    File.write!(ctx.key, "short")
    File.chmod!(ctx.key, 0o600)
    assert {:error, {:iroh_key_invalid, _path, {:size, 5}}} = Key.ensure(ctx.root)
    assert File.read!(ctx.key) == "short"

    File.write!(ctx.key, :binary.copy(<<7>>, 32))
    File.chmod!(ctx.key, 0o644)
    assert {:error, {:iroh_key_invalid, _path, {:mode, 0o644}}} = Key.ensure(ctx.root)
    assert File.read!(ctx.key) == :binary.copy(<<7>>, 32)
  end

  test "a directory where the key belongs is refused", ctx do
    File.mkdir!(ctx.key)
    assert {:error, {:iroh_key_unsafe_type, _path, :directory}} = Key.ensure(ctx.root)
  end

  test "a home whose mobile directory is not 0700 is refused", ctx do
    File.chmod!(Path.join(ctx.root, "mobile"), 0o755)
    assert {:error, {:iroh_key_dir_unusable, _dir, {:mode, 0o755}}} = Key.ensure(ctx.root)
    refute File.exists?(ctx.key)
  end

  test "a temporary file left by a crash is removed when the key is created", ctx do
    stale = ctx.key <> ".tmp.99"
    File.write!(stale, "partial")
    assert {:ok, _key} = Key.ensure(ctx.root)
    refute File.exists?(stale)
  end
end
