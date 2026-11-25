defmodule FermixCore.Memory.RepoJobHealsDegradedTest do
  # M106 §6 (stage S5): a run that ends ok without working. At the settle of
  # an ok run, a tool the run called that never once succeeded in it, nor in
  # each of the job's two runs before it, opens the heal a failure that is
  # not retried would, in the same transaction: its subject the tool's plugin
  # when it has one, the job otherwise. The run's own row stays ok with no
  # kind. Every time here is given, never read from a clock.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Jobs.Failure
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @created ~U[2031-03-04 05:00:00.000000Z]
  @kind "tool_never_succeeded"
  @lease_s 300

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-job-heals-degraded-#{unique}.db")
    repo = :"memory_repo_job_heals_degraded_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, db_path: db_path}
  end

  describe "the trigger at an ok run's settle" do
    test "three ok runs in a row whose tool never succeeded open one heal; two do not", %{
      repo: repo
    } do
      job = create_job!(repo)

      assert %{heal: :none, healed: []} = ok_run!(repo, job, at(6), [refused("tide_lookup", 2)])

      assert %{heal: :none, healed: []} =
               ok_run!(repo, job, at(7), [refused("tide_lookup", 1, "station asleep")])

      assert open_heals(repo) == []

      {third, settlement} =
        ok_run(repo, job, at(8), [
          tool("web_fetch", 3, 0),
          refused("tide_lookup", 4, "station offline")
        ])

      assert %{heal: {:opened, heal_id}, healed: []} = settlement

      assert %{failure_kind: @kind, subject_kind: "job", subject_id: subject_id} = settlement
      assert subject_id == job.id

      assert {:ok, heal} = Repo.job_heals_call({:get, heal_id}, server: repo)

      assert %{
               subject_kind: "job",
               failure_kind: @kind,
               failure_words: "station offline",
               state: "open",
               run_count: 1,
               tool: %{"name" => "tide_lookup", "failed_calls" => [4, 1, 2]}
             } = heal

      assert {heal.subject_id, heal.job_id, heal.last_run_id} == {job.id, job.id, third.id}
      assert heal.failure_text == Failure.sentence(:tool_never_succeeded)
      refute Map.has_key?(heal.tool, "plugin")
      assert heal_runs(repo, heal_id) == [third.id]

      # The run that tripped it stays an ok run with no kind.
      assert {:ok, %{status: "ok", failure_kind: nil, error: nil}} =
               Repo.get_job_run(third.id, server: repo)

      assert {:ok, %{last_status: "ok"}} = Repo.get_scheduled_job(job.id, server: repo)
    end

    test "a success of the tool in any of the three runs opens none", %{repo: repo} do
      for passing <- 0..2 do
        job = create_job!(repo)

        for {hour, index} <- Enum.with_index([6, 7, 8]) do
          entry =
            if index == passing,
              do: tool("tide_lookup", 1, 9),
              else: refused("tide_lookup")

          assert %{heal: :none} = ok_run!(repo, job, at(hour), [entry])
        end
      end

      assert open_heals(repo) == []
    end

    test "the two runs before are the job's latest settled, a failed one included; cue runs are passed over",
         %{repo: repo, db_path: db_path} do
      job = create_job!(repo)

      # A failed run with the refused tool is one of the three.
      assert %{heal: :none} = ok_run!(repo, job, at(5), [refused("tide_lookup")])

      assert {:ok, {_run, _job, %{heal: {:opened, time_heal}}}} =
               fail(repo, claim!(repo, job, at(6)), at(6, 9), [refused("tide_lookup", 2)])

      # Two cue runs, one where the tool worked, sit between the runs: no streak
      # of a scheduled job's runs ever counts them.
      seed_cue_run(db_path, job, at(6, 20), [tool("tide_lookup", 1, 0)])
      seed_cue_run(db_path, job, at(6, 40), [refused("tide_lookup")])

      # The trip's subject is the job, so its run joins the job's open heal.
      assert %{heal: {:joined, ^time_heal}, failure_kind: @kind} =
               ok_run!(repo, job, at(7), [refused("tide_lookup")])

      # A cue run's refusals make no streak either.
      other = create_job!(repo)
      seed_cue_run(db_path, other, at(6), [refused("tide_lookup")])
      seed_cue_run(db_path, other, at(6, 30), [refused("tide_lookup")])
      assert %{heal: :none} = ok_run!(repo, other, at(7), [refused("tide_lookup")])
    end

    test "a run with no tally before it breaks the streak", %{repo: repo, db_path: db_path} do
      job = create_job!(repo)
      seed_untallied_run(db_path, job, at(5))
      assert %{heal: :none} = ok_run!(repo, job, at(6), [refused("tide_lookup")])
      assert %{heal: :none} = ok_run!(repo, job, at(7), [refused("tide_lookup")])
      assert open_heals(repo) == []
      assert %{heal: {:opened, _id}} = ok_run!(repo, job, at(8), [refused("tide_lookup")])
    end

    test "a guest's job is not healed", %{repo: repo} do
      job = create_job!(repo, created_by_trust: "guest")

      for hour <- [6, 7, 8] do
        assert %{heal: :none} = ok_run!(repo, job, at(hour), [refused("tide_lookup")])
      end

      assert open_heals(repo) == []
    end
  end

  describe "a plugin's tool" do
    test "makes the plugin the subject, and a second job tripping on it joins the one heal", %{
      repo: repo
    } do
      first = create_job!(repo)
      second = create_job!(repo)
      whoami = refused("whoami", 1, "needs reconnection", "harbour_id")

      for hour <- [6, 7], job <- [first, second] do
        assert %{heal: :none} = ok_run!(repo, job, at(hour), [whoami])
      end

      {first_run, opened} = ok_run(repo, first, at(8), [whoami])

      assert %{heal: {:opened, heal_id}, subject_kind: "plugin", subject_id: "harbour_id"} =
               opened

      {second_run, joined} = ok_run(repo, second, at(8, 5), [whoami])
      assert %{heal: {:joined, ^heal_id}} = joined

      assert [%{id: ^heal_id} = heal] = open_heals(repo)

      assert %{
               subject_kind: "plugin",
               subject_id: "harbour_id",
               job_id: nil,
               failure_kind: @kind,
               failure_words: "needs reconnection",
               run_count: 2,
               tool: %{"name" => "whoami", "plugin" => "harbour_id", "failed_calls" => [1, 1, 1]}
             } = heal

      assert Enum.sort(heal_runs(repo, heal_id)) == Enum.sort([first_run.id, second_run.id])
    end

    # A plugin's heal is about one tool: another tool of the same plugin
    # working proves nothing of it, or the heal would close, the first job
    # trip again, and a second message go out, round and round.
    test "its heal closes only on an ok run in which its own tool succeeded", %{repo: repo} do
      heal_id = plugin_heal!(repo, "harbour_id")
      bystander = create_job!(repo)

      for {hour, tally} <- [
            {9, [tool("web_fetch", 2, 0)]},
            {10, [tool("whereami", 3, 0, plugin: "harbour_id")]},
            {11, [refused("whoami", 1, nil, "harbour_id")]}
          ] do
        assert %{heal: :none, healed: []} = ok_run!(repo, bystander, at(hour), tally)
      end

      assert {:ok, %{state: "open"}} = Repo.job_heals_call({:get, heal_id}, server: repo)

      assert %{heal: :none, healed: [^heal_id]} =
               ok_run!(repo, bystander, at(12), [tool("whoami", 1, 1, plugin: "harbour_id")])

      assert {:ok, %{state: "closed", outcome: "healed"}} =
               Repo.job_heals_call({:get, heal_id}, server: repo)
    end

    test "a run that trips on another tool still closes a plugin's heal whose own tool worked in it",
         %{repo: repo} do
      heal_id = plugin_heal!(repo, "harbour_id")
      job = create_job!(repo)

      for hour <- [6, 7] do
        assert %{heal: :none} = ok_run!(repo, job, at(hour), [refused("tide_lookup")])
      end

      assert %{heal: {:opened, job_heal}, subject_kind: "job", healed: [^heal_id]} =
               ok_run!(repo, job, at(8), [
                 refused("tide_lookup"),
                 tool("whoami", 1, 0, plugin: "harbour_id")
               ])

      refute job_heal == heal_id
    end
  end

  describe "a job's heal of a tool that never worked" do
    test "stays across runs that do not call the tool or fail it without tripping, and closes when it works",
         %{repo: repo} do
      job = create_job!(repo)

      for hour <- [6, 7] do
        assert %{heal: :none} = ok_run!(repo, job, at(hour), [refused("tide_lookup")])
      end

      assert %{heal: {:opened, heal_id}} = ok_run!(repo, job, at(8), [refused("tide_lookup")])

      for {hour, tally} <- [
            {9, [tool("web_fetch", 2, 0)]},
            {10, [refused("tide_lookup")]},
            {11, []}
          ] do
        assert %{heal: :none, healed: []} = ok_run!(repo, job, at(hour), tally)
      end

      assert {:ok, %{state: "open"}} = Repo.job_heals_call({:get, heal_id}, server: repo)

      assert %{heal: :none, healed: [^heal_id]} =
               ok_run!(repo, job, at(12), [tool("tide_lookup", 1, 2)])
    end

    test "a job's heal of a failure still closes on any ok run that does not trip", %{repo: repo} do
      job = create_job!(repo)

      {:ok, {_r, _j, %{heal: {:opened, heal_id}}}} =
        fail(repo, claim!(repo, job, at(6)), at(6, 9), [])

      assert %{heal: :none, healed: [^heal_id]} =
               ok_run!(repo, job, at(7), [tool("web_fetch", 1, 0)])
    end
  end

  # A row this engine cannot read (a damaged one, or a shape a later engine
  # sharing the home writes) proves nothing: it reads as no tally, which
  # breaks the streak, and the store, whose process runs the settle, stays up.
  describe "a stored tally this engine cannot read" do
    @unreadable [
      {"text that is not JSON", "{not json marker-3V"},
      {"not a list", ~s({"name": "tide_lookup", "marker": "marker-3V"})},
      {"an entry missing a count", ~s([{"name": "tide_lookup", "error": 1, "m": "marker-3V"}])},
      {"a count of the wrong type",
       ~s([{"name": "tide_lookup", "ok": "none", "error": 1, "m": "marker-3V"}])}
    ]

    for {label, stored} <- @unreadable do
      @stored stored
      test "#{label}, before the run: the settle commits, opens no heal, and the store stays up",
           %{repo: repo, db_path: db_path} do
        job = create_job!(repo)
        before = Process.whereis(repo)
        seed_run(db_path, job, at(6), Jason.encode!([refused("tide_lookup")]))
        unreadable = seed_run(db_path, job, at(7), @stored)

        {result, log} =
          ExUnit.CaptureLog.with_log(fn ->
            ok_run(repo, job, at(8), [refused("tide_lookup")])
          end)

        assert {_run, %{heal: :none}} = result
        assert log =~ unreadable
        refute log =~ "marker-3V"
        assert open_heals(repo) == []
        assert Process.whereis(repo) == before
      end
    end

    test "the settling run's own stored tally: the settle commits, and its reads give no tally",
         %{repo: repo, db_path: db_path} do
      job = create_job!(repo)
      before = Process.whereis(repo)

      for hour <- [6, 7] do
        assert %{heal: :none} = ok_run!(repo, job, at(hour), [refused("tide_lookup")])
      end

      run = claim!(repo, job, at(8))

      raw(
        db_path,
        "INSERT INTO job_run_facts (run_id, tool_tally_json) VALUES ('#{run.id}', '[1');"
      )

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          settle_ok(repo, run, at(8, 5), [refused("tide_lookup")])
        end)

      assert {:ok, {%{tool_tally: nil}, _job, %{heal: :none}}} = result
      assert log =~ run.id

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{status: "ok", tool_tally: nil}} = Repo.get_job_run(run.id, server: repo)
        assert {:ok, [_ | _]} = Repo.list_job_runs(%{job_id: job.id}, server: repo)
      end)

      assert open_heals(repo) == []
      assert Process.whereis(repo) == before
    end

    test "a heal's stored tool this engine cannot read reads as none", %{
      repo: repo,
      db_path: db_path
    } do
      job = create_job!(repo)
      before = Process.whereis(repo)
      seed_closed_heal(db_path, "jhl_unreadable_tool", "job", job.id, "healed", at(5))

      raw(db_path, """
      UPDATE job_heals SET state = 'waiting', outcome = NULL, closed_at = NULL,
        tool_json = '{"name": 7}' WHERE id = 'jhl_unreadable_tool';
      """)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{tool: nil}} =
                 Repo.job_heals_call({:get, "jhl_unreadable_tool"}, server: repo)

        assert {:ok, [%{tool: nil}]} = Repo.job_heals_call(:open_heals, server: repo)
      end)

      assert Process.whereis(repo) == before
    end
  end

  describe "closing" do
    test "a run that trips does not close its job's heal, still closes its provider's, and a later clean run closes the job's",
         %{repo: repo} do
      job = create_job!(repo)
      provider_job = create_job!(repo)

      assert {:ok, {_r, _j, %{heal: {:opened, provider_heal}}}} =
               fail(repo, claim!(repo, provider_job, at(5)), at(5, 5), nil,
                 kind: "provider_quota",
                 provider: "openai"
               )

      assert %{heal: :none} = ok_run!(repo, job, at(6), [refused("whoami", 1, nil, "harbour_id")])

      assert {:ok, {_r, _j, %{heal: {:opened, job_heal}}}} =
               fail(repo, claim!(repo, job, at(7)), at(7, 9), [
                 refused("whoami", 1, nil, "harbour_id")
               ])

      # A plugin's tool: the trip opens the plugin's heal and leaves the job's
      # own open, and the model worked, so the provider's heal closes.
      assert %{heal: {:opened, plugin_heal}, healed: [^provider_heal]} =
               ok_run!(repo, job, at(8), [refused("whoami", 1, nil, "harbour_id")],
                 provider: "openai"
               )

      assert {:ok, %{state: "open"}} = Repo.job_heals_call({:get, job_heal}, server: repo)
      assert {:ok, %{state: "closed"}} = Repo.job_heals_call({:get, provider_heal}, server: repo)

      assert %{heal: :none, healed: healed} =
               ok_run!(repo, job, at(9), [tool("whoami", 1, 0, plugin: "harbour_id")])

      assert Enum.sort(healed) == Enum.sort([job_heal, plugin_heal])

      for id <- [job_heal, plugin_heal] do
        assert {:ok, %{state: "closed", outcome: "healed"}} =
                 Repo.job_heals_call({:get, id}, server: repo)
      end
    end

    test "a watching heal whose next run trips gets its one verdict", %{repo: repo} do
      job = create_job!(repo)
      assert %{heal: :none} = ok_run!(repo, job, at(6), [refused("tide_lookup")])

      {:ok, {_r, _j, %{heal: {:opened, heal_id}}}} =
        fail(repo, claim!(repo, job, at(7)), at(7, 9), [refused("tide_lookup")])

      :ok = watch!(repo, heal_id, at(7, 30))

      {run, settlement} = ok_run(repo, job, at(8), [refused("tide_lookup", 2, "station offline")])
      assert %{heal: {:verdict, ^heal_id}, healed: [], failure_kind: @kind} = settlement

      assert {:ok, heal} = Repo.job_heals_call({:get, heal_id}, server: repo)

      assert %{
               state: "open",
               conclusion: "verdict",
               failure_kind: @kind,
               failure_words: "station offline",
               run_count: 2,
               tool: %{"name" => "tide_lookup", "failed_calls" => [2, 1, 1]}
             } = heal

      assert heal.last_run_id == run.id
    end
  end

  describe "the quiet days" do
    test "hold for the new kind, for a job and for a plugin", %{repo: repo, db_path: db_path} do
      job = create_job!(repo)
      seed_closed_heal(db_path, "jhl_quiet_job", "job", job.id, "still_failing", at(5))

      seed_closed_heal(
        db_path,
        "jhl_quiet_plugin",
        "plugin",
        "harbour_id",
        "skipped",
        at(5)
      )

      for hour <- [6, 7] do
        assert %{heal: :none} = ok_run!(repo, job, at(hour), [refused("tide_lookup")])
      end

      assert %{heal: :quiet} = ok_run!(repo, job, at(8), [refused("tide_lookup")])

      plugin_job = create_job!(repo)

      for hour <- [6, 7] do
        assert %{heal: :none} =
                 ok_run!(repo, plugin_job, at(hour), [refused("whoami", 1, nil, "harbour_id")])
      end

      assert %{heal: :quiet} =
               ok_run!(repo, plugin_job, at(8), [refused("whoami", 1, nil, "harbour_id")])

      assert open_heals(repo) == []
    end
  end

  # The heal is the settle's last write: a heal that cannot be written takes
  # the run's final row and the job's release back with it.
  test "the settle and its heal roll back together", %{repo: repo, db_path: db_path} do
    job = create_job!(repo)

    for hour <- [6, 7] do
      assert %{heal: :none} = ok_run!(repo, job, at(hour), [refused("tide_lookup")])
    end

    run = claim!(repo, job, at(8))
    seed_closed_heal(db_path, "jhl_seeded", "job", "job_other", "healed", at(5))

    raw(db_path, """
    INSERT INTO job_heal_runs (run_id, heal_id, job_id) VALUES ('#{run.id}', 'jhl_seeded', 'job_other');
    """)

    assert {:error, _reason} = settle_ok(repo, run, at(8, 5), [refused("tide_lookup")])
    assert {:ok, %{status: "queued", tool_tally: nil}} = Repo.get_job_run(run.id, server: repo)
    assert {:ok, %{state: "running"}} = Repo.get_scheduled_job(job.id, server: repo)
    assert open_heals(repo) == []
  end

  # --- helpers ---------------------------------------------------------------------

  defp at(hour, minute \\ 0), do: %{@created | hour: hour, minute: minute}

  defp tool(name, ok, error, extra \\ []) do
    entry = %{"name" => name, "ok" => ok, "error" => error, "unfinished" => 0}

    case Keyword.get(extra, :plugin) do
      nil -> entry
      plugin -> Map.put(entry, "plugin", plugin)
    end
  end

  defp refused(name, error \\ 1, last_error \\ nil, plugin \\ nil) do
    entry = tool(name, 0, error, plugin: plugin)
    if last_error, do: Map.put(entry, "last_error", last_error), else: entry
  end

  defp create_job!(repo, attrs \\ []) do
    {:ok, job} =
      Registry.create_job(
        Map.merge(
          %{
            name: "Harbour tide table #{System.unique_integer([:positive])}",
            schedule: "every 1 hour",
            timezone: "UTC",
            task_prompt: "Fetch this morning's tides.",
            created_by_trust: "operator"
          },
          Map.new(attrs)
        ),
        repo: repo,
        now: @created,
        scheduler: nil
      )

    job
  end

  defp claim!(repo, job, now) do
    patch = %{state: "running", next_run_at: DateTime.add(now, 3_600, :second), updated_at: now}

    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{System.unique_integer([:positive])}",
      trigger: "manual",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }

    {:ok, {_job, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: repo)
    run
  end

  defp ok_run!(repo, job, claimed_at, tally, opts \\ []) do
    {_run, settlement} = ok_run(repo, job, claimed_at, tally, opts)
    settlement
  end

  defp ok_run(repo, job, claimed_at, tally, opts \\ []) do
    run = claim!(repo, job, claimed_at)
    done = DateTime.add(claimed_at, 300, :second)
    {:ok, {settled, _job, settlement}} = settle_ok(repo, run, done, tally, opts)
    {settled, settlement}
  end

  defp settle_ok(repo, run, done, tally, opts \\ []) do
    attrs =
      Map.merge(run, %{
        status: "ok",
        completed_at: done,
        updated_at: done,
        final_response: "High water at 06:12.",
        tool_tally: tally,
        heal_facts: %{provider: Keyword.get(opts, :provider, "anthropic")}
      })

    Repo.settle_job_run(attrs, :ok, server: repo)
  end

  defp fail(repo, run, done, tally, opts \\ []) do
    attrs =
      Map.merge(run, %{
        status: "error",
        completed_at: done,
        updated_at: done,
        error: "the run failed",
        failure_kind: Keyword.get(opts, :kind, "time_limit"),
        tool_tally: tally,
        heal_facts: %{failure_text: "The run failed.", provider: Keyword.get(opts, :provider)}
      })

    Repo.settle_job_run(attrs, {:failed, :other}, server: repo)
  end

  # A heal Fermix moved, watching the job's next run: claimed, decided rerun,
  # delivered.
  defp watch!(repo, heal_id, now) do
    {:ok, %{id: ^heal_id, lease_token: token}} =
      Repo.job_heals_call({:claim, now, DateTime.add(now, @lease_s, :second)}, server: repo)

    plan = %{decision: "rerun", note: "Run it once more.", read_outside: true, change: nil}
    :ok = Repo.job_heals_call({:decided, heal_id, token, plan, now}, server: repo)
    :ok = Repo.job_heals_call({:delivered, heal_id, token, now}, server: repo)
    {:ok, %{state: "watching"}} = Repo.job_heals_call({:get, heal_id}, server: repo)
    :ok
  end

  defp plugin_heal!(repo, plugin) do
    job = create_job!(repo)

    for hour <- [6, 7] do
      %{heal: :none} = ok_run!(repo, job, at(hour), [refused("whoami", 1, nil, plugin)])
    end

    %{heal: {:opened, heal_id}} = ok_run!(repo, job, at(8), [refused("whoami", 1, nil, plugin)])
    heal_id
  end

  defp open_heals(repo) do
    {:ok, open} = Repo.job_heals_call(:open_heals, server: repo)
    open
  end

  defp heal_runs(repo, heal_id) do
    {:ok, runs} = Repo.job_heals_call({:runs, heal_id}, server: repo)
    runs
  end

  # A cue run as its own settle leaves it, with its tally: no scheduled run's
  # settle ever reads it.
  defp seed_cue_run(db_path, job, at, tally) do
    id = "run_cue_#{System.unique_integer([:positive])}"
    stamp = CuesSql.stamp(at)

    raw(db_path, """
    INSERT INTO job_runs (id, job_id, session_id, trigger, status, claimed_at, started_at,
      completed_at, delivery_status, created_at, updated_at)
    VALUES ('#{id}', '#{job.id}', 'cue_#{id}', 'cue', 'ok', '#{stamp}', '#{stamp}', '#{stamp}',
      'none', '#{stamp}', '#{stamp}');
    INSERT INTO job_run_facts (run_id, tool_timeline_json, tool_tally_json)
    VALUES ('#{id}', '[]', '#{Jason.encode!(tally)}');
    """)
  end

  # A settled run of the job with the tally text given, stored as written.
  defp seed_run(db_path, job, at, tally_json) do
    id = "run_seeded_#{System.unique_integer([:positive])}"
    stamp = CuesSql.stamp(at)

    raw(db_path, """
    INSERT INTO job_runs (id, job_id, session_id, trigger, status, claimed_at, started_at,
      completed_at, delivery_status, created_at, updated_at)
    VALUES ('#{id}', '#{job.id}', 'cron_#{id}', 'schedule', 'ok', '#{stamp}', '#{stamp}',
      '#{stamp}', 'none', '#{stamp}', '#{stamp}');
    INSERT INTO job_run_facts (run_id, tool_tally_json) VALUES ('#{id}', '#{tally_json}');
    """)

    id
  end

  # A run settled before tallies were kept: a row and no facts.
  defp seed_untallied_run(db_path, job, at) do
    id = "run_old_#{System.unique_integer([:positive])}"
    stamp = CuesSql.stamp(at)

    raw(db_path, """
    INSERT INTO job_runs (id, job_id, session_id, trigger, status, claimed_at, started_at,
      completed_at, delivery_status, created_at, updated_at)
    VALUES ('#{id}', '#{job.id}', 'cron_#{id}', 'schedule', 'ok', '#{stamp}', '#{stamp}',
      '#{stamp}', 'none', '#{stamp}', '#{stamp}');
    """)
  end

  defp seed_closed_heal(db_path, id, subject_kind, subject_id, outcome, closed_at) do
    job_id = if subject_kind == "job", do: "'#{subject_id}'", else: "NULL"
    stamp = CuesSql.stamp(closed_at)

    raw(db_path, """
    PRAGMA foreign_keys = OFF;
    INSERT INTO job_heals (id, subject_kind, subject_id, job_id, failure_kind, failure_text,
      state, outcome, run_count, opened_at, updated_at, closed_at, delivery_status)
    VALUES ('#{id}', '#{subject_kind}', '#{subject_id}', #{job_id}, '#{@kind}', 'A tool failed.',
      'closed', '#{outcome}', 1, '#{stamp}', '#{stamp}', '#{stamp}', 'delivered');
    """)
  end

  defp raw(db_path, sql) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end
end
