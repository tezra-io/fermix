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
  alias Fermix.CLI.Service.Packaged
  alias Fermix.CLI.Service.Systemd
  alias Fermix.CLI.Service.Templates
  alias FermixCore.Boot.PathBaseline
  alias FermixCore.BuildInfo
  alias FermixCore.Setup.ConfigStore

  @label "io.tezra.fermix"
  @linux_unit "fermix.service"
  @health_path "/health/live"
  @health_timeout_ms 2_000

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

  @doc """
  Installs this host's background service.

  Two distribution configurations, two owners. A standalone binary writes and
  installs its own unit, as it always has. A Linux distribution package never
  writes a unit — the package owns the vendor unit — so the whole transaction is
  the binding, linger, enablement and verification in `Service.Packaged`, which
  answers with the published status rather than a bare `:ok`.
  """
  @spec install(scope(), keyword()) :: :ok | {:ok, map()} | {:error, term()}
  def install(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    if packaged?(opts), do: Packaged.install(opts), else: legacy_install(scope, opts)
  end

  @spec uninstall(scope(), keyword()) :: :ok | {:error, term()}
  def uninstall(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    if packaged?(opts), do: Packaged.uninstall(opts), else: legacy_uninstall(scope, opts)
  end

  @doc """
  The published service status (M38 §4.4.1), available with no daemon running.

  Only a packaged Linux engine has a packaged service to inspect; every other
  distribution refuses rather than reporting a unit it does not own.
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []) when is_list(opts) do
    if packaged?(opts), do: Packaged.status(opts), else: {:error, :foreign_distribution}
  end

  @doc """
  Persists the listener port for `home` (M38 §4.7).

  Through the shared config write, so every unrelated setting is carried across
  by the same parse and render a setup save uses, and the value lands where the
  boot hydration and `hello`'s published origin both read it. An absent port is
  the ordinary case and changes nothing.

  This is the one write that has to work while the daemon is down, which is why
  it names the home rather than reading it back out of the environment.
  """
  @spec persist_port(Path.t(), pos_integer() | nil) ::
          :ok | {:error, {:invalid_port, String.t()} | {:config_write_failed, term()}}
  def persist_port(home, nil) when is_binary(home), do: :ok

  def persist_port(home, port) when is_binary(home) and is_integer(port) do
    case ConfigStore.put_web_port(home, port) do
      :ok -> :ok
      {:error, {:invalid_port, sentence}} -> {:error, {:invalid_port, sentence}}
      {:error, {:unrenderable_settings, sentence}} -> {:error, {:config_write_failed, sentence}}
      {:error, reason} -> {:error, {:config_write_failed, reason}}
    end
  end

  @doc """
  Whether the daemon's own web address answers `/health/live`.

  Spoken over the socket directly rather than through the shared HTTP client:
  this runs in a tree-less CLI verb, where the pooled client does not exist, and
  the address is always this machine's own loopback.
  """
  @spec health_probe(String.t() | nil) :: :ok | {:error, term()}
  def health_probe(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        request_live(host, port)

      _unusable ->
        {:error, {:invalid_origin, origin}}
    end
  end

  def health_probe(_absent), do: {:error, :no_origin}

  defp legacy_install(scope, opts) do
    with :ok <- legacy_mutation(opts),
         {:ok, spec} <- spec(scope, opts),
         # `--port` reaches both distributions' installers, so a standalone
         # install writes the setting rather than accepting the flag and
         # dropping it.
         :ok <- persist_port(spec.fermix_home, Keyword.get(opts, :port)),
         :ok <- File.mkdir_p(Path.dirname(spec.unit_path)),
         :ok <- File.mkdir_p(Path.dirname(spec.log_path)),
         :ok <- write_unit(spec),
         :ok <- backend(spec).install(spec) do
      :ok
    end
  end

  defp legacy_uninstall(scope, opts) do
    with :ok <- legacy_mutation(opts),
         {:ok, spec} <- spec(scope, opts),
         :ok <- backend(spec).uninstall(spec),
         :ok <- remove_unit(spec) do
      :ok
    end
  end

  defp request_live(host, port) do
    connect_opts = [:binary, {:active, false}, {:packet, :line}]

    case :gen_tcp.connect(to_charlist(host), port, connect_opts, @health_timeout_ms) do
      {:ok, socket} -> read_live(socket, host, port)
      {:error, reason} -> {:error, reason}
    end
  end

  # The socket is this function's to own: it is closed on the send failure, the
  # receive timeout and the successful read alike.
  defp read_live(socket, host, port) do
    request =
      "GET #{@health_path} HTTP/1.1\r\nHost: #{host}:#{port}\r\nConnection: close\r\n\r\n"

    result =
      with :ok <- :gen_tcp.send(socket, request),
           {:ok, line} <- :gen_tcp.recv(socket, 0, @health_timeout_ms) do
        live_status(line)
      end

    _ = :gen_tcp.close(socket)
    result
  end

  defp live_status(line) do
    case String.split(line, " ", parts: 3) do
      [version, "200" | _rest] when version in ["HTTP/1.1", "HTTP/1.0"] ->
        :ok

      _other ->
        {:error, {:unexpected_status, String.trim(line)}}
    end
  end

  defp packaged?(opts) do
    build_info = Keyword.get(opts, :build_info, BuildInfo)
    build_info.linux_package?()
  end

  @spec start(scope(), keyword()) :: :ok | {:error, term()}
  def start(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with :ok <- legacy_mutation(opts), do: do_start(scope, opts)
  end

  @spec stop(scope(), keyword()) :: :ok | {:error, term()}
  def stop(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    with :ok <- legacy_mutation(opts), do: do_stop(scope, opts)
  end

  @doc """
  Restarts this host's background service.

  A packaged engine never stops and starts a unit itself: systemd owns the
  termination signal, so the whole transaction — admission lease, budget reset,
  one `systemctl restart`, and the wait for a different generation — is
  `Service.Packaged.restart/1`, which answers with the new generation rather
  than a bare `:ok` (M38 §4.1).
  """
  @spec restart(scope(), keyword()) :: :ok | {:ok, map()} | {:error, term()}
  def restart(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    if packaged?(opts), do: Packaged.restart(opts), else: legacy_restart(scope, opts)
  end

  defp legacy_restart(scope, opts) do
    with :ok <- legacy_mutation(opts),
         :ok <- do_stop(scope, opts),
         :ok <- do_start(scope, opts) do
      :ok
    end
  end

  @doc """
  Whether this host has a background service set up for `scope`.

  Two distribution configurations ask two different questions of two different
  owners. A standalone binary writes its own unit, so the question is whether
  that file exists. A Linux package never writes one — the package owns the
  vendor unit — so the question is whether a home is bound and the package's
  unit is the effective one, which is what `Service.Packaged.installed?/1`
  answers through the same injected inspector `service status` reads.
  """
  @spec installed?(scope(), keyword()) :: boolean()
  def installed?(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    if packaged?(opts), do: packaged_installed?(scope, opts), else: legacy_installed?(scope, opts)
  end

  # The package owns exactly one user unit, so a system scope has nothing to be
  # installed into; answering true for both would report one service twice.
  defp packaged_installed?(:system, _opts), do: false
  defp packaged_installed?(:user, opts), do: Packaged.installed?(opts)

  defp legacy_installed?(scope, opts) do
    case spec(scope, opts) do
      {:ok, %{unit_path: path}} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  @doc """
  True only when this process is the OS-supervised release daemon.

  Callers self-restart by exiting and rely on the supervisor to relaunch, so a
  supervised daemon that answered false would refuse a restart it can perform
  and a non-supervised one that answered true would strand itself.

  The evidence differs by distribution. A standalone release is supervised when
  a unit it wrote is installed. A packaged engine's unit is owned by the package
  and is installed on every host, so its presence proves nothing about **this**
  process: systemd exports `INVOCATION_ID` into every service it starts, and its
  presence in this process's own environment is what says the vendor unit
  launched this daemon rather than an operator running the binary from a shell.
  """
  @spec supervised?(keyword()) :: boolean()
  def supervised?(opts \\ []) when is_list(opts) do
    standalone?(opts) and started_by_service?(opts)
  end

  defp started_by_service?(opts) do
    if packaged?(opts),
      do: service_invocation?(opts),
      else: installed?(:user, opts) or installed?(:system, opts)
  end

  defp service_invocation?(opts) do
    case Keyword.get_lazy(opts, :invocation_id, fn -> System.get_env("INVOCATION_ID") end) do
      value when is_binary(value) and value != "" -> true
      _absent_or_blank -> false
    end
  end

  defp standalone?(opts) do
    Keyword.get(opts, :standalone?, &Burrito.Util.running_standalone?/0).()
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

  A packaged engine renders no unit at all, so there is nothing to compare and
  nothing to reconcile: it is never drifted. Answering true there would send
  every setup launch through a rewrite path that must not write a unit file.
  """
  @spec drifted?(scope(), keyword()) :: boolean()
  def drifted?(scope \\ :user, opts \\ []) when scope in [:user, :system] do
    if packaged?(opts), do: false, else: legacy_drifted?(scope, opts)
  end

  defp legacy_drifted?(scope, opts) do
    with {:ok, spec} <- spec(scope, opts),
         {:ok, on_disk} <- File.read(spec.unit_path) do
      on_disk != render(spec)
    else
      _ -> true
    end
  end

  defp legacy_mutation(opts) do
    build_info = Keyword.get(opts, :build_info, BuildInfo)

    case build_info.app_engine?() do
      true -> {:error, {:app_managed, :legacy_service}}
      false -> :ok
      _invalid -> {:error, :invalid_build_info_adapter}
    end
  end

  defp do_start(scope, opts) do
    with {:ok, spec} <- spec(scope, opts), do: backend(spec).start(spec)
  end

  defp do_stop(scope, opts) do
    with {:ok, spec} <- spec(scope, opts), do: backend(spec).stop(spec)
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
    [os: os, binary_dir: Path.dirname(fermix_path)]
    |> PathBaseline.dirs()
    |> Enum.join(":")
  end

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
