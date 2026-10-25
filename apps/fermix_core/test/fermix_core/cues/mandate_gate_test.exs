defmodule FermixCore.Cues.MandateGateTest do
  @moduledoc """
  M60 §10.3–§10.5 at the one invoke boundary (`Capability.execute/3`): a cue
  run's mandate calls are recorded before any check, checked in the design's
  order, and run, proposed or refused; every other run is untouched.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import FermixTestSupport.CueFixtures, only: [exec!: 3, rows: 3]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.MandateFixtures, as: F
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @name "release-issues"
  @args %{"owner" => "example-org", "repo" => "ops", "title" => "Phoenix 2.0"}

  # --- helpers -------------------------------------------------------------------------

  defp run!(tag, section \\ %{}, top \\ %{}, attrs \\ %{}) do
    fixture = F.cue_run(tag, attrs)
    config = F.config(@name, fixture.job.id, section, top)
    context = F.context(fixture, @name, config: config)
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: fixture.run.session_id)
    {fixture, context}
  end

  defp approve!(context) do
    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(context))
    :ok
  end

  defp seams(context), do: context.cue_mandate_opts

  defp with_seams(context, extra),
    do: %{context | cue_mandate_opts: Keyword.merge(context.cue_mandate_opts, extra)}

  defp call(context, args \\ @args, capability \\ F.capability()),
    do: Capability.execute(capability, args, context)

  # A call to the mandate's stand-in reader.
  defp read(context), do: call(context, %{"query" => "x"}, F.capability(F.reader()))

  # The stand-in tool with `arg` added to its manifest's required arguments.
  defp requiring(arg) do
    %Capability{executor: {mod, fun, [plugin, tool]}} = capability = F.capability()
    tool = update_in(tool, ["parameters", "required"], &[arg | &1])
    %{capability | executor: {mod, fun, [plugin, tool]}, parameters: tool["parameters"]}
  end

  # Exactly one exec event per model tool call: returns it.
  defp one_exec! do
    assert_received {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
    refute_received {:telemetry, [:fermix, :tool, :exec], _, _}
    metadata
  end

  # The executor ran once, with its own one exec event.
  defp allowed!(result) do
    assert {:ok, %{success: true}} = result
    assert_received {:executed, _tool, args, context}
    {args, context, one_exec!()}
  end

  defp refused!(result, label) do
    assert {:ok, %{success: false, error: error}} = result
    refute_received {:executed, _tool, _args, _context}
    metadata = one_exec!()
    assert metadata.access_gate == label

    assert metadata.policy_enforcement == %{
             source: "access_gate",
             decision: "deny",
             phase: "pre_execution"
           }

    {error, metadata}
  end

  defp validator_script!(body) do
    dir = SafeRm.make_tmp_dir!("mandate-validator")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    path = Path.join(dir, "validate.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    {dir, path}
  end

  # --- every other run ---------------------------------------------------------------------

  describe "outside a cue run (C46)" do
    test "the owner's chat, another job and the job's own scheduled run call the tool as before",
         _ctx do
      {fixture, context} = run!("gate_c46")
      approve!(context)

      chat = %{
        session_id: fixture.run.session_id,
        source_trust: :operator,
        computer_use_origin: :interactive,
        chat_type: "private",
        outside_sources: MapSet.new()
      }

      scheduled = Map.merge(context, %{trigger: "schedule"})
      other_job = Map.merge(context, %{trigger: "manual", job_id: "another_job"})

      for run_context <- [chat, scheduled, other_job] do
        assert {:ok, %{success: true}} = call(run_context, Map.put(@args, "extra", "kept"))
        assert_received {:executed, "github_create_issue", args, executed_context}
        # Nothing normalised, nothing labelled: the tool behaves as it always did.
        assert args["extra"] == "kept"
        refute Map.has_key?(executed_context, :mandate_call_id)
        refute one_exec!()[:access_gate] == "mandate_allowed"
      end

      assert F.call_rows(fixture.conn, fixture.run.id) == []
      assert F.tools_started_at(fixture.conn, fixture.run.id) == nil
    end
  end

  # --- allowed calls -------------------------------------------------------------------------

  describe "an allowed call in auto mode" do
    test "runs on the arguments the tool sends, is recorded and marks the run (C45, C39)" do
      {fixture, context} = run!("gate_allow")
      approve!(context)

      args = Map.merge(@args, %{"extra" => "dropped"})
      assert {:ok, %{success: true, output: ~s({"number":42})}} = call(context, args)

      assert_received {:executed, "github_create_issue", sent, executed}
      assert sent == Map.put(@args, "labels", ["cue"])
      assert executed.access_gate == "mandate_allowed"
      assert executed.validator == "none"
      assert executed.mandate_args_normalized? == true

      metadata = one_exec!()
      assert metadata.access_gate == "mandate_allowed"
      assert metadata.validator == "none"
      assert metadata.success == true

      assert [row] = F.call_rows(fixture.conn, fixture.run.id)
      assert row.id == executed.mandate_call_id
      assert row.args == sent
      assert %{decision: "allow", validator: "none", result_status: "ok"} = row
      assert row.result_summary == ~s({"number":42})
      assert row.finished_at
      assert String.match?(row.key, ~r/^[0-9a-f]{32}$/)
      assert F.tools_started_at(fixture.conn, fixture.run.id)
    end

    test "a JSON-string field is decoded before the call is checked and run (C39)" do
      {_fixture, context} = run!("gate_json")
      approve!(context)

      assert {:ok, %{success: true}} = call(context, Map.put(@args, "labels", ~s(["release"])))
      assert_received {:executed, _tool, %{"labels" => ["release"]}, _context}
    end

    test "idempotency_arg is Fermix's: set from the call and the cue, hidden from the model (C39)" do
      {fixture, context} = run!("gate_idem", %{"idempotency_arg" => "client_id"})
      approve!(context)

      assert {:ok, %{success: true}} = call(context, Map.put(@args, "client_id", "model-chosen"))
      assert_received {:executed, _tool, %{"client_id" => first}, _context}
      assert {:ok, %{success: true}} = call(context, @args)
      assert_received {:executed, _tool, %{"client_id" => second}, _context}

      [row | _rest] = F.call_rows(fixture.conn, fixture.run.id)
      assert first == "fx-#{@name}-#{row.key}"
      assert second == first

      hidden = Mandates.hide_set_arguments(F.capability(), context)
      refute Map.has_key?(hidden.parameters["properties"], "client_id")

      chat = %{trigger: "schedule", cue_mandate: @name}
      shown = Mandates.hide_set_arguments(F.capability(), chat)
      assert Map.has_key?(shown.parameters["properties"], "client_id")
    end

    # The model never sees the argument, so a manifest that requires it must
    # still accept the model's call: Fermix supplies it before the tool's own
    # check of the arguments.
    test "a required idempotency_arg is supplied by Fermix, so the model's call runs (C39)" do
      {fixture, context} = run!("gate_idem_required", %{"idempotency_arg" => "client_id"})
      approve!(context)

      assert {:ok, %{success: true}} = call(context, @args, requiring("client_id"))
      assert_received {:executed, _tool, %{"client_id" => client_id}, _context}

      [row] = F.call_rows(fixture.conn, fixture.run.id)
      assert client_id == "fx-#{@name}-#{row.key}"
    end
  end

  # --- the validator ----------------------------------------------------------------------------

  describe "a mandate with a validator (C11)" do
    test "only the validator allows: it sees the call as the tool sends it" do
      {dir, script} =
        validator_script!("""
        read line
        echo "$line" > "$(dirname "$0")/request.json"
        echo "checking" 1>&2
        case "$line" in
          *'"repo":"ops"'*) echo '{"allow": true}' ;;
          *) echo '{"allow": false, "reason": "only the ops repo"}' ;;
        esac
        """)

      {fixture, context} = run!("gate_validator", %{"validator" => script})
      approve!(context)

      assert {:ok, %{success: true}} = call(context)
      assert_received {:executed, _tool, _args, %{validator: "program"}}
      assert one_exec!().validator == "program"

      request = dir |> Path.join("request.json") |> File.read!() |> Jason.decode!()
      assert request["mandate"] == @name
      assert request["tool"] == "github_create_issue"
      assert request["args"] == Map.put(@args, "labels", ["cue"])
      assert request["job"] == fixture.job.id
      assert request["run_id"] == fixture.run.id
      assert request["calls_this_run"] == 0
      assert request["cue"]["source"] == F.source()
      assert request["cue"]["item_id"] == "item-1"
      refute Map.has_key?(request, "cues")

      {error, metadata} = refused!(call(context, %{@args | "repo" => "web"}), "mandate_refused")
      assert error =~ "only the ops repo"
      # The validator's words may echo arguments written from outside text.
      assert error =~
               ~r/<untrusted_tool_result source="validator:release-issues">.*only the ops repo/s

      assert metadata.validator == "program"
      assert metadata.mandate_reason == "validator refused"

      assert [allowed, refused] = F.call_rows(fixture.conn, fixture.run.id)
      assert %{decision: "allow", validator: "program"} = allowed
      assert %{decision: "refuse", validator: "program", reason: "only the ops repo"} = refused
      assert refused.finished_at
    end

    test "a validator that times out or answers nonsense refuses the call" do
      {_dir, script} = validator_script!("echo 'not json'\n")
      {_fixture, context} = run!("gate_validator_bad", %{"validator" => script})
      approve!(context)

      {error, _metadata} = refused!(call(context), "mandate_refused")
      assert error =~ "the validator's answer was not understood"

      timeout = fn _exe, _args, _opts -> {:error, {:timeout, 5_000}} end

      {error, _metadata} =
        refused!(call(with_seams(context, command_runner: timeout)), "mandate_refused")

      assert error =~ "did not answer within 5 seconds"
    end
  end

  # --- refusals ---------------------------------------------------------------------------------

  describe "freshness (C34, C44)" do
    test "a cue older than max_cue_age is refused before the validator, with or without one" do
      test_pid = self()

      runner = fn _exe, _args, _opts ->
        send(test_pid, :validator_ran)
        {:ok, %{exit: 0, stdout: ~s({"allow": true}\n), truncated?: false}}
      end

      {_dir, script} = validator_script!("echo '{\"allow\": true}'\n")
      old = DateTime.add(F.now(), -20 * 60, :second)

      for section <- [%{}, %{"validator" => script}] do
        {fixture, context} = run!("gate_stale", section, %{}, %{received_at: old})
        context = with_seams(context, command_runner: runner)
        approve!(context)

        {error, _metadata} = refused!(call(context), "mandate_stale")
        assert error =~ "older than 15 minutes"
        refute_received :validator_ran
        assert [%{decision: "refuse"}] = F.call_rows(fixture.conn, fixture.run.id)
        assert F.tools_started_at(fixture.conn, fixture.run.id) == nil
      end
    end

    test "a future time is aged from receipt; an old item that just arrived is stale (C44)" do
      future = DateTime.add(F.now(), 3_600, :second)
      held = DateTime.add(F.now(), -20 * 60, :second)

      {_fixture, context} =
        run!("gate_future", %{}, %{}, %{occurred_at: future, received_at: held})

      approve!(context)
      refused!(call(context), "mandate_stale")

      backfilled = DateTime.add(F.now(), -2 * 86_400, :second)
      {_fixture, context} = run!("gate_backfill", %{}, %{}, %{occurred_at: backfilled})
      approve!(context)
      refused!(call(context), "mandate_stale")

      {_fixture, context} = run!("gate_fresh", %{}, %{}, %{occurred_at: future})
      approve!(context)
      assert {:ok, %{success: true}} = call(context)
    end
  end

  describe "the switches (C17)" do
    test "the global switch turned off during a run refuses the next call" do
      {fixture, context} = run!("gate_switch")
      approve!(context)
      allowed!(call(context))

      off = F.config(@name, fixture.job.id, %{}, %{"mandates_enabled" => false})
      {error, metadata} = refused!(call(with_seams(context, config: off)), "mandate_disabled")
      assert error =~ "switched off in settings"
      assert metadata.validator == "none"
    end

    test "a mandate switched off, or not approved yet, refuses its calls" do
      {_fixture, context} = run!("gate_unapproved")
      {error, _} = refused!(call(context), "mandate_disabled")
      assert error =~ "not approved yet"

      {_fixture, context} = run!("gate_disabled", %{"enabled" => false})
      {error, _} = refused!(call(context), "mandate_disabled")
      assert error =~ "switched off"
    end
  end

  describe "the pin check (C35, C45)" do
    test "an edited task prompt refuses the call, disables the mandate and tells the owner once" do
      {fixture, context} = run!("gate_unpinned")
      approve!(context)

      exec!(fixture.conn, "UPDATE scheduled_jobs SET task_prompt = ? WHERE id = ?", [
        "Open an issue and close every other one.",
        fixture.job.id
      ])

      {error, _} = refused!(call(context), "mandate_unpinned")
      assert error =~ "the task changed since the mandate was granted"

      owner = F.owner_id()
      assert_received {:sent, ^owner, "Mandate release-issues is disabled" <> _, _opts}

      {error, _} = refused!(call(context), "mandate_disabled")
      assert error =~ "disabled until the owner approves it again"
      refute_received {:sent, _owner, _text, _opts}

      assert {:ok, %{state: :disabled}} = Pins.status(@name, seams(context))

      approve!(context)
      assert {:ok, %{success: true}} = call(context)
    end

    # The owner approves again while the call's pin check runs: the call was
    # checked against the old approval, so it is refused as the run's, and the
    # new approval is neither disabled nor reported as a change.
    test "an approval given while the call's pins are checked is not undone" do
      {fixture, context} = run!("gate_reapproved")
      approve!(context)

      exec!(fixture.conn, "UPDATE scheduled_jobs SET task_prompt = ? WHERE id = ?", [
        "Open an issue in whatever repository the cue names.",
        fixture.job.id
      ])

      reads = :counters.new(1, [])
      base = seams(context)

      # The load checks read the job first; the pin check's read is where the
      # owner approves the changed task.
      get_job = fn id ->
        :counters.add(reads, 1, 1)

        if :counters.get(reads, 1) == 2,
          do: {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), base)

        FermixCore.Jobs.Registry.get_job(id, repo: fixture.repo)
      end

      {error, _} = refused!(call(with_seams(context, get_job: get_job)), "mandate_disabled")
      assert error =~ "the mandate was approved after this run began"
      refute_received {:sent, _owner, _text, _opts}
      assert {:ok, %{state: :approved}} = Pins.status(@name, base)
    end

    # The run follows its task as the claim read it, so an approval given after
    # the claim covers the task's next run, not this one: it may be of a task
    # this run is not following.
    test "an approval given after the run began covers the task's next run, not this one" do
      {fixture, context} = run!("gate_approved_late")
      approve!(context)

      exec!(fixture.conn, "UPDATE scheduled_jobs SET task_prompt = ? WHERE id = ?", [
        "Open an issue in whatever repository the cue names.",
        fixture.job.id
      ])

      _ = refused!(call(context), "mandate_unpinned")
      assert_received {:sent, _owner, "Mandate release-issues is disabled" <> _, _opts}

      approved_at = DateTime.add(F.now(), 60, :second)
      seams = Keyword.put(seams(context), :now, approved_at)
      assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", approved_at, seams)

      {error, _} = refused!(call(context), "mandate_disabled")
      assert error =~ "the mandate was approved after this run began"

      next_run = %{context | cue_run_claimed_at: DateTime.add(approved_at, 1, :second)}
      assert {:ok, %{success: true}} = call(next_run)
    end

    test "an edited skill file refuses the call; an unpinned one does not" do
      skill = SafeRm.make_tmp_dir!("mandate-skill")
      on_exit(fn -> SafeRm.rm_rf!(skill) end)
      File.write!(Path.join(skill, "SKILL.md"), "Open issues for releases.")
      File.mkdir_p!(Path.join(skill, "logs"))
      File.write!(Path.join(skill, "logs/run.log"), "first")

      {fixture, context} = run!("gate_skill", %{"unpinned" => ["logs/"]})

      exec!(fixture.conn, "UPDATE scheduled_jobs SET skill_name = 'releases' WHERE id = ?", [
        fixture.job.id
      ])

      context = with_seams(context, skill_dir: fn "releases" -> {:ok, skill} end)
      approve!(context)

      File.write!(Path.join(skill, "logs/run.log"), "second")
      allowed!(call(context))

      File.write!(Path.join(skill, "SKILL.md"), "Open issues for everything.")
      refused!(call(context), "mandate_unpinned")
    end

    test "a job row that cannot be read refuses that one call; nothing is disabled or told" do
      {_fixture, context} = run!("gate_unverified")
      approve!(context)
      allowed!(call(context))

      busy = with_seams(context, get_job: fn _id -> {:error, :timeout} end)
      {error, metadata} = refused!(call(busy, %{@args | "title" => "second"}), "mandate_refused")

      assert error ==
               "github_create_issue was not run: Fermix could not verify the mandate's pins; " <>
                 "try again. Fermix lists this refusal in its report to the owner."

      assert metadata.mandate_reason == "Fermix could not verify the mandate's pins; try again"
      refute_received {:sent, _owner, _text, _opts}
      assert {:ok, %{state: :approved}} = Pins.status(@name, seams(context))
      allowed!(call(context, %{@args | "title" => "third"}))
    end
  end

  describe "what a mandate call reads at each call" do
    test "the load checks run once a run; the switch and the pin stay live" do
      {_dir, script} = validator_script!("cat > /dev/null; echo '{\"allow\": true}'\n")
      {fixture, context} = run!("gate_snapshot", %{"validator" => script})
      approve!(context)

      stats = :counters.new(1, [])

      stat = fn _path ->
        :counters.add(stats, 1, 1)
        {:ok, %{uid: 0, mode: 0o100755, type: :regular}}
      end

      context = with_seams(context, stat: stat)
      allowed!(call(context))
      first = :counters.get(stats, 1)
      assert first > 0

      allowed!(call(context, %{@args | "title" => "second"}))
      assert :counters.get(stats, 1) == first

      off = F.config(@name, fixture.job.id, %{"validator" => script, "enabled" => false})
      {error, _} = refused!(call(with_seams(context, config: off)), "mandate_disabled")
      assert error =~ "switched off"

      exec!(fixture.conn, "UPDATE scheduled_jobs SET task_prompt = ? WHERE id = ?", [
        "Open an issue for every post.",
        fixture.job.id
      ])

      refused!(call(context, %{@args | "title" => "third"}), "mandate_unpinned")
      assert :counters.get(stats, 1) == first
    end

    test "a mandate removed during its run: a call to its tool is recorded and refused" do
      {fixture, context} = run!("gate_removed")
      approve!(context)
      gone = with_seams(context, config: Config.normalize(%{}))

      {error, metadata} = refused!(call(gone), "mandate_disabled")
      assert error =~ "the mandate no longer exists"
      assert metadata.mandate_call_id

      assert [%{decision: "refuse", reason: "the mandate no longer exists"} = row] =
               F.call_rows(fixture.conn, fixture.run.id)

      assert row.id == metadata.mandate_call_id
      assert row.finished_at
    end
  end

  describe "the loop breaker and pinned arguments" do
    test "the eleventh allowed call of a task within an hour is refused" do
      {fixture, context} = run!("gate_loop")
      approve!(context)

      for n <- 1..10 do
        allowed!(call(context, %{@args | "title" => "issue #{n}"}))
      end

      {error, _} = refused!(call(context, %{@args | "title" => "issue 11"}), "mandate_refused")
      assert error =~ "This task reached its hourly action limit."
      assert length(F.call_rows(fixture.conn, fixture.run.id)) == 11
    end

    test "a pinned argument that differs is refused" do
      {_fixture, context} = run!("gate_pins")
      approve!(context)

      {error, _} = refused!(call(context, %{@args | "owner" => "other-org"}), "mandate_refused")
      assert error =~ ~s(the argument owner must be "example-org")
    end
  end

  # --- the run's tool set ---------------------------------------------------------------------

  describe "the run's tool set" do
    test "a tool outside it is refused; a flagged one is the cue run's refusal; a reader runs" do
      {fixture, context} = run!("gate_surface")
      approve!(context)

      {error, _} =
        refused!(call(context, %{}, F.capability("slack_post_message")), "refused_cue_surface")

      assert error =~ "not one of this cue run's tools"

      flagged = F.capability("tesla_unlock_doors", flagged: true)
      refused!(call(context, %{}, flagged), "refused_cue_run")

      assert {:ok, %{success: true}} = call(context, %{"query" => "x"}, F.capability(F.reader()))
      assert_received {:executed, "github_search_issues", %{"query" => "x"}, _context}
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    # The load check reads the manifest once per run; the capability the call
    # reaches is what runs. One that is not marked read-only now (a plugin
    # update, a stale registration) gets none of a reader's free pass, and it
    # was offered, so the refusal says what changed.
    test "a read_tools entry whose capability is not marked read-only is refused" do
      {fixture, context} = run!("gate_reader_writes")
      approve!(context)
      writer = F.capability(F.reader(), read_only: false)

      {result, log} = with_log(fn -> call(context, %{"query" => "x"}, writer) end)
      {error, metadata} = refused!(result, "refused_reader_writes")
      assert metadata.validator == "none"
      assert metadata.mandate_reason =~ "not marked read-only now"

      assert error =~
               "github_search_issues was not run: it is one of the mandate's read tools, but " <>
                 "it is not marked read-only now"

      refute error =~ "not one of this cue run's tools"
      assert log =~ "Mandate release-issues: read tool github_search_issues"
      assert log =~ ~s(of plugin "github")
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    # A reader runs with none of a mandate call's other checks and is not
    # recorded, so the mandate's switches and approval are what keep the
    # owner's data from reaching the model unasked.
    test "a reader of a mandate switched off is refused" do
      {fixture, context} = run!("gate_reader_off", %{"enabled" => false})
      approve!(context)

      {error, metadata} = refused!(read(context), "mandate_disabled")
      assert error =~ "github_search_issues was not run: the mandate is switched off"
      assert metadata.validator == "none"
      assert metadata.mandate_reason == "the mandate is switched off (enabled = false)"
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    test "a reader is refused while mandates are switched off in settings" do
      {fixture, context} = run!("gate_reader_global", %{}, %{"mandates_enabled" => false})
      approve!(context)

      {error, _} = refused!(read(context), "mandate_disabled")
      assert error =~ "switched off in settings"
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    test "a reader of a mandate not approved, or disabled since, is refused" do
      {fixture, context} = run!("gate_reader_unapproved")

      {error, _} = refused!(read(context), "mandate_disabled")
      assert error =~ "not approved yet"

      approve!(context)
      assert {:ok, _state} = Pins.disable(@name, "test", F.now(), seams(context))
      {error, _} = refused!(read(context), "mandate_disabled")
      assert error =~ "disabled until the owner approves it again"
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    # As for a mandate call: the run follows its task as the claim read it, so
    # an approval given since covers the next run, not this one.
    test "a reader of a mandate approved after the run began is refused" do
      {_fixture, context} = run!("gate_reader_late")
      approved_at = DateTime.add(F.now(), 60, :second)
      seams = Keyword.put(seams(context), :now, approved_at)
      assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", approved_at, seams)

      {error, _} = refused!(read(context), "mandate_disabled")
      assert error =~ "the mandate was approved after this run began"

      next_run = %{context | cue_run_claimed_at: DateTime.add(approved_at, 1, :second)}
      assert {:ok, %{success: true}} = read(next_run)
    end

    # `read_tools` and the task are pinned, and a run that only reads never
    # reaches a mandate call's pin check, so a reader takes it: a change
    # disables the mandate and tells the owner once, as a mandate call does.
    test "a reader is refused once the task changed since the approval" do
      {fixture, context} = run!("gate_reader_task")
      approve!(context)

      exec!(fixture.conn, "UPDATE scheduled_jobs SET task_prompt = ? WHERE id = ?", [
        "Search every repository the cue names.",
        fixture.job.id
      ])

      {error, _} = refused!(read(context), "mandate_unpinned")
      assert error =~ "the task changed since the mandate was granted"
      owner = F.owner_id()
      assert_received {:sent, ^owner, "Mandate release-issues is disabled" <> _, _opts}

      {error, _} = refused!(read(context), "mandate_disabled")
      assert error =~ "disabled until the owner approves it again"
      refute_received {:sent, _owner, _text, _opts}
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    test "a reader added to the section since the approval is refused" do
      {fixture, context} = run!("gate_reader_added")

      approve!(
        with_seams(context, config: F.config(@name, fixture.job.id, %{"read_tools" => []}))
      )

      {error, _} = refused!(read(context), "mandate_unpinned")
      assert error =~ "the task changed since the mandate was granted"
      assert {:ok, %{state: :disabled}} = Pins.status(@name, seams(context))
    end

    # Readers take the run's load-check verdict, as mandate calls do.
    test "a reader of a mandate that fails its load checks is refused" do
      {fixture, context} = run!("gate_reader_inactive")
      approve!(context)

      exec!(fixture.conn, "UPDATE scheduled_jobs SET schedule_kind = 'interval' WHERE id = ?", [
        fixture.job.id
      ])

      {error, _} = refused!(read(context), "mandate_disabled")
      assert error =~ "the mandate is inactive"
      assert error =~ "runs on a schedule"
    end

    test "an approved, enabled mandate's reader runs, with no call row" do
      {fixture, context} = run!("gate_reader_on")
      approve!(context)

      assert {:ok, %{success: true}} = read(context)
      assert_received {:executed, "github_search_issues", %{"query" => "x"}, _context}
      assert F.call_rows(fixture.conn, fixture.run.id) == []
    end

    test "a mandated run's file tools read only inside the job's skill folder (design §10.4)" do
      skill = SafeRm.make_tmp_dir!("mandate-files")
      on_exit(fn -> SafeRm.rm_rf!(skill) end)
      File.write!(Path.join(skill, "cue_runs.md"), "Read me.")

      {_fixture, context} = run!("gate_files")
      file_read = file_read_capability()

      {error, _} =
        refused!(
          Capability.execute(file_read, %{"path" => "x"}, context),
          "refused_mandate_files"
        )

      assert error =~ "names no skill"

      context =
        context
        |> Map.put(:skill_name, "releases")
        |> with_seams(skill_dir: fn "releases" -> {:ok, skill} end)

      assert {:ok, %{success: true}} = Capability.execute(file_read, %{"path" => "x"}, context)
      assert_received {:file_read, %{sandbox_config: config} = read_context}
      assert config.mode == :strict
      assert config.workspace_root == skill
      assert config.allowed_roots == []

      inside = Path.join(skill, "cue_runs.md")
      assert {:ok, _path} = FermixCore.Sandbox.read_path(inside, :file_read, read_context)

      assert {:error, _reason} =
               FermixCore.Sandbox.read_path("/etc/hosts", :file_read, read_context)
    end

    # git finds the repository above the folder it is started in, so a path
    # check on the folder cannot hold it there: `git show HEAD:<path>` from a
    # skill folder inside a checkout reads the whole checkout.
    test "a mandated run's git_read is refused, even with a skill folder (design §10.4)" do
      skill = SafeRm.make_tmp_dir!("mandate-git")
      on_exit(fn -> SafeRm.rm_rf!(skill) end)

      {_fixture, context} = run!("gate_git")

      context =
        context
        |> Map.put(:skill_name, "releases")
        |> with_seams(skill_dir: fn "releases" -> {:ok, skill} end)

      git_read = file_read_capability("git_read")

      {error, _} =
        refused!(
          Capability.execute(git_read, %{"command" => "show", "repo" => skill}, context),
          "refused_mandate_files"
        )

      assert error =~ "git_read was not run"
      assert error =~ "repository around"
      refute_received {:file_read, _context}
    end
  end

  # --- the marker with the settle ----------------------------------------------------------------

  describe "the marker (C12, with the cue settle)" do
    test "a run that fails after an allowed call is exhausted; one with only refusals is retried" do
      {fixture, context} = run!("gate_marker_allow")
      approve!(context)
      allowed!(call(context))

      {:ok, {_run, _job, settlement}} =
        Repo.settle_cue_run(failed(fixture.run), {:failed, :other}, server: fixture.repo)

      assert settlement.disposition == :exhausted
      assert settlement.outcome == "failed_after_action"

      {fixture, context} = run!("gate_marker_refused")
      refused!(call(context), "mandate_disabled")

      {:ok, {_run, _job, settlement}} =
        Repo.settle_cue_run(failed(fixture.run), {:failed, :other}, server: fixture.repo)

      assert settlement.disposition == :retry

      assert [[nil]] =
               rows(fixture.conn, "SELECT tools_started_at FROM job_runs WHERE id = ?", [
                 fixture.run.id
               ])
    end
  end

  # --- helpers for the tests above -------------------------------------------------------------

  defp failed(run),
    do: Map.merge(run, %{status: "error", completed_at: F.now(), updated_at: F.now()})

  # A stand-in builtin reader named `name` that reports the context it ran with.
  defp file_read_capability(name \\ "file_read") do
    Capability.new(%{
      name: name,
      description: "Read a file.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :file_read, [self()]},
      metadata: %{category: :file}
    })
  end

  @doc false
  def file_read(_args, context, test_pid) do
    send(test_pid, {:file_read, context})
    {:ok, %{success: true, output: "Read me.", error: nil}}
  end
end
