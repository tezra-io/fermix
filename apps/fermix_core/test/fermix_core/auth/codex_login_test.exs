defmodule FermixCore.Auth.CodexLoginTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.CodexLogin

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

  test "wraps auth-store persist failures separately from OAuth failures" do
    dir = Path.join(System.tmp_dir!(), "fermix_codex_login_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)

    blocker = Path.join(dir, "not_a_dir")
    File.write!(blocker, "blocking file")
    auth_path = Path.join(blocker, "auth.json")
    port = pick_free_port()

    assert {:error, {:persist_failed, :enotdir}} =
             CodexLogin.login(
               fermix_auth_path: auth_path,
               oauth_port: port,
               oauth_opener: oauth_opener(port),
               oauth_timeout_ms: 5_000,
               oauth_req_options: [plug: &__MODULE__.token_exchange_plug/1],
               puts: fn _ -> :ok end
             )
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
