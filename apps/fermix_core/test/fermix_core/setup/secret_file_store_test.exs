defmodule FermixCore.Setup.SecretWriter.FileStoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretWriter.FileStore

  @key :openai_api_key

  setup do
    home = Path.join(System.tmp_dir!(), "fermix-file-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(home) end)
    {:ok, home: home, opts: [home: home]}
  end

  describe "put/3 and get/2" do
    test "a stored value reads back, in a 0700 directory holding a 0600 file", %{
      home: home,
      opts: opts
    } do
      assert :ok = FileStore.put(@key, "sk-value", opts)
      assert {:ok, "sk-value"} = FileStore.get(@key, opts)

      directory = Path.join(home, "secrets")
      assert mode(directory) == 0o700
      assert [file] = File.ls!(directory)
      assert mode(Path.join(directory, file)) == 0o600
    end

    test "one file per secret, so a second key leaves the first alone", %{home: home, opts: opts} do
      assert :ok = FileStore.put(@key, "first", opts)
      assert :ok = FileStore.put(:telegram_bot_token, "second", opts)

      assert {:ok, "first"} = FileStore.get(@key, opts)
      assert length(File.ls!(Path.join(home, "secrets"))) == 2
    end

    test "a write replaces a value without leaving the temporary behind", %{
      home: home,
      opts: opts
    } do
      assert :ok = FileStore.put(@key, "first", opts)
      assert :ok = FileStore.put(@key, "second", opts)

      assert {:ok, "second"} = FileStore.get(@key, opts)
      assert length(File.ls!(Path.join(home, "secrets"))) == 1
    end

    test "a key that was never stored is missing, not empty", %{opts: opts} do
      assert {:error, :missing_secret} = FileStore.get(@key, opts)
    end
  end

  describe "refusals" do
    test "a directory wider than 0700 refuses both directions, naming the path", %{
      home: home,
      opts: opts
    } do
      assert :ok = FileStore.put(@key, "sk-value", opts)
      directory = Path.join(home, "secrets")
      File.chmod!(directory, 0o755)

      assert {:error, {:insecure_permissions, ^directory, 0o755}} = FileStore.get(@key, opts)
      assert {:error, {:insecure_permissions, ^directory, 0o755}} = FileStore.put(@key, "x", opts)
    end

    test "a file wider than 0600 refuses that secret only", %{home: home, opts: opts} do
      assert :ok = FileStore.put(@key, "sk-value", opts)
      assert :ok = FileStore.put(:telegram_bot_token, "other", opts)

      [wide | _rest] =
        home
        |> Path.join("secrets")
        |> File.ls!()
        |> Enum.map(&Path.join([home, "secrets", &1]))
        |> Enum.filter(&(File.read!(&1) == "sk-value"))

      File.chmod!(wide, 0o644)

      assert {:error, {:insecure_permissions, ^wide, 0o644}} = FileStore.get(@key, opts)
      # The other secret is untouched: one bad file refuses one secret.
      assert {:ok, "other"} = FileStore.get(:telegram_bot_token, opts)
    end
  end

  describe "delete/2 and stored_keys/1" do
    test "a delete removes the file and the key stops being stored", %{opts: opts} do
      assert :ok = FileStore.put(@key, "sk-value", opts)
      assert :ok = FileStore.delete(@key, opts)

      assert {:error, :missing_secret} = FileStore.get(@key, opts)
      assert FileStore.stored_keys(opts) == []
    end

    test "deleting what was never stored succeeds, because the postcondition holds", %{opts: opts} do
      assert :ok = FileStore.delete(@key, opts)
    end

    test "stored_keys names every stored secret, for the migration back", %{opts: opts} do
      assert :ok = FileStore.put(@key, "first", opts)
      assert :ok = FileStore.put(:telegram_bot_token, "second", opts)

      assert Enum.sort(FileStore.stored_keys(opts)) == ["OPENAI_API_KEY", "TELEGRAM_BOT_TOKEN"]
    end

    test "an external name round-trips without becoming an atom", %{opts: opts} do
      key = {:external_env, "MY_SKILL_TOKEN"}

      assert :ok = FileStore.put(key, "value", opts)
      assert {:ok, "value"} = FileStore.get(key, opts)
      assert FileStore.stored_keys(opts) == ["external_env:MY_SKILL_TOKEN"]
    end
  end

  describe "available?/1" do
    test "the file store is available wherever its home can be written", %{opts: opts} do
      assert FileStore.available?(opts)
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
