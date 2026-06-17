defmodule FermixCore.Plugins.Dist.SafeRm do
  @moduledoc """
  Fail-closed removal guard for the plugin store. Production counterpart of the
  test-only `FermixTestSupport.SafeRm`: every uninstall/gc/staging-cleanup
  routes through here so a computed path can never escape the store and delete
  something it shouldn't (the CLAUDE.md SafeRm discipline applied to the new
  download surface).

  A target is removable only when it is **strictly under** the given plugins
  root, contains no `..` component, and resolves to at least #{5} path
  segments — so the root itself, a parent, or a root-ish path is always
  rejected.
  """

  @min_segments 5

  @doc "Remove `path` (recursively) only if it passes the store guard against `root`."
  @spec rm_rf(Path.t(), Path.t()) :: :ok | {:error, term()}
  def rm_rf(path, root) do
    with {:ok, checked} <- check(path, root),
         {:ok, _removed} <- File.rm_rf(checked) do
      :ok
    else
      {:error, reason, failed} -> {:error, {reason, failed}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Validate (without removing) that `path` is a safe removal target under `root`."
  @spec check(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def check(path, root) when is_binary(path) and path != "" and is_binary(root) and root != "" do
    expanded = Path.expand(path)
    root_expanded = Path.expand(root)

    cond do
      String.contains?(path, "..") -> {:error, {:traversal, path}}
      not under?(expanded, root_expanded) -> {:error, {:outside_plugins_root, expanded}}
      length(Path.split(expanded)) < @min_segments -> {:error, {:too_shallow, expanded}}
      true -> {:ok, expanded}
    end
  end

  def check(_path, _root), do: {:error, :invalid_path}

  # Strictly under (never equal) — removing the root itself is rejected.
  defp under?(path, root), do: String.starts_with?(path, root <> "/")
end
