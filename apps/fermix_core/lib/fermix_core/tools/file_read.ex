defmodule FermixCore.Tools.FileRead do
  @moduledoc """
  Read file contents. Supports offset/limit for large files.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool

  @impl true
  @spec name() :: String.t()
  def name, do: "file_read"

  @impl true
  @spec description() :: String.t()
  def description do
    "Read the contents of a file. Supports line offset and limit for large files."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to read"
        },
        offset: %{
          type: "integer",
          description: "Line number to start reading from (1-indexed, default: 1)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of lines to read (default: all)"
        }
      }
    }
  end

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
      %{tool: "file_read", agent: agent, success: success}
    )

    result
  end

  defp do_execute(args) do
    with {:ok, path} <- Map.fetch(args, "path") do
      offset = Map.get(args, "offset", 1)
      limit = Map.get(args, "limit")

      with :ok <- validate_path(path),
           {:ok, content} <- File.read(path) do
        lines = String.split(content, "\n")
        sliced = slice_lines(lines, offset, limit)
        {:ok, Tool.success(Enum.join(sliced, "\n"))}
      else
        {:error, :enoent} ->
          {:ok, Tool.error("File not found: #{path}")}

        {:error, :eisdir} ->
          {:ok, Tool.error("Path is a directory: #{path}")}

        {:error, reason} when is_binary(reason) ->
          {:ok, Tool.error(reason)}

        {:error, reason} ->
          {:ok, Tool.error("Failed to read file: #{inspect(reason)}")}
      end
    else
      :error -> {:ok, Tool.error("Missing required parameter: path")}
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

  defp slice_lines(lines, offset, nil), do: Enum.drop(lines, offset - 1)
  defp slice_lines(lines, offset, limit), do: lines |> Enum.drop(offset - 1) |> Enum.take(limit)
end
