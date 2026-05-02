defmodule FermixWebWeb.HealthControllerTest do
  use FermixWebWeb.ConnCase

  alias FermixCore.Setup.BootReport

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    telegram = Application.get_env(:fermix_channels, :telegram)
    whatsapp = Application.get_env(:fermix_channels, :whatsapp)
    discord = Application.get_env(:fermix_channels, :discord)
    slack = Application.get_env(:fermix_channels, :slack)
    signal = Application.get_env(:fermix_channels, :signal)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])

    Application.put_env(:fermix_core, :personalization,
      user_name: "Test User",
      timezone: "UTC",
      communication_style: "neutral and direct"
    )

    Application.put_env(:fermix_core, :agent, name: "fermix")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)
      restore_env(:fermix_channels, :whatsapp, whatsapp)
      restore_env(:fermix_channels, :discord, discord)
      restore_env(:fermix_channels, :slack, slack)
      restore_env(:fermix_channels, :signal, signal)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
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
      Application.put_env(:fermix_channels, :whatsapp, enabled: false)
      Application.put_env(:fermix_channels, :discord, enabled: false)
      Application.put_env(:fermix_channels, :slack, enabled: false)
      Application.put_env(:fermix_channels, :signal, enabled: false)
      BootReport.refresh()

      conn = get(conn, ~p"/health/ready")
      body = json_response(conn, 503)

      assert body["status"] == "setup_required"
      assert is_list(body["failures"])
      assert is_map(body["config"])
      assert is_list(body["providers"])
      assert is_list(body["channels"])
      assert is_map(body["memory"])

      assert Enum.any?(body["failures"], fn failure ->
               failure["component"] == "provider:openai" and
                 failure["action"] == "Set OPENAI_API_KEY."
             end)

      assert Enum.any?(body["failures"], fn failure ->
               failure["component"] == "channel:telegram" and
                 failure["action"] == "Set TELEGRAM_BOT_TOKEN."
             end)

      assert Enum.any?(body["providers"], fn provider ->
               provider["name"] == "openai" and provider["status"] == "setup_required"
             end)

      assert Enum.any?(body["channels"], fn channel ->
               channel["name"] == "telegram" and channel["status"] == "setup_required"
             end)

      assert body["memory"]["conversation_store"] == "ready"
      assert body["memory"]["store"] == "ready"
    end

    test "returns degraded when a configured long-running channel process is unavailable", %{
      conn: conn
    } do
      Application.put_env(:fermix_core, :providers,
        openai: [auth_mode: :api_key, api_key: "sk-test-123"]
      )

      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        mode: :webhook,
        bot_token: "bot"
      )

      Application.put_env(:fermix_channels, :whatsapp, enabled: false)
      Application.put_env(:fermix_channels, :discord, enabled: false)
      Application.put_env(:fermix_channels, :slack, enabled: false)

      Application.put_env(:fermix_channels, :signal,
        enabled: true,
        mode: :subprocess,
        account: "+15550001111"
      )

      BootReport.refresh()

      conn = get(conn, ~p"/health/ready")
      body = json_response(conn, 503)

      assert body["status"] == "degraded"

      assert Enum.any?(body["channels"], fn channel ->
               channel["name"] == "signal" and channel["status"] == "degraded" and
                 channel["process_alive"] == false
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
