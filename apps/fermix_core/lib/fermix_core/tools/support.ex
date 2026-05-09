defmodule FermixCore.Tools.Support do
  @moduledoc false

  alias FermixCore.Capabilities.Builtin.Tool

  @spec run(String.t(), map(), (-> {:ok, Tool.tool_result()} | {:error, term()})) ::
          {:ok, Tool.tool_result()} | {:error, term()}
  def run(tool_name, context, fun)
      when is_binary(tool_name) and is_map(context) and is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      telemetry_metadata(tool_name, agent, result, success, context)
    )

    result
  end

  @spec success_json(term()) :: {:ok, Tool.tool_result()}
  def success_json(value), do: {:ok, Tool.success(Jason.encode!(value))}

  @spec error(String.t() | term()) :: {:ok, Tool.tool_result()}
  def error(message) when is_binary(message), do: {:ok, Tool.error(message)}
  def error(reason), do: {:ok, Tool.error(inspect(reason))}

  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def required_string(args, key) when is_map(args) and is_binary(key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, "Invalid #{key}"}
      :error -> {:error, "Missing required parameter: #{key}"}
    end
  end

  @spec optional_string(map(), String.t(), String.t() | nil) :: String.t() | nil
  def optional_string(args, key, default \\ nil) do
    case Map.get(args, key, default) do
      nil -> nil
      value when is_binary(value) -> value
      _value -> default
    end
  end

  @spec optional_bool(map(), String.t(), boolean()) :: boolean()
  def optional_bool(args, key, default) do
    case Map.get(args, key, default) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  @spec optional_integer(map(), String.t(), integer(), integer(), integer()) :: integer()
  def optional_integer(args, key, default, min, max) do
    case Map.get(args, key, default) do
      value when is_integer(value) -> value |> Kernel.max(min) |> Kernel.min(max)
      _value -> default
    end
  end

  @spec optional_string_list(map(), String.t()) :: [String.t()]
  def optional_string_list(args, key) do
    case Map.get(args, key, []) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end

  @spec validate_path(String.t()) :: :ok | {:error, String.t()}
  def validate_path(path) when is_binary(path) and byte_size(path) > 0 do
    cond do
      String.contains?(path, "\0") -> {:error, "Path contains null bytes"}
      traversal_component?(path) -> {:error, "Path traversal is not allowed"}
      true -> :ok
    end
  end

  def validate_path(_path), do: {:error, "Path must be a non-empty string"}

  defp traversal_component?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp telemetry_metadata(tool_name, agent, result, success, context) do
    context
    |> tool_trace_metadata()
    |> Map.merge(%{tool: tool_name, agent: agent, success: success})
    |> maybe_put_error(result)
  end

  defp tool_trace_metadata(%{tool_trace: metadata}) when is_map(metadata), do: metadata
  defp tool_trace_metadata(_context), do: %{}

  defp maybe_put_error(metadata, {:ok, %{success: false, error: error}})
       when is_binary(error),
       do: Map.put(metadata, :error, error)

  defp maybe_put_error(metadata, {:error, reason}), do: Map.put(metadata, :error, inspect(reason))
  defp maybe_put_error(metadata, _result), do: metadata
end
