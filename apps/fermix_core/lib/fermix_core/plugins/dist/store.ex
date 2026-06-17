defmodule FermixCore.Plugins.Dist.Store do
  @moduledoc """
  The on-disk plugin store under `$FERMIX_HOME/plugins`: the versioned
  `installed/<name>/<version>` trees, the `current` symlink that is the only
  pointer the runtime reads through, and the `installed.json` lockfile
  (`name -> {version, sha256, h1, plugin_api, verified_at}`).

  All paths take an explicit `root` so the store is testable against a tmp dir.
  Activation is atomic (rename the staged tree into place, then flip the symlink
  via a renamed temp link). Compatibility (`plugin_api` window + `min_core_version`
  floor, §13) is checked here, at install and at every `list/2`.
  """

  alias FermixCore.Plugins.Dist.SafeRm

  # The manifest/interpreter contract generation this core understands, with
  # exactly one generation of back-compat (§13).
  @supported_plugin_api 2
  @min_supported_plugin_api @supported_plugin_api - 1

  @type entry :: %{
          optional(String.t()) => term()
        }

  @doc "Resolve the store's paths under `root`."
  @spec paths(Path.t()) :: %{
          root: Path.t(),
          installed: Path.t(),
          staging: Path.t(),
          run: Path.t(),
          lock: Path.t(),
          lockfile: Path.t()
        }
  def paths(root) when is_binary(root) do
    %{
      root: root,
      installed: Path.join(root, "installed"),
      staging: Path.join(root, ".staging"),
      run: Path.join(root, "run"),
      lock: Path.join(root, ".lock"),
      lockfile: Path.join(root, "installed.json")
    }
  end

  @doc "Create the store directory skeleton (idempotent). `run/` is created 0700."
  @spec ensure!(Path.t()) :: :ok
  def ensure!(root) do
    p = paths(root)
    File.mkdir_p!(p.installed)
    File.mkdir_p!(p.staging)
    File.mkdir_p!(p.run)
    _ = File.chmod(p.run, 0o700)
    :ok
  end

  @doc "GC `.staging/*` and `run/*.token` on boot — a crashed run must not leak."
  @spec sweep_transient!(Path.t()) :: :ok
  def sweep_transient!(root) do
    p = paths(root)
    each_child(p.staging, fn child -> SafeRm.rm_rf(child, root) end)

    each_child(p.run, fn child ->
      if String.ends_with?(child, ".token"), do: SafeRm.rm_rf(child, root)
    end)

    :ok
  end

  # --- installed.json lockfile ---

  @doc """
  Read the lockfile. An absent lockfile is `%{}` (no plugins installed yet — a
  valid empty state). A **present but corrupt** lockfile raises: it is a real
  fault, not an empty state, and silently treating it as `%{}` would erase the
  record of every installed plugin (and let `record/2` overwrite a fresh file).
  """
  @spec installed(Path.t()) :: %{String.t() => entry()}
  def installed(root) do
    path = paths(root).lockfile

    case File.read(path) do
      {:error, _} -> %{}
      {:ok, body} -> decode_lockfile!(path, body)
    end
  end

  defp decode_lockfile!(path, body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        map

      {:ok, other} ->
        raise "corrupt plugin lockfile at #{path}: expected an object, got #{inspect(other)}"

      {:error, err} ->
        raise "corrupt plugin lockfile at #{path}: #{Exception.message(err)}"
    end
  end

  @doc "Record `entry` under `name` in the lockfile (atomic write)."
  @spec record(Path.t(), String.t(), entry()) :: :ok | {:error, term()}
  def record(root, name, entry) when is_binary(name) and is_map(entry) do
    write_lockfile(root, Map.put(installed(root), name, entry))
  end

  @doc "Drop `name` from the lockfile."
  @spec forget(Path.t(), String.t()) :: :ok | {:error, term()}
  def forget(root, name) when is_binary(name) do
    write_lockfile(root, Map.delete(installed(root), name))
  end

  # --- version dirs + active symlink ---

  @spec version_dir(Path.t(), String.t(), String.t()) :: Path.t()
  def version_dir(root, name, version), do: Path.join([paths(root).installed, name, version])

  @spec current_link(Path.t(), String.t()) :: Path.t()
  def current_link(root, name), do: Path.join([paths(root).installed, name, "current"])

  @doc "The version the `current` symlink points at, or nil."
  @spec active_version(Path.t(), String.t()) :: String.t() | nil
  def active_version(root, name) do
    case File.read_link(current_link(root, name)) do
      {:ok, target} -> Path.basename(target)
      {:error, _} -> nil
    end
  end

  @doc """
  Atomically install a staged, already-verified tree as `version` of `name`:
  rename the staging dir into `installed/<name>/<version>`, then flip `current`.
  Fails loud on a cross-filesystem rename (`:exdev`) — no copy fallback.
  """
  @spec install_tree(Path.t(), String.t(), String.t(), Path.t()) :: :ok | {:error, term()}
  def install_tree(root, name, version, staged_dir) do
    dest = version_dir(root, name, version)
    File.mkdir_p!(Path.dirname(dest))

    with :ok <- rename_into_place(staged_dir, dest, root) do
      activate(root, name, version)
    end
  end

  @doc """
  Flip `current` to point at `version` (atomic: write `current.tmp`, rename
  over). Refuses if the version dir is absent, so a crash that left the tree
  missing never produces a `current` symlink to a void target.
  """
  @spec activate(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def activate(root, name, version) do
    if File.dir?(version_dir(root, name, version)) do
      do_activate(root, name, version)
    else
      {:error, {:version_dir_missing, name, version}}
    end
  end

  defp do_activate(root, name, version) do
    link = current_link(root, name)
    tmp = link <> ".tmp"
    _ = File.rm(tmp)

    with :ok <- File.ln_s(version, tmp),
         :ok <- File.rename(tmp, link) do
      :ok
    else
      {:error, reason} -> {:error, {:activate_failed, reason}}
    end
  end

  # Fresh version: `dest` is absent, so this is a single atomic rename. A
  # `--force` reinstall of an existing version replaces it WITHOUT destroying
  # the old tree first: move the old aside, rename the new into place, then drop
  # the old. A crash mid-swap leaves the old tree recoverable at the aside path
  # (never a window where the valid old install is simply gone).
  defp rename_into_place(staged_dir, dest, root) do
    aside = aside_path(dest)
    _ = SafeRm.rm_rf(aside, root)

    if File.exists?(dest),
      do: replace_existing(staged_dir, dest, aside, root),
      else: do_rename(staged_dir, dest)
  end

  defp replace_existing(staged_dir, dest, aside, root) do
    with :ok <- do_rename(dest, aside),
         :ok <- do_rename(staged_dir, dest) do
      _ = SafeRm.rm_rf(aside, root)
      :ok
    end
  end

  defp do_rename(src, dst) do
    case File.rename(src, dst) do
      :ok -> :ok
      {:error, :exdev} -> {:error, :plugins_dir_spans_filesystems}
      {:error, reason} -> {:error, {:install_rename_failed, reason}}
    end
  end

  # Leading dot so `version_dirs/2` (which globs `*`) never treats it as a
  # version, and it is invisible to the runtime.
  defp aside_path(dest),
    do: Path.join(Path.dirname(dest), "." <> Path.basename(dest) <> ".replacing")

  # --- h1 content hash (Terraform's unpacked-tree hash) ---

  @doc """
  SHA-256 over the sorted relative file list + contents of `dir`. A re-tar, a
  mirror copy, and the original all hash identically; offline re-verification
  reads this instead of re-shelling cosign.
  """
  @spec h1(Path.t()) :: String.t()
  def h1(dir) do
    dir
    |> files_sorted()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn rel, acc ->
      acc
      |> :crypto.hash_update(rel)
      |> :crypto.hash_update(File.read!(Path.join(dir, rel)))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp files_sorted(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  # --- compatibility (§13) ---

  @doc "The plugin-API generation this core implements."
  @spec supported_plugin_api() :: pos_integer()
  def supported_plugin_api, do: @supported_plugin_api

  @doc """
  Whether a version's `plugin_api` + `min_core_version` are compatible with the
  running core. Fail-closed with a specific, actionable reason.
  """
  @spec compatible?(map(), String.t()) :: :ok | {:error, term()}
  def compatible?(version_entry, core_version \\ core_version()) do
    with :ok <-
           check_plugin_api(
             Map.get(version_entry, :plugin_api) || Map.get(version_entry, "plugin_api")
           ) do
      check_min_core(
        Map.get(version_entry, :min_core_version) || Map.get(version_entry, "min_core_version"),
        core_version
      )
    end
  end

  defp check_plugin_api(api) when is_integer(api) do
    cond do
      api > @supported_plugin_api -> {:error, {:needs_newer_core, :plugin_api, api}}
      api < @min_supported_plugin_api -> {:error, {:plugin_too_old, :plugin_api, api}}
      true -> :ok
    end
  end

  defp check_plugin_api(_other), do: {:error, :missing_plugin_api}

  defp check_min_core(nil, _core), do: :ok

  defp check_min_core(min_core, core_version) when is_binary(min_core) do
    with {:ok, floor} <- Version.parse(min_core),
         {:ok, core} <- Version.parse(core_version) do
      if Version.compare(core, floor) == :lt,
        do: {:error, {:needs_newer_core, :min_core_version, min_core}},
        else: :ok
    else
      :error -> {:error, {:invalid_version, min_core, core_version}}
    end
  end

  @doc "Running core version string (`Application.spec(:fermix_core, :vsn)`)."
  @spec core_version() :: String.t()
  def core_version, do: :fermix_core |> Application.spec(:vsn) |> to_string()

  # --- list (re-validate installed compat at load, §13) ---

  @doc """
  List installed plugins with a runtime status: `:ready` or `:incompatible`
  (its recorded `plugin_api`/`min_core_version` no longer fits this core — e.g.
  after a `fermix upgrade` moved the support window).
  """
  @spec list(Path.t(), String.t()) :: [
          %{name: String.t(), version: String.t() | nil, status: atom(), reason: term()}
        ]
  def list(root, core_version \\ core_version()) do
    root
    |> installed()
    |> Enum.map(fn {name, entry} -> status_entry(root, name, entry, core_version) end)
    |> Enum.sort_by(& &1.name)
  end

  defp status_entry(root, name, entry, core_version) do
    case compatible?(entry, core_version) do
      :ok ->
        %{name: name, version: active_version(root, name), status: :ready, reason: nil}

      {:error, reason} ->
        %{name: name, version: active_version(root, name), status: :incompatible, reason: reason}
    end
  end

  # --- uninstall + gc (via SafeRm) ---

  @doc "Remove a plugin's whole tree, its lockfile entry, and any legacy seeded skills."
  @spec uninstall(Path.t(), String.t()) :: :ok | {:error, term()}
  def uninstall(root, name) when is_binary(name) do
    with :ok <- SafeRm.rm_rf(Path.join(paths(root).installed, name), root),
         :ok <- rm_legacy_skills(root, name) do
      forget(root, name)
    end
  end

  defp rm_legacy_skills(root, name) do
    legacy = Path.join([root, name, "skills"])
    if File.dir?(legacy), do: SafeRm.rm_rf(Path.join(root, name), root), else: :ok
  end

  @doc """
  GC: remove `.staging/*` and, per plugin, every version dir that is neither the
  active version nor the single most-recent non-active (the one-deep rollback).
  """
  @spec gc(Path.t()) :: :ok
  def gc(root) do
    p = paths(root)
    each_child(p.staging, fn child -> SafeRm.rm_rf(child, root) end)

    each_child(p.installed, fn name_dir ->
      gc_plugin_versions(root, Path.basename(name_dir))
    end)

    :ok
  end

  defp gc_plugin_versions(root, name) do
    active = active_version(root, name)
    versions = version_dirs(root, name)
    keep = Enum.filter([active, rollback(versions, active)], & &1)

    Enum.each(versions, fn v ->
      unless v in keep, do: SafeRm.rm_rf(version_dir(root, name, v), root)
    end)
  end

  defp version_dirs(root, name) do
    Path.join([paths(root).installed, name, "*"])
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    # "current" is the reserved active-pointer symlink, never a version.
    |> Enum.reject(&(&1 == "current"))
  end

  # newest non-active version (the rollback slot), by semver where possible
  defp rollback(versions, active) do
    versions
    |> Enum.reject(&(&1 == active))
    |> Enum.sort(&version_gte/2)
    |> List.first()
  end

  defp version_gte(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
      _ -> a >= b
    end
  end

  # --- helpers ---

  defp write_lockfile(root, map) do
    p = paths(root)
    File.mkdir_p!(p.root)
    tmp = p.lockfile <> ".tmp"

    with :ok <- File.write(tmp, Jason.encode!(map, pretty: true)),
         :ok <- File.rename(tmp, p.lockfile) do
      :ok
    else
      {:error, reason} -> {:error, {:lockfile_write_failed, reason}}
    end
  end

  defp each_child(dir, fun) do
    case File.ls(dir) do
      {:ok, children} -> Enum.each(children, fn c -> fun.(Path.join(dir, c)) end)
      {:error, _} -> :ok
    end
  end
end
