defmodule FermixWebWeb.PageControllerTest do
  use FermixWebWeb.ConnCase

  setup do
    provider_config = Application.get_env(:fermix_core, :providers)
    telegram_config = Application.get_env(:fermix_channels, :telegram)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, provider_config)
      restore_env(:fermix_channels, :telegram, telegram_config)
    end)

    :ok
  end

  test "GET / redirects to /setup when readiness is incomplete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / renders home when readiness is complete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")

    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "GET /setup renders actionable setup guidance when readiness is incomplete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    conn = get(conn, ~p"/setup")
    body = html_response(conn, 200)

    assert body =~ "Setup required"
    assert body =~ "mix fermix.setup"
    assert body =~ "provider:openai"
  end

  test "GET /setup renders ready state when readiness is complete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")

    conn = get(conn, ~p"/setup")
    body = html_response(conn, 200)

    assert body =~ "Fermix is ready"
    assert body =~ "configured"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
