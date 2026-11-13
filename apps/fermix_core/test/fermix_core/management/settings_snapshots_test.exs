defmodule FermixCore.Management.SettingsSnapshotsTest do
  @moduledoc """
  The `snapshots` settings section (M75 §8, ALWAYS_ON_PANE §3.12, S1, S7,
  D18): Backup settings, its one row, listed and written only on an Always On
  server's primary, a write through the settings door, what is refused, and
  the access keys of another S3 service through `secret.set`.
  Every case runs in its own home with the application environment it touches
  restored on exit, as `settings_test.exs` does.
  """

  use ExUnit.Case, async: false

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
  # An Always On server's primary, as `Home.ServerPrimary` tells it.
  @server [server_primary?: true]

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

  # ALWAYS_ON_PANE §3.12 (S1, S7): on an Always On server, Backup settings
  # is how often and nothing else. Whether the recovery passphrase is set is
  # the summary's (`detail.backup`), and no app sets any part of S3.
  test "on an Always On server: Backup settings, one row, how often", _context do
    assert %{id: "snapshots", pane: "always_on", title: "Backup settings"} in Settings.sections(
             @server
           )

    assert {:ok, %{"title" => "Backup settings", "rows" => [row]}} =
             Settings.get("snapshots", @server)

    assert %{
             "key" => "snapshots_interval_hours",
             "kind" => "number",
             "label" => "Back up every",
             "value" => 6,
             "min" => 1,
             "max" => 168,
             "format" => "hours",
             "restart" => false
           } = row
  end

  # D18: a Mac that never moved, or any computer whose home never moved,
  # keeps no S3 backup, so it lists no backup settings and takes no write.
  test "a Mac primary and a home that never moved list no backup settings and write none", %{
    home: home
  } do
    for opts <- [[macos?: true], [macos?: false], [server_primary?: false]] do
      refute Enum.any?(Settings.sections(opts), &(&1.id == "snapshots")), inspect(opts)
      assert Settings.get("snapshots", opts) == {:error, {:unknown_section, "snapshots"}}

      assert Settings.apply("snapshots", %{"snapshots_interval_hours" => 12}, opts) ==
               {:error, {:unknown_section, "snapshots"}}
    end

    refute File.exists?(Path.join(home, "config.toml"))
  end

  test "a write of how often lands in config.toml and reads back in the rows", %{home: home} do
    assert {:ok, result} =
             Settings.apply("snapshots", %{"snapshots_interval_hours" => 12}, @server)

    assert result["applied"] == ["snapshots_interval_hours"]

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.snapshots]"
    assert contents =~ "interval_hours = 12"
    assert Keyword.get(Application.get_env(:fermix_core, :snapshots), :interval_hours) == 12

    {:ok, %{"rows" => rows}} = Settings.get("snapshots", @server)
    assert %{"value" => 12} = row(rows, "snapshots_interval_hours")
  end

  test "S3 and the recovery passphrase are no setting of the section" do
    for key <- ~w(snapshots_s3_bucket snapshots_s3_region snapshots_s3_prefix
                  snapshots_s3_endpoint snapshots_recipient snapshots_passphrase) do
      assert {:error, {:invalid_params, ^key, "This section has no setting by that name."}} =
               Settings.apply("snapshots", %{key => "invented"}, @server)
    end

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
