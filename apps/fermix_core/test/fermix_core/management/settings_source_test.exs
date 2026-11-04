defmodule FermixCore.Management.Settings.SourceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Settings.Source

  test "a secret is present when its value resolved here, and a sentinel left behind is not" do
    snapshot = %{
      fermix_core: [
        providers: [
          anthropic: [api_key: "sk-ant-resolved"],
          openai: [api_key: "@keyring"],
          xai: [api_key: "@file"],
          mistral: [api_key: ""]
        ]
      ]
    }

    assert Source.secret_present?(snapshot, :anthropic_api_key)
    # A keychain reference this host could not resolve: a moved Mac home's,
    # or a locked keychain's. The pane must say it needs entering again.
    refute Source.secret_present?(snapshot, :openai_api_key)
    refute Source.secret_present?(snapshot, :xai_api_key)
    refute Source.secret_present?(snapshot, :mistral_api_key)
    refute Source.secret_present?(snapshot, :venice_api_key)
  end
end
