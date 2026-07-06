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
    |> send_resp(403, forbidden_body())
    |> halt()
  end

  # Keep the machine-readable "setup authorization required" phrase, but tell a
  # human operator the one action that actually works: the `fermix setup` CLI is
  # the only launch-token minter (a browser link is never trusted to unlock the
  # secret-writing setup surface — SECURITY_REVIEW F-1).
  defp forbidden_body do
    """
    setup authorization required

    Run `fermix setup` in your terminal to open configuration in your browser.
    """
  end
end
