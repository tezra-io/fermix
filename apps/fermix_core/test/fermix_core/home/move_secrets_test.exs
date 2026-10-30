defmodule FermixCore.Home.MoveSecretsTest do
  # The stub store is one table for the VM: each test reads and writes under
  # its own profile, so nothing here sees another test's items.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm

  setup do
    tmp = SafeRm.make_tmp_dir!("move_secrets")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    profile = "mv-#{System.unique_integer([:positive])}"
    %{tmp: tmp, profile: profile}
  end

  defp config(profile) do
    """
    [fermix_core]
    profile = "#{profile}"

    [fermix_core.providers.anthropic]
    api_key = "@keyring" # kept in the Mac's keychain

    [fermix_core.providers.openai]
    api_key = "@file"

    [fermix_channels.telegram]
    bot_token = "@keyring"

    [fermix_core.plugin_secrets]
    slack = "@keyring"

    [fermix_core.cues.sources.invented-feed]
    kind = "webhook"
    key = "@keyring"

    [fermix_core.tools.web_search]
    tavily_api_key = "tvly-invented-plaintext"
    """
  end

  test "every keychain reference, named by the id secret.set takes", %{profile: profile} do
    assert {:ok, refs} = MoveSecrets.references(config(profile))

    assert Enum.map(refs, & &1.id) == [
             "anthropic_api_key",
             "telegram_bot_token",
             "slack_plugin_secret",
             "cue_source:invented-feed:key"
           ]

    assert Enum.map(refs, & &1.file) == [
             "secrets/ANTHROPIC_API_KEY",
             "secrets/TELEGRAM_BOT_TOKEN",
             "secrets/FERMIX_PLUGIN_SLACK",
             "secrets/cue_source.invented-feed.key"
           ]
  end

  test "a keychain reference Fermix cannot name is refused by its key", %{profile: profile} do
    text = config(profile) <> "\n[fermix_core.mystery]\ntoken = \"@keyring\"\n"
    assert MoveSecrets.references(text) == {:error, {:unknown, ["fermix_core.mystery.token"]}}
  end

  test "reads each value from the keychain, and names each one it cannot read",
       %{profile: profile} do
    put = fn key, value ->
      :ok = SecretWriter.put(key, value, profile: profile, store: :keyring)
    end

    put.(:anthropic_api_key, "sk-ant-invented")
    put.(:telegram_bot_token, "123:invented")
    put.(:slack_plugin_secret, "xoxb-invented")

    {:ok, refs} = MoveSecrets.references(config(profile))

    assert MoveSecrets.read(refs, profile) ==
             {:error, {:unreadable, ["cue_source:invented-feed:key"]}}

    put.({:cue_source, "invented-feed", :key}, "invented-cue-key")
    assert {:ok, values} = MoveSecrets.read(refs, profile)

    assert MoveSecrets.extra_files(values) == [
             {"secrets/ANTHROPIC_API_KEY", "sk-ant-invented"},
             {"secrets/TELEGRAM_BOT_TOKEN", "123:invented"},
             {"secrets/FERMIX_PLUGIN_SLACK", "xoxb-invented"},
             {"secrets/cue_source.invented-feed.key", "invented-cue-key"}
           ]
  end

  test "a staged home's references to carried files become file references, and only those",
       %{tmp: tmp, profile: profile} do
    staging = Path.join(tmp, "staging")
    File.mkdir_p!(Path.join(staging, "secrets"))
    File.write!(Path.join(staging, "secrets/ANTHROPIC_API_KEY"), "sk-ant-invented")
    File.write!(Path.join(staging, "secrets/cue_source.invented-feed.key"), "invented-cue-key")

    assert {:ok, text, adopted} = MoveSecrets.adopt(config(profile), staging)
    assert adopted == ["anthropic_api_key", "cue_source:invented-feed:key"]

    assert ConfigText.value(text, "fermix_core.providers.anthropic", "api_key") ==
             {:ok, ~s("@file")}

    assert ConfigText.value(text, "fermix_core.cues.sources.invented-feed", "key") ==
             {:ok, ~s("@file")}

    # Not carried: the reference stays, and the new host reports it missing.
    assert ConfigText.value(text, "fermix_channels.telegram", "bot_token") ==
             {:ok, ~s("@keyring")}

    assert text =~ "# kept in the Mac's keychain"
  end

  test "the references that did not resolve here, by id" do
    snapshot = %{
      fermix_core: [
        providers: [anthropic: [api_key: "@keyring"], openai: [api_key: "sk-resolved"]],
        snapshots: [s3_access_key_id: "@file"]
      ],
      fermix_channels: [telegram: [bot_token: "123:resolved"]]
    }

    assert MoveSecrets.missing(snapshot) == ["anthropic_api_key", "snapshot_s3_access_key_id"]
  end
end
