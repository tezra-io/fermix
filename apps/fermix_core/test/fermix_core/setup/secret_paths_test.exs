defmodule FermixCore.Setup.SecretPathsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretPaths

  test "registers the plugin OAuth client secrets (google, github, notion, x)" do
    for {key, env, provider} <- [
          {:google_oauth_client_secret, "GOOGLE_OAUTH_CLIENT_SECRET", "google"},
          {:github_oauth_client_secret, "GITHUB_OAUTH_CLIENT_SECRET", "github"},
          {:notion_oauth_client_secret, "NOTION_OAUTH_CLIENT_SECRET", "notion"},
          {:x_oauth_client_secret, "X_OAUTH_CLIENT_SECRET", "x"}
        ] do
      secret = SecretPaths.fetch!(key)
      assert secret.env == env
      assert secret.path == [:fermix_core, :oauth, provider, :client_secret]
    end
  end

  # M31 §14.1: one key, two consumers. The operator-facing string is what a
  # keyring-resolution warning names, so it must not claim only web search.
  test "the Brave key names both of its consumers" do
    secret = SecretPaths.fetch!(:brave_api_key)

    assert secret.path == [:fermix_core, :tools, :web_search, :brave_api_key]
    assert secret.functionality == "Brave web_search backend and place_search"
  end

  test "registers the Eden plugin secret under the plugin-secret shape" do
    secret = SecretPaths.fetch!(:eden_plugin_secret)

    assert secret.env == "FERMIX_PLUGIN_EDEN"
    assert secret.path == [:fermix_core, :plugin_secrets, "eden"]
    assert secret.plugin == "eden"
    assert secret.functionality == "Eden plugin"
    assert secret.optional? == true
    assert SecretPaths.fetch_plugin("eden") == secret
  end

  test "the Eden plugin secret has exactly one source: the keychain, not the env" do
    # M27 §7.5: `env` is the keyring/account label SecretWriter stores under. A
    # `sandbox_env` entry would publish it as [sandbox.env.FERMIX_PLUGIN_EDEN],
    # creating a second credential source and making "forget local credential"
    # a lie. Eden is BEAM-internal HTTP, like the other plugin secrets.
    secret = SecretPaths.fetch!(:eden_plugin_secret)

    refute Map.has_key?(secret, :sandbox_env)
    refute :eden_plugin_secret in Enum.map(SecretPaths.sandbox_env_eligible(), & &1.key)
  end

  test "oauth client secrets are not sandbox_env eligible" do
    eligible = SecretPaths.sandbox_env_eligible() |> Enum.map(& &1.key)

    refute :google_oauth_client_secret in eligible
    refute :github_oauth_client_secret in eligible
    refute :notion_oauth_client_secret in eligible
    refute :x_oauth_client_secret in eligible
  end

  test "registers the APNs signing key as a keychain-only mobile secret" do
    secret = SecretPaths.fetch!(:mobile_apns_key)

    assert secret.env == "FERMIX_APNS_KEY"
    assert secret.path == [:fermix_channels, :mobile, :push, :key]
    assert secret.functionality == "Mobile APNs push"
    assert secret.optional? == true
    refute Map.get(secret, :sandbox_env, false)
    refute :mobile_apns_key in Enum.map(SecretPaths.sandbox_env_eligible(), & &1.key)
  end

  # M21 Phase 3: the Zoom RTMS client secret is secure-on-save like every other
  # setup secret, and stays off [sandbox.env] — the meetbot sidecar is spawned
  # for Meet and must never inherit the Zoom credentials.
  test "registers the Zoom RTMS client secret as a keychain-only meetings secret" do
    secret = SecretPaths.fetch!(:meetings_zoom_client_secret)

    assert secret.env == "MEETINGS_ZOOM_CLIENT_SECRET"
    assert secret.path == [:fermix_core, :meetings, :zoom_client_secret]
    assert secret.functionality == "Zoom RTMS meeting notetaker"
    assert secret.optional? == true
    refute Map.get(secret, :sandbox_env, false)
    refute :meetings_zoom_client_secret in Enum.map(SecretPaths.sandbox_env_eligible(), & &1.key)
  end
end
