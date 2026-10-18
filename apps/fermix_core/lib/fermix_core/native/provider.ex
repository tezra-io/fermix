defmodule FermixCore.Native.Provider do
  @moduledoc """
  Who serves this computer's own services (M76 §4.3): the Fermix app on a Mac
  (`:mac_app`), the session bus on Linux (`:dbus`), or nobody (`:none`).

  A pure function of the host `FermixCore.BootProfile.host/0` answers (the
  profile boot selected, and the operating system), so it is a fact of the
  build, stable for the daemon's life, and what it gates (a schema property, a
  delivery adapter, a prompt line) is cache-safe. It is never stored a second
  time: `current/0` asks `BootProfile`, which already holds the profile.

  On a Mac only the app's engine has an app to serve it: a standalone engine
  runs with no app attached, and a source run is a developer's daemon with
  none either. On Linux the engine asks the session bus itself, whatever the
  build. Whether the app is attached, a notification server owns its name or a
  grant is held is asked live, by each service, and never hides one.

  A caller names the provider with `provider:`, or the host that selects it
  with `host:` (`current/1`), as `PlaceSearch.Backend` takes `host:`.
  """

  alias FermixCore.BootProfile

  @type t :: :mac_app | :dbus | :none

  @providers [:mac_app, :dbus, :none]

  @doc """
  The provider for `host` (`BootProfile.host/0`'s shape). A host no build
  boots as (a Linux package on a Mac, an operating system Fermix does not ship
  for) is refused rather than given a guess.
  """
  @spec select(BootProfile.host()) :: t()
  def select(%{profile: :app_engine, os: :darwin}), do: :mac_app
  def select(%{profile: :standalone_cli, os: :darwin}), do: :none
  def select(%{profile: :source, os: :darwin}), do: :none
  def select(%{profile: _profile, os: :linux}), do: :dbus

  @doc "This build's provider: the one its boot profile and operating system select."
  @spec current() :: t()
  def current, do: select(BootProfile.host())

  @doc """
  The provider a caller resolves for: `provider:` when it names one, else the
  one `host(opts)` selects. A named provider outside the three is refused.
  """
  @spec current(keyword()) :: t()
  def current(opts) when is_list(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} when provider in @providers ->
        provider

      {:ok, other} ->
        raise ArgumentError,
              "provider: must be one of #{inspect(@providers)}, got: #{inspect(other)}"

      :error ->
        select(host(opts))
    end
  end

  @doc "The host this resolves for: `host:` when the caller names it, this build's otherwise."
  @spec host(keyword()) :: BootProfile.host()
  def host(opts) when is_list(opts), do: Keyword.get_lazy(opts, :host, &BootProfile.host/0)
end
