defmodule FermixCore.Setup.SecretStoreTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter

  @path [:fermix_channels, :telegram, :bot_token]

  setup do
    previous_writer = Application.get_env(:fermix_core, :secret_writer)
    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    on_exit(fn ->
      case previous_writer do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        value -> Application.put_env(:fermix_core, :secret_writer, value)
      end

      FermixTestSupport.SecretWriterStub.reset()
    end)

    :ok
  end

  defp snapshot_with(value) do
    %{fermix_channels: [telegram: [bot_token: value]]}
  end

  describe "secure_snapshot/2 when the persisted value is the @keyring sentinel" do
    test "keeps the sentinel when the snapshot value matches the stored secret" do
      :ok = SecretWriter.put(:telegram_bot_token, "stored-token")

      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("stored-token"),
                 previous: snapshot_with(SecretWriter.sentinel())
               )

      assert SecretStore.get_snapshot_value(secured, @path) == SecretWriter.sentinel()
      assert {:ok, "stored-token"} = SecretWriter.get(:telegram_bot_token)
    end

    test "rewrites the keyring when the snapshot value differs (rotation)" do
      :ok = SecretWriter.put(:telegram_bot_token, "stale-token")

      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("rotated-token"),
                 previous: snapshot_with(SecretWriter.sentinel())
               )

      assert SecretStore.get_snapshot_value(secured, @path) == SecretWriter.sentinel()
      assert {:ok, "rotated-token"} = SecretWriter.get(:telegram_bot_token)
    end

    test "stores the snapshot value when the keyring entry is missing" do
      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("recovered-token"),
                 previous: snapshot_with(SecretWriter.sentinel())
               )

      assert SecretStore.get_snapshot_value(secured, @path) == SecretWriter.sentinel()
      assert {:ok, "recovered-token"} = SecretWriter.get(:telegram_bot_token)
    end
  end

  describe "secure_snapshot/2 without an OS secret writer" do
    setup do
      Application.put_env(
        :fermix_core,
        :secret_writer,
        FermixTestSupport.UnavailableSecretWriter
      )

      :ok
    end

    test "keeps already-persisted plaintext unchanged instead of failing the save" do
      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("plain-token"),
                 previous: snapshot_with("plain-token")
               )

      assert SecretStore.get_snapshot_value(secured, @path) == "plain-token"
    end

    test "fails loud when a new or changed plaintext secret cannot be stored" do
      assert {:error, message} =
               SecretStore.secure_snapshot(snapshot_with("new-token"),
                 previous: snapshot_with("old-token")
               )

      assert message =~ "TELEGRAM_BOT_TOKEN"
      assert message =~ "OS keyring"
    end
  end
end
