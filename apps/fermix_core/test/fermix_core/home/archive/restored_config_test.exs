defmodule FermixCore.Home.Archive.RestoredConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Archive.RestoredConfig

  @old "/Users/invented/.fermix"
  @new "/home/invented/.fermix"

  @config """
  [fermix_core.providers.openai]
  api_key = "@keyring"

  [fermix_core.harness]
  enabled = true
  approved = true # given on the invented Mac

  [fermix_core.meetings]
  recordings = "/Users/invented/.fermix/workspace/meetings"
  extra_roots = ["/Users/invented/Projects"]
  """

  # M98 D5: whether coding agents may run is the computer's own, so a restore
  # leaves the approval out with the rest of its machine settings, named; the
  # restored engine's own machine file says whether they run there.
  test "a restore onto another host moves the home's paths, leaves the coding approval out and names the rest" do
    {:ok, text, settled} = RestoredConfig.settle(@config, facts(macos?: false, keyring: false))

    assert settled == %{
             rewritten: ["fermix_core.meetings.recordings"],
             kept_paths: ["fermix_core.meetings.extra_roots"],
             secret_store_switched: true,
             instance_role_dropped: false,
             device_settings_dropped: ["fermix_core.harness.approved"],
             keyring_secrets: 1
           }

    assert ConfigText.value(text, "fermix_core.meetings", "recordings") ==
             {:ok, ~s("/home/invented/.fermix/workspace/meetings")}

    assert ConfigText.value(text, "fermix_core.harness", "approved") == :absent
    assert ConfigText.value(text, "fermix_core.harness", "enabled") == {:ok, "true"}
    refute text =~ "given on the invented Mac"
    assert ConfigText.value(text, "fermix_core", "secret_store") == {:ok, ~s("file")}

    assert ConfigText.value(text, "fermix_core.meetings", "extra_roots") ==
             {:ok, ~s(["/Users/invented/Projects"])}
  end

  test "on macOS, or where the keyring answers, the keyring is kept" do
    {:ok, mac_text, mac} = RestoredConfig.settle(@config, facts(macos?: true, keyring: false))
    {:ok, linux_text, linux} = RestoredConfig.settle(@config, facts(macos?: false, keyring: true))

    refute mac.secret_store_switched
    refute linux.secret_store_switched
    assert ConfigText.value(mac_text, "fermix_core", "secret_store") == :absent
    assert ConfigText.value(linux_text, "fermix_core", "secret_store") == :absent
  end

  test "a home already on the file store is left as it was" do
    config = ~s([fermix_core]\nsecret_store = "file"\n\n[fermix_core.harness]\nenabled = true\n)

    assert {:ok, ^config, %{secret_store_switched: false, device_settings_dropped: []}} =
             RestoredConfig.settle(config, facts(macos?: false, keyring: false))
  end

  # A server's snapshots, signed with its own instance role, never come with
  # its home to a Mac, which keeps none; a Linux restore may be that server's
  # own, whose first boot set the role up again. A bucket set by hand with
  # access keys is kept anywhere.
  test "a server's instance-role signing is left out on a Mac and kept elsewhere" do
    config = """
    [fermix_core.snapshots]
    interval_hours = 12
    s3_bucket = "invented-server-bucket"
    s3_region = "eu-north-1"
    s3_credentials = "instance_role"
    """

    assert {:ok, mac_text, %{instance_role_dropped: true}} =
             RestoredConfig.settle(config, facts(macos?: true, keyring: true))

    assert mac_text == "[fermix_core.snapshots]\ninterval_hours = 12\n"

    assert {:ok, ^config, %{instance_role_dropped: false}} =
             RestoredConfig.settle(config, facts(macos?: false, keyring: true))

    by_hand = "[fermix_core.snapshots]\ns3_bucket = \"invented-hand-set\"\n"

    assert {:ok, ^by_hand, %{instance_role_dropped: false}} =
             RestoredConfig.settle(by_hand, facts(macos?: true, keyring: true))
  end

  test "an explicit keyring store becomes the file store in place" do
    config = ~s([fermix_core]\nsecret_store = 'keyring'\n)

    assert {:ok, ~s([fermix_core]\nsecret_store = "file"\n), %{secret_store_switched: true}} =
             RestoredConfig.settle(config, facts(macos?: false, keyring: false))
  end

  test "the keyring is asked about only when a switch is possible" do
    never = fn -> flunk("the keyring was probed on macOS") end
    facts = %{old_root: @old, new_root: @new, macos?: true, keyring_usable?: never}

    assert {:ok, _text, _settled} = RestoredConfig.settle(@config, facts)
  end

  # M97 §4: an engine keeps this computer's own settings in machine.toml,
  # which no archive carries. A home an earlier engine wrote still has them in
  # config.toml (EC2 test 2026-11-08: a Mac's dev plugin folder moved to the
  # server, whose plugin registry could not load), so a restore leaves every
  # one out, on any host, and says so; the rest of a table is kept.
  test "the computer's own settings an earlier engine kept are left out, the rest kept" do
    config = """
    [fermix_core.agent]
    name = "Orchard"

    [sandbox]
    mode = "strict"
    workspace_root = "/Users/invented/.fermix/workspace"

    [sandbox.env]
    allow = ["INVENTED_TOKEN"]

    [fermix_core.computer_use]
    enabled = true

    [fermix_core.computer_history]
    enabled = true

    [fermix_core.plugins]
    enabled = ["invented-notes"]
    dev_local = "/Users/invented/.fermix/dev-plugins" # the plugin checkouts here

    [fermix_channels.imessage]
    enabled = true

    [fermix_channels.accessories]
    enabled = true
    """

    for macos? <- [true, false] do
      {:ok, text, settled} = RestoredConfig.settle(config, facts(macos?: macos?, keyring: true))

      # The home uses iMessage, with its owner and guests: the home's own
      # (M97 §4), kept on any host, where a Mac of the home may carry it.
      assert text == """
             [fermix_core.agent]
             name = "Orchard"

             [fermix_core.plugins]
             enabled = ["invented-notes"]

             [fermix_channels.imessage]
             enabled = true
             """

      # Computer history splits by key (M97 §4): whether the computer records
      # is its own; the home's route and grants would be kept.
      assert settled.device_settings_dropped == [
               "sandbox",
               "fermix_core.computer_use",
               "fermix_channels.accessories",
               "fermix_core.plugins.dev_local",
               "fermix_core.computer_history.enabled"
             ]

      assert settled.rewritten == []
      assert settled.kept_paths == []
    end
  end

  test "a home whose settings hold none of them is left as it was" do
    assert {:ok, "", %{device_settings_dropped: []}} =
             RestoredConfig.settle("", facts(macos?: false, keyring: true))
  end

  defp facts(macos?: macos?, keyring: usable?) do
    %{old_root: @old, new_root: @new, macos?: macos?, keyring_usable?: fn -> usable? end}
  end
end
