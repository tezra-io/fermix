defmodule FermixWebWeb.WebhookController do
  use FermixWebWeb, :controller

  require Logger

  alias FermixChannels.Dispatcher
  alias FermixChannels.Telegram
  alias FermixCore.Agents.MainAgent

  @auth_errors [:invalid_token, :missing_token, :not_configured]

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
      {:error, reason} when reason in @auth_errors ->
        Logger.error("Telegram webhook auth failed: #{inspect(reason)}")

        conn
        |> put_status(401)
        |> json(%{error: "Unauthorized"})

      {:error, reason} ->
        Logger.error("Telegram webhook failed: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Invalid webhook"})
    end
  end
end
