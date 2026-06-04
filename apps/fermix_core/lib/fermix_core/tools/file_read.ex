defmodule FermixCore.Tools.FileRead do
  @moduledoc """
  Read file contents. Supports offset/limit for large files.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

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
  def when_to_use, do: "Read file contents from a known path with optional line bounds."

  @impl true
  def examples,
    do: [%{args: %{"path" => "README.md", "limit" => 80}, note: "read the top of a file"}]

  @impl true
  def failure_modes do
    [
      %{tag: "missing_path", description: "path is absent or blank"},
      %{tag: "not_found", description: "file does not exist"},
      %{tag: "invalid_path", description: "path contains traversal or null bytes"}
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
    result = do_execute(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("file_read", context, success, duration, input: args, result: result)

    result
  end

  defp do_execute(args, context) do
    with {:ok, path} <- Map.fetch(args, "path"),
         :ok <- validate_input_path(path),
         {:ok, resolved} <- Sandbox.read_path(path, :file_read, context) do
      read_resolved(resolved, args)
    else
      :error ->
        {:ok, Tool.error("Missing required parameter: path")}

      {:error, reason} when is_binary(reason) ->
        {:ok, Tool.error(reason)}

      {:error, reason} ->
        {:ok, Tool.error(format_sandbox_reason(reason))}
    end
  end

  defp read_resolved(path, args) do
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit")

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        sliced = slice_lines(lines, offset, limit)
        {:ok, Tool.success(Enum.join(sliced, "\n"))}

      {:error, :enoent} ->
        {:ok, Tool.error("File not found: #{path}")}

      {:error, :eisdir} ->
        {:ok, Tool.error("Path is a directory: #{path}")}

      {:error, reason} ->
        {:ok, Tool.error("Failed to read file: #{inspect(reason)}")}
    end
  end

  defp validate_input_path(path) when is_binary(path) and byte_size(path) > 0 do
    if String.contains?(path, "\0"),
      do: {:error, "Path contains null bytes"},
      else: :ok
  end

  defp validate_input_path(_), do: {:error, "Path must be a non-empty string"}

  defp format_sandbox_reason({:protected_path, path}),
    do: "Path is protected by the sandbox: #{path}"

  defp format_sandbox_reason({:outside_root, path}),
    do: "Path is outside the sandbox roots: #{path}"

  defp format_sandbox_reason({:blocked_root, path}),
    do: "Path is under a blocked root: #{path}"

  defp format_sandbox_reason({:too_many_symlinks, path}),
    do: "Path resolved through too many symlinks: #{path}"

  defp format_sandbox_reason(reason), do: "Sandbox denied: #{inspect(reason)}"

  defp slice_lines(lines, offset, nil), do: Enum.drop(lines, offset - 1)
  defp slice_lines(lines, offset, limit), do: lines |> Enum.drop(offset - 1) |> Enum.take(limit)
end
