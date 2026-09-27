defmodule FermixCore.Browser.HostServer do
  @moduledoc """
  The browser surface over the Fermix app's own browser pane (`:fermix_app`).

  The macOS app hosts a WebKit pane that the engine drives over a local wire,
  `browser_host.sock`, as a second implementation of the surface
  `CDP.Backend` implements over Chrome. The wire is not built yet, so every
  operation answers `host_unavailable` and nothing is sent anywhere: the mode
  can be selected, started and refused cleanly, and the refusal is all it does.
  """

  @behaviour FermixCore.Browser.Backend

  alias FermixCore.Browser.Error

  @impl true
  def init(opts) when is_list(opts), do: %{profile_name: Keyword.fetch!(opts, :profile_name)}

  @impl true
  def status(_state), do: %{"running" => false, "tabs" => 0}

  @impl true
  def start(_context, state), do: unwired(state)

  @impl true
  def stop(state), do: state

  # A server traps exits, so an exit from anything linked to it arrives here.
  # This backend links nothing.
  @impl true
  def handle_message({:EXIT, _from, _reason}, state), do: state

  @impl true
  def console_buffer(_state), do: []

  @impl true
  def open(_args, _context, state), do: unwired(state)

  @impl true
  def navigate(_args, _context, state), do: unwired(state)

  @impl true
  def snapshot(_args, _context, state), do: unwired(state)

  @impl true
  def tabs(_args, _context, state), do: unwired(state)

  @impl true
  def focus(_args, _context, state), do: unwired(state)

  @impl true
  def close(_args, _context, state), do: unwired(state)

  @impl true
  def screenshot(_args, _context, state), do: unwired(state)

  @impl true
  def pdf(_args, _context, state), do: unwired(state)

  @impl true
  def console(_args, _context, state), do: unwired(state)

  @impl true
  def dialog(_args, _context, state), do: unwired(state)

  @impl true
  def cookies(_args, _context, state), do: unwired(state)

  @impl true
  def storage(_args, _context, state), do: unwired(state)

  @impl true
  def upload(_args, _context, state), do: unwired(state)

  @impl true
  def download(_args, _context, state), do: unwired(state)

  @impl true
  def act(_args, _context, state), do: unwired(state)

  @impl true
  def webmcp(_args, _context, state), do: unwired(state)

  defp unwired(state) do
    {:error,
     Error.new(
       "host_unavailable",
       "This engine cannot drive the Fermix app's browser yet, so nothing was done in it."
     ), state}
  end
end
