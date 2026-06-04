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
  alias FermixCore.Providers.RouteResolver
  alias FermixCore.Setup.ConfigStore

  @default_timeout_ms 30 * 60 * 1_000
  @default_delivery_timeout_ms 60_000
  @default_capability_policy [:read_only, :network]
  @scheduled_job_trust :operator

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
          inactivity_timeout_ms: pos_integer() | nil
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
        )
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
    case run_agent_loop(loop_input.loop_opts, state) do
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
        job_config_snapshot: job_config_snapshot(state.job),
        capability_policy_snapshot: capability_policy_snapshot(state.job),
        updated_at: now
      })

    {:ok, run} = Repo.upsert_job_run(attrs, server: state.repo)
    JobTelemetry.run_start(state.job, run, loop_input)
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
         loop_opts: Keyword.put(loop_opts, :messages, messages)
       }}
    end
  end

  defp fallback_loop_input(state, reason) do
    messages = [
      %{role: "system", content: cron_guidance()},
      %{role: "user", content: state.job.task_prompt}
    ]

    %{
      messages: messages,
      prompt_snapshot: prompt_snapshot(messages) <> "\n\nPrompt setup error: #{inspect(reason)}",
      loop_opts: [messages: messages]
    }
  end

  defp load_skill(%{job: %{skill_name: nil}}), do: {:ok, nil}
  defp load_skill(%{job: %{skill_name: ""}}), do: {:ok, nil}

  defp load_skill(state) do
    SkillRegistry.load(state.skill_registry, state.job.skill_name)
  end

  defp prompt_messages(job, skill) do
    [
      %{role: "system", content: cron_guidance()},
      skill_prompt_message(skill, job),
      %{role: "system", content: job_context_prompt(job)},
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

    base = [
      context: loop_context(state, skill),
      capability_registry: state.capability_registry,
      allowed_tools: narrow_allowed_tools(state.job.allowed_tools),
      policy: scheduled_policy(state.job.capability_policy, trust),
      trust: trust,
      max_iterations: state.job.max_iterations
    ]

    {:ok, add_adapter_opts(base, state)}
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

  # Audit F-08 step 2 — intersection at run time.
  #
  # The persisted `created_by_trust` is the ceiling the creator could
  # reach at creation. The runner uses it as the *floor* for the run's
  # trust value, so the registry's per-trust policy default kicks in
  # (e.g., `:guest` → :read_only). The capability_policy field is now
  # empty for jobs created after this commit — the model can't widen
  # the future run's policy class.
  #
  # Persisted strings are migrated to the new vocabulary by the
  # `created_by_trust_rename` Memory.Repo migration; unknown values
  # fall through to the safe default (`@scheduled_job_trust`).
  defp effective_trust(%{created_by_trust: "operator"}), do: :operator
  defp effective_trust(%{created_by_trust: "guest"}), do: :guest
  defp effective_trust(_job), do: @scheduled_job_trust

  defp add_adapter_opts(base, %{adapter: adapter, adapter_opts: adapter_opts})
       when is_atom(adapter) and not is_nil(adapter) do
    base
    |> Keyword.put(:adapter, adapter)
    |> Keyword.put(:adapter_opts, adapter_opts)
  end

  defp add_adapter_opts(base, state) do
    {route_key, adapter_opts} = RouteResolver.resolve!(route_opts(state.job))

    base
    |> Keyword.put(:route_key, route_key)
    |> Keyword.put(:adapter_opts, adapter_opts)
  end

  defp route_opts(job) do
    []
    |> maybe_put(:provider, provider_atom(job.provider))
    |> maybe_put(:model, job.model)
  end

  defp provider_atom(nil), do: nil
  defp provider_atom("openai"), do: :openai
  defp provider_atom("openai_codex"), do: :openai_codex
  defp provider_atom("anthropic"), do: :anthropic

  defp provider_atom(other) when is_binary(other) do
    raise ArgumentError, "unsupported scheduled job provider #{inspect(other)}"
  end

  defp provider_atom(other) when is_atom(other), do: other

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

  defp loop_context(state, skill) do
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
      skill_name: if(skill, do: skill.name)
    }
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
      active_tools: 0
    })
  end

  defp watch_loop(pid, monitor_ref, activity_ref, watchdog) do
    case receive_watchdog_message(next_watchdog_wait(watchdog)) do
      {:job_loop_result, ^activity_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:job_loop_activity, ^activity_ref, event} ->
        watch_loop(pid, monitor_ref, activity_ref, update_watchdog_activity(watchdog, event))

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:agent_loop_exit, reason}}

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
        {:timeout, "wall-clock timeout after #{watchdog.timeout_ms}ms"}

      inactivity_due?(watchdog, now) ->
        kill_loop(pid, monitor_ref)
        {:timeout, "inactivity timeout after #{watchdog.inactivity_timeout_ms}ms"}

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
    %{watchdog | last_activity_at: monotonic_ms(), active_tools: watchdog.active_tools + 1}
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

  defp job_config_snapshot(job) do
    %{
      "job_id" => job.id,
      "name" => job.name,
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
      "delivery_target" => job.delivery_target
    }
  end

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

  defp configured_timeout_ms(opts, job, direct_key, seconds_key) do
    cond do
      Keyword.has_key?(opts, direct_key) ->
        Keyword.get(opts, direct_key)

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
