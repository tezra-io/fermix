defmodule FermixCore.Plugins.Dist.Installer do
  @moduledoc """
  Installs plugins from the catalog index: the ordered, fail-loud pipeline
  (resolve → compat gate → download → sha256 → cosign → extract+guard →
  validate tree → h1 → atomic activate → record lockfile), plus uninstall and
  gc.

  Serialization (§7): every mutating op (`run_install`/`run_uninstall`/`run_gc`)
  runs under the cross-VM `Dist.Lock`, so a CLI VM and the daemon VM sharing
  one `$FERMIX_HOME` cannot interleave. The GenServer exists only for daemon
  boot hygiene — the transient-staging sweep in `init`; mutations are plain
  functions callable from any VM.

  Seams (injected in tests, real impls in prod): `:fetcher` (a `Dist.Fetcher`),
  `:verifier` (a `Dist.Verifier`), and the index via `:index_opts`.
  """

  use GenServer

  require Logger

  alias Fermix.CLI.Upgrade.Manifest
  alias FermixCore.Net.StreamDownload
  alias FermixCore.Plugins.Dist.Archive
  alias FermixCore.Plugins.Dist.Fetcher.Http, as: FetcherHttp
  alias FermixCore.Plugins.Dist.Index
  alias FermixCore.Plugins.Dist.Lock
  alias FermixCore.Plugins.Dist.RuntimeProbe
  alias FermixCore.Plugins.Dist.SafeRm
  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Plugins.Dist.Telemetry
  alias FermixCore.Plugins.Dist.Verifier.Cosign, as: VerifierCosign
  alias FermixCore.Plugins.Registry
  alias FermixCore.Setup.ConfigStore

  @allowed_top ~w(plugin.json skills assets bin src CHANGELOG.md README.md LICENSE yanked.json)
  @runtime_ecosystem ~w(package.json package-lock.json pyproject.toml uv.lock requirements.txt mix.exs mix.lock)

  # --- GenServer (daemon boot hygiene: sweep) ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, config} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @impl true
  def init(config) do
    root = resolve_root(config)
    Store.ensure!(root)
    sweep_under_lock(root)
    {:ok, config}
  end

  # Boot hygiene: GC staging leftovers and run tokens from a crashed prior
  # run. Under the cross-VM lock with a small bounded budget — a held lock
  # means another VM is mid-pipeline and its live staging must not be swept;
  # skip and let the next boot collect.
  defp sweep_under_lock(root) do
    lock = Store.paths(root).lock
    sweep = fn -> Store.sweep_transient!(root) end

    case Lock.with_lock(lock, sweep, attempts: 5, delay_ms: 20) do
      :ok ->
        :ok

      {:error, :lock_unavailable} ->
        Logger.info("Plugin store busy at boot — skipping transient sweep")
        :ok
    end
  end

  # --- entry points (CLI and daemon alike): each takes the cross-VM lock ---

  @doc """
  Resolve, fetch, verify, extract, and activate a plugin from the index.
  Returns `{:ok, :installed | :already_installed}` or `{:error, reason}`. The
  whole pipeline runs under the cross-VM store lock.
  """
  @spec run_install(String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def run_install(name, opts \\ []) when is_binary(name) do
    root = resolve_root(opts)
    with_store_lock(root, opts, fn -> pipeline(name, root, opts) end)
  end

  @spec run_uninstall(String.t(), keyword()) :: :ok | {:error, term()}
  def run_uninstall(name, opts \\ []) when is_binary(name) do
    root = resolve_root(opts)
    started = Telemetry.start()
    version = Store.active_version(root, name)
    result = with_store_lock(root, opts, fn -> Store.uninstall(root, name) end)
    Telemetry.emit(:uninstall, name, version, result, started)
    result
  end

  @spec run_gc(keyword()) :: :ok | {:error, term()}
  def run_gc(opts \\ []) do
    root = resolve_root(opts)
    started = Telemetry.start()
    result = with_store_lock(root, opts, fn -> Store.gc(root) end)
    Telemetry.emit(:gc, nil, nil, result, started)
    result
  end

  defp with_store_lock(root, opts, fun) do
    Store.ensure!(root)
    Lock.with_lock(Store.paths(root).lock, fun, Keyword.get(opts, :lock_opts, []))
  end

  # --- the pipeline (lock-free core, shared by CLI + daemon) ---

  defp pipeline(name, root, opts) do
    started = Telemetry.start()
    {version, result} = resolve_and_install(name, root, opts)
    Telemetry.emit(:install, name, version, result, started)
    result
  end

  defp resolve_and_install(name, root, opts) do
    with :ok <- refuse_bundled(name),
         {:ok, plugin} <- find_plugin(name, opts),
         version = requested_version(plugin, opts),
         {:ok, version_entry} <- find_version(plugin, version),
         :ok <- refuse_yanked(plugin, version),
         :ok <- check_compat(version_entry, opts) do
      {version, maybe_install(name, version, plugin, version_entry, root, opts)}
    else
      {:error, _reason} = error -> {nil, error}
    end
  end

  # A bundled plugin ships inside the Fermix binary — it is never installable
  # from the index; a name may not exist in both sets (§8).
  defp refuse_bundled(name) do
    case Registry.bundled_names() do
      {:ok, names} ->
        if name in names, do: {:error, {:bundled_plugin, name}}, else: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_install(name, version, _plugin, version_entry, root, opts) do
    # Resolve the host-target artifact first so the idempotency check compares
    # the lockfile SHA against the artifact that would actually be installed —
    # not the first artifact in the index (which can differ on a multi-target
    # plugin, making re-enable re-download every time).
    with {:ok, artifact} <- resolve_artifact(version_entry, opts) do
      install_or_reactivate(name, version, version_entry, artifact, root, opts)
    end
  end

  defp install_or_reactivate(name, version, version_entry, artifact, root, opts) do
    force? = Keyword.get(opts, :force, false)

    if not force? and already_installed?(root, name, version, artifact) do
      with :ok <- Store.activate(root, name, version), do: {:ok, :already_installed}
    else
      fetch_verify_install(name, version, version_entry, artifact, root, opts)
    end
  end

  defp fetch_verify_install(name, version, version_entry, artifact, root, opts) do
    work = Path.join(Store.paths(root).staging, "#{name}-#{version}")
    SafeRm.rm_rf(work, root)
    File.mkdir_p!(work)

    try do
      do_fetch_verify_install(name, version, version_entry, artifact, root, work, opts)
    after
      SafeRm.rm_rf(work, root)
    end
  end

  defp do_fetch_verify_install(name, version, version_entry, artifact, root, work, opts) do
    tgz = Path.join(work, "artifact.tgz")
    sig = Path.join(work, "artifact.sig")
    cert = Path.join(work, "artifact.pem")
    tree = Path.join(work, "tree")

    with :ok <- download_all(artifact, tgz, sig, cert, opts),
         :ok <- check_sha(tgz, artifact),
         :ok <- verify_sig(tgz, sig, cert, name, version, opts),
         :ok <- Archive.extract(tgz, tree),
         {:ok, manifest} <- read_manifest(tree),
         :ok <- check_identity(manifest, name, version),
         :ok <- check_boundary(tree, runtime?(manifest)),
         {:ok, plugin} <- decode_staged_manifest(manifest, tree),
         :ok <- probe_runtime(plugin, tree, opts),
         h1 = Store.h1(tree),
         :ok <- Store.install_tree(root, name, version, tree) do
      record(root, name, version, artifact, version_entry, h1)
    end
  end

  # --- pipeline steps ---

  defp find_plugin(name, opts) do
    with {:ok, index} <- Index.load(Keyword.get(opts, :index_opts, [])) do
      case Index.find(index, name) do
        nil -> {:error, {:unknown_plugin, name}}
        plugin -> {:ok, plugin}
      end
    end
  end

  defp requested_version(plugin, opts) do
    case Keyword.get(opts, :version, :latest) do
      :latest -> plugin.latest
      version -> version
    end
  end

  defp find_version(plugin, version) do
    case Enum.find(plugin.versions, &(&1.version == version)) do
      nil -> {:error, {:version_not_found, plugin.name, version}}
      entry -> {:ok, entry}
    end
  end

  defp refuse_yanked(plugin, version) do
    if version in plugin.yanked, do: {:error, {:yanked, plugin.name, version}}, else: :ok
  end

  defp check_compat(version_entry, opts) do
    core = Keyword.get(opts, :core_version, Store.core_version())

    case Store.compatible?(version_entry, core) do
      :ok -> :ok
      {:error, reason} -> {:error, {:incompatible, reason}}
    end
  end

  # Installed = the lockfile records this version+sha AND the version dir is
  # actually present. The dir check heals a crash that left the lockfile entry
  # from a prior install but no tree (e.g. a force-reinstall that died between
  # removing the old dir and renaming the new one) — re-run the pipeline rather
  # than activate a void symlink.
  defp already_installed?(root, name, version, artifact) do
    case Map.get(Store.installed(root), name) do
      %{"version" => ^version, "sha256" => sha} ->
        sha == artifact.sha256 and File.dir?(Store.version_dir(root, name, version))

      _ ->
        false
    end
  end

  defp resolve_artifact(version_entry, opts) do
    with {:ok, target} <- target_for(opts) do
      case Enum.find(version_entry.artifacts, &(&1.target == target or &1.target == "any")) do
        nil -> {:error, {:no_build_for_target, target}}
        artifact -> {:ok, artifact}
      end
    end
  end

  defp target_for(opts) do
    case Keyword.get(opts, :target) do
      target when is_binary(target) -> {:ok, target}
      nil -> host_target()
    end
  end

  defp download_all(artifact, tgz, sig, cert, opts) do
    fetcher = Keyword.get(opts, :fetcher, FetcherHttp)

    with :ok <- fetcher.fetch(artifact.url, tgz),
         :ok <- fetcher.fetch(artifact.sig_url, sig) do
      fetcher.fetch(artifact.cert_url, cert)
    end
  end

  defp check_sha(tgz, artifact) do
    case StreamDownload.check_sha256(tgz, artifact.sha256) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_sig(tgz, sig, cert, name, version, opts) do
    verifier = Keyword.get(opts, :verifier, VerifierCosign)

    case verifier.verify(tgz, sig, cert, name: name, version: version) do
      :ok -> :ok
      {:error, reason} -> {:error, {:verification_failed, reason}}
    end
  end

  defp check_identity(manifest, name, version) do
    cond do
      manifest["name"] != name ->
        {:error, {:manifest_name_mismatch, manifest["name"], name}}

      manifest["version"] != version ->
        {:error, {:manifest_version_mismatch, manifest["version"], version}}

      true ->
        :ok
    end
  end

  defp runtime?(manifest), do: is_map(manifest["runtime"])

  defp check_boundary(tree, has_runtime?) do
    allowed = MapSet.new(@allowed_top ++ if(has_runtime?, do: @runtime_ecosystem, else: []))

    case Enum.reject(File.ls!(tree), &(&1 in allowed)) do
      [] -> :ok
      [bad | _] -> {:error, {:content_boundary_violation, bad}}
    end
  end

  # Single validation authority (§8): the staged tree must pass the same
  # `Registry.decode_manifest/2` the registry runs at load time — covering
  # required fields, tool naming/templates (SSRF, undeclared placeholders),
  # and interface assets — so a plugin that installs can never brick
  # `Registry.list/1` after activation.
  defp decode_staged_manifest(manifest, tree) do
    Registry.decode_manifest(manifest, Path.join(tree, "plugin.json"))
  end

  # mcp plugins declare a host runtime (M8 §8): probe it at install time so
  # a machine without Node/Python refuses loudly instead of enabling a
  # plugin whose child can never spawn. `:probe_opts` is the test seam.
  defp probe_runtime(%{runtime: runtime}, tree, opts) when is_map(runtime) do
    RuntimeProbe.probe(runtime, tree, Keyword.get(opts, :probe_opts, []))
  end

  defp probe_runtime(_plugin, _tree, _opts), do: :ok

  defp record(root, name, version, artifact, version_entry, h1) do
    Store.record(root, name, %{
      "version" => version,
      "sha256" => artifact.sha256,
      "h1" => h1,
      "plugin_api" => Map.get(version_entry, :plugin_api),
      "verified_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
    |> case do
      :ok -> {:ok, :installed}
      error -> error
    end
  end

  # --- helpers ---

  defp read_manifest(tree) do
    with {:ok, body} <- File.read(Path.join(tree, "plugin.json")),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(body) do
      {:ok, manifest}
    else
      {:ok, _non_map} -> {:error, :manifest_not_object}
      {:error, %Jason.DecodeError{}} -> {:error, :manifest_invalid_json}
      {:error, :enoent} -> {:error, :manifest_missing}
      other -> other
    end
  end

  defp host_target do
    case Manifest.target_for_host() do
      {:ok, {os, arch}} -> {:ok, "#{os}-#{arch}"}
      {:error, reason} -> {:error, {:host_unsupported, reason}}
    end
  end

  defp resolve_root(opts) do
    Keyword.get(opts, :root) || ConfigStore.workspace_paths().plugins
  end
end
