defmodule FermixWebWeb.HomeLive do
  @moduledoc """
  Home dashboard rendered as a LiveView so the runtime snapshot
  (main agent, realtime voice, jobs, capabilities) auto-refreshes
  without the operator having to reload the page.

  Re-uses the same `FermixWebWeb.HomeSnapshot` source as the legacy
  controller path and the CLI introspection; the only added behavior
  is a periodic `Process.send_after(self(), :refresh, ...)` driven
  re-fetch when the WebSocket is connected.

  Initial HTTP render still produces a full HTML response (so search
  engines, curl, and tests work), then the page upgrades to live via
  the LiveView socket and starts polling.
  """

  use FermixWebWeb, :live_view

  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.BootReport
  alias FermixWebWeb.HomeSnapshot

  # 3s is fast enough that the operator sees "FermixPet connected" within
  # a tick of starting the Pet, and slow enough not to thrash the daemon
  # (`Health.report/1` walks every supervised process). Local-only endpoint
  # so we don't worry about network load.
  @refresh_interval_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    case BootReport.current() do
      %{status: :ready} ->
        setup_path = setup_path!()

        if connected?(socket), do: schedule_refresh()

        {:ok,
         socket
         |> assign(page_title: "Fermix")
         |> assign(:setup_path, setup_path)
         |> assign_home_snapshot()}

      _not_ready ->
        {:ok, push_navigate(socket, to: ~p"/setup")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_home_snapshot(socket)}
  end

  defp assign_home_snapshot(socket) do
    snapshot_module = Application.get_env(:fermix_web, :home_snapshot, HomeSnapshot)

    home =
      case snapshot_module.snapshot() do
        {:ok, snapshot} -> %{status: :ok, data: snapshot}
        {:error, reason} -> %{status: :error, reason: snapshot_error_label(reason)}
      end

    assign(socket, home: home)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp setup_path! do
    case AccessToken.mint_launch_token() do
      {:ok, launch} -> ~p"/setup?t=#{launch.token}"
      {:error, reason} -> raise "could not mint setup launch token: #{inspect(reason)}"
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

  # Template helpers used by home_live.html.heex.
  def status_label(nil), do: "unknown"

  def status_label(value) when is_atom(value) do
    value |> Atom.to_string() |> status_label()
  end

  def status_label(value) when is_binary(value) do
    String.replace(value, "_", " ")
  end

  def status_label(value), do: inspect(value)

  def datetime_label(nil), do: "none"
  def datetime_label(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def datetime_label(value) when is_binary(value), do: value
  def datetime_label(value), do: inspect(value)
end
