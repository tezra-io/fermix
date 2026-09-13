defmodule FermixCore.Auth.OAuthProvidersTest do
  # async: false — definition_from_env/2 reads the global [fermix_core :oauth]
  # client config.
  use ExUnit.Case, async: false

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders

  @client [client_id: "cid", client_secret: "sec"]
  # Tesla is the one regional provider, and its region is part of the sign-in
  # client rather than a default, so its client config always carries one.
  @tesla @client ++ [region: "na"]

  describe "secret redaction" do
    test "inspect/1 never renders the OAuth client_secret in plaintext" do
      {:ok, provider} = OAuthProviders.definition("google", @client ++ [scopes: ["openid"]])

      dumped = inspect(provider)
      # `@derive {Inspect, except: [:client_secret]}` omits the field entirely
      # (collapsed into the trailing `...`), so neither the name nor the value shows.
      refute dumped =~ "client_secret"
      refute dumped =~ "sec"
      assert dumped =~ "client_id: \"cid\""
    end
  end

  describe "definition/2 — google" do
    test "builds the Google provider (endpoints, offline consent, defaults)" do
      assert {:ok, %OAuthProvider{} = provider} =
               OAuthProviders.definition("google", @client ++ [scopes: ["openid", "email"]])

      assert provider.id == :google
      assert provider.authorize_url == "https://accounts.google.com/o/oauth2/v2/auth"
      assert provider.token_url == "https://oauth2.googleapis.com/token"
      assert provider.userinfo_url == "https://openidconnect.googleapis.com/v1/userinfo"
      assert provider.client_id == "cid"
      assert provider.client_secret == "sec"
      assert provider.redirect_port == 1455
      assert provider.redirect_path == "/auth/callback"
      assert provider.scopes == ["openid", "email"]

      assert provider.extra_authorize_params == %{
               "access_type" => "offline",
               "prompt" => "consent"
             }

      assert provider.token_headers == []
      assert provider.token_auth == :body
      assert provider.scope_delimiter == " "
      assert provider.fixed_port? == false
    end
  end

  describe "definition/2 — github" do
    test "builds the GitHub provider (accept-json exchange, comma scopes)" do
      assert {:ok, %OAuthProvider{} = provider} =
               OAuthProviders.definition("github", @client ++ [scopes: ["read:user", "repo"]])

      assert provider.id == :github
      assert provider.authorize_url == "https://github.com/login/oauth/authorize"
      assert provider.token_url == "https://github.com/login/oauth/access_token"
      assert provider.userinfo_url == "https://api.github.com/user"
      assert provider.redirect_port == 1457
      assert provider.scopes == ["read:user", "repo"]
      assert provider.token_headers == [{"accept", "application/json"}]
      assert provider.token_auth == :body
      assert provider.scope_delimiter == ","
      assert provider.fixed_port? == false
    end
  end

  describe "definition/2 — notion" do
    test "builds the Notion provider (basic auth, fixed port, no userinfo)" do
      assert {:ok, %OAuthProvider{} = provider} =
               OAuthProviders.definition("notion", @client ++ [scopes: []])

      assert provider.id == :notion
      assert provider.authorize_url == "https://api.notion.com/v1/oauth/authorize"
      assert provider.token_url == "https://api.notion.com/v1/oauth/token"
      assert provider.userinfo_url == nil
      assert provider.redirect_port == 1458
      assert provider.scopes == []
      assert provider.extra_authorize_params == %{"owner" => "user"}
      assert provider.token_auth == :basic
      assert provider.fixed_port? == true
    end
  end

  describe "definition/2 — x" do
    test "builds the X provider (basic auth, fixed port, no userinfo)" do
      assert {:ok, %OAuthProvider{} = provider} =
               OAuthProviders.definition(
                 "x",
                 @client ++ [scopes: ["tweet.read", "users.read", "offline.access"]]
               )

      assert provider.id == :x
      assert provider.authorize_url == "https://x.com/i/oauth2/authorize"
      assert provider.token_url == "https://api.x.com/2/oauth2/token"
      assert provider.userinfo_url == nil
      assert provider.redirect_host == "127.0.0.1"
      assert provider.redirect_port == 1459
      assert provider.scopes == ["tweet.read", "users.read", "offline.access"]
      assert provider.token_auth == :basic
      assert provider.fixed_port? == true
      assert provider.scope_delimiter == " "
    end
  end

  describe "definition/2 — slack" do
    test "builds the Slack provider (comma scopes, fixed port, no userinfo)" do
      assert {:ok, %OAuthProvider{} = provider} =
               OAuthProviders.definition(
                 "slack",
                 @client ++ [scopes: ["channels:read", "channels:history", "users:read"]]
               )

      assert provider.id == :slack
      assert provider.authorize_url == "https://slack.com/oauth/v2/authorize"
      assert provider.token_url == "https://slack.com/api/oauth.v2.access"
      assert provider.userinfo_url == nil
      assert provider.redirect_host == "127.0.0.1"
      assert provider.redirect_port == 1460
      assert provider.scopes == ["channels:read", "channels:history", "users:read"]
      assert provider.scope_delimiter == ","
      assert provider.token_auth == :body
      assert provider.fixed_port? == true
    end
  end

  describe "definition/2 — tesla" do
    test "builds the Tesla provider (regional audience, public redirect, fixed port)" do
      assert {:ok, %OAuthProvider{} = provider} =
               OAuthProviders.definition(
                 "tesla",
                 @tesla ++ [scopes: ["openid", "offline_access", "vehicle_device_data"]]
               )

      assert provider.id == :tesla
      assert provider.authorize_url == "https://auth.tesla.com/oauth2/v3/authorize"
      assert provider.token_url == "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"
      assert provider.userinfo_url == nil
      assert provider.redirect_host == "localhost"
      assert provider.redirect_port == 1461
      assert provider.redirect_path == "/auth/callback"
      assert provider.scopes == ["openid", "offline_access", "vehicle_device_data"]
      assert provider.token_auth == :body
      assert provider.fixed_port? == true
      assert provider.scope_delimiter == " "
      assert provider.client_rejection_errors == ["invalid_client"]
    end

    # Tesla accepts no loopback redirect URI, so the registered one is a public
    # bounce page that forwards the callback to the loopback listener. The
    # listener still binds the fixed loopback port above.
    test "the registered redirect URI is the public bounce page, not the loopback" do
      assert {:ok, provider} = OAuthProviders.definition("tesla", @tesla)

      assert provider.public_redirect_uri ==
               "https://fermix.ai/api/integrations/tesla/callback"
    end

    test "an operator-supplied redirect URI overrides the default bounce page" do
      assert {:ok, provider} =
               OAuthProviders.definition(
                 "tesla",
                 @tesla ++ [redirect_uri: "https://example.test/tesla/callback"]
               )

      assert provider.public_redirect_uri == "https://example.test/tesla/callback"
    end

    # The region -> Fleet API base URL table lives in this registry alone, and
    # the base URL is what the code exchange must send as `audience`. The set is
    # read off `regions/1` rather than listed again, so a region offered to the
    # operator with no audience behind it fails here.
    test "each offered region selects its Fleet API base URL as the exchange audience" do
      audiences = %{
        "na" => "https://fleet-api.prd.na.vn.cloud.tesla.com",
        "eu" => "https://fleet-api.prd.eu.vn.cloud.tesla.com"
      }

      for %{id: region} <- OAuthProviders.regions("tesla") do
        assert {:ok, provider} = OAuthProviders.definition("tesla", @client ++ [region: region])
        assert provider.region == region
        assert provider.extra_token_params == %{"audience" => Map.fetch!(audiences, region)}
      end
    end

    # The region is chosen as part of the sign-in client. There is no default:
    # a grant minted for the wrong region is refused by Tesla on every call, so
    # an unchosen region is a refusal here rather than a silent north america.
    test "a missing region is refused by name, never defaulted" do
      assert {:error, {:missing_oauth_region, "tesla"}} =
               OAuthProviders.definition("tesla", @client)

      assert {:error, {:missing_oauth_region, "tesla"}} =
               OAuthProviders.definition("tesla", @client ++ [region: nil])

      assert {:error, {:missing_oauth_region, "tesla"}} =
               OAuthProviders.definition("tesla", @client ++ [region: "  "])
    end

    # A region with no Fleet API base URL has no audience to send, so it is
    # refused by name instead of silently falling back to another region.
    test "an unknown region is refused by definition/2, never defaulted" do
      assert {:error, {:invalid_oauth_region, "tesla", "apac"}} =
               OAuthProviders.definition("tesla", @client ++ [region: "apac"])
    end

    # China needs its own Tesla application and the plugin publishes no host for
    # it, so it is not offered and not accepted.
    test "china is not a region this registry offers or accepts" do
      refute "cn" in Enum.map(OAuthProviders.regions("tesla"), & &1.id)

      assert {:error, {:invalid_oauth_region, "tesla", "cn"}} =
               OAuthProviders.definition("tesla", @client ++ [region: "cn"])
    end

    # The probe that confirms the account's own region after a sign-in calls the
    # chosen region's own Fleet API host, so a mismatch is Tesla's answer rather
    # than a guess.
    test "the region probe calls the chosen region's own Fleet API host" do
      assert {:ok, provider} = OAuthProviders.definition("tesla", @client ++ [region: "eu"])

      assert provider.region_probe == %{
               url: "https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/users/region",
               path: ["response", "region"]
             }
    end

    test "a non-regional provider ignores a region it has no use for" do
      assert {:ok, provider} = OAuthProviders.definition("github", @client ++ [region: "apac"])
      assert provider.region == nil
      assert provider.extra_token_params == %{}
      assert provider.region_probe == nil
    end

    test "every other provider carries no region and no extra token params" do
      for id <- ~w(google github notion x slack) do
        assert {:ok, provider} = OAuthProviders.definition(id, @client)
        assert provider.region == nil
        assert provider.extra_token_params == %{}
        assert provider.public_redirect_uri == nil
        assert provider.region_probe == nil
      end
    end
  end

  # One table of regions: the picker the operator chooses from, the audience the
  # exchange sends, and the set validation accepts all read it here.
  describe "regions/1" do
    test "tesla offers the two regions its plugin publishes a host for" do
      assert OAuthProviders.regions("tesla") == [
               %{id: "na", label: "North America and Asia-Pacific"},
               %{id: "eu", label: "Europe, Middle East and Africa"}
             ]
    end

    test "every other supported provider offers none" do
      for id <- ~w(google github notion x slack) do
        assert OAuthProviders.regions(id) == []
      end
    end

    test "a provider this registry does not define has no regions to lend" do
      assert_raise FunctionClauseError, fn -> OAuthProviders.regions("linear") end
    end

    test "the label of one region is the one the picker publishes" do
      assert OAuthProviders.region_label("tesla", "eu") == "Europe, Middle East and Africa"
      assert OAuthProviders.region_label("tesla", "apac") == nil
      assert OAuthProviders.region_label("github", "eu") == nil
    end
  end

  # Tesla answers a call to the wrong region with 421 and names the right base
  # URL in its own error text. Mapping that back to a region id is the inverse
  # of the audience table, so it has the same owner.
  describe "region_for_base_url/2" do
    test "names the region whose Fleet API base URL the text carries" do
      assert OAuthProviders.region_for_base_url(
               "tesla",
               "user out of region, use base URL: https://fleet-api.prd.eu.vn.cloud.tesla.com"
             ) == "eu"

      assert OAuthProviders.region_for_base_url(
               "tesla",
               "use base URL: https://fleet-api.prd.na.vn.cloud.tesla.com"
             ) == "na"
    end

    test "a text naming no known base URL names no region" do
      assert OAuthProviders.region_for_base_url("tesla", "user out of region") == nil

      assert OAuthProviders.region_for_base_url(
               "tesla",
               "use base URL: https://fleet-api.prd.cn.vn.cloud.tesla.cn"
             ) == nil
    end

    test "a provider with one region never names one" do
      assert OAuthProviders.region_for_base_url("github", "https://api.github.com") == nil
    end
  end

  describe "validate_region/2" do
    test "accepts exactly the ids regions/1 publishes" do
      for %{id: id} <- OAuthProviders.regions("tesla") do
        assert :ok = OAuthProviders.validate_region("tesla", id)
      end
    end

    test "refuses a missing region and an unoffered one apart" do
      assert {:error, {:missing_oauth_region, "tesla"}} =
               OAuthProviders.validate_region("tesla", nil)

      assert {:error, {:invalid_oauth_region, "tesla", "cn"}} =
               OAuthProviders.validate_region("tesla", "cn")
    end

    test "a provider with one region accepts anything, region included" do
      assert :ok = OAuthProviders.validate_region("github", nil)
      assert :ok = OAuthProviders.validate_region("github", "eu")
    end
  end

  describe "definition/2 — validation" do
    test "unknown providers are refused" do
      assert {:error, {:unsupported_oauth_provider, "linear"}} =
               OAuthProviders.definition("linear", @client)
    end

    test "a nil provider (manifest without one) is refused" do
      assert {:error, {:unsupported_oauth_provider, nil}} =
               OAuthProviders.definition(nil, @client)
    end

    test "missing client credentials return needs_client_config" do
      assert {:error, :needs_client_config} = OAuthProviders.definition("github", [])

      assert {:error, :needs_client_config} =
               OAuthProviders.definition("notion", client_id: "cid")
    end

    test "non-desktop client types are refused" do
      assert {:error, {:invalid_oauth_client_type, "github", "web"}} =
               OAuthProviders.definition("github", @client ++ [client_type: "web"])
    end

    test "redirect port and host overrides are honored" do
      assert {:ok, provider} =
               OAuthProviders.definition(
                 "github",
                 @client ++ [redirect_host: "localhost", redirect_port: 9999]
               )

      assert provider.redirect_host == "localhost"
      assert provider.redirect_port == 9999
    end

    test "default redirect host is per-provider: notion uses localhost, github/x use 127.0.0.1" do
      # Notion forces https for IP-literal redirect URIs but allows http for the
      # localhost hostname, so its loopback redirect must use localhost. X is the
      # inverse — its portal accepts http://127.0.0.1 but not localhost.
      assert {:ok, notion} = OAuthProviders.definition("notion", @client)
      assert notion.redirect_host == "localhost"

      assert {:ok, github} = OAuthProviders.definition("github", @client)
      assert github.redirect_host == "127.0.0.1"

      assert {:ok, x} = OAuthProviders.definition("x", @client)
      assert x.redirect_host == "127.0.0.1"
    end
  end

  # One table of operator-facing provider names: the setup page's client forms
  # and every refused-client sentence read it here, never a copy of their own.
  describe "display names" do
    test "every plugin provider has one, and its built definition carries it" do
      assert OAuthProviders.providers() == ~w(google github notion x slack tesla)

      names =
        Map.new(OAuthProviders.providers(), fn id ->
          {:ok, provider} = OAuthProviders.definition(id, client_for(id))
          assert provider.display_name == OAuthProviders.display_name(id)
          {id, provider.display_name}
        end)

      assert names == %{
               "google" => "Google",
               "github" => "GitHub",
               "notion" => "Notion",
               "x" => "X",
               "slack" => "Slack",
               "tesla" => "Tesla"
             }
    end

    test "a provider this registry does not define has no name to lend" do
      assert_raise FunctionClauseError, fn -> OAuthProviders.display_name("linear") end
    end
  end

  describe "definition_from_env/2" do
    setup do
      previous = Application.get_env(:fermix_core, :oauth)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:fermix_core, :oauth)
          value -> Application.put_env(:fermix_core, :oauth, value)
        end
      end)

      :ok
    end

    test "builds a definition from [fermix_core.oauth.<provider>] client config" do
      Application.put_env(:fermix_core, :oauth, %{
        "github" => [
          client_type: "desktop_public_pkce",
          client_id: "gh-id",
          client_secret: "gh-sec"
        ]
      })

      assert {:ok, provider} = OAuthProviders.definition_from_env("github", ["repo"])
      assert provider.id == :github
      assert provider.client_id == "gh-id"
      assert provider.client_secret == "gh-sec"
      assert provider.scopes == ["repo"]
    end

    test "missing client config returns needs_client_config" do
      Application.put_env(:fermix_core, :oauth, %{})

      assert {:error, :needs_client_config} =
               OAuthProviders.definition_from_env("notion", [])
    end

    test "unknown providers are refused before client-config checks" do
      Application.put_env(:fermix_core, :oauth, %{})

      assert {:error, {:unsupported_oauth_provider, "linear"}} =
               OAuthProviders.definition_from_env("linear", [])
    end

    # A client saved before the region was part of it has no audience to send, so
    # the refresh path refuses it by name rather than picking a region for it.
    test "a stored client config with no region is refused on refresh too" do
      Application.put_env(:fermix_core, :oauth, %{
        "tesla" => [
          client_type: "desktop_public_pkce",
          client_id: "t-id",
          client_secret: "t-sec"
        ]
      })

      assert {:error, {:missing_oauth_region, "tesla"}} =
               OAuthProviders.definition_from_env("tesla", ["openid"])
    end

    # The refresh path reads the region from config too, so a hand-edited
    # config.toml region must fail loud here and not just on the login path.
    test "an unknown region in the stored client config is refused on refresh too" do
      Application.put_env(:fermix_core, :oauth, %{
        "tesla" => [
          client_type: "desktop_public_pkce",
          client_id: "t-id",
          client_secret: "t-sec",
          region: "apac"
        ]
      })

      assert {:error, {:invalid_oauth_region, "tesla", "apac"}} =
               OAuthProviders.definition_from_env("tesla", ["openid"])
    end

    test "a stored tesla client config rebuilds its audience for refresh-path reads" do
      Application.put_env(:fermix_core, :oauth, %{
        "tesla" => [
          client_type: "desktop_public_pkce",
          client_id: "t-id",
          client_secret: "t-sec",
          region: "eu"
        ]
      })

      assert {:ok, provider} = OAuthProviders.definition_from_env("tesla", ["openid"])
      assert provider.region == "eu"

      assert provider.extra_token_params == %{
               "audience" => "https://fleet-api.prd.eu.vn.cloud.tesla.com"
             }
    end
  end

  # A regional provider's client is incomplete without a region, so the case
  # sets that walk every provider carry the first region each one offers.
  defp client_for(id) do
    case OAuthProviders.regions(id) do
      [] -> @client
      [%{id: region} | _rest] -> @client ++ [region: region]
    end
  end
end
