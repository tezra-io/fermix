defmodule FermixCore.Setup.SecretKeyBaseTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretKeyBase

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("secret-key-base")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "generates, persists, and returns a key long enough to sign sessions", %{dir: dir} do
    key = SecretKeyBase.read_or_create!(dir)

    assert byte_size(key) >= 64
    assert String.trim(File.read!(Path.join(dir, "secret_key_base"))) == key
  end

  test "writes the key file with 0600 permissions", %{dir: dir} do
    SecretKeyBase.read_or_create!(dir)

    %File.Stat{mode: mode} = File.stat!(Path.join(dir, "secret_key_base"))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "returns the same key across calls so sessions survive a restart", %{dir: dir} do
    assert SecretKeyBase.read_or_create!(dir) == SecretKeyBase.read_or_create!(dir)
  end

  test "creates the home directory when it does not exist", %{dir: dir} do
    nested = Path.join(dir, "deep/home")

    key = SecretKeyBase.read_or_create!(nested)

    assert byte_size(key) >= 64
    assert File.exists?(Path.join(nested, "secret_key_base"))
  end

  test "raises rather than signing with a corrupt (too-short) key file", %{dir: dir} do
    File.write!(Path.join(dir, "secret_key_base"), "short")

    assert_raise RuntimeError, ~r/too short/, fn -> SecretKeyBase.read_or_create!(dir) end
  end
end
