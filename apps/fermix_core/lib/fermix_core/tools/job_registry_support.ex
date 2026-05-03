defmodule FermixCore.Tools.JobRegistrySupport do
  @moduledoc false

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Repo

  def run(tool_name, context, fun) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{tool: tool_name, agent: agent, success: success}
    )

    result
  end

  def repo(context), do: Map.get(context, :memory_repo, Repo)

  def success_json(value), do: {:ok, Tool.success(Jason.encode!(value))}

  def error(reason), do: {:ok, Tool.error(format_error(reason))}

  def required_string(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, "Invalid #{key}"}
      :error -> {:error, "Missing required parameter: #{key}"}
    end
  end

  def optional_string(args, key, default \\ nil) do
    case Map.get(args, key, default) do
      nil -> nil
      value when is_binary(value) -> value
      _value -> default
    end
  end

  def optional_list(args, key, default \\ []) do
    case Map.get(args, key, default) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> default
    end
  end

  def optional_map(args, key, default \\ nil) do
    case Map.get(args, key, default) do
      nil -> default
      value when is_map(value) -> value
      _value -> default
    end
  end

  def optional_positive_integer(args, key, default \\ nil) do
    case Map.get(args, key, default) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, "Invalid #{key}"}
    end
  end

  def optional_datetime(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, "Invalid #{key}"}
        end

      _value ->
        {:error, "Invalid #{key}"}
    end
  end

  def job_payload(job) do
    %{
      id: job.id,
      name: job.name,
      description: job.description,
      schedule_kind: job.schedule_kind,
      schedule_expr: job.schedule_expr,
      timezone: job.timezone,
      next_run_at: timestamp(job.next_run_at),
      expires_at: timestamp(job.expires_at),
      memory_source_id: job.memory_source_id,
      state: job.state,
      enabled: job.enabled?,
      allowed_tools: job.allowed_tools,
      capability_policy: job.capability_policy,
      timeout_seconds: job.timeout_seconds,
      inactivity_timeout_seconds: job.inactivity_timeout_seconds,
      delivery_mode: job.delivery_mode,
      last_run_at: timestamp(job.last_run_at),
      last_status: job.last_status,
      last_error: job.last_error
    }
  end

  def source_payload(source) do
    %{
      id: source.id,
      source_type: source.source_type,
      name: source.name,
      description: source.description,
      visibility: source.visibility,
      schedule_summary: source.schedule_summary,
      status: source.status,
      last_run_at: timestamp(source.last_run_at),
      last_status: source.last_status,
      memory_scope: source.memory_scope,
      output_scope: source.output_scope,
      metadata: source.metadata
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error({:invalid_schedule, expr}), do: "Invalid schedule: #{expr}"
  defp format_error({:invalid_datetime, key, value}), do: "Invalid #{key}: #{value}"
  defp format_error({:datetime_not_future, key}), do: "#{key} must be in the future"
  defp format_error({:expired_job, id}), do: "Job expired: #{id}"
  defp format_error({:invalid_delivery_target, message}), do: message
  defp format_error({:invalid_delivery_mode, mode}), do: "Invalid delivery_mode: #{inspect(mode)}"
  defp format_error(:not_found), do: "Not found"
  defp format_error(reason), do: inspect(reason)
end
