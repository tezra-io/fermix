defmodule FermixCore.Cues.MandateEffectCrashTest do
  @moduledoc """
  What the owner is told when a cue run, or a confirm, stops right at an effect
  (M60 §9.4, §10.3, §10.9; review 2's design concern 7): one test per kind of
  effect (an allowed call, a proposal, a confirmed call), each killing the
  process at the effect and asserting the owner's exact words, once. A kill
  is untrappable, so nothing in the process gets to tidy up: what remains is
  what a crash or a stopped daemon leaves.
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures, only: [rows: 3]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Cues.MandateGate
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Proposals
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.MandateFixtures, as: F

  @name "release-issues"
  @args %{"owner" => "example-org", "repo" => "ops", "title" => "Phoenix 2.0"}
  @prefix "Watcher release-watch · from eng-blogs\n\n"
  @wait_ms 10_000

  # The stand-in tool, whose executor is killed before or after its effect.
  defp dying_capability(moment) do
    tool = F.manifest() |> Map.put("die", moment)

    Capability.new(%{
      name: F.tool(),
      description: "Open an issue.",
      parameters: tool["parameters"],
      kind: :builtin,
      executor: {__MODULE__, :execute_then_die, ["github", tool]},
      policy_class: :external_api,
      metadata: %{plugin_owned?: true, plugin: "github", access_sensitive?: false}
    })
  end

  @doc false
  def execute_then_die(args, _context, _plugin, %{"test_pid" => pid, "die" => moment}) do
    if moment == "after", do: send(pid, {:executed, args})
    Process.exit(self(), :kill)
  end

  defp run!(tag, section \\ %{}) do
    fixture = F.cue_run(tag)
    config = F.config(@name, fixture.job.id, section)
    context = F.context(fixture, @name, config: config)
    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(context))
    {fixture, context}
  end

  defp seams(context), do: context.cue_mandate_opts

  # `fun` in a process of its own, which must die killed.
  defp killed!(fun) do
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @wait_ms
  end

  # What the scheduler does with a run that died after an effect: settle it
  # (exhausted, since its marker is set), then send its final failure once.
  defp settle_and_report!(fixture) do
    failed =
      Map.merge(fixture.run, %{
        status: "error",
        completed_at: F.now(),
        updated_at: F.now(),
        error: "runner crashed: :killed"
      })

    {:ok, {run, job, %{disposition: :exhausted}}} =
      Repo.settle_cue_run(failed, {:failed, :other}, server: fixture.repo)

    assert {:ok, "sent"} =
             CueRun.report_final_failure(job, run,
               repo: fixture.repo,
               adapter: F.SinkAdapter,
               timeout_ms: 5_000
             )

    owner = F.owner_id()
    assert_received {:sent, ^owner, text, _opts}
    refute_received {:sent, _owner, _text, _opts}
    text
  end

  defp args_json(fixture) do
    [[json]] =
      rows(fixture.conn, "SELECT args_json FROM cue_mandate_calls WHERE run_id = ?", [
        fixture.run.id
      ])

    json
  end

  defp report_of(fixture, decision) do
    "Fermix's record of this run's action calls:\n\n" <>
      "1. github_create_issue under mandate release-issues: #{decision}\n" <>
      "Arguments:\n" <> UntrustedContent.frame("github_create_issue", args_json(fixture))
  end

  describe "an allowed call (auto mode)" do
    for moment <- ["before", "after"] do
      test "a run killed #{moment} the effect: the owner reads that whether it ran is unknown, once" do
        {fixture, context} = run!("crash_allow_#{unquote(moment)}")
        capability = dying_capability(unquote(moment))

        killed!(fn -> Capability.execute(capability, @args, context) end)
        if unquote(moment) == "after", do: assert_received({:executed, _args})

        assert [%{decision: "allow", finished_at: nil}] =
                 F.call_rows(fixture.conn, fixture.run.id)

        text = settle_and_report!(fixture)

        expected =
          report_of(
            fixture,
            "allowed; the run ended before it reported, so whether it ran is unknown."
          )

        assert String.starts_with?(text, @prefix)
        assert String.ends_with?(text, "\n\n" <> expected)

        # The sweep finishes the row and tells no one again.
        later = DateTime.add(F.now(), 60, :second)
        assert {:ok, 1} = MandateGate.finish_unreported([server: fixture.repo], later, 100)
        assert {:ok, 0} = MandateGate.finish_unreported([server: fixture.repo], later, 100)
        refute_received {:sent, _owner, _text, _opts}

        assert [%{result_status: "unknown"}] = F.call_rows(fixture.conn, fixture.run.id)
        {:ok, calls} = CueRun.list_run_calls(fixture.run.id, repo: fixture.repo)
        assert CueRun.report(calls) == expected
      end
    end

    test "the sweep leaves a call of a run still going alone" do
      {fixture, context} = run!("crash_allow_running")
      killed!(fn -> Capability.execute(dying_capability("before"), @args, context) end)

      later = DateTime.add(F.now(), 60, :second)
      assert {:ok, 0} = MandateGate.finish_unreported([server: fixture.repo], later, 100)
      assert [%{finished_at: nil}] = F.call_rows(fixture.conn, fixture.run.id)
    end
  end

  describe "a proposal (approve mode)" do
    test "a run killed right after the proposal went out: the owner has it, and the report says so once" do
      {fixture, context} = run!("crash_propose", %{"mode" => "approve"})

      sender = fn inbox, spec ->
        send(F.pid_of(inbox.destination), {:proposal, spec.text, spec.token})
        Process.exit(self(), :kill)
      end

      context = %{
        context
        | cue_mandate_opts: Keyword.put(seams(context), :proposal_sender, sender)
      }

      killed!(fn -> Capability.execute(F.capability(), @args, context) end)
      assert_received {:proposal, _message, token}
      assert [{_id, "waiting"}] = F.proposals(fixture.conn)

      text = settle_and_report!(fixture)
      expected = report_of(fixture, "proposed to you; it runs only if you confirm it.")
      assert String.ends_with?(text, "\n\n" <> expected)

      # It is still the owner's to answer.
      origin = %{platform: "telegram", chat_id: F.owner_id(), user_id: F.owner_id()}

      assert {:ok, "Denied. github_create_issue will not run."} =
               Proposals.deny(token, origin, seams(context))
    end
  end

  describe "a confirmed call" do
    test "a confirm killed right after the effect: the owner is told once that whether it ran is unknown" do
      {fixture, context} = run!("crash_confirm", %{"mode" => "approve"})
      registry = :"crash_caps_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({CapabilityRegistry, name: registry}, id: registry))
      :ok = CapabilityRegistry.register(registry, dying_capability("after"))

      assert {:ok, %{success: false}} = Capability.execute(F.capability(), @args, context)
      assert_received {:proposal, _inbox, _message, token}

      origin = %{platform: "telegram", chat_id: F.owner_id(), user_id: F.owner_id()}

      confirm_seams =
        seams(context)
        |> Keyword.put(:capability_registry, registry)
        |> Keyword.put(:now, DateTime.add(F.now(), 60, :second))

      killed!(fn -> Proposals.confirm(token, origin, confirm_seams) end)
      assert_received {:executed, _args}
      assert [{_id, "confirmed"}] = F.proposals(fixture.conn)

      repo_opts = [server: fixture.repo]
      report_at = DateTime.add(F.now(), 700, :second)
      send_opts = [adapter: F.SinkAdapter]
      assert {:ok, 1} = Proposals.report_unknown(repo_opts, report_at, 100, send_opts)

      owner = F.owner_id()
      assert_received {:sent, ^owner, text, _opts}

      assert text ==
               "Fermix: the call you confirmed, github_create_issue under mandate " <>
                 "release-issues, stopped before it reported, so whether it ran is unknown. " <>
                 "Fermix will not run it again; check it before you do anything."

      assert {:ok, 0} =
               Proposals.report_unknown(
                 repo_opts,
                 DateTime.add(report_at, 60, :second),
                 100,
                 send_opts
               )

      refute_received {:sent, _owner, _text, _opts}
      refute_received {:executed, _args}
      assert [%{result_status: "unknown"}] = F.call_rows(fixture.conn, fixture.run.id)
    end
  end
end
