defmodule FermixCore.Tools.FileWrite do
  @moduledoc """
  Write content to a file. Creates parent directories if needed.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool

  @impl true
  @spec name() :: String.t()
  def name, do: "file_write"

  @impl true
  @spec description() :: String.t()
  def description do
    "Write content to a file. Creates the file if it doesn't exist, overwrites if it does."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["path", "content"],
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to write"
        },
        content: %{
          type: "string",
          description: "Content to write to the file"
        },
        mkdir: %{
          type: "boolean",
          description: "Create parent directories if they don't exist (default: true)"
        }
      }
    }
  end

  @impl true
  def when_to_use, do: "Write or overwrite a file when replacing the full contents is intended."

  @impl true
  def examples do
    [%{args: %{"path" => "notes.txt", "content" => "hello"}, note: "write a complete file"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "path or content is absent"},
      %{tag: "invalid_path", description: "path contains traversal or null bytes"},
      %{tag: "write_failed", description: "filesystem write failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :file

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")

    result = do_execute(args)

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{tool: "file_write", agent: agent, success: success}
    )

    result
  end

  defp do_execute(args) do
    with {:ok, path} <- Map.fetch(args, "path"),
         {:ok, content} <- Map.fetch(args, "content"),
         :ok <- validate_path(path),
         :ok <- maybe_mkdir(Map.get(args, "mkdir", true), path),
         :ok <- File.write(path, content) do
      {:ok, Tool.success("Wrote #{byte_size(content)} bytes to #{path}")}
    else
      :error -> {:ok, Tool.error("Missing required parameters: path and content")}
      {:error, reason} when is_binary(reason) -> {:ok, Tool.error(reason)}
      {:error, reason} -> {:ok, Tool.error("Failed to write file: #{inspect(reason)}")}
    end
  end

  defp maybe_mkdir(false, _path), do: :ok

  defp maybe_mkdir(true, path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create directories: #{inspect(reason)}"}
    end
  end

  defp validate_path(path) when is_binary(path) and byte_size(path) > 0 do
    cond do
      String.contains?(path, "\0") ->
        {:error, "Path contains null bytes"}

      has_traversal_component?(path) ->
        {:error, "Path traversal is not allowed"}

      true ->
        :ok
    end
  end

  defp validate_path(_), do: {:error, "Path must be a non-empty string"}

  defp has_traversal_component?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end
end
