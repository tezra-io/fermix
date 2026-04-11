defmodule FermixWebWeb.HealthControllerTest do
  use FermixWebWeb.ConnCase

  alias FermixCore.Setup.BootReport

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    telegram = Application.get_env(:fermix_channels, :telegram)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)
      BootReport.refresh()
    end)

    :ok
  end

  describe "GET /health/live" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, ~p"/health/live")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["app"] == "fermix"
      assert body["version"] == "0.1.0"
      assert is_binary(body["timestamp"])
    end
  end

  describe "GET /health/ready" do
    test "returns setup_required with actionable readiness failures", %{conn: conn} do
      Application.put_env(:fermix_core, :providers, [])
      Application.delete_env(:fermix_channels, :telegram)
      BootReport.refresh()

      conn = get(conn, ~p"/health/ready")
      body = json_response(conn, 503)

      assert body["status"] == "setup_required"
      assert is_list(body["failures"])

      assert Enum.any?(body["failures"], fn failure ->
               failure["component"] == "provider:openai" and
                 failure["action"] == "Set OPENAI_API_KEY or configure OAuth credentials."
             end)

      assert Enum.any?(body["failures"], fn failure ->
               failure["component"] == "channel:telegram" and
                 failure["action"] == "Set TELEGRAM_BOT_TOKEN."
             end)
    end
  end

  describe "GET /health" do
    test "aliases readiness", %{conn: conn} do
      Application.put_env(:fermix_core, :providers, [])
      Application.delete_env(:fermix_channels, :telegram)
      BootReport.refresh()

      conn = get(conn, ~p"/health")
      body = json_response(conn, 503)

      assert body["status"] == "setup_required"
      assert is_list(body["failures"])
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
