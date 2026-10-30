defmodule FermixCore.Cues.FollowUpsTest do
  @moduledoc """
  Watcher follow-ups (M60_WATCHER_CODING_RUNS.md §4, §5, §9): a passing item
  writes one trigger keyed by its delivery, within freshness, the daily cap and
  one waiting card; a task-less watcher settles its item at once; an automatic
  follow-up runs alone only while its approval's digest holds; the card's
  answers, the hold, the expiry, the notices and the follow-up's lifecycle.
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.CueAdmission
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixCore.Memory.Repo.CuesRunsSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Tools.JobRegistrySupport
  alias FermixCore.Tools.ListJobs
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-30 12:00:00.000000Z]
  @token "cp_follow-up-test-token"
  @owner %{platform: "telegram", chat_id: "chat-1", user_id: "owner-1"}
  @prompt "Review the last day's commits on dev and report the findings."

  defmodule RecordingDelivery do
    @moduledoc false
    def send_message(target, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delivered, target, text})
      :ok
    end
  end

  setup do
    ctx = start_repo("follow_ups")
    registry = :"follow_ups_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, tool("shell"))
    Map.merge(ctx, %{registry: registry, ref: "x-feed-#{System.unique_integer([:positive])}"})
  end

  # --- triggers (§4.3, §4.4) -------------------------------------------------------

  describe "a passing item" do
    test "writes one trigger keyed by its delivery; a task-less watcher's item settles", ctx do
      watcher = follow_up_watcher!(ctx)
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: watcher.id)

      pass!(ctx, 1)
      pass!(ctx, 1)

      assert [%{state: "waiting", mode: "approve", expires_at: expires_at}] =
               triggers(ctx, watcher)

      assert expires_at == DateTime.add(@now, 30 * 60, :second)
      assert [["acked", "follow_up"]] = deliveries(ctx, watcher)

      assert_receive {:telemetry, _event, _measurements,
                      %{phase: :follow_up_triggered, state: "waiting", reason: "ask_first"} =
                        meta}

      assert meta.outcome == "follow_up"
      refute_received {:telemetry, _event, _measurements, %{phase: :follow_up_triggered}}
    end

    test "older than 15 minutes, it sets nothing off", ctx do
      watcher = follow_up_watcher!(ctx)

      pass!(ctx, 1, DateTime.add(@now, -16 * 60, :second))
      pass!(ctx, 2, DateTime.add(@now, -5 * 60, :second))

      assert [
               %{state: "skipped", reason: "The item is older than 15 minutes."},
               %{state: "waiting"}
             ] = triggers(ctx, watcher)
    end

    test "while a card waits, the next item is skipped and nothing is proposed", ctx do
      watcher = follow_up_watcher!(ctx)

      pass!(ctx, 1)
      pass!(ctx, 2)
      [first, second] = triggers(ctx, watcher)
      assert second.state == "skipped"
      assert second.reason == "A card for this follow-up is already waiting."

      assert {:ok, %{state: "skipped"}} =
               FollowUps.decide(first.id, :deny, "companion", opts(ctx))

      pass!(ctx, 3)
      assert [_first, _second, %{state: "waiting"}] = triggers(ctx, watcher)
    end

    test "the daily cap counts follow-ups started or proposed, never one skipped", ctx do
      watcher = follow_up_watcher!(ctx, daily_cap: 2, mode: "auto")
      approve!(ctx, watcher)

      pass!(ctx, 1, DateTime.add(@now, -20 * 60, :second))
      pass!(ctx, 2)
      pass!(ctx, 3)
      pass!(ctx, 4)

      assert [
               %{state: "skipped"},
               %{state: "starting", mode: "auto"},
               %{state: "starting"},
               %{state: "skipped", reason: "The watcher's daily cap of 2 is reached."}
             ] = triggers(ctx, watcher)
    end

    test "task runs and follow-ups share one cap, from either side", ctx do
      watcher = follow_up_watcher!(ctx, daily_cap: 1, task: "Tell me about it.")
      insert_cue_run!(ctx, watcher.task_job_id, DateTime.add(@now, -3_600, :second))

      pass!(ctx, 1)

      assert [%{state: "skipped", reason: "The watcher's daily cap of 1 is reached."}] =
               triggers(ctx, watcher)

      other = follow_up_watcher!(ctx, name: "other", daily_cap: 1, task: "Tell me.", ref: "o")
      pass!(ctx, 2, @now, "o")
      assert [%{state: "waiting"}] = triggers(ctx, other)

      # The other watcher's task is held by its follow-up's card alone.
      assert {:ok, %{candidates: [], capped: capped}} =
               Repo.cues_call(CuesRunsSql, {:admission_candidates, @now, 3}, server: ctx.repo)

      assert Enum.sort(Enum.map(capped, & &1.watcher_id)) == Enum.sort([watcher.id, other.id])
    end
  end

  # --- automatic and its approval (§3.4, §5) ------------------------------------------

  describe "an automatic follow-up" do
    test "needs the watcher's daily cap, and Fermix suggests 5", ctx do
      sentence =
        "An automatic follow-up needs a daily cap on the watcher: say how many runs a day it " <>
          "may cause (Fermix suggests 5)."

      assert {:error, ^sentence} =
               Watchers.create(
                 params(ctx, %{
                   filter: "llm",
                   purpose: "limits",
                   listen_for: ["reset"],
                   daily_cap: "none",
                   follow_up: follow_up_params(%{mode: "auto"})
                 }),
                 context(),
                 opts(ctx)
               )

      watcher = follow_up_watcher!(ctx, daily_cap: 3, mode: "auto")
      assert {:error, ^sentence} = Watchers.update(watcher.name, %{daily_cap: "none"}, opts(ctx))

      asking = follow_up_watcher!(ctx, name: "asking", daily_cap: 3)
      assert {:ok, _} = Watchers.update(asking.name, %{daily_cap: "none"}, opts(ctx))

      assert {:error, ^sentence} =
               Watchers.set_follow_up(asking.name, %{mode: "auto"}, context(), opts(ctx))
    end

    test "asks first until approved, then runs alone", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")

      pass!(ctx, 1)
      approve!(ctx, watcher)
      pass!(ctx, 2)

      assert [%{state: "waiting", mode: "approve"}, %{state: "starting", mode: "auto"}] =
               triggers(ctx, watcher)
    end

    test "a change to what it runs or what sets it off leaves the approval behind", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")
      job_id = watcher.follow_up_job_id

      # Approved, then changed through `update_job` itself: the next item asks first.
      approve!(ctx, watcher)
      {:ok, _} = JobsRegistry.update_job(job_id, %{task_prompt: "Other."}, registry_opts(ctx))
      pass!(ctx, 1)
      assert [%{state: "waiting", mode: "approve"}] = triggers(ctx, watcher)

      changes = [
        fn ->
          Watchers.set_follow_up(
            watcher.name,
            %{prompt: "Run the deploy check."},
            context(),
            opts(ctx)
          )
        end,
        fn ->
          Watchers.set_follow_up(
            watcher.name,
            %{allowed_tools: ["shell", "web_fetch"]},
            context(),
            opts(ctx)
          )
        end,
        fn ->
          target = %{"platform" => "telegram", "chat_id" => "chat-2"}
          Watchers.set_follow_up(watcher.name, %{delivery_target: target}, context(), opts(ctx))
        end,
        fn ->
          Watchers.update(watcher.name, %{sources: [ctx.ref, "github-releases"]}, opts(ctx))
        end,
        fn ->
          Watchers.update(
            watcher.name,
            %{filter: "llm", purpose: "limit resets", listen_for: ["reset"]},
            opts(ctx)
          )
        end,
        fn ->
          JobsRegistry.update_job(job_id, %{task_prompt: "Something else."}, registry_opts(ctx))
        end
      ]

      for change <- changes do
        approve!(ctx, watcher)
        {:ok, approved} = Watchers.current_follow_up_digest(watcher.name, opts(ctx))
        assert {:ok, _changed} = change.()
        {:ok, now} = Watchers.current_follow_up_digest(watcher.name, opts(ctx))
        refute now == approved
      end
    end

    test "the approval is refused for what the owner was not shown", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")
      {:ok, shown} = Watchers.current_follow_up_digest(watcher.name, opts(ctx))

      {:ok, _} =
        Watchers.set_follow_up(watcher.name, %{prompt: "Something else."}, context(), opts(ctx))

      assert {:error, "The follow-up or what sets it off changed since you were asked" <> _} =
               Watchers.approve_follow_up(watcher.name, shown, opts(ctx))

      asking = follow_up_watcher!(ctx, name: "asking")
      {:ok, digest} = Watchers.current_follow_up_digest(asking.name, opts(ctx))

      assert {:error, "Watcher asking's follow-up asks first; make it automatic first."} =
               Watchers.approve_follow_up(asking.name, digest, opts(ctx))
    end
  end

  # --- the card and its answers (§4.5) ------------------------------------------------

  describe "the card" do
    test "goes to the sender with the item apart, and the owner's yes starts it", ctx do
      watcher = follow_up_watcher!(ctx)
      pass!(ctx, 1)
      [trigger] = claim_offers!(ctx)

      assert :offered = FollowUps.offer(trigger, offer_opts(ctx))
      assert_received {:card, card}
      assert card.watcher.name == watcher.name
      assert card.follow_up.instructions == @prompt
      assert card.follow_up.tools == ["shell"]
      assert card.outside.text =~ "Limits reset 1"
      refute inspect(Map.drop(card, [:outside])) =~ "Limits reset"
      assert_received {:notice, _watcher, :follow_up_recovered, %{}}

      # The card becomes one line naming the item (§3.3).
      assert {:ok, line} = FollowUps.confirm(@token, @owner, wake_opts(ctx))
      assert line =~ ~s(Running "Codex review" for the item from post-1 · )
      assert_received :woken

      assert [%{state: "starting", decided_from: "telegram:chat-1:owner-1"}] =
               triggers(ctx, watcher)

      assert {:error, "That follow-up is already starting."} =
               FollowUps.confirm(@token, @owner, wake_opts(ctx))
    end

    test "answers only from the chat it went to, and not once it expired", ctx do
      watcher = follow_up_watcher!(ctx)
      pass!(ctx, 1)
      [trigger] = claim_offers!(ctx)
      :offered = FollowUps.offer(trigger, offer_opts(ctx))

      stranger = %{@owner | chat_id: "chat-9"}

      assert {:error, "Answer it from the chat Fermix sent it to; nothing ran."} =
               FollowUps.confirm(@token, stranger, opts(ctx))

      assert {:ok, []} = FollowUps.waiting_in_chat(stranger, opts(ctx))
      assert {:ok, [%{id: id}]} = FollowUps.waiting_in_chat(@owner, opts(ctx))
      assert id == trigger.id

      late = Keyword.put(opts(ctx), :now, DateTime.add(@now, 31 * 60, :second))
      assert {:error, "That card expired; nothing ran."} = FollowUps.confirm(@token, @owner, late)
      assert [%{state: "waiting"}] = triggers(ctx, watcher)
    end

    test "the owner's no skips it; an app answers by id; an unknown origin changes nothing",
         ctx do
      watcher = follow_up_watcher!(ctx)
      pass!(ctx, 1)
      [trigger] = claim_offers!(ctx)
      :offered = FollowUps.offer(trigger, offer_opts(ctx))

      assert {:error, "Fermix does not know where that answer came from; nothing changed."} =
               FollowUps.decide(trigger.id, :confirm, "somewhere", opts(ctx))

      assert {:ok, ~s(Skipped "Codex review"; it did not run.)} =
               FollowUps.deny(@token, @owner, opts(ctx))

      assert [%{state: "skipped", reason: "You skipped it."}] = triggers(ctx, watcher)

      assert {:error, "That card was skipped; nothing ran."} =
               FollowUps.decide(trigger.id, :confirm, "mobile:phone-1", opts(ctx))
    end

    test "nobody's answer in 30 minutes expires it; nothing runs", ctx do
      watcher = follow_up_watcher!(ctx)
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: watcher.id)
      pass!(ctx, 1)

      repo_opts = [server: ctx.repo]
      assert {:ok, 0} = FollowUps.expire(repo_opts, DateTime.add(@now, 29 * 60, :second), 100)
      assert {:ok, 1} = FollowUps.expire(repo_opts, DateTime.add(@now, 30 * 60, :second), 100)

      assert [%{state: "expired", reason: "It expired with no answer."}] = triggers(ctx, watcher)
      assert_receive {:telemetry, _event, _measurements, %{phase: :follow_up_expired}}
    end

    test "a send that fails, or no sender, refuses the card", ctx do
      _watcher = follow_up_watcher!(ctx)
      pass!(ctx, 1)
      [trigger] = claim_offers!(ctx)

      failing = Keyword.put(offer_opts(ctx), :follow_up_sender, fn _card -> {:error, :down} end)
      assert :refused = FollowUps.offer(trigger, failing)

      assert [
               %{
                 state: "refused",
                 reason: "Fermix could not reach you, so the card was not sent."
               }
             ] =
               triggers(ctx, trigger)
    end
  end

  # --- held (§4.6) ---------------------------------------------------------------------

  describe "a held follow-up" do
    test "is refused while the switch is off, with one held notice", ctx do
      watcher = follow_up_watcher!(ctx)
      pass!(ctx, 1)
      [trigger] = claim_offers!(ctx)
      off = Keyword.put(offer_opts(ctx), :cues_config, mandates_enabled: false)

      assert :refused = FollowUps.offer(trigger, off)

      assert [
               %{
                 state: "refused",
                 reason: "Watchers may not act: \"Let watchers act\" is off " <> _
               }
             ] =
               triggers(ctx, watcher)

      assert_received {:notice, _id, :follow_up_held, %{reason: "Watchers may not act" <> _}}
      refute_received {:card, _card}
    end

    test "is refused while a tool it names is not set up, naming the tool", ctx do
      watcher = follow_up_watcher!(ctx, tools: ["shell", "codex_run"])
      pass!(ctx, 1)
      [trigger] = claim_offers!(ctx)

      assert :refused = FollowUps.offer(trigger, offer_opts(ctx))
      assert [%{reason: "codex_run is not set up on this computer" <> _}] = triggers(ctx, watcher)
    end

    test "the held and recovered notices go once each, through the follow-up's delivery", ctx do
      watcher = follow_up_watcher!(ctx)
      notice_opts = notice_opts(ctx)

      assert :sent =
               Notices.watcher(watcher.id, :follow_up_held, %{reason: "It is held."}, notice_opts)

      assert_received {:delivered, "chat-1", "Watcher " <> held}
      assert held =~ "its follow-up is held and starts nothing. It is held."

      assert :already_sent =
               Notices.watcher(watcher.id, :follow_up_held, %{reason: "Again."}, notice_opts)

      assert :sent = Notices.watcher(watcher.id, :follow_up_recovered, %{}, notice_opts)
      assert_received {:delivered, _target, "Watcher " <> _recovered}
      assert :already_sent = Notices.watcher(watcher.id, :follow_up_recovered, %{}, notice_opts)
    end
  end

  # --- a task-less watcher's notices (§4.6) ---------------------------------------------

  test "a watcher with no task gets its notices through its follow-up's delivery", ctx do
    watcher = follow_up_watcher!(ctx, daily_cap: 2)
    assert watcher.task_job_id == nil

    assert :sent = Notices.watcher(watcher.id, :cap_reached, %{cap: 2}, notice_opts(ctx))
    assert_received {:delivered, "chat-1", text}
    assert text =~ "reached its daily cap of 2 runs"
  end

  # Nothing of a task-less watcher waits for the cap (its items settle as they
  # pass), so the admission pass reads the skip off its triggers. Every item
  # here is accepted at one time, as one batch is.
  test "a task-less watcher whose cap skips an item is told once a window, through its " <>
         "follow-up's delivery",
       ctx do
    watcher = follow_up_watcher!(ctx, daily_cap: 1)
    notice = &Notices.watcher(&1, &2, &3, notice_opts(ctx))

    admit = fn ->
      CueAdmission.claim(3, @now, &%{id: &1},
        repo_opts: [server: ctx.repo],
        cue_notice: notice
      )
    end

    # A stale item skipped before the cap was spent, then the card that spends it.
    pass!(ctx, 1, DateTime.add(@now, -16 * 60, :second))
    pass!(ctx, 2)
    assert admit.() == []
    refute_received {:delivered, _target, _text}

    pass!(ctx, 3)

    assert [
             _stale,
             %{state: "waiting"},
             %{state: "skipped", reason: "The watcher's daily cap" <> _}
           ] =
             triggers(ctx, watcher)

    assert admit.() == []
    assert_received {:delivered, "chat-1", text}

    assert text ==
             "Watcher codex-limits: it reached its daily cap of 1 runs; until there is room, " <>
               "the items it passes start no follow-up."

    pass!(ctx, 4)
    assert admit.() == []
    refute_received {:delivered, _target, _text}
  end

  # --- lifecycle (§4.1, §5) ---------------------------------------------------------------

  describe "the follow-up's lifecycle" do
    test "a watcher is made with only a follow-up, and needs a task or a follow-up", ctx do
      watcher = follow_up_watcher!(ctx)
      assert {:ok, job} = JobsRegistry.get_job(watcher.follow_up_job_id, repo: ctx.repo)
      assert JobsRegistry.follow_up_job?(job)
      assert job.allowed_tools == ["shell"]
      assert job.delivery_target["chat_id"] == "chat-1"

      assert {:error, "Give the watcher a task: " <> _} =
               Watchers.create(params(ctx, %{name: "neither"}), context(), opts(ctx))
    end

    test "its job is its watcher's: the watcher guards update_job and remove_job on it", ctx do
      watcher = follow_up_watcher!(ctx)
      job_id = watcher.follow_up_job_id
      turn = %{memory_repo: ctx.repo, source_trust: :operator}

      assert {:ok, %{id: id}} = Watchers.watcher_for_job(job_id, opts(ctx))
      assert id == watcher.id

      assert {:error, "Remove the watcher first" <> _} =
               JobRegistrySupport.check_unwatched(job_id, turn)

      assert {:error, "Watcher " <> _} = JobRegistrySupport.check_watcher_consent(job_id, turn)
    end

    test "list_jobs says what sets a follow-up off, in place of a schedule", ctx do
      watcher = follow_up_watcher!(ctx)

      {:ok, unwatched} =
        JobsRegistry.create_follow_up_job(
          %{
            created_by_trust: "operator",
            name: "Spare review",
            task_prompt: @prompt,
            allowed_tools: ["shell"],
            delivery_mode: "origin",
            delivery_target: %{"platform" => "telegram", "chat_id" => "chat-1"}
          },
          registry_opts(ctx)
        )

      assert {:ok, %{output: output}} =
               ListJobs.execute(%{}, Map.put(context(), :memory_repo, ctx.repo))

      jobs = Map.new(Jason.decode!(output)["jobs"], &{&1["id"], &1})

      assert jobs[watcher.follow_up_job_id]["schedule_label"] ==
               "runs when watcher codex-limits passes an item"

      assert jobs[unwatched.id]["schedule_label"] == "runs when its watcher passes an item"
    end

    test "removing the watcher removes its follow-up's job and refuses its waiting card", ctx do
      watcher = follow_up_watcher!(ctx)
      pass!(ctx, 1)

      assert {:ok, %{echo: echo}} = Watchers.remove(watcher.name, opts(ctx))
      assert echo =~ "Its follow-up job #{watcher.follow_up_job_id} is removed."
      assert {:error, :not_found} = JobsRegistry.get_job(watcher.follow_up_job_id, repo: ctx.repo)

      assert [%{state: "refused", reason: "Not started: the watcher was removed."}] =
               triggers(ctx, watcher)
    end

    test "removing waits for a follow-up that is running", ctx do
      watcher = follow_up_watcher!(ctx)
      insert_run!(ctx, watcher.follow_up_job_id, "watcher", "running", @now)

      assert {:error, "Watcher " <> refusal} = Watchers.remove(watcher.name, opts(ctx))
      assert refusal =~ "follow-up is running right now"
    end

    test "stopping the follow-up keeps the task; a task-less watcher cannot stop it", ctx do
      alone = follow_up_watcher!(ctx)

      assert {:error, "A watcher needs a task or a follow-up" <> _} =
               Watchers.remove_follow_up(alone.name, opts(ctx))

      both = follow_up_watcher!(ctx, name: "both", task: "Tell me.", ref: "b")
      assert {:ok, _stopped} = Watchers.remove_follow_up(both.name, opts(ctx))
      assert {:ok, shown} = Watchers.show(both.name, opts(ctx))
      assert {shown.follow_up_job_id, shown.follow_up_mode} == {nil, nil}
      assert {:error, :not_found} = JobsRegistry.get_job(both.follow_up_job_id, repo: ctx.repo)
    end
  end

  # --- fixtures --------------------------------------------------------------------------

  defp follow_up_watcher!(ctx, attrs \\ []) do
    follow_up =
      follow_up_params(%{
        mode: Keyword.get(attrs, :mode, "approve"),
        allowed_tools: Keyword.get(attrs, :tools, ["shell"])
      })

    params =
      params(ctx, %{
        name: Keyword.get(attrs, :name, "codex-limits"),
        daily_cap: Keyword.get(attrs, :daily_cap, 5),
        sources: [Keyword.get(attrs, :ref, ctx.ref)],
        follow_up: follow_up
      })

    params =
      case Keyword.fetch(attrs, :task) do
        {:ok, task} -> Map.put(params, :task, task)
        :error -> params
      end

    {:ok, %{watcher: watcher}} = Watchers.create(params, context(), opts(ctx))
    watcher
  end

  defp params(ctx, extra),
    do:
      Map.merge(%{name: "codex-limits", filter: "none", daily_cap: 5, sources: [ctx.ref]}, extra)

  defp follow_up_params(extra),
    do: Map.merge(%{name: "Codex review", prompt: @prompt, allowed_tools: ["shell"]}, extra)

  defp approve!(ctx, watcher) do
    {:ok, digest} = Watchers.current_follow_up_digest(watcher.name, opts(ctx))
    {:ok, _approved} = Watchers.approve_follow_up(watcher.name, digest, opts(ctx))
  end

  defp pass!(ctx, n, occurred_at \\ @now, ref \\ nil) do
    item =
      item!(
        %{
          item_id: "post-#{n}",
          subject: "post-#{n}",
          data: %{"text" => "Limits reset #{n}"},
          occurred_at: occurred_at
        },
        @now
      )

    {:ok, _results} =
      Ingest.accept(%{ref: ref || ctx.ref, daily_budget: 0}, [item],
        now: @now,
        repo: ctx.repo,
        wake_scheduler: fn -> :ok end,
        wake_filters: fn -> :ok end
      )
  end

  defp claim_offers!(ctx) do
    {:ok, triggers} =
      Repo.cues_call(CuesFollowUpSql, {:claim_offers, @now, 10}, server: ctx.repo)

    triggers
  end

  # A trigger map (it names its watcher) or a watcher map.
  defp triggers(ctx, %{watcher_id: watcher_id}), do: triggers(ctx, %{id: watcher_id})

  defp triggers(ctx, %{id: watcher_id}) do
    ctx.conn
    |> rows(
      "SELECT id, state, mode, reason, expires_at, decided_from FROM cue_follow_up_triggers " <>
        "WHERE watcher_id = ? ORDER BY rowid",
      [watcher_id]
    )
    |> Enum.map(fn [id, state, mode, reason, expires_at, decided_from] ->
      %{
        id: id,
        state: state,
        mode: mode,
        reason: reason,
        expires_at: CuesSql.parse_stamp(expires_at),
        decided_from: decided_from
      }
    end)
  end

  defp deliveries(ctx, watcher) do
    rows(ctx.conn, "SELECT state, outcome FROM cue_deliveries WHERE watcher_id = ? ORDER BY id", [
      watcher.id
    ])
  end

  defp insert_cue_run!(ctx, job_id, at), do: insert_run!(ctx, job_id, "cue", "ok", at)

  defp insert_run!(ctx, job_id, trigger, status, at) do
    exec!(
      ctx.conn,
      """
      INSERT INTO job_runs (id, job_id, session_id, trigger, status, claimed_at, delivery_status,
        created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 'none', ?, ?)
      """,
      [
        "run_#{System.unique_integer([:positive])}",
        job_id,
        "cron_#{job_id}",
        trigger,
        status,
        DateTime.to_iso8601(at),
        DateTime.to_iso8601(at),
        DateTime.to_iso8601(at)
      ]
    )
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

  defp opts(ctx),
    do: [
      repo: ctx.repo,
      now: @now,
      scheduler: nil,
      cues_config: [],
      capability_registry: ctx.registry
    ]

  defp registry_opts(ctx), do: [repo: ctx.repo, scheduler: nil]

  defp wake_opts(ctx), do: opts(ctx) ++ [wake_scheduler: fn -> send(self(), :woken) end]

  defp offer_opts(ctx) do
    test = self()

    opts(ctx) ++
      [
        notice: fn watcher_id, kind, data -> send(test, {:notice, watcher_id, kind, data}) end,
        follow_up_sender: fn card ->
          send(test, {:card, card})

          {:ok,
           %{
             token_digest: :sha256 |> :crypto.hash(@token) |> Base.encode16(case: :lower),
             platform: @owner.platform,
             chat_id: @owner.chat_id,
             user_id: @owner.user_id
           }}
        end
      ]
  end

  defp notice_opts(ctx) do
    [
      repo: ctx.repo,
      now: @now,
      adapter: RecordingDelivery,
      delivery_opts: [test_pid: self()]
    ]
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
