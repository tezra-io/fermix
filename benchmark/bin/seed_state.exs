# Per-trial jobs, reminders and open loops for a capability task (`checker.state`).
#
#   FERMIX_HOME=<eval home> mix run --no-start --no-compile benchmark/bin/seed_state.exs <spec.json>
#
# Restores the task's baseline in the disposable eval home's memory.db before a
# trial: once no job run and no heal run (M106 §5.4) is in flight, deletes every
# heal and every run's retry and facts (job_heals, job_heal_runs, job_retries,
# job_run_facts: a heal of a provider outlives its jobs, and a closed one keeps
# the same failure quiet for 7 days), removes every scheduled job, cancels
# every active reminder, closes every live open loop and deletes every recorded
# reply to a follow-up, then creates the spec's jobs (with their past runs) and
# reminders through the same registry and claim/settle calls the daemon uses, so
# validation, schedule parsing and reminder planning are the product's own. Run
# history is back-dated: a scheduled run at one of its job's own past fire times
# (`fires_ago`), an off-schedule manual run `hours_ago` before now
# (bin/seed_run_times.exs, the rule); reminders take absolute local dates in
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
# Seeded history is the product's history: a seeded failed run settles through the
# call a live failure's does, so a failure of the owner's job opens a heal (or joins
# the one it opened before), which the daemon claims on its next pass and sends.
# Its run's own delivery reads `skipped`, as a healed failure's does; an ok run
# after it closes the heal as healed. A run may name its `failure_kind` (a
# `Jobs.Failure` kind, `other` by default), its `tool_timeline` (the runner's
# entries: name, duration_ms, status ok|error|unfinished, optional plugin), its
# `tool_tally` (the runner's whole-run tally, M106 §6: name, ok, error and unfinished
# counts, optional plugin and last_error) and its `trigger` (schedule or manual). The
# tally goes through the same settle, so an ok run whose tool never worked in it nor
# in its job's two runs before it opens a heal of kind `tool_never_succeeded` and
# stays ok; a plugin's tool makes it the plugin's heal, which a later job's tripping
# run joins. A tally the engine could not read would trip nothing, so a malformed one
# is refused. A failed run, or an ok run that opens a heal of its job, may also carry
# a `heal`: the conclusion its heal run would have reached (M106 §5.5), made through
# the Repo's own heal calls (claim, inbox, decision, message, delivered)
# `delivered_minutes_after` its run ended, so a later failed run joins a waiting heal
# or concludes a watching one a second time (the verdict) in its own settle. A rerun
# also names what came of its ask (`rerun_outcome`), recorded through the same call; a
# proposal is stored with the job version it was drawn for, which the owner's answer to
# it is fenced on, and may be followed by the owner's own edit (`owner_edit`), which
# supersedes it. A `tell` or `propose` conclusion timed `decided_minutes_after` instead
# is recorded and NOT sent: the heal run that held it stopped after its decision, as one
# that dies does, so its lease has run out and the daemon's next pass claims it, resolves
# the owner's inbox itself, and sends it (for a proposal, its card), with no model.
# Nothing is sent and the job is not touched otherwise: the spec states the job as the
# decision left it (a raised limit already raised, a proposal not applied). A job may be
# pinned to a route (`provider` and `model`, both or neither, the provider one the home
# configures). Every job and run is checked before the reset, so a refused spec leaves
# the home as it was.
#
# It runs in its own BEAM beside the eval daemon; SQLite (WAL, busy_timeout)
# serialises the two writers. Every value a spec carries is invented.

Code.require_file("seed_run_times.exs", __DIR__)

defmodule SeedState do
  alias Exqlite.Sqlite3
  alias FermixCore.Cues.Proposals
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.Degraded
  alias FermixCore.Jobs.Failure
  alias FermixCore.Jobs.HealCard
  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Jobs.Registry, as: Jobs
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
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
  # delete), a reminder mid-delivery, and a heal run holding its lease. Anything else is
  # not transient and raises.
  @transient [:run_in_flight, :job_running, :delivery_in_progress, :heal_in_flight]
  # The heal tables (M106) the reset empties, children first. A job's own rows also
  # go with it by cascade; a heal of a provider has no job, so only this removes it.
  @heal_tables ~w(job_heal_runs job_heals job_retries job_run_facts)
  @anchor_kinds ~w(matters_by ask_after)
  @reaches ~w(message conversation)
  @windows ~w(open closed)
  @other_close_reasons ~w(done stop dropped)
  @reaction_answers ~w(done plan not_yet stop drop moved reach)
  @max_reaction_passes 20
  # A seeded run's trigger, its tool timeline's outcomes, and what a seeded heal's
  # conclusion may say (M106 §5.5). A seeded pause is not offered: the seed makes
  # every job enabled.
  @run_triggers ~w(schedule manual)
  @timeline_statuses ~w(ok error unfinished)
  # A tool tally entry as the runner writes it (`Jobs.Runner`), and the run statuses
  # the settle reads a job's earlier tallies from (`Memory.Repo.JobHealsSql`).
  @tally_keys ~w(name ok error unfinished plugin last_error)
  @tally_counts ~w(ok error unfinished)
  @tally_read_statuses ~w(ok error timeout)
  @heal_decisions ~w(rerun raise_limit propose tell)
  @heal_keys ~w(decision note change read_outside rerun_outcome delivered_minutes_after
                decided_minutes_after owner_edit)
  # The decisions whose send a seed may leave to the daemon: neither moves the job, and
  # neither asks for a run after it is sent.
  @unsent_decisions ~w(tell propose)
  # What a seeded owner's edit after a proposal may change, as `Jobs.Registry`
  # takes it: each moves the job's definition, so the edit supersedes the proposal.
  @owner_edit_fields %{
    "schedule" => :schedule,
    "task_prompt" => :task_prompt,
    "timeout_seconds" => :timeout_seconds
  }
  @rerun_outcomes ~w(started running refused unanswered)
  # The job field each change field names, as a spec states the job.
  @change_fields %{
    "task" => "task_prompt",
    "schedule" => "schedule",
    "skill_name" => "skill_name",
    "timeout_seconds" => "timeout_seconds"
  }
  # The note a diagnosis may leave (`Tools.JobHealRespond`: longer is refused, never cut).
  @note_max 280
  # The failure kinds a seed can state the way the runner stores them: the reason each
  # is built from is the spec's (`other`'s own text) or the job's (`unknown_skill`'s
  # skill) or the run's (`time_limit`'s limit, the run's whole length).
  @seeded_kinds ~w(other unknown_skill time_limit)
  # The lease a seeded conclusion takes, as the Scheduler's claim does.
  @seeded_lease_s 300

  def main([spec_path]) do
    home = eval_home!()
    spec = spec_path |> File.read!() |> Jason.decode!()
    config = home_config!()
    same_database!(home)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    # `--no-start` skips `FermixCore.Application.start/2`, which records the boot
    # profile the Repo's start reads (through the Always On check); this helper is
    # a source build run from the checkout, as benchmark/audit/export_schemas.exs is.
    :ok = FermixCore.BootProfile.remember(:source)
    {:ok, _} = Repo.start_link([])
    {:ok, _} = MemoryStore.start_link([])
    now = DateTime.utc_now()
    loop_plans = plan_open_loops!(Map.get(spec, "open_loops", []), now, config)
    loop_keys = Enum.map(loop_plans, & &1.key)
    reply_plans = plan_replies!(Map.get(spec, "open_loop_replies", []), loop_keys, now)
    said_plans = plan_owner_messages!(Map.get(spec, "owner_messages", []), now)
    :ok = check_jobs!(Map.get(spec, "jobs", []), config, now)
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
  # delivery target are read exactly as the daemon read them at boot. No secret is
  # resolved: the seed needs none, and the default read runs through the daemon's
  # command host, which this script never starts.
  defp home_config! do
    {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)
    core = Map.fetch!(snapshot, :fermix_core)
    personalization = Keyword.fetch!(core, :personalization)
    zone = Keyword.get(personalization, :timezone) || raise "config.toml sets no timezone"
    # Merged over the compiled app env the way boot hydration merges it, so the
    # adapter map (`delivery_channels`) the reminder target resolves against is there.
    jobs =
      Keyword.merge(Application.get_env(:fermix_core, :jobs, []), Keyword.fetch!(core, :jobs))

    %{zone: zone, personalization: personalization, jobs: jobs, providers: configured(core)}
  end

  # The providers this home's config.toml sets anything for (the snapshot lists every
  # provider the engine knows, those it was given nothing for empty): an eval home
  # configures one, its primary.
  defp configured(core) do
    for {id, settings} <- Keyword.get(core, :providers, []), settings != [], do: to_string(id)
  end

  # --- reset -------------------------------------------------------------------

  # Delete every heal and job, cancel every reminder and close every live open loop,
  # once nothing is running. Job removal goes through Jobs.Registry so each job's
  # memory source is marked removed, exactly as the remove_job tool leaves it.
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
    with :ok <- delete_heals(),
         :ok <- remove_jobs(jobs),
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

  # Every heal, and every run's retry and facts, in one BEGIN IMMEDIATE write that the
  # daemon's heal claim (also BEGIN IMMEDIATE) cannot interleave with, refused while a
  # heal run holds its lease, so no send meets a heal that is gone. It runs before the
  # jobs go, whose removal would cascade a held heal away. Through a connection of its
  # own: the Repo has no call that removes a heal, and the engine is not changed for
  # the harness.
  defp delete_heals do
    {:ok, conn} = Sqlite3.open(MemoryConfig.database_path())

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;")
      :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")
      delete_unless_leased(conn)
    after
      :ok = Sqlite3.close(conn)
    end
  end

  defp delete_unless_leased(conn) do
    if leased_heals(conn) > 0 do
      :ok = Sqlite3.execute(conn, "ROLLBACK")
      {:error, :heal_in_flight}
    else
      Enum.each(@heal_tables, &(:ok = Sqlite3.execute(conn, "DELETE FROM #{&1}")))
      Sqlite3.execute(conn, "COMMIT")
    end
  end

  # A heal run holds its heal `diagnosing` under a lease; one whose lease ran out has
  # died, and the daemon's next pass claims its heal again.
  defp leased_heals(conn) do
    sql = "SELECT count(*) FROM job_heals WHERE state = 'diagnosing' AND lease_until > ?1"
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, [CuesSql.stamp(DateTime.utc_now())])
      {:row, [count]} = Sqlite3.step(conn, statement)
      count
    after
      :ok = Sqlite3.release(conn, statement)
    end
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
      provider: Map.get(spec, "provider"),
      model: Map.get(spec, "model"),
      expires_at: expires_at(spec, now),
      delivery_mode: "channel",
      delivery_target: Map.new(Keyword.fetch!(config.jobs, :default_delivery_target)),
      created_by_agent_id: "main",
      created_by_session_id: "eval-seed",
      created_by_channel: "cli",
      created_by_trust: "operator"
    }

    {:ok, job} = Jobs.create_job(attrs, now: now, scheduler: nil)
    starts = SeedRunTimes.starts!(spec, job_zone(spec, config), now)
    Enum.zip_with(runs(spec), starts, &seed_run!(job, &1, &2, config))
    # As the seed left it, a seeded owner's edit included.
    {:ok, seeded} = Repo.get_scheduled_job(job.id)
    {Map.fetch!(spec, "key"), job_snapshot(seeded)}
  end

  # What a checker compares the end state with ("unchanged" fields, the same id).
  # `enabled` is the row's `enabled?`, and `delivery_target` the stored map.
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
      :expires_at,
      :delivery_mode,
      :delivery_target,
      :provider,
      :model
    ])
    |> Map.update!(:expires_at, &(&1 && DateTime.to_iso8601(&1)))
    |> Map.put(:enabled, job.enabled?)
  end

  defp expires_at(spec, now) do
    case Map.get(spec, "expires_in_days") do
      nil -> nil
      days -> DateTime.add(now, days * 86_400, :second) |> DateTime.truncate(:second)
    end
  end

  # The scheduler's own claim, then the runner's own settle, back-dated to the run's
  # start (`SeedRunTimes`): the job's last_run_at / last_status / last_error come from
  # the settle exactly as they do after a real run. A run's `heal` is concluded right
  # after its settle.
  defp seed_run!(job, spec, started, config) do
    completed = SeedRunTimes.ended(spec, started)
    id = "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    run = %{
      id: id,
      job_id: job.id,
      session_id: "cron_#{job.id}_#{DateTime.to_unix(started)}",
      trigger: Map.get(spec, "trigger", "schedule"),
      status: "running",
      claimed_at: started,
      started_at: started,
      prompt_snapshot: job.task_prompt,
      delivery_status: seeded_delivery_status(Map.fetch!(spec, "status")),
      created_at: started,
      updated_at: started
    }

    {:ok, _} = Repo.claim_job_now(job.id, %{state: "running", updated_at: started}, run)
    status = Map.fetch!(spec, "status")

    {:ok, _} =
      Repo.settle_job_run(
        run
        |> Map.merge(%{
          status: status,
          completed_at: completed,
          final_response: Map.get(spec, "final_response"),
          tool_timeline: Map.get(spec, "tool_timeline"),
          tool_tally: Map.get(spec, "tool_tally"),
          updated_at: completed
        })
        |> Map.merge(seeded_failure(status, job, spec)),
        seeded_settle_by(status)
      )

    case Map.get(spec, "heal") do
      nil -> :ok
      heal -> conclude_heal!(job, heal, SeedRunTimes.concluded(spec, started), config)
    end
  end

  # A failure the heal takes sends nothing where the job delivers (M106 §5.4), so a
  # seeded failed run's own delivery reads as a live one's does.
  defp seeded_delivery_status("ok"), do: "delivered"
  defp seeded_delivery_status(_failed), do: "skipped"

  # A seeded failure says nothing waiting can clear, so it sets no retry: the
  # seeded home holds the history the spec names and nothing else.
  defp seeded_settle_by("ok"), do: :ok
  defp seeded_settle_by(_failed), do: {:failed, :other}

  # A seeded failure stored as the runner stores one (M106 §5.8): of the kind its spec
  # names (`other` by default), its reason built as the runner's would be, the heal
  # told Fermix's own sentence for it (`Failure.sentence/2`, naming the tool still
  # running when a limit stopped it), and the run's error that sentence, or for a kind
  # Fermix has no sentence for its own words, which the heal quotes as someone else's.
  defp seeded_failure("ok", _job, _spec), do: %{}

  defp seeded_failure(_failed, job, spec) do
    kind = Map.get(spec, "failure_kind", "other")
    reason = seeded_reason(kind, job, spec)
    tool = in_flight(Map.get(spec, "tool_timeline"))
    sentence = Failure.sentence(reason, in_flight: tool)
    own_words = if kind == "other", do: Failure.other_text(reason), else: nil

    %{
      error: own_words || sentence,
      failure_kind: kind,
      heal_facts: %{failure_text: sentence, failure_words: own_words, provider: nil}
    }
  end

  defp seeded_reason("other", _job, spec), do: Map.fetch!(spec, "error")
  defp seeded_reason("unknown_skill", job, _spec), do: {:unknown_skill, job.skill_name}

  defp seeded_reason("time_limit", _job, spec),
    do: {:time_limit, Map.fetch!(spec, "duration_seconds") * 1_000}

  # The tool still running when the run stopped: the newest entry its timeline marks
  # unfinished, as the runner reads it.
  defp in_flight(nil), do: nil

  defp in_flight(timeline) do
    timeline
    |> Enum.reverse()
    |> Enum.find_value(fn entry -> entry["status"] == "unfinished" && entry["name"] end)
  end

  # --- a seeded heal's conclusion (M106 §5.5) ----------------------------------

  # The heal this run opened or joined, concluded as its heal run would have, through
  # the Repo's own calls: claimed under a lease, its inbox the owner's, its decision
  # recorded, its message built by `Jobs.HealMessage` from the store's facts, and its
  # delivery marked, which takes it where its decision says. Nothing is sent, and the
  # job is as the spec states it. `check_jobs!/2` made sure no other heal is open, so
  # the claim's oldest open heal is this run's.
  defp conclude_heal!(job, %{"decided_minutes_after" => _minutes} = heal, at, config),
    do: decide_unsent!(job, heal, at, config)

  defp conclude_heal!(job, heal, at, config) do
    lease_until = DateTime.add(at, @seeded_lease_s, :second)
    {id, token} = claim_seeded_heal!(job, at, lease_until)
    inbox = seeded_inbox!(config)
    :ok = Repo.job_heals_call({:put_inbox, id, token, inbox, at})
    :ok = conclude_message!(seeded_plan(heal, job), {id, token}, inbox, at, config)
    :ok = Repo.job_heals_call({:delivered, id, token, at})
    record_rerun_outcome!(id, heal, at)
    owner_edit!(job, Map.get(heal, "owner_edit"))
  end

  # A conclusion whose send is left to the daemon: the decision recorded under a lease
  # that ends a second after it, as a heal run that died after deciding leaves it, and
  # nothing else. No inbox is stored (the daemon's heal run resolves it, the rule under
  # test) and no message for a tell (the run builds it); a proposal keeps the short ask
  # its card is held to, fitted against the inbox this home's rule gives, as a heal run
  # stores it with its decision, and its card is bound by the send that offers it.
  defp decide_unsent!(job, heal, at, config) do
    {id, token} = claim_seeded_heal!(job, at, DateTime.add(at, 1, :second))
    :ok = decide_message!(seeded_plan(heal, job), {id, token}, seeded_inbox!(config), at, config)
  end

  defp decide_message!(%{decision: "propose"} = plan, {id, token}, inbox, at, config) do
    case fitted_proposal(plan, id, inbox, config) do
      {:offered, offered} -> Repo.job_heals_call({:decided, id, token, offered, at})
      {:kept, kept} -> decide_message!(kept, {id, token}, inbox, at, config)
    end
  end

  defp decide_message!(plan, {id, token}, _inbox, at, _config),
    do: Repo.job_heals_call({:decided, id, token, plan, at})

  # The owner's inbox for a heal's card, by the engine's own rule and this home's config.
  defp seeded_inbox!(config) do
    {:ok, inbox} =
      OwnerInbox.for_approval(:approval_card, jobs_config: config.jobs, configured_owners: %{})

    inbox
  end

  # The owner's own edit of the job after its proposal reached them, through the
  # edit path `update_job` takes, which closes the waiting proposal superseded in
  # the same write (M106 §5.7).
  defp owner_edit!(_job, nil), do: :ok

  defp owner_edit!(job, edit) do
    attrs = Map.new(edit, fn {field, value} -> {Map.fetch!(@owner_edit_fields, field), value} end)
    {:ok, _edited} = Jobs.update_job(job.id, attrs, scheduler: nil)
    :ok
  end

  # A proposal goes out as a heal run sends one (`Jobs.HealRun`, M106 §5.7, D5): its
  # short ask, held to its card's bound and to an inbox whose chat can answer it
  # (`HealDecision.fit_card/3`, which otherwise keeps it as `tell`), is stored with the
  # decision, and the card is bound to that chat under a fresh token, as a send
  # leaves it. Every other decision's message is built from the store's facts.
  defp conclude_message!(%{decision: "propose"} = plan, {id, token}, inbox, at, config) do
    case fitted_proposal(plan, id, inbox, config) do
      {:offered, offered} ->
        :ok = Repo.job_heals_call({:decided, id, token, offered, at})
        {:ok, card_origin} = OwnerInbox.answer_origin(inbox)
        bind_card!(id, token, card_origin, at)

      {:kept, kept} ->
        conclude_message!(kept, {id, token}, inbox, at, config)
    end
  end

  defp conclude_message!(plan, {id, token}, _inbox, at, config) do
    :ok = Repo.job_heals_call({:decided, id, token, plan, at})
    {:ok, facts} = Repo.job_heals_call({:message_facts, id})
    text = HealMessage.build(facts, personalization: config.personalization)
    Repo.job_heals_call({:put_message, id, token, text, at})
  end

  # A proposal's short ask built from the facts with its decision, held to its card's
  # bound and to an inbox whose chat can answer it (`HealDecision.fit_card/3`), as a heal
  # run fits it: offered with that ask as its message, or kept as tell.
  defp fitted_proposal(plan, id, inbox, config) do
    {:ok, facts} = Repo.job_heals_call({:message_facts, id})
    facts = Map.merge(facts, %{decision: "propose", note: plan.note, change: plan.change})
    lines = HealMessage.card_lines(facts, personalization: config.personalization)
    chars = lines |> HealCard.card(plan.change) |> HealCard.chars()
    chat? = match?({:ok, _origin}, OwnerInbox.answer_origin(inbox))

    case HealDecision.fit_card(plan, chat?, chars) do
      %{decision: "propose"} = offered ->
        {:offered, Map.put(offered, :message, Enum.join(lines, "\n"))}

      kept ->
        IO.puts(:stderr, "seed: heal #{id}'s proposal kept as tell: #{kept.refusal_detail}")
        {:kept, kept}
    end
  end

  defp bind_card!(id, token, origin, at) do
    secret = Proposals.new_token()
    card = %{token: secret, digest: Proposals.digest(secret), origin: origin}
    {:ok, ^secret} = Repo.job_heals_call({:bind_card, id, token, card, at})
    :ok
  end

  # What came of a seeded rerun's ask, recorded with the call the heal run makes after
  # its concluding write: a refused one leaves the heal waiting, since no run is coming.
  # The run a `started` one began is the spec's next run, by hand.
  defp record_rerun_outcome!(id, %{"decision" => "rerun"} = heal, at),
    do: :ok = Repo.job_heals_call({:rerun_outcome, id, Map.fetch!(heal, "rerun_outcome"), at})

  defp record_rerun_outcome!(_id, _heal, _at), do: :ok

  defp claim_seeded_heal!(job, at, lease_until) do
    case Repo.job_heals_call({:claim, at, lease_until}) do
      {:ok, %{id: id, job_id: job_id, lease_token: token}} when job_id == job.id ->
        {id, token}

      other ->
        raise "a seeded heal of #{job.id} could not be claimed (#{inspect(other)}): the " <>
                "eval daemon may have claimed it first; seed again"
    end
  end

  # What a heal run records (`Jobs.HealRun`): a failure is framed as outside content,
  # so its run read some unless the spec says otherwise.
  defp seeded_plan(heal, job) do
    change = Map.get(heal, "change")

    %{
      decision: Map.fetch!(heal, "decision"),
      requested: Map.fetch!(heal, "decision"),
      refusal: nil,
      refusal_detail: nil,
      note: Map.fetch!(heal, "note"),
      read_outside: Map.get(heal, "read_outside", true),
      change: change,
      change_job_version: change && job.updated_at,
      change_job_digest: proposal_digest(Map.fetch!(heal, "decision"), job)
    }
  end

  # The version of the job a proposal is drawn for (M106 §5.7), from the engine's
  # own digest: without it the owner's yes reads as superseded and applies nothing.
  defp proposal_digest("propose", job), do: HealDecision.job_version(job)
  defp proposal_digest(_decision, _job), do: nil

  # --- what a jobs spec may say, checked before the reset ----------------------

  defp check_jobs!(specs, config, now) when is_list(specs) do
    Enum.each(specs, &check_job_runs!(&1, config, now))
    concluding = Enum.filter(specs, &Enum.any?(runs(&1), fn run -> Map.has_key?(run, "heal") end))
    opening = Enum.filter(specs, &opens_heal?/1)

    if concluding != [] and length(opening) > 1 do
      raise "jobs: a spec that concludes a seeded heal may give only one job runs that open " <>
              "a heal, failed or ending ok without working (the claim takes the oldest open " <>
              "heal), got #{length(opening)}"
    end

    if concluding != [], do: owner_inbox!(config)
    :ok
  end

  # A job's route pin, as `update_job` takes one (`Tools.JobRegistrySupport`): the
  # provider and the model together or neither, the provider one this home configures,
  # so the pin is one its runs could take and its heal's look reads it as the owner's.
  defp check_route_pin!(key, spec, config) do
    pin = Map.take(spec, ["provider", "model"])

    unless pin == %{} or
             (map_size(pin) == 2 and Enum.all?(Map.values(pin), &(is_binary(&1) and &1 != ""))),
           do:
             raise(
               "jobs #{key}: a route pin names its provider and its model together, or neither, got #{inspect(pin)}"
             )

    unless pin == %{} or pin["provider"] in config.providers,
      do:
        raise(
          "jobs #{key}: the pin's provider #{inspect(pin["provider"])} is not one this home configures (#{inspect(config.providers)}); seed the home with that provider"
        )
  end

  defp runs(spec), do: Map.get(spec, "runs", [])
  defp failed?(run), do: Map.get(run, "status") != "ok"
  defp job_zone(spec, config), do: Map.get(spec, "timezone", config.zone)

  # A failed run opens a heal (or joins one); so does an ok run that trips the rule of
  # runs that end ok without working (M106 §6).
  defp opens_heal?(spec) do
    runs = runs(spec)

    runs
    |> Enum.with_index()
    |> Enum.any?(fn {run, index} -> failed?(run) or tripped(runs, index) != :none end)
  end

  # What the seed's own settle of the ok run at `index` makes of the tallies, by the
  # engine's rule (`Jobs.Degraded`): the run's tally, then those of the runs settled
  # before it that the settle reads, newest first. `SeedRunTimes.check_order!/4` keeps
  # the spec's order the settle's.
  defp tripped(runs, index) do
    {before, [run | _after]} = Enum.split(runs, index)

    earlier =
      before
      |> Enum.filter(&(Map.get(&1, "status") in @tally_read_statuses))
      |> Enum.take(-(Degraded.runs() - 1))
      |> Enum.reverse()

    Degraded.decide(Enum.map([run | earlier], &Map.get(&1, "tool_tally")))
  end

  defp owner_inbox!(config) do
    case OwnerInbox.for_approval(:approval_card, jobs_config: config.jobs, configured_owners: %{}) do
      {:ok, _inbox} ->
        :ok

      other ->
        raise "a seeded heal needs an owner's inbox a send reaches (--owner-inbox-cli or " <>
                "--owner-inbox-app): #{inspect(other)}"
    end
  end

  defp check_job_runs!(spec, config, now) do
    key = Map.get(spec, "key")
    check_route_pin!(key, spec, config)
    runs = runs(spec)
    starts = SeedRunTimes.starts!(spec, job_zone(spec, config), now)
    :ok = SeedRunTimes.check_order!(key, runs, starts, now)

    runs
    |> Enum.with_index()
    |> Enum.each(fn {run, index} ->
      check_run!(key, spec, run)

      case Map.get(run, "heal") do
        nil -> :ok
        heal -> check_heal!(key, spec, runs, index, heal)
      end
    end)
  end

  defp check_run!(key, spec, run) do
    trigger = Map.get(run, "trigger", "schedule")

    unless trigger in @run_triggers,
      do:
        raise(
          "jobs #{key}: trigger must be one of #{inspect(@run_triggers)}, got #{inspect(trigger)}"
        )

    check_failure!(key, spec, run)
    check_timeline!(key, Map.get(run, "tool_timeline"))
    check_tally!(key, Map.get(run, "tool_tally"))
  end

  # A failed run's kind is one the seed builds a reason for. Only `other` states its
  # own words (`error`); every other kind's text is Fermix's sentence, which the seed
  # takes from the engine, so a spec never carries a copy of it. An ok run states none.
  defp check_failure!(key, _spec, %{"status" => "ok"} = run) do
    if Map.has_key?(run, "failure_kind") or Map.has_key?(run, "error"),
      do: raise("jobs #{key}: an ok run states no failure_kind or error, got #{inspect(run)}")
  end

  defp check_failure!(key, spec, run) do
    kind = Map.get(run, "failure_kind", "other")

    unless kind in @seeded_kinds,
      do:
        raise(
          "jobs #{key}: a seeded failure's kind is one of #{inspect(@seeded_kinds)}, got #{inspect(kind)}"
        )

    check_failure_reason!(key, kind, spec, run)
  end

  defp check_failure_reason!(key, "other", _spec, run) do
    unless is_binary(run["error"]) and run["error"] != "",
      do: raise("jobs #{key}: an `other` failure states its own words as error")
  end

  defp check_failure_reason!(key, kind, spec, run) do
    if Map.has_key?(run, "error"),
      do:
        raise(
          "jobs #{key}: a #{kind} failure's text is Fermix's own sentence, so the spec states no error"
        )

    check_kind_source!(key, kind, spec, run)
  end

  defp check_kind_source!(key, "unknown_skill", spec, _run) do
    unless is_binary(spec["skill_name"]) and spec["skill_name"] != "",
      do: raise("jobs #{key}: an unknown_skill failure needs the job's skill_name")
  end

  defp check_kind_source!(key, "time_limit", _spec, run) do
    unless run["status"] == "timeout",
      do: raise("jobs #{key}: a time_limit failure is a timeout, stopped at its whole length")
  end

  # The runner's tally (M106 §6), each tool once: a tally the engine cannot read would
  # count as none and trip nothing, so a malformed one is refused before the reset
  # rather than seeded to measure nothing.
  defp check_tally!(_key, nil), do: :ok

  defp check_tally!(key, entries) when is_list(entries) do
    Enum.each(entries, fn entry ->
      unless tally_entry?(entry),
        do:
          raise(
            "jobs #{key}: a tool_tally entry is the runner's: a name, ok, error and unfinished counts (not all 0), an optional plugin and last_error, nothing else; got #{inspect(entry)}"
          )
    end)

    names = Enum.map(entries, &Map.fetch!(&1, "name"))

    unless names == Enum.uniq(names),
      do: raise("jobs #{key}: a tool_tally names each tool once, got #{inspect(names)}")
  end

  defp check_tally!(key, other),
    do: raise("jobs #{key}: tool_tally must be a list, got #{inspect(other)}")

  defp tally_entry?(%{"name" => name} = entry) when is_binary(name) and name != "" do
    counts = Enum.map(@tally_counts, &Map.get(entry, &1))

    Map.keys(entry) -- @tally_keys == [] and Enum.all?(counts, &count?/1) and
      Enum.sum(counts) > 0 and plugin?(Map.get(entry, "plugin")) and
      (is_nil(entry["last_error"]) or is_binary(entry["last_error"]))
  end

  defp tally_entry?(_entry), do: false

  defp count?(value), do: is_integer(value) and value >= 0
  defp plugin?(plugin), do: is_nil(plugin) or (is_binary(plugin) and plugin != "")

  defp check_timeline!(_key, nil), do: :ok

  defp check_timeline!(key, entries) when is_list(entries) do
    Enum.each(entries, fn
      %{"name" => name, "duration_ms" => ms, "status" => status} = entry
      when is_binary(name) and is_integer(ms) and ms >= 0 and status in @timeline_statuses ->
        if Map.keys(entry) -- ["name", "duration_ms", "status", "plugin"] != [],
          do: raise("jobs #{key}: a tool_timeline entry has unknown keys: #{inspect(entry)}")

      entry ->
        raise "jobs #{key}: a tool_timeline entry needs name, duration_ms and a status in " <>
                "#{inspect(@timeline_statuses)}, got #{inspect(entry)}"
    end)
  end

  defp check_timeline!(key, other),
    do: raise("jobs #{key}: tool_timeline must be a list, got #{inspect(other)}")

  # A conclusion of the heal a run opened: a decision the seed can state, a note as
  # the decision tool takes one, a change that says what the job holds, nothing else,
  # and a time after this run ended and before the next began (`SeedRunTimes`).
  defp check_heal!(key, spec, runs, index, heal) do
    run = Enum.at(runs, index)
    next_run = Enum.at(runs, index + 1)
    decision = Map.get(heal, "decision")
    note = Map.get(heal, "note")

    unless failed?(run), do: check_tool_heal!(key, tripped(runs, index))

    unless Map.keys(heal) -- @heal_keys == [],
      do:
        raise(
          "jobs #{key}: a seeded heal names only #{inspect(@heal_keys)}, got #{inspect(heal)}"
        )

    unless decision in @heal_decisions,
      do:
        raise(
          "jobs #{key}: a seeded heal's decision must be one of #{inspect(@heal_decisions)}, got #{inspect(decision)}"
        )

    unless is_binary(note) and note != "" and String.length(note) <= @note_max,
      do: raise("jobs #{key}: a seeded heal needs a note of 1 to #{@note_max} characters")

    check_change!(key, spec, decision, Map.get(heal, "change"))
    check_rerun_outcome!(key, decision, next_run, Map.get(heal, "rerun_outcome"))
    check_owner_edit!(key, spec, decision, Map.get(heal, "owner_edit"))
    check_unsent!(key, decision, heal)
  end

  # A send left to the daemon: a decision that moves nothing and asks for no run, with
  # nothing after it that a sent message would come first for.
  defp check_unsent!(key, decision, %{"decided_minutes_after" => _minutes} = heal) do
    unless decision in @unsent_decisions and not Map.has_key?(heal, "owner_edit"),
      do:
        raise(
          "jobs #{key}: a seeded heal whose send is left to the daemon (decided_minutes_after) is one of #{inspect(@unsent_decisions)} with no owner_edit, got #{inspect(heal)}"
        )
  end

  defp check_unsent!(_key, _decision, _heal), do: :ok

  # An owner's edit after a proposal: on a proposal only, each field one the edit
  # path takes, each value a change from what the spec states.
  defp check_owner_edit!(_key, _spec, _decision, nil), do: :ok

  defp check_owner_edit!(key, spec, "propose", edit) when is_map(edit) and map_size(edit) > 0 do
    for {field, value} <- edit,
        not Map.has_key?(@owner_edit_fields, field) or Map.get(spec, field) == value do
      raise "jobs #{key}: an owner_edit changes one of #{inspect(Map.keys(@owner_edit_fields))} " <>
              "to a new value, got #{field}: #{inspect(value)}"
    end

    :ok
  end

  defp check_owner_edit!(key, _spec, decision, edit),
    do:
      raise(
        "jobs #{key}: an owner_edit follows a propose conclusion only, got #{decision}: #{inspect(edit)}"
      )

  # An ok run's heal is one its tool opened for the job (M106 §6). A plugin's heal is
  # told by code with no decision, so it has no conclusion to seed.
  defp check_tool_heal!(_key, {:tool, %{plugin: nil}}), do: :ok

  defp check_tool_heal!(key, {:tool, %{plugin: plugin}}),
    do:
      raise(
        "jobs #{key}: the heal this run opens is the plugin #{plugin}'s, which code tells with no decision; it has no conclusion to seed"
      )

  defp check_tool_heal!(key, :none),
    do:
      raise(
        "jobs #{key}: a heal is concluded on a failed run, or on an ok run whose tool never worked in it and in the job's two runs before it; this run opens none"
      )

  # A rerun says what came of its ask (`Jobs.HealRun`'s outcomes), and no other
  # decision has one. A run that `started` is the spec's next run, started by hand.
  defp check_rerun_outcome!(key, "rerun", next_run, outcome) do
    unless outcome in @rerun_outcomes,
      do:
        raise(
          "jobs #{key}: a seeded rerun names its rerun_outcome, one of #{inspect(@rerun_outcomes)}, got #{inspect(outcome)}"
        )

    if outcome == "started" and Map.get(next_run || %{}, "trigger") != "manual",
      do: raise("jobs #{key}: a rerun that started is followed by its run, trigger manual")

    :ok
  end

  defp check_rerun_outcome!(_key, _decision, _next_run, nil), do: :ok

  defp check_rerun_outcome!(key, decision, _next_run, outcome),
    do:
      raise("jobs #{key}: a #{decision} conclusion has no rerun_outcome, got #{inspect(outcome)}")

  # A raised limit is on the job already (the spec states it raised, within the
  # engine's run limit); a proposal is not (each field holds its `from`). Any other
  # decision changes nothing.
  defp check_change!(_key, _spec, decision, nil) when decision in ["rerun", "tell"], do: :ok

  defp check_change!(key, _spec, decision, change) when decision in ["rerun", "tell"],
    do: raise("jobs #{key}: a #{decision} conclusion carries no change, got #{inspect(change)}")

  defp check_change!(
         key,
         spec,
         "raise_limit",
         %{"timeout_seconds" => %{"from" => from, "to" => to}} = change
       )
       when map_size(change) == 1 and is_integer(from) and is_integer(to) do
    ceiling = div(FermixCore.Jobs.Runner.default_timeout_ms(), 1_000)

    unless from < to and to <= ceiling and Map.get(spec, "timeout_seconds") == to,
      do:
        raise(
          "jobs #{key}: a raised limit goes up to at most #{ceiling} s, and the job states it raised"
        )
  end

  defp check_change!(key, spec, "propose", change) when is_map(change) and map_size(change) > 0 do
    Enum.each(change, fn
      {field, %{"from" => from, "to" => to}}
      when is_map_key(@change_fields, field) and from != to ->
        unless Map.get(spec, Map.fetch!(@change_fields, field)) == from,
          do:
            raise("jobs #{key}: a proposal is not applied, so the job holds its #{field}'s from")

      {field, value} ->
        raise "jobs #{key}: a seeded change names one of #{inspect(Map.keys(@change_fields))} " <>
                "with a different from and to, got #{field}: #{inspect(value)}"
    end)
  end

  defp check_change!(key, _spec, decision, change),
    do: raise("jobs #{key}: a #{decision} conclusion's change is malformed: #{inspect(change)}")

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
