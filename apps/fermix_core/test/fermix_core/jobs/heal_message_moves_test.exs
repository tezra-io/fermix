defmodule FermixCore.Jobs.HealMessageMovesTest do
  # M106 §5.8 and §5.9 (stage S3): after Fermix's facts the message carries
  # the heal run's note, as Fermix's reading of the failure, then one line
  # saying what Fermix did; a fix that did not hold gets one message of its
  # own. Pure and code-built: no ids, every value quoted and bounded. What a
  # proposal asks is `heal_message_proposal_test.exs` (stage S4).
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealMessage

  @lisbon [personalization: [timezone: "Europe/Lisbon"]]
  @note "The harbour page now waits on every fetch until the limit ends it."

  @facts %{
    subject_kind: "job",
    subject_id: "job_tides",
    failure_kind: "time_limit",
    failure_text: "wall-clock timeout after 600000ms",
    failure_words: nil,
    opened_at: ~U[2031-03-04 07:10:00Z],
    failed_at: ~U[2031-03-04 07:10:00Z],
    run_count: 1,
    job: %{
      name: "Harbour tide table",
      enabled?: true,
      state: "scheduled",
      next_run_at: ~U[2031-03-05 07:00:00Z]
    },
    recent: %{same: 1, of: 8},
    jobs: [],
    job_count: 1,
    conclusion: "first",
    decision: nil,
    note: nil,
    change: nil
  }

  defp build(overrides), do: @facts |> Map.merge(overrides) |> HealMessage.build(@lisbon)

  describe "what Fermix did" do
    for {{decision, change, job, line}, n} <-
          Enum.with_index([
            {"rerun", nil, nil, "Fermix has asked for it to run again now."},
            {"raise_limit", %{"timeout_seconds" => %{"from" => 900, "to" => 1_800}}, nil,
             "Fermix raised its time limit from 15 to 30 minutes."},
            {"raise_limit", %{"timeout_seconds" => %{"from" => 45, "to" => 90}}, nil,
             "Fermix raised its time limit from 45 to 90 seconds."},
            {"pause", nil, %{enabled?: false, state: "paused"},
             "Fermix paused it; it will not run until you resume it."}
          ]) do
      test "#{n}: #{decision} #{inspect(change && Map.keys(change))}" do
        job = unquote(Macro.escape(job))

        overrides = %{
          decision: unquote(decision),
          note: @note,
          change: unquote(Macro.escape(change))
        }

        overrides =
          if job, do: Map.put(overrides, :job, Map.merge(@facts.job, job)), else: overrides

        text = build(overrides)

        assert text =~ unquote(line)
        [facts, after_facts] = String.split(text, @note, parts: 2)
        assert facts =~ "wall-clock timeout after 600000ms"
        assert after_facts =~ unquote(line)
        refute text =~ "40017"
        refute text =~ "job_tides"
      end
    end

    test "tell and no decision add no line of their own" do
      for decision <- ["tell", "none"] do
        text = build(%{decision: decision, note: if(decision == "tell", do: @note)})
        refute text =~ "Fermix would change"
        refute text =~ "Fermix raised"
        refute text =~ "Fermix paused"
        refute text =~ "run again"
      end
    end

    test "the note is Fermix's reading, its newlines flattened and bounded" do
      text = build(%{decision: "tell", note: "First.\n\nSecond " <> String.duplicate("x", 900)})

      assert text =~ "Fermix's reading: First. Second x"
      refute text =~ "First.\n"
      [_before, reading] = String.split(text, "Fermix's reading: ")
      assert reading |> String.split("\n") |> hd() |> String.length() <= 500
    end

    test "a pause is not said twice" do
      text =
        build(%{
          decision: "pause",
          note: @note,
          job: %{@facts.job | enabled?: false, state: "paused"}
        })

      refute text =~ "It is paused."
      assert text =~ "Fermix paused it"
    end
  end

  describe "the verdict: a fix that did not hold" do
    test "after a rerun, one message says it is still failing, with the new failure" do
      text =
        build(%{
          conclusion: "verdict",
          decision: "rerun",
          note: @note,
          failure_text: "The run stopped before it finished: the process running it ended.",
          failed_at: ~U[2031-03-04 08:05:00Z]
        })

      assert text =~
               ~s(Job "Harbour tide table" is still failing after Fermix asked for it to run again.)

      assert text =~ "The run stopped before it finished"
      assert text =~ "8:05 AM"
      refute text =~ @note
    end

    test "after a raised limit, it names the limit it now has" do
      text =
        build(%{
          conclusion: "verdict",
          decision: "raise_limit",
          change: %{"timeout_seconds" => %{"from" => 600, "to" => 1_200}}
        })

      assert text =~ "is still failing after Fermix raised its time limit to 20 minutes."
    end
  end
end
