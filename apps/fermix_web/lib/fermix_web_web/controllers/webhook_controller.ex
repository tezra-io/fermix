defmodule FermixWebWeb.WebhookController do
  use FermixWebWeb, :controller

  require Logger

  alias FermixChannels.Dispatcher
  alias FermixChannels.Telegram
  alias FermixChannels.WhatsApp
  alias FermixCore.Agents.MainAgent

  @auth_errors [
    :invalid_signature,
    :invalid_token,
    :missing_raw_body,
    :missing_signature,
    :missing_token,
    :not_configured
  ]
  @invalid_webhook_errors [:unsupported_transport]

  @spec telegram(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def telegram(conn, params) do
    with :ok <- Telegram.verify_webhook(conn),
         {:ok, messages} <- Telegram.parse_webhook(params) do
      Dispatcher.dispatch(messages,
        channel: Telegram,
        agent: MainAgent,
        agent_server: MainAgent
      )

      :telemetry.execute(
        [:fermix, :channel, :webhook],
        %{count: length(messages)},
        %{channel: :telegram}
      )

      json(conn, %{ok: true})
    else
      {:error, reason} ->
        webhook_error_response(conn, "Telegram webhook", reason)
    end
  end

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
    with :ok <- WhatsApp.verify_webhook(conn),
         {:ok, messages} <- WhatsApp.parse_webhook(params) do
      Dispatcher.dispatch(messages,
        channel: WhatsApp,
        agent: MainAgent,
        agent_server: MainAgent
      )

      :telemetry.execute(
        [:fermix, :channel, :webhook],
        %{count: length(messages)},
        %{channel: :whatsapp}
      )

      json(conn, %{ok: true})
    else
      {:error, reason} ->
        webhook_error_response(conn, "WhatsApp webhook", reason)
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

      true ->
        Logger.error("#{label} failed: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Invalid webhook"})
    end
  end
end
