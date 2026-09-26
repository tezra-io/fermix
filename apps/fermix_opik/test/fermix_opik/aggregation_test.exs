defmodule FermixOpik.AggregationTest do
  use ExUnit.Case, async: true

  alias FermixOpik.Aggregation

  # Drive a list of {event, measurements, metadata} through the reducer,
  # returning {final_state, all_closed_traces}. Each event gets a monotonically
  # increasing timestamp so spans order deterministically.
  defp run(events, opts \\ []) do
    agg = Aggregation.new(project: "fermix", ttl_ms: Keyword.get(opts, :ttl_ms, 120_000))
    base = ~U[2026-06-02 12:00:00.000Z]

    {state, closed} =
      events
      |> Enum.with_index()
      |> Enum.reduce({agg, []}, fn {{event, meas, meta}, i}, {st, acc} ->
        at = %{at: DateTime.add(base, i, :second), mono: i * 1_000_000}
        {st, new} = Aggregation.apply_event(st, event, meas, meta, at)
        {st, acc ++ new}
      end)

    {state, closed}
  end

  defp span_named(spans, name), do: Enum.find(spans, &(&1.name == name))
  defp spans_of_type(spans, type), do: Enum.filter(spans, &(&1[:type] == type))

  describe "spans arriving after their trace shipped" do
    test "a late draft-stream seal is dropped, not turned into an empty second root" do
      # Observed live: a fast turn closed at 21:50:55 and its `stream:open` /
      # `stream:seal` landed a second later, minting an input/output-less
      # `agent:main` phantom root. The draft stream is its own process, so on a
      # short turn it loses the race with `agent.message`.
      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 10},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}},
          # Both arrive AFTER the close above.
          {[:fermix, :channel, :stream], %{ttfd_ms: 40},
           %{channel: "telegram", session_id: "main-1", phase: :open, status: :ok}},
          {[:fermix, :channel, :stream], %{total_edits: 1, dropped_snapshots: 0},
           %{channel: "telegram", session_id: "main-1", phase: :seal, status: :ok}}
        ])

      # Exactly one trace, and no phantom left open behind it.
      assert [%{trace: trace}] = closed
      assert trace.name == "agent:main"
      assert state.traces == %{}

      # Only :open reaches `place_under` (and so the tombstone): :seal is already
      # filtered by `attach_if_open` upstream. :open cannot use that filter — it
      # may legitimately be a turn's first event and must be able to create the
      # session — which is exactly why the tombstone, not an open-session check,
      # is what closes this hole.
      assert state.dropped_after_close == 1
    end

    test "a genuinely new session still opens its own root after another closed" do
      {state, closed} =
        run([
          {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}},
          {[:fermix, :provider, :call], %{duration_ms: 10},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-2"}}
        ])

      # The tombstone is per session id — it must not suppress unrelated work.
      assert length(closed) == 1
      assert map_size(state.traces) == 1
      assert state.dropped_after_close == 0
    end

    test "tombstones are pruned by the sweep so they cannot grow without bound" do
      {state, _closed} =
        run([
          {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
        ])

      assert map_size(state.closed_sessions) == 1

      # Well past the tombstone TTL (10 min, monotonic microseconds).
      {swept, _} = Aggregation.sweep(state, 10_000_000_000)
      assert swept.closed_sessions == %{}
    end
  end

  test "draft-stream phases nest as child spans under the turn trace, never as roots" do
    {_state, closed} =
      run([
        {[:fermix, :channel, :stream], %{ttfd_ms: 850},
         %{channel: "telegram", session_id: "main-1", phase: :open, status: :ok}},
        {[:fermix, :channel, :stream], %{duration_us: 90_000, edit_index: 1},
         %{channel: "telegram", session_id: "main-1", phase: :edit, status: :ok}},
        {[:fermix, :channel, :stream], %{duration_us: 50_000, block_index: 2},
         %{channel: "telegram", session_id: "main-1", phase: :block, status: :ok}},
        {[:fermix, :channel, :stream], %{duration_us: 60_000, edit_index: 3},
         %{channel: "telegram", session_id: "main-1", phase: :rotate, status: :ok}},
        {[:fermix, :provider, :call], %{duration_ms: 1_000},
         %{provider: :openai_codex, model: "gpt-5-codex", status: :ok, session_id: "main-1"}},
        {[:fermix, :channel, :stream], %{total_edits: 12, dropped_snapshots: 40},
         %{channel: "telegram", session_id: "main-1", phase: :seal, status: :ok}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
      ])

    # One trace only - stream events must not create orphan roots.
    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"

    wrapper = span_named(spans, "agent:main")

    open = span_named(spans, "stream:open")
    assert open.parent_span_id == wrapper.id
    assert open.metadata.ttfd_ms == 850

    block = span_named(spans, "stream:block")
    assert block.parent_span_id == wrapper.id
    assert block.metadata.block_index == 2

    # A mid-turn draft rotation (one sealed section card) exports like a block:
    # a child span of the turn, never the terminal seal.
    rotate = span_named(spans, "stream:rotate")
    assert rotate.parent_span_id == wrapper.id

    seal = span_named(spans, "stream:seal")
    assert seal.parent_span_id == wrapper.id
    assert seal.metadata.total_edits == 12
    assert seal.metadata.dropped_snapshots == 40

    # Interim edits are deliberately not exported (would flood the trace);
    # block chunks (a handful per turn) are.
    refute span_named(spans, "stream:edit")
  end

  test "a provider failover nests as a child span under the turn trace" do
    {_state, closed} =
      run([
        {[:fermix, :provider, :failover], %{count: 1},
         %{
           from_provider: :anthropic,
           from_model: "claude-sonnet-4-6",
           to_provider: :openai,
           to_model: "gpt-5.5",
           reason_kind: :timeout,
           agent: "main",
           session_id: "main-1"
         }},
        {[:fermix, :provider, :call], %{duration_ms: 1_000},
         %{provider: :openai, model: "gpt-5.5", status: :ok, session_id: "main-1"}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"

    wrapper = span_named(spans, "agent:main")
    failover = span_named(spans, "failover:anthropic->openai")

    assert failover.parent_span_id == wrapper.id
    assert failover.trace_id == trace.id
    assert failover.metadata.from_provider == "anthropic"
    assert failover.metadata.to_provider == "openai"
    assert failover.metadata.to_model == "gpt-5.5"
    assert failover.metadata.reason_kind == "timeout"
  end

  test "a fired timeout nests as an errored point span under the run trace" do
    {_state, closed} =
      run([
        {[:fermix, :timeout, :expired], %{ms: 30_000},
         %{name: :cu_sidecar_action, session_id: "main-1"}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    wrapper = span_named(spans, "agent:main")
    timeout = span_named(spans, "timeout:cu_sidecar_action")

    assert timeout.parent_span_id == wrapper.id
    assert timeout.trace_id == trace.id
    assert timeout.metadata.ms == 30_000
    assert timeout.error_info.exception_type == "Timeout"
  end

  @compaction_event [:fermix, :agent_loop, :context_compaction]
  @recovery_event [:fermix, :agent_loop, :context_recovery]

  describe "in-loop context compaction" do
    test "the reporter subscribes to both events" do
      assert @compaction_event in FermixOpik.Reporter.events()
      assert @recovery_event in FermixOpik.Reporter.events()
    end

    test "a compaction and a recovery round nest as point spans under the turn" do
      {_state, closed} =
        run([
          {@compaction_event, %{count: 1, results: 3, bytes_before: 350_000, bytes_after: 12_000},
           %{session_id: "main-1", agent: "main", iteration: 4, level: 1, trigger: :recovery}},
          {@recovery_event, %{count: 1},
           %{session_id: "main-1", agent: "main", iteration: 4, round: 1, outcome: :recovered}},
          {[:fermix, :agent, :message], %{iterations: 5, total_tokens: 10},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      wrapper = span_named(spans, "agent:main")
      compaction = span_named(spans, "context_compaction")
      recovery = span_named(spans, "context_recovery")

      assert compaction.type == "general"
      assert compaction.parent_span_id == wrapper.id
      assert compaction.trace_id == trace.id

      assert compaction.metadata == %{
               agent: "main",
               iteration: 4,
               level: 1,
               trigger: "recovery",
               results: 3,
               bytes_before: 350_000,
               bytes_after: 12_000
             }

      assert recovery.type == "general"
      assert recovery.parent_span_id == wrapper.id
      assert recovery.trace_id == trace.id

      assert recovery.metadata == %{
               agent: "main",
               iteration: 4,
               round: 1,
               outcome: "recovered"
             }
    end

    test "a subagent's compaction hangs off the subagent's wrapper, not the turn's" do
      {_state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 900},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {[:fermix, :agent, :start], %{},
           %{name: "coder", role: "worker", session_id: "sub-abc", parent_session: "main-1"}},
          {@compaction_event, %{count: 1, results: 2, bytes_before: 90_000, bytes_after: 4_000},
           %{
             session_id: "sub-abc",
             parent_session: "main-1",
             agent: "coder",
             iteration: 2,
             level: 1,
             trigger: :budget
           }},
          {[:fermix, :agent, :task_complete], %{duration_ms: 800, iterations: 2},
           %{name: "coder", role: "worker", session_id: "sub-abc", parent_session: "main-1"}},
          {[:fermix, :agent, :message], %{iterations: 3, total_tokens: 37},
           %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      sub_wrap = span_named(spans, "subagent:coder")
      compaction = span_named(spans, "context_compaction")

      assert compaction.parent_span_id == sub_wrap.id
      assert compaction.trace_id == trace.id
    end

    test "an event without a session_id opens no trace" do
      {state, closed} =
        run([
          {@recovery_event, %{count: 1},
           %{agent: "main", iteration: 1, round: 2, outcome: :nothing_left}}
        ])

      assert closed == []
      assert map_size(state.sessions) == 0
      assert map_size(state.traces) == 0
    end
  end

  test "a main turn becomes one trace with nested llm and tool spans" do
    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 1_000},
         %{
           provider: :openai,
           model: "gpt-5",
           status: :ok,
           session_id: "main-1",
           tokens: %{prompt: 40, completion: 8}
         }},
        {[:fermix, :tool, :exec], %{duration_ms: 30},
         %{tool: "shell", success: true, session_id: "main-1"}},
        {[:fermix, :agent, :message], %{iterations: 2, total_tokens: 48},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"
    # chat turns group into an Opik thread by channel:chat_id
    assert trace.thread_id == "telegram:c1"
    assert trace.metadata.iterations == 2
    assert trace.metadata.total_tokens == 48
    assert length(spans) == 3

    wrapper = span_named(spans, "agent:main")
    assert wrapper.type == "general"
    refute Map.has_key?(wrapper, :parent_span_id)

    [llm] = spans_of_type(spans, "llm")
    [tool] = spans_of_type(spans, "tool")
    assert llm.parent_span_id == wrapper.id
    assert tool.parent_span_id == wrapper.id
    assert llm.trace_id == trace.id
    assert tool.trace_id == trace.id
    assert llm.usage == %{prompt_tokens: 40, completion_tokens: 8, total_tokens: 48}
  end

  test "a mobile turn and its generic stream keep the standard main run attribution" do
    {_state, closed} =
      run([
        {[:fermix, :channel, :stream], %{ttfd_ms: 35},
         %{channel: :mobile, session_id: "main-19", phase: :open, status: :ok}},
        {[:fermix, :provider, :call], %{duration_ms: 250},
         %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-19"}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 12},
         %{
           channel: :mobile,
           chat_id: "main",
           sender: "device",
           session_id: "main-19",
           agent: "main"
         }}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"
    assert trace.thread_id == "mobile:main"
    assert trace.metadata.channel == "mobile"

    stream = span_named(spans, "stream:open")
    assert stream.metadata.channel == :mobile
  end

  # The companion socket streams raw deltas, so its turn has no draft-stream
  # span; it is the operator's own turn with no sender id, threaded like any
  # other chat by channel and profile.
  test "a companion turn is a main run threaded as companion:<profile>" do
    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 180},
         %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-27"}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 9},
         %{
           channel: :companion,
           chat_id: "main",
           sender: nil,
           session_id: "main-27",
           agent: "main"
         }}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"
    assert trace.thread_id == "companion:main"
    assert trace.metadata.channel == "companion"
    assert [_llm] = spans_of_type(spans, "llm")
    refute Enum.any?(spans, &String.starts_with?(&1.name, "stream:"))
  end

  # The M29/Buzz duplicate-reply incident: the one trace worth reading — the
  # failed turn — carried no input, no status and nothing filterable, so a reader
  # could only find it by eyeballing output text.
  test "a failed turn carries the prompt, an error status and structured error_info" do
    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 400},
         %{provider: :openai_codex, model: "gpt-5-codex", status: :error, session_id: "main-1"}},
        {[:fermix, :agent, :message_error], %{count: 1},
         %{
           channel: :telegram,
           chat_id: "c1",
           sender: "u1",
           session_id: "main-1",
           agent: "main",
           input: "why did that reply post five times?",
           reason: {:provider_transport_error, %{kind: :transport_closed}}
         }}
      ])

    assert [%{trace: trace}] = closed
    assert trace.name == "agent:main"
    assert trace.thread_id == "telegram:c1"
    # The prompt a successful turn keeps, the failed one now keeps too.
    assert trace.input == %{text: "why did that reply post five times?"}
    assert trace.metadata.status == "error"
    assert trace.metadata.sender == "u1"
    # Filterable as failed, not findable only by reading the output text.
    assert trace.error_info.exception_type == "TurnError"
    assert trace.error_info.message =~ "transport_closed"
    assert trace.output.text =~ "transport_closed"
  end

  # Regression: enriching the failure path must leave a successful turn's trace
  # payload exactly as it was — no status key, no error_info.
  test "a successful turn's trace payload is unchanged" do
    {_state, closed} =
      run([
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{
           channel: :telegram,
           chat_id: "c1",
           sender: "u1",
           session_id: "main-1",
           agent: "main",
           input: "hello",
           output: "hi"
         }}
      ])

    assert [%{trace: trace}] = closed

    assert trace.metadata == %{
             channel: "telegram",
             chat_id: "c1",
             sender: "u1",
             iterations: 1,
             total_tokens: 10
           }

    refute Map.has_key?(trace, :error_info)

    assert Enum.sort(Map.keys(trace)) == [
             :end_time,
             :id,
             :input,
             :metadata,
             :name,
             :output,
             :project_name,
             :start_time,
             :tags,
             :thread_id
           ]
  end

  test "a subagent's work nests under the delegating turn in the same trace" do
    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 900},
         %{
           provider: :openai,
           model: "gpt-5",
           status: :ok,
           session_id: "main-1",
           tokens: %{prompt: 10, completion: 2}
         }},
        {[:fermix, :agent, :start], %{},
         %{
           name: "coder",
           role: "worker",
           session_id: "sub-abc",
           parent: "main",
           parent_session: "main-1"
         }},
        {[:fermix, :agent, :task_start], %{},
         %{
           name: "coder",
           role: "worker",
           session_id: "sub-abc",
           parent_session: "main-1",
           task_summary: "write a function"
         }},
        {[:fermix, :provider, :call], %{duration_ms: 700},
         %{
           provider: :openai,
           model: "gpt-5",
           status: :ok,
           session_id: "sub-abc",
           tokens: %{prompt: 20, completion: 5}
         }},
        {[:fermix, :tool, :exec], %{duration_ms: 15},
         %{tool: "file_write", success: true, session_id: "sub-abc"}},
        {[:fermix, :agent, :task_complete], %{duration_ms: 800, iterations: 1},
         %{
           name: "coder",
           role: "worker",
           session_id: "sub-abc",
           success: true,
           parent_session: "main-1"
         }},
        {[:fermix, :agent, :message], %{iterations: 3, total_tokens: 37},
         %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    # one trace, two wrapper spans, two llm spans, one tool span
    assert length(spans_of_type(spans, "general")) == 2
    assert length(spans_of_type(spans, "llm")) == 2
    assert length(spans_of_type(spans, "tool")) == 1
    assert Enum.all?(spans, &(&1.trace_id == trace.id))

    main_wrap = span_named(spans, "agent:main")
    sub_wrap = span_named(spans, "subagent:coder")
    assert sub_wrap.parent_span_id == main_wrap.id

    # the subagent's tool span hangs off the subagent wrapper, not the main one
    tool = Enum.find(spans, &(&1[:type] == "tool"))
    assert tool.parent_span_id == sub_wrap.id
  end

  test "a draft-stream :seal arriving after the turn closed does not resurrect a phantom trace" do
    {state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 1_000},
         %{provider: :openai_codex, model: "gpt-5-codex", status: :ok, session_id: "main-1"}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}},
        # The channel seals the draft just AFTER the turn's message closed and
        # shipped the trace — this must not spawn an empty phantom trace.
        {[:fermix, :channel, :stream], %{total_edits: 1, dropped_snapshots: 5},
         %{channel: "telegram", session_id: "main-1", phase: :seal, status: :ok}}
      ])

    # Exactly one trace (the real turn); the late seal is dropped, and no phantom
    # is left open in state for the sweep to later flush.
    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"
    assert trace.thread_id == "telegram:c1"
    refute Enum.any?(spans, &(&1.name == "stream:seal"))
    assert state.traces == %{}
  end

  test "a draft-stream :block arriving after the turn closed does not resurrect a phantom trace" do
    {state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 1_000},
         %{provider: :openai_codex, model: "gpt-5-codex", status: :ok, session_id: "main-1"}},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}},
        # In block streaming a paced :block edit can flush just AFTER the turn's
        # message closed and shipped the trace — like :seal/:discard, this must
        # not spawn an empty phantom trace (the reported symptom: thread-less,
        # input/output-less "agent:main" traces of only stream:* spans).
        {[:fermix, :channel, :stream], %{duration_us: 50_000, block_index: 23},
         %{channel: "telegram", session_id: "main-1", phase: :block, status: :ok}}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"
    assert trace.thread_id == "telegram:c1"
    refute Enum.any?(spans, &(&1.name == "stream:block"))
    assert state.traces == %{}
  end

  test "a scheduled job run is its own trace with a job thread id" do
    {_state, closed} =
      run([
        {[:fermix, :job, :run_start], %{},
         %{
           agent: "scheduled:job-7",
           job_id: "job-7",
           run_id: "run-1",
           name: "digest",
           session_id: "cron_job-7_1",
           schedule_kind: "cron",
           trigger: "schedule"
         }},
        {[:fermix, :provider, :call], %{duration_ms: 500},
         %{
           provider: :openai_codex,
           model: "gpt-5-codex",
           status: :ok,
           session_id: "cron_job-7_1",
           tokens: %{prompt: 30, completion: 12}
         }},
        {[:fermix, :job, :run_complete], %{duration_ms: 1_500, iterations: 1, total_tokens: 42},
         %{
           agent: "scheduled:job-7",
           job_id: "job-7",
           run_id: "run-1",
           status: "ok",
           session_id: "cron_job-7_1"
         }}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.thread_id == "job-7"
    assert "scheduled" in trace.tags
    assert trace.metadata.job_id == "job-7"
    assert [llm] = spans_of_type(spans, "llm")
    assert llm.provider == "openai"
  end

  test "a soul-curation draft is its own trace nesting the bounded provider call" do
    {_state, closed} =
      run([
        {[:fermix, :soul_curation, :run_start], %{},
         %{
           agent: "soul_curation",
           session_id: "soul_curation:abc",
           mode: :suggest,
           with_context: true
         }},
        {[:fermix, :provider, :call], %{duration_ms: 400},
         %{
           provider: :anthropic,
           model: "claude-opus-4-8",
           status: :ok,
           session_id: "soul_curation:abc",
           tokens: %{prompt: 80, completion: 20}
         }},
        {[:fermix, :soul_curation, :run_complete], %{byte_delta: 12, line_delta: 1},
         %{
           agent: "soul_curation",
           session_id: "soul_curation:abc",
           mode: :suggest,
           status: "proposed",
           route: "anthropic/claude-opus-4-8",
           byte_delta: 12,
           line_delta: 1
         }}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "soul_curation:suggest"
    assert "soul_curation" in trace.tags
    assert trace.metadata.mode == "suggest"
    assert trace.metadata.route == "anthropic/claude-opus-4-8"
    assert trace.metadata.with_context == true
    assert [llm] = spans_of_type(spans, "llm")
    assert llm.provider == "anthropic"
  end

  test "a skill-curation cycle is its own trace nesting the miner call, counts exported" do
    {_state, closed} =
      run([
        {[:fermix, :skill_curation, :run_start], %{},
         %{
           agent: "skill_curation",
           session_id: "skill_curation:abc",
           stage: :cycle,
           trigger: :scheduled
         }},
        {[:fermix, :provider, :call], %{duration_ms: 900},
         %{
           provider: :anthropic,
           model: "claude-opus-4-8",
           status: :ok,
           session_id: "skill_curation:abc",
           tokens: %{prompt: 120, completion: 40}
         }},
        {[:fermix, :skill_curation, :run_complete], %{count: 1},
         %{
           agent: "skill_curation",
           session_id: "skill_curation:abc",
           stage: :cycle,
           trigger: :scheduled,
           status: "ok",
           messages_scanned: 240,
           candidates: 2,
           dropped_grounding: 1,
           deferred: 0,
           proposals_new: 2,
           proposals_archive: 1,
           delivery_status: :delivered
         }}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "skill_curation:cycle"
    assert "skill_curation" in trace.tags
    assert trace.metadata.trigger == "scheduled"
    assert trace.metadata.messages_scanned == 240
    assert trace.metadata.candidates == 2
    assert trace.metadata.dropped_grounding == 1
    assert trace.metadata.proposals_new == 2
    assert trace.metadata.proposals_archive == 1
    assert trace.metadata.delivery_status == "delivered"
    assert [llm] = spans_of_type(spans, "llm")
    assert llm.provider == "anthropic"
  end

  test "a manual skill-curation cycle with a synthetic command parent stays a standalone root" do
    {_state, closed} =
      run([
        {[:fermix, :skill_curation, :run_start], %{},
         %{
           agent: "skill_curation",
           session_id: "skill_curation:xyz",
           stage: :cycle,
           trigger: :manual,
           parent_session: "command:skills:telegram:c1"
         }},
        {[:fermix, :skill_curation, :run_error], %{count: 1},
         %{
           agent: "skill_curation",
           session_id: "skill_curation:xyz",
           stage: :cycle,
           trigger: :manual,
           status: "error",
           reason_kind: :provider,
           error: "boom"
         }}
      ])

    assert [%{trace: trace}] = closed
    assert trace.name == "skill_curation:cycle"
    assert trace.metadata.reason_kind == "provider"
    assert trace.metadata.trigger == "manual"
  end

  test "a proposal action is a self-closing point trace, never a phantom root" do
    {state, closed} =
      run([
        {[:fermix, :skill_curation, :proposal_actioned], %{count: 1, age_ms: 86_400_000},
         %{agent: "skill_curation", action: "approve", kind: "new_skill"}}
      ])

    assert [%{trace: trace, spans: []}] = closed
    assert trace.name == "skillcur:approve"
    assert trace.metadata.action == "approve"
    assert trace.metadata.kind == "new_skill"
    assert trace.metadata.age_ms == 86_400_000
    assert "skill_curation" in trace.tags

    # Point events are emitted immediately, never tracked as open sessions.
    assert map_size(state.sessions) == 0
  end

  test "a background memory review is its own memory_review trace closed by the :review event" do
    session = "memory_review:main:telegram:c1:root:42"

    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 1_000},
         %{
           provider: :openai_codex,
           model: "gpt-5.5",
           status: :ok,
           agent: "memory_reviewer",
           session_id: session,
           tokens: %{prompt: 100, completion: 20}
         }},
        {[:fermix, :memory, :write], %{count: 1},
         %{
           tool: "memory_write",
           action: :added,
           agent: "memory_reviewer",
           session_id: session,
           channel: "telegram",
           chat_id: "c1"
         }},
        {[:fermix, :memory, :review],
         %{
           duration_us: 1_500_000,
           ops_added: 1,
           ops_replaced: 0,
           ops_archived: 0,
           ops_skipped: 0,
           input_messages: 3,
           input_tokens: 120
         },
         %{
           agent: "main",
           owner: "default",
           session_id: session,
           conversation_key: "telegram:c1:root",
           channel: "telegram",
           chat_id: "c1",
           status: :ok,
           fired: true
         }}
      ])

    # The :review event closes the run as one trace (not a TTL-swept orphan),
    # tagged memory_review, with its llm + memory-write spans nested under it and
    # the conversation thread backfilled from the event's channel/chat_id.
    assert [%{trace: trace, spans: spans}] = closed
    assert "memory_review" in trace.tags
    assert trace.name == "memory_review:memory_reviewer"
    assert trace.thread_id == "telegram:c1"
    assert trace.output.value.status == "ok"
    assert trace.output.value.added == 1
    assert [_llm] = spans_of_type(spans, "llm")
    assert [_write] = spans_of_type(spans, "tool")
  end

  test "a computer-history summarize cycle is its own kind, not a subagent" do
    # The summarizer (§22.4) is a headless single provider call with no bookend
    # events — its llm span creates the session, so the kind rides the id prefix.
    # The trace closes by TTL sweep in production; assert on the open state.
    {state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 900},
         %{
           provider: :openai,
           model: "gpt-5.5",
           status: :ok,
           agent: "computer_history_summarizer",
           session_id: "computer_history_summarize:1755900000000",
           tokens: %{prompt: 400, completion: 60}
         }}
      ])

    assert closed == []
    assert [{_id, trace}] = Map.to_list(state.traces)
    assert trace.tags == ["computer_history_summary"]
    # The agent name already says "computer history" — no kind prefix on top.
    assert trace.name == "computer_history_summarizer"
  end

  test "a computer-history roll-up is its own kind, nested under its cycle" do
    # The daily thread roll-up (§24.3) is a second headless call inside the
    # summarizer cycle: its own session id (so it is not mistaken for a sitting
    # summary) parented to the cycle's, and like the summarizer it has no bookend
    # events, so the kind rides the id prefix.
    {state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 1_200},
         %{
           provider: :openai,
           model: "gpt-5.5",
           status: :ok,
           agent: "computer_history_rollup",
           session_id: "computer_history_rollup:1755900000000",
           parent_session: "computer_history_summarize:1755900000000",
           tokens: %{prompt: 800, completion: 120}
         }}
      ])

    assert closed == []
    assert [{_id, trace}] = Map.to_list(state.traces)
    assert trace.tags == ["computer_history_rollup"]
    # The agent name already says what this is — no kind prefix on top.
    assert trace.name == "computer_history_rollup"
  end

  test "a soul-curation draft's synthetic command parent keeps it a standalone root" do
    # The draft's parent_session is the originating command id (never a registered
    # turn session), so it resolves to its own root trace — correlatable but
    # separate from a concurrent main turn, not collapsed into it.
    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 200},
         %{
           provider: :anthropic,
           model: "claude-opus-4-8",
           status: :ok,
           session_id: "main-1",
           tokens: %{prompt: 5, completion: 5}
         }},
        {[:fermix, :soul_curation, :run_start], %{},
         %{
           agent: "soul_curation",
           session_id: "soul_curation:def",
           parent_session: "command:soul:telegram:c1",
           mode: :review,
           with_context: false
         }},
        {[:fermix, :soul_curation, :run_complete], %{byte_delta: 0, line_delta: 0},
         %{
           agent: "soul_curation",
           session_id: "soul_curation:def",
           mode: :review,
           status: "no_change",
           byte_delta: 0,
           line_delta: 0
         }},
        {[:fermix, :agent, :message], %{},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
      ])

    # Two distinct root traces: the draft and the turn never share a trace_id.
    names = closed |> Enum.map(& &1.trace.name) |> Enum.sort()
    assert names == ["agent:main", "soul_curation:review"]
    ids = closed |> Enum.map(& &1.trace.id) |> Enum.uniq()
    assert length(ids) == 2
  end

  test "sweep force-flushes a run whose completion was never signalled" do
    agg = Aggregation.new(project: "fermix", ttl_ms: 1)

    {agg, []} =
      Aggregation.apply_event(
        agg,
        [:fermix, :provider, :call],
        %{duration_ms: 100},
        %{
          provider: :openai,
          model: "gpt-5",
          status: :ok,
          session_id: "main-9",
          tokens: %{prompt: 1, completion: 1}
        },
        %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
      )

    {_agg, closed} = Aggregation.sweep(agg, 10_000_000)
    assert [%{trace: trace}] = closed
    assert trace.name == "agent:main"
  end

  test "a scheduled run is swept by its max duration, not the idle TTL" do
    # Tiny idle TTL so a last_seen-based sweep would fire almost immediately; the
    # scheduled run must instead survive until its max_duration (+ grace) passes.
    agg = Aggregation.new(project: "fermix", ttl_ms: 1)

    {agg, []} =
      Aggregation.apply_event(
        agg,
        [:fermix, :job, :run_start],
        %{},
        %{
          agent: "scheduled:job-9",
          job_id: "job-9",
          run_id: "run-9",
          name: "slow",
          session_id: "cron_job-9_1",
          max_duration_ms: 1_000
        },
        %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
      )

    # mono is microseconds; floor = (1_000 + 60_000) * 1_000 = 61_000_000us.
    # Well past the 1us idle TTL but within the duration floor: NOT swept.
    {agg, []} = Aggregation.sweep(agg, 500_000)

    # Past max_duration + grace: swept as one trace on the job thread.
    {_agg, closed} = Aggregation.sweep(agg, 61_000_001)
    assert [%{trace: trace}] = closed
    assert trace.thread_id == "job-9"
    assert trace.name == "scheduled:slow"
  end

  test "a realtime call becomes one trace with nested llm and tool spans" do
    {_state, closed} =
      run([
        {[:fermix, :realtime, :call_start], %{},
         %{
           session_id: "session:1",
           agent: "realtime",
           device_id: "dev-1",
           model: "gpt-realtime-2",
           voice: "marin",
           session_scope: "session:1"
         }},
        {[:fermix, :realtime, :session_created], %{},
         %{session_id: "session:1", agent: "realtime", model: "gpt-realtime-2"}},
        {[:fermix, :tool, :exec], %{duration_ms: 5},
         %{tool: "browser", agent: "realtime", success: true, session_id: "session:1"}},
        {[:fermix, :provider, :call], %{duration_ms: 800},
         %{
           provider: :openai,
           model: "gpt-realtime-2",
           status: :ok,
           agent: "realtime",
           session_id: "session:1",
           tokens: %{prompt: 12, completion: 8, total: 20}
         }},
        {[:fermix, :realtime, :call_stop], %{},
         %{session_id: "session:1", agent: "realtime", model: "gpt-realtime-2", voice: "marin"}}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "realtime:session:1"
    assert "realtime" in trace.tags

    wrapper = span_named(spans, "realtime:session:1")
    assert wrapper

    [llm] = spans_of_type(spans, "llm")
    assert llm.parent_span_id == wrapper.id
    assert llm.model == "gpt-realtime-2"
    assert llm.usage == %{prompt_tokens: 12, completion_tokens: 8, total_tokens: 20}

    tool = span_named(spans, "browser")
    assert tool.parent_span_id == wrapper.id
    assert tool.type == "tool"

    created = span_named(spans, "realtime:session_created")
    assert created.parent_span_id == wrapper.id
  end

  test "a realtime call_stop folds the call's audio usage into the trace metadata" do
    {_state, closed} =
      run([
        {[:fermix, :realtime, :call_start], %{},
         %{
           session_id: "session:2",
           agent: "realtime",
           device_id: "dev-1",
           model: "gpt-realtime-2",
           voice: "marin",
           session_scope: "session:2"
         }},
        {[:fermix, :realtime, :call_stop],
         %{
           input_audio_ms: 2400,
           input_audio_tokens: 24,
           estimated_cost_cents: 0.0768,
           reported_cost_cents: 0.0
         },
         %{session_id: "session:2", agent: "realtime", model: "gpt-realtime-2", voice: "marin"}}
      ])

    assert [%{trace: trace}] = closed
    assert trace.metadata.input_audio_ms == 2400
    assert trace.metadata.input_audio_tokens == 24
    assert trace.metadata.estimated_cost_cents == 0.0768
    assert trace.metadata.reported_cost_cents == 0.0
  end

  test "a plugin dist op is its own self-closing trace" do
    {state, closed} =
      run([
        {[:fermix, :plugin, :dist], %{duration_ms: 120},
         %{op: :install, plugin: "github", version: "1.2.0", result: :installed, reason: nil}}
      ])

    assert [%{trace: trace, spans: []}] = closed
    assert trace.name == "dist:install"
    assert trace.tags == ["dist"]
    assert trace.metadata.plugin == "github"
    assert trace.metadata.version == "1.2.0"
    assert trace.metadata.result == "installed"
    assert trace.metadata.duration_ms == 120
    # Self-closing: nothing left open to sweep.
    assert state.traces == %{}
  end

  test "a failed dist op carries its reason" do
    {_state, closed} =
      run([
        {[:fermix, :plugin, :dist], %{duration_ms: 5},
         %{
           op: :install,
           plugin: "github",
           version: "1.2.0",
           result: :error,
           reason: {:verification_failed, :untrusted}
         }}
      ])

    assert [%{trace: trace, spans: []}] = closed
    assert trace.metadata.result == "error"
    assert trace.metadata.reason == "{:verification_failed, :untrusted}"
  end

  # Plugin auth ops ([:fermix, :plugin, :auth]) are sessionless point events, so
  # each is its own self-closing trace, the plugin-dist shape.
  #
  # `@plugin_auth_ops` mirrors `FermixCore.Plugins.Auth.Telemetry.ops/0` by hand:
  # this app declares no dependency on fermix_core. The emitter's own test pins
  # `ops/0` against the same literal list, so a new op fails until both agree.
  @plugin_auth_event [:fermix, :plugin, :auth]
  @plugin_auth_ops [:login, :refresh, :logout, :set, :clear]

  describe "plugin auth ops" do
    test "the reporter subscribes to the event" do
      assert @plugin_auth_event in FermixOpik.Reporter.events()
    end

    test "every op is its own self-closing trace, never the catch-all" do
      for op <- @plugin_auth_ops do
        {state, closed} =
          run([
            {@plugin_auth_event, %{duration_ms: 9},
             %{op: op, plugin: "github", result: :logged_out}}
          ])

        assert [%{trace: trace, spans: []}] = closed,
               "op #{inspect(op)} produced no trace — it fell to the catch-all"

        assert trace.name == "auth:#{op}"
        assert trace.tags == ["auth"]
        assert state.traces == %{}
      end
    end

    test "a refused sign-in client carries its class and the vendor's own words" do
      {_state, closed} =
        run([
          {@plugin_auth_event, %{duration_ms: 240},
           %{
             op: :login,
             plugin: "x",
             result: :error,
             error_class: :oauth_client_rejected,
             vendor_error: "unauthorized_client",
             vendor_description: "Missing valid authorization header"
           }}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "auth:login"

      assert trace.metadata == %{
               plugin: "x",
               result: "error",
               error_class: "oauth_client_rejected",
               vendor_error: "unauthorized_client",
               vendor_description: "Missing valid authorization header",
               duration_ms: 240
             }
    end

    test "a success exports its tag and nothing the emitter did not set" do
      {_state, closed} =
        run([
          {@plugin_auth_event, %{duration_ms: 31},
           %{op: :refresh, plugin: "github", result: :ready}}
        ])

      assert [%{trace: trace}] = closed
      assert trace.metadata == %{plugin: "github", result: "ready", duration_ms: 31}
    end
  end

  test "a memory:write event becomes a tool span and the reviewer trace gets the conversation thread_id" do
    sid = "memory_review:main:cli:e2e-x:owner:42"

    {state, _closed} =
      run([
        # The reviewer's provider call carries NO chat_id (it opens the trace
        # with a nil thread); the memory:write event is what backfills the
        # conversation thread_id — exactly the live path.
        {[:fermix, :provider, :call], %{duration_ms: 800},
         %{
           provider: :anthropic,
           model: "claude-opus-4-8",
           status: :ok,
           session_id: sid,
           agent: "memory_reviewer"
         }},
        {[:fermix, :memory, :write], %{count: 1},
         %{
           session_id: sid,
           agent: "memory_reviewer",
           channel: "cli",
           chat_id: "e2e-x",
           action: :added,
           category: "preference",
           key: "review_preference_abc_1",
           scope_type: "owner",
           memory_id: 7,
           tool: "memory_write"
         }}
      ])

    # Reviewer runs after the turn closed, so it is its own root trace — but it
    # must carry the conversation thread_id so it groups with the turn, and the
    # write must be an observable span (not invisible like the old behavior).
    {_state, drained} = Aggregation.drain(state)
    assert [%{trace: trace, spans: spans}] = drained
    assert trace.name == "memory_review:memory_reviewer"
    assert trace.thread_id == "cli:e2e-x"

    write = span_named(spans, "memory_write")
    assert write.type == "tool"
    assert write.metadata.action == :added
    assert write.metadata.category == "preference"
    assert write.metadata.memory_id == 7

    wrapper = span_named(spans, "memory_review:memory_reviewer")
    assert write.parent_span_id == wrapper.id
  end

  test "a child-span event without a chat_id does not invent a thread_id" do
    {state, _closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 100},
         %{provider: :anthropic, model: "claude-opus-4-8", status: :ok, session_id: "main-9"}}
      ])

    {_state, drained} = Aggregation.drain(state)
    assert [%{trace: trace}] = drained
    refute Map.has_key?(trace, :thread_id)
  end

  test "a harness run is its own root trace, correlated to the turn but never nested" do
    # The harness run spawns from main-1, but its run_start hard-codes
    # parent_session: nil, so it opens a standalone root even while main-1's
    # session is live — and finishes after main-1 already closed and shipped,
    # without resurrecting or nesting into the turn's trace.
    {_state, closed} =
      run([
        {[:fermix, :provider, :call], %{duration_ms: 200},
         %{
           provider: :openai,
           model: "gpt-5",
           status: :ok,
           session_id: "main-1",
           tokens: %{prompt: 5, completion: 5}
         }},
        {[:fermix, :harness, :run_start], %{},
         %{
           agent: "harness:codex",
           run_id: "hr_abc",
           vendor: "codex",
           rail: "local",
           origin_kind: "chat",
           origin_session_id: "main-1",
           session_id: "harness_hr_abc"
         }},
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
         %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}},
        {[:fermix, :provider, :call], %{duration_ms: 900},
         %{
           provider: :openai_codex,
           model: "gpt-5-codex",
           status: :ok,
           session_id: "harness_hr_abc",
           tokens: %{prompt: 20, completion: 10}
         }},
        {[:fermix, :harness, :run_complete], %{duration_ms: 1_100},
         %{
           agent: "harness:codex",
           run_id: "hr_abc",
           vendor: "codex",
           origin_session_id: "main-1",
           session_id: "harness_hr_abc",
           status: "completed",
           reason: nil,
           exit_code: 0,
           usage: %{total_cost_usd: 0.02}
         }}
      ])

    # Two distinct root traces: the turn and the harness run never share a trace id.
    names = closed |> Enum.map(& &1.trace.name) |> Enum.sort()
    assert names == ["agent:main", "harness:codex"]
    ids = closed |> Enum.map(& &1.trace.id) |> Enum.uniq()
    assert length(ids) == 2

    harness = Enum.find(closed, &(&1.trace.name == "harness:codex"))
    assert "harness" in harness.trace.tags
    assert harness.trace.metadata.origin_session_id == "main-1"
    assert harness.trace.metadata.vendor == "codex"
    assert harness.trace.metadata.exit_code == 0

    # The harness run's own provider.call nested under its wrapper, not the turn.
    wrapper = span_named(harness.spans, "harness:codex")
    [llm] = spans_of_type(harness.spans, "llm")
    assert llm.parent_span_id == wrapper.id
    assert llm.trace_id == harness.trace.id
    assert llm.model == "gpt-5-codex"

    # The turn trace carries only its own llm span, not the harness one.
    turn = Enum.find(closed, &(&1.trace.name == "agent:main"))
    assert [turn_llm] = spans_of_type(turn.spans, "llm")
    assert turn_llm.model == "gpt-5"
  end

  test "a harness progress event nests as a child span under the run trace" do
    {_state, closed} =
      run([
        {[:fermix, :harness, :run_start], %{},
         %{
           agent: "harness:codex",
           run_id: "hr_p",
           vendor: "codex",
           origin_session_id: "main-1",
           session_id: "harness_hr_p"
         }},
        {[:fermix, :harness, :progress], %{events: 12, framing_errors: 0},
         %{
           agent: "harness:codex",
           run_id: "hr_p",
           vendor: "codex",
           session_id: "harness_hr_p",
           phase: "running"
         }},
        {[:fermix, :harness, :run_complete], %{duration_ms: 500},
         %{
           agent: "harness:codex",
           run_id: "hr_p",
           vendor: "codex",
           session_id: "harness_hr_p",
           status: "completed",
           exit_code: 0
         }}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "harness:codex"

    wrapper = span_named(spans, "harness:codex")
    progress = span_named(spans, "harness:progress")
    assert progress.parent_span_id == wrapper.id
    assert progress.trace_id == trace.id
    assert progress.metadata.events == 12
    assert progress.metadata.framing_errors == 0
    assert progress.metadata.phase == "running"
  end

  test "a harness run is swept by its max duration, not the idle TTL" do
    # Tiny idle TTL so a last_seen-based sweep would fire immediately; the harness
    # run must instead survive until its max_duration (+ grace) passes.
    agg = Aggregation.new(project: "fermix", ttl_ms: 1)

    {agg, []} =
      Aggregation.apply_event(
        agg,
        [:fermix, :harness, :run_start],
        %{},
        %{
          agent: "harness:codex",
          run_id: "hr_slow",
          vendor: "codex",
          origin_session_id: "main-1",
          session_id: "harness_hr_slow",
          max_duration_ms: 1_000
        },
        %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
      )

    # mono is microseconds; floor = (1_000 + 60_000) * 1_000 = 61_000_000us.
    # Well past the 1us idle TTL but within the duration floor: NOT swept.
    {agg, []} = Aggregation.sweep(agg, 500_000)

    # Past max_duration + grace: swept as one harness trace.
    {_agg, closed} = Aggregation.sweep(agg, 61_000_001)
    assert [%{trace: trace}] = closed
    assert trace.name == "harness:codex"
    assert "harness" in trace.tags
    assert trace.metadata.origin_session_id == "main-1"
  end

  # Outbound MCP client lifecycle ([:fermix, :mcp_client, :lifecycle]).
  #
  # `@mcp_client_phases` mirrors `FermixCore.Capabilities.MCP.Telemetry.phases/0`
  # by hand: `fermix_opik` deliberately declares no dependency on `fermix_core`
  # (it must stay standalone-testable), so the emitter's list cannot be read here.
  # Its counterpart test in
  # `apps/fermix_core/test/fermix_core/capabilities/mcp/telemetry_test.exs` pins
  # `phases/0` against the same literal list, so adding a phase there fails until
  # both halves are updated.
  @mcp_client_event [:fermix, :mcp_client, :lifecycle]
  @mcp_client_boot_phases [:initialize, :discover, :ready, :owner_down, :teardown]
  @mcp_client_turn_phases [:security_block, :drift, :reconnect]
  @mcp_client_phases @mcp_client_boot_phases ++ @mcp_client_turn_phases

  defp mcp_meta(phase, extra \\ %{}) do
    Map.merge(%{source_id: "plugin:acme", plugin: "acme", phase: phase, result: :ok}, extra)
  end

  describe "outbound MCP client lifecycle" do
    test "the reporter subscribes to the event" do
      assert @mcp_client_event in FermixOpik.Reporter.events()
    end

    # Registry completeness: every phase must hit a real clause, never the
    # catch-all (which returns `{state, []}` and leaves nothing behind). Looping
    # the phase list is the gate — a phase added later either joins it or fails.
    test "every phase is handled by a non-catch-all clause" do
      for phase <- @mcp_client_phases do
        {state, closed} = run([{@mcp_client_event, %{duration_ms: 4}, mcp_meta(phase)}])

        assert [%{trace: trace, spans: []}] = closed,
               "phase #{inspect(phase)} produced no trace — it fell to the catch-all"

        assert trace.name == "mcp_client:#{phase}"
        assert trace.tags == ["mcp_client"]
        assert state.traces == %{}
      end
    end

    test "a boot phase self-closes even when a session_id is somehow present" do
      # initialize/discover/ready/teardown/owner_down run before any turn. Nesting
      # one under a non-turn session id would mint a phantom root whose
      # `infer_kind/1` falls through to :subagent — the orphan-span bug.
      for phase <- @mcp_client_boot_phases do
        {state, closed} =
          run([
            {@mcp_client_event, %{duration_ms: 4},
             mcp_meta(phase, %{session_id: "mcp_client_boot"})}
          ])

        assert [%{trace: trace, spans: []}] = closed
        assert trace.name == "mcp_client:#{phase}"
        refute "subagent" in trace.tags
        assert state.traces == %{}
        assert state.sessions == %{}
      end
    end

    test "a boot-phase trace carries the emitter's redacted metadata" do
      {_state, closed} =
        run([
          {@mcp_client_event, %{duration_ms: 87},
           mcp_meta(:initialize, %{result: :error, error_class: "remote_unreachable", attempt: 3})}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.metadata.source_id == "plugin:acme"
      assert trace.metadata.plugin == "acme"
      assert trace.metadata.phase == "initialize"
      assert trace.metadata.result == "error"
      assert trace.metadata.error_class == "remote_unreachable"
      assert trace.metadata.attempt == 3
      assert trace.metadata.duration_ms == 87
    end

    test "a turn phase nests under the turn that hit it" do
      for phase <- @mcp_client_turn_phases do
        {_state, closed} =
          run([
            {[:fermix, :provider, :call], %{duration_ms: 10},
             %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
            {@mcp_client_event, %{duration_ms: 2},
             mcp_meta(phase, %{
               result: :error,
               error_class: "tool_not_allowed",
               session_id: "main-1"
             })},
            {[:fermix, :agent, :message], %{iterations: 1},
             %{channel: :cli, chat_id: "c1", session_id: "main-1", agent: "main"}}
          ])

        assert [%{trace: trace, spans: spans}] = closed
        assert trace.name == "agent:main"

        span = span_named(spans, "mcp_client:#{phase}")
        assert span, "phase #{inspect(phase)} produced no child span under the turn"
        assert span.trace_id == trace.id
        assert span.parent_span_id == span_named(spans, "agent:main").id
        assert span.metadata.error_class == "tool_not_allowed"
      end
    end

    test "a turn phase outside a turn self-closes rather than orphaning" do
      {state, closed} =
        run([{@mcp_client_event, %{duration_ms: 1}, mcp_meta(:reconnect, %{attempt: 2})}])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "mcp_client:reconnect"
      assert state.traces == %{}
    end
  end

  # Proactive reminder lifecycle ([:fermix, :reminder, :lifecycle], M30 §15.2).
  #
  # `@reminder_phases` mirrors `FermixCore.Temporal.Telemetry.phases/0` by hand:
  # `fermix_opik` deliberately declares no dependency on `fermix_core` (it must
  # stay standalone-testable), so the emitter's list cannot be read here. Its
  # counterpart test in
  # `apps/fermix_core/test/fermix_core/temporal/telemetry_test.exs` pins
  # `phases/0` against the same literal list, so adding a phase there fails until
  # both halves are updated.
  @reminder_event [:fermix, :reminder, :lifecycle]
  @reminder_phases [
    :materialized,
    :claimed,
    :delivered,
    :retry_scheduled,
    :failed,
    :expired,
    :superseded,
    :cancelled,
    :event_completed,
    :scheduler_error,
    # A follow-up that never became a run: no session, so it stays a point event
    # on this lifecycle and costs the exporter nothing beyond this list. A
    # follow-up that DID start owns a session and is the run below.
    :followup_skipped
  ]

  defp reminder_meta(phase, extra \\ %{}) do
    Map.merge(
      %{
        component: "temporal_scheduler",
        phase: phase,
        event_id: "evt_1",
        reminder_id: "rem_1",
        occurrence_key: "2026-09-14",
        rule_id: "day_of",
        platform: "telegram",
        result: :ok
      },
      extra
    )
  end

  describe "proactive reminder lifecycle" do
    test "the reporter subscribes to the event" do
      assert @reminder_event in FermixOpik.Reporter.events()
    end

    # Registry completeness: every phase must hit a real clause, never the
    # catch-all (which returns `{state, []}` and leaves nothing behind).
    test "every phase is handled by a non-catch-all clause" do
      for phase <- @reminder_phases do
        {state, closed} = run([{@reminder_event, %{count: 1}, reminder_meta(phase)}])

        assert [%{trace: trace, spans: []}] = closed,
               "phase #{inspect(phase)} produced no trace — it fell to the catch-all"

        assert trace.name == "reminder:#{phase}"
        assert trace.tags == ["reminder"]
        assert state.traces == %{}
      end
    end

    # A reminder delivery is not an agent run (§6.4): it has no session, so it
    # must never nest under one or mint a phantom root to hang itself on.
    test "a lifecycle event never nests under a turn or opens a session" do
      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 10},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@reminder_event, %{duration_ms: 12}, reminder_meta(:delivered)},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :cli, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      names = Enum.map(closed, & &1.trace.name)
      assert "reminder:delivered" in names
      assert "agent:main" in names

      turn = Enum.find(closed, &(&1.trace.name == "agent:main"))
      refute span_named(turn.spans, "reminder:delivered")
      assert state.traces == %{}
    end

    test "the trace carries the emitter's correlation fields" do
      {_state, closed} =
        run([
          {@reminder_event, %{duration_ms: 87},
           reminder_meta(:failed, %{
             result: :error,
             error_class: "permanent",
             attempt: 5
           })}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.metadata.component == "temporal_scheduler"
      assert trace.metadata.phase == "failed"
      assert trace.metadata.event_id == "evt_1"
      assert trace.metadata.reminder_id == "rem_1"
      assert trace.metadata.occurrence_key == "2026-09-14"
      assert trace.metadata.rule_id == "day_of"
      assert trace.metadata.platform == "telegram"
      assert trace.metadata.result == "error"
      assert trace.metadata.error_class == "permanent"
      assert trace.metadata.attempt == 5
      assert trace.metadata.duration_ms == 87
    end
  end

  # Post-delivery follow-up run ([:fermix, :reminder, :followup_start |
  # :followup_complete | :followup_error], M30 §22.7). The delivery lifecycle
  # above is session-less by design; this one IS an agent run — it drives the
  # loop in its own context — so it owns a session, opens a ROOT trace, and its
  # provider/tool spans nest under it through the shared session_id.
  @followup_start [:fermix, :reminder, :followup_start]
  @followup_complete [:fermix, :reminder, :followup_complete]
  @followup_error [:fermix, :reminder, :followup_error]
  @followup_session "followup_rem_1"

  # The emitter's own metadata shape (FermixCore.Temporal.FollowupTelemetry):
  # correlation ids, the run's agent name, and a component tag. `fermix_opik`
  # declares no dependency on `fermix_core`, so this mirrors it by hand, exactly
  # like `reminder_meta/2` above.
  defp followup_meta(extra \\ %{}) do
    Map.merge(
      %{
        component: "temporal_followup",
        agent: "followup:evt_1",
        session_id: @followup_session,
        event_id: "evt_1",
        reminder_id: "rem_1",
        occurrence_key: "2026-09-14"
      },
      extra
    )
  end

  describe "post-delivery follow-up run" do
    test "a follow-up is swept by its max duration, not the idle TTL" do
      # The run's wall-clock watchdog and the default idle TTL are both 120s, so
      # without a sweep floor a slow first provider call could get the root
      # force-closed just before its closer arrives (which would then tombstone).
      agg = Aggregation.new(project: "fermix", ttl_ms: 1)

      {agg, []} =
        Aggregation.apply_event(
          agg,
          @followup_start,
          %{count: 1},
          followup_meta(%{max_duration_ms: 1_000}),
          %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
        )

      # mono is microseconds; floor = (1_000 + 60_000) * 1_000 = 61_000_000us.
      # Well past the 1us idle TTL but within the duration floor: NOT swept.
      {agg, []} = Aggregation.sweep(agg, 500_000)

      # Past max_duration + grace: swept as one unthreaded root.
      {_agg, closed} = Aggregation.sweep(agg, 61_000_001)
      assert [%{trace: trace}] = closed
      assert trace.name == "followup:evt_1"
      refute Map.has_key?(trace, :thread_id)
    end

    test "the reporter subscribes to all three bookends" do
      for event <- [@followup_start, @followup_complete, @followup_error] do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so the run is invisible to Opik"
      end
    end

    test "a follow-up run is its own root trace nesting its provider and tool spans" do
      {_state, closed} =
        run([
          {@followup_start, %{count: 1}, followup_meta()},
          {[:fermix, :provider, :call], %{duration_ms: 700},
           %{
             provider: :anthropic,
             model: "claude-opus-4-8",
             status: :ok,
             session_id: @followup_session,
             tokens: %{prompt: 90, completion: 25}
           }},
          {[:fermix, :tool, :exec], %{duration_ms: 12},
           %{tool: "memory_store", success: true, session_id: @followup_session}},
          {@followup_complete, %{duration_ms: 4_200},
           followup_meta(%{outcome: "sent", output: "Want me to draft her a note?"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "followup:evt_1"
      assert trace.tags == ["reminder_followup"]
      assert trace.output == %{text: "Want me to draft her a note?"}
      assert trace.metadata.outcome == "sent"
      assert trace.metadata.component == "temporal_followup"
      assert trace.metadata.event_id == "evt_1"
      assert trace.metadata.reminder_id == "rem_1"
      assert trace.metadata.occurrence_key == "2026-09-14"
      # A run that reached a decision is a successful run, whatever it decided.
      refute Map.has_key?(trace.metadata, :status)

      # No destination anywhere: the temporal family never carries the delivery
      # target, so the follow-up is an unthreaded root found by session/event id.
      refute Map.has_key?(trace, :thread_id)

      wrapper = span_named(spans, "followup:evt_1")
      refute Map.has_key?(wrapper, :parent_span_id)

      assert [llm] = spans_of_type(spans, "llm")
      assert [tool] = spans_of_type(spans, "tool")
      assert llm.parent_span_id == wrapper.id
      assert tool.parent_span_id == wrapper.id
      assert llm.trace_id == trace.id
      assert tool.trace_id == trace.id
    end

    # The turn that stored the event closed hours or days before delivery, so the
    # run is a root by construction — nesting would resurrect a closed trace (the
    # harness precedent). The opener hard-codes nil, which this pins by naming a
    # live parent and proving it is ignored.
    test "the run stays a root even when a live parent session is named" do
      {_state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 100},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@followup_start, %{count: 1}, followup_meta(%{parent_session: "main-1"})},
          {@followup_complete, %{duration_ms: 900}, followup_meta(%{outcome: "declined"})},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      names = closed |> Enum.map(& &1.trace.name) |> Enum.sort()
      assert names == ["agent:main", "followup:evt_1"]
      assert closed |> Enum.map(& &1.trace.id) |> Enum.uniq() |> length() == 2

      followup = Enum.find(closed, &(&1.trace.name == "followup:evt_1"))
      assert followup.trace.metadata.outcome == "declined"
      # Declining sends nothing, so there is no owner-facing text to carry.
      refute Map.has_key?(followup.trace, :output)
      refute Map.has_key?(span_named(followup.spans, "followup:evt_1"), :parent_span_id)

      turn = Enum.find(closed, &(&1.trace.name == "agent:main"))
      refute span_named(turn.spans, "followup:evt_1")
    end

    test "a run that never reached a decision closes with its own status word" do
      for status <- ["error", "timeout"] do
        {_state, closed} =
          run([
            {@followup_start, %{count: 1}, followup_meta()},
            {@followup_error, %{duration_ms: 120_000},
             followup_meta(%{status: status, error: "wall-clock timeout after 120000ms"})}
          ])

        assert [%{trace: trace}] = closed
        assert trace.metadata.status == status, "the #{status} status never reached the trace"
        assert trace.output == %{text: "wall-clock timeout after 120000ms"}
        assert trace.metadata.event_id == "evt_1"
        assert trace.metadata.reminder_id == "rem_1"
      end
    end

    # A run whose first exported event is a provider call — the opener lost the
    # race, or was never delivered — must still classify from its session prefix
    # rather than falling through to :subagent, which is the only evidence left.
    test "a span arriving before the opener classifies the lazily created run" do
      {_state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 300},
           %{
             provider: :anthropic,
             model: "claude-opus-4-8",
             status: :ok,
             session_id: @followup_session,
             agent: "followup:evt_1"
           }},
          {@followup_complete, %{duration_ms: 800}, followup_meta(%{outcome: "empty"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.tags == ["reminder_followup"]
      assert trace.name == "followup:evt_1"
      assert trace.metadata.outcome == "empty"
      assert [llm] = spans_of_type(spans, "llm")
      assert llm.parent_span_id == span_named(spans, "followup:evt_1").id
    end
  end

  # Meeting runs ([:fermix, :meeting, :run_start | :run_complete | :run_error |
  # :phase], M21 §11.1). A meeting outlives the turn that asked for it by an
  # hour, so it is a root run of its own — the follow-up/harness shape — with the
  # phase transitions as point spans inside it.
  @meeting_start [:fermix, :meeting, :run_start]
  @meeting_complete [:fermix, :meeting, :run_complete]
  @meeting_error [:fermix, :meeting, :run_error]
  @meeting_phase [:fermix, :meeting, :phase]
  @meeting_session "meeting_mtg_ab12cd_20260602_120000"

  # The emitter's own metadata shape (FermixCore.Meetings.Telemetry). `fermix_opik`
  # declares no dependency on `fermix_core`, so this mirrors it by hand, exactly
  # like `reminder_meta/2` and `followup_meta/1` above.
  defp meeting_meta(extra \\ %{}) do
    Map.merge(
      %{
        agent: "meeting:mtg_ab12cd",
        meeting_id: "mtg_ab12cd",
        platform: "meet",
        session_id: @meeting_session,
        origin: "channel"
      },
      extra
    )
  end

  describe "meeting runs" do
    test "the reporter subscribes to all four events" do
      for event <- [@meeting_start, @meeting_complete, @meeting_error, @meeting_phase] do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so the run is invisible to Opik"
      end
    end

    test "a meeting is its own root trace nesting its phase, provider and tool spans" do
      {_state, closed} =
        run([
          {@meeting_start, %{}, meeting_meta()},
          {@meeting_phase, %{count: 1}, meeting_meta(%{from: :admitted, to: :capturing})},
          {[:fermix, :provider, :call], %{duration_ms: 900},
           %{
             provider: :deepgram,
             model: "nova-3",
             status: :ok,
             session_id: @meeting_session,
             tokens: %{}
           }},
          {[:fermix, :tool, :exec], %{duration_ms: 20},
           %{tool: "send_message", success: true, session_id: @meeting_session}},
          {@meeting_complete,
           %{duration_ms: 3_600_000, segments: 412, words: 8_900, participants_peak: 5},
           meeting_meta(%{status: "delivered"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "meeting:mtg_ab12cd"
      assert trace.tags == ["meeting"]
      assert trace.metadata.meeting_id == "mtg_ab12cd"
      assert trace.metadata.platform == "meet"
      assert trace.metadata.origin == "channel"
      assert trace.metadata.status == "delivered"
      assert trace.metadata.segments == 412
      assert trace.metadata.words == 8_900
      assert trace.metadata.participants_peak == 5

      # The meetings family never carries a delivery destination on the run, so
      # the meeting is an unthreaded root found by its meeting/session ids.
      refute Map.has_key?(trace, :thread_id)

      wrapper = span_named(spans, "meeting:mtg_ab12cd")
      refute Map.has_key?(wrapper, :parent_span_id)

      phase = span_named(spans, "meeting:capturing")
      assert phase.parent_span_id == wrapper.id
      assert phase.metadata.from == "admitted"

      assert [llm] = spans_of_type(spans, "llm")
      assert [tool] = spans_of_type(spans, "tool")
      assert llm.parent_span_id == wrapper.id
      assert tool.parent_span_id == wrapper.id
      assert llm.trace_id == trace.id
      assert tool.trace_id == trace.id
    end

    # The turn that asked for the meeting closes within seconds while the meeting
    # runs for an hour, so nesting under it would ship the trace early and leave
    # every later span to the tombstone (the harness root reason). The opener
    # hard-codes nil, which this pins by naming a LIVE parent and proving it is
    # kept as correlation metadata only.
    test "the run stays a root even when the originating turn is still open" do
      {_state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 100},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@meeting_start, %{}, meeting_meta(%{parent_session: "main-1"})},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}},
          {@meeting_complete, %{duration_ms: 60_000, segments: 3},
           meeting_meta(%{parent_session: "main-1", status: "delivered"})}
        ])

      names = closed |> Enum.map(& &1.trace.name) |> Enum.sort()
      assert names == ["agent:main", "meeting:mtg_ab12cd"]
      assert closed |> Enum.map(& &1.trace.id) |> Enum.uniq() |> length() == 2

      meeting = Enum.find(closed, &(&1.trace.name == "meeting:mtg_ab12cd"))
      assert meeting.trace.metadata.parent_session == "main-1"
      refute Map.has_key?(span_named(meeting.spans, "meeting:mtg_ab12cd"), :parent_span_id)

      turn = Enum.find(closed, &(&1.trace.name == "agent:main"))
      refute span_named(turn.spans, "meeting:mtg_ab12cd")
    end

    # The terminal state word IS the diagnosis (which wall the meeting hit), so
    # the closer must not flatten it to a generic "error".
    test "a failed run keeps its terminal state word and exports as errored" do
      {_state, closed} =
        run([
          {@meeting_start, %{}, meeting_meta()},
          {@meeting_error, %{count: 1, duration_ms: 4_000},
           meeting_meta(%{status: "failed", error: "join_denied"})}
        ])

      assert [%{trace: trace}] = closed
      assert trace.metadata.status == "failed"
      assert trace.output == %{text: "join_denied"}
      assert trace.error_info == %{exception_type: "MeetingError", message: "join_denied"}
    end

    # A run whose first exported event is a phase transition — the opener lost the
    # race, or was never delivered — must still classify from its session prefix
    # rather than falling through to :subagent.
    test "a phase span arriving before the opener classifies the lazily created run" do
      {_state, closed} =
        run([
          {@meeting_phase, %{count: 1}, meeting_meta(%{from: :joining, to: :admitted})},
          {@meeting_complete, %{duration_ms: 1_000, segments: 1},
           meeting_meta(%{status: "delivered"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.tags == ["meeting"], "the run fell through to the :subagent fallback"
      assert trace.name == "meeting:mtg_ab12cd"

      assert span_named(spans, "meeting:admitted").parent_span_id ==
               span_named(spans, "meeting:mtg_ab12cd").id
    end

    # The URL can embed a passcode and the title is meeting content, so both are
    # gated at the emitter: this module exports exactly what it was handed.
    test "the URL and title export only when the emitter passed them" do
      {_state, bare} =
        run([
          {@meeting_start, %{}, meeting_meta()},
          {@meeting_phase, %{count: 1},
           meeting_meta(%{from: :capturing, to: :summarizing, reason: :meeting_ended})},
          {@meeting_complete, %{duration_ms: 10}, meeting_meta(%{status: "delivered"})}
        ])

      assert [%{trace: trace, spans: spans}] = bare
      refute Map.has_key?(span_named(spans, "meeting:mtg_ab12cd"), :input)
      refute Map.has_key?(trace.metadata, :title)
      assert span_named(spans, "meeting:summarizing").metadata.reason == "meeting_ended"

      {_state, captured} =
        run([
          {@meeting_start, %{},
           meeting_meta(%{url: "https://meet.google.com/abc-defg-hij", title: "Board sync"})},
          {@meeting_complete, %{duration_ms: 10}, meeting_meta(%{status: "delivered"})}
        ])

      assert [%{trace: trace, spans: spans}] = captured
      # The URL rides the run wrapper's input, the job/harness precedent.
      assert span_named(spans, "meeting:mtg_ab12cd").input ==
               %{text: "https://meet.google.com/abc-defg-hij"}

      assert trace.metadata.title == "Board sync"
    end

    # A quiet meeting emits nothing between phase transitions and would be
    # force-closed by the idle TTL mid-call, minting a second root when its
    # closer finally arrives (the follow-up precedent).
    test "a meeting is swept by its max duration, not the idle TTL" do
      agg = Aggregation.new(project: "fermix", ttl_ms: 1)

      {agg, []} =
        Aggregation.apply_event(
          agg,
          @meeting_start,
          %{},
          meeting_meta(%{max_duration_ms: 1_000}),
          %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
        )

      # mono is microseconds; floor = (1_000 + 60_000) * 1_000 = 61_000_000us.
      {agg, []} = Aggregation.sweep(agg, 500_000)

      {_agg, closed} = Aggregation.sweep(agg, 61_000_001)
      assert [%{trace: trace}] = closed
      assert trace.name == "meeting:mtg_ab12cd"
    end
  end

  @voice_live_start [:fermix, :voice_live, :call_start]
  @voice_live_session_started [:fermix, :voice_live, :session_started]
  @voice_live_delegation_start [:fermix, :voice_live, :delegation_start]
  @voice_live_delegation_stop [:fermix, :voice_live, :delegation_stop]
  @voice_live_provider_error [:fermix, :voice_live, :provider_error]
  @voice_live_stop [:fermix, :voice_live, :call_stop]
  @voice_live_call "voice_live:1"
  @voice_delegation_session "voice_delegation_7"

  # The emitter's own metadata shape (FermixCore.Realtime.LiveTelemetry).
  # `fermix_opik` declares no dependency on `fermix_core`, so this mirrors it by
  # hand, exactly like `meeting_meta/1` and `followup_meta/1` above.
  defp voice_live_meta(extra) do
    Map.merge(
      %{
        agent: "voice_live",
        session_id: @voice_live_call,
        device_id: "dev-1",
        model: "gpt-live-1",
        voice: "marin",
        engine: "openai_live"
      },
      extra
    )
  end

  describe "live voice runs" do
    test "the reporter subscribes to every voice_live event" do
      for event <- [
            @voice_live_start,
            @voice_live_session_started,
            @voice_live_delegation_start,
            @voice_live_delegation_stop,
            @voice_live_provider_error,
            @voice_live_stop
          ] do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so the run is invisible to Opik"
      end
    end

    test "a live call becomes one trace whose delegation turn nests under the root via parent_session" do
      {_state, closed} =
        run([
          {@voice_live_start, %{}, voice_live_meta(%{max_duration_ms: 900_000})},
          {@voice_live_session_started, %{},
           voice_live_meta(%{provider_session_id: "sess_live_abc"})},
          # The backend turn is its own run: its session id is minted by the Live
          # session and its parent_session is the CALL, which is the only link
          # between the two — a delegation carries no other correlation.
          {[:fermix, :provider, :call], %{duration_ms: 900},
           %{
             provider: :anthropic,
             model: "claude-opus-4-8",
             status: :ok,
             agent: "main",
             session_id: @voice_delegation_session,
             parent_session: @voice_live_call,
             tokens: %{prompt: 120, completion: 40}
           }},
          {@voice_live_delegation_start, %{},
           voice_live_meta(%{
             delegation_id: "dlg_1",
             revision: 1,
             turn_session_id: @voice_delegation_session
           })},
          {@voice_live_delegation_stop, %{duration_ms: 1_200},
           voice_live_meta(%{
             delegation_id: "dlg_1",
             revision: 1,
             turn_session_id: @voice_delegation_session,
             status: "completed"
           })},
          {@voice_live_stop,
           %{
             voice_seconds: 62,
             voice_cost_millicents: 5_167,
             backend_turns: 1,
             accounting_complete: 1
           }, voice_live_meta(%{reason: "call_stop"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "voice_live:1"
      assert trace.tags == ["voice_live"]
      # A call that ended on its own terms is not flagged errored; `reason`
      # below is what names the wall when one was hit.
      refute Map.has_key?(trace, :error_info)

      # The call's own wrapper IS the root: no parent span id survives export.
      root = span_named(spans, "voice_live:1")
      refute Map.has_key?(root, :parent_span_id)

      # The delegation's own wrapper hangs off the root wrapper, and the model
      # call hangs off the delegation — one trace, two runs, no orphan root.
      delegation = span_named(spans, @voice_delegation_session)
      assert delegation.parent_span_id == root.id

      [llm] = spans_of_type(spans, "llm")
      assert llm.parent_span_id == delegation.id
      assert llm.usage == %{prompt_tokens: 120, completion_tokens: 40, total_tokens: 160}

      started = span_named(spans, "voice_live:session_started")
      assert started.parent_span_id == root.id
      assert started.metadata.provider_session_id == "sess_live_abc"

      stopped = span_named(spans, "voice_live:delegation_stop")
      assert stopped.metadata.status == "completed"
      assert stopped.metadata.turn_session_id == @voice_delegation_session

      # Voice is duration-priced: the ledger rides the trace, never as tokens.
      assert trace.metadata.voice_seconds == 62
      assert trace.metadata.voice_cost_millicents == 5_167
      assert trace.metadata.backend_turns == 1
      assert trace.metadata.accounting_complete == 1
      assert trace.metadata.reason == "call_stop"
      assert trace.metadata.engine == "openai_live"
      assert trace.metadata.model == "gpt-live-1"
    end

    test "a provider_error is a phase span, never a terminal event" do
      {state, closed} =
        run([
          {@voice_live_start, %{}, voice_live_meta(%{max_duration_ms: 900_000})},
          {@voice_live_provider_error, %{},
           voice_live_meta(%{reason: "moderation cut the reply"})}
        ])

      assert closed == []
      assert map_size(state.traces) == 1
    end

    # A Live call is silent between delegations for minutes at a time; the idle
    # TTL would force-close it mid-call and mint a second root when call_stop
    # finally arrived (the meeting/follow-up precedent).
    test "a live call is swept by its max duration, not the idle TTL" do
      agg = Aggregation.new(project: "fermix", ttl_ms: 1)

      {agg, []} =
        Aggregation.apply_event(
          agg,
          @voice_live_start,
          %{},
          voice_live_meta(%{max_duration_ms: 1_000}),
          %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
        )

      {agg, []} = Aggregation.sweep(agg, 500_000)

      {_agg, closed} = Aggregation.sweep(agg, 61_000_001)
      assert [%{trace: trace}] = closed
      assert trace.name == "voice_live:1"
    end

    # Without the prefix clause a call_stop that arrived after a daemon restart
    # would mint a root `infer_kind/1` reads as `:subagent` — the phantom-root
    # shape the computer-history clause exists to prevent.
    test "a call_stop with no opener still closes as a voice_live root" do
      {_state, closed} =
        run([
          {@voice_live_stop, %{voice_seconds: 5, accounting_complete: 0},
           voice_live_meta(%{reason: "provider_disconnected"})}
        ])

      assert [%{trace: trace}] = closed
      assert trace.tags == ["voice_live"]
      assert trace.name == "voice_live:1"
    end
  end

  @cu_start [:fermix, :computer_use, :session_start]
  @cu_complete [:fermix, :computer_use, :session_complete]
  @cu_error [:fermix, :computer_use, :session_error]
  @cu_pause [:fermix, :computer_use, :session_pause]
  @cu_resume [:fermix, :computer_use, :session_resume]
  @cu_session "cua_ab12"
  @cu_turn "main-9"

  # The emitter's own metadata shape (FermixCore.ComputerUse.Telemetry), mirrored
  # by hand like `voice_live_meta/1` above — `fermix_opik` declares no dependency
  # on `fermix_core`.
  defp computer_use_meta(extra) do
    Map.merge(
      %{
        agent: "main",
        session_id: @cu_session,
        parent_session: @cu_turn,
        mode: :host,
        origin: :interactive
      },
      extra
    )
  end

  describe "computer-use sessions" do
    test "the reporter subscribes to every computer_use event" do
      for event <- [@cu_start, @cu_complete, @cu_error, @cu_pause, @cu_resume] do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so the run is invisible to Opik"
      end
    end

    # The session is keyed by conversation and reused across turns, so it opens
    # its own root: `parent_session` rides as correlation metadata only. The tool
    # exec that drove it stays under the TURN, joined by `cu_session` — that is
    # the whole correlation, and both halves are asserted here together.
    test "a session is its own root, its tool exec stays under the turn, and the two join by cu_session" do
      {state, closed} =
        run([
          {@cu_start, %{}, computer_use_meta(%{})},
          {[:fermix, :tool, :exec], %{duration_ms: 120},
           %{
             tool: "computer_use",
             agent: "main",
             success: true,
             session_id: @cu_turn,
             action: "click",
             cu_session: @cu_session,
             outcome: "performed"
           }},
          {@cu_pause, %{}, computer_use_meta(%{})},
          {@cu_resume, %{}, computer_use_meta(%{})},
          {@cu_complete, %{actions: 3, duration_ms: 4_200}, computer_use_meta(%{})},
          {[:fermix, :agent, :message], %{iterations: 2, total_tokens: 90},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: @cu_turn, agent: "main"}}
        ])

      assert state.traces == %{}
      assert [%{trace: cu_trace, spans: cu_spans}, %{trace: turn, spans: turn_spans}] = closed

      assert cu_trace.name == "computer_use:#{@cu_session}"
      assert cu_trace.tags == ["computer_use"]
      assert cu_trace.metadata.mode == "host"
      assert cu_trace.metadata.origin == "interactive"
      assert cu_trace.metadata.parent_session == @cu_turn
      assert cu_trace.metadata.actions == 3
      assert cu_trace.metadata.duration_ms == 4_200

      # A root even though it names a parent: the session outlives the turn.
      root = span_named(cu_spans, "computer_use:#{@cu_session}")
      refute Map.has_key?(root, :parent_span_id)

      paused = span_named(cu_spans, "computer_use:session_pause")
      assert paused.parent_span_id == root.id
      assert paused.metadata.mode == "host"
      assert span_named(cu_spans, "computer_use:session_resume").parent_span_id == root.id

      # The action is the TURN's tool call, where every trace reader looks for it.
      assert spans_of_type(cu_spans, "tool") == []
      assert turn.name == "agent:main"
      [tool] = spans_of_type(turn_spans, "tool")
      assert tool.name == "computer_use"
      assert tool.metadata.cu_session == @cu_session
      assert tool.metadata.outcome == "performed"
    end

    # The error fires mid-turn (a sidecar exit, a poison reset). Closing the
    # turn's trace here would ship it early and tombstone the rest of the turn.
    test "a session_error closes only the computer-use root, leaving the turn open" do
      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 10},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: @cu_turn}},
          {@cu_start, %{}, computer_use_meta(%{})},
          {@cu_error, %{}, computer_use_meta(%{reason: "{:sidecar_exited, 1}"})},
          {[:fermix, :provider, :call], %{duration_ms: 12},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: @cu_turn}},
          {[:fermix, :agent, :message], %{iterations: 2, total_tokens: 20},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: @cu_turn, agent: "main"}}
        ])

      assert state.traces == %{}
      assert state.dropped_after_close == 0

      assert [%{trace: cu_trace}, %{trace: turn, spans: turn_spans}] = closed
      assert cu_trace.name == "computer_use:#{@cu_session}"
      assert cu_trace.metadata.status == "error"
      assert cu_trace.output == %{text: "{:sidecar_exited, 1}"}
      assert cu_trace.error_info.exception_type == "ComputerUseError"

      # The turn kept both of its model calls, including the one after the error.
      assert turn.name == "agent:main"
      assert length(spans_of_type(turn_spans, "llm")) == 2
    end

    # The marker clause is the one door into this family that does not force the
    # parent away, so it is the one that can still nest the run under the turn —
    # the exact shape the opener forbids. Reached when the run's root was swept
    # and its tombstone has since expired while the opening turn is still open:
    # `/pause` would create the run inside the turn's trace, and the following
    # bookend would then ship that turn early.
    test "a pause with no open run never attaches to the turn that opened the session" do
      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 10},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: @cu_turn}},
          {@cu_pause, %{}, computer_use_meta(%{})},
          {@cu_complete, %{actions: 2, duration_ms: 900}, computer_use_meta(%{})}
        ])

      # The bookend closed the computer-use run and nothing else.
      assert [%{trace: cu_trace, spans: cu_spans}] = closed
      assert cu_trace.name == "computer_use:#{@cu_session}"
      assert cu_trace.metadata.actions == 2
      assert span_named(cu_spans, "computer_use:session_pause")

      # The turn is untouched: still open, still holding its own model call.
      assert map_size(state.traces) == 1
      [turn_acc] = Map.values(state.traces)
      assert turn_acc.root_session == @cu_turn
      assert turn_acc.open?
    end

    # The NORMAL case, not an edge. Between its opener and its bookend the root
    # receives nothing (the actions ride the turn) and a session outlives the turn
    # by design, so the idle TTL ships the root first and the bookend opens a
    # CONTINUATION root under the same id, carrying the counts. Pinned here so the
    # documented behaviour cannot drift silently.
    test "an idle session ships its root, and its bookend opens a continuation root" do
      agg = Aggregation.new(project: "fermix", ttl_ms: 1)

      at = fn seconds ->
        %{
          at: DateTime.add(~U[2026-09-19 12:00:00.000Z], seconds, :second),
          mono: seconds * 1_000_000
        }
      end

      {agg, []} = Aggregation.apply_event(agg, @cu_start, %{}, computer_use_meta(%{}), at.(0))

      {agg, [%{trace: first}]} = Aggregation.sweep(agg, 2_000_000)
      assert first.name == "computer_use:#{@cu_session}"
      assert first.metadata.mode == "host"
      refute Map.has_key?(first.metadata, :actions)

      # While the tombstone stands a marker is dropped from Opik; the JSONL
      # stream still carries it.
      {agg, []} = Aggregation.apply_event(agg, @cu_pause, %{}, computer_use_meta(%{}), at.(3))
      assert agg.dropped_after_close == 1

      {_agg, [%{trace: second}]} =
        Aggregation.apply_event(
          agg,
          @cu_complete,
          %{actions: 5, duration_ms: 90_000},
          computer_use_meta(%{}),
          at.(4)
        )

      # A second root under the same id: this is where the run's counts live.
      assert second.name == "computer_use:#{@cu_session}"
      assert second.id != first.id
      assert second.metadata.actions == 5
      assert second.metadata.duration_ms == 90_000
    end

    # Without the prefix clause a completion arriving after a daemon restart would
    # mint a root `infer_kind/1` reads as `:subagent` — a stray computer-use run
    # rendered as a sub-agent of nothing.
    test "a session_complete with no opener still closes as a computer_use root" do
      {_state, closed} =
        run([
          {@cu_complete, %{actions: 1, duration_ms: 500}, computer_use_meta(%{})}
        ])

      assert [%{trace: trace}] = closed
      assert trace.tags == ["computer_use"]
      assert trace.name == "computer_use:#{@cu_session}"
    end
  end
end
