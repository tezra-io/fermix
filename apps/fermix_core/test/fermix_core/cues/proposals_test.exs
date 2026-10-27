defmodule FermixCore.Cues.ProposalsTest do
  @moduledoc """
  M60 §10.9 with the PLAN §1 fixes: a mandate in approve mode proposes, the
  owner confirms or denies from the DM it was sent to, and a confirmed call runs
  exactly as recorded, at most once (C50, C55, the 3,500-character refusal, a
  proposal that survives a restart, the unknown-outcome report).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import FermixTestSupport.CueFixtures, only: [exec!: 3, rows: 3]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.MandateGate
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Proposals
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.MandateFixtures, as: F
  alias FermixTestSupport.TelemetryCapture

  @name "release-issues"
  @args %{"owner" => "example-org", "repo" => "ops", "title" => "Phoenix 2.0"}

  # --- helpers -------------------------------------------------------------------------

  # A claimed cue run under an approved approve-mode mandate, with the stand-in
  # tool registered where a confirm looks it up.
  defp proposing!(tag, section \\ %{}) do
    fixture = F.cue_run(tag)
    config = F.config(@name, fixture.job.id, Map.merge(%{"mode" => "approve"}, section))
    registry = :"proposal_caps_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({CapabilityRegistry, name: registry}, id: registry))
    :ok = CapabilityRegistry.register(registry, F.capability())

    context = F.context(fixture, @name, config: config, capability_registry: registry)
    session = fixture.run.session_id

    TelemetryCapture.attach([[:fermix, :tool, :exec], [:fermix, :cue, :lifecycle]],
      session_id: session
    )

    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(context))
    {fixture, context}
  end

  defp seams(context), do: context.cue_mandate_opts

  defp later(context, seconds),
    do: Keyword.put(seams(context), :now, DateTime.add(F.now(), seconds, :second))

  defp propose!(context, args \\ @args) do
    assert {:ok, %{success: false, error: text}} =
             Capability.execute(F.capability(), args, context)

    assert text =~ "Proposed to the owner; it runs only if they confirm it."
    assert_received {:proposal, _inbox, message, token}
    refute_received {:executed, _tool, _args, _context}
    {message, token}
  end

  defp owner_origin, do: %{platform: "telegram", chat_id: F.owner_id(), user_id: F.owner_id()}

  defp exec_event! do
    assert_received {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
    metadata
  end

  defp phase!(phase) do
    assert_received {:telemetry, [:fermix, :cue, :lifecycle], _measurements,
                     %{phase: ^phase} = metadata}

    metadata
  end

  # --- proposing -------------------------------------------------------------------------

  describe "proposing" do
    test "an allowed call is stored with the decision, marks the run and goes to the owner's DM" do
      {fixture, context} = proposing!("prop_store")
      {message, token} = propose!(context)

      metadata = exec_event!()
      assert metadata.access_gate == "mandate_proposed"
      assert metadata.policy_enforcement.decision == "confirm"
      assert metadata.validator == "none"
      refute_received {:telemetry, [:fermix, :tool, :exec], _, _}

      proposed = phase!(:proposed)
      assert proposed.session_id == fixture.run.session_id
      assert proposed.mandate == @name
      assert proposed.mandate_call_id == metadata.mandate_call_id

      assert String.starts_with?(token, "cp_")
      assert byte_size(token) == 35
      # The token is in the owner's message, never in the model's result or a row.
      assert message =~ "/confirm #{token}"
      assert message =~ "/deny #{token}"
      assert message =~ "release issues"
      assert message =~ "release-watch"
      assert message =~ "Phoenix 2.0 is out."
      assert message =~ "Saturday, October 10, 2026 at 12:30 PM UTC"

      assert [] =
               rows(fixture.conn, "SELECT 1 FROM cue_proposals WHERE token_digest = ?", [token])

      [[platform, chat, user, state]] =
        rows(
          fixture.conn,
          "SELECT sent_platform, sent_chat_id, sent_user_id, state FROM cue_proposals",
          []
        )

      assert {platform, chat, user, state} == {"telegram", F.owner_id(), F.owner_id(), "waiting"}
      assert [%{decision: "propose", proposal_id: id}] = F.call_rows(fixture.conn, fixture.run.id)
      assert is_binary(id)
      assert F.tools_started_at(fixture.conn, fixture.run.id)
    end

    test "the same call proposed twice is one proposal; the model gets its state (C50)" do
      {fixture, context} = proposing!("prop_twice")
      _ = propose!(context)

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(F.capability(), @args, context)

      assert text =~ "already proposed to the owner and waits for their answer"
      refute_received {:proposal, _inbox, _message, _token}
      assert [{_id, "waiting"}] = F.proposals(fixture.conn)

      assert [%{decision: "propose"}, %{decision: "propose", reason: "already proposed"}] =
               F.call_rows(fixture.conn, fixture.run.id)
    end

    test "a message over 3,500 characters is refused, never cut" do
      {fixture, context} = proposing!("prop_long")
      long = %{@args | "title" => String.duplicate("x", Proposals.max_message_chars())}

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(F.capability(), long, context)

      assert text =~ "This call is too long to show you in full; it was not proposed."
      refute_received {:proposal, _inbox, _message, _token}
      assert F.proposals(fixture.conn) == []
      assert [%{decision: "refuse"}] = F.call_rows(fixture.conn, fixture.run.id)
      assert F.tools_started_at(fixture.conn, fixture.run.id) == nil
    end

    test "a DM that cannot be reached refuses the proposal, and the run's record says so (C50)" do
      {fixture, context} = proposing!("prop_unreachable")
      down = fn _inbox, _text, _token -> {:error, :channel_down} end
      context = %{context | cue_mandate_opts: Keyword.put(seams(context), :proposal_sender, down)}

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(F.capability(), @args, context)

      assert text =~ "could not reach the owner"
      assert [{_id, "refused"}] = F.proposals(fixture.conn)

      assert [%{decision: "propose", result_status: "refused", result_summary: summary}] =
               F.call_rows(fixture.conn, fixture.run.id)

      assert summary =~ "could not reach you"
      assert phase!(:proposal_refused).reason == "unreachable"
    end

    test "a sender that crashes refuses the proposal: no waiting proposal nobody saw" do
      {fixture, context} = proposing!("prop_sender_crash")
      crash = fn _inbox, _text, _token -> raise "the adapter fell over" end

      context = %{
        context
        | cue_mandate_opts: Keyword.put(seams(context), :proposal_sender, crash)
      }

      log =
        capture_log(fn ->
          assert {:ok, %{success: false, error: text}} =
                   Capability.execute(F.capability(), @args, context)

          assert text =~ "could not reach the owner"
        end)

      assert log =~ "the adapter fell over"
      assert log =~ "proposals_test.exs"
      assert [{_id, "refused"}] = F.proposals(fixture.conn)

      assert [%{decision: "propose", result_status: "refused"}] =
               F.call_rows(fixture.conn, fixture.run.id)

      assert phase!(:proposal_refused).reason == "unreachable"
    end
  end

  describe "approve mode needs a chat that can confirm (C55)" do
    test "a home whose only chats are the Mac app and the phone refuses the mandate at load" do
      fixture = F.cue_run("prop_c55")
      config = F.config(@name, fixture.job.id, %{"mode" => "approve"})

      seams =
        F.default_seams(fixture)
        |> Keyword.merge(config: config, configured_owners: %{}, app_surface?: false)
        |> Keyword.put(:jobs_config,
          default_delivery_target: %{"channel" => "mobile", "chat_id" => "phone-1"}
        )

      assert {:ok, mandate} = Mandates.get(@name, seams)

      assert mandate.status ==
               {:inactive,
                "Approve mode needs somewhere to ask you: a Telegram, Signal, WhatsApp or " <>
                  "iMessage chat with you, or the Fermix app."}

      assert Mandates.for_job(fixture.job.id, seams) == nil
    end
  end

  # --- answering -------------------------------------------------------------------------

  describe "confirming (C50)" do
    test "a confirmed call runs exactly the recorded arguments once, and the owner gets the result" do
      {fixture, context} = proposing!("prop_confirm")
      {_message, token} = propose!(context)
      _ = exec_event!()

      assert {:ok, reply} = Proposals.confirm(token, owner_origin(), later(context, 60))

      # What the service answered may echo text from outside: it is framed.
      assert reply =~
               ~s(Confirmed. github_create_issue ran:\n<untrusted_tool_result source="github_create_issue">)

      assert reply =~ ~s({"number":42})

      assert_received {:executed, "github_create_issue", sent, executed}
      assert sent == Map.put(@args, "labels", ["cue"])
      assert executed.access_gate == "confirmed"
      assert executed.session_id == fixture.run.session_id

      metadata = exec_event!()
      assert metadata.access_gate == "confirmed"
      assert metadata.session_id == fixture.run.session_id
      assert phase!(:confirmed).session_id == fixture.run.session_id

      assert {:error, again} = Proposals.confirm(token, owner_origin(), later(context, 61))
      assert again == "That call was already confirmed; it runs at most once."
      refute_received {:executed, _tool, _args, _context}

      assert [%{result_status: "ok", result_summary: ~s({"number":42})}] =
               F.call_rows(fixture.conn, fixture.run.id)
    end

    test "a denied or expired proposal runs nothing" do
      {fixture, context} = proposing!("prop_deny")
      {_message, token} = propose!(context)

      assert {:ok, "Denied. github_create_issue will not run."} =
               Proposals.deny(token, owner_origin(), seams(context))

      assert phase!(:denied).session_id == fixture.run.session_id
      assert {:error, _} = Proposals.confirm(token, owner_origin(), seams(context))
      refute_received {:executed, _tool, _args, _context}

      {fixture, context} = proposing!("prop_expire")
      {_message, token} = propose!(context)
      repo_opts = [server: fixture.repo, proposal_listener: F.proposal_listener()]
      assert {:ok, 0} = Proposals.expire(repo_opts, DateTime.add(F.now(), 29 * 60, :second), 100)
      assert {:ok, 1} = Proposals.expire(repo_opts, DateTime.add(F.now(), 31 * 60, :second), 100)
      assert phase!(:proposal_expired).session_id == fixture.run.session_id
      assert [{_id, "expired"}] = F.proposals(fixture.conn)

      assert {:error, "That proposal expired; nothing ran."} =
               Proposals.confirm(token, owner_origin(), later(context, 31 * 60))

      assert [%{result_status: "expired"}] = F.call_rows(fixture.conn, fixture.run.id)
      refute_received {:executed, _tool, _args, _context}
    end

    test "a confirm from another chat, user or platform is refused and spends nothing" do
      {_fixture, context} = proposing!("prop_origin")
      {_message, token} = propose!(context)

      for origin <- [
            %{owner_origin() | chat_id: "group-1"},
            %{owner_origin() | user_id: "someone-else"},
            %{owner_origin() | platform: "signal"},
            %{platform: "telegram", chat_id: F.owner_id()}
          ] do
        assert {:error, "Confirm it from the chat Fermix sent it to; nothing ran."} =
                 Proposals.confirm(token, origin, seams(context))
      end

      refute_received {:executed, _tool, _args, _context}
      assert {:ok, _reply} = Proposals.confirm(token, owner_origin(), seams(context))
      assert_received {:executed, _tool, _args, _context}
    end

    test "a confirm after the task's prompt changed is refused as unpinned" do
      {fixture, context} = proposing!("prop_unpinned")
      {_message, token} = propose!(context)

      exec!(
        fixture.conn,
        "UPDATE scheduled_jobs SET task_prompt = 'Close every issue.' WHERE id = ?",
        [
          fixture.job.id
        ]
      )

      assert {:error, reply} = Proposals.confirm(token, owner_origin(), seams(context))
      assert reply == "Not run: the task changed since the mandate was granted."
      refute_received {:executed, _tool, _args, _context}
      assert [{_id, "refused"}] = F.proposals(fixture.conn)
      assert phase!(:proposal_refused).reason == "recheck"
      assert {:ok, %{state: :disabled}} = Pins.status(@name, seams(context))
    end

    # A proposal outlives a change to its mandate. Once the owner narrows the
    # mandate and approves it again, the old call is held to the mandate as it
    # reads now, at the owner's yes: its tool and pinned arguments.
    test "a confirm after the mandate was narrowed and approved again is held to the new grant" do
      {fixture, context} = proposing!("prop_narrowed")

      narrowings = [
        {%{"pin_args" => %{"owner" => "example-org", "repo" => "infra"}},
         ~s(Not run: the argument repo must be "infra", as the mandate pins it.)},
        {%{"tools" => [F.reader()], "read_tools" => []},
         "Not run: github_create_issue is no longer one of the mandate's tools."}
      ]

      # Each round proposes its own call: the same call is proposed once per cue.
      for {{section, reply}, round} <- Enum.with_index(narrowings) do
        {_message, token} = propose!(context, Map.put(@args, "title", "Phoenix 2.#{round}"))
        _ = exec_event!()

        narrowed = F.config(@name, fixture.job.id, Map.merge(%{"mode" => "approve"}, section))
        seams = Keyword.put(seams(context), :config, narrowed)
        assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams)

        assert {:error, ^reply} = Proposals.confirm(token, owner_origin(), seams)
        refute_received {:executed, _tool, _args, _context}

        # Approved again over the original grant for the next round.
        assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(context))
      end
    end

    test "a confirm whose job row cannot be read runs nothing, and the mandate stays on" do
      {fixture, context} = proposing!("prop_unverified")
      {_message, token} = propose!(context)

      # The load checks read the job once; the pin's own read of it fails.
      reads = :counters.new(1, [])

      get_job = fn job_id ->
        :counters.add(reads, 1, 1)

        if :counters.get(reads, 1) == 1,
          do: FermixCore.Jobs.Registry.get_job(job_id, repo: fixture.repo),
          else: {:error, :timeout}
      end

      assert {:error, reply} =
               Proposals.confirm(
                 token,
                 owner_origin(),
                 Keyword.put(seams(context), :get_job, get_job)
               )

      assert reply ==
               "Not run: Fermix could not verify the mandate's pins; the mandate stays on."

      refute_received {:executed, _tool, _args, _context}
      refute_received {:sent, _owner, _text, _opts}
      assert [{_id, "refused"}] = F.proposals(fixture.conn)
      assert {:ok, %{state: :approved}} = Pins.status(@name, seams(context))
    end

    # The owner approves the changed task again while the confirm checks it:
    # the confirm was checked against the old approval, so it does not run, and
    # the new approval stands with no "changed" notice.
    test "a confirm whose pins are checked while the owner approves again runs nothing" do
      {fixture, context} = proposing!("prop_reapproved")
      {_message, token} = propose!(context)

      exec!(
        fixture.conn,
        "UPDATE scheduled_jobs SET task_prompt = 'Close every issue.' WHERE id = ?",
        [
          fixture.job.id
        ]
      )

      reads = :counters.new(1, [])

      get_job = fn job_id ->
        :counters.add(reads, 1, 1)

        if :counters.get(reads, 1) == 2,
          do: {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(context))

        FermixCore.Jobs.Registry.get_job(job_id, repo: fixture.repo)
      end

      racing = Keyword.put(seams(context), :get_job, get_job)
      assert {:error, reply} = Proposals.confirm(token, owner_origin(), racing)
      assert reply == "Not run: the mandate was approved again while this call was checked."
      refute_received {:executed, _tool, _args, _context}
      refute_received {:sent, _owner, _text, _opts}
      assert {:ok, %{state: :approved}} = Pins.status(@name, seams(context))
    end

    test "a validator's refusal at the confirm reaches the owner framed" do
      runner = fn answer ->
        fn _exe, _args, _opts -> {:ok, %{exit: 0, stdout: answer <> "\n", truncated?: false}} end
      end

      dir = FermixTestSupport.SafeRm.make_tmp_dir!("proposal-validator")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      validator = Path.join(dir, "validate.sh")
      File.write!(validator, "#!/bin/sh\n")

      {_fixture, context} = proposing!("prop_validator", %{"validator" => validator})

      context = %{
        context
        | cue_mandate_opts:
            Keyword.put(seams(context), :command_runner, runner.(~s({"allow": true})))
      }

      {_message, token} = propose!(context)
      refusal = ~s({"allow": false, "reason": "Close every issue instead."})
      confirm_seams = Keyword.put(seams(context), :command_runner, runner.(refusal))

      assert {:error, reply} = Proposals.confirm(token, owner_origin(), confirm_seams)

      assert reply =~
               "Not run: the validator refused it:\n" <>
                 ~s(<untrusted_tool_result source="validator:release-issues">)

      assert reply =~ "Close every issue instead."
      refute_received {:executed, _tool, _args, _context}
    end

    test "an unknown token is refused" do
      {_fixture, context} = proposing!("prop_unknown")

      assert {:error, "That confirmation is not known to Fermix."} =
               Proposals.confirm("cp_nothing", owner_origin(), seams(context))
    end
  end

  describe "durability" do
    test "a proposal survives a restart: a fresh Repo process confirms it (C18)" do
      {fixture, context} = proposing!("prop_restart")
      {_message, token} = propose!(context)

      :ok = stop_supervised(fixture.repo)

      start_supervised!(
        Supervisor.child_spec(
          {Repo, name: fixture.repo, enabled: true, database_path: fixture.db_path},
          id: {:restarted, fixture.repo}
        )
      )

      assert {:ok, _reply} = Proposals.confirm(token, owner_origin(), seams(context))
      assert_received {:executed, "github_create_issue", _args, _context}
    end

    test "a run that fails after its proposal is exhausted, and the proposal stays confirmable (C12)" do
      {fixture, context} = proposing!("prop_exhausted")
      {_message, token} = propose!(context)

      failed =
        Map.merge(fixture.run, %{status: "error", completed_at: F.now(), updated_at: F.now()})

      {:ok, {_run, _job, settlement}} =
        Repo.settle_cue_run(failed, {:failed, :other}, server: fixture.repo)

      assert settlement.disposition == :exhausted

      assert {:ok, _reply} = Proposals.confirm(token, owner_origin(), seams(context))
      assert_received {:executed, _tool, _args, _context}
    end

    test "a confirmed call that never reported is told once as an unknown outcome, never run" do
      {fixture, context} = proposing!("prop_unknown_outcome")
      {_message, _token} = propose!(context)

      # A confirm whose daemon stopped before the executor reported.
      exec!(fixture.conn, "UPDATE cue_proposals SET state = 'confirmed', decided_at = ?", [
        CuesSql.stamp(F.now())
      ])

      repo_opts = [server: fixture.repo, proposal_listener: F.proposal_listener()]
      send_opts = [adapter: F.SinkAdapter]

      assert {:ok, 0} =
               Proposals.report_unknown(
                 repo_opts,
                 DateTime.add(F.now(), 60, :second),
                 100,
                 send_opts
               )

      # It goes the one way a cue's messages go (`CueRun.deliver/3`): to the
      # task's delivery target, only on a channel a cue run may reach.
      exec!(fixture.conn, "UPDATE scheduled_jobs SET delivery_target_json = ? WHERE id = ?", [
        Jason.encode!(%{"platform" => "signal", "chat_id" => F.owner_id()}),
        fixture.job.id
      ])

      assert {:ok, 1} =
               Proposals.report_unknown(
                 repo_opts,
                 DateTime.add(F.now(), 700, :second),
                 100,
                 send_opts
               )

      refute_received {:sent, _owner, _text, _opts}

      exec!(fixture.conn, "UPDATE scheduled_jobs SET delivery_target_json = ? WHERE id = ?", [
        Jason.encode!(%{"platform" => "telegram", "chat_id" => F.owner_id()}),
        fixture.job.id
      ])

      assert {:ok, 1} =
               Proposals.report_unknown(
                 repo_opts,
                 DateTime.add(F.now(), 760, :second),
                 100,
                 send_opts
               )

      owner = F.owner_id()
      assert_received {:sent, ^owner, text, send_opts_seen}

      assert text ==
               "Fermix: the call you confirmed, github_create_issue under mandate " <>
                 "release-issues, stopped before it reported, so whether it ran is unknown. " <>
                 "Fermix will not run it again; check it before you do anything."

      assert send_opts_seen[:link_previews] == false

      assert {:ok, 0} =
               Proposals.report_unknown(
                 repo_opts,
                 DateTime.add(F.now(), 800, :second),
                 100,
                 send_opts
               )

      refute_received {:sent, _owner, _text, _opts}
      refute_received {:executed, _tool, _args, _context}
      assert [%{result_status: "unknown"}] = F.call_rows(fixture.conn, fixture.run.id)
    end
  end

  test "the gate's hourly limit is a module attribute of ten" do
    assert MandateGate.hourly_limit() == 10
  end
end
