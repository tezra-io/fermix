# Per-trial jobs and reminders for a capability task (`checker.state`).
#
#   FERMIX_HOME=<eval home> mix run --no-start --no-compile benchmark/bin/seed_state.exs <spec.json>
#
# Restores the task's baseline in the disposable eval home's memory.db before a
# trial: once no job run is in flight, removes every scheduled job and cancels
# every active reminder, then creates the spec's jobs (with their past
# runs) and reminders through the same registry and claim/settle calls the
# daemon uses, so validation, schedule parsing and reminder planning are the
# product's own. Run history is back-dated relative to now; reminders take
# absolute local dates in the home's configured timezone. Prints one JSON
# manifest line last: the created ids, job snapshots, the zone and local date.
#
# It runs in its own BEAM beside the eval daemon; SQLite (WAL, busy_timeout)
# serialises the two writers. Every value a spec carries is invented.

defmodule SeedState do
  alias FermixCore.Jobs.Registry, as: Jobs
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Temporal.Registry, as: Temporal

  @reset_wait_ms 120_000
  @reset_poll_ms 1_000
  @max_event_pages 50
  # The refusals a reset outlasts: a run in flight (or claimed between the check and the
  # delete) and a reminder mid-delivery. Anything else is not transient and raises.
  @transient [:run_in_flight, :job_running, :delivery_in_progress]

  def main([spec_path]) do
    home = eval_home!()
    spec = spec_path |> File.read!() |> Jason.decode!()
    config = home_config!()
    same_database!(home)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Repo.start_link([])
    now = DateTime.utc_now()
    reset!(now, System.monotonic_time(:millisecond) + @reset_wait_ms)
    jobs = Map.new(Map.get(spec, "jobs", []), &seed_job!(&1, now, config))
    reminders = Enum.map(Map.get(spec, "reminders", []), &seed_reminder!(&1, now, config))
    # `today` is the home's local date at seed time: what a checker grading "tomorrow"
    # counts from, so it needs no timezone database of its own.
    today = now |> DateTime.shift_zone!(config.zone) |> DateTime.to_date() |> Date.to_iso8601()

    IO.puts(
      Jason.encode!(%{
        now: DateTime.to_iso8601(now),
        zone: config.zone,
        today: today,
        jobs: jobs,
        reminders: reminders
      })
    )
  end

  def main(_args) do
    raise ArgumentError, "usage: seed_state.exs <spec.json> (FERMIX_HOME set to an eval home)"
  end

  # --- guards and config -------------------------------------------------------

  defp eval_home! do
    home = System.fetch_env!("FERMIX_HOME") |> Path.expand()
    leaf = home |> Path.basename() |> String.downcase()

    unless String.contains?(leaf, "eval") or String.contains?(leaf, "e2e") do
      raise "refusing to seed state outside a disposable eval home: #{home}"
    end

    home
  end

  # The store the checkers read is <home>/memory.db; an inherited override
  # (FERMIX_MEMORY_DB_PATH, MIX_ENV=test) would seed some other database and the
  # trial would run on leftovers while the manifest looked fine.
  defp same_database!(home) do
    opened = Path.expand(MemoryConfig.database_path())
    wanted = Path.expand(Path.join(home, "memory.db"))

    unless opened == wanted do
      raise "the helper would open #{opened}, not the eval home's #{wanted}"
    end
  end

  # The home's own config.toml through the engine's loader, so the timezone and the
  # delivery target are read exactly as the daemon read them at boot.
  defp home_config! do
    {:ok, snapshot} = ConfigStore.load_runtime_config()
    core = Map.fetch!(snapshot, :fermix_core)
    personalization = Keyword.fetch!(core, :personalization)
    zone = Keyword.get(personalization, :timezone) || raise "config.toml sets no timezone"
    # Merged over the compiled app env the way boot hydration merges it, so the
    # adapter map (`delivery_channels`) the reminder target resolves against is there.
    jobs =
      Keyword.merge(Application.get_env(:fermix_core, :jobs, []), Keyword.fetch!(core, :jobs))

    %{zone: zone, personalization: personalization, jobs: jobs}
  end

  # --- reset -------------------------------------------------------------------

  # Delete every job and cancel every reminder, once nothing is running. Removal goes
  # through Jobs.Registry so each job's memory source is marked removed, exactly as
  # the remove_job tool leaves it.
  defp reset!(now, deadline) do
    case clear(now) do
      :ok ->
        :ok

      {:error, reason} when reason in @transient ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "could not reset jobs and reminders within #{@reset_wait_ms} ms: #{reason}"
        end

        Process.sleep(@reset_poll_ms)
        reset!(now, deadline)

      {:error, reason} ->
        raise "could not reset jobs and reminders: #{inspect(reason)}"
    end
  end

  defp clear(now) do
    {:ok, unsettled} = Repo.unsettled_job_runs(limit: 1)
    {:ok, jobs} = Repo.list_scheduled_jobs(%{})

    cond do
      unsettled != [] -> {:error, :run_in_flight}
      true -> with :ok <- remove_jobs(jobs), do: cancel_active_events(now, @max_event_pages)
    end
  end

  defp remove_jobs(jobs) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      case Jobs.remove_job(job.id, scheduler: nil) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Listing is paged; each pass cancels what it saw, so the next pass lists the rest.
  defp cancel_active_events(_now, 0), do: {:error, :more_active_reminders_than_the_cap}

  defp cancel_active_events(now, pages_left) do
    {:ok, %{events: events}} = Repo.list_temporal_events(%{status: "active", limit: 100})

    case cancel_events(events, now) do
      :ok when events == [] -> :ok
      :ok -> cancel_active_events(now, pages_left - 1)
      error -> error
    end
  end

  defp cancel_events(events, now) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Repo.cancel_temporal_event(event.id, now) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- jobs --------------------------------------------------------------------

  defp seed_job!(spec, now, config) do
    attrs = %{
      name: Map.fetch!(spec, "name"),
      schedule: Map.fetch!(spec, "schedule"),
      task_prompt: Map.fetch!(spec, "task_prompt"),
      skill_name: Map.get(spec, "skill_name"),
      description: Map.get(spec, "description"),
      timezone: Map.get(spec, "timezone", config.zone),
      allowed_tools: [],
      capability_policy: [],
      timeout_seconds: Map.get(spec, "timeout_seconds"),
      expires_at: expires_at(spec, now),
      delivery_mode: "channel",
      delivery_target: Map.new(Keyword.fetch!(config.jobs, :default_delivery_target)),
      created_by_agent_id: "main",
      created_by_session_id: "eval-seed",
      created_by_channel: "cli",
      created_by_trust: "operator"
    }

    {:ok, job} = Jobs.create_job(attrs, now: now, scheduler: nil)
    Enum.each(Map.get(spec, "runs", []), &seed_run!(job, &1, now))
    {Map.fetch!(spec, "key"), job_snapshot(job)}
  end

  # What a checker compares the end state with ("unchanged" fields, the same id).
  defp job_snapshot(job) do
    job
    |> Map.take([
      :id,
      :name,
      :description,
      :schedule_expr,
      :timezone,
      :task_prompt,
      :skill_name,
      :timeout_seconds,
      :expires_at
    ])
    |> Map.update!(:expires_at, &(&1 && DateTime.to_iso8601(&1)))
  end

  defp expires_at(spec, now) do
    case Map.get(spec, "expires_in_days") do
      nil -> nil
      days -> DateTime.add(now, days * 86_400, :second) |> DateTime.truncate(:second)
    end
  end

  # The scheduler's own claim, then the runner's own settle, back-dated: the job's
  # last_run_at / last_status / last_error come from the settle exactly as they do
  # after a real run.
  defp seed_run!(job, spec, now) do
    started = DateTime.add(now, -Map.fetch!(spec, "hours_ago") * 3600, :second)
    completed = DateTime.add(started, Map.fetch!(spec, "duration_seconds"), :second)
    id = "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    run = %{
      id: id,
      job_id: job.id,
      session_id: "cron_#{job.id}_#{DateTime.to_unix(started)}",
      trigger: "schedule",
      status: "running",
      claimed_at: started,
      started_at: started,
      prompt_snapshot: job.task_prompt,
      delivery_status: "delivered",
      created_at: started,
      updated_at: started
    }

    {:ok, _} = Repo.claim_job_now(job.id, %{state: "running", updated_at: started}, run)

    {:ok, _} =
      Repo.settle_job_run(
        Map.merge(run, %{
          status: Map.fetch!(spec, "status"),
          completed_at: completed,
          error: Map.get(spec, "error"),
          final_response: Map.get(spec, "final_response"),
          updated_at: completed
        })
      )
  end

  # --- reminders ---------------------------------------------------------------

  defp seed_reminder!(spec, now, config) do
    {date, time} = reminder_instant(spec)

    params = %{
      title: Map.fetch!(spec, "title"),
      kind: Map.get(spec, "kind", "explicit_reminder"),
      when: %{"type" => "datetime", "date" => Date.to_iso8601(date), "time" => time},
      reminders: Map.get(spec, "plan", [%{"type" => "at_time"}])
    }

    context = %{computer_use_origin: :interactive, temporal_scheduler: nil}
    opts = [now: now, personalization: config.personalization, jobs_config: config.jobs]
    {:ok, %{event: event}} = Temporal.create_event(params, context, opts)
    %{id: event.id, title: event.title, local_date: Date.to_iso8601(date), local_time: time}
  end

  # Absolute dates only: a weekday or "tomorrow" computed from the run date makes the
  # task mean something different on a Friday than on a Monday.
  defp reminder_instant(spec) do
    {Date.from_iso8601!(Map.fetch!(spec, "date")), Map.fetch!(spec, "time")}
  end
end

SeedState.main(System.argv())
