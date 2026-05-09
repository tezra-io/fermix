defmodule FermixWebWeb.PageController do
  use FermixWebWeb, :controller

  alias FermixCore.Setup.BootReport
  alias FermixWebWeb.HomeSnapshot

  def home(conn, _params) do
    case BootReport.current() do
      %{status: :ready} -> render(conn, :home, home: home_snapshot())
      _report -> redirect(conn, to: ~p"/setup")
    end
  end

  defp home_snapshot do
    snapshot_module =
      Application.get_env(:fermix_web, :home_snapshot, HomeSnapshot)

    case snapshot_module.snapshot() do
      {:ok, snapshot} -> %{status: :ok, data: snapshot}
      {:error, reason} -> %{status: :error, reason: snapshot_error_label(reason)}
    end
  end

  defp snapshot_error_label({:main_agent_unavailable, _reason}),
    do: "Main agent status is unavailable. Check Fermix logs for details."

  defp snapshot_error_label({:capabilities_unavailable, _reason}),
    do: "Capability registry status is unavailable. Check Fermix logs for details."

  defp snapshot_error_label({:jobs_unavailable, _reason}),
    do: "Scheduled jobs status is unavailable. Check Fermix logs for details."

  defp snapshot_error_label(_reason),
    do: "Runtime introspection is unavailable. Check Fermix logs for details."
end
