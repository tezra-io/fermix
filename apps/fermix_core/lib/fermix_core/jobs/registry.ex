defmodule FermixCore.Jobs.Registry do
  @moduledoc """
  Durable registry for scheduled job definitions and their memory sources.
  """

  alias FermixCore.Jobs.Schedule
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo

  @default_agent_id "main"

  @spec create_job(map(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def create_job(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- normalize_create_attrs(attrs, now),
         {:ok, job} <-
           Repo.create_job_with_source(
             job_attrs(normalized),
             source_attrs(normalized),
             repo_opts(opts)
           ) do
      notify_scheduler(opts)
      {:ok, job}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_job(String.t(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def get_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    Repo.get_scheduled_job(id, repo_opts(opts))
  end

  @spec list_jobs(keyword()) :: {:ok, [Repo.scheduled_job_row()]} | {:error, term()}
  def list_jobs(opts \\ []) when is_list(opts) do
    Repo.list_scheduled_jobs(job_list_selector(opts), repo_opts(opts))
  end

  @spec pause_job(String.t(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def pause_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    update_job_state(id, %{enabled?: false, state: "paused"}, "paused", opts)
  end

  @spec resume_job(String.t(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def resume_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, job} <- Repo.get_scheduled_job(id, repo_opts(opts)),
         {:ok, next_run_at} <- next_run_at_for_resume(job, now) do
      update_existing_job_state(
        job,
        %{enabled?: true, state: "scheduled", next_run_at: next_run_at},
        "enabled",
        opts
      )
    end
  end

  @spec remove_job(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    with {:ok, job} <- Repo.get_scheduled_job(id, repo_opts(opts)),
         :ok <- Repo.delete_scheduled_job_if_idle(id, repo_opts(opts)),
         :ok <- mark_source(job.memory_source_id, "removed", opts) do
      notify_scheduler(opts)
      :ok
    end
  end

  @spec get_memory_source(String.t(), keyword()) ::
          {:ok, Repo.memory_source_row()} | {:error, term()}
  def get_memory_source(id, opts \\ []) when is_binary(id) and is_list(opts) do
    Repo.get_memory_source(id, repo_opts(opts))
  end

  @spec list_memory_sources(keyword()) :: {:ok, [Repo.memory_source_row()]} | {:error, term()}
  def list_memory_sources(opts \\ []) when is_list(opts) do
    Repo.list_memory_sources(memory_source_selector(opts), repo_opts(opts))
  end

  defp update_job_state(id, patch, source_status, opts) do
    with {:ok, job} <- Repo.get_scheduled_job(id, repo_opts(opts)) do
      update_existing_job_state(job, patch, source_status, opts)
    end
  end

  defp update_existing_job_state(job, patch, source_status, opts) do
    with attrs <- job |> Map.merge(patch) |> Map.put(:updated_at, DateTime.utc_now()),
         {:ok, updated} <- Repo.upsert_scheduled_job(attrs, repo_opts(opts)),
         :ok <- mark_source(updated.memory_source_id, source_status, opts) do
      notify_scheduler(opts)
      {:ok, updated}
    end
  end

  defp next_run_at_for_resume(%{schedule_kind: "once"} = job, now) do
    with :ok <- ensure_not_expired(job, now),
         {:ok, parsed} <- Schedule.parse(job.schedule_expr, timezone: job.timezone, now: now) do
      case DateTime.compare(parsed.next_run_at, now) do
        :gt -> {:ok, parsed.next_run_at}
        _not_future -> {:error, {:expired_once_job, job.id}}
      end
    end
  end

  defp next_run_at_for_resume(job, now) do
    with :ok <- ensure_not_expired(job, now),
         {:ok, parsed} <- Schedule.parse(job.schedule_expr, timezone: job.timezone, now: now) do
      {:ok, parsed.next_run_at}
    end
  end

  defp ensure_not_expired(%{expires_at: nil}, _now), do: :ok

  defp ensure_not_expired(%{expires_at: %DateTime{} = expires_at, id: id}, now) do
    case DateTime.compare(now, expires_at) do
      :lt -> :ok
      _expired -> {:error, {:expired_job, id}}
    end
  end

  defp mark_source(source_id, status, opts) do
    case Repo.get_memory_source(source_id, repo_opts(opts)) do
      {:ok, source} ->
        source
        |> Map.put(:status, status)
        |> Map.put(:updated_at, DateTime.utc_now())
        |> Repo.upsert_memory_source(repo_opts(opts))
        |> case do
          {:ok, _source} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_create_attrs(attrs, now) do
    name = required_string(attrs, :name)
    task_prompt = required_string(attrs, :task_prompt, fallback: :task)
    schedule_expr = required_string(attrs, :schedule)
    timezone = optional_string(attrs, :timezone, "UTC")

    with {:ok, parsed} <- Schedule.parse(schedule_expr, timezone: timezone, now: now),
         {:ok, expires_at} <- optional_future_datetime(attrs, :expires_at, now) do
      id = optional_string(attrs, :id, nil) || generate_job_id(name)
      memory_source_id = "job:#{id}"

      {:ok,
       %{
         id: id,
         name: name,
         description: optional_string(attrs, :description, nil),
         schedule: parsed,
         timezone: timezone,
         task_prompt: task_prompt,
         skill_name: optional_string(attrs, :skill_name, nil),
         session_mode: optional_string(attrs, :session_mode, "isolated"),
         provider: optional_string(attrs, :provider, nil),
         model: optional_string(attrs, :model, nil),
         max_iterations: optional_integer(attrs, :max_iterations, 25),
         timeout_seconds: optional_integer(attrs, :timeout_seconds, nil),
         inactivity_timeout_seconds: optional_integer(attrs, :inactivity_timeout_seconds, nil),
         capability_policy: list_of_strings(attrs, :capability_policy, []),
         allowed_tools: list_of_strings(attrs, :allowed_tools, []),
         memory_source_id: memory_source_id,
         memory_read_scopes: list_of_strings(attrs, :memory_read_scopes, ["job:self"]),
         memory_write_scope: optional_string(attrs, :memory_write_scope, "job:self"),
         main_visible?: optional_boolean(attrs, :main_visible?, true),
         delivery_mode: optional_string(attrs, :delivery_mode, "none"),
         delivery_target: optional_map(attrs, :delivery_target, nil),
         silent_marker: optional_string(attrs, :silent_marker, "[SILENT]"),
         created_by_agent_id: optional_string(attrs, :created_by_agent_id, @default_agent_id),
         created_by_session_id: optional_string(attrs, :created_by_session_id, nil),
         expires_at: expires_at
       }}
    end
  rescue
    _error in KeyError -> {:error, :missing_required_job_field}
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp job_attrs(normalized) do
    %{
      id: normalized.id,
      name: normalized.name,
      description: normalized.description,
      schedule_kind: normalized.schedule.kind,
      schedule_expr: normalized.schedule.expr,
      timezone: normalized.timezone,
      next_run_at: normalized.schedule.next_run_at,
      task_prompt: normalized.task_prompt,
      skill_name: normalized.skill_name,
      session_mode: normalized.session_mode,
      provider: normalized.provider,
      model: normalized.model,
      max_iterations: normalized.max_iterations,
      timeout_seconds: normalized.timeout_seconds,
      inactivity_timeout_seconds: normalized.inactivity_timeout_seconds,
      capability_policy: normalized.capability_policy,
      allowed_tools: normalized.allowed_tools,
      memory_source_id: normalized.memory_source_id,
      memory_read_scopes: normalized.memory_read_scopes,
      memory_write_scope: normalized.memory_write_scope,
      main_visible?: normalized.main_visible?,
      delivery_mode: normalized.delivery_mode,
      delivery_target: normalized.delivery_target,
      silent_marker: normalized.silent_marker,
      enabled?: true,
      state: "scheduled",
      created_by_agent_id: normalized.created_by_agent_id,
      created_by_session_id: normalized.created_by_session_id,
      expires_at: normalized.expires_at
    }
  end

  defp source_attrs(normalized) do
    %{
      id: normalized.memory_source_id,
      source_type: "scheduled_job",
      name: normalized.name,
      description: normalized.description,
      owner_agent_id: normalized.created_by_agent_id,
      visibility: source_visibility(normalized.main_visible?),
      schedule_summary: normalized.schedule.summary,
      status: "enabled",
      memory_scope: normalized.memory_source_id,
      output_scope: "cron:#{normalized.id}",
      metadata: %{"job_id" => normalized.id}
    }
  end

  defp source_visibility(true), do: "main_visible"
  defp source_visibility(false), do: "private"

  defp job_list_selector(opts) do
    opts
    |> Keyword.take([:state, :created_by_agent_id, :memory_source_id])
    |> Enum.into(%{})
  end

  defp memory_source_selector(opts) do
    opts
    |> Keyword.take([:source_type, :owner_agent_id, :visibility, :status])
    |> Enum.into(%{})
  end

  defp notify_scheduler(opts) do
    case Keyword.get(opts, :scheduler, Scheduler) do
      nil -> :ok
      scheduler -> Scheduler.job_changed(scheduler)
    end
  end

  defp generate_job_id(name) do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "#{slug(name)}_#{suffix}"
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "job"
      slug -> slug
    end
  end

  defp required_string(attrs, key, opts \\ []) do
    fallback = Keyword.get(opts, :fallback)

    case fetch_field(attrs, key, fallback) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "missing required scheduled job field #{inspect(key)}"
    end
  end

  defp optional_string(attrs, key, default) do
    case fetch_field(attrs, key) do
      nil ->
        default

      value when is_binary(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end

  defp optional_integer(attrs, key, default) do
    case fetch_field(attrs, key) do
      nil ->
        default

      value when is_integer(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be an integer, got: #{inspect(value)}"
    end
  end

  defp optional_boolean(attrs, key, default) do
    case fetch_field(attrs, key) do
      nil ->
        default

      value when is_boolean(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a boolean, got: #{inspect(value)}"
    end
  end

  defp optional_map(attrs, key, default) do
    case fetch_field(attrs, key) do
      nil -> default
      value when is_map(value) -> value
      value -> raise ArgumentError, "expected #{inspect(key)} to be a map, got: #{inspect(value)}"
    end
  end

  defp optional_future_datetime(attrs, key, now) do
    case fetch_field(attrs, key) do
      nil ->
        {:ok, nil}

      %DateTime{} = value ->
        validate_future_datetime(value, key, now)

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, parsed, _offset} -> validate_future_datetime(parsed, key, now)
          {:error, _reason} -> {:error, {:invalid_datetime, key, value}}
        end

      value ->
        raise ArgumentError,
              "expected #{inspect(key)} to be an ISO8601 datetime, got: #{inspect(value)}"
    end
  end

  defp validate_future_datetime(value, key, now) do
    case DateTime.compare(value, now) do
      :gt -> {:ok, value}
      _not_future -> {:error, {:datetime_not_future, key}}
    end
  end

  defp list_of_strings(attrs, key, default) do
    case fetch_field(attrs, key) do
      nil ->
        default

      values when is_list(values) ->
        ensure_strings!(values, key)

      value ->
        raise ArgumentError,
              "expected #{inspect(key)} to be a list of strings, got: #{inspect(value)}"
    end
  end

  defp ensure_strings!(values, key) do
    if Enum.all?(values, &is_binary/1) do
      values
    else
      raise ArgumentError,
            "expected #{inspect(key)} to be a list of strings, got: #{inspect(values)}"
    end
  end

  defp fetch_field(attrs, key, fallback \\ nil) do
    with :error <- Map.fetch(attrs, key),
         :error <- Map.fetch(attrs, Atom.to_string(key)) do
      fallback_value(attrs, fallback)
    else
      {:ok, value} -> value
    end
  end

  defp fallback_value(_attrs, nil), do: nil

  defp fallback_value(attrs, key) do
    with :error <- Map.fetch(attrs, key),
         :error <- Map.fetch(attrs, Atom.to_string(key)) do
      nil
    else
      {:ok, value} -> value
    end
  end

  defp repo_opts(opts), do: [server: Keyword.get(opts, :repo, Keyword.get(opts, :server, Repo))]
end
