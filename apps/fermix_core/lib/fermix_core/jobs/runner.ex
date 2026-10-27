defmodule FermixCore.Jobs.Runner do
  @moduledoc """
  Scheduled-job runner.

  It records the lifecycle for a claimed job run, builds the isolated cron
  prompt, runs one bounded AgentLoop execution, and persists run artifacts.
  """

  use GenServer
  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.Skill
  alias FermixCore.Clock
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Notices
  alias FermixCore.Jobs.CueAdmission
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Jobs.CueSurface
  alias FermixCore.Jobs.Delivery
  alias FermixCore.Jobs.MediaBridge
  alias FermixCore.Jobs.Telemetry, as: JobTelemetry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Net.Egress
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

  # Ceiling for the logged text of a crash inside the AgentLoop process: the
  # exception and its top frames, bounded like every other raw-payload log.
  @crash_log_max 2_000

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
          readiness_opts: keyword(),
          cue: nil | {:ok, CueRun.context()} | {:error, term()},
          cue_mandate: Mandates.t() | nil,
          cue_mandate_opts: keyword()
        }

  # A runner spends its whole run inside `handle_continue/2`, so it cannot answer
  # a message until the run is over. The scheduler's crash reconciliation still
  # has to map a live child pid back to the run it is executing, so the run id is
  # published under a process-dictionary key (not OTP's `Process.set_label/1` —
  # this predates a hard OTP 27 floor) during `init/1` — before the pid ever
  # reaches the supervisor's caller — and read out-of-band with `Process.info/2`.
  # Any module used as a runner must publish it the same way or its run is
  # treated as orphaned.
  @run_id_key :fermix_job_run_id

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Publish the run id this process is executing, for out-of-band liveness lookup.
  """
  @spec put_run_id(String.t()) :: :ok
  def put_run_id(run_id) when is_binary(run_id) do
    Process.put(@run_id_key, run_id)
    :ok
  end

  @doc """
  The run id a runner process published, or `nil` when it is dead or unlabelled.
  """
  @spec run_id(pid()) :: String.t() | nil
  def run_id(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, @run_id_key)
      nil -> nil
    end
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
      readiness_opts: Keyword.get(opts, :readiness_opts, []),
      egress: Keyword.get_lazy(opts, :egress, &Egress.active/0),
      # A cue run's delivery, cue and watcher (M60 §9.3), read at the start of
      # the run from the delivery its row holds; nil for every other run.
      cue: nil,
      # The mandate a cue run acts under, read once at its start; nil otherwise.
      cue_mandate: nil,
      # Test seams for that read and for the run's mandate gate, one set for
      # both (the gate's `cue_mandate_opts`); none in production.
      cue_mandate_opts: Keyword.get(opts, :cue_mandate_opts, [])
    }

    :ok = put_run_id(state.run.id)

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    state = load_cue(state)

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
        failed_run = mark_failed(%{state | run: run}, "error", reason)
        notify(state.notify, {:job_runner, :completed, failed_run.id, state.job.id})
        {:stop, :normal, %{state | run: failed_run}}
    end
  end

  defp execute_and_finalize(state, loop_input) do
    stagger_start(state)
    await_network_ready(loop_input.loop_opts, state)

    result = run_agent_loop_with_retry(loop_input.loop_opts, state)

    # The media closure dies with the run, not with the runner process: a leaked
    # copy (a straggling task, a subagent that somehow kept it) must not be able
    # to send after the loop returned — so the flag drops BEFORE the run is
    # marked and its final text delivered.
    deactivate_media(loop_input)

    case result do
      {:ok, result} ->
        complete_run(state, result)

      {:timeout, reason} ->
        mark_failed(state, "timeout", reason)

      {:error, reason} ->
        mark_failed(state, "error", reason)
    end
  end

  # A cue run (M60 §9.3, §9.4) settles its delivery with its outcome, writes no
  # `latest` summary, and sends the owner its prefixed message with Fermix's
  # report of its mandate calls, even when the reply is the silent marker.
  defp complete_run(%{cue: {:ok, cue}} = state, result) do
    calls = run_calls!(state)
    outcome = CueRun.outcome({:ok, result}, state.job, calls)
    message = CueRun.message(state.job, cue, result.response, calls)
    {completed_run, job} = mark_cue_completed(state, result, outcome, message)
    completed_state = %{state | run: completed_run}

    update_memory_source_status(job, "ok", completed_run.completed_at, state.repo)
    finalize_cue_delivery(completed_state, message)
  end

  defp complete_run(state, result) do
    {completed_run, job} = mark_completed(state, result)
    completed_state = %{state | run: completed_run}

    persist_run_summary_memory(completed_state, result)
    update_memory_source_status(job, "ok", completed_run.completed_at, state.repo)
    finalize_delivery(completed_state, result.response)
  end

  # Read once the loop has returned, so every call the run made is in it. A
  # Repo that cannot answer fails the runner loudly; the scheduler's crash
  # settle then moves the delivery by the run row.
  defp run_calls!(state) do
    {:ok, calls} = CueRun.list_run_calls(state.run.id, repo: state.repo)
    calls
  end

  # The mandate is read once, at the run's start, on the run's Repo (as its
  # gate reads it): that read may disable a changed mandate and tell the owner
  # (`CueRun.mandate/2`), and the run's tool list and context both use it.
  defp load_cue(%{run: %{trigger: "cue", cue_delivery_id: delivery_id}} = state)
       when is_integer(delivery_id) do
    case CueRun.load(delivery_id, repo: state.repo) do
      {:ok, _cue} = cue ->
        opts = Keyword.put_new(state.cue_mandate_opts, :repo, state.repo)
        %{state | cue: cue, cue_mandate: CueRun.mandate(state.job, opts)}

      error ->
        %{state | cue: error}
    end
  end

  defp load_cue(state), do: state

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
    JobTelemetry.run_start(state.job, telemetry_run(state, run), loop_input, state.timeout_ms)
    run
  end

  # `Jobs.Telemetry` reads a cue run's watcher from the run map: the row does
  # not carry it.
  defp telemetry_run(%{cue: {:ok, cue}}, run), do: Map.put(run, :watcher_id, cue.watcher.id)
  defp telemetry_run(_state, run), do: run

  # The final run row and the job's release land in one settle
  # (`Repo.settle_job_run/2`): a runner that dies after it leaves a released
  # job, one that dies before it leaves a run the Scheduler's reaper settles.
  # The release now lands before the run summary memory; a job's next run reads
  # that memory through tools, never at prompt build, so the order is safe.
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
        tool_failures: result.tool_failures,
        token_usage: %{"total" => result.total_tokens},
        latency: %{},
        delivery_status: Delivery.initial_status(state.job, result.response),
        updated_at: now
      })

    {:ok, {run, job}} = Repo.settle_job_run(attrs, server: state.repo)
    JobTelemetry.run_complete(state.job, run, result)
    {run, job}
  end

  # The cue run's settle (`CueAdmission.settle/3`) moves its delivery in the
  # same transaction. Its artifact holds ids and the outcome, never the reply;
  # the reply stays on the run row, which `get_job_run` withholds outside an
  # attended turn (§9.3).
  defp mark_cue_completed(state, result, outcome, message) do
    now = DateTime.utc_now()
    {:ok, output_ref} = write_run_artifact(state, "output.md", cue_artifact(state, "ok", outcome))

    attrs =
      state.run
      |> Map.merge(%{
        status: "ok",
        completed_at: now,
        output_ref: output_ref,
        final_response: result.response,
        iterations: result.iterations,
        tool_failures: result.tool_failures,
        token_usage: %{"total" => result.total_tokens},
        latency: %{},
        delivery_status: Delivery.initial_status(state.job, message),
        updated_at: now
      })

    {:ok, {run, job, settlement}} = CueAdmission.settle(attrs, outcome, server: state.repo)
    mark_gaps_told(state, settlement)
    JobTelemetry.run_complete(state.job, telemetry_run(state, run), result)
    {run, job}
  end

  # The gaps a run's prompt named are marked reported (and closed) once the
  # owner is told: by an acked run, or by the final failure, whose text names
  # them. A retried attempt leaves them for the next one. A mark that fails is
  # logged; the gap stays unreported and the hourly gap sweep tells the owner.
  defp mark_gaps_told(_state, %{disposition: :retry}), do: :ok

  defp mark_gaps_told(%{cue: {:ok, cue}} = state, _settlement) do
    case CueRun.mark_gaps_reported(cue, DateTime.utc_now(), repo: state.repo) do
      {:ok, _marked} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Cue run #{state.run.id}: its gaps were not marked reported: #{inspect(reason)}"
        )
    end
  end

  defp mark_gaps_told(_state, _settlement), do: :ok

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

  # A cue run's failure settles its delivery by its outcome (M60 §9.4). A
  # retried attempt sends and writes nothing the owner reads: no failure text,
  # no memory-source status. The delivery's final failure sends the failure
  # text once, prefixed, with Fermix's report of the run's mandate calls.
  defp mark_failed(%{cue: cue} = state, status, reason)
       when not is_nil(cue) and status in ["error", "timeout"] do
    now = DateTime.utc_now()
    error = persisted_error(status, reason)
    calls = run_calls!(state)
    outcome = CueRun.outcome(failure_result(status, reason), state.job, calls)
    text = cue_failure_text(state, status, reason, calls)

    {:ok, output_ref} =
      write_run_artifact(state, "error.md", cue_artifact(state, status, outcome))

    attrs =
      state.run
      |> Map.merge(%{
        status: status,
        completed_at: now,
        output_ref: output_ref,
        error: error,
        delivery_status: Delivery.initial_status(state.job, text),
        updated_at: now
      })

    {:ok, {run, job, settlement}} = CueAdmission.settle(attrs, outcome, server: state.repo)
    mark_gaps_told(state, settlement)
    JobTelemetry.run_error(state.job, telemetry_run(state, run), status, error)
    failed_state = %{state | run: run}
    notify_provider_down(failed_state, settlement, outcome)
    finish_cue_failure(failed_state, job, settlement, {status, now, text})
  end

  defp mark_failed(state, status, reason) when status in ["error", "timeout"] do
    now = DateTime.utc_now()
    error = persisted_error(status, reason)
    text = failure_delivery_text(state, status, reason)

    {:ok, output_ref} =
      write_run_artifact(state, "error.md", failure_artifact(state, status, reason))

    attrs =
      state.run
      |> Map.merge(%{
        status: status,
        completed_at: now,
        output_ref: output_ref,
        error: error,
        delivery_status: Delivery.initial_status(state.job, text),
        updated_at: now
      })

    {:ok, {run, job}} = Repo.settle_job_run(attrs, server: state.repo)
    failed_state = %{state | run: run}
    JobTelemetry.run_error(state.job, run, status, error)
    update_memory_source_status(job, status, now, state.repo)
    finalize_delivery(failed_state, text)
  end

  # A provider failure that will be retried tells the owner once per outage
  # (design §9.4 row 3, §9.5): `Cues.Notices` keeps `:task_provider_down` to
  # once per 24 hours and logs a send that failed.
  defp notify_provider_down(
         %{cue: {:ok, cue}} = state,
         %{disposition: :retry},
         {:failed, :provider}
       ) do
    opts = [
      repo: state.repo,
      adapter: state.delivery_adapter,
      channels: state.delivery_channels,
      delivery_opts: state.delivery_opts,
      timeout_ms: state.delivery_timeout_ms
    ]

    _sent_or_logged = Notices.watcher(cue.watcher.id, :task_provider_down, %{}, opts)
    :ok
  end

  defp notify_provider_down(_state, _settlement, _outcome), do: :ok

  # Nothing will retry a delivery that ended `exhausted`, or that left the run
  # (`untouched`), so only those tell the owner.
  defp finish_cue_failure(state, _job, %{disposition: :retry}, _failure),
    do: mark_delivery(state, "skipped", nil)

  defp finish_cue_failure(state, job, _final, {status, now, text}) do
    update_memory_source_status(job, status, now, state.repo)
    finalize_cue_delivery(state, text)
  end

  defp failure_result("timeout", reason), do: {:timeout, reason}
  defp failure_result("error", reason), do: {:error, reason}

  # Without its context (the delivery could not be read) the run has no
  # watcher to name and read no cue: the plain failure text goes.
  defp cue_failure_text(%{cue: {:ok, cue}} = state, status, reason, calls),
    do: CueRun.failure_message(cue, failure_delivery_text(state, status, reason), calls)

  defp cue_failure_text(state, status, reason, _calls),
    do: failure_delivery_text(state, status, reason)

  # Every message a cue run causes goes through `CueRun.deliver/3`: only to a
  # channel a cue run may reach, and with link previews off (§9.5).
  defp finalize_cue_delivery(state, text) do
    case CueRun.deliver(state.job, text, delivery_opts(state)) do
      {:ok, delivery_status} -> mark_delivery(state, delivery_status, nil)
      {:error, reason} -> mark_delivery(state, "failed", inspect(reason))
    end
  end

  # The ledger's machine-readable reason (run row, job row, telemetry): a
  # watchdog timeout's reason is already its own sentence; an error keeps the
  # inspected term. A run with no route keeps the text it had before the
  # reason was tagged.
  defp persisted_error("timeout", reason) when is_binary(reason), do: reason
  defp persisted_error("error", {:no_route, message}), do: inspect(message)
  defp persisted_error("error", {:skill_grants_nothing, sentence}), do: inspect(sentence)
  defp persisted_error("error", {:cue_history_lost, sentence}), do: inspect(sentence)
  defp persisted_error("error", reason), do: inspect(reason)

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

    # A refused write exits the runner with the outcome and its error in its
    # reason, so the Scheduler's crash path fails the still-pending delivery with
    # that cause at once, instead of a :normal exit leaving the row for the
    # reconcile pass's generic "no live runner" text.
    case Repo.upsert_job_run(attrs, server: state.repo) do
      {:ok, run} ->
        run

      {:error, reason} ->
        exit({:delivery_status_write_failed, delivery_status, delivery_error, reason})
    end
  end

  # The memory-source row mirrors the job's last run for display and nothing
  # gates on it, so a failed lookup or write is logged and the run goes on.
  defp update_memory_source_status(job, status, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{last_run_at: now, last_status: status, updated_at: now})
        |> Repo.upsert_memory_source(server: repo)
        |> log_memory_source_write(job)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("Scheduled job #{job.id} memory source lookup failed: #{inspect(reason)}")
    end
  end

  defp log_memory_source_write({:ok, _source}, _job), do: :ok

  defp log_memory_source_write({:error, reason}, job) do
    Logger.warning("Scheduled job #{job.id} memory source update failed: #{inspect(reason)}")
  end

  defp build_loop_input(%{cue: {:error, reason}}), do: {:error, {:cue_run_context, reason}}

  # A cue run sends no attachment (`send_attachment` is outside its surface),
  # so it binds no media route. The watcher's gaps its prompt names are marked
  # reported by the settle that tells the owner (`mark_gaps_told/2`).
  defp build_loop_input(%{cue: {:ok, cue}} = state) do
    media = {:unavailable, :cue_run}

    with {:ok, skill} <- load_skill(state),
         {:ok, loop_opts, _media} <- loop_opts(state, skill, media) do
      messages = cue_prompt_messages(state.job, skill, cue)

      {:ok,
       %{
         messages: messages,
         prompt_snapshot: prompt_snapshot(messages),
         route_used: resolved_route_used(loop_opts, state.job),
         loop_opts: Keyword.put(loop_opts, :messages, messages),
         media_active: nil
       }}
    end
  end

  defp build_loop_input(state) do
    media = build_media_bridge(state)

    with {:ok, skill} <- load_skill(state),
         {:ok, loop_opts, media} <- loop_opts(state, skill, media) do
      messages = prompt_messages(state.job, skill, media)

      {:ok,
       %{
         messages: messages,
         prompt_snapshot: prompt_snapshot(messages),
         route_used: resolved_route_used(loop_opts, state.job),
         loop_opts: Keyword.put(loop_opts, :messages, messages),
         media_active: media_active_ref(media)
       }}
    end
  end

  # Resolve once, bind once (M46 §7.1). `active` starts at 1 and is zeroed the
  # moment the loop returns; `sends` counts every media request this run made,
  # successful or not.
  defp build_media_bridge(state) do
    active = :atomics.new(1, signed: false)
    :atomics.put(active, 1, 1)

    opts = [
      adapter: state.delivery_adapter,
      channels: state.delivery_channels,
      delivery_opts: state.delivery_opts,
      delivery_timeout_ms: state.delivery_timeout_ms,
      deadline_ms: run_deadline_ms(state),
      active: active,
      sends: :atomics.new(1, signed: false)
    ]

    case MediaBridge.build(state.job, state.run, opts) do
      {:ok, reply_fn, target} ->
        {:ok, %{reply_fn: reply_fn, active: active, platform: target.platform}}

      {:unavailable, reason} ->
        {:unavailable, reason}
    end
  end

  defp run_deadline_ms(%{timeout_ms: nil}), do: nil
  defp run_deadline_ms(%{timeout_ms: timeout_ms}), do: monotonic_ms() + timeout_ms

  # One fact draws both the prompt's attachment line and the media `reply_fn`
  # on the context: which tools that send files through the job's media route
  # (`send_attachment`, the `:media` generators) are on the run's own surface,
  # the registry list its loop resolves from the same options. A run with none
  # is neither told it can send files nor handed the route.
  defp media_on_surface({:unavailable, _reason} = media, _surface), do: media

  defp media_on_surface({:ok, route}, surface) do
    case for(%Capability{} = capability <- surface, media_tool?(capability), do: capability.name) do
      [] -> {:unavailable, :no_media_tool}
      tools -> {:ok, Map.put(route, :tools, tools)}
    end
  end

  defp media_tool?(%Capability{name: "send_attachment"}), do: true
  defp media_tool?(%Capability{metadata: metadata}), do: Map.get(metadata, :category) == :media

  defp media_active_ref({:ok, %{active: active}}), do: active
  defp media_active_ref({:unavailable, _reason}), do: nil

  defp deactivate_media(%{media_active: nil}), do: :ok
  defp deactivate_media(%{media_active: active}), do: :atomics.put(active, 1, 0)

  defp fallback_loop_input(state, reason) do
    messages = [
      %{role: "system", content: cron_guidance()},
      %{role: "system", content: CurrentDate.note()},
      run_message(state.job.task_prompt)
    ]

    %{
      messages: messages,
      media_active: nil,
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
  defp prompt_messages(job, skill, media) do
    [
      %{role: "system", content: cron_guidance()},
      skill_prompt_message(skill, job),
      %{role: "system", content: job_context_prompt(job, media)},
      %{role: "system", content: CurrentDate.note()},
      run_message(job.task_prompt)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The run's own message opens with the current time to the minute: scheduled
  # work reasons about time left, and the date note above stays date-only so
  # the cached prefix holds between runs.
  defp run_message(text),
    do: %{role: "user", content: Clock.now_line(DateTime.utc_now()) <> "\n\n" <> text}

  # A cue run's prompt (M60 §9.3): the cue guidance, the skill's prompt when
  # the job names one, the job context, the date, then one user message with
  # the task prompt, the framed cue and Fermix's gap notices.
  defp cue_prompt_messages(job, skill, cue) do
    [
      %{role: "system", content: CueRun.guidance(job)},
      skill_prompt_message(skill, job),
      %{role: "system", content: CueRun.job_context(job, cue)},
      %{role: "system", content: CurrentDate.note()},
      run_message(CueRun.user_message(job, cue))
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

  defp job_context_prompt(job, media) do
    """
    Scheduled job: #{job.name}
    Job id: #{job.id}
    Schedule: #{job.schedule_expr} (#{job.timezone})
    Memory source id: #{job.memory_source_id}
    Delivery mode: #{job.delivery_mode}
    #{attachment_line(media)}
    """
    |> String.trim()
  end

  # The prompt says what is actually wired (M46 §7.2), derived from the SAME
  # resolution the closure came from — never a hopeful sentence the run cannot
  # honour. Execute-time refusal stays the hard gate either way.
  defp attachment_line({:ok, %{platform: platform, tools: tools}}) do
    verb = if length(tools) == 1, do: "delivers", else: "deliver"

    "Attachments: #{Enum.join(tools, ", ")} #{verb} files to this job's configured " <>
      "#{platform} destination"
  end

  defp attachment_line({:unavailable, :no_media_tool}),
    do: "Attachments: unavailable (this run has no tool that sends files)"

  defp attachment_line({:unavailable, reason}) do
    "Attachments: unavailable (#{MediaBridge.unavailable_reason(reason)})"
  end

  defp prompt_snapshot(messages) do
    Enum.map_join(messages, "\n\n---\n\n", fn message ->
      "#{String.upcase(message.role)}:\n#{message.content}"
    end)
  end

  # The run's trust is the job's, met with its skill's: a plugin skill loads at
  # guest whoever calls it, so a job bound to one runs at guest, as `skill_run`
  # of it would. The context keeps the job's own trust as its `source_trust`
  # (the person), so the loop's `effective_trust` stamp marks the run as
  # narrowed by trust for any job it sets up or changes.
  #
  # Every registry read sits inside this rescue, so a failing registry is a run
  # error, recorded, never a runner crash.
  defp loop_opts(state, skill, media) do
    job_trust = effective_trust(state.job)
    trust = loop_trust(job_trust, skill)
    allowed_tools = run_allowed_tools(state, skill)

    with {:ok, policy} <- run_policy(state.job, job_trust, skill),
         surface = surface(state.capability_registry, trust, policy, allowed_tools),
         :ok <- check_cue_history(state, surface, skill),
         media = media_on_surface(media, surface),
         {:ok, {routing_opts, worker_routing}} <- run_routing(state) do
      base = [
        context: loop_context(state, skill, job_trust, worker_routing, media),
        capability_registry: state.capability_registry,
        allowed_tools: allowed_tools,
        policy: policy,
        trust: trust,
        max_iterations: state.job.max_iterations
      ]

      {:ok, base ++ routing_opts, media}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # The registry list the run's loop resolves from the same options (`AgentLoop`).
  defp surface(registry, trust, policy, allowed_tools) do
    CapabilityRegistry.list_for(registry,
      allowed_tools: allowed_tools,
      policy: policy,
      trust: trust
    )
  end

  @cue_history "cue_history"

  @doc """
  Whether a cue run of `job`, bound to `skill`, has `cue_history` on its
  surface: listed at the trust the run's loop runs at (the job's met with the
  skill's) with the classes it gets (`Capabilities.Skill.classes_within/2` of
  the job's grant). `cue_history` is owner-only and `:read_only`, so a plugin
  skill (guest) or one asking only for other classes leaves a watcher's task
  unable to read its watcher's deliveries. The one predicate behind
  `update_job`'s refusal and a cue run's failure (`cue_skill_sentence/1`).
  """
  @spec cue_history_on_surface?(map(), AgentDefinition.t() | nil, GenServer.server()) ::
          boolean()
  def cue_history_on_surface?(job, skill, registry) when is_map(job) do
    job_trust = effective_trust(job)

    case run_policy(job, job_trust, skill) do
      {:ok, policy} ->
        registry
        |> surface(loop_trust(job_trust, skill), policy, [@cue_history])
        |> cue_history?()

      {:error, _no_classes} ->
        false
    end
  end

  @doc "The sentence a watcher's task bound to `skill` without `cue_history` gets."
  @spec cue_skill_sentence(map()) :: String.t()
  def cue_skill_sentence(skill) do
    "Skill #{skill.name} leaves a watcher's task without cue_history, which the task " <>
      "reads its watcher's deliveries through: at the trust and capability classes the " <>
      "skill runs with, cue_history is not on its runs' surface. Bind another skill, or " <>
      "drop skill_name."
  end

  defp cue_history?(surface), do: Enum.any?(surface, &(&1.name == @cue_history))

  # A cue run whose skill leaves `cue_history` off its surface fails before the
  # model is asked, rather than run half-blind (a row bound before `update_job`
  # refused it). The surface is the run's own: its allowlist is the cue surface
  # built from the mandate and skill this run loaded once (`load_cue/1`).
  defp check_cue_history(%{cue: {:ok, _cue}}, surface, skill) do
    if cue_history?(surface),
      do: :ok,
      else: {:error, {:cue_history_lost, cue_skill_sentence(skill)}}
  end

  defp check_cue_history(_state, _surface, _skill), do: :ok

  # A route that cannot be resolved (no provider to select, an unknown pinned
  # provider) is tagged, so a cue run tells "no route", a provider failure,
  # from its other setup failures (M60 §9.4). The ledger and the failure text
  # read as they did before the tag (`persisted_error/2`, `job_error_sentence/1`).
  defp run_routing(state) do
    {:ok, resolve_run_routing(state)}
  rescue
    error -> {:error, {:no_route, Exception.message(error)}}
  end

  # The trust the run's loop runs at: the job's, met with its skill's.
  defp loop_trust(job_trust, nil), do: job_trust
  defp loop_trust(job_trust, skill), do: CapabilityRegistry.lower_trust(job_trust, skill.trust)

  # A cue run's exact surface is `Jobs.CueSurface`'s (M60 §9.3, S5), whatever
  # the job names; every other run keeps its job and skill allowlists.
  defp run_allowed_tools(%{cue: {:ok, cue}} = state, skill),
    do: CueSurface.tools(state.job, skill, cue.watcher, state.cue_mandate)

  defp run_allowed_tools(state, skill), do: effective_allowed_tools(state.job, skill)

  # `:operator` jobs run with the trust-derived registry default (full
  # operator surface). The static scheduled-job policy default
  # (`[:read_only, :network]`) would otherwise win at
  # `Registry.resolve_policy/2` and silently re-narrow an operator-created
  # job — defeating the `created_by_trust` ceiling captured at creation.
  defp scheduled_policy(_explicit, :operator), do: nil
  defp scheduled_policy(explicit, _trust), do: capability_policy(explicit)

  # The run's policy classes. With no skill, the job's own at the job's trust.
  # With one, the classes the skill declares at its own trust kept to the job's
  # grant, read at the job's trust: an operator job grants its trust's whole
  # default (its row's own policy is not read), a guest job its row's policy or
  # the scheduled-job default. That is `Capabilities.Skill.classes_within/2`,
  # the meet `skill_run` of the skill uses, so the job offers what `skill_run`
  # would within its grant. They are passed explicitly, since the loop runs at
  # the trust a plugin skill lowers. Only a guest job's grant can leave a skill
  # no class: the run fails loudly, with a sentence the owner can act on, rather
  # than leak back to a trust default.
  defp run_policy(job, job_trust, nil),
    do: {:ok, scheduled_policy(job.capability_policy, job_trust)}

  defp run_policy(job, job_trust, skill) do
    granted = job_policy_classes(scheduled_policy(job.capability_policy, job_trust), job_trust)

    case Skill.classes_within(skill, granted) do
      [] -> {:error, {:skill_grants_nothing, no_classes_sentence(skill, granted)}}
      classes -> {:ok, classes}
    end
  end

  defp no_classes_sentence(skill, granted) do
    "Skill #{skill.name} asks only for capability classes this job does not grant " <>
      "(it asks for #{class_words(skill)}; the job grants #{class_words(granted)}). The job " <>
      "was set up at guest trust, which is its limit: set it up again from the owner's own " <>
      "turn, bind another skill, or drop skill_name."
  end

  defp class_words(classes) when is_list(classes),
    do: Enum.map_join(classes, ", ", &Atom.to_string/1)

  defp class_words(skill), do: skill |> Skill.declared_classes() |> class_words()

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

  defp loop_context(state, skill, trust, worker_routing, media) do
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
      # What started this run, from its row ("schedule", "manual", or "cue" for
      # a run a cue woke): `Capabilities.AccessGate` refuses every
      # access-sensitive command in a cue run on it (M60 §10.5).
      trigger: Map.fetch!(state.run, :trigger),
      skill_name: if(skill, do: skill.name),
      # Part B §11.1: the job's own trust is the run's person. The loop runs at
      # the run trust (lowered by a plugin skill) and stamps it as
      # `effective_trust`; a delegated worker's surface derives from the lower of
      # the two (`CapabilityRegistry.run_trust/1`), so an operator cron run can
      # fan out via `subagents` while a guest run never sees the tool
      # (policy-class exclusion). `worker_routing` places
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
    |> put_media_reply_fn(media)
    |> put_cue_context(state)
  end

  # A cue run is tainted by its cue's source from its first token (S2) and
  # carries the cue's ids for the tools and gates that read them (PLAN §4.3).
  defp put_cue_context(context, %{cue: {:ok, cue}} = state) do
    context
    |> Map.merge(CueRun.run_context(cue, state.cue_mandate, state.run.claimed_at))
    |> Map.put(:cue_mandate_opts, state.cue_mandate_opts)
  end

  defp put_cue_context(context, _state), do: context

  # Present only when the run actually has a media route: a `reply_fn` a tool
  # cannot use is worse than none, because `send_attachment` would report a
  # delivery failure where the truth is "this job has nowhere to send".
  defp put_media_reply_fn(context, {:ok, %{reply_fn: reply_fn}}),
    do: Map.put(context, :reply_fn, reply_fn)

  defp put_media_reply_fn(context, {:unavailable, _reason}), do: context

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
        # Behind a proxy the first hop is the proxy: the route's own host is
        # not reachable from here, and probing it would spend the whole budget.
        {probe_host, probe_port} = Egress.readiness_target(state.egress, host, port)
        _result = Readiness.await(probe_host, probe_port, readiness_opts(state))
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

    # Linked AND monitored in one atomic call (ChannelSend's monitored_call
    # pattern): a runner shut down mid-run, as a :rest_for_one restart of an
    # earlier core child does, takes its loop with it, so the restarted
    # Scheduler's reap and next claim never run beside a live loop (JOB-8).
    # `report_loop/2` turns every raise, throw or exit of the loop body into a
    # value, so the loop exits :normal and the link carries only runner -> loop.
    # The closure takes the job id alone, not the runner state it would copy.
    job_id = state.job.id

    {pid, monitor_ref} =
      Process.spawn(
        fn -> send(parent, {:job_loop_result, activity_ref, report_loop(loop_opts, job_id)}) end,
        [:link, :monitor]
      )

    watch_loop(pid, monitor_ref, activity_ref, %{
      started_at: monotonic_ms(),
      last_activity_at: monotonic_ms(),
      timeout_ms: state.timeout_ms,
      inactivity_timeout_ms: state.inactivity_timeout_ms,
      active_tools: 0,
      tools_started?: false
    })
  end

  # Runs inside the loop process. A crash is logged here, bounded because it
  # can carry a response body, since the loop's :normal exit leaves no crash
  # report. Residual: a process the loop links to itself can still kill it with
  # an exit signal, and the link then takes the runner down too; the
  # Scheduler's DOWN path settles that run as "runner crashed", with no failure
  # text delivered and no run_error bookend (before JOB-8's fix that death was
  # a clean {:agent_loop_exit, _} failure).
  defp report_loop(loop_opts, job_id) do
    AgentLoop.run(loop_opts)
  catch
    kind, reason ->
      Logger.error(
        "Scheduled job #{job_id} AgentLoop crashed: " <>
          (kind |> Exception.format(reason, __STACKTRACE__) |> String.slice(0, @crash_log_max))
      )

      {:error, {:agent_loop_exit, reason}}
  end

  # The loop answered and is exiting :normal: drop its link and monitor. The
  # runner does not trap exits, so the link can have queued no {:EXIT, _, _}.
  defp release_loop(pid, monitor_ref) do
    Process.unlink(pid)
    Process.demonitor(monitor_ref, [:flush])
  end

  # Returns `{result, tools_started?}`: the loop result plus whether any tool
  # executed this attempt, which gates the whole-loop transient retry (a retry
  # after a tool ran would replay its side effects).
  defp watch_loop(pid, monitor_ref, activity_ref, watchdog) do
    case receive_watchdog_message(next_watchdog_wait(watchdog)) do
      {:job_loop_result, ^activity_ref, result} ->
        release_loop(pid, monitor_ref)
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

  # Unlink first, so the watchdog's kill cannot reach the runner through the
  # link. A runner killed between the two leaves its loop unlinked, the same
  # few-instruction residual as ChannelSend's kill_and_drain.
  defp kill_loop(pid, monitor_ref) do
    Process.unlink(pid)
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

  defp update_watchdog_activity(watchdog, {:tool_finish, _name, _outcome}) do
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
    Tool failures: #{result.tool_failures}

    ## Final Response

    #{result.response}
    """
  end

  defp failure_artifact(state, status, reason) do
    """
    # Scheduled Job Failure

    Job: #{state.job.name}
    Job ID: #{state.job.id}
    Run ID: #{state.run.id}
    Session ID: #{state.run.session_id}
    Status: #{status}

    ## Error

    #{failure_artifact_error(status, reason)}
    """
  end

  # A cue run's artifact records its ids and outcome only (M60 §9.3): its
  # reply and error can carry text the model wrote from the cue, and a file
  # tool or a shell in another run can read this folder.
  defp cue_artifact(state, status, outcome) do
    """
    # Cue Run #{if status == "ok", do: "Output", else: "Failure"}

    Job: #{state.job.name}
    Job ID: #{state.job.id}
    Run ID: #{state.run.id}
    Session ID: #{state.run.session_id}
    Delivery ID: #{state.run.cue_delivery_id}
    Watcher ID: #{cue_watcher_id(state)}
    Status: #{status}
    Outcome: #{outcome_label(outcome)}

    A cue run's reply and error are kept on its run record only.
    """
  end

  defp cue_watcher_id(%{cue: {:ok, cue}}), do: cue.watcher.id
  defp cue_watcher_id(_state), do: "unknown (the delivery could not be read)"

  defp outcome_label(:ignored), do: "ignored"
  defp outcome_label(:acted), do: "acted"
  defp outcome_label({:failed, :provider}), do: "failed on a provider failure"
  defp outcome_label({:failed, :other}), do: "failed"

  defp failure_artifact_error("timeout", reason), do: persisted_error("timeout", reason)

  defp failure_artifact_error("error", reason) do
    "#{job_error_sentence(reason)}\n\nDetail: #{persisted_error("error", reason)}"
  end

  defp failure_delivery_text(state, "timeout", reason) do
    """
    Scheduled job "#{state.job.name}" finished with timeout.

    Run ID: #{state.run.id}
    Error: #{persisted_error("timeout", reason)}
    """
    |> String.trim()
  end

  # An error leads with a sentence the owner can act on; the raw reason follows
  # as the detail the ledger keeps.
  defp failure_delivery_text(state, "error", reason) do
    """
    Scheduled job "#{state.job.name}" finished with error.
    #{job_error_sentence(reason)}

    Run ID: #{state.run.id}
    Detail: #{persisted_error("error", reason)}
    """
    |> String.trim()
  end

  defp job_error_sentence({:no_route, message}),
    do: TurnRunner.error_reply(message, surface: :job)

  defp job_error_sentence({:skill_grants_nothing, sentence}), do: sentence
  defp job_error_sentence({:cue_history_lost, sentence}), do: sentence
  defp job_error_sentence(reason), do: TurnRunner.error_reply(reason, surface: :job)

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
      delivery_opts: Keyword.put(state.delivery_opts, :proactive_key, "job:#{state.run.id}"),
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
