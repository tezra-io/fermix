defmodule FermixCore.Auth.OAuthProvidersTest do
  # async: false — definition_from_env/2 reads the global [fermix_core :oauth]
  # client config.
  use ExUnit.Case, async: false

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders

  @client [client_id: "cid", client_secret: "sec"]

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

  describe "definition/2 — validation" do
    test "unknown providers are refused" do
      assert {:error, {:unsupported_oauth_provider, "slack"}} =
               OAuthProviders.definition("slack", @client)
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
  end
end
