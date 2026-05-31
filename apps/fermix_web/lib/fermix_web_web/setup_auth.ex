defmodule FermixWebWeb.SetupAuth do
  @moduledoc """
  Gates `/setup` behind a local setup session.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias FermixCore.Setup.AccessToken

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn = fetch_query_params(conn)

    cond do
      AccessToken.session_authorized?(get_session(conn, :setup_authorized), opts) ->
        conn

      is_binary(conn.query_params["t"]) ->
        authorize_launch(conn, conn.query_params["t"], opts)

      true ->
        forbidden(conn)
    end
  end

  defp authorize_launch(conn, token, opts) do
    case AccessToken.consume_launch_token(token, opts) do
      {:ok, fingerprint} ->
        conn
        |> put_session(:setup_authorized, fingerprint)
        |> redirect(to: "/setup")
        |> halt()

      {:error, _reason} ->
        forbidden(conn)
    end
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "setup authorization required\n")
    |> halt()
  end
end
