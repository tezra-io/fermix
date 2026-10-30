defmodule FermixCore.Browser.Routing do
  @moduledoc """
  Which backend a conversation's browser use runs on, and so which profile
  serves it.

  The named profiles `fermix` and `fermix_visible` are the ones routed: the
  pane is the visible browser, so a task on either runs in the Fermix app's
  browser pane (`:fermix_app`) when the app's browser host is attached and its
  last report says the pane is available (`HostAvailability`), and in the
  managed Chrome (`:managed`) exactly as before otherwise. When no host is
  attached and `launch_app` allows it, the app is opened first and the
  decision waits for it under one deadline (`HostLauncher`). `fermix_headless`,
  `fermix_chrome` and `selected_tab`, and every other profile, run what their
  configuration says and are never routed to the pane. `fermix_chrome`, the
  managed Chrome for what the pane cannot do (a page's WebMCP tools, a task's
  downloads), is a second profile beside a pane task, never a re-route of it.

  A conversation's browser can live under two keys (`Scope`): the scope's own
  profile, which for the owner is one per device and shared by every owner
  conversation (one Chrome), and the conversation's own pane profile
  (`Scope.pane_key/2`). A pane task is bound to the turn that started it and
  ends with it (`HostServer`), so the pane is never shared: it runs under the
  conversation's pane key, and Chrome under the scope's key. A guest's two keys
  are one, its conversation's.

  The request is pinned, in this order, to the conversation's own live pane
  profile, then to the scope's live profile (the owner's Chrome), each by the
  backend its registry entry recorded when it started (`ProfileManager.backend/3`),
  a cold start of the same request included; only with neither live is it
  decided fresh, and that decision is the conversation's alone. So a task never
  changes browser mid-way: a Chrome task stays in Chrome when the pane appears,
  a pane task that loses its pane fails there (`HostServer`) instead of being
  re-run in Chrome, and one conversation's pane task never ends, moves or fails
  another's.
  """

  alias FermixCore.Browser.Backend
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostLauncher
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Trace

  @routed_profiles ~w(fermix fermix_visible)

  @typedoc """
  Where a conversation's browser can live: the scope's own profile key
  (`Scope.owner_key/1`) and the conversation's own pane profile key
  (`Scope.pane_key/2`).
  """
  @type keys :: %{owner: String.t(), pane: String.t()}

  @doc """
  The profile a request runs on, the backend that implies, and the key of the
  profile that serves it.

  `opts` may carry `:registry` (the profile registry to read), and
  `:host_availability`, `:launcher`, `:now` and `:sleep` for `HostLauncher`;
  each defaults to the real one.
  """
  @spec for_request(keys(), String.t(), Config.profile(), Config.t(), map(), keyword()) ::
          {Config.profile(), Backend.label(), String.t()}
  def for_request(keys, profile_name, profile, %Config{} = config, context, opts \\ [])
      when is_binary(profile_name) and is_map(profile) and is_map(context) do
    case live(keys, profile_name, opts) do
      {key, recorded} -> {pin(profile, recorded), recorded, key}
      nil -> decide(keys, profile_name, profile, config, context, opts)
    end
  end

  @doc """
  The live profile a conversation's requests are pinned to, as `{key,
  backend}`: its own pane profile, else the scope's profile; `nil` when
  neither is live. Decides nothing and opens nothing.
  """
  @spec live(keys(), String.t(), keyword()) :: {String.t(), Backend.label()} | nil
  def live(%{owner: owner, pane: pane}, profile_name, opts \\ [])
      when is_binary(owner) and is_binary(pane) and is_binary(profile_name) do
    case ProfileManager.backend(pane, profile_name, opts) do
      :fermix_app -> {pane, :fermix_app}
      _no_pane -> scope_profile(owner, profile_name, opts)
    end
  end

  defp scope_profile(owner, profile_name, opts) do
    case ProfileManager.backend(owner, profile_name, opts) do
      nil -> nil
      recorded -> {owner, recorded}
    end
  end

  @doc "A profile held to the backend recorded for it."
  @spec pin(Config.profile(), Backend.label()) :: Config.profile()
  def pin(profile, :fermix_app), do: %{profile | mode: :fermix_app}
  def pin(profile, :cdp), do: profile

  defp decide(keys, profile_name, %{mode: :managed} = profile, config, context, opts)
       when profile_name in @routed_profiles do
    launcher_opts = Keyword.take(opts, [:host_availability, :launcher, :now, :sleep])

    case HostLauncher.decide(config, launcher_opts) do
      :fermix_app ->
        trace(context, keys.pane, profile_name, :fermix_app, nil)
        {pin(profile, :fermix_app), :fermix_app, keys.pane}

      {:managed, reason} ->
        trace(context, keys.owner, profile_name, :cdp, reason)
        {profile, :cdp, keys.owner}
    end
  end

  defp decide(keys, _profile_name, profile, _config, _context, _opts),
    do: {profile, Backend.label(profile.mode), keys.owner}

  # Why a task ran where it did is answered here and nowhere else, so the
  # decision is traced beside the launch events of the profile it starts.
  defp trace(context, owner, profile_name, backend, reason) do
    Trace.record(:agent_event, Map.get(context, :agent_name, "browser"), %{
      "event" => "browser_route",
      "profile" => profile_name,
      "owner" => owner,
      "backend" => Atom.to_string(backend),
      "reason" => reason
    })
  end
end
