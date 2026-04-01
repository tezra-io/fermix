defmodule FermixCore.Tools.FileWrite do
  @moduledoc """
  Write content to a file. Creates parent directories if needed.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

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
    path = Map.fetch!(args, "path")
    content = Map.fetch!(args, "content")
    mkdir = Map.get(args, "mkdir", true)

    with :ok <- validate_path(path) do
      if mkdir do
        path |> Path.dirname() |> File.mkdir_p!()
      end

      case File.write(path, content) do
        :ok ->
          {:ok, Tool.success("Wrote #{byte_size(content)} bytes to #{path}")}

        {:error, reason} ->
          {:ok, Tool.error("Failed to write file: #{inspect(reason)}")}
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  defp validate_path(path) when is_binary(path) and byte_size(path) > 0 do
    if path_traversal?(path) do
      {:error, "Path traversal is not allowed"}
    else
      :ok
    end
  end

  defp validate_path(_), do: {:error, "Path must be a non-empty string"}

  defp path_traversal?(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
    |> Kernel.or(String.contains?(path, ".."))
  end
end
