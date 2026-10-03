defmodule FermixCore.Auth.ChatGPT.CallbackTest do
  # The ChatGPT callback listener (M57 §4.2): one attempt, two inputs (the
  # browser and a pasted address), the hardened request rules, and where the
  # issued client id comes from. Each test binds its own OS-chosen port.
  use ExUnit.Case, async: true

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider

  @host_id "urn:uuid:0b6f3b8e-4d0a-4c5e-9f1e-2a7d3c9b1e44"

  defp provider(client_id, opts \\ []) do
    OAuthProvider.chatgpt(
      Keyword.merge([client_id: client_id, host_id: @host_id, nonce: "nonce-1"], opts)
    )
  end

  # Runs the attempt in this process. `deliver` gets the authorize url's query
  # and the bound port, and runs in its own process (as a browser would).
  defp await(provider, deliver, opts \\ []) do
    opener = fn url ->
      query = query_of(url)
      port = query["redirect_uri"] |> URI.parse() |> Map.fetch!(:port)
      Task.start(fn -> deliver.(query, port) end)
      :ok
    end

    OAuthFlow.await_authorization(
      provider,
      Keyword.merge([opener: opener, puts: fn _line -> :ok end, timeout_ms: 5_000], opts)
    )
  end

  describe "the authorize url" do
    test "a first registration names the entry point, the hint, the host and the resource" do
      parent = self()

      assert {:error, :callback_timeout} =
               OAuthFlow.await_authorization(provider(nil),
                 opener: fn url -> send(parent, {:url, url}) && :ok end,
                 puts: fn _line -> :ok end,
                 timeout_ms: 50
               )

      assert_received {:url, url}
      assert String.starts_with?(url, "https://auth.openai.com/api/accounts/authorize?")
      query = query_of(url)

      assert query["client_id"] == "dynamic_agent_client"
      assert query["agent_name_hint"] == "Fermix"
      assert query["ext_agent_host_id"] == @host_id
      assert query["resource"] == "https://api.openai.com/v1"
      assert query["nonce"] == "nonce-1"
      assert query["response_type"] == "code"
      assert query["code_challenge_method"] == "S256"
      assert byte_size(query["code_challenge"]) == 43
      assert byte_size(query["state"]) > 20

      assert query["scope"] ==
               "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

      assert %URI{scheme: "http", host: "127.0.0.1", path: "/auth/callback", port: port} =
               URI.parse(query["redirect_uri"])

      assert port > 0
      refute Map.has_key?(query, "prompt")
      refute Map.has_key?(query, "id_token_hint")
      refute url =~ "localhost"
    end

    test "a re-authorization names the issued client and no hint" do
      query = authorize_query(provider("oaiapp_A1"))

      assert query["client_id"] == "oaiapp_A1"
      refute Map.has_key?(query, "agent_name_hint")
      refute Map.has_key?(query, "prompt")
      assert query["ext_agent_host_id"] == @host_id
    end

    test "consent is asked for only when the caller says so" do
      assert authorize_query(provider("oaiapp_A1", consent?: true))["prompt"] == "consent"
    end
  end

  describe "the issued client id" do
    test "a first registration returns the client the callback names" do
      deliver = fn query, port ->
        get(
          port,
          "/auth/callback?code=C1&state=#{query["state"]}&client_id=oaiapp_NEW&scope=openid"
        )
      end

      assert {:ok, authorization} = await(provider(nil), deliver)
      assert authorization.code == "C1"
      assert authorization.client_id == "oaiapp_NEW"
      assert authorization.scope == "openid"
      assert authorization.redirect_uri =~ ~r{\Ahttp://127\.0\.0\.1:\d+/auth/callback\z}
      assert is_binary(authorization.code_verifier)
    end

    test "a first registration whose callback names no client is incomplete" do
      deliver = fn query, port -> get(port, "/auth/callback?code=C1&state=#{query["state"]}") end
      assert {:error, :registration_incomplete} = await(provider(nil), deliver)
    end

    test "the registration entry point is not an issued client" do
      deliver = fn query, port ->
        get(port, "/auth/callback?code=C1&state=#{query["state"]}&client_id=dynamic_agent_client")
      end

      assert {:error, :registration_incomplete} = await(provider(nil), deliver)
    end

    test "a re-authorization may leave the client out" do
      deliver = fn query, port -> get(port, "/auth/callback?code=C2&state=#{query["state"]}") end
      assert {:ok, %{client_id: "oaiapp_A1", code: "C2"}} = await(provider("oaiapp_A1"), deliver)
    end

    test "a re-authorization that names another client is refused" do
      deliver = fn query, port ->
        get(port, "/auth/callback?code=C2&state=#{query["state"]}&client_id=oaiapp_OTHER")
      end

      assert {:error, :client_mismatch} = await(provider("oaiapp_A1"), deliver)
    end
  end

  describe "the browser's answer" do
    test "a declined consent ends the attempt without a code" do
      deliver = fn query, port ->
        get(port, "/auth/callback?error=access_denied&state=#{query["state"]}")
      end

      assert {:error, :access_denied} = await(provider(nil), deliver)
    end

    test "another OAuth error is named by its code" do
      deliver = fn query, port ->
        get(port, "/auth/callback?error=server_error&state=#{query["state"]}")
      end

      assert {:error, {:authorization_error, "server_error"}} = await(provider(nil), deliver)
    end

    test "the callback page is never cached and leaks no referrer" do
      parent = self()

      deliver = fn query, port ->
        send(parent, {:response, get(port, "/auth/callback?code=C&state=#{query["state"]}")})
      end

      assert {:ok, _authorization} = await(provider("oaiapp_A1"), deliver)
      assert_receive {:response, response}
      assert response =~ "HTTP/1.1 200 OK"
      assert response =~ "Cache-Control: no-store"
      assert response =~ "Referrer-Policy: no-referrer"
    end
  end

  # A request that is not this attempt's callback is answered and the attempt
  # keeps waiting: the good callback that follows still completes it.
  describe "requests that do not settle the attempt" do
    for {name, status, bad} <- [
          {"a wrong state", 400, {"GET", "/auth/callback?code=X&state=WRONG", "127.0.0.1"}},
          {"a missing state", 400, {"GET", "/auth/callback?code=X", "127.0.0.1"}},
          {"a localhost Host", 400, {"GET", "/auth/callback?code=X&state=:state", "localhost"}},
          {"another path", 404, {"GET", "/callback?code=X&state=:state", "127.0.0.1"}},
          {"a favicon probe", 404, {"GET", "/favicon.ico", "127.0.0.1"}},
          {"a POST", 405, {"POST", "/auth/callback?code=X&state=:state", "127.0.0.1"}}
        ] do
      test "#{name} is answered #{status} and the attempt goes on" do
        parent = self()
        {method, target, hostname} = unquote(Macro.escape(bad))

        deliver = fn query, port ->
          target = String.replace(target, ":state", query["state"])
          send(parent, {:bad, request(port, method, target, "#{hostname}:#{port}")})
          get(port, "/auth/callback?code=GOOD&state=#{query["state"]}")
        end

        assert {:ok, %{code: "GOOD"}} = await(provider("oaiapp_A1"), deliver)
        assert_receive {:bad, response}
        assert response =~ "HTTP/1.1 #{unquote(status)} "
        assert response =~ "Cache-Control: no-store"
      end
    end
  end

  describe "a pasted address" do
    test "completes the same attempt through the same rules" do
      parent = self()

      opener = fn url ->
        query = query_of(url)

        send(
          parent,
          {:chatgpt_callback, "#{query["redirect_uri"]}?code=PASTED&state=#{query["state"]}"}
        )

        :ok
      end

      assert {:ok, %{code: "PASTED", client_id: "oaiapp_A1"}} =
               OAuthFlow.await_authorization(provider("oaiapp_A1"),
                 opener: opener,
                 puts: fn _line -> :ok end,
                 timeout_ms: 5_000,
                 paste_message: :chatgpt_callback
               )
    end

    test "one from another attempt is refused and the wait goes on" do
      parent = self()

      opener = fn url ->
        query = query_of(url)
        send(parent, {:chatgpt_callback, "#{query["redirect_uri"]}?code=OLD&state=STALE"})

        send(
          parent,
          {:chatgpt_callback, "http://127.0.0.1:1/auth/callback?code=X&state=#{query["state"]}"}
        )

        send(
          parent,
          {:chatgpt_callback, "#{query["redirect_uri"]}?code=NEW&state=#{query["state"]}"}
        )

        :ok
      end

      assert {:ok, %{code: "NEW"}} =
               OAuthFlow.await_authorization(provider("oaiapp_A1"),
                 opener: opener,
                 puts: fn line -> send(parent, {:said, line}) end,
                 timeout_ms: 5_000,
                 paste_message: :chatgpt_callback
               )

      assert_received {:said, "That address is not from this sign-in." <> _}
    end

    test "is not read by a flow that did not ask for it" do
      parent = self()

      opener = fn url ->
        query = query_of(url)

        send(
          parent,
          {:chatgpt_callback, "#{query["redirect_uri"]}?code=P&state=#{query["state"]}"}
        )

        :ok
      end

      assert {:error, :callback_timeout} =
               OAuthFlow.await_authorization(provider("oaiapp_A1"),
                 opener: opener,
                 puts: fn _line -> :ok end,
                 timeout_ms: 100
               )

      assert_received {:chatgpt_callback, _url}
    end
  end

  describe "the port" do
    test "a pinned port that is taken fails loud, with no fallback" do
      {:ok, blocker} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(blocker)

      assert {:error, {:port_in_use, ^port}} =
               OAuthFlow.await_authorization(provider(nil, port: port),
                 opener: fn _url -> :ok end,
                 puts: fn _line -> :ok end,
                 timeout_ms: 100
               )

      :gen_tcp.close(blocker)
    end

    test "an opener that fails prints the url and keeps waiting" do
      parent = self()

      opener = fn url ->
        query = query_of(url)

        send(
          parent,
          {:chatgpt_callback, "#{query["redirect_uri"]}?code=C&state=#{query["state"]}"}
        )

        {:error, :no_opener}
      end

      assert {:ok, %{code: "C"}} =
               OAuthFlow.await_authorization(provider("oaiapp_A1"),
                 opener: opener,
                 puts: fn line -> send(parent, {:said, line}) end,
                 timeout_ms: 5_000,
                 paste_message: :chatgpt_callback
               )

      assert_received {:said,
                       "Open this URL in your browser to sign in:\n  https://auth.openai.com/" <>
                         _}
    end
  end

  test "nothing of the attempt is left in the caller's mailbox" do
    deliver = fn query, port -> get(port, "/auth/callback?code=C&state=#{query["state"]}") end
    assert {:ok, _authorization} = await(provider("oaiapp_A1"), deliver)

    refute_received _anything
  end

  defp authorize_query(provider) do
    parent = self()

    {:error, :callback_timeout} =
      OAuthFlow.await_authorization(provider,
        opener: fn url -> send(parent, {:url, url}) && :ok end,
        puts: fn _line -> :ok end,
        timeout_ms: 50
      )

    assert_received {:url, url}
    query_of(url)
  end

  defp query_of(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp get(port, target), do: request(port, "GET", target, "127.0.0.1:#{port}")

  defp request(port, method, target, host) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        conn,
        "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n"
      )

    response = read_all(conn, "")
    :gen_tcp.close(conn)
    response
  end

  defp read_all(conn, acc) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, chunk} -> read_all(conn, acc <> chunk)
      {:error, _closed} -> acc
    end
  end
end
