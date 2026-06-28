defmodule FermixCore.Tools.JobRegistrySupport do
  @moduledoc false

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Repo
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  def run(tool_name, context, fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(tool_name, context, success, duration,
      metadata: maybe_put_error(%{}, result),
      result: result
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

  @doc """
  Validates the optional `provider`/`model` route pin shared by `schedule_job`
  and `update_job`. Returns `{:ok, {provider, model}}` where each is a string or
  nil, or `{:error, message}` for a clean tool error.

  Contract:

    * `provider`, if present, must be a known provider. The known set is
      `ModelCatalog.providers/0` — the SAME source `Jobs.Runner.provider_atom/1`
      gates against at run time, so this tool-boundary check can never drift
      from the run-time guard.
    * `model` is a free-form provider-specific slug (ollama/openrouter accept
      arbitrary models) — not validated against any list.
    * Both-or-neither: `RouteResolver.resolve!/1` defaults the model to a
      catalog/config value when only a provider is pinned, so a provider-only
      pin would silently resolve to a model the caller never chose. Requiring
      the pair keeps the pin unambiguous (CLAUDE.md #12 — no fallbacks).
  """
  @spec validate_route_pin(map()) ::
          {:ok, {String.t() | nil, String.t() | nil}} | {:error, String.t()}
  def validate_route_pin(args) when is_map(args) do
    provider = optional_string(args, "provider")
    model = optional_string(args, "model")

    with :ok <- validate_route_pair(provider, model),
         :ok <- validate_known_provider(provider) do
      {:ok, {provider, model}}
    end
  end

  defp validate_route_pair(nil, nil), do: :ok
  defp validate_route_pair(provider, model) when is_binary(provider) and is_binary(model), do: :ok

  defp validate_route_pair(_provider, _model) do
    {:error, "provider and model must be set together (both pin the job's route, or neither)"}
  end

  defp validate_known_provider(nil), do: :ok

  defp validate_known_provider(provider) when is_binary(provider) do
    known = ModelCatalog.providers()

    if Enum.any?(known, &(Atom.to_string(&1) == provider)) do
      :ok
    else
      {:error, "unknown provider #{inspect(provider)} (known: #{providers_hint(known)})"}
    end
  end

  defp providers_hint(known), do: Enum.map_join(known, ", ", &Atom.to_string/1)

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
      task_prompt: job.task_prompt,
      schedule_kind: job.schedule_kind,
      schedule_expr: job.schedule_expr,
      timezone: job.timezone,
      skill_name: job.skill_name,
      provider: job.provider,
      model: job.model,
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
      delivery_target: job.delivery_target,
      last_run_at: timestamp(job.last_run_at),
      last_status: job.last_status,
      last_error: job.last_error
    }
  end

  def job_run_summary(run) do
    %{
      id: run.id,
      job_id: run.job_id,
      session_id: run.session_id,
      trigger: run.trigger,
      status: run.status,
      claimed_at: timestamp(run.claimed_at),
      started_at: timestamp(run.started_at),
      completed_at: timestamp(run.completed_at),
      final_response: run.final_response,
      error: run.error,
      delivery_status: run.delivery_status,
      delivery_error: run.delivery_error,
      iterations: run.iterations,
      created_at: timestamp(run.created_at)
    }
  end

  def job_run_payload(run) do
    run
    |> job_run_summary()
    |> Map.merge(%{
      task_prompt: run_task_prompt(run),
      prompt_snapshot: run.prompt_snapshot,
      job_config_snapshot: run.job_config_snapshot,
      capability_policy_snapshot: run.capability_policy_snapshot,
      output_ref: run.output_ref,
      token_usage: run.token_usage,
      latency: run.latency,
      updated_at: timestamp(run.updated_at)
    })
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

  # The exact task_prompt this run executed, captured in its job-config
  # snapshot. Runs recorded before task_prompt was snapshotted return nil —
  # their instructions remain visible verbatim inside prompt_snapshot.
  defp run_task_prompt(%{job_config_snapshot: snapshot}) when is_map(snapshot),
    do: Map.get(snapshot, "task_prompt")

  defp run_task_prompt(_run), do: nil

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp maybe_put_error(metadata, {:ok, %{success: false, error: error}})
       when is_binary(error) do
    Map.put(metadata, :error, error)
  end

  defp maybe_put_error(metadata, {:error, reason}) do
    Map.put(metadata, :error, format_error(reason))
  end

  defp maybe_put_error(metadata, _result), do: metadata

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error({:invalid_schedule, expr}), do: "Invalid schedule: #{expr}"
  defp format_error({:invalid_datetime, key, value}), do: "Invalid #{key}: #{value}"
  defp format_error({:datetime_not_future, key}), do: "#{key} must be in the future"
  defp format_error({:expired_job, id}), do: "Job expired: #{id}"
  defp format_error({:invalid_delivery_target, message}), do: message
  defp format_error({:invalid_delivery_mode, mode}), do: "Invalid delivery_mode: #{inspect(mode)}"
  defp format_error(:already_running), do: "Job already has an active run"

  defp format_error(:not_runnable),
    do: "Job is not runnable (paused, disabled, or already completed)"

  defp format_error(:expired), do: "Job has expired"
  defp format_error(:not_found), do: "Not found"
  defp format_error(reason), do: inspect(reason)
end
