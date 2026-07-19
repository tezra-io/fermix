defmodule FermixCore.Tools.FileEdit do
  @moduledoc """
  Replace one unique string anchor in a file.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox
  alias FermixCore.Tools.Support

  @impl true
  def name, do: "file_edit"

  @impl true
  def description,
    do: "Replace a unique anchor string in a file using an atomic tmp+rename write."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path", "old_string", "new_string"],
      properties: %{
        path: %{type: "string", description: "Path to the file to edit."},
        old_string: %{type: "string", description: "Unique string anchor to replace."},
        new_string: %{type: "string", description: "Replacement string."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Edit a file by replacing exactly one known anchor string."

  @impl true
  def examples do
    [
      %{
        args: %{"path" => "README.md", "old_string" => "old", "new_string" => "new"},
        note: "surgically replace one unique string"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_found", description: "old_string does not appear in the file"},
      %{tag: "not_unique", description: "old_string appears more than once"},
      %{tag: "invalid_path", description: "path is blank, traversing, or contains null bytes"},
      %{tag: "write_failed", description: "atomic replacement failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :file

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, path} <- Support.required_string(args, "path"),
         {:ok, old_string} <- Support.required_string(args, "old_string"),
         {:ok, new_string} <- Map.fetch(args, "new_string"),
         :ok <- validate_args(path, old_string, new_string),
         {:ok, resolved_path} <- Sandbox.write_path(path, :file_edit, context),
         {:ok, content} <- File.read(resolved_path),
         {:ok, updated} <- replace_unique(content, old_string, new_string),
         :ok <- atomic_write(resolved_path, updated) do
      {:ok, Tool.success("Replaced unique anchor in #{resolved_path}")}
    else
      :error -> Support.error("Missing required parameter: new_string")
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, :enoent} -> Support.error("File not found")
      {:error, reason} -> Support.error(format_error(reason))
    end
  end

  defp validate_args(path, old_string, new_string) when is_binary(new_string) do
    with :ok <- Support.validate_path(path) do
      if old_string == "", do: {:error, "old_string must be non-empty"}, else: :ok
    end
  end

  defp validate_args(_path, _old_string, _new_string), do: {:error, "new_string must be a string"}

  defp replace_unique(content, old_string, new_string) do
    parts = String.split(content, old_string)

    case length(parts) - 1 do
      0 -> {:error, "old_string not found"}
      1 -> {:ok, Enum.join(parts, new_string)}
      count -> {:error, "old_string is not unique; found #{count} occurrences"}
    end
  end

  defp atomic_write(path, content) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with {:ok, stat} <- File.stat(path),
         :ok <- File.write(tmp, content),
         :ok <- File.chmod(tmp, stat.mode),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp format_error({:outside_root, path}) do
    "Sandbox denied file_edit outside roots: #{path}. " <>
      "To allow this directory, run: fermix grant path #{Path.dirname(path)}, " <>
      "or call the request_directory_access tool to ask the owner to approve it."
  end

  defp format_error({:protected_path, path}),
    do: "Sandbox denied protected path: #{path}. Run: fermix sandbox explain"

  defp format_error({:blocked_root, path}),
    do: "Sandbox denied blocked root: #{path}. Run: fermix sandbox explain"

  defp format_error(reason), do: "file_edit failed: #{inspect(reason)}"
end
