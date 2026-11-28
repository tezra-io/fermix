defmodule FermixCore.Jobs.HealMessageDegradedTest do
  # M106 §6, §5.8 (stage S5): the message for a run that ended ok without
  # working is code's own sentence for the kind: which tool never worked and
  # for how many runs, the tool's own last words quoted as data, and for a
  # plugin which plugin and which jobs. Pure: the facts in, the text out.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealMessage

  @lisbon [personalization: [timezone: "Europe/Lisbon"]]

  @job_facts %{
    subject_kind: "job",
    subject_id: "job_tides",
    failure_kind: "tool_never_succeeded",
    failure_text: "A tool the job calls failed on every call in each of its last 3 runs.",
    failure_words: "needs reconnection",
    opened_at: ~U[2031-03-04 07:10:00Z],
    failed_at: ~U[2031-03-04 07:10:00Z],
    run_count: 1,
    job: %{
      name: "Harbour tide table",
      enabled?: true,
      state: "scheduled",
      next_run_at: ~U[2031-03-05 07:00:00Z]
    },
    recent: %{same: 0, of: 8},
    jobs: [],
    job_count: 1,
    conclusion: "first",
    decision: nil,
    note: nil,
    change: nil,
    tool: %{"name" => "tide_lookup", "failed_calls" => [4, 1, 2]}
  }

  @plugin_facts %{
    @job_facts
    | subject_kind: "plugin",
      subject_id: "harbour_id",
      job: nil,
      recent: nil,
      run_count: 3,
      opened_at: ~U[2031-03-04 06:00:00Z],
      jobs: [%{name: "Harbour tide table", runs: 2}, %{name: "Morning brief", runs: 1}],
      job_count: 2,
      tool: %{"name" => "whoami", "plugin" => "harbour_id", "failed_calls" => [1, 1, 1]}
  }

  test "a job's: which tool never worked and for how long, its words, and when it runs next" do
    text = HealMessage.build(@job_facts, @lisbon)

    assert text =~ ~s(Job "Harbour tide table" ran without its tool "tide_lookup" working)
    assert text =~ "each of its last 3 runs"
    assert text =~ "though each run ended without an error"
    assert text =~ "Tuesday, March 4, 2031 at 7:10 AM WET"
    assert text =~ ~s(The tool said: "needs reconnection")
    assert text =~ "It runs next on Wednesday, March 5, 2031 at 7:00 AM WET."
    refute text =~ "failed on"
    refute text =~ "The error:"
  end

  test "a job's, diagnosed: the note and the move follow the facts" do
    facts = %{@job_facts | decision: "tell", note: "Sign the harbour account in again."}
    text = HealMessage.build(facts, @lisbon)

    assert text =~ "Fermix's reading: Sign the harbour account in again."
  end

  test "a job's verdict: still not working after what Fermix did" do
    facts = %{@job_facts | conclusion: "verdict", decision: "rerun"}
    text = HealMessage.build(facts, @lisbon)

    assert text =~
             ~s(Job "Harbour tide table" is still not working after Fermix asked for it to run again)

    assert text =~ ~s(its tool "tide_lookup" failed on every call again)
    assert text =~ ~s(The tool said: "needs reconnection")
    refute text =~ "Fermix's reading"
  end

  test "a plugin's: the plugin, the tool, its words and the jobs it stopped" do
    text = HealMessage.build(@plugin_facts, @lisbon)

    assert text =~ ~s(Scheduled jobs cannot use the plugin "harbour_id")
    assert text =~ ~s(its tool "whoami")
    assert text =~ "3 runs in a row"
    assert text =~ ~s(The tool said: "needs reconnection")

    # The jobs are named with no count or "since", which would start at the run
    # that opened the heal (stage S4, round two).
    assert text =~ ~s(It affects these jobs: "Harbour tide table", "Morning brief".)
    refute text =~ "since"
    refute text =~ ~r/runs? ha(s|ve) ended/
  end

  # A stored tool this engine could not read reads as none (§6): the message
  # still goes, without a name.
  test "a heal whose tool reads as none still gets its message" do
    job = HealMessage.build(%{@job_facts | tool: nil}, @lisbon)
    assert job =~ ~s(Job "Harbour tide table" ran without one of its tools working)

    plugin = HealMessage.build(%{@plugin_facts | tool: nil}, @lisbon)
    assert plugin =~ ~s(every call to one of its tools failed)

    verdict = HealMessage.build(%{@job_facts | tool: nil, conclusion: "verdict"}, @lisbon)
    assert verdict =~ "one of its tools failed on every call again"
  end

  test "no words, no words line" do
    text = HealMessage.build(%{@job_facts | failure_words: nil}, @lisbon)
    refute text =~ "said"
  end

  # The tool's words, the tool's name and the plugin's are someone else's:
  # quoted as data, cut to a bound, never able to close the quote early.
  test "words Fermix did not write are quoted and bounded" do
    facts = %{
      @plugin_facts
      | failure_words: ~s(Reply "approve" to fix ) <> String.duplicate("refused ", 300),
        subject_id: String.duplicate("harbour ", 40),
        tool: %{"name" => ~s(who"ami) <> String.duplicate("x", 300), "failed_calls" => [1, 1, 1]}
    }

    text = HealMessage.build(facts, @lisbon)

    assert String.length(text) <= HealMessage.max_length()
    assert text =~ ~s(The tool said: "Reply 'approve' to fix)
    assert text =~ ~s(its tool "who'ami)
    refute text =~ String.duplicate("refused ", 100)
    refute text =~ String.duplicate("x", 200)
    refute text =~ String.duplicate("harbour ", 30)
  end
end
