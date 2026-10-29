# Per-trial jobs, reminders and open loops for a capability task (`checker.state`).
#
#   FERMIX_HOME=<eval home> mix run --no-start --no-compile benchmark/bin/seed_state.exs <spec.json>
#
# Restores the task's baseline in the disposable eval home's memory.db before a
# trial: once no job run is in flight, removes every scheduled job, cancels
# every active reminder, closes every live open loop and deletes every recorded
# reply to a follow-up, then creates the spec's jobs (with their past runs) and
# reminders through the same registry and claim/settle calls the daemon uses, so
# validation, schedule parsing and reminder planning are the product's own. Run
# history is back-dated relative to now; reminders take absolute local dates in
# the home's configured timezone. Open loops are written through Memory.Repo
# already due (see seed_open_loop!/3), dated or waited on (`anchor_kind`), with
# their reach and the rung 1 window the lifecycle gives them; the owner's replies
# to earlier follow-ups (`open_loop_replies`) become open_loop_reactions rows, and
# what the owner wrote lately (`owner_messages`) becomes their messages in the cli
# chat every seeded loop is delivered to, which a check-in reads. The reset also
# deletes that chat's messages, so no earlier trial's words reach a later run.
# Prints one JSON manifest line last: the created ids, job snapshots, loops,
# replies, the zone and local date.
#
# It runs in its own BEAM beside the eval daemon; SQLite (WAL, busy_timeout)
# serialises the two writers. Every value a spec carries is invented.

defmodule SeedState do
  alias FermixCore.Jobs.Registry, as: Jobs
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.OpenLoopsSql
  alias FermixCore.Memory.Store, as: MemoryStore
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.Defaults, as: OpenLoopDefaults
  alias FermixCore.OpenLoops.Lifecycle
  alias FermixCore.OpenLoops.Registry, as: OpenLoopRegistry
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Temporal.Registry, as: Temporal

  @reset_wait_ms 120_000
  @reset_poll_ms 1_000
  @max_event_pages 50
  # The refusals a reset outlasts: a run in flight (or claimed between the check and the
  # delete) and a reminder mid-delivery. Anything else is not transient and raises.
  @transient [:run_in_flight, :job_running, :delivery_in_progress]
  @anchor_kinds ~w(matters_by ask_after)
  @reaches ~w(message conversation)
  @windows ~w(open closed)
  @other_close_reasons ~w(done stop dropped)
  @reaction_answers ~w(done plan not_yet stop drop moved reach)
  @max_reaction_passes 20

  def main([spec_path]) do
    home = eval_home!()
    spec = spec_path |> File.read!() |> Jason.decode!()
    config = home_config!()
    same_database!(home)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Repo.start_link([])
    {:ok, _} = MemoryStore.start_link([])
    now = DateTime.utc_now()
    loop_plans = plan_open_loops!(Map.get(spec, "open_loops", []), now, config)
    loop_keys = Enum.map(loop_plans, & &1.key)
    reply_plans = plan_replies!(Map.get(spec, "open_loop_replies", []), loop_keys, now)
    said_plans = plan_owner_messages!(Map.get(spec, "owner_messages", []), now)
    reset!(now, System.monotonic_time(:millisecond) + @reset_wait_ms)
    jobs = Map.new(Map.get(spec, "jobs", []), &seed_job!(&1, now, config))
    reminders = Enum.map(Map.get(spec, "reminders", []), &seed_reminder!(&1, now, config))
    open_loops = seed_open_loops!(loop_plans, now, config)
    replies = seed_replies!(reply_plans, open_loops, now, config)
    owner_messages = Enum.map(said_plans, &seed_owner_message!/1)
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
        open_loops: open_loops,
        open_loop_replies: replies.reactions,
        reply_loops: replies.loops,
        owner_messages: owner_messages
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
         :ok <- close_open_loops(now),
         :ok <- delete_reactions(),
         do: Repo.delete_messages(owner_chat())
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

  # Every recorded reply to a follow-up goes too: a reply seeded for one task (a
  # "stop checking in on personal things") would otherwise be the next task's
  # evidence, and each trial would see the previous trial's rows beside its own.
  # Repo deletes a loop's record at a time, so each pass lists the owner's record
  # (at most `reactions_kept`, the bound every insert holds) and deletes it by loop.
  defp delete_reactions, do: delete_reactions(MemoryConfig.owner_id(), @max_reaction_passes)

  defp delete_reactions(_owner, 0), do: {:error, :reactions_left_after_the_pass_cap}

  defp delete_reactions(owner, passes_left) do
    {:ok, rows} = Repo.list_open_loop_reactions(owner)

    case rows |> Enum.map(& &1.open_loop_id) |> Enum.uniq() do
      [] ->
        :ok

      loop_ids ->
        Enum.each(loop_ids, fn id -> {:ok, _} = Repo.delete_open_loop_reactions(owner, id) end)
        delete_reactions(owner, passes_left - 1)
    end
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

  defp seed_open_loops!(plans, now, config) do
    budget_unspent!(now, config.zone)
    Enum.map(plans, &seed_open_loop!(&1, now, config))
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
  # the loop days out, and the task needs one that is due now, which no management
  # verb can arrange. The row is created with its touch a day ahead, so no due scan
  # can act on it, then settled due in one more write, with the rung 1 window the
  # lifecycle gives it (`rung1_until!/3`). It is delivered to the home's own cli
  # chat, whose adapter needs no credentials.
  defp seed_open_loop!(plan, now, config) do
    {:ok, {:created, created}} = Repo.create_open_loop(plan.attrs)
    {:ok, loop} = Repo.settle_open_loop(created.id, plan.changes, now: now)
    seed_memory_fact!(plan.memory_fact)
    open_loop_manifest(plan.spec, loop, config.zone)
  end

  # Every loop entry is checked whole before the reset and before any write, as the
  # replies are (`plan_replies!/3`): this script's own rules, the Repo's validation of
  # the row it creates and of the settle that makes it due (the same normalisers
  # Repo.create_open_loop/2 and Repo.settle_open_loop/3 run first), the memory fact's
  # shape, and that no two entries share a key or an intention (the second create
  # would find the first loop live). So a spec refused on any entry, its second
  # included, stops before the reset and leaves the home as it was.
  defp plan_open_loops!(specs, now, config) do
    plans = Enum.map(specs, &plan_open_loop!(&1, now, config))
    distinct!(plans, & &1.key, "key")
    distinct!(plans, & &1.attrs.dedupe_key, "intention")
    plans
  end

  defp plan_open_loop!(spec, now, config) do
    zone = config.zone
    said_at = DateTime.add(now, -Map.fetch!(spec, "said_days_ago") * 86_400, :second)
    anchor = anchor!(spec, now, zone)
    class = horizon_class!(spec, anchor, said_at, zone)
    reach = reach!(spec)

    attrs =
      loop_attrs(Map.fetch!(spec, "intention"), anchor, class, reach, said_at, now, config)
      |> Map.put(:why_it_matters, Map.get(spec, "why_it_matters"))
      |> Map.merge(source_attr(spec))

    changes = due_changes(spec, attrs, now)
    repo_accepts!(spec, "row", OpenLoopsSql.normalize_create(attrs))
    repo_accepts!(spec, "settle", OpenLoopsSql.normalize_changes(changes))

    %{
      key: Map.fetch!(spec, "key"),
      spec: spec,
      attrs: attrs,
      changes: changes,
      memory_fact: memory_fact!(spec)
    }
  end

  defp repo_accepts!(_spec, _write, {:ok, _normalized}), do: :ok

  defp repo_accepts!(spec, write, {:error, reason}),
    do: raise("open loop #{spec["key"]}: Memory.Repo refuses its #{write}: #{inspect(reason)}")

  defp distinct!(plans, value_of, what) do
    shared = for {value, count} <- Enum.frequencies_by(plans, value_of), count > 1, do: value

    unless shared == [] do
      raise "open_loops: two entries share a #{what}: #{inspect(shared)}"
    end
  end

  defp memory_fact!(spec) do
    case Map.get(spec, "memory_fact") do
      nil ->
        nil

      %{"key" => key, "value" => value} = fact when is_binary(key) and is_binary(value) ->
        fact

      other ->
        raise "open loop #{spec["key"]}: memory_fact must be a key and a value, got #{inspect(other)}"
    end
  end

  # The columns every seeded row shares, a reply's other thread included.
  defp loop_attrs(intention, anchor, class, reach, said_at, now, config) do
    %{
      id: "loop_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
      agent_id: MemoryConfig.agent_id(),
      owner_id: MemoryConfig.owner_id(),
      dedupe_key: dedupe_key!(intention),
      intention: intention,
      # The fixture is the owner's own words, as a loop noted on a turn that read
      # nothing is.
      noted_after_outside_content: false,
      anchor_kind: anchor.anchor_kind,
      matters_by_kind: anchor.kind,
      matters_by_date: anchor.date,
      matters_by_time: anchor.time,
      matters_by_at: anchor.at,
      timezone: config.zone,
      horizon_class: class,
      reach: reach,
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
  end

  # Something to do by a date (`matters_in_days`, the instant that local date has
  # passed), or something waited on (`ask_after`): its anchor is the instant asking
  # first felt natural, which is the touch now due (`due_hours_ago`), as an `after`
  # loop's one slot is its anchor.
  defp anchor!(spec, now, zone) do
    case Map.get(spec, "anchor_kind", "matters_by") do
      "matters_by" ->
        dated_anchor!(spec, now, zone)

      "ask_after" ->
        after_anchor!(spec, now, zone)

      other ->
        raise "open loop #{spec["key"]}: anchor_kind #{inspect(other)} is not one of #{inspect(@anchor_kinds)}"
    end
  end

  defp dated_anchor!(spec, now, zone) do
    matters_on = Date.add(local_date(now, zone), Map.fetch!(spec, "matters_in_days"))
    at = ActiveHours.local_instant(Date.add(matters_on, 1), ~T[00:00:00], zone)
    %{anchor_kind: "matters_by", kind: "date", date: matters_on, time: nil, at: at}
  end

  defp after_anchor!(spec, now, zone) do
    for key <- ["matters_in_days", "matters_by_source"], Map.has_key?(spec, key) do
      raise "open loop #{spec["key"]}: an ask_after loop takes no #{key}"
    end

    now
    |> DateTime.add(-Map.fetch!(spec, "due_hours_ago") * 3_600, :second)
    |> instant_anchor(zone)
  end

  # An `ask_after` anchor at one instant, as the Registry stores a datetime one.
  defp instant_anchor(at, zone) do
    at = DateTime.truncate(at, :second)
    local = DateTime.shift_zone!(at, zone)
    time = local |> DateTime.to_time() |> Time.truncate(:second)

    %{
      anchor_kind: "ask_after",
      kind: "datetime",
      date: DateTime.to_date(local),
      time: time,
      at: at
    }
  end

  # A spec's class must be the one its anchor gives, so a fixture cannot claim a
  # long loop whose dates make it medium; an `ask_after` loop is always `after`.
  defp horizon_class!(spec, %{anchor_kind: "ask_after"}, _said_at, _zone),
    do: stated_class!(spec, "after")

  defp horizon_class!(spec, anchor, said_at, zone),
    do: stated_class!(spec, OpenLoopDefaults.horizon_class(said_at, anchor.at, zone))

  defp stated_class!(spec, derived) do
    stated = Map.fetch!(spec, "horizon_class")

    unless stated == derived do
      raise "open loop #{spec["key"]}: horizon_class #{stated}, but its anchor makes it #{derived}"
    end

    stated
  end

  defp reach!(spec) do
    reach = Map.get(spec, "reach", "message")

    unless reach in @reaches do
      raise "open loop #{spec["key"]}: reach #{inspect(reach)} is not one of #{inspect(@reaches)}"
    end

    reach
  end

  # A dated loop's source is the spec's, or the column's default (`owner`).
  defp source_attr(%{"matters_by_source" => source}), do: %{matters_by_source: source}
  defp source_attr(_spec), do: %{}

  # `attrs` is the row about to be created: open, unclaimed, with the spec's ledger
  # and its touch now due, it is what the lifecycle's due scan would see.
  defp due_changes(spec, attrs, now) do
    next_touch_at = DateTime.add(now, -Map.fetch!(spec, "due_hours_ago") * 3_600, :second)
    handback_phase!(spec, next_touch_at, attrs.matters_by_at)
    touches = Map.fetch!(spec, "touches")
    ledger = Map.merge(%{touches: touches}, last_touch(spec, touches, now))

    pending =
      attrs
      |> Map.merge(%{state: "open", claimed_at: nil})
      |> Map.merge(ledger)
      |> Map.put(:next_touch_at, next_touch_at)

    Map.merge(ledger, %{
      state: "due",
      next_touch_at: next_touch_at,
      rung1_until: rung1_until!(spec, pending, now)
    })
  end

  # The window the lifecycle itself writes when its due scan marks this row due,
  # asked at the moment the touch came due: three hours for a loop raised by
  # message, the date for an imminent one, the next window for one kept for
  # conversation. The spec says whether that window is still open at seed time
  # (`rung1_window`), and a spec whose times say otherwise is refused.
  defp rung1_until!(spec, pending, now) do
    until =
      case Lifecycle.due_decision(pending, pending.next_touch_at) do
        {:due, until} ->
          until

        other ->
          raise "open loop #{spec["key"]}: the lifecycle does not mark it due at its touch (#{inspect(other)})"
      end

    window!(spec, pending.reach, DateTime.compare(until, now) == :gt, until)
    until
  end

  defp window!(spec, reach, open?, until) do
    declared = Map.get(spec, "rung1_window", "closed")
    actual = if open?, do: "open", else: "closed"

    cond do
      declared not in @windows ->
        raise "open loop #{spec["key"]}: rung1_window #{inspect(declared)} is not open or closed"

      declared == "closed" and reach == "conversation" ->
        raise "open loop #{spec["key"]}: a loop kept for conversation whose window has closed " <>
                "takes the quiet path at the next scan; seed it with rung1_window open"

      declared != actual ->
        raise "open loop #{spec["key"]}: due_hours_ago leaves its rung 1 window #{actual} " <>
                "(until #{DateTime.to_iso8601(until)}), but rung1_window says #{declared}"

      true ->
        :ok
    end
  end

  # A loop whose date has passed is at its hand-back only while its pending touch
  # is after the date too; seeded before local midnight plus `due_hours_ago` it
  # would read as a passed before-the-date slot, and the due scan would move it.
  defp handback_phase!(spec, next_touch_at, matters_by_at) do
    passed = Map.get(spec, "matters_in_days", 0) < 0

    if passed and DateTime.compare(next_touch_at, matters_by_at) == :lt do
      raise "open loop #{spec["key"]}: seed a hand-back at least due_hours_ago after local midnight"
    end
  end

  # A previous message makes the last touch a rung 2 send; a touch without one was
  # a rung 1 raise in conversation. A seeded message is Fermix's own, written
  # after reading nothing someone else wrote.
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
      last_message: message,
      last_message_after_outside_content: false
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
      anchor_kind: loop.anchor_kind,
      reach: loop.reach,
      said_on: loop.said_at |> local_date(zone) |> Date.to_iso8601(),
      matters_on: Date.to_iso8601(loop.matters_by_date),
      rung1_until: DateTime.to_iso8601(loop.rung1_until),
      touches: loop.touches,
      last_message: loop.last_message
    }
  end

  # --- the owner's replies to earlier follow-ups (M83 §07) -------------------------

  # One open_loop_reactions row per entry: what Fermix raised, when, and what the
  # owner said next, or that they said nothing. An entry names a seeded loop
  # (`loop`), or another thread (`other_intention`), seeded as a closed loop of its
  # own so the reply has the words it was about. Every row is written through the
  # Repo calls the product records follow-ups with (record, capture or stamp, answer).
  #
  # Each entry is checked whole before anything is seeded (`plan_replies!/3`), so a
  # refused entry leaves no row behind, neither its own nor the spec's loops.
  defp plan_replies!(specs, loop_keys, now), do: Enum.map(specs, &plan_reply!(&1, loop_keys, now))

  defp plan_reply!(spec, loop_keys, now) do
    raised_at = DateTime.add(now, -Map.fetch!(spec, "raised_hours_ago") * 3_600, :second)

    %{
      target: reply_target!(spec, loop_keys),
      raised_at: raised_at,
      reply: reply!(spec, raised_at, now),
      fields: reaction_fields!(spec)
    }
  end

  defp reply_target!(%{"loop" => key} = spec, loop_keys) do
    cond do
      Map.has_key?(spec, "other_intention") ->
        raise "open_loop_replies: name a loop or an other_intention, not both"

      key not in loop_keys ->
        raise "open_loop_replies: loop #{inspect(key)} names no seeded open loop"

      true ->
        {:loop, key}
    end
  end

  defp reply_target!(spec, _loop_keys) do
    reason = Map.get(spec, "other_close_reason", "dropped")

    unless reason in @other_close_reasons do
      raise "open_loop_replies: other_close_reason #{inspect(reason)} is not one of " <>
              inspect(@other_close_reasons)
    end

    {:other, Map.fetch!(spec, "other_intention"), reason}
  end

  defp reply!(spec, raised_at, now) do
    case Map.get(spec, "reply_text") do
      nil ->
        if Map.has_key?(spec, "reply_after_minutes"),
          do: raise("open_loop_replies: reply_after_minutes without a reply_text")

        # The product marks a follow-up unanswered only once its reply window has passed.
        if DateTime.diff(now, raised_at, :millisecond) < OpenLoopDefaults.reply_window_ms(),
          do: raise("open_loop_replies: an unanswered follow-up must be raised a day or more ago")

        %{text: nil, at: nil, outcome: "no_reply"}

      text ->
        at = DateTime.add(raised_at, Map.fetch!(spec, "reply_after_minutes") * 60, :second)
        if DateTime.compare(at, now) == :gt, do: raise("open_loop_replies: a reply after now")
        window_ms = OpenLoopDefaults.reply_window_ms()

        if DateTime.diff(at, raised_at, :millisecond) > window_ms,
          do: raise("open_loop_replies: a reply after the one-day reply window is no reply")

        text = bounded!(text, "reply_text", OpenLoopDefaults.reply_text_max())
        %{text: text, at: at, outcome: "replied"}
    end
  end

  defp seed_replies!([], _loops, _now, _config), do: %{reactions: [], loops: []}

  # In raised order, each follow-up is recorded and resolved (its reply captured, or
  # stamped as unanswered) before the next is recorded, so Repo's capture and stamp,
  # which act on every follow-up still awaiting a reply, only ever find this one.
  defp seed_replies!(plans, loops, now, config) do
    ids = Map.new(loops, &{&1.key, &1.id})

    {reactions, others} =
      plans
      |> Enum.sort_by(& &1.raised_at, DateTime)
      |> Enum.map(&seed_reply!(&1, ids, now, config))
      |> Enum.unzip()

    %{reactions: reactions, loops: Enum.reject(others, &is_nil/1)}
  end

  defp seed_reply!(plan, ids, now, config) do
    {loop_id, other} = reply_loop!(plan.target, plan, ids, now, config)
    owner = MemoryConfig.owner_id()
    {:ok, raised} = Repo.record_open_loop_reaction(raise_attrs(plan, loop_id))
    resolve_reply!(plan, owner, now)

    if plan.fields.answer do
      {:ok, 1} = Repo.answer_open_loop_reaction(owner, loop_id, plan.fields.answer, now: now)
    end

    {%{id: raised.id, open_loop_id: loop_id, outcome: plan.reply.outcome}, other}
  end

  defp raise_attrs(plan, loop_id) do
    Map.merge(cli_conversation(), %{
      id: "reaction_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
      open_loop_id: loop_id,
      rung: plan.fields.rung,
      raised_at: plan.raised_at,
      session_id: "eval-seed",
      raised_with: plan.fields.raised_with,
      raised_after_outside_content: false
    })
  end

  defp resolve_reply!(%{reply: %{outcome: "replied"}} = plan, _owner, _now) do
    attrs =
      Map.merge(cli_conversation(), %{
        reply_text: plan.reply.text,
        reply_at: plan.reply.at,
        since: plan.raised_at
      })

    {:ok, [_answered]} = Repo.capture_open_loop_replies(attrs)
    :ok
  end

  defp resolve_reply!(plan, owner, now) do
    cutoff = DateTime.add(plan.raised_at, 1, :second)
    {:ok, [_stamped]} = Repo.stamp_open_loop_no_replies(owner, cutoff, now: now)
    :ok
  end

  defp cli_conversation do
    %{
      owner_id: MemoryConfig.owner_id(),
      agent_id: MemoryConfig.agent_id(),
      source_channel: "cli",
      source_chat_id: "cli",
      source_thread_scope: "root"
    }
  end

  defp reply_loop!({:loop, key}, _plan, ids, _now, _config), do: {Map.fetch!(ids, key), nil}

  defp reply_loop!({:other, intention, reason}, plan, _ids, now, config) do
    raised_at = plan.raised_at
    said_at = DateTime.add(raised_at, -3 * 86_400, :second)
    anchor = instant_anchor(raised_at, config.zone)
    attrs = loop_attrs(intention, anchor, "after", "message", said_at, now, config)
    {:ok, {:created, created}} = Repo.create_open_loop(attrs)
    closing = other_closing(plan.fields, reason, raised_at, plan.reply.at || raised_at)
    {:ok, closed} = Repo.settle_open_loop(created.id, closing, now: now)
    {closed.id, %{id: closed.id, intention: closed.intention, close_reason: closed.close_reason}}
  end

  defp other_closing(fields, reason, raised_at, closed_at) do
    answer = fields.answer

    %{
      state: "closed",
      close_reason: reason,
      closed_at: closed_at,
      next_touch_at: nil,
      touches: 1,
      last_touch_at: raised_at,
      last_touch_rung: fields.rung
    }
    |> Map.merge(if answer in ~w(done stop drop), do: %{last_answer: answer}, else: %{})
  end

  defp reaction_fields!(spec) do
    %{
      rung: rung!(spec),
      answer: answer!(spec),
      raised_with:
        bounded!(
          Map.fetch!(spec, "raised_with"),
          "raised_with",
          OpenLoopDefaults.raised_with_max()
        )
    }
  end

  defp rung!(%{"rung" => rung}) when rung in [1, 2], do: rung

  defp rung!(spec),
    do: raise("open_loop_replies: rung must be 1 or 2, got #{inspect(spec["rung"])}")

  defp answer!(spec) do
    answer = Map.get(spec, "answer")

    unless is_nil(answer) or answer in @reaction_answers,
      do:
        raise(
          "open_loop_replies: answer #{inspect(answer)} is not one of #{inspect(@reaction_answers)}"
        )

    answer
  end

  defp bounded!(text, key, max) when is_binary(text) do
    if String.length(text) > max, do: raise("open_loop_replies: #{key} is over #{max} characters")
    text
  end

  # --- what the owner wrote lately (M83 §10) ---------------------------------------

  # The cli chat every seeded loop is delivered to (`loop_attrs/7`), where a check-in
  # reads the owner's recent messages.
  defp owner_chat do
    %{
      agent_id: MemoryConfig.agent_id(),
      owner_id: MemoryConfig.owner_id(),
      channel: "cli",
      chat_id: "cli",
      thread_scope: "root"
    }
  end

  # Each entry is the owner's own words `hours_ago` before now, checked whole before
  # anything is seeded, as replies are.
  defp plan_owner_messages!(specs, now), do: Enum.map(specs, &plan_owner_message!(&1, now))

  defp plan_owner_message!(%{"hours_ago" => hours, "text" => text}, now)
       when is_number(hours) and hours > 0 and is_binary(text) and text != "" do
    %{text: text, at: DateTime.add(now, -round(hours * 3_600), :second)}
  end

  defp plan_owner_message!(spec, _now) do
    raise "owner_messages: each entry needs a positive hours_ago and a text, got #{inspect(spec)}"
  end

  defp seed_owner_message!(plan) do
    {:ok, row} =
      owner_chat()
      |> Map.merge(%{
        sender: "owner",
        role: "user",
        kind: "chat_message",
        content: plan.text,
        created_at: plan.at
      })
      |> Repo.insert_message()

    %{id: row.id, at: DateTime.to_iso8601(plan.at)}
  end

  defp local_date(%DateTime{} = at, zone),
    do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
end

SeedState.main(System.argv())
