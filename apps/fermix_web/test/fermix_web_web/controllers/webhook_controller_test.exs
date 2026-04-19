defmodule FermixWebWeb.WebhookControllerTest do
  use FermixWebWeb.ConnCase

  alias FermixWebWeb.WebhookController

  @slack_signing_secret "test-slack-signing-secret"
  @whatsapp_app_secret "test-whatsapp-secret"
  @webhook_body_limit_bytes 1_000_000

  setup do
    Application.put_env(:fermix_channels, :whatsapp,
      enabled: true,
      mode: :webhook,
      access_token: "whatsapp-access-token",
      phone_number_id: "123456789",
      verify_token: "verify-token",
      app_secret: @whatsapp_app_secret
    )

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :webhook,
      bot_token: "xoxb-test-token",
      signing_secret: @slack_signing_secret
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :whatsapp)
      Application.delete_env(:fermix_channels, :slack)
    end)

    :ok
  end

  describe "GET /webhook/whatsapp" do
    test "returns challenge for valid verification request", %{conn: conn} do
      conn =
        get(conn, ~p"/webhook/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "verify-token",
          "hub.challenge" => "challenge-value"
        })

      assert response(conn, 200) == "challenge-value"
    end

    test "returns 401 for invalid verification token", %{conn: conn} do
      conn =
        get(conn, ~p"/webhook/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong",
          "hub.challenge" => "challenge-value"
        })

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end

  describe "POST /webhook/whatsapp" do
    test "returns 200 with valid payload and signature", %{conn: conn} do
      body = Jason.encode!(whatsapp_message_payload("hello whatsapp"))
      signature = whatsapp_signature(body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> post(~p"/webhook/whatsapp", body)

      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "returns 401 when signature is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhook/whatsapp", Jason.encode!(whatsapp_message_payload("hello")))

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "returns 413 when payload exceeds the parser body limit", %{conn: conn} do
      body =
        whatsapp_message_payload(String.duplicate("a", @webhook_body_limit_bytes))
        |> Jason.encode!()

      signature = whatsapp_signature(body)

      assert_error_sent 413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> post(~p"/webhook/whatsapp", body)
      end
    end
  end

  describe "POST /webhook/slack" do
    test "returns the URL verification challenge for a valid signed request", %{conn: conn} do
      body =
        Jason.encode!(%{
          "type" => "url_verification",
          "challenge" => "challenge-value"
        })

      timestamp = Integer.to_string(System.os_time(:second))
      signature = slack_signature(body, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-request-timestamp", timestamp)
        |> put_req_header("x-slack-signature", signature)
        |> post(~p"/webhook/slack", body)

      assert json_response(conn, 200) == %{"challenge" => "challenge-value"}
    end

    test "returns 200 with a valid signed event callback", %{conn: conn} do
      body = Jason.encode!(slack_dm_payload("hello slack"))
      timestamp = Integer.to_string(System.os_time(:second))
      signature = slack_signature(body, timestamp)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-request-timestamp", timestamp)
        |> put_req_header("x-slack-signature", signature)
        |> post(~p"/webhook/slack", body)

      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "returns 401 when the Slack signature is missing", %{conn: conn} do
      body = Jason.encode!(slack_dm_payload("hello slack"))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhook/slack", body)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end

  describe "webhook_error_response/3" do
    test "maps unsupported transport errors to invalid webhook responses", %{conn: conn} do
      conn = WebhookController.webhook_error_response(conn, "Discord", :unsupported_transport)

      assert json_response(conn, 400) == %{"error" => "Invalid webhook"}
    end

    test "maps client-side dispatch validation failures to invalid webhook responses", %{
      conn: conn
    } do
      conn =
        WebhookController.webhook_error_response(
          conn,
          "WhatsApp",
          {:attachment_download_failed, :missing_attachment_reference}
        )

      assert json_response(conn, 400) == %{"error" => "Invalid webhook"}
    end

    test "keeps genuine internal dispatch failures as 500 responses", %{conn: conn} do
      conn =
        WebhookController.webhook_error_response(
          conn,
          "WhatsApp",
          {:transcription_failed, :timeout}
        )

      assert json_response(conn, 500) == %{"error" => "Webhook dispatch failed"}
    end
  end

  defp whatsapp_message_payload(text) do
    %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "waba-id",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "metadata" => %{"phone_number_id" => "123456789"},
                "contacts" => [
                  %{"wa_id" => "15551234567", "profile" => %{"name" => "Alice"}}
                ],
                "messages" => [
                  %{
                    "from" => "15551234567",
                    "id" => "wamid.123",
                    "timestamp" => "1714000000",
                    "type" => "text",
                    "text" => %{"body" => text}
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end

  defp whatsapp_signature(body) do
    digest = :crypto.mac(:hmac, :sha256, @whatsapp_app_secret, body)
    "sha256=" <> Base.encode16(digest, case: :lower)
  end

  defp slack_dm_payload(text) do
    %{
      "type" => "event_callback",
      "team_id" => "T12345",
      "api_app_id" => "A12345",
      "event" => %{
        "type" => "message",
        "channel" => "D12345",
        "channel_type" => "im",
        "user" => "U12345",
        "text" => text,
        "ts" => "1714000000.000100"
      }
    }
  end

  defp slack_signature(body, timestamp) do
    digest =
      :crypto.mac(:hmac, :sha256, @slack_signing_secret, "v0:#{timestamp}:#{body}")

    "v0=" <> Base.encode16(digest, case: :lower)
  end
end
