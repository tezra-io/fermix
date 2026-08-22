defmodule FermixWebWeb.SetupAuthTest do
  use FermixWebWeb.ConnCase

  alias FermixCore.Management.Router
  alias FermixCore.Setup.AccessToken

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-auth")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    :ok
  end

  test "rejects setup without an authorized session or launch token", %{conn: conn} do
    conn = get(conn, ~p"/setup")
    assert response(conn, 403) =~ "setup authorization required"
  end

  test "launch token mints a setup session and is consumed", %{conn: conn} do
    {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()

    conn = get(conn, ~p"/setup?t=#{launch_token}")
    assert redirected_to(conn) == ~p"/setup"

    conn = conn |> recycle() |> get(~p"/setup")
    assert html_response(conn, 200) =~ "Fermix setup"

    reused = build_conn() |> get(~p"/setup?t=#{launch_token}")
    assert response(reused, 403) =~ "setup authorization required"
  end

  test "management setup session reaches authorized Setup and remains one use", %{conn: conn} do
    request = %{
      request_id: "req-setup-auth",
      protocol_version: 1,
      method: "setup.session.create",
      params: %{}
    }

    assert {:ok, %{"url" => url, "expires_at_ms" => expires_at_ms}} =
             Router.route(request, endpoint_opts: [port: 4030])

    assert is_integer(expires_at_ms)
    uri = URI.parse(url)
    assert uri.scheme == "http"
    assert uri.host == "127.0.0.1"
    assert uri.port == 4030
    assert uri.path == "/setup"
    assert is_binary(uri.query)

    tokenized_path = uri.path <> "?" <> uri.query
    conn = get(conn, tokenized_path)
    assert redirected_to(conn) == ~p"/setup"

    conn = conn |> recycle() |> get(~p"/setup")
    assert html_response(conn, 200) =~ "Fermix setup"

    reused = build_conn() |> get(tokenized_path)
    assert response(reused, 403) =~ "setup authorization required"
  end

  test "rotating the persistent setup token invalidates existing setup sessions", %{conn: conn} do
    {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()

    conn = get(conn, ~p"/setup?t=#{launch_token}")
    assert redirected_to(conn) == ~p"/setup"

    assert {:ok, _token} = AccessToken.rotate_setup_token()

    conn = conn |> recycle() |> get(~p"/setup")
    assert response(conn, 403) =~ "setup authorization required"
  end
end
