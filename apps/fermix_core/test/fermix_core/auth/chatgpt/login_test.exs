defmodule FermixCore.Auth.ChatGPT.LoginTest do
  # The whole sign-in through `Auth.ChatGPT.login/1`, against a fake OpenAI
  # answered by one Req plug (token endpoint and JWKS) and a callback handed in
  # as the browser or a pasted address would. Sync: a successful sign-in stops
  # the shared TokenSupervisor's `chatgpt` manager, and one test shortens the
  # VM-wide profile-lock wait.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.ChatGPT.HostId
  alias FermixCore.Auth.ChatGPT.Registration
  alias FermixCore.Auth.Store
  alias FermixTestSupport.SafeRm

  @full_scope "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke"
  @no_plan_scope "email offline_access openid profile resource.invoke"

  setup_all do
    %{key: :public_key.generate_key({:rsa, 2048, 65_537})}
  end

  setup %{key: key} do
    home = SafeRm.make_tmp_dir!("chatgpt-login")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    {:ok, nonces} = Agent.start_link(fn -> nil end)
    %{auth_path: Path.join(home, "auth.json"), key: key, nonces: nonces}
  end

  describe "a first sign-in" do
    test "registers, verifies and stores the registration", ctx do
      test = self()

      callback = fn query ->
        send(test, {:host_file?, File.exists?(HostId.path(ctx.auth_path))})
        "code=CODE-SECRET-1&state=#{query["state"]}&client_id=oaiapp_NEW&scope=openid"
      end

      assert {:ok, %{account: "ada@example.test", plan_usage: :on}} = login(ctx, callback)

      assert_received {:host_file?, true}
      assert_received {:authorize, authorize}
      assert authorize["client_id"] == "dynamic_agent_client"
      assert authorize["agent_name_hint"] == "Fermix"
      assert {:ok, authorize["ext_agent_host_id"]} == HostId.fetch_or_create(ctx.auth_path)

      assert_received {:token_form, form}
      assert form["grant_type"] == "authorization_code"
      assert form["client_id"] == "oaiapp_NEW"
      assert form["code"] == "CODE-SECRET-1"
      assert form["redirect_uri"] == authorize["redirect_uri"]
      assert form["resource"] == "https://api.openai.com/v1"
      assert byte_size(form["code_verifier"]) >= 43
      refute Map.has_key?(form, "client_secret")

      assert {:ok, entry} = Store.read("chatgpt", ctx.auth_path)
      assert entry.provider == "chatgpt"
      assert entry.client_id == "oaiapp_NEW"
      assert entry.subject == "user-sub-1"
      assert Store.account_label(entry) == "ada@example.test"
      assert entry.tokens == %{access_token: "AT-1", refresh_token: "RT-1"}
      assert entry.status == "ready"
      assert "chatgpt.tokens.use.direct" in entry.granted_scopes
      assert %DateTime{} = entry.earliest_refresh_at

      assert ChatGPT.summary(fermix_path: ctx.auth_path) == %{
               state: :connected,
               account: "ada@example.test"
             }
    end

    test "with plan usage declined signs in with plan usage off, and asks consent next time",
         ctx do
      callback = fn query -> "code=C&state=#{query["state"]}&client_id=oaiapp_NEW" end

      assert {:ok, %{plan_usage: :off}} = login(ctx, callback, scope: @no_plan_scope)
      assert ChatGPT.route_status(fermix_path: ctx.auth_path) == {:error, :plan_usage_off}

      assert {:ok, %{plan_usage: :on}} =
               login(ctx, fn query -> "code=C2&state=#{query["state"]}" end)

      assert_received {:authorize, _first}
      assert_received {:authorize, second}
      assert second["client_id"] == "oaiapp_NEW"
      assert second["prompt"] == "consent"
      refute Map.has_key?(second, "agent_name_hint")
    end

    test "cancelled in the browser stores nothing and spends nothing", ctx do
      {result, log} =
        with_log(fn ->
          login(ctx, fn query -> "error=access_denied&state=#{query["state"]}" end)
        end)

      assert result == {:error, :access_denied}
      refute_received {:token_form, _form}
      assert {:ok, nil} = Registration.read(ctx.auth_path)
      assert log =~ "ChatGPT sign-in failed: access_denied"
    end
  end

  describe "the issued client" do
    test "is kept when the exchange fails, and the next attempt reuses it", ctx do
      callback = fn query -> "code=CODE-SECRET-2&state=#{query["state"]}&client_id=oaiapp_NEW" end
      refused = fn _form -> {400, %{"error" => "invalid_grant"}} end

      {result, log} = with_log(fn -> login(ctx, callback, exchange: refused) end)

      assert {:error, {:token_exchange_failed, _detail}} = result
      assert {:ok, pending} = Registration.read(ctx.auth_path)
      assert pending.client_id == "oaiapp_NEW"
      assert pending.status == "pending"

      assert {:error, {:invalid_auth_entry, "chatgpt", :missing_access_token}} =
               Store.read("chatgpt", ctx.auth_path)

      assert ChatGPT.summary(fermix_path: ctx.auth_path).state == :not_connected
      assert log =~ "token_exchange_failed"
      refute log =~ "CODE-SECRET-2"
      refute log =~ "api/accounts/authorize"

      assert {:ok, %{plan_usage: :on}} =
               login(ctx, fn query -> "code=C3&state=#{query["state"]}" end)

      assert_received {:authorize, _first}
      assert_received {:authorize, retry}
      assert retry["client_id"] == "oaiapp_NEW"
      refute Map.has_key?(retry, "agent_name_hint")
      refute Map.has_key?(retry, "prompt")

      assert {:ok, %{client_id: "oaiapp_NEW", status: "ready"}} =
               Store.read("chatgpt", ctx.auth_path)
    end

    test "is kept when the account cannot be verified", ctx do
      callback = fn query -> "code=C&state=#{query["state"]}&client_id=oaiapp_NEW" end

      {result, _log} = with_log(fn -> login(ctx, callback, jwks: :down) end)

      assert result == {:error, :identity_verification_unavailable}

      assert {:ok, %{client_id: "oaiapp_NEW", status: "pending"}} =
               Registration.read(ctx.auth_path)
    end
  end

  describe "a re-authorization" do
    setup ctx do
      :ok = Store.write("chatgpt", ready_entry(), ctx.auth_path)
      :ok
    end

    test "that returns another account replaces nothing", ctx do
      callback = fn query -> "code=C&state=#{query["state"]}" end

      {result, _log} = with_log(fn -> login(ctx, callback, sub: "user-sub-OTHER") end)

      assert result == {:error, :account_mismatch}
      assert {:ok, entry} = Store.read("chatgpt", ctx.auth_path)
      assert entry.tokens == %{access_token: "AT-0", refresh_token: "RT-0"}
      assert entry.subject == "user-sub-1"
    end

    test "that names another client replaces nothing", ctx do
      callback = fn query -> "code=C&state=#{query["state"]}&client_id=oaiapp_OTHER" end

      {result, _log} = with_log(fn -> login(ctx, callback) end)

      assert result == {:error, :client_mismatch}
      refute_received {:token_form, _form}

      assert {:ok, %{client_id: "oaiapp_A1", tokens: %{access_token: "AT-0"}}} =
               Store.read("chatgpt", ctx.auth_path)
    end

    test "of the same account renews the token set under the same client", ctx do
      assert {:ok, %{plan_usage: :on}} =
               login(ctx, fn query -> "code=C&state=#{query["state"]}" end)

      assert_received {:authorize, authorize}
      assert authorize["client_id"] == "oaiapp_A1"
      refute Map.has_key?(authorize, "prompt")
      assert_received {:token_form, %{"client_id" => "oaiapp_A1"}}
      assert {:ok, %{tokens: %{access_token: "AT-1"}}} = Store.read("chatgpt", ctx.auth_path)
    end

    test "while another process holds the profile refuses with the code unspent", ctx do
      FermixTestSupport.ProfileLockWait.shorten!(ctx)
      test = self()

      holder =
        spawn(fn ->
          Store.with_profile_lock("chatgpt", ctx.auth_path, fn ->
            send(test, :holding)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :holding

      {result, _log} =
        with_log(fn -> login(ctx, fn query -> "code=C&state=#{query["state"]}" end) end)

      send(holder, :release)

      assert result == {:error, :profile_busy}
      refute_received {:token_form, _form}
      assert ChatGPT.failure_sentence(:profile_busy) == Store.busy_sentence()
    end
  end

  describe "the callback's two routes" do
    test "an address pasted from another process completes the sign-in", ctx do
      test = self()

      opener = fn url ->
        query = query_of(url)
        Agent.update(ctx.nonces, fn _nonce -> query["nonce"] end)
        send(test, {:opened, self(), query})
        :ok
      end

      task =
        Task.async(fn ->
          ChatGPT.login(
            fermix_path: ctx.auth_path,
            opener: opener,
            puts: fn _line -> :ok end,
            timeout_ms: 5_000,
            req_options: [plug: openai(ctx, [])]
          )
        end)

      assert_receive {:opened, pid, query}
      address = "#{query["redirect_uri"]}?code=C&state=#{query["state"]}&client_id=oaiapp_NEW"
      assert :ok = ChatGPT.paste_callback(pid, address)

      assert {:ok, %{plan_usage: :on}} = Task.await(task)
    end

    test "the browser's request to the listener completes the sign-in", ctx do
      opener = fn url ->
        query = query_of(url)
        Agent.update(ctx.nonces, fn _nonce -> query["nonce"] end)
        port = query["redirect_uri"] |> URI.parse() |> Map.fetch!(:port)
        target = "/auth/callback?code=C&state=#{query["state"]}&client_id=oaiapp_NEW"
        Task.start(fn -> browser_get(port, target) end)
        :ok
      end

      assert {:ok, %{plan_usage: :on}} =
               ChatGPT.login(
                 fermix_path: ctx.auth_path,
                 opener: opener,
                 puts: fn _line -> :ok end,
                 timeout_ms: 5_000,
                 req_options: [plug: openai(ctx, [])]
               )
    end

    test "a pinned port that is taken fails loud", ctx do
      {:ok, blocker} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(blocker)

      {result, _log} =
        with_log(fn ->
          ChatGPT.login(
            fermix_path: ctx.auth_path,
            opener: nil,
            puts: fn _ -> :ok end,
            port: port
          )
        end)

      :gen_tcp.close(blocker)
      assert result == {:error, {:port_in_use, port}}

      assert ChatGPT.failure_sentence(result |> elem(1)) =~
               "Port #{port} on 127.0.0.1 is already in use"
    end
  end

  # The attempt runs in this process; the opener captures the authorize url,
  # hands the attempt's nonce to the fake token endpoint, and pastes the
  # callback this process will read.
  defp login(ctx, callback, fake \\ []) do
    test = self()

    opener = fn url ->
      query = query_of(url)
      Agent.update(ctx.nonces, fn _nonce -> query["nonce"] end)
      send(test, {:authorize, query})
      send(self(), {:chatgpt_callback, "#{query["redirect_uri"]}?#{callback.(query)}"})
      :ok
    end

    ChatGPT.login(
      fermix_path: ctx.auth_path,
      opener: opener,
      puts: fn _line -> :ok end,
      timeout_ms: 5_000,
      req_options: [plug: openai(ctx, fake)]
    )
  end

  defp openai(ctx, fake) do
    test = self()

    fn conn ->
      case conn.request_path do
        "/.well-known/jwks.json" -> jwks_answer(conn, ctx.key, Keyword.get(fake, :jwks, :up))
        "/api/accounts/oauth/token" -> token_answer(conn, ctx, fake, test)
      end
    end
  end

  defp jwks_answer(conn, _key, :down), do: Plug.Conn.send_resp(conn, 503, "down")
  defp jwks_answer(conn, key, :up), do: Req.Test.json(conn, jwks(key))

  defp token_answer(conn, ctx, fake, test) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    form = URI.decode_query(body)
    send(test, {:token_form, form})
    nonce = Agent.get(ctx.nonces, & &1)

    exchange =
      Keyword.get(fake, :exchange, fn form -> {200, tokens(form, nonce, ctx.key, fake)} end)

    {status, answer} = exchange.(form)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(answer))
  end

  defp tokens(form, nonce, key, fake) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://auth.openai.com",
      "aud" => form["client_id"],
      "sub" => Keyword.get(fake, :sub, "user-sub-1"),
      "email" => "ada@example.test",
      "iat" => now,
      "exp" => now + 3_600,
      "nonce" => nonce
    }

    %{
      "access_token" => "AT-1",
      "refresh_token" => "RT-1",
      "id_token" => sign(claims, key),
      "token_type" => "Bearer",
      "expires_in" => 3_600,
      "scope" => Keyword.get(fake, :scope, @full_scope),
      "earliest_refresh_at" => now + 1_800
    }
  end

  defp ready_entry do
    %{
      auth_mode: "oauth_siwc",
      provider: "chatgpt",
      client_id: "oaiapp_A1",
      subject: "user-sub-1",
      account: %{email: "ada@example.test"},
      granted_scopes: String.split(@full_scope),
      tokens: %{access_token: "AT-0", refresh_token: "RT-0"},
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      last_refresh: nil,
      status: "ready"
    }
  end

  defp jwks(key) do
    %{
      "keys" => [
        %{
          "kty" => "RSA",
          "kid" => "kid-1",
          "use" => "sig",
          "n" => b64(:binary.encode_unsigned(elem(key, 2))),
          "e" => b64(:binary.encode_unsigned(elem(key, 3)))
        }
      ]
    }
  end

  defp sign(claims, key) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => "kid-1"}
    signed = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    signed <> "." <> b64(:public_key.sign(signed, :sha256, key))
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp query_of(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp browser_get(port, target) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        conn,
        "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
      )

    {:ok, _response} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
  end
end
