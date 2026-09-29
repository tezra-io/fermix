defmodule FermixCore.Auth.RefreshClientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.RefreshClient

  @client [client_id: "client-id", client_secret: "stale-secret", scopes: []]

  # A regional provider's client is incomplete without a region, so a sweep over
  # every provider carries the first region each one offers.
  defp provider(id) do
    {:ok, provider} = OAuthProviders.definition(id, @client ++ region_of(id))
    provider
  end

  defp region_of(id) do
    case OAuthProviders.regions(id) do
      [] -> []
      [%{id: region} | _rest] -> [region: region]
    end
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

  # 408 and 429 say the endpoint did not act on the request, not that the grant
  # is dead, so they take the bounded retries a 5xx takes and never end as the
  # permanent 4xx that quarantines a live grant. `:retry_sleep` records each
  # backoff instead of sleeping it.
  describe "refresh — a 408 or 429 is transient" do
    # Answers `status` to the first `failures` requests, then a token pair.
    defp flaky_plug(status, failures) do
      parent = self()
      seen = :counters.new(1, [])

      fn conn ->
        :counters.add(seen, 1, 1)
        send(parent, :token_request)

        {code, body} =
          if :counters.get(seen, 1) <= failures,
            do: {status, %{"error" => "slow_down"}},
            else: {200, %{"access_token" => "new_at", "refresh_token" => "new_rt"}}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(code, Jason.encode!(body))
      end
    end

    defp recorded_sleep(parent), do: fn ms -> send(parent, {:retry_sleep, ms}) end

    # The Codex path and the provider path, each with its own fresh options.
    defp both_paths(options) do
      [
        {:codex, fn -> RefreshClient.refresh("old_rt", options.()) end},
        {:plugin, fn -> RefreshClient.refresh(provider("github"), "old_rt", options.()) end}
      ]
    end

    defp flaky(status, failures) do
      parent = self()
      fn -> [plug: flaky_plug(status, failures), retry_sleep: recorded_sleep(parent)] end
    end

    test "one 429 or 408, then a 200, refreshes on both paths" do
      for status <- [408, 429], {path, refresh} <- both_paths(flaky(status, 1)) do
        assert {{:ok, %{access_token: "new_at"}}, ^path} = {refresh.(), path}
        assert_received {:retry_sleep, 350}
      end
    end

    test "a 429 or 408 on every attempt ends after three, and not as a permanent 4xx" do
      for status <- [408, 429], {path, refresh} <- both_paths(flaky(status, 3)) do
        assert {{:error, "Refresh failed (" <> detail}, ^path} = {refresh.(), path}
        assert String.starts_with?(detail, "#{status})")
        for _attempt <- 1..3, do: assert_received(:token_request)
        refute_received :token_request
        assert_received {:retry_sleep, 350}
        assert_received {:retry_sleep, 700}
      end
    end

    # A seam that is not a one-argument function is refused before the first
    # request, not at the first retry deep inside a locked refresh.
    test "a :retry_sleep that is not a one-argument function is refused up front" do
      for bad <- [:later, fn -> :ok end],
          {path, refresh} <- both_paths(fn -> [plug: flaky_plug(429, 3), retry_sleep: bad] end) do
        assert_raise ArgumentError, ~r/:retry_sleep must be a one-argument function/, fn ->
          refresh.()
        end

        refute_received :token_request, "#{path} sent a request before refusing the seam"
      end
    end
  end

  # `extra_token_params` belongs to the authorization-code exchange alone: Tesla
  # refuses an exchange without `audience` and its refresh form is documented
  # without one, so a refresh that copied the exchange's extras would be sending
  # a parameter the endpoint never asked for.
  describe "refresh/3 — the exchange-only token params never travel" do
    test "a Tesla refresh sends no audience, only the documented refresh form" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:refresh_form, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "new_at"}))
      end

      assert {:ok, %{access_token: "new_at"}} =
               RefreshClient.refresh(provider("tesla"), "old_rt", plug: plug)

      assert_received {:refresh_form, form}
      refute Map.has_key?(form, "audience")
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "old_rt"
      assert form["client_id"] == "client-id"
    end
  end

  # A refresh runs under the profile lock, whose stale threshold is sized from
  # these bounds (Store's "lock bounds" tests). Unset, the connect wait is
  # Mint's 30 s default and three attempts outlast the threshold.
  describe "per-attempt timeouts" do
    defp recording_adapter(parent) do
      fn request ->
        send(parent, {:request_options, request.options})
        body = %{"access_token" => "new_at", "refresh_token" => "new_rt", "expires_in" => 3600}
        {request, Req.Response.new(status: 200, body: body)}
      end
    end

    test "both refresh paths bound pool checkout, connect and receive" do
      assert {:ok, _tokens} = RefreshClient.refresh("old_rt", adapter: recording_adapter(self()))
      assert_received {:request_options, codex}

      assert {:ok, _tokens} =
               RefreshClient.refresh(provider("github"), "old_rt",
                 adapter: recording_adapter(self())
               )

      assert_received {:request_options, plugin}

      for options <- [codex, plugin] do
        assert Map.get(options, :pool_timeout) == 5_000
        assert Map.get(options, :connect_options) == [timeout: 10_000]
        assert Map.get(options, :receive_timeout) == 15_000
      end
    end
  end
end
