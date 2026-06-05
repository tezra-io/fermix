defmodule FermixCore.Auth.XAILoginTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.XAILogin

  defp tmp_path do
    dir = Path.join(System.tmp_dir!(), "fermix_xai_login_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, "auth.json")
  end

  defp pick_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp deliver_callback(port, path) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
    :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)
  end

  # A JWT-shaped access token with an exp claim one hour out — xAI token
  # responses omit expires_in (design doc §6.4).
  defp jwt_access_token do
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)

    payload =
      %{"exp" => System.os_time(:second) + 3600, "sub" => "user-1"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "#{header}.#{payload}.sig"
  end

  describe "login/1" do
    test "runs the loopback PKCE flow with Grok params and persists under xai_oauth" do
      port = pick_free_port()
      fermix_path = tmp_path()
      parent = self()
      access_token = jwt_access_token()

      token_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        # xAI re-validates PKCE at the token endpoint (§6.4).
        assert is_binary(params["code_verifier"])
        assert is_binary(params["code_challenge"])
        assert params["code_challenge_method"] == "S256"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => access_token, "refresh_token" => "xai_rt"})
        )
      end

      opener = fn url ->
        send(parent, {:opened, url})

        Task.start(fn ->
          state =
            url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

          deliver_callback(port, "/callback?code=AUTHCODE&state=#{state}")
        end)

        :ok
      end

      assert {:ok, entry} =
               XAILogin.login(
                 provider: OAuthProvider.xai(),
                 # The CLI threads --port through as :port (overrides the
                 # provider's default redirect port).
                 port: port,
                 fermix_path: fermix_path,
                 opener: opener,
                 timeout_ms: 5_000,
                 puts: fn _ -> :ok end,
                 req_options: [plug: token_plug]
               )

      assert entry.auth_mode == "oauth_pkce"
      assert entry.provider == "xai"
      assert entry.tokens.access_token == access_token
      assert entry.tokens.refresh_token == "xai_rt"
      assert entry.status == "ready"
      # No expires_in in the response — expiry derived from the JWT exp claim.
      assert %DateTime{} = entry.expires_at

      assert {:ok, stored} = Store.read("xai_oauth", fermix_path)
      assert stored.provider == "xai"
      assert %DateTime{} = stored.expires_at

      # The authorize URL carries the Grok Build requirements (§6.4).
      assert_received {:opened, url}
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["plan"] == "generic"
      assert is_binary(query["nonce"]) and query["nonce"] != ""
      assert query["scope"] =~ "grok-cli:access"
      assert query["code_challenge_method"] == "S256"
      # state and nonce must be independent values (§5.6 regression class).
      assert is_binary(query["state"]) and query["state"] != ""
      assert query["state"] != query["nonce"]
      assert query["state"] != query["code_challenge"]
    end

    test "refuses a non-HTTPS token endpoint" do
      provider = %{OAuthProvider.xai() | token_url: "http://auth.x.ai/oauth2/token"}

      assert {:error, {:insecure_token_endpoint, _url}} =
               XAILogin.login(provider: provider, fermix_path: tmp_path())
    end

    test "refuses a token endpoint outside x.ai" do
      provider = %{OAuthProvider.xai() | token_url: "https://auth.evil.example/oauth2/token"}

      assert {:error, {:untrusted_token_endpoint, _url}} =
               XAILogin.login(provider: provider, fermix_path: tmp_path())
    end

    test "accepts apex and subdomain x.ai token endpoints" do
      # Apex hosts are valid; the flow then fails on the loopback (no
      # opener delivers a callback within the timeout), not on validation.
      provider = %{
        OAuthProvider.xai(redirect_port: pick_free_port())
        | token_url: "https://x.ai/oauth2/token"
      }

      result =
        XAILogin.login(
          provider: provider,
          fermix_path: tmp_path(),
          opener: fn _url -> :ok end,
          timeout_ms: 50,
          puts: fn _ -> :ok end
        )

      refute match?({:error, {:untrusted_token_endpoint, _}}, result)
      refute match?({:error, {:insecure_token_endpoint, _}}, result)
    end
  end
end
