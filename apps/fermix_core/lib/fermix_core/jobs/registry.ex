defmodule FermixCore.Jobs.Registry do
  @moduledoc """
  Durable registry for scheduled job definitions and their memory sources.

  A job that runs on cues (M60 §9.1, a watcher's task) has `schedule_kind` and
  `schedule_expr` `"cue"`, no `next_run_at` and no `expires_at`. Only
  `create_cue_job/2` makes one: `Schedule.parse/2` has no word for it, so no
  model can type one into `schedule_job` or `update_job`. Its schedule never
  changes, it never runs now by hand, and its runs start from cues
  (`Jobs.Scheduler`'s cue admission), never from the due scan, which never
  sees a job with neither a next run nor an expiry.
  """

  alias FermixCore.Agents.IterationLimits
  alias FermixCore.Jobs.Schedule
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo

  @default_agent_id "main"

  @cue_kind "cue"
  @cue_summary "runs on cues"
  @cue_default_timeout_seconds 600
  @cue_max_timeout_seconds 1_800
  @reaching_delivery_modes ["origin", "channel"]

  @cue_no_schedule "A job that runs on cues has no schedule of its own."
  @cue_no_expiry "A job that runs on cues cannot expire."
  @cue_timeout_cap "A job that runs on cues may run for at most 30 minutes."
  @cue_must_report "A watcher's task must reach you: pick where it reports."
  @cue_schedule_fixed "This job runs on cues; its schedule cannot change."
  @cue_no_run_now "This job runs on cues."
  @cue_no_policy "A job that runs on cues uses the cue surface; it takes no capability policy."

  @spec create_job(map(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def create_job(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- normalize_create_attrs(attrs, now) do
      insert_job(normalized, opts)
    end
  end

  @doc """
  Create a job that runs on cues, for `manage_watcher` (M60 §9.1, §9.5). It
  takes the attributes `create_job/2` takes, except that a `schedule`,
  `timezone`, `expires_at` or `capability_policy` (its surface is
  `Jobs.CueSurface`'s alone) is refused, `timeout_seconds` defaults to 10
  minutes and is refused above 30, and the delivery must reach the owner: a
  `delivery_mode` of `"origin"` or `"channel"` with its resolved
  `delivery_target` (the caller resolves and checks it, as `schedule_job` does
  through `Jobs.DeliveryDefaults`). Each refusal is a sentence for the owner.
  """
  @spec create_cue_job(map(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def create_cue_job(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, normalized} <- normalize_cue_attrs(attrs) do
      insert_job(normalized, opts)
    end
  end

  @doc "Whether `job` runs on cues rather than on a schedule of its own."
  @spec cue_job?(map()) :: boolean()
  def cue_job?(%{schedule_kind: @cue_kind}), do: true
  def cue_job?(job) when is_map(job), do: false

  @doc """
  For `run_job_now`: a job that runs on cues never runs now by hand, because a
  run of it is the run of one cue. `{:error, :not_found}` for an unknown id.
  """
  @spec check_run_now(String.t(), keyword()) :: :ok | {:error, term()}
  def check_run_now(id, opts \\ []) when is_binary(id) and is_list(opts) do
    with {:ok, job} <- Repo.get_scheduled_job(id, repo_opts(opts)) do
      if cue_job?(job), do: {:error, @cue_no_run_now}, else: :ok
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
    update_job_fields(id, %{enabled?: false, state: "paused"}, "paused", opts)
  end

  @spec resume_job(String.t(), keyword()) :: {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def resume_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, job} <- Repo.get_scheduled_job(id, repo_opts(opts)),
         {:ok, next_run_at} <- next_run_at_for_resume(job, now) do
      update_job_fields(
        id,
        %{enabled?: true, state: "scheduled", next_run_at: next_run_at},
        "enabled",
        opts
      )
    end
  end

  @spec update_job(String.t(), map(), keyword()) ::
          {:ok, Repo.scheduled_job_row()} | {:error, term()}
  def update_job(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, job} <- Repo.get_scheduled_job(id, repo_opts(opts)),
         :ok <- check_cue_update(job, attrs),
         {:ok, job_patch, source_patch} <- normalize_update_attrs(job, attrs, now) do
      apply_job_update(job, job_patch, source_patch, now, opts)
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

  defp insert_job(normalized, opts) do
    with {:ok, job} <-
           Repo.create_job_with_source(
             job_attrs(normalized),
             source_attrs(normalized),
             repo_opts(opts)
           ) do
      notify_scheduler(opts)
      {:ok, job}
    end
  end

  # A job that runs on cues keeps no schedule of its own, keeps reaching the
  # owner and keeps the cue surface (M60 §8.8, §9.1, §9.3, §9.5). Every other
  # job passes untouched here.
  defp check_cue_update(%{schedule_kind: @cue_kind}, attrs) do
    cond do
      Enum.any?([:schedule, :timezone, :expires_at], &given?(attrs, &1)) ->
        {:error, @cue_schedule_fixed}

      policy_given?(attrs) ->
        {:error, @cue_no_policy}

      given?(attrs, :delivery_mode) and not reaches_owner?(attrs) ->
        {:error, @cue_must_report}

      true ->
        :ok
    end
  end

  defp check_cue_update(_job, _attrs), do: :ok

  defp given?(attrs, key), do: fetch_field(attrs, key) not in [nil, ""]

  # An empty list names no policy.
  defp policy_given?(attrs), do: fetch_field(attrs, :capability_policy) not in [nil, "", []]

  # Pause and resume write only the columns they own (enabled, state, and
  # resume's next_run_at), never a whole row from an earlier read: a run's
  # settle can land in between, and a stale copy would revert its release.
  defp update_job_fields(id, fields, source_status, opts) do
    fields = Map.put(fields, :updated_at, DateTime.utc_now())

    with {:ok, updated} <- Repo.update_scheduled_job_fields(id, fields, repo_opts(opts)),
         :ok <- mark_source(updated.memory_source_id, source_status, opts) do
      notify_scheduler(opts)
      {:ok, updated}
    end
  end

  # An edit writes only the fields it changes, never state, enabled or last_*,
  # so it cannot put back a `running` the run's settle has already released.
  defp apply_job_update(job, job_patch, source_patch, now, opts) do
    fields = Map.put(job_patch, :updated_at, now)

    with {:ok, updated} <- Repo.update_scheduled_job_fields(job.id, fields, repo_opts(opts)),
         :ok <- update_source(updated.memory_source_id, source_patch, opts) do
      notify_scheduler(opts)
      {:ok, updated}
    end
  end

  defp normalize_update_attrs(job, attrs, now) do
    task = optional_update_string(attrs, :task_prompt, fallback: :task)
    description = optional_update_string(attrs, :description)
    schedule = optional_update_string(attrs, :schedule)

    with {:ok, schedule_job_patch, schedule_source_patch} <- schedule_patch(job, schedule, now) do
      job_patch =
        %{}
        |> put_present(:task_prompt, task)
        |> put_present(:description, description)
        |> put_present(:skill_name, optional_update_string(attrs, :skill_name))
        |> put_present(:provider, optional_update_string(attrs, :provider))
        |> put_present(:model, optional_update_string(attrs, :model))
        |> Map.merge(route_pin_patch(attrs))
        |> Map.merge(delivery_patch(attrs))
        |> Map.merge(schedule_job_patch)

      source_patch =
        %{}
        |> put_present(:description, description)
        |> Map.merge(schedule_source_patch)

      if map_size(job_patch) == 0,
        do: {:error, :empty_update},
        else: {:ok, job_patch, source_patch}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  # An explicit clear_route_pin sentinel nulls provider AND model together so a
  # job returns to default routing. Both are written as a pair: the normal write
  # path drops provider: nil ("leave unchanged"), so the pin would otherwise
  # survive. The tool guarantees the sentinel never co-occurs with a new pin.
  defp route_pin_patch(attrs) do
    case fetch_field(attrs, :clear_route_pin) do
      true -> %{provider: nil, model: nil}
      _absent -> %{}
    end
  end

  # Delivery is set as a pair so switching to a target-less mode (none/local)
  # also clears any stale delivery_target. The tool resolves and validates the
  # mode/target before they reach here; an absent delivery yields no key at all.
  defp delivery_patch(%{delivery_mode: mode} = attrs) when is_binary(mode) do
    %{delivery_mode: mode, delivery_target: Map.get(attrs, :delivery_target)}
  end

  defp delivery_patch(_attrs), do: %{}

  defp schedule_patch(_job, nil, _now), do: {:ok, %{}, %{}}

  defp schedule_patch(job, schedule_expr, now) do
    with {:ok, parsed} <- Schedule.parse(schedule_expr, timezone: job.timezone, now: now) do
      {:ok,
       %{schedule_kind: parsed.kind, schedule_expr: parsed.expr, next_run_at: parsed.next_run_at},
       %{schedule_summary: parsed.summary}}
    end
  end

  # Its runs start from cues, never from a time, so a resume arms no next run.
  defp next_run_at_for_resume(%{schedule_kind: @cue_kind}, _now), do: {:ok, nil}

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
    update_source(source_id, %{status: status}, opts)
  end

  defp update_source(_source_id, patch, _opts) when map_size(patch) == 0, do: :ok

  defp update_source(source_id, patch, opts) do
    case Repo.get_memory_source(source_id, repo_opts(opts)) do
      {:ok, source} ->
        source
        |> Map.merge(patch)
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
      {:ok,
       attrs
       |> normalized_job(name, task_prompt)
       |> Map.merge(%{
         schedule: parsed,
         timezone: timezone,
         timeout_seconds: optional_integer(attrs, :timeout_seconds, nil),
         delivery_mode: optional_string(attrs, :delivery_mode, "none"),
         expires_at: expires_at
       })}
    end
  rescue
    _error in KeyError -> {:error, :missing_required_job_field}
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp normalize_cue_attrs(attrs) do
    name = required_string(attrs, :name)
    task_prompt = required_string(attrs, :task_prompt, fallback: :task)

    with :ok <- refuse_given(attrs, [:schedule, :timezone], @cue_no_schedule),
         :ok <- refuse_given(attrs, [:expires_at], @cue_no_expiry),
         :ok <- refuse_policy(attrs),
         {:ok, timeout_seconds} <- cue_timeout_seconds(attrs),
         {:ok, delivery_mode} <- cue_delivery_mode(attrs) do
      {:ok,
       attrs
       |> normalized_job(name, task_prompt)
       |> Map.merge(%{
         schedule: cue_schedule(),
         timezone: "UTC",
         timeout_seconds: timeout_seconds,
         delivery_mode: delivery_mode,
         expires_at: nil
       })}
    end
  rescue
    _error in KeyError -> {:error, :missing_required_job_field}
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  # The fields every kind of job takes the same way; the schedule, timezone,
  # timeout, delivery mode and expiry are each kind's own.
  defp normalized_job(attrs, name, task_prompt) do
    id = optional_string(attrs, :id, nil) || generate_job_id(name)

    %{
      id: id,
      name: name,
      description: optional_string(attrs, :description, nil),
      task_prompt: task_prompt,
      skill_name: optional_string(attrs, :skill_name, nil),
      session_mode: optional_string(attrs, :session_mode, "isolated"),
      provider: optional_string(attrs, :provider, nil),
      model: optional_string(attrs, :model, nil),
      max_iterations:
        optional_integer(attrs, :max_iterations, IterationLimits.scheduled_job_default()),
      inactivity_timeout_seconds: optional_integer(attrs, :inactivity_timeout_seconds, nil),
      capability_policy: list_of_strings(attrs, :capability_policy, []),
      allowed_tools: list_of_strings(attrs, :allowed_tools, []),
      memory_source_id: "job:#{id}",
      memory_read_scopes: list_of_strings(attrs, :memory_read_scopes, ["job:self"]),
      memory_write_scope: optional_string(attrs, :memory_write_scope, "job:self"),
      main_visible?: optional_boolean(attrs, :main_visible?, true),
      delivery_target: optional_map(attrs, :delivery_target, nil),
      silent_marker: optional_string(attrs, :silent_marker, "[SILENT]"),
      created_by_agent_id: optional_string(attrs, :created_by_agent_id, @default_agent_id),
      created_by_session_id: optional_string(attrs, :created_by_session_id, nil),
      created_by_channel: optional_string(attrs, :created_by_channel, nil),
      created_by_trust: required_trust(attrs)
    }
  end

  # What a job that runs on cues stores where a schedule goes: an expression the
  # parser has no word for, and no next run.
  defp cue_schedule do
    %{kind: @cue_kind, expr: @cue_kind, timezone: "UTC", next_run_at: nil, summary: @cue_summary}
  end

  defp refuse_given(attrs, keys, sentence) do
    if Enum.any?(keys, &given?(attrs, &1)), do: {:error, sentence}, else: :ok
  end

  defp refuse_policy(attrs),
    do: if(policy_given?(attrs), do: {:error, @cue_no_policy}, else: :ok)

  # The watchdog bounds the agent loop only; start-up and delivery add about
  # three minutes on top (M60 §9.1).
  defp cue_timeout_seconds(attrs) do
    case optional_integer(attrs, :timeout_seconds, @cue_default_timeout_seconds) do
      seconds when seconds > @cue_max_timeout_seconds ->
        {:error, @cue_timeout_cap}

      seconds when seconds > 0 ->
        {:ok, seconds}

      seconds ->
        raise ArgumentError, "expected :timeout_seconds to be positive, got: #{seconds}"
    end
  end

  defp cue_delivery_mode(attrs) do
    if reaches_owner?(attrs),
      do: {:ok, fetch_field(attrs, :delivery_mode)},
      else: {:error, @cue_must_report}
  end

  # A cue run's reply is the only way the owner hears of it, so the task must
  # report to a chat with a resolved target (M60 §9.5); `none` and `local` are
  # silent.
  defp reaches_owner?(attrs) do
    target = fetch_field(attrs, :delivery_target)

    fetch_field(attrs, :delivery_mode) in @reaching_delivery_modes and is_map(target) and
      map_size(target) > 0
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
      created_by_channel: normalized.created_by_channel,
      created_by_trust: normalized.created_by_trust,
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

  # Every job carries the creator's trust — there is no default. A missing or
  # out-of-vocabulary value fails creation loudly (caught by the ArgumentError
  # rescue in normalize_create_attrs, surfaced as {:error, message}).
  defp required_trust(attrs) do
    case fetch_field(attrs, :created_by_trust) do
      trust when trust in ["operator", "guest"] ->
        trust

      other ->
        raise ArgumentError,
              "created_by_trust must be \"operator\" or \"guest\", got: #{inspect(other)}"
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

  defp optional_update_string(attrs, key, opts \\ []) do
    case fetch_field(attrs, key, Keyword.get(opts, :fallback)) do
      nil ->
        nil

      "" ->
        nil

      value when is_binary(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
