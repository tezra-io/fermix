defmodule FermixCore.Setup.SecretStoreChoiceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.ConfigStore

  setup do
    home =
      Path.join(System.tmp_dir!(), "fermix-store-choice-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(home) end)
    {:ok, home: home}
  end

  test "a home that has never chosen saves to the keyring", %{home: home} do
    assert {:ok, :keyring} = ConfigStore.secret_store(home)
  end

  test "the choice persists, so a later save is not asked again", %{home: home} do
    assert :ok = ConfigStore.put_secret_store(home, :file)

    assert {:ok, :file} = ConfigStore.secret_store(home)
  end

  test "returning to the keyring leaves no setting behind", %{home: home} do
    assert :ok = ConfigStore.put_secret_store(home, :file)
    assert :ok = ConfigStore.put_secret_store(home, :keyring)

    assert {:ok, :keyring} = ConfigStore.secret_store(home)
    refute File.read!(Path.join(home, "config.toml")) =~ "secret_store"
  end

  test "an unrelated setting survives the write", %{home: home} do
    assert :ok = ConfigStore.put_web_port(home, 4123)
    assert :ok = ConfigStore.put_secret_store(home, :file)

    assert {:ok, 4123} = ConfigStore.web_port(home)
    assert {:ok, :file} = ConfigStore.secret_store(home)
  end

  test "the recorded choice rides on every save, not only the one that consented" do
    home =
      Path.join(System.tmp_dir!(), "fermix-choice-ride-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(home) end)
    :ok = ConfigStore.put_secret_store(home, :file)

    # The wizard, a settings save and a boot-time rotation all go through
    # `secure_snapshot/2`; a home that consented through the app must keep
    # saving to the store it chose, or the next save silently returns it to a
    # keyring it cannot reach.
    assert {:ok, :file} = ConfigStore.secret_store(home)
  end

  test "a store this engine does not know is an error, not a quiet default", %{home: home} do
    File.write!(Path.join(home, "config.toml"), "[fermix_core]\nsecret_store = \"kwallet\"\n")

    assert {:error, {:unknown_secret_store, "kwallet"}} = ConfigStore.secret_store(home)
  end
end
