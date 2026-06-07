defmodule FermixCore.Auth.OAuthFlowTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider

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

  describe "authorize_url/1" do
    test "includes every required Codex/ChatGPT-Plus param" do
      pkce = OAuthFlow.generate_pkce()
      url = OAuthFlow.authorize_url(pkce)

      assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize?")
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["response_type"] == "code"
      assert query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert query["redirect_uri"] == "http://localhost:1455/auth/callback"
      assert query["scope"] == "openid profile email offline_access"
      assert query["code_challenge"] == pkce.code_challenge
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == pkce.state
      assert query["codex_cli_simplified_flow"] == "true"
      assert query["id_token_add_organizations"] == "true"
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

  describe "exchange_code/3" do
    test "POSTs the form body and parses tokens on 200" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["grant_type"] == "authorization_code"
        assert params["code"] == "the-code"
        assert params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
        assert params["redirect_uri"] == "http://localhost:1455/auth/callback"
        assert params["code_verifier"] == "the-verifier"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "AT",
            "refresh_token" => "RT",
            "id_token" => "IT",
            "expires_in" => 3600
          })
        )
      end

      assert {:ok, tokens} = OAuthFlow.exchange_code("the-code", "the-verifier", plug: plug)
      assert tokens.access_token == "AT"
      assert tokens.refresh_token == "RT"
      assert tokens.id_token == "IT"
      assert %DateTime{} = tokens.expires_at
    end

    test "returns error string on non-200" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 400, "bad code") end

      assert {:error, "Token exchange failed (400): " <> _} =
               OAuthFlow.exchange_code("bad", "v", plug: plug)
    end

    test "returns :invalid_token_response when access_token is missing" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"refresh_token" => "RT"}))
      end

      assert {:error, :invalid_token_response} =
               OAuthFlow.exchange_code("c", "v", plug: plug)
    end

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
      provider = OAuthProvider.google(client_id: "cid")

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
  end

  describe "start_loopback/1 (integration)" do
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
               OAuthFlow.start_loopback(
                 port: port,
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
               OAuthFlow.start_loopback(
                 port: port,
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
               OAuthFlow.start_loopback(
                 port: port,
                 opener: opener,
                 timeout_ms: 200,
                 puts: fn _ -> :ok end
               )
    end

    test "surfaces opener failure instead of waiting for callback timeout" do
      port = pick_free_port()

      assert {:error, {:opener_failed, :browser_missing, url}} =
               OAuthFlow.start_loopback(
                 port: port,
                 opener: fn _url -> {:error, :browser_missing} end,
                 timeout_ms: 200,
                 puts: fn _ -> :ok end
               )

      assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize?")
    end

    test "surfaces listen failure when the port is already bound" do
      port = pick_free_port()
      {:ok, blocker} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])

      assert {:error, {:listen_failed, ^port, :eaddrinuse}} =
               OAuthFlow.start_loopback(
                 port: port,
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
               OAuthFlow.start_loopback(
                 port: port,
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
               OAuthFlow.start_loopback(
                 port: port,
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
               OAuthFlow.start_loopback(
                 port: port,
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
               OAuthFlow.start_loopback(
                 port: port,
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end
               )
    end
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
