defmodule FermixWebWeb.WebhookControllerTest do
  use FermixWebWeb.ConnCase

  @webhook_secret "test_webhook_secret_token"

  setup do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test_bot_token",
      webhook_secret: @webhook_secret
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
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
end
