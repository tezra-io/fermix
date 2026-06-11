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

  test "oauth client secrets are not sandbox_env eligible" do
    eligible = SecretPaths.sandbox_env_eligible() |> Enum.map(& &1.key)

    refute :google_oauth_client_secret in eligible
    refute :github_oauth_client_secret in eligible
    refute :notion_oauth_client_secret in eligible
    refute :x_oauth_client_secret in eligible
  end
end
