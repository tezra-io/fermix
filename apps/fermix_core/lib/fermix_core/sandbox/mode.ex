defmodule FermixCore.Sandbox.Mode do
  @moduledoc """
  Expands sandbox modes into effective root sets.
  """

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy

  @spec effective_roots(Config.t() | map() | keyword()) :: [String.t()]
  def effective_roots(config), do: effective_roots(config, nil)

  # `request_cwd` is the working directory of the current turn's origin (the dir
  # the owner ran `fermix ask` from), threaded from the tool context. Standard
  # mode admits it as a root when it is a real directory strictly inside the OS
  # home, so the agent "works where you are" without a grant. `os_home` itself is
  # never admitted (that would silently widen standard to all of $HOME — the
  # exact grant `ConfigMutation` refuses). Open mode's `os_home` root already
  # covers it and strict never admits it. Candidate roots are canonicalized
  # (symlink-resolved) before the containment and blocked-root gates, so a
  # request cwd that is a symlink escaping the OS home cannot be admitted, and a
  # blocked directory cannot be re-admitted through the request cwd.
  @spec effective_roots(Config.t() | map() | keyword(), String.t() | nil) :: [String.t()]
  def effective_roots(config, request_cwd) do
    config = Config.normalize(config)

    (mode_roots(config) ++ request_roots(config, request_cwd) ++ config.allowed_roots)
    |> Enum.map(&canonical_dir/1)
    |> reject_blocked(config.blocked_roots)
    |> Enum.uniq()
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

  @typedoc "Where an effective root came from: `:granted` (config `allowed_roots`) vs `:mode` (workspace / launch cwd / request cwd / os_home)."
  @type provenance :: :granted | :mode

  @spec root_provenance(Config.t() | map() | keyword()) :: [{String.t(), provenance()}]
  def root_provenance(config), do: root_provenance(config, nil)

  # Annotate each effective root by provenance so the owner can tell an explicit
  # grant from an automatic mode root. Both `allowed_roots` and the effective
  # roots are compared in canonical (symlink-resolved) form — a raw config value
  # can differ from its effective form only by a symlinked prefix, so a string
  # compare against the unresolved config would mislabel a granted root as mode.
  @spec root_provenance(Config.t() | map() | keyword(), String.t() | nil) ::
          [{String.t(), provenance()}]
  def root_provenance(config, request_cwd) do
    config = Config.normalize(config)
    granted = MapSet.new(config.allowed_roots, &canonical_dir/1)

    config
    |> effective_roots(request_cwd)
    |> Enum.map(fn root -> {root, provenance(root, granted)} end)
  end

  defp provenance(root, granted) do
    if MapSet.member?(granted, root), do: :granted, else: :mode
  end

  defp mode_roots(%Config{mode: :strict} = config), do: [config.workspace_root]
  defp mode_roots(%Config{mode: :open} = config), do: [config.os_home]

  defp mode_roots(%Config{mode: :standard} = config) do
    [config.workspace_root, launch_root(config.os_home)]
    |> Enum.reject(&is_nil/1)
  end

  defp request_roots(%Config{mode: :standard, os_home: os_home}, request_cwd)
       when is_binary(request_cwd) do
    canonical = canonical_dir(request_cwd)

    if File.dir?(canonical) and strictly_under_home?(canonical, os_home),
      do: [canonical],
      else: []
  end

  defp request_roots(_config, _request_cwd), do: []

  defp launch_root(os_home) do
    launch = canonical_dir(launch_cwd())

    if strictly_under_home?(launch, os_home), do: launch, else: nil
  end

  defp reject_blocked(roots, blocked_roots) do
    blocked = Enum.map(blocked_roots, &canonical_dir/1)

    Enum.reject(roots, fn root ->
      Enum.any?(blocked, &inside_or_equal?(root, &1))
    end)
  end

  defp canonical_dir(path) do
    PathPolicy.canonical_path(path)
  end

  # Strictly inside the OS home — `os_home` itself is excluded so admitting the
  # request/launch cwd can never widen standard mode to all of $HOME. Both
  # operands are canonical (symlink-resolved) so a symlinked cwd cannot escape.
  defp strictly_under_home?(path, home) do
    home = canonical_dir(home)
    path != home and String.starts_with?(path, home <> "/")
  end

  defp allowed_root?(path, roots), do: Enum.any?(roots, &inside_or_equal?(path, &1))
  defp inside_or_equal?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp launch_cwd do
    Application.get_env(:fermix_core, :sandbox_launch_cwd, File.cwd!())
  end
end
