defmodule FermixCore.Sandbox.PathPolicy do
  @moduledoc """
  Path resolution and containment checks for sandbox-owned operations.
  """

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Mode

  @protected_home_dirs ~w(.ssh .aws .gnupg .docker .kube .codex .anthropic)
  @os_roots ~w(/etc /usr /bin /sbin /System /Library)

  @spec resolve_working_dir(String.t() | nil, Config.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_working_dir(nil, config, context) when is_map(context) do
    base = Map.get(context, :cwd)

    if is_binary(base) and allowed_path?(base, config) == :ok do
      {:ok, Path.expand(base)}
    else
      {:ok, Mode.default_working_dir(config)}
    end
  end

  def resolve_working_dir(dir, config, _context) when is_binary(dir) do
    with {:ok, resolved} <- resolve(dir, Mode.default_working_dir(config)),
         :ok <- allowed_path?(resolved, config),
         true <- File.dir?(resolved) do
      {:ok, resolved}
    else
      false -> {:error, {:missing_working_dir, dir}}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_working_dir(_dir, _config, _context), do: {:error, :invalid_working_dir}

  @spec resolve_write_path(String.t(), Config.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_write_path(path, config, context) when is_binary(path),
    do: resolve_constrained_path(path, config, context)

  def resolve_write_path(_path, _config, _context), do: {:error, :invalid_path}

  @spec resolve_read_path(String.t(), Config.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_read_path(path, config, context) when is_binary(path),
    do: resolve_constrained_path(path, config, context)

  def resolve_read_path(_path, _config, _context), do: {:error, :invalid_path}

  defp resolve_constrained_path(path, config, context) do
    with {:ok, base} <- resolve_working_dir(Map.get(context, :cwd), config, context),
         {:ok, resolved} <- resolve(path, base),
         :ok <- allowed_path?(resolved, config) do
      {:ok, resolved}
    end
  end

  @spec allowed_path?(String.t(), Config.t()) :: :ok | {:error, term()}
  def allowed_path?(path, config) when is_binary(path) do
    expanded = canonical_path(path)

    cond do
      protected_path?(expanded, config) -> {:error, {:protected_path, expanded}}
      blocked_path?(expanded, config.blocked_roots) -> {:error, {:blocked_root, expanded}}
      under_effective_root?(expanded, config) -> :ok
      true -> {:error, {:outside_root, expanded}}
    end
  end

  def allowed_path?(_path, _config), do: {:error, :invalid_path}

  @spec protected_paths(Config.t()) :: [String.t()]
  def protected_paths(config) do
    home = config.home
    fermix_home = fermix_home()

    (@os_roots ++
       Enum.map(@protected_home_dirs, &Path.join(home, &1)) ++
       [
         Path.join(fermix_home, "config.toml"),
         Path.join(fermix_home, "config.toml.pre-m5"),
         Path.join(fermix_home, "auth.json"),
         Path.join(fermix_home, "grants"),
         Path.join(fermix_home, "logs"),
         Path.join(fermix_home, "traces"),
         Path.join(fermix_home, "memory.db"),
         Path.join(fermix_home, "daemon.sock")
       ])
    |> Enum.map(&canonical_path/1)
  end

  @spec canonical_path(String.t()) :: String.t()
  def canonical_path(path) when is_binary(path) do
    case resolve(path, "/") do
      {:ok, resolved} -> resolved
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp resolve(path, base) do
    path
    |> expand_path(base)
    |> resolve_components(64)
  end

  defp expand_path("~", _base), do: System.user_home!()
  defp expand_path("~/" <> rest, _base), do: Path.join(System.user_home!(), rest)
  defp expand_path("/" <> _rest = path, _base), do: Path.expand(path)
  defp expand_path(path, base), do: Path.expand(path, base)

  defp resolve_components(path, 0), do: {:error, {:too_many_symlinks, path}}

  defp resolve_components(path, hops_left) do
    parts = Path.expand(path) |> Path.split()
    resolve_parts("/", Enum.drop(parts, 1), hops_left)
  end

  defp resolve_parts(current, [], _hops_left), do: {:ok, current}

  defp resolve_parts(current, [part | rest], hops_left) do
    next = join_part(current, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} -> resolve_symlink(next, rest, hops_left)
      {:ok, _stat} -> resolve_parts(next, rest, hops_left)
      {:error, :enoent} -> {:ok, append_parts(next, rest)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_symlink(path, rest, hops_left) do
    with {:ok, target} <- File.read_link(path) do
      target
      |> symlink_target(Path.dirname(path))
      |> append_parts(rest)
      |> resolve_components(hops_left - 1)
    end
  end

  defp symlink_target("/" <> _rest = target, _parent), do: target
  defp symlink_target(target, parent), do: Path.expand(target, parent)

  defp append_parts(path, parts), do: Enum.reduce(parts, path, &Path.join(&2, &1))
  defp join_part("/", part), do: "/" <> part
  defp join_part(path, part), do: Path.join(path, part)

  defp protected_path?(path, config) do
    Enum.any?(protected_paths(config), &inside_or_equal?(path, &1))
  end

  defp blocked_path?(path, blocked_roots) do
    Enum.any?(blocked_roots, &inside_or_equal?(path, &1))
  end

  defp under_effective_root?(path, config) do
    config
    |> Mode.effective_roots()
    |> Enum.any?(&inside_or_equal?(path, &1))
  end

  defp inside_or_equal?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end
end
