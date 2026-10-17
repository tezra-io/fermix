defmodule FermixCore.BootProfile do
  @moduledoc """
  Selects and prepares the engine boot posture.

  App-engine ownership comes only from immutable build identity. Burrito
  detection remains relevant to standalone artifacts and is never consulted to
  identify an app engine.

  The profile boot selected is remembered (`remember/1`) and read back with
  `current/0`, so a later question about this build (which place search
  backend it carries, say) asks the one answer boot already gave rather than
  selecting again. `host/0` pairs it with the operating system: the one host
  value a caller hands on, and a test names.
  """

  alias FermixCore.Boot.PathBaseline

  @profiles [:app_engine, :standalone_cli, :linux_package_cli, :source]

  @type profile :: :app_engine | :standalone_cli | :linux_package_cli | :source
  @type host :: %{profile: profile(), os: atom()}

  @doc "Selects a boot profile while giving app identity strict precedence."
  @spec select(String.t(), (-> boolean())) :: profile()
  def select("macos_app", detector) when is_function(detector, 0), do: :app_engine

  def select("standalone", detector) when is_function(detector, 0) do
    if detector.(), do: :standalone_cli, else: :source
  end

  # A `linux_package` stamp names how the artifact was built, and a source run of
  # that checkout is still a developer's tree: only the Burrito wrapper is the
  # packaged CLI the distribution package installs.
  def select("linux_package", detector) when is_function(detector, 0) do
    if detector.(), do: :linux_package_cli, else: :source
  end

  @doc "Records the profile boot selected, before anything reads it."
  @spec remember(profile()) :: :ok
  def remember(profile) when profile in @profiles,
    do: Application.put_env(:fermix_core, :boot_profile, profile)

  @doc """
  The profile boot selected. Raises when boot recorded none: a reader outside
  a started application has no build to describe.
  """
  @spec current() :: profile()
  def current, do: Application.fetch_env!(:fermix_core, :boot_profile)

  @doc "This build's profile and the operating system it runs on (`:darwin`, `:linux`)."
  @spec host() :: host()
  def host do
    {_family, os} = :os.type()
    %{profile: current(), os: os}
  end

  @doc """
  Applies runtime gates required before sibling OTP applications start.

  The `PATH` baseline is applied here and only here: an `SMAppService`-launched
  engine inherits launchd's bare `PATH` and would otherwise resolve no `cosign`,
  no brew `node` or `python`, and no `codex` or `claude` in `~/.local/bin`.
  A `:source` run deliberately gets none, so a developer sees their own `PATH`.
  """
  @spec prepare(profile()) :: :ok
  def prepare(profile) when profile in [:app_engine, :standalone_cli, :linux_package_cli] do
    PathBaseline.ensure!()
    enable_endpoint_server()
    Application.put_env(:fermix_core, :daemon_socket_enabled, true)
    Application.put_env(:fermix_core, :realtime_socket_enabled, true)
  end

  def prepare(:source), do: :ok

  defp enable_endpoint_server do
    existing = Application.get_env(:fermix_web, FermixWebWeb.Endpoint, [])
    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, Keyword.put(existing, :server, true))
  end
end
