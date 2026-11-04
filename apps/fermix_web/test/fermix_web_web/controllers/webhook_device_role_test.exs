defmodule FermixWebWeb.WebhookDeviceRoleTest do
  # M75 D13: a device-role engine answers the webhook routes with 503 and hands
  # nothing to a channel, so it never posts the refusal into Slack or WhatsApp.
  #
  # async: false: the channel hand-off's telemetry and the idempotency table are
  # global, and both are read for an absence.
  use FermixWebWeb.ConnCase, async: false

  alias FermixChannels.Gateway.Idempotency

  @device %{role: :device, primary: "aws i-0f3b1c"}
  @slack_signing_secret "device-role-slack-secret"

  setup do
    previous = Application.fetch_env(:fermix_channels, :slack)

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :webhook,
      bot_token: "xoxb-device-role",
      signing_secret: @slack_signing_secret
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :slack, value)
        :error -> Application.delete_env(:fermix_channels, :slack)
      end
    end)

    test_pid = self()
    handler = "webhook-device-role-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fermix, :channel, :webhook],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:handed_to_channel, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "a signed Slack message gets 503 and reaches no channel", %{conn: conn} do
    body = Jason.encode!(slack_message("device role probe"))
    timestamp = Integer.to_string(System.os_time(:second))

    conn =
      conn
      |> Plug.Conn.put_private(:fermix_engine_role, @device)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-slack-request-timestamp", timestamp)
      |> put_req_header("x-slack-signature", slack_signature(body, timestamp))
      |> post(~p"/webhook/slack", body)

    assert json_response(conn, 503) == %{"error" => "This engine runs in the device role"}

    # The hand-off emits its event before the response is sent, so a message
    # that reached a channel would already be in this mailbox.
    refute_received {:handed_to_channel, _metadata}

    # Never recorded either, so the platform's retry after a move back is fresh.
    assert Idempotency.check_and_record(:slack, "1714000000.000200") == :fresh
    :ok = Idempotency.forget(:slack, "1714000000.000200")
  end

  test "the WhatsApp routes answer 503 too", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_private(:fermix_engine_role, @device)
      |> get(~p"/webhook/whatsapp", %{"hub.mode" => "subscribe", "hub.challenge" => "c"})

    assert json_response(conn, 503) == %{"error" => "This engine runs in the device role"}
    refute_received {:handed_to_channel, _metadata}
  end

  defp slack_message(text) do
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
        "ts" => "1714000000.000200"
      }
    }
  end

  defp slack_signature(body, timestamp) do
    digest = :crypto.mac(:hmac, :sha256, @slack_signing_secret, "v0:#{timestamp}:#{body}")
    "v0=" <> Base.encode16(digest, case: :lower)
  end
end
