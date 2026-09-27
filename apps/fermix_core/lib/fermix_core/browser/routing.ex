defmodule FermixCore.Browser.Routing do
  @moduledoc """
  Which backend a conversation's browser use runs on, decided once, when it
  starts.

  The named profile `fermix` is the one profile routed. It runs in the Fermix
  app's browser pane (`:fermix_app`) when the app's browser host is attached
  and its last report says the pane is available (`HostAvailability`), and in
  the managed Chrome (`:managed`) exactly as before otherwise. Every other
  profile is what its configuration says.

  The decision is made when no profile is live for the conversation and never
  again while one is: a live profile's registry entry records the backend it
  was started on (`ProfileManager.backend/3`), and the request is pinned to
  it, a cold start of the same request included. So a task never changes
  browser mid-way: a Chrome task stays in Chrome when the pane appears, and a
  pane task that loses its pane fails there (`HostServer`) instead of being
  re-run in Chrome.
  """

  alias FermixCore.Browser.Backend
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Trace

  @routed_profile "fermix"

  @doc """
  The profile a request runs on, and the backend that implies.

  `opts` may carry `:registry` (the profile registry to read) and
  `:host_availability` (the availability process to ask); both default to the
  browser tree's own.
  """
  @spec for_request(String.t(), String.t(), Config.profile(), Config.t(), map(), keyword()) ::
          {Config.profile(), Backend.label()}
  def for_request(owner, profile_name, profile, %Config{} = config, context, opts \\ [])
      when is_binary(owner) and is_binary(profile_name) and is_map(profile) and is_map(context) do
    case ProfileManager.backend(owner, profile_name, opts) do
      nil -> decide(owner, profile_name, profile, config, context, opts)
      recorded -> {pin(profile, recorded), recorded}
    end
  end

  @doc "A profile held to the backend recorded for it."
  @spec pin(Config.profile(), Backend.label()) :: Config.profile()
  def pin(profile, :fermix_app), do: %{profile | mode: :fermix_app}
  def pin(profile, :cdp), do: profile

  defp decide(owner, @routed_profile, %{mode: :managed} = profile, _config, context, opts) do
    host = opts |> Keyword.get(:host_availability, HostAvailability) |> HostAvailability.current()

    if HostAvailability.usable?(host) do
      trace(context, owner, :fermix_app, nil)
      {pin(profile, :fermix_app), :fermix_app}
    else
      trace(context, owner, :cdp, HostAvailability.unavailable_reason(host))
      {profile, :cdp}
    end
  end

  defp decide(_owner, _profile_name, profile, _config, _context, _opts),
    do: {profile, Backend.label(profile.mode)}

  # Why a task ran where it did is answered here and nowhere else, so the
  # decision is traced beside the launch events of the profile it starts.
  defp trace(context, owner, backend, reason) do
    Trace.record(:agent_event, Map.get(context, :agent_name, "browser"), %{
      "event" => "browser_route",
      "profile" => @routed_profile,
      "owner" => owner,
      "backend" => Atom.to_string(backend),
      "reason" => reason
    })
  end
end
