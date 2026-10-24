defmodule FermixCore.Setup.SecretPathsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretPaths

  test "registers the plugin OAuth client secrets (google, github, notion, x, slack, tesla)" do
    for {key, env, provider} <- [
          {:google_oauth_client_secret, "GOOGLE_OAUTH_CLIENT_SECRET", "google"},
          {:github_oauth_client_secret, "GITHUB_OAUTH_CLIENT_SECRET", "github"},
          {:notion_oauth_client_secret, "NOTION_OAUTH_CLIENT_SECRET", "notion"},
          {:x_oauth_client_secret, "X_OAUTH_CLIENT_SECRET", "x"},
          {:slack_oauth_client_secret, "SLACK_OAUTH_CLIENT_SECRET", "slack"},
          {:tesla_oauth_client_secret, "TESLA_OAUTH_CLIENT_SECRET", "tesla"}
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

  # M27 §7.5: a plugin secret's `env` is only the keyring/account label
  # SecretWriter stores under. A `sandbox_env` entry would publish it as
  # [sandbox.env.<env>], a second credential source that makes "forget local
  # credential" a lie. Plugin credentials are BEAM-internal HTTP.
  test "every plugin secret sits under the plugin-secret shape and never reaches the sandbox env" do
    plugin_secrets = Enum.filter(SecretPaths.all(), &Map.has_key?(&1, :plugin))
    eligible = Enum.map(SecretPaths.sandbox_env_eligible(), & &1.key)

    assert plugin_secrets != []

    for secret <- plugin_secrets do
      assert secret.path == [:fermix_core, :plugin_secrets, secret.plugin]
      assert secret.optional? == true
      assert SecretPaths.fetch_plugin(secret.plugin) == secret
      refute Map.has_key?(secret, :sandbox_env)
      refute secret.key in eligible
    end
  end

  test "oauth client secrets are not sandbox_env eligible" do
    eligible = SecretPaths.sandbox_env_eligible() |> Enum.map(& &1.key)

    refute :google_oauth_client_secret in eligible
    refute :github_oauth_client_secret in eligible
    refute :notion_oauth_client_secret in eligible
    refute :x_oauth_client_secret in eligible
    refute :slack_oauth_client_secret in eligible
    refute :tesla_oauth_client_secret in eligible
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

  test "registers the FCM service account as a keychain-only mobile secret" do
    secret = SecretPaths.fetch!(:mobile_fcm_service_account)

    assert secret.env == "FERMIX_FCM_SERVICE_ACCOUNT"
    assert secret.path == [:fermix_channels, :mobile, :fcm, :service_account]
    assert secret.functionality == "Mobile FCM push"
    assert secret.optional? == true
    refute Map.get(secret, :sandbox_env, false)
    refute :mobile_fcm_service_account in Enum.map(SecretPaths.sandbox_env_eligible(), & &1.key)
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

  describe "env_override/2" do
    @runtime_exs Path.expand("../../../../../config/runtime.exs", __DIR__)

    # A variable `config/runtime.exs` layers over the stored value wins at every
    # start, so the daemon reports it wherever the stored value is shown as the
    # one in use. The registry flag is what the report reads; this pins it to
    # the file that actually does the layering, so neither can move alone.
    test "flags exactly the registry secrets config/runtime.exs overlays" do
      overlaid =
        ~r/put_env_overlay\.\(:\w+, "([A-Z0-9_]+)"\)/
        |> Regex.scan(File.read!(@runtime_exs), capture: :all_but_first)
        |> MapSet.new(&hd/1)

      registry = MapSet.new(SecretPaths.all(), & &1.env)

      flagged =
        SecretPaths.all()
        |> Enum.filter(&Map.get(&1, :env_overlay, false))
        |> MapSet.new(& &1.env)

      assert flagged == MapSet.intersection(overlaid, registry)
      assert "ANTHROPIC_API_KEY" in flagged
      refute "TELEGRAM_BOT_TOKEN" in flagged
    end

    # One rule for every secret: `put_env_overlay`, where a blank variable is
    # unset. A secret read any other way escapes both that rule and the flag
    # above, as `System.get_env(NAME) || stored` once let an exported empty
    # variable blank the stored secret.
    test "config/runtime.exs reads no registry secret from the environment but by the one rule" do
      source = File.read!(@runtime_exs)

      for %{env: env} <- SecretPaths.all() do
        refute source =~ ~s|System.get_env("#{env}")|,
               "#{env} is read outside put_env_overlay, so a blank variable is not unset"
      end
    end

    test "names the variable when it is set and nonblank for an overlaid secret" do
      env = %{"ANTHROPIC_API_KEY" => "proxy-managed"}

      assert SecretPaths.env_override(:anthropic_api_key, &Map.get(env, &1)) ==
               "ANTHROPIC_API_KEY"
    end

    test "answers nil for an unset or blank variable" do
      assert SecretPaths.env_override(:anthropic_api_key, fn _name -> nil end) == nil
      assert SecretPaths.env_override(:anthropic_api_key, fn _name -> "" end) == nil
    end

    # TELEGRAM_BOT_TOKEN is the keychain label only: runtime.exs never reads it,
    # so an exported one overrides nothing and must not be reported as if it did.
    test "answers nil for a secret runtime.exs never reads from the environment" do
      assert SecretPaths.env_override(:telegram_bot_token, fn _name -> "123:abc" end) == nil
    end
  end
end
