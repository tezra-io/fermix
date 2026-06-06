defmodule FermixCore.Tools.FileRead do
  @moduledoc """
  Read file contents. Supports offset/limit for large files.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @max_output_bytes 100_000

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
          minimum: 1,
          description: "Line number to start reading from (1-indexed, default: 1)"
        },
        limit: %{
          type: "integer",
          minimum: 1,
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
      %{tag: "invalid_path", description: "path contains traversal or null bytes"},
      %{tag: "invalid_range", description: "offset or limit is not a positive integer"}
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
    with {:ok, offset} <- validate_range_arg(args, "offset", 1),
         {:ok, limit} <- validate_range_arg(args, "limit", nil),
         :ok <- validate_readable(path) do
      stream_slice(path, offset || 1, limit)
    else
      {:error, message} -> {:ok, Tool.error(message)}
    end
  end

  defp validate_range_arg(args, key, default) do
    case Map.get(args, key, default) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value >= 1 ->
        {:ok, value}

      value ->
        {:error, "#{key} must be a positive integer (1-indexed), got: #{inspect(value)}"}
    end
  end

  defp validate_readable(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "Path is a directory: #{path}"}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  # Streams the line range instead of loading the whole file. Output is
  # capped at @max_output_bytes: a capped read succeeds with a marker that
  # names the offset to continue from; a single line that alone exceeds
  # the cap is an explicit error rather than a partial slice.
  defp stream_slice(path, offset, limit) do
    path
    |> File.stream!()
    |> Stream.drop(offset - 1)
    |> bounded(limit)
    |> Enum.reduce_while(%{lines: [], bytes: 0, line: offset, truncated_at: nil}, &collect_line/2)
    |> render_slice()
  rescue
    error in File.Error ->
      {:ok, Tool.error("Failed to read file: #{inspect(error.reason)}")}
  end

  defp bounded(stream, nil), do: stream
  defp bounded(stream, limit), do: Stream.take(stream, limit)

  defp collect_line(raw, acc) do
    line = strip_newline(raw)
    new_bytes = acc.bytes + byte_size(line) + 1

    if new_bytes > @max_output_bytes do
      {:halt, %{acc | truncated_at: acc.line}}
    else
      {:cont, %{acc | lines: [line | acc.lines], bytes: new_bytes, line: acc.line + 1}}
    end
  end

  defp render_slice(%{lines: [], truncated_at: line}) when is_integer(line) do
    {:ok, Tool.error("Line #{line} alone exceeds the #{@max_output_bytes}-byte output cap")}
  end

  defp render_slice(%{lines: lines, truncated_at: nil}) do
    {:ok, Tool.success(join_lines(lines))}
  end

  defp render_slice(%{lines: lines, truncated_at: line}) do
    output =
      join_lines(lines) <>
        "\n[truncated at #{@max_output_bytes} bytes — continue with offset #{line}]"

    {:ok, Tool.success(output)}
  end

  defp join_lines(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  defp strip_newline(raw) do
    if String.ends_with?(raw, "\n") do
      binary_part(raw, 0, byte_size(raw) - 1)
    else
      raw
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
end
