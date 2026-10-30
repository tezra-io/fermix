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

  # The daemon runs a confirmed access-sensitive command when the owner taps,
  # usually after the turn that parked it has shipped. It carries that turn's
  # session_id (so it pairs with the held call by `access_intent`) and must still
  # ship rather than be dropped at the closed-session tombstone.
  describe "a confirmed access-sensitive run" do
    @held %{
      tool: "tesla_unlock_doors",
      success: false,
      session_id: "main-1",
      access_gate: "held_this_chat",
      access_intent: "intent-1"
    }

    @confirmed %{
      tool: "tesla_unlock_doors",
      success: true,
      session_id: "main-1",
      access_gate: "confirmed",
      access_intent: "intent-1"
    }

    @turn_close {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
                 %{
                   channel: :telegram,
                   chat_id: "c1",
                   sender: "u1",
                   session_id: "main-1",
                   agent: "main"
                 }}

    test "after its turn shipped, it ships as its own trace carrying the tool span" do
      {state, closed} =
        run([
          {[:fermix, :tool, :exec], %{duration_ms: 0}, @held},
          @turn_close,
          {[:fermix, :tool, :exec], %{duration_ms: 900}, @confirmed}
        ])

      assert [%{trace: turn}, %{trace: late, spans: [span]}] = closed
      assert turn.name == "agent:main"
      assert late.name == "access_gate:confirmed"
      assert late.metadata.session_id == "main-1"
      assert late.metadata.access_intent == "intent-1"
      assert span.trace_id == late.id
      assert span.name == "tesla_unlock_doors"
      assert span.metadata.access_gate == "confirmed"
      assert span.metadata.access_intent == "intent-1"
      assert state.dropped_after_close == 0
      assert state.traces == %{}
    end

    test "while its turn is still open, it nests under that turn like any tool span" do
      {_state, closed} =
        run([
          {[:fermix, :tool, :exec], %{duration_ms: 0}, @held},
          {[:fermix, :tool, :exec], %{duration_ms: 900}, @confirmed},
          @turn_close
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "agent:main"
      assert length(spans_of_type(spans, "tool")) == 2
    end

    test "any other late tool span is still dropped at the tombstone" do
      {state, closed} =
        run([@turn_close, {[:fermix, :tool, :exec], %{duration_ms: 1}, @held}])

      assert length(closed) == 1
      assert state.dropped_after_close == 1
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

  @attachment_save_event [:fermix, :attachment, :save]

  describe "inbound attachment saves (M67 D1)" do
    test "the reporter subscribes to the save event" do
      assert @attachment_save_event in FermixOpik.Reporter.events()
    end

    test "a turn's workspace save nests as a point span under the turn" do
      {_state, closed} =
        run([
          {@attachment_save_event,
           %{
             duration_us: 2_000,
             saved: 1,
             failed: 0,
             files: 1,
             bytes: 9,
             pruned_files: 0,
             pruned_bytes: 0
           }, %{channel: "telegram", session_id: "main-1", outcome: :saved, detail: nil}},
          {[:fermix, :provider, :call], %{duration_ms: 1_000},
           %{provider: :openai, model: "gpt-5.5", status: :ok, session_id: "main-1"}},
          {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 10},
           %{channel: :telegram, chat_id: "c1", sender: "u1", session_id: "main-1", agent: "main"}}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "agent:main"
      wrapper = span_named(spans, "agent:main")
      save = span_named(spans, "attachment_save")

      assert save.parent_span_id == wrapper.id
      assert save.trace_id == trace.id
      assert save.metadata.saved == 1
      assert save.metadata.outcome == "saved"
    end
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

  # M56 §4.4: a chat turn during a voice call may end with no reply; the turn's
  # root says so, so a turn that answered nothing reads as chosen, not lost.
  test "a turn that ended with no reply says so on its root" do
    {_state, closed} =
      run([
        {[:fermix, :agent, :message], %{iterations: 1, total_tokens: 9},
         %{
           channel: :companion,
           chat_id: "main",
           sender: "Companion owner",
           session_id: "main-56",
           agent: "main",
           silent: true
         }}
      ])

    assert [%{trace: trace}] = closed
    assert trace.metadata.silent == true
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

  test "a cue run's trace carries its trigger, watcher and delivery" do
    {_state, closed} =
      run([
        {[:fermix, :job, :run_start], %{},
         %{
           agent: "scheduled:job-8",
           job_id: "job-8",
           run_id: "run-2",
           name: "release watch",
           session_id: "cron_job-8_20261017_120000_a1b2c3",
           schedule_kind: "cue",
           trigger: "cue",
           watcher_id: "cwt_1",
           delivery_id: 17
         }},
        {[:fermix, :job, :run_complete], %{duration_ms: 900, iterations: 1, total_tokens: 10},
         %{
           agent: "scheduled:job-8",
           job_id: "job-8",
           run_id: "run-2",
           status: "ok",
           session_id: "cron_job-8_20261017_120000_a1b2c3",
           trigger: "cue",
           watcher_id: "cwt_1",
           delivery_id: 17
         }}
      ])

    assert [%{trace: trace}] = closed
    assert "scheduled" in trace.tags
    assert trace.metadata.trigger == "cue"
    assert trace.metadata.watcher_id == "cwt_1"
    assert trace.metadata.delivery_id == 17
    refute Map.has_key?(trace.metadata, :cue_count)
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
    :scheduler_error
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

    # The reminder rail runs no model, so the lifecycle is its only event: no
    # run kind trails a delivered reminder.
    test "the lifecycle is the reminder family's only subscribed event" do
      reminder_events = Enum.filter(FermixOpik.Reporter.events(), &match?([_, :reminder, _], &1))

      assert reminder_events == [@reminder_event]
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

  # Open-loop check-ins ([:fermix, :open_loop, :checkin, :start | :complete |
  # :error], M78 §09). A check-in drives the loop in its own context, so it owns
  # a session, opens a ROOT trace, and its provider/tool spans nest under it
  # through the shared session_id. `skipped` and `settled` have no run behind
  # them and render as self-closing traces, the reminder-lifecycle shape.
  @open_loop_start [:fermix, :open_loop, :checkin, :start]
  @open_loop_complete [:fermix, :open_loop, :checkin, :complete]
  @open_loop_error [:fermix, :open_loop, :checkin, :error]
  @open_loop_skipped [:fermix, :open_loop, :skipped]
  @open_loop_settled [:fermix, :open_loop, :settled]
  @open_loop_fault [:fermix, :open_loop, :fault]
  @open_loop_reaction [:fermix, :open_loop, :reaction]
  @open_loop_events [
    @open_loop_start,
    @open_loop_complete,
    @open_loop_error,
    @open_loop_skipped,
    @open_loop_settled,
    @open_loop_fault,
    @open_loop_reaction
  ]
  @open_loop_id "loop_Vq3kT9wZrHc"
  @open_loop_agent "open_loop:loop_Vq3kT9wZrHc"
  @open_loop_session "open_loop_loop_Vq3kT9wZrHc_2"

  # Mirrors the closed set in FermixCore.OpenLoops.Telemetry by hand:
  # `fermix_opik` declares no dependency on `fermix_core`, exactly as
  # `@reminder_phases` mirrors the reminder emitter.
  @open_loop_skip_reasons [
    "disabled",
    "budget",
    "active_hours",
    "no_target",
    "max_children",
    "closed_meanwhile"
  ]
  @open_loop_fault_stages ["scan", "claim", "release", "timer", "start_checkin", "sweep"]

  # The emitter's own bookend metadata shape (FermixCore.OpenLoops.Telemetry),
  # mirrored by hand like `reminder_meta/2` above.
  defp open_loop_meta(extra) do
    Map.merge(
      %{
        component: "open_loop_checkin",
        agent: @open_loop_agent,
        session_id: @open_loop_session,
        open_loop_id: @open_loop_id,
        touch: 2
      },
      extra
    )
  end

  defp open_loop_start_meta(extra \\ %{}) do
    open_loop_meta(
      Map.merge(
        %{
          rung: 2,
          horizon_class: "medium",
          active_hours: "08:30-22:00",
          max_duration_ms: 120_000
        },
        extra
      )
    )
  end

  defp open_loop_provider_call(extra \\ %{}) do
    {[:fermix, :provider, :call], %{duration_ms: 600},
     Map.merge(
       %{
         provider: :anthropic,
         model: "claude-opus-4-8",
         status: :ok,
         session_id: @open_loop_session,
         tokens: %{prompt: 120, completion: 30}
       },
       extra
     )}
  end

  describe "open-loop check-in runs" do
    test "the reporter subscribes to all seven events" do
      for event <- @open_loop_events do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so it is invisible to Opik"
      end
    end

    test "a check-in is its own root trace nesting its provider and tool spans" do
      {state, closed} =
        run([
          {@open_loop_start, %{count: 1}, open_loop_start_meta()},
          open_loop_provider_call(),
          {[:fermix, :tool, :exec], %{duration_ms: 9},
           %{tool: "open_loop_respond", success: true, session_id: @open_loop_session}},
          {@open_loop_complete, %{duration_ms: 3_900},
           open_loop_meta(%{outcome: "spoke", output: "How did the kiln booking go?"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == @open_loop_agent
      assert trace.tags == ["open_loop_checkin"]
      assert trace.output == %{text: "How did the kiln booking go?"}

      # The metadata is the allowlist and nothing else: the opener's snapshot
      # survives the closer, and no session id, agent or ceiling leaks in.
      assert trace.metadata == %{
               component: "open_loop_checkin",
               open_loop_id: @open_loop_id,
               touch: 2,
               rung: 2,
               horizon_class: "medium",
               active_hours: "08:30-22:00",
               outcome: "spoke"
             }

      # Unthreaded: the family never carries the delivery destination.
      refute Map.has_key?(trace, :thread_id)

      wrapper = span_named(spans, @open_loop_agent)
      refute Map.has_key?(wrapper, :parent_span_id)

      assert [llm] = spans_of_type(spans, "llm")
      assert [tool] = spans_of_type(spans, "tool")
      assert llm.parent_span_id == wrapper.id
      assert tool.parent_span_id == wrapper.id
      assert llm.trace_id == trace.id
      assert tool.trace_id == trace.id
      assert state.traces == %{}
    end

    # The scheduler spawned the run, not another run: the opener hard-codes nil,
    # which this pins by naming a live parent and proving it is ignored.
    test "the run stays a root even when a live parent session is named" do
      {_state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 100},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@open_loop_start, %{count: 1}, open_loop_start_meta(%{parent_session: "main-1"})},
          {@open_loop_complete, %{duration_ms: 900}, open_loop_meta(%{outcome: "silent"})},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      names = closed |> Enum.map(& &1.trace.name) |> Enum.sort()
      assert names == ["agent:main", @open_loop_agent]

      check_in = Enum.find(closed, &(&1.trace.name == @open_loop_agent))
      assert check_in.trace.metadata.outcome == "silent"
      refute Map.has_key?(check_in.trace, :output)
      refute Map.has_key?(check_in.trace.metadata, :status)
      refute Map.has_key?(span_named(check_in.spans, @open_loop_agent), :parent_span_id)

      turn = Enum.find(closed, &(&1.trace.name == "agent:main"))
      refute span_named(turn.spans, @open_loop_agent)
    end

    test "a run that never reached a decision closes with its own status word" do
      for status <- ["timeout", "error"] do
        {_state, closed} =
          run([
            {@open_loop_start, %{count: 1}, open_loop_start_meta()},
            {@open_loop_error, %{duration_ms: 120_000},
             open_loop_meta(%{status: status, error: "watchdog fired at 120000ms"})}
          ])

        assert [%{trace: trace}] = closed
        assert trace.metadata.status == status, "the #{status} status never reached the trace"
        assert trace.output == %{text: "watchdog fired at 120000ms"}
        assert trace.metadata.open_loop_id == @open_loop_id
        assert trace.metadata.horizon_class == "medium"
      end
    end

    test "a check-in is swept by its max duration, not the idle TTL" do
      agg = Aggregation.new(project: "fermix", ttl_ms: 1)

      {agg, []} =
        Aggregation.apply_event(
          agg,
          @open_loop_start,
          %{count: 1},
          open_loop_start_meta(%{max_duration_ms: 1_000}),
          %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
        )

      # mono is microseconds; floor = (1_000 + 60_000) * 1_000 = 61_000_000us.
      {agg, []} = Aggregation.sweep(agg, 500_000)

      {_agg, closed} = Aggregation.sweep(agg, 61_000_001)
      assert [%{trace: trace}] = closed
      assert trace.name == @open_loop_agent
      assert trace.tags == ["open_loop_checkin"]
      refute Map.has_key?(trace, :thread_id)
    end

    # A run whose first exported event is a provider call (the opener lost the
    # race, or was never delivered) classifies from its session prefix alone, and
    # with no agent name to go by it is named by that session id.
    test "a span arriving with no opener classifies the run by its session prefix" do
      agg = Aggregation.new(project: "fermix", ttl_ms: 1)

      {agg, []} =
        Aggregation.apply_event(
          agg,
          [:fermix, :provider, :call],
          %{duration_ms: 600},
          %{provider: :openai, model: "gpt-5", status: :ok, session_id: @open_loop_session},
          %{at: ~U[2026-06-02 12:00:00.000Z], mono: 0}
        )

      {_agg, closed} = Aggregation.sweep(agg, 10_000)
      assert [%{trace: trace, spans: spans}] = closed
      assert trace.tags == ["open_loop_checkin"]
      assert trace.name == @open_loop_session
      assert [_llm] = spans_of_type(spans, "llm")
    end

    test "a closer arriving without its opener still carries the run's ids" do
      {_state, closed} =
        run([
          open_loop_provider_call(%{agent: @open_loop_agent}),
          {@open_loop_complete, %{duration_ms: 800}, open_loop_meta(%{outcome: "empty"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.tags == ["open_loop_checkin"]
      assert trace.name == @open_loop_agent
      assert trace.metadata.outcome == "empty"
      assert trace.metadata.open_loop_id == @open_loop_id
      assert [llm] = spans_of_type(spans, "llm")
      assert llm.parent_span_id == span_named(spans, @open_loop_agent).id
    end

    # A run that timed out is retried under the same touch, so the same session
    # id, seconds later: inside the closed-session tombstone window. The retry's
    # opener begins a new run, so its spans nest in its own trace instead of
    # being dropped as late spans of the run that already shipped.
    test "a retried check-in under the same touch keeps its spans" do
      {state, closed} =
        run([
          {@open_loop_start, %{count: 1}, open_loop_start_meta()},
          {@open_loop_error, %{duration_ms: 120_000},
           open_loop_meta(%{status: "timeout", error: "watchdog fired"})},
          {@open_loop_start, %{count: 1}, open_loop_start_meta()},
          open_loop_provider_call(),
          {@open_loop_complete, %{duration_ms: 2_000}, open_loop_meta(%{outcome: "silent"})}
        ])

      assert [%{trace: first}, %{trace: retry, spans: spans}] = closed
      assert first.metadata.status == "timeout"
      assert retry.metadata.outcome == "silent"
      assert retry.id != first.id
      assert [llm] = spans_of_type(spans, "llm")
      assert llm.parent_span_id == span_named(spans, @open_loop_agent).id
      assert state.dropped_after_close == 0
    end

    # Registry completeness: every skip reason hits a real clause, never the
    # catch-all (which returns `{state, []}` and leaves nothing behind).
    test "every skip is its own self-closing trace and opens no session" do
      for reason <- @open_loop_skip_reasons do
        {state, closed} =
          run([
            {@open_loop_skipped, %{count: 1},
             %{open_loop_id: @open_loop_id, reason: reason, component: "open_loop_scheduler"}}
          ])

        assert [%{trace: trace, spans: []}] = closed,
               "reason #{inspect(reason)} produced no trace — it fell to the catch-all"

        assert trace.name == "open_loop:#{reason}"
        assert trace.tags == ["open_loop"]

        assert trace.metadata == %{
                 component: "open_loop_scheduler",
                 open_loop_id: @open_loop_id,
                 reason: reason
               }

        assert state.traces == %{}
        assert state.sessions == %{}
      end
    end

    # A settlement names the settling turn's session as correlation, but it is
    # a point event of its own: it never nests under that turn or opens one.
    test "a settlement is its own self-closing trace, even beside a live turn" do
      settled_meta = %{
        open_loop_id: @open_loop_id,
        from: "asked",
        to: "closed",
        answer: "done",
        by: "main_agent",
        component: "open_loops",
        session_id: "main-1"
      }

      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 100},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@open_loop_settled, %{count: 1}, settled_meta},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      assert [%{trace: settled, spans: []}, %{trace: turn, spans: turn_spans}] = closed
      assert settled.name == "open_loop:settled"
      assert settled.tags == ["open_loop"]
      assert settled.metadata == settled_meta
      assert turn.name == "agent:main"
      refute span_named(turn_spans, "open_loop:settled")
      assert state.traces == %{}
    end

    test "a scheduler expiry with no answer and no session carries neither" do
      {state, closed} =
        run([
          {@open_loop_settled, %{count: 1},
           %{
             open_loop_id: @open_loop_id,
             from: "asked",
             to: "expired",
             by: "scheduler",
             component: "open_loops"
           }}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "open_loop:settled"
      refute Map.has_key?(trace.metadata, :answer)
      refute Map.has_key?(trace.metadata, :session_id)
      assert trace.metadata.to == "expired"
      assert state.sessions == %{}
    end

    # Registry completeness again: every scheduler fault stage hits a real
    # clause, never the catch-all, and the trace carries the derived class only.
    test "every scheduler fault is its own self-closing trace and opens no session" do
      for stage <- @open_loop_fault_stages do
        fault_meta = %{
          stage: stage,
          open_loop_id: @open_loop_id,
          component: "open_loop_scheduler",
          error_class: "repo_timeout"
        }

        {state, closed} = run([{@open_loop_fault, %{count: 1}, fault_meta}])

        assert [%{trace: trace, spans: []}] = closed,
               "stage #{inspect(stage)} produced no trace — it fell to the catch-all"

        assert trace.name == "open_loop:fault"
        assert trace.tags == ["open_loop"]
        assert trace.metadata == fault_meta
        assert trace.start_time == trace.end_time
        assert state.traces == %{}
        assert state.sessions == %{}
      end
    end

    # M83 §07: a follow-up's outcome is a point event of its own. The delay rides
    # the measurements and lands in the trace's metadata; no text ever does, and
    # the observing turn's session is correlation, never a parent.
    test "a reply to a follow-up is its own self-closing trace with its delay" do
      reaction_meta = %{
        open_loop_id: @open_loop_id,
        rung: 1,
        outcome: "replied",
        component: "open_loops",
        session_id: "main-1"
      }

      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 100},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@open_loop_reaction, %{count: 1, reply_after_ms: 5_400_000}, reaction_meta},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :telegram, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      assert [%{trace: reaction, spans: []}, %{trace: turn, spans: turn_spans}] = closed
      assert reaction.name == "open_loop:reaction"
      assert reaction.tags == ["open_loop"]
      assert reaction.metadata == Map.put(reaction_meta, :reply_after_ms, 5_400_000)
      assert reaction.start_time == reaction.end_time
      refute span_named(turn_spans, "open_loop:reaction")
      assert turn.name == "agent:main"
      assert state.traces == %{}
    end

    test "silence a day on carries no delay and, without a caller session, no session" do
      {state, closed} =
        run([
          {@open_loop_reaction, %{count: 1},
           %{open_loop_id: @open_loop_id, rung: 2, outcome: "no_reply", component: "open_loops"}}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "open_loop:reaction"

      assert trace.metadata == %{
               open_loop_id: @open_loop_id,
               rung: 2,
               outcome: "no_reply",
               component: "open_loops"
             }

      assert state.sessions == %{}
    end

    test "a fault that concerns no single loop carries no loop id" do
      {_state, closed} =
        run([
          {@open_loop_fault, %{count: 1},
           %{stage: "scan", component: "open_loop_scheduler", error_class: "unclassified"}}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "open_loop:fault"

      assert trace.metadata == %{
               stage: "scan",
               component: "open_loop_scheduler",
               error_class: "unclassified"
             }
    end
  end

  # Meeting runs ([:fermix, :meeting, :run_start | :run_complete | :run_error |
  # :phase], M21 §11.1). A meeting outlives the turn that asked for it by an
  # hour, so it is a root run of its own — the harness shape — with the
  # phase transitions as point spans inside it.
  @meeting_start [:fermix, :meeting, :run_start]
  @meeting_complete [:fermix, :meeting, :run_complete]
  @meeting_error [:fermix, :meeting, :run_error]
  @meeting_phase [:fermix, :meeting, :phase]
  @meeting_session "meeting_mtg_ab12cd_20260602_120000"

  # The emitter's own metadata shape (FermixCore.Meetings.Telemetry). `fermix_opik`
  # declares no dependency on `fermix_core`, so this mirrors it by hand, exactly
  # like `reminder_meta/2` above.
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
    # closer finally arrives.
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
  # hand, exactly like `meeting_meta/1` above.
  defp voice_live_meta(extra) do
    Map.merge(
      %{
        agent: "voice_live",
        session_id: @voice_live_call,
        device_id: "dev-1",
        model: "gpt-live-1",
        voice: "marin",
        engine: "openai_live",
        provider: "openai"
      },
      extra
    )
  end

  # The same emitter on the other task engine (M70 §09): one run kind and one
  # event family, told apart by the engine, provider and pinned model it names.
  defp grok_meta(extra) do
    voice_live_meta(
      Map.merge(
        %{engine: "xai_realtime", provider: "xai", model: "grok-voice-3.0", voice: "eve"},
        extra
      )
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
      assert trace.metadata.provider == "openai"
      assert trace.metadata.model == "gpt-live-1"
      assert started.metadata.engine == "openai_live"
      assert started.metadata.provider == "openai"
    end

    # M70 §09: a Grok call reuses the run kind and every event, so the engine,
    # provider and model are all that tell it from a GPT Live call, on the root
    # and on each phase span. Its own work rides the shared emitters on the
    # call's session: one `fermix_task` tool span per function call the model
    # made, and one llm span per Grok response carrying the vendor's token
    # counts. The backend task is a turn of its own under the call.
    test "a Grok call is one root that names its engine and nests its task, tool and model spans" do
      {_state, closed} =
        run([
          {@voice_live_start, %{}, grok_meta(%{max_duration_ms: 900_000})},
          {@voice_live_session_started, %{}, grok_meta(%{provider_session_id: "sess_grok_1"})},
          {@voice_live_delegation_start, %{},
           grok_meta(%{
             delegation_id: "task_1",
             revision: 1,
             turn_session_id: @voice_delegation_session
           })},
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
          {@voice_live_delegation_stop, %{duration_ms: 1_200},
           grok_meta(%{
             delegation_id: "task_1",
             revision: 1,
             turn_session_id: @voice_delegation_session,
             status: "completed"
           })},
          {[:fermix, :tool, :exec], %{duration_ms: 1_400},
           %{
             tool: "fermix_task",
             agent: "voice_live",
             success: true,
             session_id: @voice_live_call,
             status: "completed",
             task_id: "task_1",
             action: "submit"
           }},
          # A refused call is still one tool span: its status is the record.
          {[:fermix, :tool, :exec], %{duration_ms: 0},
           %{
             tool: "fermix_task",
             agent: "voice_live",
             success: false,
             session_id: @voice_live_call,
             status: "rejected",
             action: "invalid"
           }},
          {[:fermix, :provider, :call], %{duration_ms: 700},
           %{
             provider: :xai,
             model: "grok-voice-3.0",
             status: :ok,
             agent: "voice_live",
             session_id: @voice_live_call,
             tokens: %{prompt: 310, completion: 52, total: 362}
           }},
          {@voice_live_stop,
           %{
             voice_seconds: 95.5,
             voice_cost_millicents: 13_533,
             voice_text_items: 3,
             backend_turns: 1,
             accounting_complete: 0,
             user_turns: 4,
             generation_latency_ms_median: 640,
             generation_latency_ms_max: 1_310,
             audible_latency_ms_median: 820,
             audible_latency_ms_max: 1_650
           }, grok_meta(%{reason: "call_stop", provider_session_id: "sess_grok_1"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == @voice_live_call
      assert trace.tags == ["voice_live"]

      assert trace.metadata.engine == "xai_realtime"
      assert trace.metadata.provider == "xai"
      assert trace.metadata.model == "grok-voice-3.0"
      assert trace.metadata.voice == "eve"
      assert trace.metadata.provider_session_id == "sess_grok_1"

      # The ledger: duration plus billable text items, and no vendor terminal
      # usage to settle against, so the accounting stays visibly incomplete.
      assert trace.metadata.voice_seconds == 95.5
      assert trace.metadata.voice_cost_millicents == 13_533
      assert trace.metadata.voice_text_items == 3
      assert trace.metadata.backend_turns == 1
      assert trace.metadata.accounting_complete == 0

      # How long the owner waited, kept apart from the backend task's time:
      # the provider's generation and the audible end-to-end latency.
      assert trace.metadata.user_turns == 4
      assert trace.metadata.generation_latency_ms_median == 640
      assert trace.metadata.generation_latency_ms_max == 1_310
      assert trace.metadata.audible_latency_ms_median == 820
      assert trace.metadata.audible_latency_ms_max == 1_650

      root = span_named(spans, @voice_live_call)
      refute Map.has_key?(root, :parent_span_id)

      for phase <- ~w(session_started delegation_start delegation_stop) do
        span = span_named(spans, "voice_live:#{phase}")
        assert span.parent_span_id == root.id
        assert span.metadata.engine == "xai_realtime"
        assert span.metadata.provider == "xai"
        assert span.metadata.model == "grok-voice-3.0"
      end

      delegation = span_named(spans, @voice_delegation_session)
      assert delegation.parent_span_id == root.id

      [backend, grok] = spans_of_type(spans, "llm")
      assert backend.parent_span_id == delegation.id
      assert grok.parent_span_id == root.id
      assert grok.name == "llm:grok-voice-3.0"
      assert grok.provider == "xai"
      assert grok.usage == %{prompt_tokens: 310, completion_tokens: 52, total_tokens: 362}
      refute Map.has_key?(grok, :input)
      refute Map.has_key?(grok, :output)

      [submitted, rejected] = spans_of_type(spans, "tool")
      assert Enum.all?([submitted, rejected], &(&1.name == "fermix_task"))
      assert Enum.all?([submitted, rejected], &(&1.parent_span_id == root.id))
      assert submitted.metadata == %{status: "completed", task_id: "task_1", action: "submit"}
      assert rejected.metadata == %{status: "rejected", action: "invalid"}
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
    # finally arrived (the meeting precedent).
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

    # M56 §4.6: a task that outlived its call stops after the call's root
    # shipped at call_stop, emitted by its new owner. Attached while the call's
    # run is open, it never opens a run of its own: on a closed or forgotten
    # call it would be an empty phantom root.
    test "a detached delegation's stop never mints a root of its own" do
      detached_stop =
        {@voice_live_delegation_stop, %{duration_ms: 1_800_000},
         voice_live_meta(%{
           delegation_id: "dlg_9",
           revision: 1,
           turn_session_id: @voice_delegation_session,
           status: "timed_out",
           detached: true
         })}

      {state, closed} =
        run([
          {@voice_live_start, %{}, voice_live_meta(%{max_duration_ms: 900_000})},
          {@voice_live_stop, %{voice_seconds: 62, accounting_complete: 1},
           voice_live_meta(%{reason: "call_stop"})},
          detached_stop
        ])

      assert [%{trace: %{name: "voice_live:1"}}] = closed
      assert state.traces == %{}

      {forgotten, none} = run([detached_stop])
      assert none == []
      assert forgotten.traces == %{}
      refute Map.has_key?(forgotten.sessions, @voice_live_call)

      {open, []} =
        run([
          {@voice_live_start, %{}, voice_live_meta(%{max_duration_ms: 900_000})},
          detached_stop
        ])

      [%{spans: spans}] = Map.values(open.traces)
      stopped = span_named(spans, "voice_live:delegation_stop")
      assert stopped.metadata.detached == true
      assert stopped.metadata.status == "timed_out"
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

  @voice_gist_start [:fermix, :voice_gist, :run_start]
  @voice_gist_complete [:fermix, :voice_gist, :run_complete]
  @voice_gist_error [:fermix, :voice_gist, :run_error]
  @voice_gist_session "voice_gist:6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"

  # The emitter's own metadata shape (FermixCore.Realtime.GistTelemetry),
  # mirrored by hand like `voice_live_meta/1`.
  defp voice_gist_meta(extra) do
    Map.merge(
      %{
        agent: "voice_gist",
        session_id: @voice_gist_session,
        call_uuid: "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
      },
      extra
    )
  end

  # M56 §7: a call's gist is made after the call's run closed, so it is a root
  # of its own, nesting only its own provider call, never under the call.
  describe "a call's gist" do
    test "the reporter subscribes to every voice_gist event" do
      for event <- [@voice_gist_start, @voice_gist_complete, @voice_gist_error] do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so the run is invisible to Opik"
      end
    end

    test "a gist is one root trace nesting its summarising call, closed with its sizes" do
      {_state, closed} =
        run([
          {@voice_live_stop, %{voice_seconds: 62}, voice_live_meta(%{reason: "call_stop"})},
          {@voice_gist_start, %{},
           voice_gist_meta(%{tasks: 2, speech_bytes: 900, input_bytes: 1_100, tainted: false})},
          {[:fermix, :provider, :call], %{duration_ms: 1_800},
           %{
             provider: :openai,
             model: "gpt-5",
             status: :ok,
             agent: "voice_gist",
             session_id: @voice_gist_session,
             tokens: %{prompt: 300, completion: 80}
           }},
          {@voice_gist_complete, %{duration_ms: 2_000, gist_bytes: 310},
           voice_gist_meta(%{status: "written"})}
        ])

      gist = Enum.find(closed, &(&1.trace.name == @voice_gist_session))
      assert %{trace: trace, spans: spans} = gist
      assert trace.tags == ["voice_gist"]
      assert trace.metadata.call_uuid == "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
      assert trace.metadata.status == "written"
      assert trace.metadata.gist_bytes == 310
      assert trace.metadata.input_bytes == 1_100
      assert [llm] = spans_of_type(spans, "llm")
      assert llm.trace_id == trace.id

      wrapper = span_named(spans, @voice_gist_session)
      refute Map.has_key?(wrapper, :parent_span_id)
    end

    # Without the prefix clause an error arriving with no opener would mint a
    # root `infer_kind/1` reads as `:subagent`.
    test "a gist that failed with no opener still closes as a voice_gist root, failed" do
      {_state, closed} =
        run([
          {@voice_gist_error, %{count: 1, duration_ms: 60_000},
           voice_gist_meta(%{status: "failed", error: "timeout"})}
        ])

      assert [%{trace: trace}] = closed
      assert trace.tags == ["voice_gist"]
      assert trace.metadata.status == "failed"
      assert trace.error_info.message == "timeout"
    end
  end

  @cue_filter_start [:fermix, :cue_filter, :run_start]
  @cue_filter_complete [:fermix, :cue_filter, :run_complete]
  @cue_filter_error [:fermix, :cue_filter, :run_error]
  @cue_filter_session "cue_filter_cwt_9f2e_20261017_120000_a1b2c3"

  # The emitter's own metadata shape (FermixCore.Cues.Filter.Telemetry),
  # mirrored by hand like `voice_gist_meta/1`.
  defp cue_filter_meta(extra) do
    Map.merge(
      %{
        agent: "cue_filter",
        session_id: @cue_filter_session,
        filter_call_id: "cfc_1",
        watcher_id: "cwt_9f2e",
        delivery_id: 17,
        cue_id: 9,
        source_ref: "eng-feeds",
        attempt: 0
      },
      extra
    )
  end

  # M60 §14: one filter call for one cue is a run kind of its own, a root with
  # its provider call nested by the shared session id.
  describe "a cue filter call" do
    test "the reporter subscribes to every cue_filter event" do
      for event <- [@cue_filter_start, @cue_filter_complete, @cue_filter_error] do
        assert event in FermixOpik.Reporter.events(),
               "#{inspect(event)} is not subscribed, so the run is invisible to Opik"
      end
    end

    test "a filter call is one root trace nesting its model call, closed with the decision" do
      {_state, closed} =
        run([
          {@cue_filter_start, %{count: 1}, cue_filter_meta(%{})},
          {[:fermix, :provider, :call], %{duration_ms: 900},
           %{
             provider: :openai,
             model: "gpt-5.4-mini",
             status: :ok,
             agent: "cue_filter",
             session_id: @cue_filter_session,
             tokens: %{prompt: 400, completion: 20}
           }},
          {@cue_filter_complete, %{count: 1, duration_ms: 950},
           cue_filter_meta(%{status: "ok", decision: "pass"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.tags == ["cue_filter"]
      assert trace.name == @cue_filter_session
      assert trace.metadata.decision == "pass"
      assert trace.metadata.watcher_id == "cwt_9f2e"
      assert trace.metadata.delivery_id == 17
      assert [llm] = spans_of_type(spans, "llm")
      assert llm.trace_id == trace.id
      refute Map.has_key?(span_named(spans, @cue_filter_session), :parent_span_id)
    end

    # Without the prefix clause a closer arriving with no opener would mint a
    # root `infer_kind/1` reads as `:subagent`.
    test "a failed call with no opener still closes as a cue_filter root with its status" do
      {_state, closed} =
        run([
          {@cue_filter_error, %{count: 1, duration_ms: 60_000},
           cue_filter_meta(%{status: "provider_failure", error_kind: "timeout"})}
        ])

      assert [%{trace: trace}] = closed
      assert trace.tags == ["cue_filter"]
      assert trace.metadata.status == "provider_failure"
      assert trace.error_info.message == "timeout"
    end

    # `Cues.Filter.Llm` puts the call's session id in the chain's failover
    # telemetry, as the adapter's own call event carries it.
    test "a failover on the filter call's chain nests under the call's root" do
      {_state, closed} =
        run([
          {@cue_filter_start, %{count: 1}, cue_filter_meta(%{})},
          {[:fermix, :provider, :failover], %{count: 1},
           %{
             from_provider: :openai,
             from_model: "gpt-5.4-mini",
             to_provider: :openai,
             to_model: "gpt-5.4",
             reason_kind: :timeout,
             agent: "cue_filter",
             surface: :cue_filter,
             session_id: @cue_filter_session
           }},
          {@cue_filter_complete, %{count: 1, duration_ms: 950},
           cue_filter_meta(%{status: "ok", decision: "pass"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == @cue_filter_session
      root = span_named(spans, @cue_filter_session)
      failover = span_named(spans, "failover:openai->openai")
      assert failover.trace_id == trace.id
      assert failover.parent_span_id == root.id
    end
  end

  # Cue lifecycle ([:fermix, :cue, :lifecycle], M60 §14). `@cue_phases` mirrors
  # `FermixCore.Cues.Telemetry.phases/0` by hand, as `@reminder_phases` does:
  # `fermix_opik` declares no dependency on `fermix_core`, and
  # `apps/fermix_core/test/fermix_core/cues/telemetry_test.exs` pins `phases/0`
  # against the same literal list.
  @cue_event [:fermix, :cue, :lifecycle]
  @cue_phases ~w(accepted duplicate conflict stale rejected rate_limited over_budget
                 routed gap expired unmatched overflow write_failed ingest_error sweep_error
                 passed dropped filter_retry filter_held filter_failed claimed settled retry
                 exhausted proposed confirmed denied proposal_expired proposal_refused
                 follow_up_triggered follow_up_decided follow_up_expired follow_up_refused
                 follow_up_started follow_up_approval_asked follow_up_approval_decided
                 follow_up_approval_expired)a
  @cue_run_session "cron_job-8_20261017_120000_a1b2c3"

  # The emitter's own metadata shape (FermixCore.Cues.Telemetry): ids, labels
  # and counts, the phase and the component.
  defp cue_meta(phase, extra) do
    Map.merge(%{phase: phase, component: "cues", source_ref: "eng-feeds"}, extra)
  end

  defp cue_run_meta(phase, extra) do
    cue_meta(
      phase,
      Map.merge(
        %{
          session_id: @cue_run_session,
          job_id: "job-8",
          run_id: "run-2",
          delivery_id: 17,
          watcher_id: "cwt_9f2e"
        },
        extra
      )
    )
  end

  defp cue_job_meta(extra) do
    Map.merge(
      %{
        agent: "scheduled:job-8",
        job_id: "job-8",
        run_id: "run-2",
        name: "release watch",
        session_id: @cue_run_session,
        schedule_kind: "cue",
        schedule_expr: "cue",
        trigger: "cue",
        watcher_id: "cwt_9f2e",
        delivery_id: 17
      },
      extra
    )
  end

  describe "cue lifecycle" do
    test "the reporter subscribes to the event" do
      assert @cue_event in FermixOpik.Reporter.events()
    end

    # Registry completeness: with no session to nest under, every phase must
    # ship as its own trace, never fall to the catch-all.
    test "every phase without a session is its own self-closing trace" do
      for phase <- @cue_phases do
        {state, closed} = run([{@cue_event, %{count: 1}, cue_meta(phase, %{cue_id: 9})}])

        assert [%{trace: trace, spans: []}] = closed,
               "phase #{inspect(phase)} produced no trace — it fell to the catch-all"

        assert trace.name == "cue:#{phase}"
        assert trace.tags == ["cue"]
        assert state.traces == %{}
      end
    end

    test "a sessionless trace carries the emitter's ids, labels and measurements only" do
      {_state, closed} =
        run([
          {@cue_event, %{count: 1, accept_ms: 14},
           cue_meta(:accepted, %{cue_id: 9, result: :ok, unknown_key: "dropped"})}
        ])

      assert [%{trace: trace}] = closed
      assert trace.metadata.phase == "accepted"
      assert trace.metadata.component == "cues"
      assert trace.metadata.source_ref == "eng-feeds"
      assert trace.metadata.cue_id == 9
      assert trace.metadata.result == "ok"
      assert trace.metadata.accept_ms == 14
      refute Map.has_key?(trace.metadata, :unknown_key)
    end

    test "a sessionless phase never nests under a run that is open" do
      {state, closed} =
        run([
          {[:fermix, :provider, :call], %{duration_ms: 10},
           %{provider: :openai, model: "gpt-5", status: :ok, session_id: "main-1"}},
          {@cue_event, %{count: 1}, cue_meta(:routed, %{cue_id: 9, delivery_id: 17})},
          {[:fermix, :agent, :message], %{iterations: 1},
           %{channel: :cli, chat_id: "c1", session_id: "main-1", agent: "main"}}
        ])

      turn = Enum.find(closed, &(&1.trace.name == "agent:main"))
      refute span_named(turn.spans, "cue:routed")
      assert Enum.any?(closed, &(&1.trace.name == "cue:routed"))
      assert state.traces == %{}
    end

    test "a filter-scoped phase is a child span of the filter call's trace" do
      {_state, closed} =
        run([
          {@cue_filter_start, %{count: 1}, cue_filter_meta(%{})},
          {@cue_event, %{count: 1},
           cue_meta(:dropped, %{
             session_id: @cue_filter_session,
             filter_call_id: "cfc_1",
             watcher_id: "cwt_9f2e",
             delivery_id: 17,
             cue_id: 9,
             decision: :drop,
             attempt: 0
           })},
          {@cue_filter_complete, %{count: 1, duration_ms: 950},
           cue_filter_meta(%{status: "ok", decision: "drop"})}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == @cue_filter_session
      wrapper = span_named(spans, @cue_filter_session)
      assert %{parent_span_id: parent, metadata: metadata} = span_named(spans, "cue:dropped")
      assert parent == wrapper.id
      assert metadata.decision == "drop"
      assert metadata.filter_call_id == "cfc_1"
    end

    # A `none` watcher's delivery passes at acceptance with no filter call (§14).
    test "a pass with no filter session ships as its own trace" do
      {_state, closed} =
        run([
          {@cue_event, %{count: 1},
           cue_meta(:passed, %{cue_id: 9, delivery_id: 17, reason: "no filter"})}
        ])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "cue:passed"
      assert trace.metadata.reason == "no filter"
    end

    # The claim is traced in the scheduler before the runner exists, so its
    # phase opens the run's session; the job's opener must still give the trace
    # its name, metadata, thread and sweep floor.
    test "a cue run's trace holds its claim and settle, with the job opener's fields" do
      {state, closed} =
        run([
          {@cue_event, %{queue_ms: 2_500}, cue_run_meta(:claimed, %{state: "claimed"})},
          {[:fermix, :job, :run_start], %{}, cue_job_meta(%{max_duration_ms: 600_000})}
        ])

      assert closed == []
      # Past the idle TTL but inside the run's own timeout: still open.
      {state, []} = Aggregation.sweep(state, 3 * 1_000_000 + 130_000_000)

      {_state, closed} =
        Enum.reduce(
          [
            {@cue_event, %{count: 1},
             cue_run_meta(:settled, %{state: "acked", outcome: "acted", reason: "acted"})},
            {[:fermix, :job, :run_complete], %{duration_ms: 900, iterations: 1},
             cue_job_meta(%{status: "ok"})}
          ],
          {state, []},
          fn {event, meas, meta}, {st, acc} ->
            at = %{at: ~U[2026-06-02 12:05:00.000Z], mono: 200_000_000}
            {st, new} = Aggregation.apply_event(st, event, meas, meta, at)
            {st, acc ++ new}
          end
        )

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "scheduled:release watch"
      assert trace.thread_id == "job-8"
      assert trace.metadata.trigger == "cue"
      assert trace.metadata.schedule_kind == "cue"
      assert trace.metadata.delivery_id == 17

      wrapper = span_named(spans, "scheduled:release watch")
      assert %{parent_span_id: claim_parent} = claimed = span_named(spans, "cue:claimed")
      assert claim_parent == wrapper.id
      assert claimed.metadata.queue_ms == 2_500
      assert span_named(spans, "cue:settled").parent_span_id == wrapper.id
    end

    # A follow-up's run (trigger "watcher", M60_WATCHER_CODING_RUNS.md §8) is
    # started by the scheduler before its runner exists, so its start opens the
    # run's session as a cue run's claim does; the job's opener names the trace
    # and gives it the trigger, the cue and the trigger's id.
    test "a follow-up's run trace holds its start, with the watcher trigger's ids" do
      started =
        cue_run_meta(:follow_up_started, %{trigger_id: "cft_4a", cue_id: 31, state: "started"})

      job =
        cue_job_meta(%{
          schedule_kind: "watcher",
          schedule_expr: "watcher",
          trigger: "watcher",
          delivery_id: nil,
          cue_id: 31,
          trigger_id: "cft_4a"
        })

      {_state, closed} =
        run([
          {@cue_event, %{count: 1}, started},
          {[:fermix, :job, :run_start], %{}, job},
          {[:fermix, :job, :run_complete], %{duration_ms: 900}, Map.put(job, :status, "ok")}
        ])

      assert [%{trace: trace, spans: spans}] = closed
      assert trace.name == "scheduled:release watch"
      assert trace.metadata.trigger == "watcher"
      assert trace.metadata.cue_id == 31
      assert trace.metadata.trigger_id == "cft_4a"
      wrapper = span_named(spans, "scheduled:release watch")
      start = span_named(spans, "cue:follow_up_started")
      assert start.parent_span_id == wrapper.id
      assert start.metadata.trigger_id == "cft_4a"
    end

    # A proposal is confirmed, or a crashed run reaped, after the run's trace
    # shipped: the phase still ships, as its own trace naming the run's session,
    # rather than being dropped at the tombstone or minting a phantom root.
    test "a run-scoped phase after the run's trace shipped is its own trace" do
      {state, closed} =
        run([
          {[:fermix, :job, :run_start], %{}, cue_job_meta(%{})},
          {[:fermix, :job, :run_complete], %{duration_ms: 900}, cue_job_meta(%{status: "ok"})},
          {@cue_event, %{count: 1},
           cue_run_meta(:confirmed, %{proposal_id: "cpr_1", state: "confirmed"})}
        ])

      assert [%{trace: run_trace}, %{trace: late, spans: []}] = closed
      assert run_trace.name == "scheduled:release watch"
      assert late.name == "cue:confirmed"
      assert late.metadata.session_id == @cue_run_session
      assert late.metadata.proposal_id == "cpr_1"
      assert state.dropped_after_close == 0
      assert state.traces == %{}
    end

    test "a run-scoped phase for a run that was never seen opens no root" do
      {state, closed} =
        run([{@cue_event, %{count: 1}, cue_run_meta(:exhausted, %{reason: "reaped"})}])

      assert [%{trace: trace, spans: []}] = closed
      assert trace.name == "cue:exhausted"
      assert trace.metadata.session_id == @cue_run_session
      assert state.traces == %{}
      assert state.sessions == %{}
    end

    # The owner confirms a proposal hours after its run's trace shipped and its
    # tombstone was pruned: the call still ships as its own trace, not as a
    # phantom `scheduled:` root holding one span.
    test "a proposal's confirmed call long after its run is its own trace" do
      {state, _closed} =
        run([
          {[:fermix, :job, :run_start], %{}, cue_job_meta(%{})},
          {[:fermix, :job, :run_complete], %{duration_ms: 900}, cue_job_meta(%{status: "ok"})}
        ])

      {state, []} = Aggregation.sweep(state, 10_000_000_000)
      assert state.closed_sessions == %{}

      confirmed = %{
        tool: "ops_create_issue",
        success: true,
        session_id: @cue_run_session,
        access_gate: "confirmed",
        mandate_call_id: "cmc_1"
      }

      at = %{at: ~U[2026-06-02 15:00:00.000Z], mono: 10_000_000_001}

      {state, closed} =
        Aggregation.apply_event(
          state,
          [:fermix, :tool, :exec],
          %{duration_ms: 400},
          confirmed,
          at
        )

      assert [%{trace: trace, spans: [span]}] = closed
      assert trace.name == "access_gate:confirmed"
      assert trace.metadata.session_id == @cue_run_session
      assert span.metadata.mandate_call_id == "cmc_1"
      assert state.traces == %{}
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
