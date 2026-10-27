defmodule FermixCore.Tools.JobRegistrySupport do
  @moduledoc false

  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Clock
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Jobs.Runner
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

  @doc """
  An existing job row's access check for `update_job`, `resume_job` and
  `run_job_now`: a job whose allowlist names an access-sensitive tool may be
  changed, resumed or run now only from a turn that would run that tool
  directly (`Capabilities.AccessGate`). Returns the row it read.
  """
  @spec check_job_access(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def check_job_access(job_id, context) when is_binary(job_id) and is_map(context) do
    with {:ok, job} <- JobsRegistry.get_job(job_id, repo: repo(context)),
         :ok <- AccessGate.check_job_tools(Map.get(job, :allowed_tools) || [], context) do
      {:ok, job}
    end
  end

  @doc """
  For `remove_job`: a job a watcher wakes is not removed (M60 §8.8), so the
  watcher never points at nothing.
  """
  @spec check_unwatched(String.t(), map()) :: :ok | {:error, term()}
  def check_unwatched(job_id, context) when is_binary(job_id) and is_map(context) do
    case Watchers.watcher_for_job(job_id, repo: repo(context)) do
      {:ok, nil} -> :ok
      {:ok, _watcher} -> {:error, "Remove the watcher first, or link it to another job."}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  For `update_job`: a job a watcher wakes changes only on the owner's consent
  turn (`AccessGate.owner_consent_turn?/1`, M60 S6), because what the task may
  do is what outside text can start.
  """
  @spec check_watcher_consent(String.t(), map()) :: :ok | {:error, term()}
  def check_watcher_consent(job_id, context) when is_binary(job_id) and is_map(context) do
    case Watchers.watcher_for_job(job_id, repo: repo(context)) do
      {:ok, nil} ->
        :ok

      {:ok, watcher} ->
        if AccessGate.owner_consent_turn?(context),
          do: :ok,
          else:
            {:error,
             "Watcher #{watcher.name} wakes this job; change it from a private chat with " <>
               "Fermix, in a turn that has read no outside text."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The most refused tool names one sentence lists before it counts the rest.
  @named_max 8
  @give_refusal "This run can't give a job tools it doesn't have itself: "
  @change_refusal "This run can't change a job with tools it doesn't have itself: "

  @doc """
  The tools a run may hand on to a job it creates or changes, or `nil` when
  nothing narrowed the run.

  Narrowing is authorization only, read from the stamps `AgentLoop` puts on
  every run it drives (the owner's turn, a job's run, a skill's or a sub-agent's
  worker): the run was given an explicit `effective_allowed_tools`; its
  `effective_policy` lacks a class its own trust grants by default; or its loop
  ran at an `effective_trust` below its person's operator `source_trust` (a
  plugin skill's worker under the owner's turn). What a surface leaves out to
  fit its channel (voice's channel, media and delegation tools, an ACP
  session's harness tools) or what registered after a cached profile was built
  narrows nothing, so the owner's own turns never count as narrowed.

  A narrowed run's tools are the names `Capabilities.Registry.list_for/2` gives
  for its `effective_trust`, `effective_policy` and `effective_allowed_tools`.
  A context with no stamp (a voice call's `Realtime.ToolBridge`, a direct
  executor such as `Cues.Proposals`) is not narrowed. One with no
  `source_trust` (a sub-agent worker strips it) is judged on its stamps alone,
  and cannot create a job anyway (`schedule_job` refuses it).

  No eval covers this rule: the behavioral harness drives only the owner's text
  turns, which are never narrowed, so ExUnit is its whole proof (`jobs_test`,
  `capabilities/skill_test`, `tools/subagents_test`,
  `realtime/session_server_test`).
  """
  @spec run_tools(map()) :: [String.t()] | nil
  def run_tools(context) when is_map(context) do
    run_trust = CapabilityRegistry.run_trust(context)

    if narrowed?(context, run_trust) do
      tool_names(context,
        trust: run_trust,
        policy_classes: Map.get(context, :effective_policy),
        allowed_tools: Map.get(context, :effective_allowed_tools)
      )
    else
      nil
    end
  end

  defp narrowed?(context, run_trust) do
    is_list(Map.get(context, :effective_allowed_tools)) or
      short_of_trust?(Map.get(context, :effective_policy), run_trust) or
      (Map.get(context, :source_trust) == :operator and run_trust != :operator)
  end

  defp short_of_trust?(nil, _trust), do: false

  defp short_of_trust?(classes, trust) when is_list(classes),
    do: Enum.any?(CapabilityRegistry.default_policy_classes(trust), &(&1 not in classes))

  @doc """
  The names the run's own grant (`effective_allowed_tools`) lists that no
  capability carries right now, such as a disabled plugin's: the run cannot
  hand them on today, but would have them back with the plugin.
  """
  @spec unregistered_grants(map()) :: [String.t()]
  def unregistered_grants(context) when is_map(context) do
    registry = registry(context)

    context
    |> Map.get(:effective_allowed_tools)
    |> List.wrap()
    |> Enum.reject(&match?({:ok, _}, CapabilityRegistry.find(registry, &1)))
  end

  @doc """
  The names of the registered capabilities `filters` admits
  (`Capabilities.Registry.list_for/2`); a `nil` filter is left out, so it
  narrows nothing.
  """
  @spec tool_names(map(), keyword()) :: [String.t()]
  def tool_names(context, filters) when is_map(context) and is_list(filters) do
    opts = Enum.reject(filters, fn {_key, value} -> is_nil(value) end)

    context
    |> registry()
    |> CapabilityRegistry.list_for(opts)
    |> Enum.map(& &1.name)
  end

  defp registry(context), do: Map.get(context, :capability_registry) || CapabilityRegistry

  @doc """
  For `schedule_job`, after the trust scoping: a job gets at most the tools of
  the run that creates it (`run_tools/1`). From a narrowed run, a list naming
  any other tool is refused, naming it, rather than trimmed, so the job never
  quietly does less than asked; no list (`[]`, which a job reads as every tool)
  becomes the run's own, stored explicitly so the job can never widen later.
  """
  @spec within_run_tools([String.t()], map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def within_run_tools(requested, context) when is_list(requested) and is_map(context) do
    case run_tools(context) do
      nil -> {:ok, requested}
      run_tools -> scope_to_run_tools(requested, run_tools)
    end
  end

  # An empty list on a job is every tool, so a run with none has none to give.
  defp scope_to_run_tools([], []),
    do: {:error, "This run has no tools, so it can't give a job any."}

  defp scope_to_run_tools([], run_tools), do: {:ok, run_tools}

  defp scope_to_run_tools(requested, run_tools) do
    with :ok <- inside_run_tools(requested, run_tools, @give_refusal), do: {:ok, requested}
  end

  @doc """
  For `update_job`, on the row `check_job_access/2` returned: a run below
  operator trust (`CapabilityRegistry.run_trust/1`: a plugin skill's worker
  under the owner's turn, or a job bound to a plugin skill) cannot change an
  operator job, whatever tools both hold: the job would keep running at
  operator on instructions a guest run wrote.
  """
  @spec check_change_trust(map(), map()) :: :ok | {:error, String.t()}
  def check_change_trust(job, context) when is_map(job) and is_map(context) do
    if CapabilityRegistry.run_trust(context) != :operator and
         Map.get(job, :created_by_trust) == "operator" do
      {:error,
       "This run is at guest trust, below the operator trust this job was set up at, so " <>
         "it can't change the job."}
    else
      :ok
    end
  end

  @doc """
  For `update_job`: a watcher's task job (one that runs on cues) is bound only
  to a skill that keeps `cue_history` on its runs' surface, the task's one way to
  read its watcher's deliveries (`Jobs.Runner.cue_history_on_surface?/3`, the
  predicate a cue run itself fails on). A plugin skill (guest) loses it, and so
  does one asking only for classes other than `:read_only`.
  """
  @spec check_cue_skill(map(), map() | nil, map()) :: :ok | {:error, String.t()}
  def check_cue_skill(job, skill, context)
      when is_map(job) and (is_map(skill) or is_nil(skill)) and is_map(context) do
    cond do
      is_nil(skill) or not JobsRegistry.cue_job?(job) -> :ok
      Runner.cue_history_on_surface?(job, skill, registry(context)) -> :ok
      true -> {:error, Runner.cue_skill_sentence(skill)}
    end
  end

  @doc """
  For `update_job`, on the row `check_job_access/2` returned: a narrowed run
  (`run_tools/1`) changes only a job whose tools, after the change, are all its
  own, since whatever the change sets the job to do runs with the job's tools.
  Those are the job's list narrowed by its skill's, as `Jobs.Runner` narrows a
  run: `skill` is the definition the change binds, or nil to keep the job's
  own. A name no capability carries now passes when the run's grant lists it
  (`unregistered_grants/1`): the change keeps or narrows the job's list, never
  adds to it. With no list on the job or its skill, nothing bounds the job and
  the change is refused.
  """
  @spec check_within_run_tools(map(), map() | nil, map()) :: :ok | {:error, String.t()}
  def check_within_run_tools(job, skill, context)
      when is_map(job) and (is_map(skill) or is_nil(skill)) and is_map(context) do
    case run_tools(context) do
      nil -> :ok
      run_tools -> job_within_run(job, skill, run_tools ++ unregistered_grants(context), context)
    end
  end

  defp job_within_run(job, nil, run_tools, context) do
    with {:ok, skill} <- bound_skill(job, context), do: bounded_within_run(job, skill, run_tools)
  end

  defp job_within_run(job, skill, run_tools, _context),
    do: bounded_within_run(job, skill, run_tools)

  defp bounded_within_run(job, skill, run_tools) do
    case job_allowlist(job, skill) do
      nil -> {:error, "This run can't change a job no tool list bounds: " <> unbounded(skill)}
      job_tools -> inside_run_tools(job_tools, run_tools, @change_refusal)
    end
  end

  defp unbounded(nil), do: "the job names no tools."
  defp unbounded({:gone, name}), do: "the job names no tools, and its skill #{name} is gone."
  defp unbounded(skill), do: "neither the job nor its skill #{Map.get(skill, :name)} names tools."

  # `Jobs.Runner.effective_allowed_tools/2`: the job's list (`[]` narrows
  # nothing) meets its skill's; nil when neither names tools.
  defp job_allowlist(job, skill) do
    case {nonempty(Map.get(job, :allowed_tools)), skill_allowlist(skill)} do
      {nil, skill_list} -> skill_list
      {job_list, nil} -> job_list
      {job_list, skill_list} -> Enum.filter(job_list, &(&1 in skill_list))
    end
  end

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp skill_allowlist(nil), do: nil
  defp skill_allowlist({:gone, _name}), do: nil
  defp skill_allowlist(skill), do: Map.get(skill, :allowed_tools)

  # The skill the job is bound to. One the registry no longer has narrows
  # nothing (the job's run fails on it), which can only leave the job more tools
  # to check, never fewer.
  defp bound_skill(%{skill_name: name}, context) when is_binary(name) and name != "" do
    case SkillRegistry.load(Map.get(context, :skill_registry, SkillRegistry), name) do
      {:ok, skill} -> {:ok, skill}
      {:error, {:unknown_skill, _name}} -> {:ok, {:gone, name}}
    end
  catch
    :exit, reason -> {:error, "skill_registry_unavailable: #{inspect(reason)}"}
  end

  defp bound_skill(_job, _context), do: {:ok, nil}

  # The one check behind both refusals: `:ok`, or `sentence` naming the tools
  # outside the run's (the first eight, then how many more).
  defp inside_run_tools(names, run_tools, sentence) do
    case Enum.reject(names, &(&1 in run_tools)) do
      [] -> :ok
      outside -> {:error, sentence <> name_list(outside)}
    end
  end

  defp name_list(names) do
    case Enum.split(names, @named_max) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> Enum.join(shown, ", ") <> " and #{length(rest)} more"
    end
  end

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
      the pair keeps the pin unambiguous (AGENTS.md #12 — no fallbacks).
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

  def job_payload(job, repo) do
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
    |> put_schedule_label(job, repo)
  end

  @doc """
  The words a job echo (`list_jobs` first) shows for a job that runs on cues,
  in place of a schedule it does not have, or `nil` for any other job: "runs
  on cues from watcher <name>" (M60 build decision 8), or "runs on cues" for
  one no watcher wakes. The one hook for that label.
  """
  @spec schedule_label(map(), GenServer.server()) :: String.t() | nil
  def schedule_label(job, repo) when is_map(job) do
    if JobsRegistry.cue_job?(job), do: cue_label(job, repo), else: nil
  end

  defp cue_label(job, repo) do
    case Watchers.name_for_job(job.id, repo: repo) do
      {:ok, nil} ->
        "runs on cues"

      {:ok, name} ->
        "runs on cues from watcher #{name}"

      {:error, reason} ->
        Logger.warning("job #{job.id}: its watcher could not be read: #{inspect(reason)}")
        "runs on cues (its watcher could not be read: #{inspect(reason)})"
    end
  end

  defp put_schedule_label(payload, job, repo) do
    case schedule_label(job, repo) do
      nil -> payload
      label -> Map.put(payload, :schedule_label, label)
    end
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
      tool_failures: run.tool_failures,
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
  # A model reads these, so an instant carries the owner's offset (`FermixCore.Clock`).
  defp timestamp(%DateTime{} = value), do: Clock.iso(value)

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
