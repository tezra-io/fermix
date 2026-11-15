defmodule Fermix.CLI.Doctor.S3BackupsCheckTest do
  # D18: S3 backups run only on an Always On server's primary. A primary that
  # is not one but whose settings still name a bucket (set by hand in
  # config.toml) gets one Doctor row saying its S3 backups stopped, not
  # silence. The host and the device list are injected.
  use ExUnit.Case, async: true

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixTestSupport.SafeRm

  @mac %{device_id: "11111111-2222-4333-8444-555555555555", name: "orchard-mac"}

  setup do
    home = SafeRm.make_tmp_dir!("doctor-s3")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp settings!(home, text), do: File.write!(Path.join(home, "config.toml"), text)

  defp check(home, macos?, rows),
    do: Checks.s3_backups(home: home, macos?: macos?, desktop_rows: fn _home -> rows end)

  test "a Mac primary with a bucket in its settings is told its S3 backups stopped",
       %{home: home} do
    settings!(home, "[fermix_core.snapshots]\ns3_bucket = \"invented-snapshots\"\n")

    assert check(home, true, {:ok, []}) == %{
             name: "s3 backups",
             status: :warn,
             detail:
               "stopped: config.toml names the S3 bucket invented-snapshots, but Fermix keeps " <>
                 "S3 backups only on an Always On server, and this Mac is not one. Remove " <>
                 "s3_bucket from [fermix_core.snapshots] to clear this."
           }
  end

  test "a Linux primary that never moved is told the same, in its own words", %{home: home} do
    settings!(home, "[fermix_core.snapshots]\ns3_bucket = \"invented-snapshots\"\n")

    assert %{status: :warn, detail: detail} = check(home, false, {:ok, []})
    assert detail =~ "and this computer is not one: no desktop moved its home here."
  end

  test "an Always On server's primary, and a home naming no bucket, have no row",
       %{home: home} do
    settings!(home, "[fermix_core.snapshots]\ns3_bucket = \"invented-snapshots\"\n")
    assert check(home, false, {:ok, [@mac]}) == nil

    settings!(home, "[fermix_core.snapshots]\ninterval_hours = 6\n")
    assert check(home, true, {:ok, []}) == nil
  end

  test "a desktop's retired settings are the primary's to keep, so a device has no row",
       %{home: home} do
    settings!(
      home,
      "[fermix_core.engine]\nrole = \"device\"\n\n" <>
        "[fermix_core.snapshots]\ns3_bucket = \"invented-snapshots\"\n"
    )

    assert check(home, true, {:ok, []}) == nil
  end

  test "the engine's doctor publishes the row in its local catalog" do
    assert "s3_backups" in Enum.map(Descriptor.catalog(:local), & &1.id)
  end
end
