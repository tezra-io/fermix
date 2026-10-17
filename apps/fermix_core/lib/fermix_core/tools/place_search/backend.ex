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
  backend is Apple Maps on macOS and Brave elsewhere, and the resolution says
  which of the two decided, so Doctor can say why. The host is injected as
  `macos?:` (a test crossing the platform gate names the platform it means).

  Nothing falls back. A backend that is not ready refuses with its own reason
  (`ready/2`): Brave without a resolvable key, Apple Maps without its helper or
  off a Mac. A search that fails returns its own tag and is never retried on
  the other backend (M31 §21.7); `brave` on a Mac never spawns the helper.
  """

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
  @type source :: :configured | :platform_default
  @type resolution :: %{name: Config.backend(), module: module(), source: source()}

  @doc "The backend's configuration word, as `[fermix_core.tools.place_search] backend` spells it."
  @callback name() :: Config.backend()

  @doc "Whether a search could run now: `:ok`, or the tagged reason it would refuse."
  @callback ready(opts :: keyword()) :: :ok | {:error, String.t()}

  @doc "One search: the normalized places and the trace metadata, or a tagged reason."
  @callback search(request(), opts :: keyword()) ::
              {:ok, [place()], trace_metadata()} | {:error, String.t(), trace_metadata()}

  @modules %{apple_maps: AppleMaps, brave: Brave}

  @off_mac "provider_error: Apple Maps place search runs only on macOS; set " <>
             "[fermix_core.tools.place_search] backend = \"brave\" to search through Brave"

  @doc """
  The backend in force for a section (`Config.t()`) on this host.

  Pure: the section and the host come in, so a tool, a readiness probe and a
  settings row ask the same question and get the same answer.
  """
  @spec resolve(Config.t(), keyword()) :: resolution()
  def resolve(%{backend: configured}, opts) when is_list(opts) do
    case configured do
      nil -> resolution(platform_default(macos?(opts)), :platform_default)
      name -> resolution(name, :configured)
    end
  end

  @doc "The backends a host can run, in the order a choice lists them: Linux has Brave alone."
  @spec available(boolean()) :: [Config.backend()]
  def available(true), do: Config.backends()
  def available(false), do: [:brave]

  @doc """
  Whether the resolved backend could search now. Apple Maps off a Mac is the
  refusal a misconfiguration gets, loud and named, before any spawn.
  """
  @spec ready(resolution(), keyword()) :: :ok | {:error, String.t()}
  def ready(%{name: :apple_maps, module: module}, opts) when is_list(opts) do
    if macos?(opts), do: module.ready(opts), else: {:error, @off_mac}
  end

  def ready(%{module: module}, opts) when is_list(opts), do: module.ready(opts)

  @doc "The host this resolves for: `macos?:` when the caller names it, the real one otherwise."
  @spec macos?(keyword()) :: boolean()
  def macos?(opts) when is_list(opts),
    do: Keyword.get_lazy(opts, :macos?, fn -> :os.type() == {:unix, :darwin} end)

  defp platform_default(true), do: :apple_maps
  defp platform_default(false), do: :brave

  defp resolution(name, source),
    do: %{name: name, module: Map.fetch!(@modules, name), source: source}
end
