defmodule FermixCore.Cues.FollowUpAnswersTest do
  @moduledoc """
  Answering a watcher's follow-up (M60_WATCHER_CODING_RUNS.md §3.4, §4.5, §5,
  §6.2, §9): every `cp_` token goes through `Cues.Proposals`, the one place
  answers go, which hands a follow-up's card to `Cues.FollowUps` and an
  automatic follow-up's approval prompt to `Cues.FollowUpApprovals`; a card's
  id answers only from the chat it waits in (the bare `/confirm`); the app
  surfaces are offered each card and told its end; and the approval applies
  only what the prompt showed.
  """
  use ExUnit.Case, async: true

  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUpApprovals
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql

  @now ~U[2026-10-30 12:00:00.000000Z]
  @owner %{platform: "telegram", chat_id: "chat-1", user_id: "owner-1"}
  @stranger %{platform: "telegram", chat_id: "chat-9", user_id: "owner-1"}
  @prompt "Review the last day's commits on dev and report the findings."
  @app %{surface: :companion, device_id: nil}

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
      assert line =~ ~s(Running "Codex review" for the item from post-1)
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

      assert {:ok, "Running" <> _rest} = Proposals.confirm(trigger.id, @owner, opts(ctx))

      assert [%{state: "starting", decided_from: "telegram:chat-1:owner-1"}] =
               states(ctx, watcher)
    end

    # §4.2: one active run per job, and the card says so at the tap.
    test "a yes while the follow-up runs is refused at once, and the card says so", ctx do
      watcher = follow_up_watcher!(ctx)
      _trigger = offer!(ctx, "cp_card-four")

      exec!(ctx.conn, "UPDATE scheduled_jobs SET state = 'running' WHERE id = ?", [
        watcher.follow_up_job_id
      ])

      assert {:ok, "Not started: it is already running."} =
               Proposals.confirm("cp_card-four", @owner, opts(ctx))

      assert [%{state: "refused", reason: "Not started: it is already running."}] =
               states(ctx, watcher)

      refute_received :woken
      assert_received {:event, {:resolved, %{state: "refused"}}}
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

  # --- the automatic approval's prompt (§3.4, §5) ----------------------------------------

  describe "an automatic follow-up's prompt" do
    test "is refused for a follow-up that asks first", ctx do
      watcher = follow_up_watcher!(ctx)

      assert {:error, "Watcher codex-limits's follow-up asks first; make it automatic first."} =
               FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_unused"))
    end

    test "goes to the sender, and the owner's yes approves exactly what it showed", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")

      assert {:ok, "Fermix sent you a prompt to approve it" <> _rest} =
               FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_prompt-one"))

      assert_received {:card, card}
      assert card.watcher_name == watcher.name
      assert card.daily_cap == 5
      assert card.task_prompt == @prompt
      assert card.sources == [ctx.ref]
      assert_received {:event, {:offered, %{follow_up: %{asks: "automatic", daily_cap: 5}}}}

      assert {:ok, [%{kind: :approval}]} = Proposals.waiting_in_chat(@owner, opts(ctx))

      assert {:ok, ~s(Approved: "Codex review" runs on its own, at most 5 a day.)} =
               Proposals.confirm("cp_prompt-one", @owner, opts(ctx))

      assert_received {:event, {:resolved, %{state: "confirmed"}}}
      pass!(ctx, 1)
      assert [%{state: "starting"}] = states(ctx, watcher)
    end

    test "a change since the prompt approves nothing, and it keeps asking first", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")
      {:ok, _sent} = FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_prompt-two"))

      {:ok, _} =
        Watchers.update(watcher.name, %{sources: [ctx.ref, "github-releases"]}, opts(ctx))

      assert {:error, "The follow-up or what sets it off changed since you were asked" <> _} =
               Proposals.confirm("cp_prompt-two", @owner, opts(ctx))

      pass!(ctx, 1)
      assert [%{state: "waiting", mode: "approve"}] = states(ctx, watcher)
    end

    test "the owner's no keeps it asking first", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")
      {:ok, _sent} = FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_prompt-three"))

      assert {:ok, ~s(Kept asking: each run of "Codex review" waits for your tap.)} =
               Proposals.deny("cp_prompt-three", @owner, opts(ctx))

      pass!(ctx, 1)
      assert [%{state: "waiting", mode: "approve"}] = states(ctx, watcher)
    end

    test "answers only from the chat it went to; an app answers by its id", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")
      {:ok, _sent} = FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_prompt-four"))
      assert {:ok, [%{id: id}]} = FollowUpApprovals.waiting_in_chat(@owner, opts(ctx))

      assert {:error, "Answer it from the chat Fermix sent it to."} =
               Proposals.confirm("cp_prompt-four", @stranger, opts(ctx))

      assert {:ok, %{proposal_id: ^id, state: "confirmed"}} =
               Proposals.decide(id, :confirm, @app, opts(ctx))

      assert {:error, "That prompt was already approved."} =
               Proposals.confirm("cp_prompt-four", @owner, opts(ctx))
    end

    test "a new prompt expires the one before it; nobody's answer expires the last", ctx do
      watcher = follow_up_watcher!(ctx, mode: "auto")
      {:ok, _sent} = FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_prompt-five"))
      {:ok, _sent} = FollowUpApprovals.ask(watcher.name, prompt_opts(ctx, "cp_prompt-six"))

      assert_received {:event, {:resolved, %{state: "expired"}}}

      assert {:error, "That prompt expired; each run still asks first."} =
               Proposals.confirm("cp_prompt-five", @owner, opts(ctx))

      later = DateTime.add(@now, 30 * 60, :second)
      assert {:ok, 1} = FollowUpApprovals.expire([server: ctx.repo], later, 10)
      assert {:ok, []} = FollowUpApprovals.waiting_in_chat(@owner, opts(ctx))
    end
  end

  # --- fixtures --------------------------------------------------------------------------

  defp follow_up_watcher!(ctx, attrs \\ []) do
    params = %{
      name: "codex-limits",
      filter: "none",
      daily_cap: 5,
      sources: [ctx.ref],
      follow_up: %{
        name: "Codex review",
        prompt: @prompt,
        allowed_tools: ["shell"],
        mode: Keyword.get(attrs, :mode, "approve")
      }
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
      wake_scheduler: fn -> send(test, :woken) end,
      proposal_listener: fn event -> send(test, {:event, event}) end
    ]
  end

  defp offer_opts(ctx, token) do
    opts(ctx) ++
      [notice: fn _watcher, _kind, _data -> :ok end, follow_up_sender: sender(token)]
  end

  defp prompt_opts(ctx, token), do: opts(ctx) ++ [follow_up_sender: sender(token)]

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
