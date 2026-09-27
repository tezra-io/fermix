defmodule FermixCore.Browser.HostServer do
  @moduledoc """
  The browser surface over the Fermix app's own browser pane (`:fermix_app`).

  The macOS app hosts a WebKit pane that the engine drives over a local wire,
  `browser_host.sock`, as a second implementation of the surface
  `CDP.Backend` implements over Chrome. The wire is not built yet, so every
  operation answers `host_unavailable` and nothing is sent anywhere: the mode
  can be selected, started and refused cleanly, and the refusal is all it does.

  Before every operation the host's last report is read (`HostAvailability`).
  A pane that is no longer available fails the task where it stands: the
  operation answers `host_lost` and the profile is reaped. Nothing re-runs it
  in Chrome; the conversation's next browser use is decided afresh.
  """

  @behaviour FermixCore.Browser.Backend

  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability

  @impl true
  def init(opts) when is_list(opts) do
    %{
      profile_name: Keyword.fetch!(opts, :profile_name),
      host_availability: Keyword.get(opts, :host_availability, HostAvailability)
    }
  end

  @impl true
  def status(_state), do: %{"running" => false, "tabs" => 0}

  @impl true
  def start(_context, state), do: answer(state)

  @impl true
  def stop(state), do: state

  # A server traps exits, so an exit from anything linked to it arrives here.
  # This backend links nothing.
  @impl true
  def handle_message({:EXIT, _from, _reason}, state), do: state

  @impl true
  def console_buffer(_state), do: []

  @impl true
  def open(_args, _context, state), do: answer(state)

  @impl true
  def navigate(_args, _context, state), do: answer(state)

  @impl true
  def snapshot(_args, _context, state), do: answer(state)

  @impl true
  def tabs(_args, _context, state), do: answer(state)

  @impl true
  def focus(_args, _context, state), do: answer(state)

  @impl true
  def close(_args, _context, state), do: answer(state)

  @impl true
  def screenshot(_args, _context, state), do: answer(state)

  @impl true
  def pdf(_args, _context, state), do: answer(state)

  @impl true
  def console(_args, _context, state), do: answer(state)

  @impl true
  def dialog(_args, _context, state), do: answer(state)

  @impl true
  def cookies(_args, _context, state), do: answer(state)

  @impl true
  def storage(_args, _context, state), do: answer(state)

  @impl true
  def upload(_args, _context, state), do: answer(state)

  @impl true
  def download(_args, _context, state), do: answer(state)

  @impl true
  def act(_args, _context, state), do: answer(state)

  @impl true
  def webmcp(_args, _context, state), do: answer(state)

  defp answer(state) do
    host = HostAvailability.current(state.host_availability)

    if HostAvailability.usable?(host),
      do: unwired(state),
      else: {:reap, lost(host), state}
  end

  defp lost(host) do
    Error.new(
      "host_lost",
      "The Fermix app's browser is no longer available: " <>
        HostAvailability.unavailable_reason(host) <> "."
    )
  end

  defp unwired(state) do
    {:error,
     Error.new(
       "host_unavailable",
       "This engine cannot drive the Fermix app's browser yet, so nothing was done in it."
     ), state}
  end
end
