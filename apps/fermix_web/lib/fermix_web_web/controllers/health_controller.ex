defmodule FermixWebWeb.HealthController do
  use FermixWebWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      app: "fermix",
      version: "0.1.0",
      timestamp: DateTime.utc_now()
    })
  end
end
