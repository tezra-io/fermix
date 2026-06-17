defmodule Fermix.CLI.Service do
  @moduledoc """
  OS service installation for `fermix run`.

  Generates and installs a launchd `.plist` (macOS) or systemd
  `.service` unit (Linux) that executes `fermix run`. Two scopes
  per OS — user (default; per-user, no sudo) and system (`--system`;
  boot survival, sudo). On Linux user-scope, `loginctl enable-linger`
  is required for reboot survival; the installer runs it and aborts
  loud if it fails (no degraded "works while logged in" half-state).

  Pure dispatch: the launchd backend lives in `Service.Launchd`, the
  systemd backend in `Service.Systemd`, and the unit-file templates
  in `Service.Templates`. This module decides which backend to call
  based on the host OS, holds the install/uninstall/start/stop
  contracts, and computes the install target paths.
  """

  alias Burrito.Util.Args, as: BurritoArgs
  alias Fermix.CLI.Service.Launchd
  alias Fermix.CLI.Service.Systemd
  alias Fermix.CLI.Service.Templates
  alias FermixCore.Setup.ConfigStore

  @label "io.tezra.fermix"
  @linux_unit "fermix.service"

  # Non-secret observability env propagated into the OS service file so the
  # installed daemon behaves like the setup shell. FERMIX_OPIK_ENABLED is the
  # activation switch; the rest are overrides with working defaults. The Opik
  # API key is deliberately absent — secrets never go into launchd/systemd files.
  @observability_env ~w(
    FERMIX_OPIK_ENABLED
    FERMIX_OPIK_BASE_URL
    FERMIX_OPIK_PROJECT
    FERMIX_TRACE_CONTENT
  )

  @type scope :: :user | :system
  @type os :: :darwin | :linux

  @type unit_spec :: %{
          os: os(),
          scope: scope(),
          unit_path: Path.t(),
          fermix_path: Path.t(),
          fermix_home: Path.t(),
          service_env: %{String.t() => String.t()},
          log_path: Path.t(),
          label: String.t(),
          linux_unit: String.t()
        }

  @spec install(scope(), keyword()) :: :ok | {:error, term()}
  def install(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts),
         :ok <- File.mkdir_p(Path.dirname(spec.unit_path)),
         :ok <- File.mkdir_p(Path.dirname(spec.log_path)),
         :ok <- write_unit(spec),
         :ok <- backend(spec).install(spec) do
      :ok
    end
  end

  @spec uninstall(scope(), keyword()) :: :ok | {:error, term()}
  def uninstall(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts),
         :ok <- backend(spec).uninstall(spec),
         :ok <- remove_unit(spec) do
      :ok
    end
  end

  @spec start(scope(), keyword()) :: :ok | {:error, term()}
  def start(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts), do: backend(spec).start(spec)
  end

  @spec stop(scope(), keyword()) :: :ok | {:error, term()}
  def stop(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts), do: backend(spec).stop(spec)
  end

  @spec restart(scope(), keyword()) :: :ok | {:error, term()}
  def restart(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with :ok <- stop(scope, opts), do: start(scope, opts)
  end

  @spec installed?(scope(), keyword()) :: boolean()
  def installed?(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    case spec(scope, opts) do
      {:ok, %{unit_path: path}} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  @doc """
  True only when this process is the OS-supervised release daemon: a Burrito
  standalone release whose launchd/systemd unit is installed. False under
  `mix fermix.dev` and in tests, so callers that self-restart by exiting (and
  rely on the supervisor to relaunch) never strand a non-supervised process.
  """
  @spec supervised?(keyword()) :: boolean()
  def supervised?(opts \\ []) when is_list(opts) do
    Burrito.Util.running_standalone?() and
      (installed?(:user, opts) or installed?(:system, opts))
  end

  @spec spec(scope(), keyword()) :: {:ok, unit_spec()} | {:error, term()}
  def spec(scope, opts \\ []) when scope in [:user, :system] do
    case detect_os(opts) do
      :darwin -> {:ok, build_spec(:darwin, scope, opts)}
      :linux -> {:ok, build_spec(:linux, scope, opts)}
      other -> {:error, {:unsupported_os, other}}
    end
  end

  @doc """
  Render the unit-file body that would be written by `install/2` for
  the given scope. Used by tests and by `fermix doctor` to verify
  installed-vs-current parity.
  """
  @spec render_unit(scope(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render_unit(scope, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts), do: {:ok, render(spec)}
  end

  @doc """
  True when the installed unit file no longer matches what `install/2` would
  write for `scope` now — e.g. a binary upgrade changed the template or the
  computed `PATH`. `fermix setup` uses this to *reconcile* a drifted unit
  (rewrite + reload) instead of merely restarting a stale one, so unit changes
  reach an already-installed daemon without a manual `fermix service install`.
  False when the on-disk unit matches. An unreadable/absent unit counts as
  drift: rewriting it is the safe convergent action (callers gate on
  `installed?/2`, so this is the file-vanished/unreadable edge, not the steady
  state).
  """
  @spec drifted?(scope(), keyword()) :: boolean()
  def drifted?(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with {:ok, spec} <- spec(scope, opts),
         {:ok, on_disk} <- File.read(spec.unit_path) do
      on_disk != render(spec)
    else
      _ -> true
    end
  end

  defp build_spec(os, scope, opts) do
    home = fermix_home(opts)
    fermix_path = fermix_path(opts)

    %{
      os: os,
      scope: scope,
      unit_path: unit_path(os, scope, opts),
      fermix_path: fermix_path,
      fermix_home: home,
      service_env: service_env(opts, home, service_path(os, fermix_path)),
      log_path: log_path(opts),
      label: @label,
      linux_unit: @linux_unit
    }
  end

  defp unit_path(:darwin, :user, opts) do
    Keyword.get(opts, :unit_path) ||
      Path.join(System.user_home!(), "Library/LaunchAgents/#{@label}.plist")
  end

  defp unit_path(:darwin, :system, opts) do
    Keyword.get(opts, :unit_path) || "/Library/LaunchDaemons/#{@label}.plist"
  end

  defp unit_path(:linux, :user, opts) do
    Keyword.get(opts, :unit_path) ||
      Path.join(System.user_home!(), ".config/systemd/user/#{@linux_unit}")
  end

  defp unit_path(:linux, :system, opts) do
    Keyword.get(opts, :unit_path) || "/etc/systemd/system/#{@linux_unit}"
  end

  # When running inside the Burrito wrapper, `System.find_executable/1`
  # returns the *extracted* release launcher inside the Burrito cache,
  # which only understands the standard mix-release verbs (`start`,
  # `daemon`, `eval`) and rejects our `fermix run` subcommand. We need
  # the wrapper binary itself — the one launchd or systemd should
  # invoke — and Burrito exposes that via `__BURRITO_BIN_PATH`.
  defp fermix_path(opts) do
    resolved =
      Keyword.get(opts, :fermix_path) || burrito_bin_path() ||
        System.find_executable("fermix") ||
        raise(ArgumentError, "fermix binary not on PATH; pass :fermix_path explicitly")

    stable_path(resolved)
  end

  # A Homebrew install resolves to a versioned Cellar path
  # (e.g. /opt/homebrew/Cellar/fermix/0.1.0/bin/fermix). Pin the service unit to
  # the stable `<prefix>/bin/<name>` symlink so `brew upgrade` does not strand the
  # unit on a removed version; non-Cellar paths pass through unchanged.
  defp stable_path(path) do
    case Regex.run(~r{^(.*)/Cellar/[^/]+/[^/]+/bin/([^/]+)$}, path) do
      [_full, prefix, name] ->
        symlink = Path.join([prefix, "bin", name])
        if File.exists?(symlink), do: symlink, else: path

      _no_match ->
        path
    end
  end

  defp burrito_bin_path do
    case BurritoArgs.get_bin_path() do
      :not_in_burrito -> nil
      path when is_binary(path) -> path
    end
  end

  defp fermix_home(opts) do
    Keyword.get(opts, :fermix_home, default_fermix_home())
  end

  defp log_path(opts) do
    Keyword.get(opts, :log_path, Path.join(default_fermix_home(), "logs/fermix.log"))
  end

  # Delegate to the canonical resolver (which treats a blank FERMIX_HOME as
  # unset) rather than re-deriving it here.
  defp default_fermix_home, do: ConfigStore.fermix_home()

  # The env map written into the unit file: the FERMIX_HOME + PATH baseline plus
  # any set, allowlisted observability vars. The source is the install-time
  # process env by default; callers (and tests) inject an explicit `:env` map to
  # snapshot deterministically. It is a snapshot — changing the env later needs a
  # reinstall. PATH is *computed* (see `service_path/2`), never copied from the
  # source env — the install-time shell PATH is irrelevant to the daemon.
  defp service_env(opts, fermix_home, service_path) do
    source = Keyword.get(opts, :env) || system_observability_env()

    source
    |> Map.take(@observability_env)
    |> Map.reject(fn {_key, value} -> blank?(value) end)
    |> Map.put("FERMIX_HOME", fermix_home)
    |> Map.put("PATH", service_path)
  end

  # launchd and systemd hand a spawned daemon a bare PATH (roughly
  # `/usr/bin:/bin:/usr/sbin:/sbin`) that omits the Homebrew prefix where
  # `cosign` (plugin-signature verification) and brew-installed `node`/`python`
  # (MCP-plugin runtimes) live. With no PATH in the unit file the daemon's
  # `System.find_executable/1` returns nil and plugin installs fail as if the
  # signature were bad. Pin a PATH that leads with the directory fermix itself
  # was installed into — its siblings include `cosign` on a Homebrew install —
  # then the standard system locations. `Enum.uniq` collapses the common case
  # where that directory already is a standard bin dir (Homebrew = `…/bin`).
  defp service_path(os, fermix_path) do
    [Path.dirname(fermix_path) | standard_bindirs(os)]
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp standard_bindirs(:darwin),
    do: ~w(/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)

  defp standard_bindirs(:linux),
    do: ~w(/usr/local/bin /usr/bin /bin /usr/sbin /sbin)

  defp system_observability_env do
    Map.new(@observability_env, fn key -> {key, System.get_env(key)} end)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp detect_os(opts) do
    Keyword.get(opts, :os) ||
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
        other -> other
      end
  end

  defp backend(%{os: :darwin}), do: Launchd
  defp backend(%{os: :linux}), do: Systemd

  defp render(%{os: :darwin} = spec), do: Templates.render_darwin_plist(spec)
  defp render(%{os: :linux} = spec), do: Templates.render_linux_unit(spec)

  defp write_unit(spec), do: File.write(spec.unit_path, render(spec))

  defp remove_unit(%{unit_path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:remove_failed, reason}}
    end
  end
end
