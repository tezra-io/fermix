defmodule FermixCore.Auth.CodexLoginTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.CodexLogin
  alias FermixCore.Auth.Store
  alias FermixTestSupport.SafeRm

  def token_exchange_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "oauth_at",
        "refresh_token" => "oauth_rt",
        "expires_in" => 3600
      })
    )
  end

  # The profile lock is taken before the exchange, so a store that cannot be
  # written is found only at the write: the auth file here is a directory,
  # while the directory the lockfiles live in is a real one.
  test "wraps auth-store persist failures separately from OAuth failures" do
    dir = SafeRm.make_tmp_dir!("codex-login-persist")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    auth_path = Path.join(dir, "auth.json")
    File.mkdir_p!(auth_path)
    port = pick_free_port()

    assert {:error, {:persist_failed, :eisdir}} =
             CodexLogin.login(
               fermix_auth_path: auth_path,
               oauth_port: port,
               oauth_opener: oauth_opener(port),
               oauth_timeout_ms: 5_000,
               oauth_req_options: [plug: &__MODULE__.token_exchange_plug/1],
               puts: fn _ -> :ok end
             )
  end

  # The exchange spends the authorization code and mints the grant. A profile
  # that stays busy past the lock's wait refuses before that, so the operator
  # signs in again with nothing lost; it used to exchange first and then wait
  # out a stale lock the app's job budget could not outlast.
  test "refuses a busy Codex profile before it exchanges the code" do
    dir = SafeRm.make_tmp_dir!("codex-login-busy")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    auth_path = Path.join(dir, "auth.json")
    File.write!(Store.profile_lock_path(:openai_codex, auth_path), "0 a-refresh\n")
    port = pick_free_port()
    parent = self()

    exchange = fn conn ->
      send(parent, :code_exchanged)
      token_exchange_plug(conn)
    end

    login =
      Task.async(fn ->
        CodexLogin.login(
          fermix_auth_path: auth_path,
          oauth_port: port,
          oauth_opener: oauth_opener(port),
          oauth_timeout_ms: 5_000,
          oauth_req_options: [plug: exchange],
          puts: fn _ -> :ok end
        )
      end)

    assert {:ok, {:error, :profile_busy}} =
             Task.yield(login, 15_000) || Task.shutdown(login, :brutal_kill)

    refute_received :code_exchanged
    refute File.exists?(auth_path)
  end

  test "a free profile exchanges the code once and stores the grant" do
    dir = SafeRm.make_tmp_dir!("codex-login-free")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    auth_path = Path.join(dir, "auth.json")
    port = pick_free_port()
    parent = self()

    exchange = fn conn ->
      send(parent, :code_exchanged)
      token_exchange_plug(conn)
    end

    assert {:ok, entry} =
             CodexLogin.login(
               fermix_auth_path: auth_path,
               oauth_port: port,
               oauth_opener: oauth_opener(port),
               oauth_timeout_ms: 5_000,
               oauth_req_options: [plug: exchange],
               puts: fn _ -> :ok end
             )

    assert entry.tokens.access_token == "oauth_at"
    assert_received :code_exchanged
    refute_received :code_exchanged
    assert {:ok, %{tokens: %{access_token: "oauth_at"}}} = Store.read(:openai_codex, auth_path)
    refute File.exists?(Store.profile_lock_path(:openai_codex, auth_path))
  end

  defp pick_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp oauth_opener(port) do
    fn url ->
      Task.start(fn ->
        state =
          url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end
  end

  defp deliver_callback(port, path) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request = "GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(conn, request)
    {:ok, _resp} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
  end
end
