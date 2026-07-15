defmodule FermixCore.Jobs.Runner do
  @moduledoc """
  Scheduled-job runner.

  It records the lifecycle for a claimed job run, builds the isolated cron
  prompt, runs one bounded AgentLoop execution, and persists run artifacts.
  """

  use GenServer
  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Delivery
  alias FermixCore.Jobs.Telemetry, as: JobTelemetry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Net.Readiness
  alias FermixCore.Prompt.CurrentDate
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RouteResolver
  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Providers.Selection
  alias FermixCore.Providers.Transient
  alias FermixCore.Setup.ConfigStore

  @default_timeout_ms 30 * 60 * 1_000
  @default_delivery_timeout_ms 60_000
  @default_capability_policy [:read_only, :network]

  # Transient-infrastructure retry (wake-from-sleep network race). A scheduled
  # run that fires right after the host resumes can hit the network before it
  # is ready; the LLM call cannot obtain a connection and surfaces as a
  # `:connection_unavailable` transport error. The network comes up seconds
  # later, so the runner re-runs the whole loop with exponential backoff,
  # bounded by attempt count AND a cumulative wall-clock ceiling (Rule #2).
  @default_max_transient_attempts 4
  @default_transient_backoff_ms 2_000
  @default_max_transient_retry_ms 60_000

  @type state :: %{
          repo: GenServer.server(),
          capability_registry: GenServer.server(),
          skill_registry: GenServer.server(),
          job: Repo.scheduled_job_row(),
          run: Repo.job_run_row(),
          notify: pid() | nil,
          adapter: module() | nil,
          adapter_opts: keyword(),
          delivery_adapter: module() | nil,
          delivery_opts: keyword(),
          delivery_channels: map() | keyword(),
          delivery_timeout_ms: non_neg_integer() | nil,
          output_base_dir: String.t(),
          timeout_ms: pos_integer() | nil,
          inactivity_timeout_ms: pos_integer() | nil,
          delay_fn: (non_neg_integer() -> any()),
          max_transient_attempts: non_neg_integer(),
          transient_backoff_ms: pos_integer(),
          max_transient_retry_ms: non_neg_integer(),
          readiness_enabled: boolean(),
          readiness_host: String.t() | nil,
          readiness_port: :inet.port_number() | nil,
          readiness_opts: keyword()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    run = Keyword.fetch!(opts, :run)

    %{
      id: {__MODULE__, run.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      job: Keyword.fetch!(opts, :job),
      run: Keyword.fetch!(opts, :run),
      notify: Keyword.get(opts, :notify),
      adapter: Keyword.get(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      delivery_adapter: Keyword.get(opts, :delivery_adapter),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      delivery_channels: Keyword.get(opts, :delivery_channels, default_delivery_channels()),
      delivery_timeout_ms: Keyword.get(opts, :delivery_timeout_ms, default_delivery_timeout_ms()),
      output_base_dir: Keyword.get(opts, :output_base_dir) || default_output_base_dir(),
      timeout_ms:
        configured_timeout_ms(opts, Keyword.fetch!(opts, :job), :timeout_ms, :timeout_seconds) ||
          default_timeout_ms(opts),
      inactivity_timeout_ms:
        configured_timeout_ms(
          opts,
          Keyword.fetch!(opts, :job),
          :inactivity_timeout_ms,
          :inactivity_timeout_seconds
        ),
      delay_fn: Keyword.get(opts, :delay_fn, &Process.sleep/1),
      start_delay_ms: Keyword.get(opts, :start_delay_ms, 0),
      max_transient_attempts:
        Keyword.get(opts, :max_transient_attempts, @default_max_transient_attempts),
      transient_backoff_ms:
        Keyword.get(opts, :transient_backoff_ms, @default_transient_backoff_ms),
      max_transient_retry_ms:
        Keyword.get(opts, :max_transient_retry_ms, @default_max_transient_retry_ms),
      readiness_enabled:
        Keyword.get(opts, :network_readiness_enabled, network_readiness_enabled?()),
      readiness_host: Keyword.get(opts, :readiness_host),
      readiness_port: Keyword.get(opts, :readiness_port),
      readiness_opts: Keyword.get(opts, :readiness_opts, [])
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    case build_loop_input(state) do
      {:ok, loop_input} ->
        run = mark_running(state, loop_input)
        notify(state.notify, {:job_runner, :started, run.id, state.job.id})

        completed_run =
          state
          |> Map.put(:run, run)
          |> execute_and_finalize(loop_input)

        notify(state.notify, {:job_runner, :completed, completed_run.id, state.job.id})
        {:stop, :normal, %{state | run: completed_run}}

      {:error, reason} ->
        run = mark_running(state, fallback_loop_input(state, reason))
        failed_run = mark_failed(%{state | run: run}, "error", inspect(reason))
        notify(state.notify, {:job_runner, :completed, failed_run.id, state.job.id})
        {:stop, :normal, %{state | run: failed_run}}
    end
  end

  defp execute_and_finalize(state, loop_input) do
    stagger_start(state)
    await_network_ready(loop_input.loop_opts, state)

    case run_agent_loop_with_retry(loop_input.loop_opts, state) do
      {:ok, result} ->
        completed_run = mark_completed(state, result)
        completed_state = %{state | run: completed_run}

        persist_run_summary_memory(completed_state, result)
        finalize_job(completed_state)
        finalize_delivery(completed_state, result.response)

      {:timeout, reason} ->
        mark_failed(state, "timeout", reason)

      {:error, reason} ->
        mark_failed(state, "error", inspect(reason))
    end
  end

  defp mark_running(state, loop_input) do
    now = DateTime.utc_now()

    attrs =
      state.run
      |> Map.merge(%{
        status: "running",
        started_at: now,
        prompt_snapshot: loop_input.prompt_snapshot,
        job_config_snapshot: job_config_snapshot(state.job, loop_input),
        capability_policy_snapshot: capability_policy_snapshot(state.job),
        updated_at: now
      })

    {:ok, run} = Repo.upsert_job_run(attrs, server: state.repo)
    JobTelemetry.run_start(state.job, run, loop_input, state.timeout_ms)
    run
  end

  defp mark_completed(state, result) do
    now = DateTime.utc_now()
    {:ok, output_ref} = write_run_artifact(state, "output.md", success_artifact(state, result))

    attrs =
      state.run
      |> Map.merge(%{
        status: "ok",
        completed_at: now,
        output_ref: output_ref,
        final_response: result.response,
        iterations: result.iterations,
        token_usage: %{"total" => result.total_tokens},
        latency: %{},
        delivery_status: Delivery.initial_status(state.job, result.response),
        updated_at: now
      })

    {:ok, run} = Repo.upsert_job_run(attrs, server: state.repo)
    JobTelemetry.run_complete(state.job, run, result)
    run
  end

  defp persist_run_summary_memory(state, result) do
    if Delivery.silent?(result.response, state.job.silent_marker) do
      :ok
    else
      attrs = %{
        agent_id: state.job.created_by_agent_id || MemoryConfig.agent_id(),
        owner_id: MemoryConfig.owner_id(),
        scope_type: "job",
        scope_id: state.job.memory_source_id,
        category: "job_run_summary",
        key: "latest",
        value: result.response,
        confidence: 1.0,
        promote_target: "none",
        source_id: state.job.memory_source_id,
        source_type: "scheduled_job",
        source_name: state.job.name,
        source_description: state.job.description,
        session_id: state.run.session_id,
        run_id: state.run.id
      }

      case Repo.upsert_memory(attrs, server: state.repo) do
        {:ok, _memory} ->
          :ok

        {:error, :disabled} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Scheduled job #{state.job.id} memory summary write failed: #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp mark_failed(state, status, error) when status in ["error", "timeout"] do
    now = DateTime.utc_now()

    {:ok, output_ref} =
      write_run_artifact(state, "error.md", failure_artifact(state, status, error))

    attrs =
      state.run
      |> Map.merge(%{
        status: status,
        completed_at: now,
        output_ref: output_ref,
        error: error,
        delivery_status:
          Delivery.initial_status(state.job, failure_delivery_text(state, status, error)),
        updated_at: now
      })

    {:ok, run} = Repo.upsert_job_run(attrs, server: state.repo)
    failed_state = %{state | run: run}
    JobTelemetry.run_error(state.job, run, status, error)
    finalize_failed_job(failed_state, status, error)
    finalize_delivery(failed_state, failure_delivery_text(state, status, error))
  end

  defp finalize_delivery(state, text) do
    case Delivery.deliver_with_timeout(state.job, text, delivery_opts(state)) do
      {:ok, delivery_status} ->
        mark_delivery(state, delivery_status, nil)

      {:error, reason} ->
        mark_delivery(state, "failed", inspect(reason))
    end
  end

  defp mark_delivery(state, delivery_status, delivery_error) do
    now = DateTime.utc_now()

    attrs =
      state.run
      |> Map.merge(%{
        delivery_status: delivery_status,
        delivery_error: delivery_error,
        updated_at: now
      })

    case Repo.upsert_job_run(attrs, server: state.repo) do
      {:ok, run} ->
        run

      {:error, reason} ->
        Logger.warning(
          "Scheduled job #{state.job.id} delivery status update failed: #{inspect(reason)}"
        )

        state.run
    end
  end

  defp finalize_job(state) do
    now = state.run.completed_at || DateTime.utc_now()

    case Repo.get_scheduled_job(state.job.id, server: state.repo) do
      {:ok, current_job} ->
        job_attrs =
          current_job
          |> Map.merge(final_job_state(current_job, state.job.schedule_kind))
          |> Map.merge(%{
            last_run_at: now,
            last_status: "ok",
            last_error: nil,
            updated_at: now
          })

        {:ok, updated_job} = Repo.upsert_scheduled_job(job_attrs, server: state.repo)
        update_memory_source(updated_job, now, state.repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        raise "failed to finalize scheduled job #{state.job.id}: #{inspect(reason)}"
    end
  end

  defp final_job_state(_current_job, "once") do
    %{enabled?: false, state: "completed", next_run_at: nil}
  end

  defp final_job_state(%{state: "running"}, _schedule_kind), do: %{state: "scheduled"}

  defp final_job_state(_current_job, _schedule_kind), do: %{}

  defp update_memory_source(job, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{
          last_run_at: now,
          last_status: "ok",
          updated_at: now
        })
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp finalize_failed_job(state, status, error) do
    now = state.run.completed_at || DateTime.utc_now()

    case Repo.get_scheduled_job(state.job.id, server: state.repo) do
      {:ok, current_job} ->
        job_attrs =
          current_job
          |> Map.merge(final_job_state(current_job, state.job.schedule_kind))
          |> Map.merge(%{
            last_run_at: now,
            last_status: status,
            last_error: error,
            updated_at: now
          })

        {:ok, updated_job} = Repo.upsert_scheduled_job(job_attrs, server: state.repo)
        update_memory_source_status(updated_job, status, now, state.repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        raise "failed to finalize failed scheduled job #{state.job.id}: #{inspect(reason)}"
    end
  end

  defp update_memory_source_status(job, status, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{last_run_at: now, last_status: status, updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp build_loop_input(state) do
    with {:ok, skill} <- load_skill(state),
         {:ok, loop_opts} <- loop_opts(state, skill) do
      messages = prompt_messages(state.job, skill)

      {:ok,
       %{
         messages: messages,
         prompt_snapshot: prompt_snapshot(messages),
         route_used: resolved_route_used(loop_opts, state.job),
         loop_opts: Keyword.put(loop_opts, :messages, messages)
       }}
    end
  end

  defp fallback_loop_input(state, reason) do
    messages = [
      %{role: "system", content: cron_guidance()},
      %{role: "system", content: CurrentDate.note()},
      %{role: "user", content: state.job.task_prompt}
    ]

    %{
      messages: messages,
      prompt_snapshot: prompt_snapshot(messages) <> "\n\nPrompt setup error: #{inspect(reason)}",
      # Route resolution is what failed here — there is no route to record, and
      # re-resolving for the snapshot would just raise the same error again.
      route_used: nil,
      loop_opts: [messages: messages]
    }
  end

  defp load_skill(%{job: %{skill_name: nil}}), do: {:ok, nil}
  defp load_skill(%{job: %{skill_name: ""}}), do: {:ok, nil}

  defp load_skill(state) do
    SkillRegistry.load(state.skill_registry, state.job.skill_name)
  end

  # Job runs bypass TurnRunner, so they stamp the current date themselves —
  # scheduled work is exactly where "today" matters most.
  defp prompt_messages(job, skill) do
    [
      %{role: "system", content: cron_guidance()},
      skill_prompt_message(skill, job),
      %{role: "system", content: job_context_prompt(job)},
      %{role: "system", content: CurrentDate.note()},
      %{role: "user", content: job.task_prompt}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp skill_prompt_message(nil, _job), do: nil

  defp skill_prompt_message(skill, job) do
    %{
      role: "system",
      content:
        skill.system_prompt <>
          "\n\n---\n\nYou are running as the \"#{skill.name}\" skill for scheduled job \"#{job.name}\"."
    }
  end

  defp cron_guidance do
    """
    You are running as a scheduled Fermix job.

    Your final response will be saved and delivered by Fermix if delivery is configured.
    Do not call messaging tools to deliver your own result unless the job explicitly allows it.
    Fermix owns job lifecycle through registry state and expires_at; scheduled runs should focus on the job task and final response.

    If there is genuinely nothing new to report, respond exactly with [SILENT].
    Do not combine [SILENT] with other text.
    """
    |> String.trim()
  end

  defp job_context_prompt(job) do
    """
    Scheduled job: #{job.name}
    Job id: #{job.id}
    Schedule: #{job.schedule_expr} (#{job.timezone})
    Memory source id: #{job.memory_source_id}
    Delivery mode: #{job.delivery_mode}
    """
    |> String.trim()
  end

  defp prompt_snapshot(messages) do
    Enum.map_join(messages, "\n\n---\n\n", fn message ->
      "#{String.upcase(message.role)}:\n#{message.content}"
    end)
  end

  defp loop_opts(state, skill) do
    trust = effective_trust(state.job)
    {routing_opts, worker_routing} = resolve_run_routing(state)

    base = [
      context: loop_context(state, skill, trust, worker_routing),
      capability_registry: state.capability_registry,
      allowed_tools: effective_allowed_tools(state.job, skill),
      policy: effective_policy(state.job, trust, skill),
      trust: trust,
      max_iterations: state.job.max_iterations
    ]

    {:ok, base ++ routing_opts}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # `:operator` jobs run with the trust-derived registry default (full
  # operator surface). The static scheduled-job policy default
  # (`[:read_only, :network]`) would otherwise win at
  # `Registry.resolve_policy/2` and silently re-narrow an operator-created
  # job — defeating the `created_by_trust` ceiling captured at creation.
  defp scheduled_policy(_explicit, :operator), do: nil
  defp scheduled_policy(explicit, _trust), do: capability_policy(explicit)

  # A named skill's declared `policy` narrows the run further, clamped to the
  # classes the job's own trust actually grants — so naming an operator skill
  # from a guest job can never widen the run past guest. A skill with no policy
  # (or `policy: []`, which `Registry.resolve_policy/2` reads as "use the trust
  # default") leaves the job's trust-derived policy untouched. An empty clamp
  # means the skill demanded only classes the trust forbids: fail the run loudly
  # rather than silently leak back to the trust default.
  defp effective_policy(job, trust, skill) do
    base = scheduled_policy(job.capability_policy, trust)

    case skill_policy(skill) do
      nil -> base
      skill_classes -> clamp_skill_policy(base, skill_classes, trust, skill)
    end
  end

  defp skill_policy(nil), do: nil
  defp skill_policy(%{policy: classes}) when is_list(classes) and classes != [], do: classes
  defp skill_policy(_skill), do: nil

  defp clamp_skill_policy(base, skill_classes, trust, skill) do
    granted = job_policy_classes(base, trust)

    case Enum.filter(skill_classes, &(&1 in granted)) do
      [] ->
        raise ArgumentError,
              "skill #{inspect(skill.name)} policy #{inspect(skill_classes)} grants no " <>
                "capability classes under job trust #{inspect(trust)}"

      classes ->
        classes
    end
  end

  # The concrete class set the job runs with absent a skill: the explicit
  # scheduled-job policy when set, else the trust's registry default.
  defp job_policy_classes(base, _trust) when is_list(base), do: base
  defp job_policy_classes(nil, trust), do: CapabilityRegistry.default_policy_classes(trust)

  # Audit F-08 follow-up. AgentLoop's `capability_allowed?/2` treats
  # `nil` as "no narrowing" and a list as an exact allowlist. An empty
  # list therefore means "deny every tool", which is the wrong default
  # for a scheduled job that simply didn't ask to narrow. Map empty to
  # `nil` at this boundary so jobs without an explicit allowlist run
  # against the trust-derived registry surface, exactly like the
  # creator's live turn would.
  defp narrow_allowed_tools([]), do: nil
  defp narrow_allowed_tools(nil), do: nil
  defp narrow_allowed_tools(list) when is_list(list), do: list

  # A job that names a skill must run inside that skill's declared tool
  # confinement — otherwise the run "cosplays" as the skill (its prompt)
  # while wielding the creator's full tool surface. The effective allowlist
  # is the intersection of the job's caller-scoped allowlist (the ceiling
  # its creator could reach) and the skill's declared allowlist. `nil` on
  # either side means "no narrowing from that source"; an empty intersection
  # denies every tool (AgentLoop reads `[]` as deny-all).
  defp effective_allowed_tools(job, skill) do
    intersect_allowlist(narrow_allowed_tools(job.allowed_tools), skill_allowed_tools(skill))
  end

  defp skill_allowed_tools(nil), do: nil
  defp skill_allowed_tools(%{allowed_tools: allowed_tools}), do: allowed_tools

  defp intersect_allowlist(nil, other), do: other
  defp intersect_allowlist(other, nil), do: other

  defp intersect_allowlist(job_list, skill_list)
       when is_list(job_list) and is_list(skill_list) do
    Enum.filter(job_list, &(&1 in skill_list))
  end

  # Audit F-08 step 2 — intersection at run time.
  #
  # The persisted `created_by_trust` is the ceiling the creator could
  # reach at creation. The runner uses it as the *floor* for the run's
  # trust value, so the registry's per-trust policy default kicks in
  # (e.g., `:guest` → :read_only). The capability_policy field is now
  # empty for jobs created after this commit — the model can't widen
  # the future run's policy class.
  #
  # The stored vocabulary is `"operator"`/`"guest"`, enforced by the
  # scheduled_jobs CHECK constraint (trust-check Memory.Repo migration).
  # There is no fall-through: an out-of-vocabulary value can only mean a
  # corrupt row, so it raises and fails the run loudly rather than silently
  # granting a trust the creator may never have had. Public for tests.
  @doc false
  @spec effective_trust(map()) :: :operator | :guest
  def effective_trust(%{created_by_trust: "operator"}), do: :operator
  def effective_trust(%{created_by_trust: "guest"}), do: :guest

  # The run's routing, resolved once and threaded two ways (§11.1): as the
  # AgentLoop route opts for the run's own loop, and as the `worker_routing`
  # seam its loop context hands delegated `subagents` workers. An injected
  # adapter (test stubs) drives the run's loop directly and reaches workers as
  # `:provider` (mirroring TurnRunner); a real run resolves `job_routes/1` once
  # so a provider-pinned job's workers inherit that same chain instead of
  # silently falling back to the global primary.
  defp resolve_run_routing(%{adapter: adapter, adapter_opts: adapter_opts} = state)
       when is_atom(adapter) and not is_nil(adapter) do
    {[adapter: adapter, adapter_opts: adapter_opts],
     %{ordered_routes: job_routes(state.job), provider: adapter}}
  end

  defp resolve_run_routing(state) do
    routes = job_routes(state.job)
    {[routes: routes], %{ordered_routes: routes}}
  end

  # Jobs with a persisted provider/model stay strict (one route) for
  # reproducibility; jobs without one follow the current primary/fallback
  # chain at execution time (§7). Route-selection failures (e.g. multiple
  # primaries) raise here and fail the run loudly.
  defp job_routes(job) do
    case route_opts(job) do
      [] -> unpinned_routes()
      explicit -> [RouteResolver.resolve!(explicit)]
    end
  end

  # An unpinned job uses the global [fermix_core.routing] cron_* default if set,
  # else today's primary/fallback chain — with cron_reasoning_effort overlaid on
  # whichever chain results (docs/design/SUBAGENT_MODEL_SELECTION.md §5d). An
  # invalid cron_* value raises here and fails the run loudly, as before.
  defp unpinned_routes do
    override = RoutingOverrides.infer_provider(RoutingOverrides.cron())

    base =
      case {override.provider, override.model} do
        {nil, nil} -> primary_chain()
        _pin -> [RouteResolver.resolve!(provider: override.provider, model: override.model)]
      end

    RoutingOverrides.apply_effort(base, override.reasoning_effort)
  end

  defp primary_chain do
    case Selection.ordered_routes() do
      {:ok, routes} ->
        routes

      {:error, reason} ->
        raise ArgumentError, "scheduled job route selection failed: #{inspect(reason)}"
    end
  end

  defp route_opts(job) do
    []
    |> maybe_put(:provider, provider_atom(job.provider))
    |> maybe_put(:model, job.model)
  end

  # Public for tests — provider-string parsing is a known regression site
  # (provider design doc §13: "jobs raise on unknown provider strings").
  # Derived from the catalog so new providers don't need a clause here.
  @doc false
  @spec provider_atom(String.t() | atom() | nil) :: atom() | nil
  def provider_atom(nil), do: nil

  def provider_atom(provider) when is_binary(provider) do
    Enum.find(ModelCatalog.providers(), &(Atom.to_string(&1) == provider)) ||
      raise ArgumentError, "unsupported scheduled job provider #{inspect(provider)}"
  end

  # Atoms get the same gate as strings — an unknown atom used to pass
  # through and fail later in RouteResolver with a less specific message
  # (M12 §2.3-6).
  def provider_atom(other) when is_atom(other) do
    if other in ModelCatalog.providers() do
      other
    else
      raise ArgumentError, "unsupported scheduled job provider #{inspect(other)}"
    end
  end

  defp capability_policy([]), do: @default_capability_policy
  defp capability_policy(nil), do: @default_capability_policy

  defp capability_policy(policy) when is_list(policy) do
    Enum.map(policy, fn
      "read_only" -> :read_only
      "read_write" -> :read_write
      "exec" -> :exec
      "network" -> :network
      "external_api" -> :external_api
      value when is_atom(value) -> value
      value -> raise ArgumentError, "unsupported scheduled job policy #{inspect(value)}"
    end)
  end

  defp loop_context(state, skill, trust, worker_routing) do
    %{
      agent_name: "scheduled:#{state.job.id}",
      conversation_key: {:scheduled_job, state.job.id, state.run.id},
      session_id: state.run.session_id,
      capability_registry: state.capability_registry,
      memory_repo: state.repo,
      memory_agent_id: state.job.created_by_agent_id || MemoryConfig.agent_id(),
      memory_owner_id: MemoryConfig.owner_id(),
      memory_source_id: state.job.memory_source_id,
      memory_source_type: "scheduled_job",
      memory_source_name: state.job.name,
      memory_read_scopes: state.job.memory_read_scopes,
      job_id: state.job.id,
      run_id: state.run.id,
      skill_name: if(skill, do: skill.name),
      # Part B §11.1: the same run trust that selects the capability surface also
      # selects any delegated worker's surface (one derivation, two consumers),
      # so an operator cron run can fan out via `subagents` while a guest run
      # never sees the tool (policy-class exclusion). `worker_routing` places
      # workers on the run's own route (an injected adapter rides `:provider`, a
      # resolved chain rides `:ordered_routes`) rather than re-resolving the
      # global primary.
      source_trust: trust,
      # Cron owns transient recovery via its own deadline-bounded outer backoff
      # (run_agent_loop_with_retry), whose longer waits suit the wake-from-sleep
      # race better than the inner loop's quick retries — so opt the route-level
      # retry out and avoid stacking two retry loops on the same error.
      route_transient_retry: false
    }
    |> Map.merge(worker_routing)
  end

  # Proactive readiness gate (Layer 2 of the wake-from-sleep defense). Before
  # the first LLM call, poll a cheap TCP connect against the run's primary-route
  # host until the local network is actually reachable, so a run that fired
  # moments after the host resumed does not burn its first attempt on a dead
  # network. Advisory only: an exhausted budget returns `:unready` and the run
  # proceeds regardless — the transient-backoff retry below stays the floor.
  # Skipped when disabled, or when no route host is known (an injected adapter
  # in tests carries no `:routes`).
  # Spread a wake-time burst: when the scheduler fires many due jobs at once,
  # each runner waits a short, capped delay (assigned by the scheduler from how
  # many runs are already active) before its first network call, so they don't
  # all check out HTTP connections at the same instant — when the pool is least
  # ready, just after wake-from-sleep. Zero for a lone run. Uses delay_fn so
  # tests don't actually sleep.
  defp stagger_start(%{start_delay_ms: ms} = state) when is_integer(ms) and ms > 0 do
    state.delay_fn.(ms)
  end

  defp stagger_start(_state), do: :ok

  defp await_network_ready(_loop_opts, %{readiness_enabled: false}), do: :ok

  defp await_network_ready(loop_opts, state) do
    case readiness_target(loop_opts, state) do
      {host, port} ->
        _result = Readiness.await(host, port, readiness_opts(state))
        :ok

      :none ->
        :ok
    end
  end

  # An explicit host/port (test injection) wins; production derives the target
  # from the resolved primary route's base URL.
  defp readiness_target(_loop_opts, %{readiness_host: host, readiness_port: port})
       when is_binary(host) and is_integer(port) do
    {host, port}
  end

  defp readiness_target(loop_opts, _state) do
    loop_opts
    |> Keyword.get(:routes, [])
    |> primary_route_target()
  end

  defp primary_route_target([{%{base_url: base_url}, _opts} | _rest]) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        {host, port}

      _unparseable ->
        :none
    end
  end

  defp primary_route_target(_routes), do: :none

  defp readiness_opts(state) do
    Keyword.put(state.readiness_opts, :delay_fn, state.delay_fn)
  end

  # Re-run the whole loop on a transient-infrastructure failure (see the
  # @default_max_transient_* attributes). Provider failover cannot recover the
  # wake-from-sleep network race — every provider shares the dead local
  # network — so the time-delayed retry lives here, in the cron-specific path
  # where "the host just woke" is the expected condition. A live user turn,
  # by contrast, just surfaces the one error and the user retries.
  defp run_agent_loop_with_retry(loop_opts, state) do
    run_agent_loop_with_retry(loop_opts, state, 0, 0)
  end

  defp run_agent_loop_with_retry(loop_opts, state, attempt, elapsed_ms) do
    case run_agent_loop(loop_opts, state) do
      {{:error, reason}, tools_started?} ->
        retry_or_fail(reason, tools_started?, loop_opts, state, attempt, elapsed_ms)

      {other, _tools_started?} ->
        other
    end
  end

  defp retry_or_fail(reason, tools_started?, loop_opts, state, attempt, elapsed_ms) do
    cond do
      # Idempotency gate: the whole-loop retry replays every completed tool call
      # (and its side effects). Once any tool has executed this attempt, a
      # connection loss is a mid-run failure like any other and fails loudly —
      # the retry only exists for the wake-from-sleep race that kills the FIRST
      # LLM call, before any tool ran.
      tools_started? ->
        {:error, reason}

      # Cron retries ONLY the fast wake-from-sleep pool-checkout race, NOT the
      # broader transient set the interactive route-retry uses. A provider
      # timeout/5xx already burned its receive-timeout budget, and the watchdog
      # is recreated per attempt with only backoff counted against the budget, so
      # retrying slow failures would let a run exceed its configured job timeout.
      not Transient.connection_unavailable?(reason) ->
        {:error, reason}

      attempt >= state.max_transient_attempts ->
        log_retry_exhausted(state, :attempts, reason)
        {:error, reason}

      transient_budget_exceeded?(state, attempt, elapsed_ms) ->
        log_retry_exhausted(state, :budget, reason)
        {:error, reason}

      true ->
        retry_after_backoff(reason, loop_opts, state, attempt, elapsed_ms)
    end
  end

  defp retry_after_backoff(reason, loop_opts, state, attempt, elapsed_ms) do
    delay_ms = transient_backoff_ms(state, attempt)

    Logger.warning(
      "Scheduled job #{state.job.id} transient infrastructure failure " <>
        "(#{transient_reason_kind(reason)}); retry #{attempt + 1}/#{state.max_transient_attempts} " <>
        "after #{delay_ms}ms backoff"
    )

    state.delay_fn.(delay_ms)
    run_agent_loop_with_retry(loop_opts, state, attempt + 1, elapsed_ms + delay_ms)
  end

  # The single transient-infrastructure signature the runner recovers from: HTTP
  # pool-checkout exhaustion. Failover treats it as terminal (every route shares
  # the one dead local network), so it reaches the runner unfailed-over — either
  # as the typed `:connection_unavailable` transport error (Codex mints it) or as
  # the bare Finch %RuntimeError{} the other providers return. Recognizing both
  # keeps recovery provider-agnostic. Every other error — auth, provider 5xx, an
  # exhausted failover chain, deterministic bugs — fails the run as before.
  defp transient_reason_kind({:provider_transport_error, %{kind: kind}}), do: kind
  defp transient_reason_kind(%RuntimeError{}), do: :connection_unavailable
  defp transient_reason_kind(_reason), do: :unknown

  # Exponential backoff, capped per step at the cumulative ceiling so a single
  # sleep never overshoots the budget. attempt is 0-based (0 = before retry 1).
  defp transient_backoff_ms(state, attempt) do
    min(state.transient_backoff_ms * Integer.pow(2, attempt), state.max_transient_retry_ms)
  end

  defp transient_budget_exceeded?(state, attempt, elapsed_ms) do
    elapsed_ms + transient_backoff_ms(state, attempt) > state.max_transient_retry_ms
  end

  defp log_retry_exhausted(state, :attempts, reason) do
    Logger.error(
      "Scheduled job #{state.job.id} exhausted transient-infrastructure retries " <>
        "(#{state.max_transient_attempts}); failing run. Last reason: #{inspect(reason)}"
    )
  end

  defp log_retry_exhausted(state, :budget, reason) do
    Logger.error(
      "Scheduled job #{state.job.id} exhausted transient-infrastructure retry budget " <>
        "(#{state.max_transient_retry_ms}ms); failing run. Last reason: #{inspect(reason)}"
    )
  end

  defp run_agent_loop(loop_opts, state) do
    parent = self()
    activity_ref = make_ref()

    loop_opts =
      Keyword.put(loop_opts, :activity_callback, fn event ->
        send(parent, {:job_loop_activity, activity_ref, event})
      end)

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {:job_loop_result, activity_ref, AgentLoop.run(loop_opts)})
      end)

    watch_loop(pid, monitor_ref, activity_ref, %{
      started_at: monotonic_ms(),
      last_activity_at: monotonic_ms(),
      timeout_ms: state.timeout_ms,
      inactivity_timeout_ms: state.inactivity_timeout_ms,
      active_tools: 0,
      tools_started?: false
    })
  end

  # Returns `{result, tools_started?}`: the loop result plus whether any tool
  # executed this attempt, which gates the whole-loop transient retry (a retry
  # after a tool ran would replay its side effects).
  defp watch_loop(pid, monitor_ref, activity_ref, watchdog) do
    case receive_watchdog_message(next_watchdog_wait(watchdog)) do
      {:job_loop_result, ^activity_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {result, watchdog.tools_started?}

      {:job_loop_activity, ^activity_ref, event} ->
        watch_loop(pid, monitor_ref, activity_ref, update_watchdog_activity(watchdog, event))

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {{:error, {:agent_loop_exit, reason}}, watchdog.tools_started?}

      :watchdog_timeout ->
        handle_watchdog_timeout(pid, monitor_ref, activity_ref, watchdog)

      _other ->
        watch_loop(pid, monitor_ref, activity_ref, watchdog)
    end
  end

  defp receive_watchdog_message(:infinity) do
    receive do
      message -> message
    end
  end

  defp receive_watchdog_message(wait_ms) do
    receive do
      message -> message
    after
      wait_ms -> :watchdog_timeout
    end
  end

  defp handle_watchdog_timeout(pid, monitor_ref, activity_ref, watchdog) do
    now = monotonic_ms()

    cond do
      timeout_due?(watchdog, now) ->
        kill_loop(pid, monitor_ref)
        {{:timeout, "wall-clock timeout after #{watchdog.timeout_ms}ms"}, watchdog.tools_started?}

      inactivity_due?(watchdog, now) ->
        kill_loop(pid, monitor_ref)

        {{:timeout, "inactivity timeout after #{watchdog.inactivity_timeout_ms}ms"},
         watchdog.tools_started?}

      true ->
        watch_loop(pid, monitor_ref, activity_ref, watchdog)
    end
  end

  defp kill_loop(pid, monitor_ref) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
    after
      100 -> :ok
    end
  end

  defp next_watchdog_wait(watchdog) do
    now = monotonic_ms()

    [
      deadline_wait(watchdog.started_at, watchdog.timeout_ms, now),
      inactivity_wait(watchdog, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :infinity
      waits -> waits |> Enum.min() |> max(0)
    end
  end

  defp inactivity_wait(%{active_tools: active_tools}, _now) when active_tools > 0, do: nil

  defp inactivity_wait(watchdog, now) do
    deadline_wait(watchdog.last_activity_at, watchdog.inactivity_timeout_ms, now)
  end

  defp deadline_wait(_start, nil, _now), do: nil
  defp deadline_wait(start, duration, now), do: start + duration - now

  defp timeout_due?(%{timeout_ms: nil}, _now), do: false
  defp timeout_due?(watchdog, now), do: now - watchdog.started_at >= watchdog.timeout_ms

  defp inactivity_due?(%{inactivity_timeout_ms: nil}, _now), do: false
  defp inactivity_due?(%{active_tools: active_tools}, _now) when active_tools > 0, do: false

  defp inactivity_due?(watchdog, now) do
    now - watchdog.last_activity_at >= watchdog.inactivity_timeout_ms
  end

  defp update_watchdog_activity(watchdog, {:tool_start, _name}) do
    %{
      watchdog
      | last_activity_at: monotonic_ms(),
        active_tools: watchdog.active_tools + 1,
        tools_started?: true
    }
  end

  defp update_watchdog_activity(watchdog, {:tool_finish, _name}) do
    %{
      watchdog
      | last_activity_at: monotonic_ms(),
        active_tools: max(watchdog.active_tools - 1, 0)
    }
  end

  defp update_watchdog_activity(watchdog, _event) do
    %{watchdog | last_activity_at: monotonic_ms()}
  end

  defp write_run_artifact(state, filename, content) do
    ref = Path.join(["job_runs", state.run.id, filename])
    path = Path.join(state.output_base_dir, ref)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, ref}
    end
  end

  defp success_artifact(state, result) do
    """
    # Scheduled Job Output

    Job: #{state.job.name}
    Job ID: #{state.job.id}
    Run ID: #{state.run.id}
    Session ID: #{state.run.session_id}

    ## Final Response

    #{result.response}
    """
  end

  defp failure_artifact(state, status, error) do
    """
    # Scheduled Job Failure

    Job: #{state.job.name}
    Job ID: #{state.job.id}
    Run ID: #{state.run.id}
    Session ID: #{state.run.session_id}
    Status: #{status}

    ## Error

    #{error}
    """
  end

  defp failure_delivery_text(state, status, error) do
    """
    Scheduled job "#{state.job.name}" finished with #{status}.

    Run ID: #{state.run.id}
    Error: #{error}
    """
    |> String.trim()
  end

  defp job_config_snapshot(job, loop_input) do
    %{
      "job_id" => job.id,
      "name" => job.name,
      "task_prompt" => job.task_prompt,
      "schedule_kind" => job.schedule_kind,
      "schedule_expr" => job.schedule_expr,
      "timezone" => job.timezone,
      "session_mode" => job.session_mode,
      "provider" => job.provider,
      "model" => job.model,
      "max_iterations" => job.max_iterations,
      "timeout_seconds" => job.timeout_seconds,
      "inactivity_timeout_seconds" => job.inactivity_timeout_seconds,
      "memory_read_scopes" => job.memory_read_scopes,
      "memory_write_scope" => job.memory_write_scope,
      "delivery_mode" => job.delivery_mode,
      "delivery_target" => job.delivery_target,
      # The route actually resolved for this run — for an unpinned job that used
      # the global cron_* default, job.provider/job.model are nil while this
      # records what ran (docs/design/SUBAGENT_MODEL_SELECTION.md §5d).
      "route_used" => loop_input.route_used
    }
  end

  # Resolved once, in `build_loop_input`'s success branch, so the `mark_running`
  # snapshot never re-resolves. The old second resolution re-raised on the
  # route-failure path — stranding the run mid-mark instead of recording a clean
  # failure (the fallback input carries `route_used: nil`). When the loop got a
  # resolved chain we reuse it directly; an injected adapter (tests) has no
  # `:routes`, so we resolve the job's config route once to record what its
  # config implies.
  defp resolved_route_used(loop_opts, job) do
    case Keyword.get(loop_opts, :routes) do
      [{route_key, adapter_opts} | _] ->
        route_used_map(route_key.provider, route_key.model, adapter_opts)

      _no_routes ->
        job_route_descriptor(job)
    end
  end

  defp job_route_descriptor(job) do
    case job_routes(job) do
      [{route_key, adapter_opts} | _] ->
        route_used_map(route_key.provider, route_key.model, adapter_opts)

      _empty ->
        nil
    end
  end

  defp route_used_map(provider, model, adapter_opts) do
    %{
      "provider" => stringify(provider),
      "model" => model,
      "reasoning_effort" => stringify(adapter_opts[:reasoning_effort])
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp capability_policy_snapshot(job) do
    %{
      "capability_policy" => job.capability_policy,
      "allowed_tools" => job.allowed_tools
    }
  end

  defp default_output_base_dir do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:output_base_dir, Path.join(ConfigStore.fermix_home(), "job_runs"))
  end

  defp default_delivery_channels do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:delivery_channels, %{})
  end

  defp network_readiness_enabled? do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:network_readiness_enabled, true)
  end

  defp delivery_opts(state) do
    [
      adapter: state.delivery_adapter,
      channels: state.delivery_channels,
      delivery_opts: state.delivery_opts,
      timeout_ms: state.delivery_timeout_ms
    ]
  end

  defp default_delivery_timeout_ms do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:delivery_timeout_ms, @default_delivery_timeout_ms)
  end

  defp default_timeout_ms(opts) do
    Keyword.get(opts, :default_timeout_ms) ||
      :fermix_core
      |> Application.get_env(:jobs, [])
      |> Keyword.get(:default_timeout_ms, @default_timeout_ms)
  end

  # Precedence: caller opt > job column > nil (the wall-clock caller adds the
  # daemon default on top). Keyed on the VALUE, not the key's presence: every
  # caller builds this opt list positionally (`timeout_ms: state.timeout_ms`),
  # so an unset timeout arrives as a present key with a nil value. Testing
  # presence made that nil read as "explicitly configured", shadowing the job's
  # own timeout_seconds/inactivity_timeout_seconds.
  defp configured_timeout_ms(opts, job, direct_key, seconds_key) do
    cond do
      is_integer(Keyword.get(opts, direct_key)) ->
        Keyword.fetch!(opts, direct_key)

      is_integer(Map.get(job, seconds_key)) ->
        Map.fetch!(job, seconds_key) * 1_000

      true ->
        nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp notify(pid, message) when is_pid(pid), do: send(pid, message)
  defp notify(_pid, _message), do: :ok
end
