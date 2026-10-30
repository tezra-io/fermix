defmodule FermixWebWeb.WebhookController do
  use FermixWebWeb, :controller

  require Logger

  alias FermixChannels.Channels.Slack
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway.WebhookIngress

  @auth_errors [
    :invalid_signature,
    :invalid_token,
    :missing_raw_body,
    :missing_signature,
    :missing_timestamp,
    :missing_token,
    :not_configured,
    :stale_timestamp
  ]
  @invalid_webhook_errors [:unsupported_transport, :invalid_webhook_payload]

  @spec whatsapp_verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def whatsapp_verify(conn, params) do
    case WhatsApp.verify_challenge(params) do
      {:ok, challenge} ->
        text(conn, challenge)

      {:error, reason} ->
        webhook_error_response(conn, "WhatsApp webhook verification", reason)
    end
  end

  @spec whatsapp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def whatsapp(conn, params) do
    case WhatsApp.verify_webhook(conn) do
      :ok -> ingest(conn, :whatsapp, WhatsApp, params, "WhatsApp webhook")
      {:error, reason} -> webhook_error_response(conn, "WhatsApp webhook", reason)
    end
  end

  @spec slack(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def slack(conn, params) do
    with :ok <- Slack.verify_webhook(conn) do
      case Slack.url_verification_challenge(params) do
        {:ok, challenge} ->
          json(conn, %{challenge: challenge})

        :ignore ->
          ingest(conn, :slack, Slack, params, "Slack webhook")

        {:error, reason} ->
          webhook_error_response(conn, "Slack webhook", reason)
      end
    else
      {:error, reason} ->
        webhook_error_response(conn, "Slack webhook", reason)
    end
  end

  @doc false
  @spec webhook_error_response(Plug.Conn.t(), String.t(), term()) :: Plug.Conn.t()
  def webhook_error_response(conn, label, reason)
      when is_binary(label) or is_atom(label) do
    cond do
      reason in @auth_errors ->
        Logger.error("#{label} auth failed: #{inspect(reason)}")

        conn
        |> put_status(401)
        |> json(%{error: "Unauthorized"})

      reason in @invalid_webhook_errors ->
        Logger.error("#{label} failed: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Invalid webhook"})

      client_dispatch_error?(reason) ->
        Logger.error("#{label} failed client validation: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Invalid webhook"})

      true ->
        Logger.error("#{label} dispatch failed: #{inspect(reason)}")

        conn
        |> put_status(500)
        |> json(%{error: "Webhook dispatch failed"})
    end
  end

  # A verified payload takes the one path every transport of the channel
  # shares (`Gateway.WebhookIngress`); the provider is acknowledged once its
  # fresh messages are handed off, and told to retry when nothing could be.
  defp ingest(conn, channel_key, channel_module, params, label) do
    case WebhookIngress.ingest(channel_key, channel_module, params) do
      :ok ->
        json(conn, %{ok: true})

      {:error, {:parse, reason}} ->
        webhook_error_response(conn, label, reason)

      {:error, {:handoff, _reason}} ->
        conn
        |> put_status(503)
        |> json(%{error: "Webhook handoff unavailable"})
    end
  end

  defp client_dispatch_error?({:attachment_download_failed, :missing_attachment_reference}),
    do: true

  defp client_dispatch_error?({:transcription_failed, :empty_transcription}), do: true
  defp client_dispatch_error?({:invalid_message, _field}), do: true
  defp client_dispatch_error?(_reason), do: false
end
