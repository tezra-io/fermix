defmodule FermixWebWeb.HealthController do
  use FermixWebWeb, :controller

  alias FermixCore.Health

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
    readiness = Health.report()

    conn
    |> put_status(if(readiness.status == :ready, do: :ok, else: :service_unavailable))
    |> json(readiness)
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
