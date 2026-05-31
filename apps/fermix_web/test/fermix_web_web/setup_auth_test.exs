defmodule FermixWebWeb.SetupAuthTest do
  use FermixWebWeb.ConnCase

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

  test "rotating the persistent setup token invalidates existing setup sessions", %{conn: conn} do
    {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()

    conn = get(conn, ~p"/setup?t=#{launch_token}")
    assert redirected_to(conn) == ~p"/setup"

    assert {:ok, _token} = AccessToken.rotate_setup_token()

    conn = conn |> recycle() |> get(~p"/setup")
    assert response(conn, 403) =~ "setup authorization required"
  end
end
