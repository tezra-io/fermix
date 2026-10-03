defmodule FermixCore.Auth.OAuthFlowTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction

  describe "generate_pkce/0" do
    test "produces verifier, challenge, and state" do
      pkce = OAuthFlow.generate_pkce()
      assert byte_size(pkce.code_verifier) >= 43
      assert byte_size(pkce.code_challenge) >= 43
      assert byte_size(pkce.state) >= 32
      assert pkce.code_challenge != pkce.code_verifier
    end

    test "challenge is SHA-256 of verifier (base64url, no padding)" do
      pkce = OAuthFlow.generate_pkce()

      expected =
        :crypto.hash(:sha256, pkce.code_verifier)
        |> Base.url_encode64(padding: false)

      assert pkce.code_challenge == expected
    end

    test "two calls produce different values" do
      a = OAuthFlow.generate_pkce()
      b = OAuthFlow.generate_pkce()
      assert a.code_verifier != b.code_verifier
      assert a.state != b.state
    end
  end

  describe "parse_callback_path/2" do
    test "extracts code when state matches" do
      assert {:ok, "abc"} =
               OAuthFlow.parse_callback_path("/auth/callback?code=abc&state=xyz", "xyz")
    end

    test "rejects state mismatch" do
      assert {:error, :state_mismatch} =
               OAuthFlow.parse_callback_path("/auth/callback?code=abc&state=other", "xyz")
    end

    test "surfaces OAuth error param" do
      assert {:error, "OAuth error: access_denied (user cancelled)"} =
               OAuthFlow.parse_callback_path(
                 "/auth/callback?error=access_denied&error_description=user+cancelled",
                 "xyz"
               )
    end

    test "missing code returns :missing_code" do
      assert {:error, :missing_code} =
               OAuthFlow.parse_callback_path("/auth/callback?state=xyz", "xyz")
    end

    test "no query string returns :missing_code" do
      assert {:error, :missing_code} = OAuthFlow.parse_callback_path("/auth/callback", "xyz")
    end
  end

  describe "exchange_code/5" do
    test "echoes the code challenge for providers that re-validate PKCE at exchange" do
      provider = OAuthProvider.xai()

      expected_challenge =
        :sha256 |> :crypto.hash("the-verifier") |> Base.url_encode64(padding: false)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["code_verifier"] == "the-verifier"
        assert params["code_challenge"] == expected_challenge
        assert params["code_challenge_method"] == "S256"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "AT", "expires_in" => 60})
        )
      end

      assert {:ok, _tokens} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 "http://127.0.0.1:56121/callback",
                 plug: plug
               )
    end

    test "providers without the echo flag never send the challenge at exchange" do
      {:ok, provider} =
        OAuthProviders.definition("google", client_id: "cid", client_secret: "sec")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        refute Map.has_key?(params, "code_challenge")
        refute Map.has_key?(params, "code_challenge_method")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "AT", "expires_in" => 60})
        )
      end

      assert {:ok, _tokens} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 "http://127.0.0.1:1455/auth/callback",
                 plug: plug
               )
    end

    test "GitHub exchange sends the accept-json header with body credentials" do
      {:ok, provider} =
        OAuthProviders.definition("github",
          client_id: "gh-id",
          client_secret: "gh-sec",
          scopes: ["read:user", "repo"]
        )

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
        assert params["client_id"] == "gh-id"
        assert params["client_secret"] == "gh-sec"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "gh_at", "scope" => "repo,read:user"})
        )
      end

      assert {:ok, tokens} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 "http://127.0.0.1:1457/auth/callback",
                 plug: plug
               )

      assert tokens.access_token == "gh_at"
      assert tokens.scope == "repo,read:user"
    end

    test "Notion exchange authenticates with HTTP Basic, never body credentials" do
      {:ok, provider} =
        OAuthProviders.definition("notion",
          client_id: "n-id",
          client_secret: "n-sec",
          scopes: []
        )

      expected = "Basic " <> Base.encode64("n-id:n-sec")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert Plug.Conn.get_req_header(conn, "authorization") == [expected]
        refute Map.has_key?(params, "client_secret")
        refute Map.has_key?(params, "client_id")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "n_at", "refresh_token" => "n_rt"})
        )
      end

      assert {:ok, tokens} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 "http://127.0.0.1:1458/auth/callback",
                 plug: plug
               )

      assert tokens.access_token == "n_at"
      assert tokens.refresh_token == "n_rt"
    end
  end

  # `extra_token_params` exists because Tesla's code exchange is refused without
  # an `audience` naming the region's Fleet API base URL, while its refresh must
  # not carry one. These prove the exchange half; refresh_client_test proves the
  # refresh half never sees it.
  describe "exchange_code/5 — provider extra_token_params" do
    defp tesla_provider(extra) do
      {:ok, provider} =
        OAuthProviders.definition(
          "tesla",
          extra ++ [client_id: "t-id", client_secret: "t-sec", scopes: ["openid"], region: "na"]
        )

      provider
    end

    defp form_capturing_plug do
      parent = self()

      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:token_form, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "t_at"}))
      end
    end

    test "the Tesla exchange form carries the region's audience" do
      provider = tesla_provider(region: "eu")

      assert {:ok, %{access_token: "t_at"}} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 provider.public_redirect_uri,
                 plug: form_capturing_plug()
               )

      assert_received {:token_form, form}
      assert form["audience"] == "https://fleet-api.prd.eu.vn.cloud.tesla.com"
      assert form["grant_type"] == "authorization_code"
      assert form["client_id"] == "t-id"
      assert form["client_secret"] == "t-sec"
      assert form["redirect_uri"] == "https://fermix.ai/api/integrations/tesla/callback"
    end

    test "a provider without extra token params sends no audience" do
      {:ok, provider} =
        OAuthProviders.definition("github", client_id: "gh-id", client_secret: "gh-sec")

      assert {:ok, _tokens} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 "http://127.0.0.1:1457/auth/callback",
                 plug: form_capturing_plug()
               )

      assert_received {:token_form, form}
      refute Map.has_key?(form, "audience")
    end

    # A provider field must never be able to rewrite the exchange's own fields:
    # the fixed ones win, so a bad manifest or config cannot redirect the code.
    test "extra token params can never override the exchange's fixed fields" do
      %OAuthProvider{} = base = tesla_provider([])

      provider = %{
        base
        | extra_token_params: %{
            "audience" => "https://fleet-api.prd.na.vn.cloud.tesla.com",
            "grant_type" => "client_credentials",
            "code" => "spoofed",
            "redirect_uri" => "https://attacker.test/callback",
            "code_verifier" => "spoofed",
            "client_id" => "spoofed"
          }
      }

      assert {:ok, _tokens} =
               OAuthFlow.exchange_code(
                 provider,
                 "the-code",
                 "the-verifier",
                 provider.public_redirect_uri,
                 plug: form_capturing_plug()
               )

      assert_received {:token_form, form}
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "the-code"
      assert form["code_verifier"] == "the-verifier"
      assert form["redirect_uri"] == "https://fermix.ai/api/integrations/tesla/callback"
      assert form["client_id"] == "t-id"
      assert form["audience"] == "https://fleet-api.prd.na.vn.cloud.tesla.com"
    end
  end

  # The provider refusing the operator's saved client is its own diagnosis: the
  # vendor body used to come back as a raw string whose "Token" the redactor
  # turned into "[REDACTED]", so no surface could say what to fix.
  describe "exchange_code/5 — a refused client" do
    @x_redirect "http://127.0.0.1:1459/auth/callback"

    defp x_provider do
      {:ok, provider} =
        OAuthProviders.definition("x",
          client_id: "x-id",
          client_secret: "stale-secret",
          scopes: ["tweet.read"]
        )

      provider
    end

    defp json_plug(status, body) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    end

    test "X answering 401 unauthorized_client is the typed refusal" do
      plug =
        json_plug(401, %{
          "error" => "unauthorized_client",
          "error_description" => "Missing valid authorization header"
        })

      assert {:error, {:oauth_client_rejected, detail}} =
               OAuthFlow.exchange_code(x_provider(), "the-code", "the-verifier", @x_redirect,
                 plug: plug
               )

      assert detail.provider == "x"
      assert detail.status == 401
      assert detail.error == "unauthorized_client"
      assert detail.description == "Missing valid authorization header"
    end

    test "GitHub answering 200 incorrect_client_credentials is the typed refusal" do
      {:ok, provider} =
        OAuthProviders.definition("github", client_id: "gh-id", client_secret: "gh-sec")

      plug = json_plug(200, %{"error" => "incorrect_client_credentials"})

      assert {:error, {:oauth_client_rejected, %{provider: "github", status: 200}}} =
               OAuthFlow.exchange_code(provider, "c", "v", "http://127.0.0.1:1457/auth/callback",
                 plug: plug
               )
    end

    test "any other refusal keeps the vendor string, byte for byte" do
      body = %{"error" => "invalid_grant"}

      assert {:error, "Token exchange failed (400): " <> rest} =
               OAuthFlow.exchange_code(x_provider(), "c", "v", @x_redirect,
                 plug: json_plug(400, body)
               )

      assert rest == Redaction.format(body)
    end

    test "a 200 without tokens that is no refusal stays an invalid token response" do
      {:ok, provider} =
        OAuthProviders.definition("github", client_id: "gh-id", client_secret: "gh-sec")

      assert {:error, :invalid_token_response} =
               OAuthFlow.exchange_code(provider, "c", "v", "http://127.0.0.1:1457/auth/callback",
                 plug: json_plug(200, %{"error" => "bad_verification_code"})
               )
    end
  end

  # A client whose id is its own and whose listener is not hardened (xAI, the
  # plugins' providers): the callback is read from the request line alone.
  describe "start_loopback/2 — a static client (integration)" do
    test "completes the full handshake when a synthetic callback is delivered" do
      port = pick_free_port()
      parent = self()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "loopback_AT",
            "refresh_token" => "loopback_RT",
            "expires_in" => 3600
          })
        )
      end

      # Capture the URL the opener would have launched, then deliver the
      # callback ourselves on the same port the listener is bound to.
      opener = fn url ->
        send(parent, {:opened, url})

        Task.start(fn ->
          state =
            url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

          deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
        end)

        :ok
      end

      assert {:ok, tokens} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: plug]
               )

      assert tokens.access_token == "loopback_AT"
      assert tokens.refresh_token == "loopback_RT"
      assert_received {:opened, _url}
    end

    test "skips browser preflight requests and continues waiting" do
      port = pick_free_port()
      parent = self()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "AT", "expires_in" => 3600})
        )
      end

      opener = fn url ->
        send(parent, {:opened, url})

        Task.start(fn ->
          state =
            url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

          # Browser hits /favicon.ico first — must be ignored.
          deliver_callback(port, "/favicon.ico")
          Process.sleep(50)
          deliver_callback(port, "/auth/callback?code=C&state=#{state}")
        end)

        :ok
      end

      assert {:ok, %{access_token: "AT"}} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: plug]
               )
    end

    test "times out when no callback arrives" do
      port = pick_free_port()
      opener = fn _url -> :ok end

      assert {:error, :callback_timeout} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 200,
                 puts: fn _ -> :ok end
               )
    end

    test "an opener that fails prints the address, and the wait goes on" do
      port = pick_free_port()
      parent = self()

      assert {:error, :callback_timeout} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: fn _url -> {:error, :browser_missing} end,
                 timeout_ms: 200,
                 puts: fn line -> send(parent, {:printed, line}) end
               )

      assert_received {:printed,
                       "Open this URL in your browser to sign in:\n  " <>
                         "https://auth.example.test/authorize?" <> _query}
    end

    # A client registered with its exact redirect URI cannot move to another
    # port, so a taken one fails loud instead of falling back.
    test "surfaces a taken fixed port instead of waiting" do
      port = pick_free_port()
      {:ok, blocker} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])

      assert {:error, {:port_in_use, ^port}} =
               OAuthFlow.start_loopback(%{static_provider(port) | fixed_port?: true},
                 opener: fn _ -> :ok end,
                 timeout_ms: 200,
                 puts: fn _ -> :ok end
               )

      :gen_tcp.close(blocker)
    end

    test "recovers from an empty connection (connect-then-close) before the real callback" do
      port = pick_free_port()
      parent = self()

      opener = fn url ->
        Task.start(fn ->
          state = state_from(url)
          # A browser/OS preconnect probe opens and closes without sending.
          deliver_empty(port)
          Process.sleep(50)
          deliver_callback(port, "/auth/callback?code=C&state=#{state}")
        end)

        send(parent, {:opened, url})
        :ok
      end

      assert {:ok, %{access_token: "AT"}} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: access_token_plug("AT")]
               )
    end

    test "recovers from a junk (non-HTTP) connection before the real callback" do
      port = pick_free_port()
      parent = self()

      opener = fn url ->
        Task.start(fn ->
          state = state_from(url)
          # Non-HTTP bytes (TLS ClientHello-shaped); no parseable request line.
          deliver_junk(port, <<22, 3, 1, 0, 5, 1, 0, 0, 1, 0>>)
          Process.sleep(50)
          deliver_callback(port, "/auth/callback?code=C&state=#{state}")
        end)

        send(parent, {:opened, url})
        :ok
      end

      assert {:ok, %{access_token: "AT"}} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: access_token_plug("AT")]
               )
    end

    test "accumulates a request line split across reads (full code, not truncated)" do
      port = pick_free_port()
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:exchanged_code, Map.get(URI.decode_query(body), "code")})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "AT", "expires_in" => 3600})
        )
      end

      code = "LONG-AUTH-CODE-0123456789-abcdefghij"

      opener = fn url ->
        Task.start(fn ->
          state = state_from(url)
          deliver_fragmented(port, "/auth/callback?code=#{code}&state=#{state}")
        end)

        send(parent, {:opened, url})
        :ok
      end

      assert {:ok, %{access_token: "AT"}} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: plug]
               )

      assert_received {:exchanged_code, ^code}
    end

    test "a state mismatch on the real callback still fails fast (does not retry to timeout)" do
      port = pick_free_port()
      parent = self()

      opener = fn url ->
        Task.start(fn -> deliver_callback(port, "/auth/callback?code=C&state=WRONG") end)
        send(parent, {:opened, url})
        :ok
      end

      # timeout_ms is generous; a genuine callback-validation error must return
      # immediately rather than being retried until the deadline.
      assert {:error, :state_mismatch} =
               OAuthFlow.start_loopback(static_provider(port),
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end
               )
    end
  end

  # Tesla registers a public https redirect URI and accepts no loopback one, so
  # a static bounce page forwards the callback query string to this listener.
  # The authorize request and the code exchange must both name the public URI
  # while the listener still binds 127.0.0.1 on the provider's fixed port.
  describe "start_loopback/2 — a provider with a public redirect URI" do
    test "authorizes with the public URI, binds the loopback port, and completes on a bounce" do
      port = pick_free_port()
      parent = self()

      {:ok, provider} =
        OAuthProviders.definition("tesla",
          client_id: "t-id",
          client_secret: "t-sec",
          scopes: ["openid", "offline_access"],
          region: "na",
          redirect_port: port
        )

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:token_form, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "tesla_at",
            "refresh_token" => "tesla_rt",
            "expires_in" => 28_800
          })
        )
      end

      opener = fn url ->
        send(parent, {:opened, url})

        Task.start(fn ->
          # The bounce page forwards the query string it was handed, so the
          # daemon sees an ordinary loopback callback on its own port.
          deliver_callback(port, "/auth/callback?code=TESLACODE&state=#{state_from(url)}")
        end)

        :ok
      end

      assert {:ok, tokens} =
               OAuthFlow.start_loopback(provider,
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: plug]
               )

      assert tokens.access_token == "tesla_at"
      assert tokens.refresh_token == "tesla_rt"
      assert tokens.userinfo == nil

      assert_received {:opened, url}
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert String.starts_with?(url, "https://auth.tesla.com/oauth2/v3/authorize?")
      assert query["redirect_uri"] == "https://fermix.ai/api/integrations/tesla/callback"
      assert query["scope"] == "openid offline_access"
      assert query["code_challenge_method"] == "S256"

      assert_received {:token_form, form}
      assert form["code"] == "TESLACODE"
      assert form["redirect_uri"] == "https://fermix.ai/api/integrations/tesla/callback"
      assert form["audience"] == "https://fleet-api.prd.na.vn.cloud.tesla.com"
    end

    # The public redirect URI replaces only the URI that is sent; the listener
    # is still local, which is what a wrongly bound listener would break.
    test "the loopback listener is bound on 127.0.0.1, not on the public host" do
      port = pick_free_port()
      parent = self()

      {:ok, provider} =
        OAuthProviders.definition("tesla",
          client_id: "t-id",
          client_secret: "t-sec",
          scopes: ["openid"],
          region: "na",
          redirect_port: port
        )

      opener = fn _url ->
        Task.start(fn ->
          result = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
          send(parent, {:connected, result})
        end)

        :ok
      end

      assert {:error, :callback_timeout} =
               OAuthFlow.start_loopback(provider,
                 opener: opener,
                 timeout_ms: 400,
                 puts: fn _ -> :ok end
               )

      assert_receive {:connected, {:ok, socket}}, 1_000
      :gen_tcp.close(socket)
    end
  end

  defp static_provider(port) do
    %OAuthProvider{
      id: :test_static,
      authorize_url: "https://auth.example.test/authorize",
      token_url: "https://auth.example.test/token",
      client_id: "test-client",
      redirect_host: "127.0.0.1",
      redirect_port: port,
      redirect_path: "/auth/callback",
      scopes: ["openid"]
    }
  end

  defp pick_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp deliver_callback(port, path) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request = "GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(conn, request)
    {:ok, _resp} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
  end

  # Connect and close without sending — a browser/OS preconnect probe.
  defp deliver_empty(port) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.close(conn)
  end

  # Connect, send non-HTTP bytes, close — a port probe / TLS handshake.
  defp deliver_junk(port, bytes) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(conn, bytes)
    :gen_tcp.close(conn)
  end

  # Send the request line split mid-path across two writes, so the server's
  # first read sees a truncated line with no terminator.
  defp deliver_fragmented(port, path) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    {first, second} = String.split_at(path, div(String.length(path), 2))
    :ok = :gen_tcp.send(conn, "GET #{first}")
    Process.sleep(100)

    :ok =
      :gen_tcp.send(
        conn,
        "#{second} HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"
      )

    {:ok, _resp} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
  end

  defp state_from(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  defp access_token_plug(token) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => token, "expires_in" => 3600}))
    end
  end
end
