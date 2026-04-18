defmodule FermixWebWeb.CacheBodyReader do
  @moduledoc """
  Plug body reader that caches raw request bodies for signed webhook checks.
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, cache_raw_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, cache_raw_body(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cache_raw_body(conn, body) do
    existing = conn.assigns[:raw_body] || ""
    Plug.Conn.assign(conn, :raw_body, existing <> body)
  end
end
