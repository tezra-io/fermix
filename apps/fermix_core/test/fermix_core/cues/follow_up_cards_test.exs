defmodule FermixCore.Cues.FollowUpCardsTest do
  @moduledoc """
  A follow-up's card on its way to the owner (M60_WATCHER_CODING_RUNS.md
  §4.5): a sender that crashes is a send that failed, logged with every `cp_`
  token taken out, so a log never carries what answers a card.
  """
  # Asserts on the log, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql

  @now ~U[2026-10-30 12:00:00.000000Z]

  setup do
    ctx = start_repo("follow_up_cards")
    registry = :"follow_up_cards_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, tool("shell"))
    Map.merge(ctx, %{registry: registry, ref: "x-feed-#{System.unique_integer([:positive])}"})
  end

  test "a card's sender that crashes is logged with no token in the log", ctx do
    _watcher = watcher!(ctx)
    pass!(ctx)

    {:ok, [trigger]} =
      Repo.cues_call(CuesFollowUpSql, {:claim_offers, @now, 10}, server: ctx.repo)

    token = Proposals.new_token()

    opts =
      opts(ctx) ++
        [notice: fn _watcher, _kind, _data -> :ok end, follow_up_sender: raising(token)]

    log = capture_log(fn -> assert :refused = FollowUps.offer(trigger, opts) end)

    assert log =~ "The follow-up sender crashed"
    assert log =~ "cp_…"
    refute log =~ token
  end

  # A sender that wrote its token, then raised with it in the reason.
  defp raising(token), do: fn _card -> raise "the chat refused the card #{token}" end

  defp watcher!(ctx) do
    params = %{
      name: "codex-limits",
      filter: "none",
      daily_cap: 5,
      sources: [ctx.ref],
      follow_up: %{
        name: "Codex review",
        prompt: "Review the last day's commits on dev.",
        allowed_tools: ["shell"]
      }
    }

    context = %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1", :root},
      session_id: "telegram:chat-1:root",
      source_trust: :operator,
      memory_agent_id: "main"
    }

    {:ok, %{watcher: watcher}} = Watchers.create(params, context, opts(ctx))
    watcher
  end

  defp pass!(ctx) do
    item = item!(%{item_id: "post-1", data: %{"text" => "Limits reset"}, occurred_at: @now}, @now)

    {:ok, _results} =
      Ingest.accept(%{ref: ctx.ref, daily_budget: 0}, [item],
        now: @now,
        repo: ctx.repo,
        wake_scheduler: fn -> :ok end,
        wake_filters: fn -> :ok end
      )
  end

  defp opts(ctx) do
    [
      repo: ctx.repo,
      now: @now,
      scheduler: nil,
      cues_config: [],
      capability_registry: ctx.registry,
      # The follow-ups report to Telegram, which the test config leaves off.
      channel_ready?: fn :telegram -> true end,
      proposal_listener: fn _event -> :ok end
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
