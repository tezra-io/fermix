defmodule FermixCore.Auth.RefreshClientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.RefreshClient

  @client [client_id: "client-id", client_secret: "stale-secret", scopes: []]

  defp provider(id) do
    {:ok, provider} = OAuthProviders.definition(id, @client)
    provider
  end

  # Answers every request with one JSON response and reports each request to
  # the test, so a retry is visible as a second message.
  defp counting_plug(status, body) do
    parent = self()

    fn conn ->
      send(parent, :token_request)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  describe "refresh/3 — a refused client" do
    test "X 401 unauthorized_client is the typed refusal, asked once" do
      plug =
        counting_plug(401, %{
          "error" => "unauthorized_client",
          "error_description" => "Missing valid authorization header"
        })

      assert {:error, {:oauth_client_rejected, detail}} =
               RefreshClient.refresh(provider("x"), "old_rt", plug: plug)

      assert detail.error == "unauthorized_client"
      assert detail.status == 401
      assert_received :token_request
      refute_received :token_request
    end

    # A success status is never read as tokens when it carries a refusal.
    test "GitHub and Slack refuse with 200, and it is still the typed refusal" do
      assert {:error, {:oauth_client_rejected, %{provider: "github", status: 200}}} =
               RefreshClient.refresh(provider("github"), "old_rt",
                 plug: counting_plug(200, %{"error" => "incorrect_client_credentials"})
               )

      assert {:error, {:oauth_client_rejected, %{provider: "slack", error: "bad_client_secret"}}} =
               RefreshClient.refresh(provider("slack"), "old_rt",
                 plug: counting_plug(200, %{"ok" => false, "error" => "bad_client_secret"})
               )
    end
  end

  describe "refresh/3 — everything else keeps its classification" do
    test "invalid_grant stays a permanent 4xx" do
      body = %{"error" => "invalid_grant"}

      assert {:error, {:permanent, 400, ^body}} =
               RefreshClient.refresh(provider("x"), "old_rt", plug: counting_plug(400, body))
    end

    test "a built-in provider's invalid_client stays a permanent 4xx" do
      body = %{"error" => "invalid_client"}

      assert {:error, {:permanent, 401, ^body}} =
               RefreshClient.refresh(OAuthProvider.xai(), "old_rt",
                 plug: counting_plug(401, body)
               )
    end

    test "a 200 without tokens that is no refusal stays an invalid token response" do
      assert {:error, :invalid_token_response} =
               RefreshClient.refresh(provider("github"), "old_rt",
                 plug: counting_plug(200, %{"error" => "bad_verification_code"})
               )
    end

    test "a 200 with tokens still refreshes" do
      plug = counting_plug(200, %{"access_token" => "new_at", "refresh_token" => "new_rt"})

      assert {:ok, %{access_token: "new_at", refresh_token: "new_rt"}} =
               RefreshClient.refresh(provider("x"), "old_rt", plug: plug)
    end
  end
end
