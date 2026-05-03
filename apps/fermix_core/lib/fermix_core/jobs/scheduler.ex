defmodule FermixCore.Jobs.Scheduler do
  @moduledoc """
  Scheduler for durable scheduled jobs.

  Owns due-job discovery, atomic claim, run record creation, and dispatch to
  supervised scheduled-job runners.
  """

  use GenServer
  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Schedule
  alias FermixCore.Memory.Repo

  @default_reconciliation_interval_ms 60_000
  @default_due_limit 20

  @type state :: %{
          enabled?: boolean(),
          timer_enabled?: boolean(),
          repo: GenServer.server(),
          capability_registry: GenServer.server(),
          skill_registry: GenServer.server(),
          runner_supervisor: Supervisor.supervisor(),
          runner_module: module(),
          adapter: module() | nil,
          adapter_opts: keyword(),
          delivery_adapter: module() | nil,
          delivery_opts: keyword(),
          delivery_channels: map() | keyword(),
          delivery_timeout_ms: non_neg_integer() | nil,
          output_base_dir: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          inactivity_timeout_ms: pos_integer() | nil,
          runner_notify: pid() | nil,
          runner_delay_ms: non_neg_integer(),
          reconciliation_interval_ms: pos_integer(),
          due_limit: pos_integer(),
          due_timer: reference() | nil,
          reconciliation_timer: reference() | nil,
          run_monitors: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec tick(GenServer.server(), keyword()) :: :ok
  def tick(server \\ __MODULE__, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    GenServer.call(server, {:tick, now})
  end

  @spec job_changed(GenServer.server()) :: :ok
  def job_changed(server \\ __MODULE__) do
    GenServer.cast(server, :job_changed)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?: Keyword.get(opts, :scheduler_enabled, jobs_config(:scheduler_enabled, true)),
      timer_enabled?: Keyword.get(opts, :timer_enabled, true),
      repo: Keyword.get(opts, :repo, Repo),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      runner_supervisor: Keyword.get(opts, :runner_supervisor, RunnerSupervisor),
      runner_module: Keyword.get(opts, :runner_module, Runner),
      adapter: Keyword.get(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      delivery_adapter: Keyword.get(opts, :delivery_adapter),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      delivery_channels:
        Keyword.get(opts, :delivery_channels, jobs_config(:delivery_channels, %{})),
      delivery_timeout_ms:
        Keyword.get(opts, :delivery_timeout_ms, jobs_config(:delivery_timeout_ms, 60_000)),
      output_base_dir: Keyword.get(opts, :output_base_dir),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      inactivity_timeout_ms: Keyword.get(opts, :inactivity_timeout_ms),
      runner_notify: Keyword.get(opts, :runner_notify),
      runner_delay_ms: Keyword.get(opts, :runner_delay_ms, 0),
      reconciliation_interval_ms:
        Keyword.get(
          opts,
          :reconciliation_interval_ms,
          jobs_config(:reconciliation_interval_ms, @default_reconciliation_interval_ms)
        ),
      due_limit: Keyword.get(opts, :due_limit, @default_due_limit),
      due_timer: nil,
      reconciliation_timer: nil,
      run_monitors: %{}
    }

    state =
      state
      |> schedule_due_timer()
      |> schedule_reconciliation_timer()

    {:ok, state}
  end

  @impl true
  def handle_call({:tick, %DateTime{} = now}, _from, state) do
    state =
      state
      |> run_due_jobs(now)
      |> schedule_due_timer()

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:job_changed, state) do
    {:noreply, schedule_due_timer(state)}
  end

  @impl true
  def handle_info(:due_tick, state) do
    state =
      state
      |> run_due_jobs(DateTime.utc_now())
      |> schedule_due_timer()

    {:noreply, state}
  end

  def handle_info(:reconcile_tick, state) do
    state =
      state
      |> run_due_jobs(DateTime.utc_now())
      |> schedule_due_timer()
      |> schedule_reconciliation_timer()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.run_monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | run_monitors: monitors}}

      {_run_info, monitors} when reason in [:normal, :shutdown] ->
        {:noreply, %{state | run_monitors: monitors}}

      {%{job_id: job_id, run_id: run_id}, monitors} ->
        state = %{state | run_monitors: monitors}
        {:noreply, mark_run_crashed(run_id, job_id, reason, state)}
    end
  end

  defp run_due_jobs(%{enabled?: false} = state, _now), do: state

  defp run_due_jobs(state, now) do
    case Repo.due_scheduled_jobs(now, server: state.repo, limit: state.due_limit) do
      {:ok, jobs} ->
        Enum.reduce(jobs, state, &claim_and_start(&1, now, &2))

      {:error, reason} ->
        Logger.error("Scheduled job due scan failed: #{inspect(reason)}")
        state
    end
  end

  defp claim_and_start(job, now, state) do
    if expired?(job, now) do
      expire_job(job.id, now, state)
    else
      claim_and_start_due_job(job, now, state)
    end
  end

  defp claim_and_start_due_job(job, now, state) do
    with {:ok, job_patch} <- claim_job_patch(job, now),
         run_attrs <- run_attrs(job, now) do
      case Repo.claim_due_job(job.id, job_patch, run_attrs, now, server: state.repo) do
        {:ok, {claimed_job, run}} ->
          start_or_mark_failed(claimed_job, run, state)

        {:error, :already_running} ->
          state

        {:error, :not_due} ->
          state

        {:error, reason} ->
          Logger.error("Scheduled job #{job.id} claim failed: #{inspect(reason)}")
          state
      end
    else
      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} claim patch failed: #{inspect(reason)}")
        state
    end
  end

  defp expired?(%{expires_at: nil}, _now), do: false

  defp expired?(%{expires_at: %DateTime{} = expires_at}, now) do
    DateTime.compare(now, expires_at) != :lt
  end

  defp expire_job(job_id, now, state) do
    case Repo.get_scheduled_job(job_id, server: state.repo) do
      {:ok, %{enabled?: true, state: "scheduled"} = job} ->
        expire_scheduled_job(job, now, state.repo)

      {:ok, _job} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job #{job_id} expiry lookup failed: #{inspect(reason)}")
    end

    state
  end

  defp expire_scheduled_job(job, now, repo) do
    if expired?(job, now) do
      job
      |> Map.merge(%{
        enabled?: false,
        state: "completed",
        next_run_at: nil,
        last_status: "expired",
        last_error: nil,
        updated_at: now
      })
      |> Repo.upsert_scheduled_job(server: repo)
      |> case do
        {:ok, updated_job} ->
          mark_source_expired(updated_job, now, repo)

        {:error, reason} ->
          Logger.error("Scheduled job #{job.id} expiry update failed: #{inspect(reason)}")
      end
    end
  end

  defp start_or_mark_failed(job, run, state) do
    case start_runner(job, run, state) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        put_in(state.run_monitors[ref], %{job_id: job.id, run_id: run.id})

      {:error, reason} ->
        Logger.error("Scheduled job #{job.id} runner start failed: #{inspect(reason)}")
        mark_run_crashed(run.id, job.id, reason, state)
    end
  end

  defp claim_job_patch(%{schedule_kind: "once"} = _job, now) do
    {:ok, %{state: "running", next_run_at: nil, updated_at: now}}
  end

  defp claim_job_patch(job, now) do
    with {:ok, parsed} <- Schedule.parse(job.schedule_expr, timezone: job.timezone, now: now) do
      {:ok, %{state: "running", next_run_at: parsed.next_run_at, updated_at: now}}
    end
  end

  defp run_attrs(job, now) do
    %{
      id: "run_#{random_id()}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{timestamp_id(now)}",
      trigger: "schedule",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }
  end

  defp start_runner(job, run, state) do
    case RunnerSupervisor.start_run(state.runner_supervisor,
           runner_module: state.runner_module,
           repo: state.repo,
           capability_registry: state.capability_registry,
           skill_registry: state.skill_registry,
           job: job,
           run: run,
           adapter: state.adapter,
           adapter_opts: state.adapter_opts,
           delivery_adapter: state.delivery_adapter,
           delivery_opts: state.delivery_opts,
           delivery_channels: state.delivery_channels,
           delivery_timeout_ms: state.delivery_timeout_ms,
           output_base_dir: state.output_base_dir,
           timeout_ms: state.timeout_ms,
           inactivity_timeout_ms: state.inactivity_timeout_ms,
           notify: state.runner_notify,
           delay_ms: state.runner_delay_ms
         ) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, pid, _info} when is_pid(pid) -> {:ok, pid}
      :ignore -> {:error, :runner_ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_run_crashed(run_id, job_id, reason, state) do
    now = DateTime.utc_now()
    error = "runner crashed: #{inspect(reason)}"

    case mark_run_error(run_id, error, now, state.repo) do
      {:active_run_marked, _run} ->
        mark_job_error(job_id, error, now, state.repo)

      {:pending_delivery_marked, run} ->
        mark_job_completed_after_delivery_crash(job_id, run, now, state.repo)

      :ok ->
        :ok
    end

    state
  end

  defp mark_run_error(run_id, error, now, repo) do
    case Repo.get_job_run(run_id, server: repo) do
      {:ok, %{status: status} = run} when status in ["queued", "running"] ->
        mark_active_run_crashed(run, run_id, error, now, repo)

      {:ok, %{status: "ok", delivery_status: "pending"} = run} ->
        mark_pending_delivery_failed(run, run_id, error, now, repo)

      {:ok, _finished_run} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job run #{run_id} crash update failed: #{inspect(reason)}")
    end
  end

  defp mark_active_run_crashed(run, run_id, error, now, repo) do
    run
    |> Map.merge(%{
      status: "error",
      completed_at: now,
      error: error,
      updated_at: now
    })
    |> update_reaped_run(run_id, repo, :active_run_marked, "crash update")
  end

  defp mark_pending_delivery_failed(run, run_id, error, now, repo) do
    run
    |> Map.merge(%{
      delivery_status: "failed",
      delivery_error: error,
      updated_at: now
    })
    |> update_reaped_run(run_id, repo, :pending_delivery_marked, "pending delivery update")
  end

  defp update_reaped_run(run, run_id, repo, success_tag, log_context) do
    case Repo.upsert_job_run(run, server: repo) do
      {:ok, updated_run} ->
        {success_tag, updated_run}

      {:error, reason} ->
        Logger.error("Scheduled job run #{run_id} #{log_context} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_job_completed_after_delivery_crash(job_id, run, now, repo) do
    run_at = run.completed_at || now

    case Repo.get_scheduled_job(job_id, server: repo) do
      {:ok, job} ->
        job
        |> Map.merge(completed_job_state(job))
        |> Map.merge(%{
          last_run_at: run_at,
          last_status: "ok",
          last_error: nil,
          updated_at: now
        })
        |> Repo.upsert_scheduled_job(server: repo)
        |> case do
          {:ok, updated_job} ->
            mark_source_ok(updated_job, run_at, now, repo)

          {:error, reason} ->
            Logger.error(
              "Scheduled job #{job_id} delivery crash update failed: #{inspect(reason)}"
            )
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job #{job_id} delivery crash lookup failed: #{inspect(reason)}")
    end
  end

  defp completed_job_state(%{schedule_kind: "once"}) do
    %{enabled?: false, state: "completed", next_run_at: nil}
  end

  defp completed_job_state(%{state: "running"}), do: %{state: "scheduled"}
  defp completed_job_state(_job), do: %{}

  defp mark_job_error(job_id, error, now, repo) do
    case Repo.get_scheduled_job(job_id, server: repo) do
      {:ok, job} ->
        job
        |> Map.merge(failed_job_state(job))
        |> Map.merge(%{
          last_run_at: now,
          last_status: "error",
          last_error: error,
          updated_at: now
        })
        |> Repo.upsert_scheduled_job(server: repo)
        |> case do
          {:ok, updated_job} ->
            mark_source_error(updated_job, now, repo)

          {:error, reason} ->
            Logger.error("Scheduled job #{job_id} crash update failed: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduled job #{job_id} crash lookup failed: #{inspect(reason)}")
    end
  end

  defp failed_job_state(%{schedule_kind: "once"}) do
    %{enabled?: false, state: "completed", next_run_at: nil}
  end

  defp failed_job_state(%{state: "running"}), do: %{state: "scheduled"}
  defp failed_job_state(_job), do: %{}

  defp mark_source_error(job, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{last_run_at: now, last_status: "error", updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Scheduled job source #{job.memory_source_id} crash update failed: #{inspect(reason)}"
        )
    end
  end

  defp mark_source_ok(job, run_at, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{last_run_at: run_at, last_status: "ok", updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Scheduled job source #{job.memory_source_id} delivery crash update failed: #{inspect(reason)}"
        )
    end
  end

  defp mark_source_expired(job, now, repo) do
    case Repo.get_memory_source(job.memory_source_id, server: repo) do
      {:ok, source} ->
        source
        |> Map.merge(%{status: "expired", last_status: "expired", updated_at: now})
        |> Repo.upsert_memory_source(server: repo)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Scheduled job source #{job.memory_source_id} expiry update failed: #{inspect(reason)}"
        )
    end
  end

  defp schedule_due_timer(state) do
    cancel_timer(state.due_timer)

    if state.enabled? and state.timer_enabled? do
      %{state | due_timer: next_due_timer(state)}
    else
      %{state | due_timer: nil}
    end
  end

  defp next_due_timer(state) do
    case Repo.next_scheduled_job(server: state.repo) do
      {:ok, job} when is_map(job) ->
        case next_wakeup_at(job) do
          %DateTime{} = wakeup_at ->
            Process.send_after(self(), :due_tick, due_delay_ms(wakeup_at))

          nil ->
            nil
        end

      {:ok, _none} ->
        nil

      {:error, reason} ->
        Logger.error("Scheduled job timer lookup failed: #{inspect(reason)}")
        nil
    end
  end

  defp next_wakeup_at(%{next_run_at: nil, expires_at: nil}), do: nil
  defp next_wakeup_at(%{next_run_at: nil, expires_at: expires_at}), do: expires_at
  defp next_wakeup_at(%{next_run_at: next_run_at, expires_at: nil}), do: next_run_at

  defp next_wakeup_at(%{
         next_run_at: %DateTime{} = next_run_at,
         expires_at: %DateTime{} = expires_at
       }) do
    if DateTime.compare(expires_at, next_run_at) == :lt do
      expires_at
    else
      next_run_at
    end
  end

  defp schedule_reconciliation_timer(state) do
    cancel_timer(state.reconciliation_timer)

    if state.enabled? and state.timer_enabled? do
      timer = Process.send_after(self(), :reconcile_tick, state.reconciliation_interval_ms)
      %{state | reconciliation_timer: timer}
    else
      %{state | reconciliation_timer: nil}
    end
  end

  defp due_delay_ms(next_run_at) do
    delay = DateTime.diff(next_run_at, DateTime.utc_now(), :millisecond)
    max(delay, 0)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp random_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp timestamp_id(now) do
    Enum.map_join(
      [
        now.year,
        pad(now.month),
        pad(now.day),
        "_",
        pad(now.hour),
        pad(now.minute),
        pad(now.second)
      ],
      &to_string/1
    )
  end

  defp pad(value) when is_integer(value) and value < 10, do: "0#{value}"
  defp pad(value), do: value

  defp jobs_config(key, default) do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(key, default)
  end
end
