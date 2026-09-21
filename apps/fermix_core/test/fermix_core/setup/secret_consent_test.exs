defmodule FermixCore.Setup.SecretWriter.ConsentTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.SecretWriter.FileStore
  alias FermixTestSupport.SecretWriterStub

  @key :openai_api_key

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

  setup do
    home = Path.join(System.tmp_dir!(), "fermix-consent-#{System.unique_integer([:positive])}")
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

    {:ok, opts: [home: home]}
  end

  describe "put/3 routing" do
    test "without consent the keyring takes it, and nothing is written to a file", %{opts: opts} do
      assert :ok = SecretWriter.put(@key, "sk-value", opts)

      assert {:ok, "sk-value"} = SecretWriterStub.get(@key)
      assert FileStore.stored_keys(opts) == []
    end

    test "the file store is reached only by consent carried in the call", %{opts: opts} do
      assert :ok = SecretWriter.put(@key, "sk-value", [store: :file] ++ opts)

      assert {:ok, "sk-value"} = FileStore.get(@key, opts)
      # The keyring was not asked, and no value reached it.
      assert {:error, :missing_secret} = SecretWriterStub.get(@key)
    end

    test "a refused keyring is never answered by storing the value elsewhere", %{opts: opts} do
      assert {:error, :keyring_locked} =
               SecretWriter.put(@key, "sk-value", [impl: LockedKeyring] ++ opts)

      # The owner has not been asked, so nothing was stored on their behalf.
      assert FileStore.stored_keys(opts) == []
    end
  end

  describe "the way back" do
    test "a keyring write deletes the file copy it supersedes", %{opts: opts} do
      assert :ok = SecretWriter.put(@key, "sk-value", [store: :file] ++ opts)
      assert FileStore.stored_keys(opts) == ["OPENAI_API_KEY"]

      assert :ok = SecretWriter.put(@key, "sk-value", opts)

      assert {:ok, "sk-value"} = SecretWriterStub.get(@key)
      assert FileStore.stored_keys(opts) == []
    end

    test "a file copy that cannot be removed is reported, not passed over", %{opts: opts} do
      assert :ok = SecretWriter.put(@key, "sk-value", [store: :file] ++ opts)
      directory = FileStore.directory(opts)
      File.chmod!(directory, 0o500)
      on_exit(fn -> File.chmod(directory, 0o700) end)

      assert {:error, {:file_copy_remains, _reason}} = SecretWriter.put(@key, "sk-value", opts)
    end
  end
end
