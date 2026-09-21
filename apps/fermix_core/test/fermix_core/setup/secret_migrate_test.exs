defmodule FermixCore.Setup.SecretMigrateTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.SecretWriter.FileStore
  alias FermixCore.Setup.SecretWriter.Migration
  alias FermixTestSupport.SecretWriterStub

  @key :openai_api_key
  @other :telegram_bot_token

  defmodule LockedKeyring do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def put(_key, _value, _opts \\ []), do: {:error, :keyring_locked}

    @impl true
    def get(_key, _opts \\ []), do: {:error, :missing_secret}

    @impl true
    def delete(_key, _opts \\ []), do: :ok

    @impl true
    def command_source(_key, _opts \\ []), do: %{source: :command, command: "locked", args: []}
  end

  defmodule ForgetfulKeyring do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: true

    # Takes the write and then cannot produce the value: the read-back exists
    # for exactly this, because a delete after it would lose the secret.
    @impl true
    def put(_key, _value, _opts \\ []), do: :ok

    @impl true
    def get(_key, _opts \\ []), do: {:error, :missing_secret}

    @impl true
    def delete(_key, _opts \\ []), do: :ok

    @impl true
    def command_source(_key, _opts \\ []), do: %{source: :command, command: "forgetful", args: []}
  end

  setup do
    home = Path.join(System.tmp_dir!(), "fermix-migrate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    SecretWriterStub.reset()
    previous = Application.get_env(:fermix_core, :secret_writer)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf(home)

      case previous do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        value -> Application.put_env(:fermix_core, :secret_writer, value)
      end
    end)

    opts = [home: home]
    :ok = ConfigStore.put_secret_store(home, :file)
    {:ok, home: home, opts: opts}
  end

  test "every file-stored secret moves, and the choice goes back to the keyring", %{
    home: home,
    opts: opts
  } do
    :ok = SecretWriter.put(@key, "first", [store: :file] ++ opts)
    :ok = SecretWriter.put(@other, "second", [store: :file] ++ opts)

    assert {:ok, %{moved: moved, store: :keyring}} = Migration.to_keyring(opts)

    assert Enum.sort(moved) == [:openai_api_key, :telegram_bot_token]
    assert {:ok, "first"} = SecretWriterStub.get(@key)
    assert FileStore.stored_keys(opts) == []
    assert {:ok, :keyring} = ConfigStore.secret_store(home)
  end

  test "a home with nothing in the file store is already home", %{opts: opts} do
    assert {:ok, %{moved: [], store: :keyring}} = Migration.to_keyring(opts)
  end

  test "a locked keyring moves nothing, deletes nothing and changes no setting", %{
    home: home,
    opts: opts
  } do
    :ok = SecretWriter.put(@key, "first", [store: :file] ++ opts)

    assert {:error, :keyring_locked} = Migration.to_keyring([impl: LockedKeyring] ++ opts)

    assert FileStore.stored_keys(opts) == ["OPENAI_API_KEY"]
    assert {:ok, "first"} = FileStore.get(@key, opts)
    assert {:ok, :file} = ConfigStore.secret_store(home)
  end

  test "a value the keyring cannot read back keeps its file copy", %{home: home, opts: opts} do
    :ok = SecretWriter.put(@key, "first", [store: :file] ++ opts)

    assert {:error, {:verify_failed, "OPENAI_API_KEY"}} =
             Migration.to_keyring([impl: ForgetfulKeyring] ++ opts)

    # The file copy is the only copy that answers, so it stays and the home
    # keeps saving to the store that works.
    assert {:ok, "first"} = FileStore.get(@key, opts)
    assert {:ok, :file} = ConfigStore.secret_store(home)
  end

  test "the unlock request reaches the keyring write", %{opts: opts} do
    :ok = SecretWriter.put(@key, "first", [store: :file] ++ opts)
    owner = self()

    recorder = fn key, value, write_opts ->
      send(owner, {:wrote, Keyword.get(write_opts, :unlock)})
      SecretWriterStub.put(key, value, write_opts)
    end

    assert {:ok, _report} = Migration.to_keyring([unlock: true, put: recorder] ++ opts)

    assert_received {:wrote, true}
  end
end
