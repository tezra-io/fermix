defmodule FermixWebWeb.WebhookControllerTest do
  use FermixWebWeb.ConnCase

  @webhook_secret "test_webhook_secret_token"
  @whatsapp_app_secret "test-whatsapp-secret"

  setup do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test_bot_token",
      webhook_secret: @webhook_secret
    )

    Application.put_env(:fermix_channels, :whatsapp,
      enabled: true,
      mode: :webhook,
      access_token: "whatsapp-access-token",
      phone_number_id: "123456789",
      verify_token: "verify-token",
      app_secret: @whatsapp_app_secret
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
      Application.delete_env(:fermix_channels, :whatsapp)
    end)

    :ok
  end

  describe "POST /webhook/telegram" do
    test "returns 200 with valid payload and secret", %{conn: conn} do
      payload = telegram_message_payload("hello bot")

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post(~p"/webhook/telegram", payload)

      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "returns 200 for non-message updates (empty messages)", %{conn: conn} do
      payload = %{"update_id" => 999}

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post(~p"/webhook/telegram", payload)

      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "returns 401 when secret token is missing", %{conn: conn} do
      payload = telegram_message_payload("hello")

      conn = post(conn, ~p"/webhook/telegram", payload)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "returns 401 when secret token is wrong", %{conn: conn} do
      payload = telegram_message_payload("hello")

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", "wrong_token")
        |> post(~p"/webhook/telegram", payload)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "handles channel post without from field", %{conn: conn} do
      payload = %{
        "update_id" => 123_456,
        "message" => %{
          "message_id" => 789,
          "chat" => %{"id" => 42},
          "text" => "channel post"
        }
      }

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post(~p"/webhook/telegram", payload)

      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "emits telemetry event on valid message", %{conn: conn} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:fermix, :channel, :webhook]
        ])

      payload = telegram_message_payload("test message")

      conn
      |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
      |> post(~p"/webhook/telegram", payload)

      assert_receive {[:fermix, :channel, :webhook], ^ref, %{count: 1}, %{channel: :telegram}}
    end
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
  end

  defp telegram_message_payload(text) do
    %{
      "update_id" => 123_456,
      "message" => %{
        "message_id" => 789,
        "chat" => %{"id" => 42},
        "from" => %{"username" => "test_user", "first_name" => "Test"},
        "text" => text
      }
    }
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
end
