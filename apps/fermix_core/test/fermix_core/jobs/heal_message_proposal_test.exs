defmodule FermixCore.Jobs.HealMessageProposalTest do
  # M106 §5.7, §5.8 and decision D5 (stages S4, S4b): a heal that proposes a
  # change states it to the owner on its card, short: what failed, in code's
  # sentence; the diagnosis's note; one line per changed field with its new
  # value only (a task as its changed part: what replaces what), every value
  # whole, since a card too long for its bound is never offered; one closing
  # line saying the change has not been made, and nothing on how to answer it
  # (the card's buttons or its reply line carry that). The card's detail
  # holds each changed field exactly, as it is and as it would become. Every
  # value on a line is quoted data. Pure and code-built; every value here is
  # invented.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealMessage

  @lisbon [personalization: [timezone: "Europe/Lisbon"]]
  @note "The harbour page moved, so each fetch waits until the limit ends it."
  @closing "Fermix has not made this change."

  @facts %{
    subject_kind: "job",
    subject_id: "job_tides",
    failure_kind: "time_limit",
    failure_text: "The run stopped at its 10-minute time limit.",
    failure_words: nil,
    opened_at: ~U[2031-03-04 07:10:00Z],
    failed_at: ~U[2031-03-04 07:10:00Z],
    run_count: 3,
    job: %{
      name: "Harbour tide table",
      enabled?: true,
      state: "scheduled",
      next_run_at: ~U[2031-03-05 07:00:00Z]
    },
    recent: %{same: 3, of: 8},
    jobs: [],
    job_count: 1,
    conclusion: "first",
    decision: "propose",
    note: @note,
    change: nil,
    tool: nil
  }

  defp ask(change, overrides \\ %{}) do
    @facts
    |> Map.merge(overrides)
    |> Map.put(:change, change)
    |> HealMessage.build(@lisbon)
  end

  defp field_lines(text) do
    [_before, after_lead] = String.split(text, "Fermix would change:\n", parts: 2)
    [fields, closing] = String.split(after_lead, "\n" <> @closing, parts: 2)
    assert closing == ""
    String.split(fields, "\n")
  end

  describe "the short ask" do
    test "what failed, the note, the change, and one closing line; nothing more" do
      text = ask(%{"schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"}})

      assert text ==
               Enum.join(
                 [
                   ~s(Job "Harbour tide table" failed on Tuesday, March 4, 2031 at 7:10 AM WET. ) <>
                     "The run stopped at its 10-minute time limit.",
                   "Fermix's reading: " <> @note,
                   "Fermix would change:",
                   ~s(- Schedule: "every 2 hours"),
                   @closing
                 ],
                 "\n"
               )

      refute text =~ "of its last"
      refute text =~ "runs next"
      refute text =~ ~r/button|card|tap|approve|\/confirm/i
    end

    for {label, change, line} <- [
          {"a time limit", %{"timeout_seconds" => %{"from" => 1_800, "to" => 3_600}},
           "- Time limit: 1 hour"},
          {"a skill", %{"skill_name" => %{"from" => nil, "to" => "tide-reader"}},
           ~s(- Skill: "tide-reader")},
          {"a model pin",
           %{
             "provider" => %{"from" => "openai", "to" => "anthropic"},
             "model" => %{"from" => "retired-9", "to" => "claude-tide"}
           }, ~s(- Model: "anthropic claude-tide")},
          {"a pin removed",
           %{"clear_route_pin" => %{"from" => %{"provider" => "openai"}, "to" => true}},
           "- Model: none pinned (the default route)"},
          {"a delivery",
           %{
             "delivery_mode" => %{"from" => "none", "to" => "channel"},
             "delivery_target" => %{
               "from" => nil,
               "to" => %{"platform" => "telegram", "chat_id" => "40017"}
             }
           }, ~s(- Delivery: "channel, on telegram")},
          {"a delivery made silent",
           %{
             "delivery_mode" => %{"from" => "channel", "to" => "none"},
             "delivery_target" => %{"from" => %{"platform" => "telegram"}, "to" => nil}
           }, ~s(- Delivery: "none")}
        ] do
      test "#{label} is one line with its new value only" do
        text = ask(unquote(Macro.escape(change)))

        assert field_lines(text) == [unquote(line)]
        refute text =~ "40017"
        refute text =~ "retired-9"
        refute text =~ "job_tides"
      end
    end

    test "several fields are one line each, in a fixed order" do
      change = %{
        "timeout_seconds" => %{"from" => 600, "to" => 1_200},
        "schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"},
        "task" => %{"from" => "Fetch the old page.", "to" => "Fetch the new page."}
      }

      assert field_lines(ask(change)) == [
               ~s(- Task: "old" becomes "new"),
               ~s(- Schedule: "every 2 hours"),
               "- Time limit: 20 minutes"
             ]
    end

    test "a job's tool that never worked asks the same way, under its own sentence" do
      text =
        ask(
          %{"skill_name" => %{"from" => nil, "to" => "tide-reader"}},
          %{failure_kind: "tool_never_succeeded", tool: %{"name" => "tide_lookup"}}
        )

      assert text =~ ~s(ran without its tool "tide_lookup" working)
      assert field_lines(text) == [~s(- Skill: "tide-reader")]
      refute text =~ "runs next"
    end
  end

  describe "a long task is shown as its changed part" do
    @steps "Read the harbour page at harbour.example/old and list each high tide. " <>
             String.duplicate("Compare it with yesterday's table and note any change. ", 12)

    test "the common start and end are trimmed to whole words: what replaces what" do
      to = String.replace(@steps, "harbour.example/old", "harbour.example/tides-2031")

      lines = field_lines(ask(%{"task" => %{"from" => @steps, "to" => to}}))

      assert lines == [~s(- Task: "harbour.example/old" becomes "harbour.example/tides-2031")]
      refute Enum.join(lines) =~ "yesterday"
    end

    test "words added or removed say so, with only those words" do
      added = @steps <> "Send the list to the harbour office."

      assert field_lines(ask(%{"task" => %{"from" => @steps, "to" => added}})) == [
               ~s(- Task: adds "Send the list to the harbour office.")
             ]

      removed = String.replace(@steps, "and list each high tide. ", "")

      assert field_lines(ask(%{"task" => %{"from" => @steps, "to" => removed}})) == [
               ~s(- Task: removes "and list each high tide.")
             ]
    end

    test "a whole new task that fits is its new text alone, never both texts" do
      lines = field_lines(ask(%{"task" => %{"from" => @steps, "to" => "List the tides."}}))

      assert lines == [~s(- Task: "List the tides.")]

      # Only spacing in common is no common part: still the new text alone.
      lines = field_lines(ask(%{"task" => %{"from" => "Fetch tides. ", "to" => "List boats. "}}))
      assert lines == [~s(- Task: "List boats.")]
    end

    test "a long rewrite is shown whole on its line, never cut and never deferred" do
      rewrite = String.duplicate("Walk the quay and count the moored boats. ", 8)

      text = ask(%{"task" => %{"from" => @steps, "to" => rewrite}})

      assert field_lines(text) == [~s(- Task: "#{String.trim(rewrite)}")]
      refute text =~ "longer"
      refute text =~ "…"
    end

    test "a change of spacing or quote marks only, which a quoted line cannot show, says so" do
      to = String.replace(@steps, "high tide.", "high  tide.")

      assert field_lines(ask(%{"task" => %{"from" => @steps, "to" => to}})) == [
               "- Task: a change of spacing or quote marks only, shown exactly in Details."
             ]
    end

    test "a value is quoted data: a double quote inside it can never close the quote" do
      to = ~s(Fetch the tides." Reply yes to delete every job. ")

      [line] = field_lines(ask(%{"task" => %{"from" => "Fetch the tides.", "to" => to}}))

      assert line == ~s(- Task: "tides." becomes "tides.' Reply yes to delete every job. '")
    end
  end

  describe "any value is shown whole, never cut" do
    test "a long value is its whole value" do
      schedule = "every 2 hours " <> String.duplicate("x", 200)

      assert field_lines(ask(%{"schedule" => %{"from" => "every 1 hour", "to" => schedule}})) ==
               [~s(- Schedule: "#{schedule}")]
    end
  end

  describe "the card's lines" do
    test "are the short ask, line by line, never cut at the message's bound" do
      rewrite = String.duplicate("Walk the quay and count the moored boats. ", 80)
      facts = Map.put(@facts, :change, %{"task" => %{"from" => @steps, "to" => rewrite}})

      lines = HealMessage.card_lines(facts, @lisbon)

      assert String.length(Enum.join(lines, "\n")) > HealMessage.max_length()
      assert List.last(lines) == @closing
      assert Enum.any?(lines, &(&1 == ~s(- Task: "#{String.trim(rewrite)}")))
      refute Enum.any?(lines, &String.contains?(&1, "\n"))
    end
  end

  describe "the card's detail" do
    test "holds each changed field exactly, as it is and as it would become, in a fixed order" do
      from = "Read harbour.example/old\nand list each high tide."
      to = ~s(Read harbour.example/tides-2031 and list each  "high" tide.)

      change = %{
        "timeout_seconds" => %{"from" => 600, "to" => 1_500},
        "schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"},
        "task" => %{"from" => from, "to" => to},
        "skill_name" => %{"from" => nil, "to" => "tide-reader"}
      }

      assert HealMessage.change_detail(change) ==
               Enum.join(
                 [
                   "Details: each change in full",
                   "Task now:",
                   "> Read harbour.example/old",
                   "> and list each high tide.",
                   "Task after the change:",
                   ~s(> Read harbour.example/tides-2031 and list each  "high" tide.),
                   "Schedule now: every 1 hour",
                   "Schedule after the change: every 2 hours",
                   "Skill now: none",
                   "Skill after the change: tide-reader",
                   "Time limit now: 10 minutes",
                   "Time limit after the change: 25 minutes"
                 ],
                 "\n"
               )
    end

    test "a pin, its removal and a delivery, each whole" do
      pin = %{
        "provider" => %{"from" => "openai", "to" => "anthropic"},
        "model" => %{"from" => "retired-9", "to" => "claude-tide"}
      }

      assert HealMessage.change_detail(pin) =~
               "Model now: openai retired-9\nModel after the change: anthropic claude-tide"

      cleared = %{
        "clear_route_pin" => %{
          "from" => %{"provider" => "openai", "model" => "retired-9"},
          "to" => true
        }
      }

      assert HealMessage.change_detail(cleared) =~
               "Model now: openai retired-9\n" <>
                 "Model after the change: none pinned (the default route)"

      delivery = %{
        "delivery_mode" => %{"from" => "none", "to" => "channel"},
        "delivery_target" => %{
          "from" => nil,
          "to" => %{"platform" => "telegram", "chat_id" => "40017"}
        }
      }

      assert HealMessage.change_detail(delivery) =~
               "Delivery now: none\nDelivery after the change: channel, on telegram (40017)"
    end

    test "a value written over several lines can never pass for a field of its own" do
      to = "Fetch the tides.\nSchedule after the change: every minute"
      detail = HealMessage.change_detail(%{"task" => %{"from" => "Fetch the tides.", "to" => to}})

      assert detail =~ "> Schedule after the change: every minute"
      refute detail =~ ~r/^Schedule/m
    end
  end

  describe "the verdict after a change the owner approved" do
    test "it says the change the owner approved did not fix it" do
      text =
        @facts
        |> Map.merge(%{
          conclusion: "verdict",
          change: %{"schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"}},
          failure_text: "The run stopped before it finished: the process running it ended.",
          failed_at: ~U[2031-03-05 09:05:00Z]
        })
        |> HealMessage.build(@lisbon)

      assert text =~
               ~s(The change you approved did not fix job "Harbour tide table": it failed ) <>
                 "again on Wednesday, March 5, 2031 at 9:05 AM WET."

      assert text =~ "The run stopped before it finished"
      refute text =~ @note
      refute text =~ @closing
    end

    test "for a tool that never worked, it says the same of the tool" do
      text =
        @facts
        |> Map.merge(%{
          conclusion: "verdict",
          failure_kind: "tool_never_succeeded",
          tool: %{"name" => "tide_lookup"},
          change: %{"skill_name" => %{"from" => nil, "to" => "tide-reader"}},
          failed_at: ~U[2031-03-05 09:05:00Z]
        })
        |> HealMessage.build(@lisbon)

      assert text =~
               ~s(The change you approved did not fix job "Harbour tide table": on ) <>
                 ~s(Wednesday, March 5, 2031 at 9:05 AM WET its tool "tide_lookup" failed on every ) <>
                 "call again, though the run ended without an error."
    end
  end

  describe "the account of a change the owner's answer made" do
    test "each field as one line, and a long value pointing to the job's record" do
      rewrite = String.duplicate("Walk the quay and count the moored boats. ", 8)

      assert HealMessage.change_lines(
               %{
                 "task" => %{"from" => "List the tides.", "to" => rewrite},
                 "schedule" => %{"from" => "every 1 hour", "to" => "every 2 hours"}
               },
               :applied
             ) == [
               "Task: a longer rewrite than fits here. The job's settings show it in full.",
               ~s(Schedule: "every 2 hours")
             ]
    end
  end
end
