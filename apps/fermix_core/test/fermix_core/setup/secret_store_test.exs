defmodule FermixCore.Setup.SecretStoreTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter

  @path [:fermix_channels, :telegram, :bot_token]

  # available? but get/2 fails transiently (locked keychain). put/3 RAISES so any
  # escalation-to-write regression fails the test loudly.
  defmodule ReadFailsWriter do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def get(_key, _opts \\ []), do: {:error, {:helper_timeout, "/usr/bin/security", 3_000}}

    @impl true
    def put(_key, _value, _opts \\ []) do
      raise "secure-on-save must not write when the keychain read failed"
    end
  end

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

    test "keeps the sentinel without writing when the stored secret is unreadable" do
      # No keyring entry: get/2 returns {:error, :missing_secret}. The save must keep
      # the @keyring sentinel and NOT escalate to a write. Production cannot reach
      # this with a resolved value (load resolves @keyring first and would have
      # raised), but a transient lock between load and save can.
      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("resolved-token"),
                 previous: snapshot_with(SecretWriter.sentinel())
               )

      assert SecretStore.get_snapshot_value(secured, @path) == SecretWriter.sentinel()
      assert {:error, :missing_secret} = SecretWriter.get(:telegram_bot_token)
    end
  end

  describe "secure_snapshot/2 when the keychain read fails transiently" do
    setup do
      Application.put_env(:fermix_core, :secret_writer, ReadFailsWriter)
      :ok
    end

    test "keeps the sentinel and never escalates to a write that could fail the save" do
      # Regression guard for the keep_or_rotate hardening: a transient keychain read
      # failure on an already-secured (@keyring) secret must preserve the sentinel
      # and leave the save succeeding — not fall through to a write (ReadFailsWriter
      # raises on put) that would fail an otherwise-unrelated config save.
      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("resolved-token"),
                 previous: snapshot_with(SecretWriter.sentinel())
               )

      assert SecretStore.get_snapshot_value(secured, @path) == SecretWriter.sentinel()
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

    test "an already-secured (@keyring) secret keeps the sentinel without a failing put" do
      # `old_value == sentinel` is checked before the writer-availability guard, so a
      # writer-less host still enters keep_or_rotate. The read returns {:error,
      # :unavailable}; the hardening keeps the sentinel instead of attempting a put
      # that would fail the whole save.
      assert {:ok, secured} =
               SecretStore.secure_snapshot(snapshot_with("resolved-token"),
                 previous: snapshot_with(SecretWriter.sentinel())
               )

      assert SecretStore.get_snapshot_value(secured, @path) == SecretWriter.sentinel()
    end
  end
end
