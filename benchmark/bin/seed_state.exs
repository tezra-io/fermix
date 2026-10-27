# Per-trial jobs, reminders and open loops for a capability task (`checker.state`).
#
#   FERMIX_HOME=<eval home> mix run --no-start --no-compile benchmark/bin/seed_state.exs <spec.json>
#
# Restores the task's baseline in the disposable eval home's memory.db before a
# trial: once no job run is in flight, removes every scheduled job, cancels
# every active reminder and closes every live open loop, then creates the
# spec's jobs (with their past runs) and reminders through the same registry
# and claim/settle calls the daemon uses, so validation, schedule parsing and
# reminder planning are the product's own. Run history is back-dated relative
# to now; reminders take absolute local dates in the home's configured
# timezone. Open loops are written through Memory.Repo already due (see
# seed_open_loop!/3), with dates relative to now. Prints one JSON manifest line
# last: the created ids, job snapshots, loops, the zone and local date.
#
# It runs in its own BEAM beside the eval daemon; SQLite (WAL, busy_timeout)
# serialises the two writers. Every value a spec carries is invented.

defmodule SeedState do
  alias FermixCore.Jobs.Registry, as: Jobs
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Store, as: MemoryStore
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.Defaults, as: OpenLoopDefaults
  alias FermixCore.OpenLoops.Registry, as: OpenLoopRegistry
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
    {:ok, _} = MemoryStore.start_link([])
    now = DateTime.utc_now()
    reset!(now, System.monotonic_time(:millisecond) + @reset_wait_ms)
    jobs = Map.new(Map.get(spec, "jobs", []), &seed_job!(&1, now, config))
    reminders = Enum.map(Map.get(spec, "reminders", []), &seed_reminder!(&1, now, config))
    open_loops = seed_open_loops!(Map.get(spec, "open_loops", []), now, config)
    # `today` is the home's local date at seed time: what a checker grading "tomorrow"
    # counts from, so it needs no timezone database of its own.
    today = now |> DateTime.shift_zone!(config.zone) |> DateTime.to_date() |> Date.to_iso8601()

    IO.puts(
      Jason.encode!(%{
        now: DateTime.to_iso8601(now),
        zone: config.zone,
        today: today,
        jobs: jobs,
        reminders: reminders,
        open_loops: open_loops
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

  # Delete every job, cancel every reminder and close every live open loop, once
  # nothing is running. Removal goes through Jobs.Registry so each job's memory
  # source is marked removed, exactly as the remove_job tool leaves it.
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
      true -> remove_all(jobs, now)
    end
  end

  defp remove_all(jobs, now) do
    with :ok <- remove_jobs(jobs),
         :ok <- cancel_active_events(now, @max_event_pages),
         do: close_open_loops(now)
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

  # --- open loops ----------------------------------------------------------------

  # Each live loop closes as dropped, and its spent rung 2 budget (`last_rung2_at`)
  # is cleared in the same settle. Closing alone would not reset the day: one rung 2
  # check-in a day is counted across every loop of the owner, closed ones included
  # (`Repo.open_loop_budget_spent_since/3`), so the first trial's check-in would turn
  # every later trial that day into a budget skip. A loop the daemon ended between
  # the listing and the settle is already where the reset wants it (`:not_live`).
  defp close_open_loops(now) do
    {:ok, live} = Repo.list_open_loops(%{owner_id: MemoryConfig.owner_id(), state: "live"})

    Enum.reduce_while(live, :ok, fn loop, :ok ->
      case Repo.settle_open_loop(loop.id, reset_changes(now), now: now) do
        {:ok, _closed} -> {:cont, :ok}
        {:error, :not_live} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reset_changes(now) do
    %{
      state: "closed",
      close_reason: "dropped",
      closed_at: now,
      next_touch_at: nil,
      last_rung2_at: nil
    }
  end

  defp seed_open_loops!([], _now, _config), do: []

  defp seed_open_loops!(specs, now, config) do
    budget_unspent!(now, config.zone)
    Enum.map(specs, &seed_open_loop!(&1, now, config))
  end

  # The reset must leave the day's rung 2 budget unspent, or every trial would be a
  # skip rather than a measurement: say so here instead of after a column of them.
  defp budget_unspent!(now, zone) do
    day_start = ActiveHours.day_start(now, zone)

    case Repo.open_loop_budget_spent_since(MemoryConfig.owner_id(), day_start) do
      {:ok, false} -> :ok
      {:ok, true} -> raise "a closed open loop already spent today's rung 2 budget"
    end
  end

  # Written through Memory.Repo, not OpenLoops.Registry: the Registry would schedule
  # the loop days out, and the task needs one that is due now with its rung 1 window
  # closed, which no management verb can arrange. The row is created with its touch
  # a day ahead, so no due scan can act on it, then settled due in one more write.
  # It is delivered to the home's own cli chat, whose adapter needs no credentials.
  defp seed_open_loop!(spec, now, config) do
    zone = config.zone
    said_at = DateTime.add(now, -Map.fetch!(spec, "said_days_ago") * 86_400, :second)
    matters_on = Date.add(local_date(now, zone), Map.fetch!(spec, "matters_in_days"))
    matters_by_at = ActiveHours.local_instant(Date.add(matters_on, 1), ~T[00:00:00], zone)
    class = horizon_class!(spec, said_at, matters_by_at, zone)
    intention = Map.fetch!(spec, "intention")

    attrs = %{
      id: "loop_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
      agent_id: MemoryConfig.agent_id(),
      owner_id: MemoryConfig.owner_id(),
      dedupe_key: dedupe_key!(intention),
      intention: intention,
      # The fixture is the owner's own words, as a loop noted on a turn that read
      # nothing is.
      noted_after_outside_content: false,
      why_it_matters: Map.get(spec, "why_it_matters"),
      matters_by_kind: "date",
      matters_by_date: matters_on,
      matters_by_time: nil,
      matters_by_at: matters_by_at,
      timezone: zone,
      horizon_class: class,
      said_at: said_at,
      source_channel: "cli",
      source_chat_id: "cli",
      source_thread_scope: "root",
      next_touch_at: DateTime.add(now, 86_400, :second),
      delivery_platform: "cli",
      delivery_destination: "cli",
      delivery_thread_scope: "root",
      created_at: said_at
    }

    changes = due_changes(spec, now, matters_by_at)
    {:ok, {:created, created}} = Repo.create_open_loop(attrs)
    {:ok, loop} = Repo.settle_open_loop(created.id, changes, now: now)
    seed_memory_fact!(Map.get(spec, "memory_fact"))
    open_loop_manifest(spec, loop, zone)
  end

  # A spec's class must be the one the dates give, so a fixture cannot claim a
  # long loop whose dates make it medium.
  defp horizon_class!(spec, said_at, matters_by_at, zone) do
    stated = Map.fetch!(spec, "horizon_class")
    derived = OpenLoopDefaults.horizon_class(said_at, matters_by_at, zone)

    unless stated == derived do
      raise "open loop #{spec["key"]}: horizon_class #{stated}, but its dates make it #{derived}"
    end

    stated
  end

  defp due_changes(spec, now, matters_by_at) do
    due_ms = Map.fetch!(spec, "due_hours_ago") * 3_600_000

    unless due_ms > OpenLoopDefaults.rung1_window_ms() do
      raise "open loop #{spec["key"]}: due_hours_ago must exceed the rung 1 window"
    end

    next_touch_at = DateTime.add(now, -div(due_ms, 1000))
    handback_phase!(spec, next_touch_at, matters_by_at)
    touches = Map.fetch!(spec, "touches")

    %{state: "due", touches: touches, next_touch_at: next_touch_at}
    |> Map.merge(last_touch(spec, touches, now))
  end

  # A loop whose date has passed is at its hand-back only while its pending touch
  # is after the date too; seeded before local midnight plus `due_hours_ago` it
  # would read as a passed before-the-date slot, and the due scan would move it.
  defp handback_phase!(spec, next_touch_at, matters_by_at) do
    passed = Map.fetch!(spec, "matters_in_days") < 0

    if passed and DateTime.compare(next_touch_at, matters_by_at) == :lt do
      raise "open loop #{spec["key"]}: seed a hand-back at least due_hours_ago after local midnight"
    end
  end

  # A previous message makes the last touch a rung 2 send; a touch without one was
  # a rung 1 raise in conversation.
  defp last_touch(spec, 0, _now) do
    if Map.has_key?(spec, "last_message") or Map.has_key?(spec, "last_touch_days_ago") do
      raise "open loop #{spec["key"]}: a previous touch needs touches above 0"
    end

    %{}
  end

  defp last_touch(spec, _touches, now) do
    message = Map.get(spec, "last_message")
    days_ago = Map.fetch!(spec, "last_touch_days_ago")

    %{
      last_touch_at: DateTime.add(now, -days_ago * 86_400, :second),
      last_touch_rung: if(message, do: 2, else: 1),
      last_message: message
    }
  end

  defp seed_memory_fact!(nil), do: :ok

  defp seed_memory_fact!(%{"key" => key, "value" => value}) do
    {:ok, :durable} = MemoryStore.store({:owner, MemoryConfig.owner_id()}, key, value)
    :ok
  end

  # The very key a captured loop gets, so a seeded loop is recognised the same way.
  defp dedupe_key!(intention) do
    {:ok, key} = OpenLoopRegistry.dedupe_key(intention)
    key
  end

  defp open_loop_manifest(spec, loop, zone) do
    %{
      key: Map.fetch!(spec, "key"),
      id: loop.id,
      intention: loop.intention,
      said_on: loop.said_at |> local_date(zone) |> Date.to_iso8601(),
      matters_on: Date.to_iso8601(loop.matters_by_date),
      touches: loop.touches,
      last_message: loop.last_message
    }
  end

  defp local_date(%DateTime{} = at, zone),
    do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
end

SeedState.main(System.argv())
