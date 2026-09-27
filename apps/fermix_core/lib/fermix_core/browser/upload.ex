defmodule FermixCore.Browser.Upload do
  @moduledoc """
  The one rule for a file the `browser` tool puts into a page's file input: it
  is a regular file inside the Fermix workspace, whichever backend uploads it.
  """

  alias FermixCore.Browser.Error
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.ConfigStore

  @doc """
  The upload's real location, or why it is refused.

  Containment is decided on RESOLVED paths, both sides. `Path.expand/1` is
  purely lexical, so a symlinked final component — or any symlinked
  intermediate directory — used to satisfy the prefix test while pointing the
  upload at a file outside the workspace. `PathPolicy.canonical_path/1` walks
  every component and follows the links, so the string compare below is a
  compare of real locations.

  Deliberately NOT routed through `Sandbox.read_path/3`: that helper confines
  to `Mode.effective_roots/2` (workspace + launch cwd + request cwd + grants),
  which would WIDEN the upload surface past workspace-only, and it needs a tool
  context a backend does not thread.
  """
  @spec confined_path(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def confined_path(path) when is_binary(path) do
    canonical = PathPolicy.canonical_path(path)

    workspace_root =
      ConfigStore.workspace_paths() |> Map.fetch!(:workspace) |> PathPolicy.canonical_path()

    with :ok <- under_root(canonical, workspace_root),
         true <- File.regular?(canonical) do
      {:ok, canonical}
    else
      false -> {:error, Error.new("upload_not_found", "Upload file was not found")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def confined_path(_path), do: {:error, Error.new("missing_arg", "upload requires path")}

  defp under_root(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, Error.new("upload_blocked", "Upload path is outside the Fermix workspace")}
    end
  end
end
