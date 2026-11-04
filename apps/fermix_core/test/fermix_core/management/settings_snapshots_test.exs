defmodule FermixCore.Management.SettingsSnapshotsTest do
  @moduledoc """
  The `snapshots` settings section (M75 §8): its rows, a write through the
  settings door, the two secrets through `secret.set`, and what is refused.
  Every case runs in its own home with the application environment it touches
  restored on exit, as `settings_test.exs` does.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Home.Snapshot.Recipient
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

  test "the section is published under the Always On pane", _context do
    assert %{id: "snapshots", pane: "always_on", title: "Recovery snapshots"} in Settings.sections()

    assert {:ok, %{"rows" => rows}} = Settings.get("snapshots")

    assert Enum.map(rows, & &1["key"]) == ~w(
             snapshots_recipient snapshots_interval_hours snapshots_s3_bucket
             snapshots_s3_region snapshot_s3_access_key_id snapshot_s3_secret_access_key
             snapshots_s3_prefix snapshots_s3_endpoint
           )

    assert %{"read_only" => true, "value" => ""} = row(rows, "snapshots_recipient")

    assert %{"value" => 6, "min" => 1, "max" => 168, "restart" => false} =
             row(rows, "snapshots_interval_hours")

    assert %{"kind" => "secret", "present" => false} = row(rows, "snapshot_s3_access_key_id")
  end

  test "a write lands in config.toml and reads back in the rows", %{home: home} do
    assert {:ok, result} =
             Settings.apply("snapshots", %{
               "snapshots_s3_bucket" => "invented-fermix-snapshots",
               "snapshots_s3_region" => "eu-west-1",
               "snapshots_interval_hours" => 12
             })

    assert Enum.sort(result["applied"]) ==
             ~w(snapshots_interval_hours snapshots_s3_bucket snapshots_s3_region)

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.snapshots]"
    assert contents =~ ~s(s3_bucket = "invented-fermix-snapshots")
    assert contents =~ "interval_hours = 12"
    assert Keyword.get(Application.get_env(:fermix_core, :snapshots), :interval_hours) == 12

    {:ok, %{"rows" => rows}} = Settings.get("snapshots")
    assert %{"value" => "invented-fermix-snapshots"} = row(rows, "snapshots_s3_bucket")
    assert %{"value" => 12} = row(rows, "snapshots_interval_hours")

    # Clearing a text row removes the key, so its default applies again.
    assert {:ok, _cleared} = Settings.apply("snapshots", %{"snapshots_s3_region" => ""})
    refute File.read!(Path.join(home, "config.toml")) =~ "s3_region"
  end

  test "the access keys are stored with secret.set and reported present", %{home: home} do
    assert {:ok, %{"present" => true}} = Secrets.set("snapshot_s3_access_key_id", "AKIAINVENTED")

    assert File.read!(Path.join(home, "config.toml")) =~ ~s(s3_access_key_id = "@keyring")
    assert SecretWriterStub.get(:snapshot_s3_access_key_id) == {:ok, "AKIAINVENTED"}

    {:ok, %{"rows" => rows}} = Settings.get("snapshots")
    assert %{"present" => true} = row(rows, "snapshot_s3_access_key_id")
  end

  test "the recovery key, a secret row and a bad value are refused by name" do
    recipient = Recipient.encode(Recipient.generate())

    assert {:error,
            {:invalid_params, "snapshots_recipient",
             "This setting is shown here and changed elsewhere."}} =
             Settings.apply("snapshots", %{"snapshots_recipient" => recipient})

    assert {:error,
            {:invalid_params, "snapshot_s3_access_key_id",
             "This is a secret. Store it with secret.set instead."}} =
             Settings.apply("snapshots", %{"snapshot_s3_access_key_id" => "AKIA"})

    assert {:error, {:invalid_params, "snapshots_s3_bucket", sentence}} =
             Settings.apply("snapshots", %{"snapshots_s3_bucket" => "Not A Bucket"})

    assert sentence =~ "s3_bucket takes a bucket name"

    assert ConfigStore.current_snapshot().fermix_core
           |> Keyword.get(:snapshots, [])
           |> Keyword.get(:s3_bucket) == nil
  end

  defp row(rows, key), do: Enum.find(rows, &(&1["key"] == key))

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
