defmodule FermixWebWeb.PageController do
  use FermixWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
