defmodule FermixCore.Cues.FollowUpAnswersTest do
  @moduledoc """
  Answering a watcher's follow-up (M60_WATCHER_CODING_RUNS.md §3.4, §4.5, §5,
  §6.2, §9): every `cp_` token goes through `Cues.Proposals`, the one place
  answers go, which hands a follow-up's card to `Cues.FollowUps`; a card's id
  answers only from the chat it waits in (the bare `/confirm`); the app
  surfaces are offered each card and told its end; and Always allow allows
  only what the card showed.
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.CueAdmission
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-30 12:00:00.000000Z]
  @owner %{platform: "telegram", chat_id: "chat-1", user_id: "owner-1"}
  @stranger %{platform: "telegram", chat_id: "chat-9", user_id: "owner-1"}
  @prompt "Review the last day's commits on dev and report the findings."
  @app %{surface: :companion, device_id: nil}

  defmodule RecordingDelivery do
    @moduledoc false
    def send_message(target, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delivered, target, text})
      :ok
    end
  end

  setup do
    ctx = start_repo("follow_up_answers")
    registry = :"follow_up_answers_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, tool("shell"))
    Map.merge(ctx, %{registry: registry, ref: "x-feed-#{System.unique_integer([:positive])}"})
  end

  # --- a follow-up's card (§4.5, §6.2) -------------------------------------------------

  describe "a follow-up's card" do
    test "is answered by its cp_ token through Proposals, which hands it to FollowUps", ctx do
      watcher = follow_up_watcher!(ctx)
      trigger = offer!(ctx, "cp_card-one")

      assert_received {:event, {:offered, card}}
      assert card.proposal_id == trigger.id
      assert card.follow_up.asks == "run"
      assert card.follow_up.tools == ["shell"]
      assert card.outside.cue.text =~ "Limits reset 1"
      refute Map.has_key?(card.outside, :args_text)

      assert {:ok, line} = Proposals.confirm("cp_card-one", @owner, opts(ctx))
      assert line =~ ~s(Starting "Codex review" for post-1's post · )
      assert_received :woken
      assert [%{state: "starting"}] = states(ctx, watcher)

      assert_received {:event, {:resolved, %{proposal_id: id, state: "confirmed"}}}
      assert id == trigger.id

      assert {:error, "That follow-up is already starting."} =
               Proposals.confirm("cp_card-one", @owner, opts(ctx))
    end

    test "a no skips it, and every app surface hears it", ctx do
      watcher = follow_up_watcher!(ctx)
      _trigger = offer!(ctx, "cp_card-two")

      assert {:ok, ~s(Skipped "Codex review"; it did not run.)} =
               Proposals.deny("cp_card-two", @owner, opts(ctx))

      assert [%{state: "skipped"}] = states(ctx, watcher)
      assert_received {:event, {:resolved, %{state: "denied"}}}
      refute_received :woken
    end

    test "a token no card holds is not known, and runs nothing", ctx do
      assert {:error, "That confirmation is not known to Fermix."} =
               Proposals.confirm("cp_nobody-holds-this", @owner, opts(ctx))
    end

    test "its id answers only from the chat it waits in", ctx do
      watcher = follow_up_watcher!(ctx)
      trigger = offer!(ctx, "cp_card-three")

      assert {:error, "That card is not waiting in this chat; nothing ran."} =
               Proposals.confirm(trigger.id, @stranger, opts(ctx))

      assert [%{state: "waiting"}] = states(ctx, watcher)

      assert {:ok, [%{kind: :follow_up, id: id, title: ~s(Run "Codex review"?)}]} =
               Proposals.waiting_in_chat(@owner, opts(ctx))

      assert id == trigger.id
      assert {:ok, []} = Proposals.waiting_in_chat(@stranger, opts(ctx))

      assert {:ok, "Starting" <> _rest} = Proposals.confirm(trigger.id, @owner, opts(ctx))

      assert [%{state: "starting", decided_from: "telegram:chat-1:owner-1"}] =
               states(ctx, watcher)
    end

    # §4.2: one active run per job. The tap says the follow-up is starting; the
    # claim that finds it still running refuses it, and the owner hears so through
    # where it reports, as every app surface does.
    test "a yes while the follow-up runs is refused at its turn, and the owner is told", ctx do
      watcher = follow_up_watcher!(ctx)
      trigger = offer!(ctx, "cp_card-four")

      exec!(ctx.conn, "UPDATE scheduled_jobs SET state = 'running' WHERE id = ?", [
        watcher.follow_up_job_id
      ])

      assert {:ok, "Starting \"Codex review\" for post-1's post · " <> _time} =
               Proposals.confirm("cp_card-four", @owner, opts(ctx))

      assert_received :woken
      assert [%{state: "starting"}] = states(ctx, watcher)

      told = opts(ctx) ++ [adapter: RecordingDelivery, delivery_opts: [test_pid: self()]]

      admission = [
        repo_opts: [server: ctx.repo],
        notice: fn _watcher, _kind, _data -> :ok end,
        capability_registry: ctx.registry,
        cues_config: [],
        channel_ready?: fn :telegram -> true end,
        refused: &FollowUps.refused(&1, &2, told)
      ]

      assert [] = CueAdmission.claim_follow_ups(1, @now, &run_attrs/1, admission)

      running = "Not started: it is already running."
      assert [%{state: "refused", reason: ^running}] = states(ctx, watcher)

      assert_received {:event,
                       {:resolved, %{proposal_id: id, state: "refused", sentence: ^running}}}

      assert id == trigger.id

      assert_received {:delivered, "chat-1", text}

      assert text ==
               ~s(Watcher codex-limits: "Codex review" for post-1's post did not start. ) <>
                 running
    end

    test "an app answers by its id, and the app surfaces list it only while it waits", ctx do
      watcher = follow_up_watcher!(ctx)
      trigger = offer!(ctx, "cp_card-five")

      assert {:ok, cards} = Proposals.waiting_cards(opts(ctx))
      assert [%{proposal_id: id, follow_up: %{asks: "run"}}] = cards
      assert id == trigger.id

      assert {:ok, %{proposal_id: ^id, state: "confirmed"}} =
               Proposals.decide(trigger.id, :confirm, @app, opts(ctx))

      assert [%{state: "starting", decided_from: "companion"}] = states(ctx, watcher)
      assert {:ok, []} = Proposals.waiting_cards(opts(ctx))
    end

    test "nobody's answer expires it, and every app surface hears it", ctx do
      _watcher = follow_up_watcher!(ctx)
      _trigger = offer!(ctx, "cp_card-six")
      listener = [proposal_listener: Keyword.fetch!(opts(ctx), :proposal_listener)]
      later = DateTime.add(@now, 30 * 60, :second)

      assert {:ok, 1} = FollowUps.expire([server: ctx.repo] ++ listener, later, 10)
      assert_received {:event, {:resolved, %{state: "expired"}}}
    end
  end

  # --- Always allow (2026-10-31 revision of §3.4, §5) -------------------------------------

  describe "Always allow on a follow-up's card" do
    test "runs this one and allows what the card showed, so the next item needs no card", ctx do
      watcher = follow_up_watcher!(ctx)
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: watcher.id)
      _trigger = offer!(ctx, "cp_allow-one")

      assert_received {:event, {:offered, %{follow_up: %{asks: "run"} = follow_up}}}
      assert follow_up.offers_always_allow == true

      assert {:ok, line} = Proposals.always_allow("cp_allow-one", @owner, opts(ctx))
      assert line =~ ~s(Starting "Codex review" for post-1's post · )
      assert line =~ "Always allowed: from now on it runs with no card."
      assert_received :woken

      assert_received {:event, {:resolved, %{state: "confirmed", sentence: sentence}}}

      assert sentence ==
               "Confirmed; the follow-up is starting, and runs with no card from now on."

      assert_receive {:telemetry, _event, _measurements,
                      %{phase: :follow_up_decided, decision: :always_allow} = decided}

      assert {decided.outcome, decided.kind, decided.state} == {"allowed", "telegram", "starting"}

      pass!(ctx, 2)

      assert [%{state: "starting", mode: "approve"}, %{state: "starting", mode: "auto"}] =
               states(ctx, watcher)

      assert {:ok, []} =
               Repo.cues_call(CuesFollowUpSql, {:claim_offers, @now, 10}, server: ctx.repo)

      assert {:error, "That follow-up is already starting."} =
               Proposals.always_allow("cp_allow-one", @owner, opts(ctx))
    end

    test "a change since the card was shown allows nothing; the run still starts", ctx do
      watcher = follow_up_watcher!(ctx)
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: watcher.id)
      _trigger = offer!(ctx, "cp_allow-two")

      {:ok, _} =
        Watchers.update(watcher.name, %{sources: [ctx.ref, "github-releases"]}, opts(ctx))

      assert {:ok, line} = Proposals.always_allow("cp_allow-two", @owner, opts(ctx))
      assert line =~ ~s(Starting "Codex review" for post-1's post · )

      assert line =~
               "Not always allowed: it changed since this card was shown, so the next item " <>
                 "asks again."

      assert_receive {:telemetry, _event, _measurements,
                      %{phase: :follow_up_decided, outcome: "changed"}}

      pass!(ctx, 2)
      assert [%{state: "starting"}, %{state: "waiting", mode: "approve"}] = states(ctx, watcher)
    end

    test "an app answers it by the card's id", ctx do
      watcher = follow_up_watcher!(ctx)
      trigger = offer!(ctx, "cp_allow-three")

      assert {:ok, %{proposal_id: id, state: "confirmed"}} =
               Proposals.decide(trigger.id, :always_allow, @app, opts(ctx))

      assert id == trigger.id
      assert_received :woken
      assert [%{state: "starting", decided_from: "companion"}] = states(ctx, watcher)

      pass!(ctx, 2)
      assert [_card, %{state: "starting", mode: "auto"}] = states(ctx, watcher)
    end

    test "its id answers only from the chat it waits in", ctx do
      watcher = follow_up_watcher!(ctx)
      trigger = offer!(ctx, "cp_allow-four")

      assert {:error, "That card is not waiting in this chat; nothing ran."} =
               Proposals.always_allow(trigger.id, @stranger, opts(ctx))

      assert {:ok, "Starting" <> _rest} = Proposals.always_allow(trigger.id, @owner, opts(ctx))
      assert [%{state: "starting"}] = states(ctx, watcher)
    end

    test "a mandate's proposal offers no Always allow", ctx do
      assert {:error, "Only a follow-up's card offers Always allow; nothing ran."} =
               Proposals.decide("cpr_9a0b1c2d3e4f5a6b7c8d9e0f", :always_allow, @app, opts(ctx))
    end
  end

  # --- fixtures --------------------------------------------------------------------------

  defp follow_up_watcher!(ctx) do
    params = %{
      name: "codex-limits",
      filter: "none",
      daily_cap: 5,
      sources: [ctx.ref],
      follow_up: %{name: "Codex review", prompt: @prompt, allowed_tools: ["shell"]}
    }

    {:ok, %{watcher: watcher}} = Watchers.create(params, context(), opts(ctx))
    watcher
  end

  # A passing item's card, offered through a sender that answers `token`'s digest.
  defp offer!(ctx, token) do
    pass!(ctx, 1)

    {:ok, [trigger]} =
      Repo.cues_call(CuesFollowUpSql, {:claim_offers, @now, 10}, server: ctx.repo)

    assert :offered = FollowUps.offer(trigger, offer_opts(ctx, token))
    trigger
  end

  defp pass!(ctx, n) do
    item =
      item!(
        %{
          item_id: "post-#{n}",
          subject: "post-#{n}",
          data: %{"text" => "Limits reset #{n}"},
          occurred_at: @now
        },
        @now
      )

    {:ok, _results} =
      Ingest.accept(%{ref: ctx.ref, daily_budget: 0}, [item],
        now: @now,
        repo: ctx.repo,
        wake_scheduler: fn -> :ok end,
        wake_filters: fn -> :ok end
      )
  end

  defp states(ctx, watcher) do
    ctx.conn
    |> rows(
      "SELECT state, mode, reason, decided_from FROM cue_follow_up_triggers " <>
        "WHERE watcher_id = ? ORDER BY rowid",
      [watcher.id]
    )
    |> Enum.map(fn [state, mode, reason, decided_from] ->
      %{state: state, mode: mode, reason: reason, decided_from: decided_from}
    end)
  end

  defp run_attrs(job_id) do
    %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job_id,
      session_id: "cron_#{job_id}",
      trigger: "watcher",
      status: "queued",
      claimed_at: @now,
      delivery_status: "none",
      created_at: @now,
      updated_at: @now
    }
  end

  defp context do
    %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1", :root},
      session_id: "telegram:chat-1:root",
      source_trust: :operator,
      memory_agent_id: "main"
    }
  end

  defp opts(ctx) do
    test = self()

    [
      repo: ctx.repo,
      now: @now,
      scheduler: nil,
      cues_config: [],
      capability_registry: ctx.registry,
      # The follow-ups report to Telegram, which the test config leaves off.
      channel_ready?: fn :telegram -> true end,
      wake_scheduler: fn -> send(test, :woken) end,
      proposal_listener: fn event -> send(test, {:event, event}) end
    ]
  end

  defp offer_opts(ctx, token) do
    opts(ctx) ++
      [notice: fn _watcher, _kind, _data -> :ok end, follow_up_sender: sender(token)]
  end

  defp sender(token) do
    test = self()

    fn card ->
      send(test, {:card, card})
      {:ok, Map.put(@owner, :token_digest, Proposals.digest(token))}
    end
  end

  defp tool(name) do
    Capability.new(%{
      name: name,
      description: "a test tool",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :never, []},
      policy_class: :exec
    })
  end
end
