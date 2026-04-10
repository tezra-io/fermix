defmodule FermixWebWeb.HealthController do
  use FermixWebWeb, :controller

  alias FermixCore.Readiness

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    ready(conn, %{})
  end

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, ok_payload())
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    readiness = readiness_payload()

    conn
    |> put_status(if(readiness.status == :ready, do: :ok, else: :service_unavailable))
    |> json(readiness)
  end

  defp readiness_payload do
    Readiness.report()
    |> Map.put(:app, "fermix")
    |> Map.put(:version, "0.1.0")
    |> Map.put(:timestamp, DateTime.utc_now())
  end

  defp ok_payload do
    %{
      status: "ok",
      app: "fermix",
      version: "0.1.0",
      timestamp: DateTime.utc_now()
    }
  end
end
