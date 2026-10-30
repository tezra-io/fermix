defmodule FermixCore.Home.Snapshot.ConfigTest do
  # async: false: the save and load run through `FERMIX_HOME` and application
  # environment, both global to the VM, and both are restored on exit.
  use ExUnit.Case, async: false

  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @recipient Recipient.encode(%{salt: <<3::128>>, public_key: <<4::256>>})

  # The shape application environment holds after a load, with the two
  # secrets as plaintext a setup save secures.
  @app_env [
    recipient: @recipient,
    interval_hours: 12,
    s3_bucket: "invented-snapshots",
    s3_region: "eu-west-1",
    s3_prefix: "fermix/home",
    s3_endpoint: "https://s3.invented.test",
    s3_credentials: :keys,
    s3_access_key_id: "AKIAINVENTED",
    s3_secret_access_key: "invented-secret"
  ]

  setup do
    home = System.get_env("FERMIX_HOME")
    snapshots = Application.fetch_env(:fermix_core, :snapshots)
    tmp = SafeRm.make_tmp_dir!("snapshot_config")
    System.put_env("FERMIX_HOME", tmp)

    on_exit(fn ->
      if home, do: System.put_env("FERMIX_HOME", home), else: System.delete_env("FERMIX_HOME")

      case snapshots do
        {:ok, value} -> Application.put_env(:fermix_core, :snapshots, value)
        :error -> Application.delete_env(:fermix_core, :snapshots)
      end

      SecretWriterStub.delete(:snapshot_s3_access_key_id)
      SecretWriterStub.delete(:snapshot_s3_secret_access_key)
      SafeRm.rm_rf!(tmp)
    end)

    %{home: tmp}
  end

  test "normalize and to_keyword are inverses over the app-environment shape" do
    assert Config.normalize(@app_env) == @app_env
    assert Config.normalize(Config.to_keyword(@app_env)) == @app_env
    assert Keyword.fetch!(Config.to_keyword(@app_env), :s3_credentials) == "keys"
    assert Config.to_keyword(Config.to_keyword(@app_env)) == Config.to_keyword(@app_env)
    assert Config.normalize(nil) == []
  end

  test "save and load round-trip the section, secrets secured and resolved", %{home: home} do
    snapshot = %{fermix_core: [snapshots: @app_env], fermix_channels: [], fermix_web: []}

    assert :ok = ConfigStore.save_snapshot(snapshot)
    contents = File.read!(Path.join(home, "config.toml"))

    assert contents =~ "[fermix_core.snapshots]\n"
    assert contents =~ ~s(\nrecipient = "#{@recipient}"\n)
    assert contents =~ ~s(s3_credentials = "keys")
    assert contents =~ ~s(s3_access_key_id = "@keyring")
    refute contents =~ "invented-secret"
    assert SecretWriterStub.get(:snapshot_s3_secret_access_key) == {:ok, "invented-secret"}

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    # Resolving a secret puts its key first; the values are the section's.
    assert Enum.sort(Keyword.fetch!(loaded.fermix_core, :snapshots)) == Enum.sort(@app_env)
    assert :ok = ConfigStore.apply_snapshot(loaded)
    assert Application.get_env(:fermix_core, :snapshots) == @app_env

    # A second save from the live snapshot, as setup makes it, is a fixed point.
    assert :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())
    assert section(File.read!(Path.join(home, "config.toml"))) == section(contents)

    assert ConfigStore.snapshots_config(home) |> elem(1) |> Keyword.get(:s3_bucket) ==
             "invented-snapshots"
  end

  defp section(contents) do
    [_before, rest] = String.split(contents, "[fermix_core.snapshots]\n", parts: 2)
    rest |> String.split("\n\n", parts: 2) |> hd()
  end

  test "an unset section is never written and reads as defaults", %{home: home} do
    assert :ok =
             ConfigStore.save_snapshot(%{fermix_core: [], fermix_channels: [], fermix_web: []})

    refute File.read!(Path.join(home, "config.toml")) =~ "fermix_core.snapshots"
    assert {:ok, []} = ConfigStore.snapshots_config(home)

    assert Config.interval_hours([]) == 6
    assert Config.s3([]) == :not_configured
    assert Config.recipient([]) == :absent
    assert Config.s3(s3_bucket: "b") == :not_configured
  end

  test "the S3 target is on with a recipient and a bucket, defaults filled" do
    assert {:ok, s3} = Config.s3(recipient: @recipient, s3_bucket: "invented-snapshots")

    assert s3 == %{
             bucket: "invented-snapshots",
             region: "us-east-1",
             prefix: "fermix",
             endpoint: nil,
             credentials: :instance_profile,
             access_key_id: nil,
             secret_access_key: nil
           }
  end

  test "an empty text value is a cleared field" do
    assert Config.normalize(%{"s3_bucket" => "", "s3_prefix" => "", "interval_hours" => 3}) ==
             [interval_hours: 3]
  end

  test "each bad value is refused by name, with the fix" do
    for {key, value, said} <- [
          {"interval_hours", 0, "takes a whole number of hours from 1 to 168"},
          {"interval_hours", 169, "from 1 to 168"},
          {"s3_bucket", "Invented_Bucket", "takes a bucket name"},
          {"s3_region", "EU West", "takes a region name"},
          {"s3_prefix", "/fermix", "with no slash at either end"},
          {"s3_endpoint", "ftp://s3.invented.test", "takes the storage service's address"},
          {"s3_endpoint", "https://s3.invented.test/path", "with no path"},
          {"s3_credentials", "root", ~s(takes "instance_profile" or "keys")},
          {"s3_access_key_id", "two\nlines", "takes a single line"}
        ] do
      error = assert_raise ArgumentError, fn -> Config.normalize(%{key => value}) end
      assert error.message =~ "config.toml [fermix_core.snapshots] #{key} takes", key
      assert error.message =~ said, key
      assert String.ends_with?(error.message, "Fix it and save again."), key
    end

    error =
      assert_raise ArgumentError, fn -> Config.normalize(%{"recipient" => "fxsnap1.x.y"}) end

    assert error.message =~ "recipient is not a recovery key Fermix wrote"

    error = assert_raise ArgumentError, fn -> Config.normalize(%{"bucket" => "x"}) end
    assert error.message =~ "has unknown key(s): bucket"
  end

  test "a bad section is refused when the file is loaded", %{home: home} do
    File.write!(Path.join(home, "config.toml"), "[fermix_core.snapshots]\ninterval_hours = 0\n")

    assert_raise ArgumentError, ~r/interval_hours takes a whole number/, fn ->
      ConfigStore.load_runtime_config()
    end

    assert {:error, {:config, _file, message}} = ConfigStore.snapshots_config(home)
    assert message =~ "interval_hours takes a whole number"
  end
end
