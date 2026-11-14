defmodule FermixCore.Tools.PlaceSearch.Backend do
  @moduledoc """
  The place search backends, and the one resolver that chooses between them
  (M72 §14.1, M89 D13).

  Three backends yield the one M31 record (§10.2): Brave Place Search over
  HTTPS (`PlaceSearch.Brave`), Apple Maps through the `fermix-maps` helper on
  a Mac (`PlaceSearch.AppleMaps`), and Apple Maps on a Mac of the home, asked
  over its link (`PlaceSearch.Computer`). M31 §21.6 rejected a shared
  behaviour while there was one provider; with more it exists, as
  `WebSearch.Backend` does.

  `resolve/2` is the only place the choice is made, one backend per home and
  never per call, from facts that already exist, in this order:

    1. `[fermix_core.tools.place_search] backend` when it is set;
    2. Apple Maps where this build carries the helper (the Fermix Mac app's
       engine, and a checkout built on a Mac);
    3. `computer` where the home has a computer whose latest report lists
       the `places` offer on (`PlaceSearch.Computer.offered/1`, the one view
       of the computers the choice of one reads too): a server's home with
       the owner's Mac linked;
    4. Brave.

  Computers that cannot be read (a record Fermix did not write, a link that
  is not running) never pass to the fourth rule: the resolution is
  `computer` from `:computers_unknown`, which `ready/2` refuses by name.

  The resolution says which rule decided (`source`), so Doctor can say why.
  The build is the host value `FermixCore.BootProfile.host/0` answers (the
  profile boot selected, and the operating system), injected as `host:`, so a
  test names the build it means. It is never a look at the helper file. The
  computers are read only when the first two rules leave the choice open,
  and a test names them as `Computers.fetch/1`'s seams (`records:`,
  `rows:`, `role:`, `version:`, ...).

  Nothing falls back. A backend that is not ready refuses with its own reason
  (`ready/2`): Brave without a resolvable key; Apple Maps on a build that
  carries no helper, naming the build; Apple Maps whose helper or disclaim shim
  is missing from a build that should carry them, saying reinstall; `computer`
  while no computer of the home offers places. A search that fails returns its
  own tag and is never retried on another backend (M31 §21.7); `brave` never
  spawns the helper, and a `computer` whose Mac is away is refused at once,
  never sent to Brave.
  """

  alias FermixCore.BootProfile
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixCore.Tools.PlaceSearch.Brave
  alias FermixCore.Tools.PlaceSearch.Computer
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
  @type source :: :configured | :build_default | :linked_computer | :computers_unknown
  @type resolution :: %{name: Config.backend(), module: module(), source: source()}

  @doc "The backend's configuration word, as `[fermix_core.tools.place_search] backend` spells it."
  @callback name() :: Config.backend()

  @doc "Whether a search could run now: `:ok`, or the tagged reason it would refuse."
  @callback ready(opts :: keyword()) :: :ok | {:error, String.t()}

  @doc "One search: the normalized places and the trace metadata, or a tagged reason."
  @callback search(request(), opts :: keyword()) ::
              {:ok, [place()], trace_metadata()} | {:error, String.t(), trace_metadata()}

  @modules %{apple_maps: AppleMaps, computer: Computer, brave: Brave}

  @set_brave "Set [fermix_core.tools.place_search] backend = \"brave\" to search through Brave"

  @doc """
  The backend in force for a section (`Config.t()`) on this build and home
  (the moduledoc's order).

  Pure but for the facts it reads lazily: the host (`host:`) and, only when
  the first two rules leave the choice open, the home's computers
  (`PlaceSearch.Computer.offered/1`). So a tool, a readiness probe and a
  settings row ask the same question and get the same answer.
  """
  @spec resolve(Config.t(), keyword()) :: resolution()
  def resolve(%{backend: configured}, opts) when is_list(opts) do
    cond do
      configured != nil -> resolution(configured, :configured)
      carries_helper?(host(opts)) -> resolution(:apple_maps, :build_default)
      true -> by_computers(Computer.offered(opts))
    end
  end

  defp by_computers({:ok, true}), do: resolution(:computer, :linked_computer)
  defp by_computers({:ok, false}), do: resolution(:brave, :build_default)
  defp by_computers({:error, _reason}), do: resolution(:computer, :computers_unknown)

  @doc """
  The backends a build can run, in the order a choice lists them: where the
  build carries no Apple Maps helper, a Mac of the home and Brave.
  """
  @spec available(BootProfile.host()) :: [Config.backend()]
  def available(%{profile: _profile, os: _os} = host) do
    if carries_helper?(host), do: [:apple_maps, :brave], else: [:computer, :brave]
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

  @doc """
  Whether a build carries the Apple Maps helper. A fact of the build, never a
  look at the helper file: the Mac app's engine ships it, and a checkout on a
  Mac makes it with `mix compile`. The Homebrew and Linux builds are made off
  a Mac and carry none. An app engine missing it is a broken install, which
  `ready/2` names, not a different default. A computer's `places` offer reads
  the same fact (`Computers.Facts`).
  """
  @spec carries_helper?(BootProfile.host()) :: boolean()
  def carries_helper?(%{profile: :app_engine}), do: true
  def carries_helper?(%{profile: :source, os: :darwin}), do: true
  def carries_helper?(%{profile: _profile, os: _os}), do: false

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
