defmodule FermixWebWeb.WebhookController do
  use FermixWebWeb, :controller

  require Logger

  alias FermixChannels.Dispatcher
  alias FermixChannels.Idempotency
  alias FermixChannels.Slack
  alias FermixChannels.WhatsApp
  alias FermixCore.Agents.MainAgent

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
    with :ok <- WhatsApp.verify_webhook(conn),
         {:ok, messages} <- WhatsApp.parse_webhook(params) do
      # Audit F-06: ack the provider quickly. Idempotency check happens
      # synchronously (cheap ETS lookup); the actual agent dispatch (which
      # may transcribe audio / call the LLM) runs in a supervised task.
      fresh = filter_fresh(messages, :whatsapp)

      dispatch_async(fresh,
        channel: WhatsApp,
        agent: MainAgent,
        agent_server: MainAgent
      )

      :telemetry.execute(
        [:fermix, :channel, :webhook],
        %{count: length(fresh), duplicates: length(messages) - length(fresh)},
        %{channel: :whatsapp}
      )

      json(conn, %{ok: true})
    else
      {:error, reason} ->
        webhook_error_response(conn, "WhatsApp webhook", reason)
    end
  end

  @spec slack(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def slack(conn, params) do
    with :ok <- Slack.verify_webhook(conn) do
      case Slack.url_verification_challenge(params) do
        {:ok, challenge} ->
          json(conn, %{challenge: challenge})

        :ignore ->
          dispatch_slack_webhook(conn, params)

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

  defp dispatch_slack_webhook(conn, params) do
    case Slack.parse_webhook(params) do
      {:ok, messages} ->
        fresh = filter_fresh(messages, :slack)

        dispatch_async(fresh,
          channel: Slack,
          agent: MainAgent,
          agent_server: MainAgent
        )

        :telemetry.execute(
          [:fermix, :channel, :webhook],
          %{count: length(fresh), duplicates: length(messages) - length(fresh)},
          %{channel: :slack}
        )

        json(conn, %{ok: true})

      {:error, reason} ->
        webhook_error_response(conn, "Slack webhook", reason)
    end
  end

  defp filter_fresh(messages, channel) do
    Enum.filter(messages, fn message ->
      case Idempotency.check_and_record(channel, message.id) do
        :fresh ->
          true

        :duplicate ->
          Logger.info(
            "#{channel} webhook dropped duplicate message #{inspect(message.id)} (idempotency)"
          )

          false
      end
    end)
  end

  defp dispatch_async([], _opts), do: :ok

  defp dispatch_async(messages, opts) do
    Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn ->
      case Dispatcher.dispatch(messages, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Async webhook dispatch failed for #{inspect(Keyword.get(opts, :channel))}: " <>
              inspect(reason)
          )
      end
    end)

    :ok
  end

  defp client_dispatch_error?({:attachment_download_failed, :missing_attachment_reference}),
    do: true

  defp client_dispatch_error?({:transcription_failed, :empty_transcription}), do: true
  defp client_dispatch_error?({:invalid_message, _field}), do: true
  defp client_dispatch_error?(_reason), do: false
end
