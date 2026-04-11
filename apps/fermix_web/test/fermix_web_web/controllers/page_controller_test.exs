defmodule FermixWebWeb.PageControllerTest do
  use FermixWebWeb.ConnCase

  alias FermixCore.Setup.BootReport

  setup do
    provider_config = Application.get_env(:fermix_core, :providers)
    telegram_config = Application.get_env(:fermix_channels, :telegram)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, provider_config)
      restore_env(:fermix_channels, :telegram, telegram_config)
      BootReport.refresh()
    end)

    :ok
  end

  test "GET / redirects to /setup when readiness is incomplete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    BootReport.refresh()

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / renders home when readiness is complete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    BootReport.refresh()

    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "GET /setup renders actionable setup guidance when readiness is incomplete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    BootReport.refresh()

    conn = get(conn, ~p"/setup")
    body = html_response(conn, 200)

    assert body =~ "Setup required"
    assert body =~ "mix fermix.setup"
    assert body =~ "provider:openai"
  end

  test "GET /setup renders ready state when readiness is complete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    BootReport.refresh()

    conn = get(conn, ~p"/setup")
    body = html_response(conn, 200)

    assert body =~ "Fermix is ready"
    assert body =~ "configured"
  end

  test "web setup routes use cached readiness until BootReport refreshes", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    BootReport.refresh()

    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")

    home_conn = get(conn, ~p"/")
    assert redirected_to(home_conn) == ~p"/setup"

    setup_conn = home_conn |> recycle() |> get(~p"/setup")
    setup_body = html_response(setup_conn, 200)

    assert setup_body =~ "Setup required"
    assert setup_body =~ "provider:openai"

    ready_conn = setup_conn |> recycle() |> get(~p"/health/ready")
    ready_body = json_response(ready_conn, 503)

    assert ready_body["status"] == "setup_required"
    assert Enum.any?(ready_body["failures"], &(&1["component"] == "provider:openai"))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
