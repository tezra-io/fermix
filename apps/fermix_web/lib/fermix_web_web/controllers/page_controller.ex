defmodule FermixWebWeb.PageController do
  use FermixWebWeb, :controller

  alias FermixCore.Setup.BootReport

  def home(conn, _params) do
    case BootReport.refresh() do
      %{status: :ready} -> render(conn, :home)
      _report -> redirect(conn, to: ~p"/setup")
    end
  end
end
