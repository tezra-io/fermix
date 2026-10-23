defmodule FermixCore.Cues.ProposalsAppTest do
  @moduledoc """
  M60 app surface §3.7 (D28): a proposal reaches the owner's devices. The
  record and the card an app shows, `decide/4` from the companion socket, a
  phone and the management socket (each runs the recorded call exactly once,
  and the first answer from any surface wins), the announcements every app
  surface hears, and the reach rule (approve mode needs a chat with the owner
  or the Fermix app).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import FermixTestSupport.CueFixtures, only: [exec!: 3, rows: 3]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Proposals
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.MandateFixtures, as: F
  alias FermixTestSupport.TelemetryCapture

  @name "release-issues"
  @args %{"owner" => "example-org", "repo" => "ops", "title" => "Phoenix 2.0"}
  @recorded Map.put(@args, "labels", ["cue"])
  # A confirmed call runs in a task of its own: its arrival is awaited on a
  # named bound that holds on a loaded runner.
  @arrival_ms 10_000
  @management %{surface: :management, device_id: nil}
  @companion %{surface: :companion, device_id: nil}

  @record_keys ~w(created_at decided_at decided_from expires_at mandate proposal_id result_status
                  source_ref state status_sentence task tool watcher)a

  # --- helpers -------------------------------------------------------------------------

  # A claimed cue run under an approved approve-mode mandate, with the stand-in
  # tool registered, a task supervisor for confirmed calls and a listener that
  # hands every announcement to this test. `seams` override the defaults.
  defp proposing!(tag, seams \\ []) do
    fixture = F.cue_run(tag)
    config = F.config(@name, fixture.job.id, %{"mode" => "approve"})
    registry = :"proposal_app_caps_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({CapabilityRegistry, name: registry}, id: registry))
    :ok = CapabilityRegistry.register(registry, F.capability())
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))
    test_pid = self()

    defaults = [
      config: config,
      capability_registry: registry,
      task_supervisor: tasks,
      proposal_listener: fn event -> send(test_pid, {:proposal_event, event}) end
    ]

    context = F.context(fixture, @name, Keyword.merge(defaults, seams))

    TelemetryCapture.attach([[:fermix, :tool, :exec], [:fermix, :cue, :lifecycle]],
      session_id: fixture.run.session_id
    )

    assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), seams(context))
    {fixture, context}
  end

  defp seams(context), do: context.cue_mandate_opts

  defp later(context, seconds),
    do: Keyword.put(seams(context), :now, DateTime.add(F.now(), seconds, :second))

  # The model's call, proposed; the id of the one proposal it stored.
  defp propose!(fixture, context) do
    assert {:ok, %{success: false, error: text}} =
             Capability.execute(F.capability(), @args, context)

    assert text =~ "Proposed to the owner; it runs only if they confirm it."
    refute_received {:executed, _tool, _args, _context}
    [{id, "waiting"}] = F.proposals(fixture.conn)
    id
  end

  defp token! do
    assert_received {:proposal, _inbox, _message, token}
    token
  end

  defp owner_origin, do: %{platform: "telegram", chat_id: F.owner_id(), user_id: F.owner_id()}

  defp phase!(phase) do
    assert_received {:telemetry, [:fermix, :cue, :lifecycle], _measurements,
                     %{phase: ^phase} = metadata}

    metadata
  end

  defp resolved! do
    assert_receive {:proposal_event, {:resolved, resolved}}, @arrival_ms
    resolved
  end

  # --- the record and the card ------------------------------------------------------------

  describe "the record and the card" do
    test "a waiting proposal's record is Fermix's alone: every field, no argument, no cue text" do
      {fixture, context} = proposing!("app_record")
      id = propose!(fixture, context)

      assert {:ok, [record]} = Proposals.records(:waiting, seams(context))
      assert record |> Map.keys() |> Enum.sort() == @record_keys

      assert record == %{
               proposal_id: id,
               state: "waiting",
               mandate: @name,
               tool: F.tool(),
               task: %{job_id: fixture.job.id, name: "release issues"},
               watcher: "release-watch",
               source_ref: F.source(),
               created_at: "2026-10-10T12:00:00Z",
               expires_at: "2026-10-10T12:30:00Z",
               decided_at: nil,
               decided_from: nil,
               result_status: nil,
               status_sentence: "Waiting for your answer; it runs only if you confirm."
             }

      refute inspect(record) =~ "Phoenix"
      assert {:ok, [^record]} = Proposals.records(:recent, seams(context))

      # Past its expiry and not yet swept: no longer waiting for an answer.
      assert {:ok, []} = Proposals.records(:waiting, later(context, 31 * 60))
      assert {:ok, [_still_recent]} = Proposals.records(:recent, later(context, 31 * 60))
      assert {:ok, []} = Proposals.records(:recent, later(context, 8 * 86_400))
    end

    test "the card is the record, when the cue arrived, Fermix's sentence and the outside text" do
      {fixture, context} = proposing!("app_card")
      id = propose!(fixture, context)

      assert {:ok, card} = Proposals.card(id, seams(context))
      assert {:ok, [record]} = Proposals.records(:waiting, seams(context))
      assert Map.take(card, @record_keys) == record
      assert card.received_at == "2026-10-10T11:59:00Z"

      assert card.summary ==
               "A task wants to run github_create_issue under your mandate release-issues. " <>
                 "It runs only if you confirm."

      assert card.outside == %{
               args_text: Jason.encode!(@recorded, pretty: true),
               cue: %{
                 type: "release",
                 subject: "phoenix",
                 text: "Phoenix 2.0 is out.",
                 occurred_at: nil
               }
             }

      assert {:ok, [^card]} = Proposals.waiting_cards(seams(context))
    end

    test "a card whose cue Fermix no longer keeps has no cue; an unknown id is not found" do
      {fixture, context} = proposing!("app_card_gone")
      id = propose!(fixture, context)
      exec!(fixture.conn, "UPDATE cues SET snapshot = NULL", [])

      assert {:ok, %{outside: %{cue: nil, args_text: args_text}}} =
               Proposals.card(id, seams(context))

      assert args_text =~ "Phoenix 2.0"
      assert {:error, :not_found} = Proposals.card("cpr_nothing", seams(context))
    end

    test "with memory off the reads say so" do
      repo = :"proposal_app_off_#{System.unique_integer([:positive])}"
      start_supervised!({Repo, name: repo, enabled: false})

      assert {:error, :memory_off} = Proposals.records(:waiting, repo: repo)
      assert {:error, :memory_off} = Proposals.card("cpr_any", repo: repo)
      assert {:error, :memory_off} = Proposals.waiting_cards(repo: repo)
    end
  end

  # --- deciding from a device ----------------------------------------------------------------

  describe "decide/4" do
    test "the management socket's confirm runs the recorded call exactly once" do
      {fixture, context} = proposing!("app_confirm")
      id = propose!(fixture, context)
      token = token!()

      assert {:ok, record} = Proposals.decide(id, :confirm, @management, later(context, 60))
      assert %{state: "confirmed", decided_from: "management", result_status: nil} = record
      assert record.decided_at == "2026-10-10T12:01:00Z"

      assert_receive {:executed, "github_create_issue", sent, executed}, @arrival_ms
      assert sent == @recorded
      assert executed.access_gate == "confirmed"
      assert executed.session_id == fixture.run.session_id

      assert resolved!() == %{
               proposal_id: id,
               state: "confirmed",
               result_status: "ok",
               sentence: "Confirmed. github_create_issue ran.",
               result_text: ~s({"number":42})
             }

      confirmed = phase!(:confirmed)
      assert confirmed.kind == "management"
      assert confirmed.session_id == fixture.run.session_id

      # A second answer, from any surface, runs nothing.
      again = "That call was already confirmed; it runs at most once."
      assert {:error, ^again} = Proposals.decide(id, :confirm, @companion, later(context, 61))
      assert {:error, ^again} = Proposals.decide(id, :deny, @management, later(context, 62))

      assert {:error, ^again} =
               Proposals.decide(
                 id,
                 :confirm,
                 %{surface: :mobile, device_id: "dev-1"},
                 later(context, 63)
               )

      assert {:error, ^again} = Proposals.confirm(token, owner_origin(), later(context, 64))
      refute_receive {:executed, _tool, _args, _context}, 100

      assert {:ok, [%{decided_from: "management", result_status: "ok"} = done]} =
               Proposals.records(:recent, later(context, 65))

      assert done.status_sentence == "Confirmed; github_create_issue ran."
      assert [%{result_status: "ok"}] = F.call_rows(fixture.conn, fixture.run.id)
    end

    test "the companion socket's denial runs nothing and ends the call" do
      {fixture, context} = proposing!("app_deny")
      id = propose!(fixture, context)
      token = token!()

      assert {:ok, %{state: "denied", decided_from: "companion"} = record} =
               Proposals.decide(id, :deny, @companion, seams(context))

      assert record.status_sentence == "Denied; github_create_issue did not run."

      assert resolved!() == %{
               proposal_id: id,
               state: "denied",
               result_status: nil,
               sentence: "Denied. github_create_issue will not run.",
               result_text: nil
             }

      assert phase!(:denied).kind == "companion"
      assert [%{result_status: "denied"}] = F.call_rows(fixture.conn, fixture.run.id)

      assert {:error, "That call was already denied."} =
               Proposals.confirm(token, owner_origin(), seams(context))

      refute_received {:executed, _tool, _args, _context}
    end

    test "a phone's answer records its device" do
      {fixture, context} = proposing!("app_phone")
      id = propose!(fixture, context)
      phone = %{surface: :mobile, device_id: "dev-7"}

      assert {:ok, %{decided_from: "mobile"}} = Proposals.decide(id, :deny, phone, seams(context))

      assert [["mobile:dev-7"]] =
               rows(fixture.conn, "SELECT decided_from FROM cue_proposals WHERE id = ?", [id])
    end

    test "an answer after expiry, or for no proposal, runs nothing" do
      {fixture, context} = proposing!("app_expired")
      id = propose!(fixture, context)

      assert {:error, "That proposal expired; nothing ran."} =
               Proposals.decide(id, :confirm, @management, later(context, 31 * 60))

      assert [{^id, "waiting"}] = F.proposals(fixture.conn)

      assert {:error, "Fermix has no proposal with that id; nothing ran."} =
               Proposals.decide("cpr_nothing", :confirm, @companion, seams(context))

      refute_receive {:executed, _tool, _args, _context}, 100
    end

    test "an answer after the chat's confirm runs nothing; the chat's confirm is announced" do
      {fixture, context} = proposing!("app_after_chat")
      id = propose!(fixture, context)
      assert {:ok, _reply} = Proposals.confirm(token!(), owner_origin(), seams(context))
      assert_received {:executed, _tool, _args, _context}
      assert phase!(:confirmed).kind == "telegram"
      assert %{proposal_id: ^id, state: "confirmed", result_status: "ok"} = resolved!()

      assert {:error, "That call was already confirmed; it runs at most once."} =
               Proposals.decide(id, :confirm, @companion, seams(context))

      refute_receive {:executed, _tool, _args, _context}, 100
    end

    test "a refusal at the confirm's re-check is announced, and nothing runs" do
      {fixture, context} = proposing!("app_recheck")
      id = propose!(fixture, context)
      off = F.config(@name, fixture.job.id, %{"mode" => "approve", "enabled" => false})

      assert {:ok, %{state: "confirmed"}} =
               Proposals.decide(
                 id,
                 :confirm,
                 @management,
                 Keyword.put(seams(context), :config, off)
               )

      assert %{state: "refused", sentence: "Not run: the mandate is switched off."} = resolved!()
      refute_received {:executed, _tool, _args, _context}
      assert [{^id, "refused"}] = F.proposals(fixture.conn)
    end
  end

  # --- announcements and reach -----------------------------------------------------------

  describe "a confirmed call that never finished" do
    # A device's confirm whose daemon stopped before the call reported: the
    # unknown-outcome report is the only end it will have.
    test "is ended unknown by the report, once, and every app surface hears it" do
      {fixture, context} = proposing!("app_unknown")
      id = propose!(fixture, context)

      exec!(
        fixture.conn,
        "UPDATE cue_proposals SET state = 'confirmed', decided_at = ?, decided_from = 'companion'",
        [CuesSql.stamp(F.now())]
      )

      listener = Keyword.fetch!(seams(context), :proposal_listener)
      repo_opts = [server: fixture.repo, proposal_listener: listener]
      send_opts = [adapter: F.SinkAdapter]
      at = DateTime.add(F.now(), 700, :second)

      assert {:ok, 1} = Proposals.report_unknown(repo_opts, at, 100, send_opts)

      assert resolved!() == %{
               proposal_id: id,
               state: "confirmed",
               result_status: "unknown",
               sentence:
                 "Confirmed, but github_create_issue stopped before it reported, so whether " <>
                   "it ran is unknown. Check it before you do anything; Fermix will not run it " <>
                   "again.",
               result_text: nil
             }

      assert {:ok, [record]} = Proposals.records(:recent, Keyword.put(seams(context), :now, at))
      assert record.result_status == "unknown"

      assert record.status_sentence ==
               "Confirmed, but github_create_issue stopped before it reported, so whether it " <>
                 "ran is unknown."

      later = DateTime.add(at, 600, :second)
      assert {:ok, 0} = Proposals.report_unknown(repo_opts, later, 100, send_opts)
      refute_receive {:proposal_event, {:resolved, _resolved}}, 100
      assert [%{result_status: "unknown"}] = F.call_rows(fixture.conn, fixture.run.id)
      refute_received {:executed, _tool, _args, _context}
    end

    test "a re-check that raises refuses the call at once, announced, and nothing runs" do
      {fixture, context} = proposing!("app_recheck_raise")
      id = propose!(fixture, context)

      raising =
        Keyword.put(seams(context), :get_job, fn _job_id -> raise "the job store fell over" end)

      log =
        capture_log(fn ->
          assert {:ok, %{state: "confirmed"}} =
                   Proposals.decide(id, :confirm, @management, raising)

          assert %{state: "refused", sentence: "Not run: Fermix could not finish checking it."} =
                   resolved!()
        end)

      assert log =~ "the job store fell over"
      refute_received {:executed, _tool, _args, _context}
      assert [{^id, "refused"}] = F.proposals(fixture.conn)
      assert [%{result_status: "refused"}] = F.call_rows(fixture.conn, fixture.run.id)
    end
  end

  describe "announcements" do
    test "a stored proposal is offered to every app surface as its card" do
      {fixture, context} = proposing!("app_offer")
      id = propose!(fixture, context)

      assert_received {:proposal_event, {:offered, card}}
      assert {:ok, ^card} = Proposals.card(id, seams(context))
    end

    test "an expired proposal is announced" do
      {fixture, context} = proposing!("app_expiry_event")
      id = propose!(fixture, context)
      listener = Keyword.fetch!(seams(context), :proposal_listener)
      repo_opts = [server: fixture.repo, proposal_listener: listener]

      assert {:ok, 1} =
               Proposals.expire(repo_opts, DateTime.add(F.now(), 31 * 60, :second), 100)

      assert %{
               proposal_id: ^id,
               state: "expired",
               sentence: "That proposal expired; nothing ran."
             } = resolved!()
    end
  end

  describe "reach (C55)" do
    test "with the Fermix app and no chat with the owner, a proposal waits for the app" do
      {fixture, context} =
        proposing!("app_reach",
          configured_owners: %{},
          jobs_config: [default_delivery_target: %{"channel" => "mobile", "chat_id" => "p-1"}],
          app_surface?: true
        )

      assert {:ok, %Mandates{status: :active}} = Mandates.get(@name, seams(context))
      id = propose!(fixture, context)

      refute_received {:proposal, _inbox, _message, _token}
      assert_received {:proposal_event, {:offered, %{proposal_id: ^id, state: "waiting"}}}
      assert phase!(:proposed).proposal_id == id

      assert [[nil, nil, nil]] =
               rows(
                 fixture.conn,
                 "SELECT sent_platform, sent_chat_id, sent_user_id FROM cue_proposals",
                 []
               )

      assert {:ok, %{state: "confirmed"}} =
               Proposals.decide(id, :confirm, @companion, seams(context))

      assert_receive {:executed, "github_create_issue", _args, _context}, @arrival_ms
    end

    test "with the Fermix app, a chat send that fails leaves the proposal waiting" do
      down = fn _inbox, _text, _token -> {:error, :channel_down} end
      {fixture, context} = proposing!("app_reach_down", proposal_sender: down, app_surface?: true)
      id = propose!(fixture, context)

      assert_received {:proposal_event, {:offered, %{proposal_id: ^id}}}
      assert [{^id, "waiting"}] = F.proposals(fixture.conn)
    end

    test "with no app and no chat with the owner, approve mode does not load" do
      fixture = F.cue_run("app_reach_none")
      config = F.config(@name, fixture.job.id, %{"mode" => "approve"})

      seams =
        F.default_seams(fixture)
        |> Keyword.merge(config: config, configured_owners: %{}, app_surface?: false)
        |> Keyword.put(:jobs_config,
          default_delivery_target: %{"channel" => "mobile", "chat_id" => "phone-1"}
        )

      assert {:ok, %Mandates{status: {:inactive, sentence}}} = Mandates.get(@name, seams)

      assert sentence ==
               "Approve mode needs somewhere to ask you: a Telegram, Signal, WhatsApp or " <>
                 "iMessage chat with you, or the Fermix app."
    end
  end
end
