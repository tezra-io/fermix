defmodule FermixWebWeb.WebhookController do
  use FermixWebWeb, :controller

  require Logger

  alias FermixChannels.Telegram
  alias FermixCore.Agents.MainAgent

  @spec telegram(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def telegram(conn, params) do
    with :ok <- Telegram.verify_webhook(conn),
         {:ok, messages} <- Telegram.parse_webhook(params) do
      forward_messages(messages)

      :telemetry.execute(
        [:fermix, :channel, :webhook],
        %{count: length(messages)},
        %{channel: :telegram}
      )

      json(conn, %{ok: true})
    else
      {:error, reason} ->
        Logger.error("Telegram webhook failed: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Invalid webhook"})
    end
  end

  defp forward_messages(messages) do
    Enum.each(messages, fn msg ->
      reply_fn = fn text ->
        Telegram.send_message(msg.chat_id, text)
      end

      agent_msg = %{
        content: msg.content,
        sender: msg.sender,
        channel: msg.channel,
        chat_id: msg.chat_id,
        reply_fn: reply_fn
      }

      MainAgent.handle_message(agent_msg)
    end)
  end
end
