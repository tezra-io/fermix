defmodule FermixCore.Tools.PlaceSearch.Backend do
  @moduledoc """
  The place search backends, and the one resolver that chooses between them
  (M72 §14.1).

  Two providers yield the one M31 record (§10.2): Brave Place Search over
  HTTPS (`PlaceSearch.Brave`) and Apple Maps through the `fermix-maps` helper on
  a Mac (`PlaceSearch.AppleMaps`). M31 §21.6 rejected a shared behaviour while
  there was one provider; with two it exists, as `WebSearch.Backend` does.

  `resolve/2` is the only place the choice is made.
  `[fermix_core.tools.place_search] backend` wins when it is set; unset, the
  build decides: Apple Maps where the build carries the helper (the Fermix Mac
  app's engine, and a checkout built on a Mac), Brave in the Homebrew and Linux
  builds. The resolution says which of the two decided, so Doctor can say why.
  The build is the host value `FermixCore.BootProfile.host/0` answers (the
  profile boot selected, and the operating system), injected as `host:`, so a
  test names the build it means. It is never a look at the helper file.

  Nothing falls back. A backend that is not ready refuses with its own reason
  (`ready/2`): Brave without a resolvable key; Apple Maps on a build that
  carries no helper, naming the build; Apple Maps whose helper or disclaim shim
  is missing from a build that should carry them, saying reinstall. A search
  that fails returns its own tag and is never retried on the other backend
  (M31 §21.7); `brave` never spawns the helper.
  """

  alias FermixCore.BootProfile
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixCore.Tools.PlaceSearch.Brave
  alias FermixCore.Tools.PlaceSearch.Config

  @type anchor :: {:location, String.t()} | {:coordinates, number(), number()}
  @type request :: %{
          required(:query) => String.t(),
          optional(:anchor) => anchor(),
          optional(:radius_meters) => pos_integer(),
          optional(:count) => pos_integer(),
          optional(:country) => String.t(),
          optional(:language) => String.t(),
          optional(:units) => :metric | :imperial
        }
  @type place :: %{required(:name) => String.t(), optional(atom()) => term()}
  @type trace_metadata :: %{optional(atom()) => term()}
  @type source :: :configured | :build_default
  @type resolution :: %{name: Config.backend(), module: module(), source: source()}

  @doc "The backend's configuration word, as `[fermix_core.tools.place_search] backend` spells it."
  @callback name() :: Config.backend()

  @doc "Whether a search could run now: `:ok`, or the tagged reason it would refuse."
  @callback ready(opts :: keyword()) :: :ok | {:error, String.t()}

  @doc "One search: the normalized places and the trace metadata, or a tagged reason."
  @callback search(request(), opts :: keyword()) ::
              {:ok, [place()], trace_metadata()} | {:error, String.t(), trace_metadata()}

  @modules %{apple_maps: AppleMaps, brave: Brave}

  @set_brave "Set [fermix_core.tools.place_search] backend = \"brave\" to search through Brave"

  @doc """
  The backend in force for a section (`Config.t()`) on this build.

  Pure: the section and the host come in, so a tool, a readiness probe and a
  settings row ask the same question and get the same answer.
  """
  @spec resolve(Config.t(), keyword()) :: resolution()
  def resolve(%{backend: configured}, opts) when is_list(opts) do
    case configured do
      nil -> resolution(build_default(host(opts)), :build_default)
      name -> resolution(name, :configured)
    end
  end

  @doc """
  The backends a build can run, in the order a choice lists them: Brave alone
  where the build carries no Apple Maps helper.
  """
  @spec available(BootProfile.host()) :: [Config.backend()]
  def available(%{profile: _profile, os: _os} = host) do
    if carries_helper?(host), do: Config.backends(), else: [:brave]
  end

  @doc """
  Whether the resolved backend could search now. Apple Maps on a build that
  carries no helper is the refusal a misconfiguration gets, loud and naming the
  build, before any spawn.
  """
  @spec ready(resolution(), keyword()) :: :ok | {:error, String.t()}
  def ready(%{name: :apple_maps, module: module}, opts) when is_list(opts) do
    host = host(opts)
    if carries_helper?(host), do: module.ready(opts), else: {:error, no_helper(host)}
  end

  def ready(%{module: module}, opts) when is_list(opts), do: module.ready(opts)

  @doc "The host this resolves for: `host:` when the caller names it, this build's otherwise."
  @spec host(keyword()) :: BootProfile.host()
  def host(opts) when is_list(opts), do: Keyword.get_lazy(opts, :host, &BootProfile.host/0)

  # Which builds carry the helper is a fact of the build, never a look at the
  # helper file: the Mac app's engine ships it, and a checkout on a Mac makes
  # it with `mix compile`. The Homebrew and Linux builds are made off a Mac and
  # carry none. An app engine missing it is a broken install, which `ready/2`
  # names, not a different default.
  defp carries_helper?(%{profile: :app_engine}), do: true
  defp carries_helper?(%{profile: :source, os: :darwin}), do: true
  defp carries_helper?(%{profile: _profile, os: _os}), do: false

  defp build_default(host), do: if(carries_helper?(host), do: :apple_maps, else: :brave)

  defp no_helper(%{profile: profile}) do
    "provider_error: this build (#{build_name(profile)}) carries no Apple Maps helper; " <>
      "the Fermix Mac app does. " <> @set_brave
  end

  defp build_name(:standalone_cli), do: "the standalone Fermix that Homebrew installs"
  defp build_name(:linux_package_cli), do: "the Linux package"
  defp build_name(:source), do: "a source build off a Mac"

  defp resolution(name, source),
    do: %{name: name, module: Map.fetch!(@modules, name), source: source}
end
