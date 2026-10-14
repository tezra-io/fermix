defmodule FermixWebWeb.HomeLive do
  @moduledoc """
  Home dashboard rendered as a LiveView so the runtime snapshot
  (main agent, realtime voice, jobs, capabilities) auto-refreshes
  without the operator having to reload the page.

  Re-uses the same `FermixWebWeb.HomeSnapshot` source as the legacy
  controller path and the CLI introspection; the only added behavior
  is a periodic `Process.send_after(self(), :refresh, ...)` driven
  re-fetch when the WebSocket is connected.

  Initial HTTP render still produces a full HTML response (so curl and
  tests work), then the page upgrades to live via the LiveView socket
  and starts polling. Both answer only the setup session, as `/setup`
  does: `SetupAuth` refuses the HTTP request, and `mount/3` refuses a
  socket that connects without it (M65 security review F-02).
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

  # An unauthorized mount goes to `/setup`, whose SetupAuth refuses it with a
  # 403. SetupLive sends its own unauthorized mount to `/`, refused the same way,
  # so neither redirect can loop.
  @impl true
  def mount(_params, session, socket) do
    if AccessToken.session_authorized?(setup_authorization(session)) do
      mount_authorized(socket)
    else
      {:ok, redirect(socket, to: ~p"/setup")}
    end
  end

  defp mount_authorized(socket) do
    case BootReport.current() do
      %{status: :ready} ->
        if connected?(socket), do: schedule_refresh()

        # A bare `/setup` link — never mint a launch token here. The operator's
        # session cookie satisfies SetupAuth on its own, and the `fermix setup`
        # CLI stays the only launch-token minter.
        {:ok,
         socket
         |> assign(page_title: "Fermix")
         |> assign(:setup_path, ~p"/setup")
         |> assign_home_snapshot()}

      _not_ready ->
        {:ok, push_navigate(socket, to: ~p"/setup")}
    end
  end

  defp setup_authorization(session) do
    session["setup_authorized"] || session[:setup_authorized]
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
