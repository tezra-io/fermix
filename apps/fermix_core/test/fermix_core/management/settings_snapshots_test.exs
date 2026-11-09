defmodule FermixCore.Management.SettingsSnapshotsTest do
  @moduledoc """
  The `snapshots` settings section (M75 §8, ALWAYS_ON_PANE §3.12): its two
  rows, a write through the settings door, what is refused, and the access
  keys of another S3 service through `secret.set`.
  Every case runs in its own home with the application environment it touches
  restored on exit, as `settings_test.exs` does.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Settings, as: SnapshotSettings
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @core_keys [
    :providers,
    :routing,
    :personalization,
    :agent,
    :compaction,
    :memory,
    :skill_curation,
    :realtime,
    :transcription,
    :meetings,
    :computer_use,
    :computer_history,
    :harness,
    :tools,
    :sandbox,
    :browser,
    :secret_writer,
    :secret_store,
    :snapshots
  ]
  @channel_keys [:telegram, :whatsapp, :discord, :slack, :signal, :acp, :mobile, :imessage]

  setup do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@core_keys, fn key -> {key, Application.fetch_env(:fermix_core, key)} end)

    channels =
      Map.new(@channel_keys, fn key -> {key, Application.fetch_env(:fermix_channels, key)} end)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    tmp = SafeRm.make_tmp_dir!("management_settings_snapshots")
    System.put_env("FERMIX_HOME", tmp)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      Enum.each(channels, fn {key, value} -> restore(:fermix_channels, key, value) end)
      SecretWriterStub.delete(:snapshot_s3_access_key_id)
      if home, do: System.put_env("FERMIX_HOME", home), else: System.delete_env("FERMIX_HOME")
      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  # ALWAYS_ON_PANE §3.12 (D7, D18): no app sets any part of S3. The section
  # keeps how often and whether the recovery passphrase is set; the raw
  # recovery key is never shown.
  test "the section offers how often and the passphrase's state, and nothing of S3", _context do
    assert %{id: "snapshots", pane: "always_on", title: "Recovery snapshots"} in Settings.sections()

    assert {:ok, %{"rows" => rows}} = Settings.get("snapshots")
    assert Enum.map(rows, & &1["key"]) == ~w(snapshots_passphrase snapshots_interval_hours)

    assert %{
             "kind" => "text",
             "label" => "Recovery passphrase",
             "value" => "Not set",
             "read_only" => true,
             "footer" => "Every backup is encrypted to it, and Fermix never stores it."
           } = row(rows, "snapshots_passphrase")

    assert %{"value" => 6, "min" => 1, "max" => 168, "restart" => false} =
             row(rows, "snapshots_interval_hours")
  end

  test "the passphrase reads Set once a recovery key is kept, and the key is never shown" do
    assert {:ok, _saved} = SnapshotSettings.put_recipient(Recipient.generate())

    {:ok, %{"rows" => rows}} = Settings.get("snapshots")
    assert %{"value" => "Set"} = row(rows, "snapshots_passphrase")
    refute Enum.any?(rows, &(is_binary(&1["value"]) and &1["value"] =~ "fxsnap1."))
  end

  test "a write of how often lands in config.toml and reads back in the rows", %{home: home} do
    assert {:ok, result} = Settings.apply("snapshots", %{"snapshots_interval_hours" => 12})
    assert result["applied"] == ["snapshots_interval_hours"]

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.snapshots]"
    assert contents =~ "interval_hours = 12"
    assert Keyword.get(Application.get_env(:fermix_core, :snapshots), :interval_hours) == 12

    {:ok, %{"rows" => rows}} = Settings.get("snapshots")
    assert %{"value" => 12} = row(rows, "snapshots_interval_hours")
  end

  test "S3 is no setting of the section, and the passphrase changes elsewhere" do
    for key <- ~w(snapshots_s3_bucket snapshots_s3_region snapshots_s3_prefix
                  snapshots_s3_endpoint snapshots_recipient) do
      assert {:error, {:invalid_params, ^key, "This section has no setting by that name."}} =
               Settings.apply("snapshots", %{key => "invented"})
    end

    assert {:error,
            {:invalid_params, "snapshots_passphrase",
             "This setting is shown here and changed elsewhere."}} =
             Settings.apply("snapshots", %{"snapshots_passphrase" => "Set"})

    assert_raise ArgumentError, ~r/unknown snapshot setting/, fn ->
      SnapshotSettings.save(s3_bucket: "invented-fermix-snapshots")
    end

    assert ConfigStore.current_snapshot().fermix_core
           |> Keyword.get(:snapshots, [])
           |> Keyword.get(:s3_bucket) == nil
  end

  # Another S3 service is set on the server itself: its keys still go through
  # secret.set (`fermix settings secret set`), though no row shows them.
  test "the access keys of another S3 service are still stored with secret.set", %{home: home} do
    assert {:ok, %{"present" => true}} = Secrets.set("snapshot_s3_access_key_id", "AKIAINVENTED")

    assert File.read!(Path.join(home, "config.toml")) =~ ~s(s3_access_key_id = "@keyring")
    assert SecretWriterStub.get(:snapshot_s3_access_key_id) == {:ok, "AKIAINVENTED"}
  end

  defp row(rows, key), do: Enum.find(rows, &(&1["key"] == key))

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
