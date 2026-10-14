defmodule FermixWebWeb.HealthControllerTest do
  use FermixWebWeb.ConnCase

  alias FermixCore.BuildInfo
  alias FermixCore.Setup.BootReport

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    realtime = Application.get_env(:fermix_core, :realtime)
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
      restore_env(:fermix_core, :realtime, realtime)
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
      assert body["version"] == BuildInfo.product_version()
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

  # F-02 of the M65 security review: a webhook tunnel forwards every path to the
  # loopback listener, so readiness answers anyone with its status alone. The
  # failures, paths, providers and channels behind it are `Health.report/0`'s
  # (FermixCore.HealthTest), printed by `fermix health --json`.
  describe "GET /health/ready" do
    test "answers setup_required with its status alone, tunneled or not", %{conn: conn} do
      require_setup()

      for conn <- [conn, tunneled(conn)] do
        body = conn |> get(~p"/health/ready") |> json_response(503)

        assert_status_alone(body, "setup_required")
      end
    end

    test "answers 200 with its status alone once ready, tunneled or not", %{conn: conn} do
      Application.put_env(:fermix_core, :providers,
        openai: [auth_mode: :api_key, api_key: "sk-test-123"]
      )

      Application.put_env(:fermix_core, :realtime, enabled: false)

      for channel <- [:telegram, :whatsapp, :discord, :slack, :signal, :acp] do
        Application.put_env(:fermix_channels, channel, enabled: false)
      end

      BootReport.refresh()

      for conn <- [conn, tunneled(conn)] do
        body = conn |> get(~p"/health/ready") |> json_response(200)

        assert_status_alone(body, "ready")
      end
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

      assert_status_alone(body, "degraded")
    end
  end

  describe "GET /health" do
    test "aliases readiness, tunneled or not", %{conn: conn} do
      require_setup()

      for conn <- [conn, tunneled(conn)] do
        body = conn |> get(~p"/health") |> json_response(503)

        assert_status_alone(body, "setup_required")
      end
    end
  end

  defp require_setup do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :whatsapp, enabled: false)
    Application.put_env(:fermix_channels, :discord, enabled: false)
    Application.put_env(:fermix_channels, :slack, enabled: false)
    Application.put_env(:fermix_channels, :signal, enabled: false)
    BootReport.refresh()
  end

  # The four keys `/health/live` gives, `status` carrying the readiness verdict:
  # no config, path, failure, provider, channel, memory or realtime key.
  defp assert_status_alone(body, status) do
    assert Enum.sort(Map.keys(body)) == ["app", "status", "timestamp", "version"]
    assert body["status"] == status
    assert body["app"] == "fermix"
    assert body["version"] == BuildInfo.product_version()
    assert is_binary(body["timestamp"])
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
