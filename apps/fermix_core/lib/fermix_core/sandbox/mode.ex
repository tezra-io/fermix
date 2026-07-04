defmodule FermixCore.Sandbox.Mode do
  @moduledoc """
  Expands sandbox modes into effective root sets.
  """

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy

  @common_project_dirs ~w(projects src code work dev)

  @spec effective_roots(Config.t() | map() | keyword()) :: [String.t()]
  def effective_roots(config) do
    config = Config.normalize(config)

    config
    |> mode_roots()
    |> Kernel.++(config.allowed_roots)
    |> reject_blocked(config.blocked_roots)
    |> uniq_existing_or_configured()
  end

  @spec default_working_dir(Config.t() | map() | keyword()) :: String.t()
  def default_working_dir(config) do
    default_working_dir(config, effective_roots(config))
  end

  # Precomputed-roots variant: the caller already resolved `effective_roots`
  # once for this operation and threads it in, so a single `working_dir`/path
  # check does not re-run the effective-root filesystem walk. Byte-identical to
  # the self-computing arity when given that arity's own `effective_roots`.
  @spec default_working_dir(Config.t() | map() | keyword(), [String.t()]) :: String.t()
  def default_working_dir(config, effective_roots) when is_list(effective_roots) do
    config = Config.normalize(config)
    launch = launch_cwd()

    cond do
      allowed_root?(launch, effective_roots) -> launch
      File.dir?(config.workspace_root) -> config.workspace_root
      true -> hd(effective_roots)
    end
  end

  defp mode_roots(%Config{mode: :strict} = config), do: [config.workspace_root]
  defp mode_roots(%Config{mode: :open} = config), do: [config.home]

  defp mode_roots(%Config{mode: :standard} = config) do
    [config.workspace_root, launch_root(config.home) | common_project_roots(config.home)]
    |> Enum.reject(&is_nil/1)
  end

  defp launch_root(home) do
    launch = launch_cwd()

    if under_home?(launch, home), do: launch, else: nil
  end

  defp common_project_roots(home) do
    home
    |> then(fn root -> Enum.map(@common_project_dirs, &Path.join(root, &1)) end)
    |> Enum.filter(&File.dir?/1)
  end

  defp reject_blocked(roots, blocked_roots) do
    Enum.reject(roots, fn root ->
      Enum.any?(blocked_roots, &inside_or_equal?(root, &1))
    end)
  end

  defp uniq_existing_or_configured(roots) do
    roots
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&canonical_dir/1)
    |> Enum.uniq()
  end

  defp canonical_dir(path) do
    PathPolicy.canonical_path(path)
  end

  defp under_home?(path, home), do: inside_or_equal?(Path.expand(path), Path.expand(home))
  defp allowed_root?(path, roots), do: Enum.any?(roots, &inside_or_equal?(path, &1))
  defp inside_or_equal?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp launch_cwd do
    Application.get_env(:fermix_core, :sandbox_launch_cwd, File.cwd!())
  end
end
