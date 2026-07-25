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

  test "draft-stream phases nest as child spans under the turn trace, never as roots" do
    {_state, closed} =
      run([
        {[:fermix, :channel, :stream], %{ttfd_ms: 850},
         %{channel: "telegram", session_id: "main-1", phase: :open, status: :ok}},
        {[:fermix, :channel, :stream], %{duration_us: 90_000, edit_index: 1},
         %{channel: "telegram", session_id: "main-1", phase: :edit, status: :ok}},
        {[:fermix, :channel, :stream], %{duration_us: 50_000, block_index: 2},
         %{channel: "telegram", session_id: "main-1", phase: :block, status: :ok}},
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
end
