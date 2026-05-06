defmodule FermixWebWeb.HealthController do
  use FermixWebWeb, :controller

  alias FermixCore.Health

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    ready(conn, %{})
  end

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, params) do
    send_json(conn, ok_payload(), params)
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, params) do
    readiness = Health.report()

    conn
    |> put_status(if(readiness.status == :ready, do: :ok, else: :service_unavailable))
    |> send_json(readiness, params)
  end

  defp ok_payload do
    %{
      status: "ok",
      app: "fermix",
      version: "0.1.0",
      timestamp: DateTime.utc_now()
    }
  end

  defp send_json(conn, payload, %{"pretty" => "1"}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, Jason.encode!(payload, pretty: true))
  end

  defp send_json(conn, payload, _params) do
    json(conn, payload)
  end
end
