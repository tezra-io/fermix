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
    acp = Application.get_env(:fermix_channels, :acp)
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
      restore_env(:fermix_channels, :acp, acp)
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
      assert body["version"] == to_string(Application.spec(:fermix_core, :vsn))
      assert is_binary(body["timestamp"])
    end

    test "pretty=1 returns indented JSON for browser reads", %{conn: conn} do
      conn = get(conn, ~p"/health/live?pretty=1")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert conn.resp_body =~ "{\n"
      assert conn.resp_body =~ "\n  \""
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
                 failure["action"] ==
                   "Set the Telegram bot token: run `fermix setup` or set bot_token in config.toml."
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

    test "pretty=1 returns indented readiness JSON without changing status", %{conn: conn} do
      Application.put_env(:fermix_core, :providers, [])
      Application.delete_env(:fermix_channels, :telegram)
      Application.put_env(:fermix_channels, :whatsapp, enabled: false)
      Application.put_env(:fermix_channels, :discord, enabled: false)
      Application.put_env(:fermix_channels, :slack, enabled: false)
      Application.put_env(:fermix_channels, :signal, enabled: false)
      BootReport.refresh()

      conn = get(conn, ~p"/health/ready?pretty=1")
      body = json_response(conn, 503)

      assert body["status"] == "setup_required"
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert conn.resp_body =~ "{\n"
      assert conn.resp_body =~ "\n  \""
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

    test "lists the acp transport with its listener state", %{conn: conn} do
      Application.put_env(:fermix_core, :providers,
        openai: [auth_mode: :api_key, api_key: "sk-test-123"]
      )

      Application.put_env(:fermix_channels, :telegram, enabled: false)
      Application.put_env(:fermix_channels, :whatsapp, enabled: false)
      Application.put_env(:fermix_channels, :discord, enabled: false)
      Application.put_env(:fermix_channels, :slack, enabled: false)
      Application.put_env(:fermix_channels, :signal, enabled: false)
      Application.put_env(:fermix_channels, :acp, enabled: true, mode: :gateway)
      BootReport.refresh()

      # Status-agnostic on purpose: the assertion is that the transport is
      # listed, not what the rest of this host's readiness happens to be.
      body = conn |> get(~p"/health/ready") |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert Enum.any?(body["channels"], fn channel ->
               channel["name"] == "acp" and channel["enabled"] == true and
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
