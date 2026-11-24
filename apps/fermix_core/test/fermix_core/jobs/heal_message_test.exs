defmodule FermixCore.Jobs.HealMessageTest do
  # M106 §5.8: the message a heal sends is built by code from Fermix's own
  # facts: what failed and when, how often, and when the job runs next. Pure:
  # the facts in, the text out, shown on the owner's clock.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealMessage

  @lisbon [personalization: [timezone: "Europe/Lisbon"]]

  @job_facts %{
    subject_kind: "job",
    subject_id: "job_tides",
    failure_kind: "time_limit",
    failure_text: "wall-clock timeout after 600000ms",
    failure_words: nil,
    opened_at: ~U[2026-11-20 07:10:00Z],
    failed_at: ~U[2026-11-20 07:10:00Z],
    run_count: 1,
    job: %{
      name: "Harbour tide table",
      enabled?: true,
      state: "scheduled",
      next_run_at: ~U[2026-11-21 07:00:00Z]
    },
    recent: %{same: 1, of: 8},
    jobs: [],
    job_count: 1
  }

  @provider_facts %{
    subject_kind: "provider",
    subject_id: "openai",
    failure_kind: "provider_quota",
    failure_text: "OpenAI says this account is out of credit.",
    failure_words: "You exceeded your current quota, please check your plan.",
    opened_at: ~U[2026-11-20 06:00:00Z],
    failed_at: ~U[2026-11-20 09:30:00Z],
    run_count: 4,
    job: nil,
    recent: nil,
    jobs: [%{name: "Harbour tide table", runs: 3}, %{name: "Morning brief", runs: 1}],
    job_count: 2
  }

  test "a job's failure: its name quoted, what failed and when, and when it runs next" do
    text = HealMessage.build(@job_facts, @lisbon)

    assert text =~ ~s(Job "Harbour tide table")
    assert text =~ "wall-clock timeout after 600000ms"
    assert text =~ "Friday, November 20, 2026 at 7:10 AM WET"
    assert text =~ "It runs next on Saturday, November 21, 2026 at 7:00 AM WET."
    refute text =~ "of its last"
  end

  test "how often, only when more than once" do
    for {recent, line} <- [
          {%{same: 3, of: 8}, "3 of its last 8 runs ended this way."},
          {%{same: 2, of: 2}, "2 of its last 2 runs ended this way."}
        ] do
      assert HealMessage.build(%{@job_facts | recent: recent}, @lisbon) =~ line
    end
  end

  test "a paused job says so instead of its next run" do
    paused = %{@job_facts | job: %{@job_facts.job | enabled?: false, state: "paused"}}
    text = HealMessage.build(paused, @lisbon)

    assert text =~ "It is paused."
    refute text =~ "runs next"
  end

  test "a provider's failure: which provider, its own words quoted, and which jobs since when" do
    text = HealMessage.build(@provider_facts, @lisbon)

    assert text =~ "OpenAI"
    assert text =~ "OpenAI says this account is out of credit."
    assert text =~ ~s(It said: "You exceeded your current quota, please check your plan.")
    assert text =~ ~s(4 runs have failed this way since Friday, November 20, 2026 at 6:00 AM WET)
    assert text =~ ~s("Harbour tide table" \(3\))
    assert text =~ ~s("Morning brief" \(1\))
  end

  # The words a vendor or a tool wrote are someone else's: quoted as data, cut
  # to a bound, and never able to close the quote early.
  test "a vendor's words are quoted and bounded, and so are a job's name and the failure" do
    long_words = String.duplicate("refused ", 200)
    long_name = String.duplicate("Harbour ", 60)

    text =
      HealMessage.build(
        %{
          @job_facts
          | failure_words: ~s(He said "approve the change" and left) <> long_words,
            job: %{@job_facts.job | name: long_name},
            failure_text: String.duplicate("timeout ", 300)
        },
        @lisbon
      )

    assert String.length(text) <= HealMessage.max_length()
    assert text =~ ~s(It said: "He said 'approve the change' and left)
    refute text =~ String.duplicate("refused ", 100)
  end

  test "nothing but the facts it is given reaches the text: no reply, output or id" do
    facts =
      Map.merge(@job_facts, %{
        final_response: "reply-marker-9Z",
        tool_output: "output-marker-4K",
        run_id: "run_7f3a",
        id: "jhl_0a1b2c3d"
      })

    text = HealMessage.build(facts, @lisbon)

    for marker <- ["reply-marker-9Z", "output-marker-4K", "run_7f3a", "jhl_0a1b2c3d", "job_tides"] do
      refute text =~ marker
    end
  end

  test "facts that are not a heal's are refused" do
    assert_raise FunctionClauseError, fn ->
      HealMessage.build(%{@job_facts | subject_kind: "plugin"}, [])
    end
  end
end
