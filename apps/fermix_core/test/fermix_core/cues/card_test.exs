defmodule FermixCore.Cues.CardTest do
  @moduledoc """
  The compact card (M60_WATCHER_CODING_RUNS.md §6): a follow-up's card (§6.1),
  an automatic follow-up's approval prompt (§3.4) and a mandate's proposal
  (§6.3), one layout made for a phone. Pure.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Card

  @now ~U[2026-10-30 14:02:00Z]
  @chat %{platform: "telegram", chat_id: "owner-1", user_id: "owner-1"}
  @opts [now: @now, chat: @chat, personalization: [timezone: "Etc/UTC"]]
  @instructions "Use Codex in ~/projects/fermix to review the last day's commits on dev and " <>
                  "report the findings to me, with a short list of what to look at first."

  describe "a follow-up's card (§6.1)" do
    test "asks whether now, with the item quoted, the reason, the instructions cut, the expiry" do
      card = Card.follow_up(follow_up(), @opts)

      assert [
               ~s(Run "Codex review"?),
               quote,
               "Why: the post says usage limits reset.",
               will,
               "Expires 2:32 PM UTC · reports here"
             ] = card.lines

      assert quote =~ ~s(❝ @limits_bot, 2 min ago: ")
      assert String.length(quote) < 130
      assert String.ends_with?(quote, ~s(…"))
      assert String.starts_with?(will, "It will: Use Codex in ~/projects/fermix")
      assert String.length(will) == String.length("It will: ") + 120
      assert card.actions == %{confirm: "▶ Run", deny: "Skip"}
    end

    test "keeps the whole item, the whole instructions, the tools and the delivery in Details" do
      card = Card.follow_up(follow_up(), @opts)

      assert String.starts_with?(card.detail, "Details\n")
      assert card.detail =~ long_post()
      assert card.detail =~ @instructions
      assert card.detail =~ "Uses: codex_run"
      assert card.detail =~ "Reports to: this chat"
      assert card.detail =~ "Watcher: codex-limits"
      refute card.detail =~ "{"
    end

    test "leaves Why out for a watcher with no filter, and names where else it reports" do
      elsewhere = %{mode: "channel", target: %{"platform" => "slack", "channel_id" => "C1"}}

      card =
        follow_up()
        |> put_in([:outside, :reason], nil)
        |> put_in([:follow_up, :delivery], elsewhere)
        |> Card.follow_up(@opts)

      refute Enum.any?(card.lines, &String.starts_with?(&1, "Why:"))
      assert List.last(card.lines) =~ "· reports to Slack"
      assert card.detail =~ "Reports to: Slack (C1)"
    end

    test "cuts the item in Details to what a chat takes, never the instructions" do
      huge = String.duplicate("word ", 2_000)
      card = follow_up() |> put_in([:outside, :text], huge) |> Card.follow_up(@opts)

      assert String.length(Card.text(card)) <= Card.max_chars()
      assert card.detail =~ @instructions
    end

    test "for a chat with no buttons is the lines, the detail and the bare reply" do
      spec = follow_up() |> Card.follow_up(@opts) |> Card.spec("cp_token")

      assert spec.kind == :follow_up
      assert spec.token == "cp_token"
      assert String.ends_with?(spec.text, "Reply /confirm to run or /deny to skip.")
      assert spec.text =~ ~s(Run "Codex review"?\n)
      refute spec.text =~ "cp_token"
    end

    test "after a tap becomes one line naming the item" do
      assert Card.starting(follow_up(), @opts) ==
               ~s(Starting "Codex review" for @limits_bot's post · 2:02 PM UTC)

      assert Card.skipped(follow_up()) == ~s(Skipped "Codex review"; it did not run.)
    end

    test "confirmed and then refused, it tells the owner why it did not start" do
      refused =
        %{follow_up() | state: "refused"} |> Map.put(:reason, "Not started: it is paused.")

      assert Card.not_started(refused) ==
               ~s(Watcher codex-limits: "Codex review" for @limits_bot's post did not start. ) <>
                 "Not started: it is paused."
    end
  end

  describe "an automatic follow-up's prompt (§3.4)" do
    test "names what it runs, how often at most, and in Details what it is bound to" do
      card = Card.approval(approval(), @opts)

      assert [first, cost, "Expires 2:32 PM UTC"] = card.lines

      assert first =~
               ~s(Automatic follow-up for codex-limits: whenever an item passes, run "Codex review")

      assert first =~ "with no card."

      assert cost ==
               "That is a run with codex_run each time, at most 5 a day (the watcher's daily cap)."

      assert card.actions == %{confirm: "✅ Approve", deny: "❌ Keep asking"}
      assert card.detail =~ @instructions
      assert card.detail =~ "Set off by: x-feed; listens for reset, limits"
      assert Card.text(card) =~ "Reply /confirm to approve or /deny to keep asking."
      assert Card.approved(approval()) =~ ~s(Approved: "Codex review" runs on its own, at most 5)
    end
  end

  describe "a mandate's card (§6.3)" do
    test "shows every argument as name: value, cut on its line and whole in Details" do
      body =
        "Kestrel 2.4 changes the cache key format; " <> String.duplicate("upgrade notes ", 20)

      args = %{"title" => "Kestrel 2.4: breaking cache change", "body" => body, "labels" => ["a"]}
      card = Card.mandate(mandate(args), @opts)

      assert hd(card.lines) == "Run github_create_issue for release-watch?"
      assert "title: Kestrel 2.4: breaking cache change" in card.lines
      assert ~s(labels: ["a"]) in card.lines

      body_line = Enum.find(card.lines, &String.starts_with?(&1, "body: "))
      assert String.length(body_line) == String.length("body: ") + 80
      assert List.last(card.lines) == "Expires 2:32 PM UTC"

      assert String.starts_with?(card.detail, "Every argument, whole, and the whole item\n")
      assert card.detail =~ "body: " <> body
      assert card.detail =~ "Kestrel 2.4 released with a breaking cache change."
      assert card.detail =~ "Mandate: release-issues · task: release issues"
      refute Card.text(card) =~ "untrusted_tool_result"
    end
  end

  defp long_post,
    do:
      "Codex usage limits have been reset for Plus and Pro, so anything you queued " <>
        "yesterday can run again today, and the weekly window starts over."

  defp follow_up do
    %{
      trigger_id: "cft_1",
      state: "waiting",
      expires_at: ~U[2026-10-30 14:32:00Z],
      watcher: %{id: "cwt_1", name: "codex-limits"},
      follow_up: %{
        job_id: "job_1",
        name: "Codex review",
        instructions: @instructions,
        tools: ["codex_run"],
        delivery: %{mode: "origin", target: %{"platform" => "telegram", "chat_id" => "owner-1"}}
      },
      outside: %{
        source_ref: "x-feed",
        received_at: ~U[2026-10-30 14:00:30Z],
        occurred_at: ~U[2026-10-30 14:00:00Z],
        type: "x.post",
        subject: "@limits_bot",
        text: long_post(),
        reason: "the post says usage limits reset."
      }
    }
  end

  defp approval do
    %{
      id: "cfa_1",
      shown_digest: "d",
      watcher_name: "codex-limits",
      expires_at: ~U[2026-10-30 14:32:00Z],
      daily_cap: 5,
      sources: ["x-feed"],
      listen_for: ["reset", "limits"],
      job_id: "job_1",
      job_name: "Codex review",
      task_prompt: @instructions,
      allowed_tools: ["codex_run"],
      delivery_mode: "origin",
      delivery_target: %{"platform" => "telegram", "chat_id" => "owner-1"}
    }
  end

  defp mandate(args) do
    %{
      tool: "github_create_issue",
      args: args,
      mandate: "release-issues",
      task: "release issues",
      cue: %{
        watcher_name: "release-watch",
        source_ref: "eng-blogs",
        subject: "kestrel",
        occurred_at: ~U[2026-10-30 13:59:00Z],
        received_at: ~U[2026-10-30 13:59:30Z],
        decision_reason: "A release with a breaking change."
      },
      snapshot:
        ~s({"subject":"eng-blogs","text":"Kestrel 2.4 released with a breaking cache change."}),
      expires_at: ~U[2026-10-30 14:32:00Z]
    }
  end
end
