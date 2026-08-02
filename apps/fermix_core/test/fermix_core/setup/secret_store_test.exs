defmodule FermixCore.Setup.SecretStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    @impl true
    def delete(_key, _opts \\ []), do: raise("secure-on-save must never delete")

    @impl true
    def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
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

  defp profiled_snapshot(profile, value) do
    %{fermix_core: [profile: profile], fermix_channels: [telegram: [bot_token: value]]}
  end

  # Records which process performed each read, so tests can pin that keyring
  # resolution fans out to tasks instead of blocking the caller sequentially.
  defmodule RecordingWriter do
    @behaviour FermixCore.Setup.SecretWriter

    @table __MODULE__

    def start do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :bag])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def reader_pids do
      @table |> :ets.tab2list() |> Enum.map(fn {_key, pid} -> pid end)
    end

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def get(key, _opts \\ []) do
      :ets.insert(@table, {key, self()})

      case key do
        :exa_api_key -> {:error, {:helper_timeout, "/usr/bin/security", 3_000}}
        other -> {:ok, "resolved-" <> Atom.to_string(other)}
      end
    end

    @impl true
    def put(_key, _value, _opts \\ []), do: raise("resolution must never write")

    @impl true
    def delete(_key, _opts \\ []), do: raise("resolution must never delete")

    @impl true
    def command_source(key, _opts \\ []) do
      %{source: :command, command: "recording", args: [Atom.to_string(key)]}
    end
  end

  # Captures the opts each read receives, so tests can pin that the caller's
  # world (supervised: false for the tree-less boot chain) is threaded through
  # to the writer — which forwards it to CommandRunner.
  defmodule OptsRecordingWriter do
    @behaviour FermixCore.Setup.SecretWriter

    @table __MODULE__

    def start do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :bag])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def recorded_opts, do: @table |> :ets.tab2list() |> Enum.map(fn {_key, opts} -> opts end)

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def get(key, opts \\ []) do
      :ets.insert(@table, {key, opts})
      {:ok, "resolved-" <> Atom.to_string(key)}
    end

    @impl true
    def put(_key, _value, _opts \\ []), do: raise("resolution must never write")

    @impl true
    def delete(_key, _opts \\ []), do: raise("resolution must never delete")

    @impl true
    def command_source(key, _opts \\ []) do
      %{source: :command, command: "recording", args: [Atom.to_string(key)]}
    end
  end

  describe "resolve_sentinels/2 supervised threading" do
    setup do
      :ok = OptsRecordingWriter.start()
      Application.put_env(:fermix_core, :secret_writer, OptsRecordingWriter)
      :ok
    end

    @sentinel_snapshot %{fermix_channels: [telegram: [bot_token: "@keyring"]]}

    test "the tree-less boot chain threads supervised: false to the read" do
      SecretStore.resolve_sentinels(@sentinel_snapshot, warn_plaintext: false, supervised: false)

      assert [opts] = OptsRecordingWriter.recorded_opts()
      assert Keyword.get(opts, :supervised) == false
      assert Keyword.get(opts, :profile) == "general"
    end

    test "a daemon caller omits supervised so CommandRunner defaults to the host" do
      SecretStore.resolve_sentinels(@sentinel_snapshot, warn_plaintext: false)

      assert [opts] = OptsRecordingWriter.recorded_opts()
      refute Keyword.has_key?(opts, :supervised)
    end
  end

  describe "resolve_sentinels/2 keyring fan-out" do
    setup do
      :ok = RecordingWriter.start()
      Application.put_env(:fermix_core, :secret_writer, RecordingWriter)
      :ok
    end

    @multi_snapshot %{
      fermix_core: [
        providers: [openai: [api_key: "@keyring"]],
        tools: [web_search: [exa_api_key: "@keyring"]]
      ],
      fermix_channels: [telegram: [bot_token: "@keyring"]]
    }

    test "keyring reads run in tasks, not the calling process" do
      SecretStore.resolve_sentinels(@multi_snapshot, warn_plaintext: false)

      pids = RecordingWriter.reader_pids()
      assert length(pids) == 3
      refute self() in pids, "keyring reads still run sequentially in the caller"
    end

    test "resolved values land on their paths; a failed read leaves its sentinel" do
      resolved = SecretStore.resolve_sentinels(@multi_snapshot, warn_plaintext: false)

      assert SecretStore.get_snapshot_value(resolved, [
               :fermix_core,
               :providers,
               :openai,
               :api_key
             ]) == "resolved-openai_api_key"

      assert SecretStore.get_snapshot_value(resolved, [:fermix_channels, :telegram, :bot_token]) ==
               "resolved-telegram_bot_token"

      # exa fails: optional secret keeps its sentinel, isolated from the others.
      assert SecretStore.get_snapshot_value(resolved, [
               :fermix_core,
               :tools,
               :web_search,
               :exa_api_key
             ]) == SecretWriter.sentinel()
    end
  end

  describe "mask_resolved_secrets/2" do
    test "masks a resolved value back to the sentinel when persisted holds it" do
      masked =
        SecretStore.mask_resolved_secrets(
          snapshot_with("resolved-token"),
          snapshot_with(SecretWriter.sentinel())
        )

      assert SecretStore.get_snapshot_value(masked, @path) == SecretWriter.sentinel()
    end

    test "leaves the value alone when persisted holds plaintext" do
      masked =
        SecretStore.mask_resolved_secrets(
          snapshot_with("env-token"),
          snapshot_with("disk-token")
        )

      assert SecretStore.get_snapshot_value(masked, @path) == "env-token"
    end

    test "leaves an absent value absent so the diff still signals a restart" do
      masked =
        SecretStore.mask_resolved_secrets(
          snapshot_with(nil),
          snapshot_with(SecretWriter.sentinel())
        )

      assert SecretStore.get_snapshot_value(masked, @path) == nil
    end
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

  describe "resolve_sentinels/2 when a required secret cannot be resolved at boot" do
    setup do
      Application.put_env(:fermix_core, :secret_writer, ReadFailsWriter)
      :ok
    end

    test "leaves the sentinel instead of raising, so the daemon still boots" do
      # 0.5.0 regression: a locked/slow login keychain makes `security` time out;
      # resolving a REQUIRED @keyring secret then raised inside BootReport.init and
      # crashed the whole daemon at boot — leaving the setup UI (the recovery
      # surface) unreachable. It must leave the sentinel in place (like optional
      # secrets), so the daemon boots and the secret resolves on the next boot once
      # the keychain is reachable — and a save meanwhile round-trips the sentinel
      # rather than orphaning the stored key.
      assert resolve(snapshot_with(SecretWriter.sentinel())) == SecretWriter.sentinel()
    end

    test "logs an actionable error naming the secret and how to recover" do
      log =
        capture_log(fn ->
          SecretStore.resolve_sentinels(snapshot_with(SecretWriter.sentinel()),
            warn_plaintext: true
          )
        end)

      assert log =~ "TELEGRAM_BOT_TOKEN"
      assert log =~ "Unlock"
    end
  end

  describe "secrets are namespaced per profile" do
    test "a named profile stores and resolves under its own keychain coordinate" do
      # The same secret key, written under two profiles, must not collide — and
      # each profile must resolve ITS OWN value. Guards the profile being threaded
      # through secure_snapshot/resolve_sentinels: drop `profile:` on any path and
      # the two profiles collapse to one entry, failing these assertions.
      assert {:ok, _} = SecretStore.secure_snapshot(profiled_snapshot("work", "work-token"))
      assert {:ok, _} = SecretStore.secure_snapshot(profiled_snapshot("general", "general-token"))

      assert resolve(profiled_snapshot("work", SecretWriter.sentinel())) == "work-token"
      assert resolve(profiled_snapshot("general", SecretWriter.sentinel())) == "general-token"
    end
  end

  defp resolve(snapshot) do
    snapshot
    |> SecretStore.resolve_sentinels(warn_plaintext: false)
    |> SecretStore.get_snapshot_value(@path)
  end

  test "plaintext warning includes the active config path" do
    previous_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("secret-store-warning")

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    System.put_env("FERMIX_HOME", home)

    log =
      capture_log(fn ->
        SecretStore.resolve_sentinels(snapshot_with("plain-token"), warn_plaintext: true)
      end)

    assert log =~ Path.join(home, "config.toml")
    assert log =~ "TELEGRAM_BOT_TOKEN"
  end
end
