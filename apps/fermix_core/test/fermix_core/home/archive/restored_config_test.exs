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

  [sandbox]
  workspace_root = "/Users/invented/.fermix/workspace"
  extra_roots = ["/Users/invented/Projects"]
  """

  test "a restore onto another host moves the home's paths, withdraws harness consent and names the rest" do
    {:ok, text, settled} = RestoredConfig.settle(@config, facts(macos?: false, keyring: false))

    assert settled == %{
             rewritten: ["sandbox.workspace_root"],
             kept_paths: ["sandbox.extra_roots"],
             harness_consent_reset: true,
             secret_store_switched: true,
             imessage_disabled: false,
             keyring_secrets: 1
           }

    assert ConfigText.value(text, "sandbox", "workspace_root") ==
             {:ok, ~s("/home/invented/.fermix/workspace")}

    assert ConfigText.value(text, "fermix_core.harness", "approved") ==
             {:ok, "false"}

    assert text =~ "approved = false # given on the invented Mac"
    assert ConfigText.value(text, "fermix_core", "secret_store") == {:ok, ~s("file")}

    assert ConfigText.value(text, "sandbox", "extra_roots") ==
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

  test "a home already on the file store, or without consent, is left as it was" do
    config = ~s([fermix_core]\nsecret_store = "file"\n\n[fermix_core.harness]\napproved = false\n)

    assert {:ok, ^config, %{secret_store_switched: false, harness_consent_reset: false}} =
             RestoredConfig.settle(config, facts(macos?: false, keyring: false))
  end

  test "iMessage turned on is turned off away from a Mac, and kept on one" do
    config = "[fermix_channels.imessage]\nenabled = true\n"

    assert {:ok, linux_text, %{imessage_disabled: true}} =
             RestoredConfig.settle(config, facts(macos?: false, keyring: true))

    assert ConfigText.value(linux_text, "fermix_channels.imessage", "enabled") == {:ok, "false"}

    assert {:ok, ^config, %{imessage_disabled: false}} =
             RestoredConfig.settle(config, facts(macos?: true, keyring: false))
  end

  test "iMessage already off, or never configured, is left as it was" do
    off = "[fermix_channels.imessage]\nenabled = false\n"

    assert {:ok, ^off, %{imessage_disabled: false}} =
             RestoredConfig.settle(off, facts(macos?: false, keyring: true))

    assert {:ok, "", %{imessage_disabled: false}} =
             RestoredConfig.settle("", facts(macos?: false, keyring: true))
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

  defp facts(macos?: macos?, keyring: usable?) do
    %{old_root: @old, new_root: @new, macos?: macos?, keyring_usable?: fn -> usable? end}
  end
end
