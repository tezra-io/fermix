defmodule FermixChannels.Gateway.QueueTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.DraftStream
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Memory.ConversationStore

  # Stands in for `FermixCore.Agents.MainAgent.checkout_turn_state/2`. The turn
  # state it returns only needs to carry the test pid the fake runner reports to.
  defmodule StubAgent do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, opts) do
      case Map.get(opts, :error) do
        nil -> {:reply, {:ok, %{test_pid: opts.test_pid}, :hit}, opts}
        reason -> {:reply, {:error, reason}, opts}
      end
    end
  end

  # Controllable turn runner: announces each turn to the test, then blocks until
  # told to reply (returns the response — the QUEUE delivers it) or crash. Lets
  # the queue's scheduling + delivery be observed without a real provider/turn.
  defmodule FakeRunner do
    def run(msg, turn_state, _deliver) do
      send(turn_state.test_pid, {:turn_started, msg.content, self()})

      receive do
        {:proceed, :reply} ->
          {:ok, "reply:" <> msg.content, 0}

        {:proceed, :empty} ->
          {:ok, "", 0}

        {:proceed, :crash} ->
          raise "boom"
      after
        15_000 -> {:ok, "reply:" <> msg.content, 0}
      end
    end

    # Returns :compacted for the "compact_me" message so the queue's
    # post-compaction user notice can be exercised; :ok otherwise.
    def commit(msg, turn_state, response, _context_tokens) do
      send(turn_state.test_pid, {:committed, response})

      cond do
        msg.content == "commit_crash" -> raise "commit boom"
        msg.content == "compact_me" -> :compacted
        true -> :ok
      end
    end

    def error_reply(_reason), do: "error reply"
  end

  # Streaming-aware runner: run/4 drives the stream callback like a real turn
  # (session, iteration, then a delta past the 30-char draft threshold) unless
  # the message content opts out. run/3 is the legacy non-streaming entry.
  defmodule StreamingFakeRunner do
    def run(msg, turn_state, deliver), do: run(msg, turn_state, deliver, nil)

    def run(msg, turn_state, _deliver, stream_callback) do
      send(turn_state.test_pid, {:turn_started, msg.content, self()})
      maybe_stream(msg.content, stream_callback)

      receive do
        {:proceed, :reply} ->
          {:ok, "reply:" <> msg.content, 0}

        {:proceed, :error} ->
          {:error, :boom}

        {:proceed, :crash} ->
          raise "boom"
      after
        15_000 -> {:ok, "reply:" <> msg.content, 0}
      end
    end

    defp maybe_stream("no_deltas" <> _rest, _callback), do: :ok

    defp maybe_stream(_content, callback) when is_function(callback, 1) do
      callback.({:session_started, "sess-q"})
      callback.({:iteration_started, 1})
      callback.({:text_delta, "a streamed draft snapshot grown well past thirty characters"})
      :ok
    end

    defp maybe_stream(_content, _callback), do: :ok

    def commit(_msg, turn_state, response, _context_tokens) do
      send(turn_state.test_pid, {:committed, response})
      :ok
    end

    def error_reply(_reason), do: "error reply"
  end

  # Delivers a configured mid-turn channel side-effect (a reaction or media)
  # through the wrapped `deliver`, then returns an EMPTY final completion — the
  # react-then-empty / attachment-then-empty shape the §7 ledger must recognize.
  defmodule SideEffectRunner do
    def run(msg, turn_state, deliver), do: run(msg, turn_state, deliver, nil)

    def run(msg, turn_state, deliver, _stream_callback) do
      send(turn_state.test_pid, {:turn_started, msg.content, self()})

      receive do
        {:proceed, {:deliver_then_empty, part}} ->
          deliver.(part)
          {:ok, "", 0}

        {:proceed, :empty} ->
          {:ok, "", 0}
      after
        15_000 -> {:ok, "", 0}
      end
    end

    def commit(_msg, turn_state, response, _context_tokens) do
      send(turn_state.test_pid, {:committed, response})
      :ok
    end

    def error_reply(_reason), do: "error reply"
  end

  # Reports which `run/N` arity the queue dispatched to (the byte-identical
  # regression for messages that carry none of the optional closures), and
  # drives the activity callback when it is given one.
  defmodule ArityRunner do
    def run(msg, turn_state, _deliver), do: finish(msg, turn_state, 3)

    def run(msg, turn_state, _deliver, _stream_callback), do: finish(msg, turn_state, 4)

    def run(msg, turn_state, _deliver, _stream_callback, activity_callback) do
      activity_callback.({:tool_start, "shell"})
      activity_callback.({:tool_finish, "shell", %{status: :error}})
      finish(msg, turn_state, 5)
    end

    defp finish(msg, turn_state, arity) do
      send(turn_state.test_pid, {:runner_arity, arity})
      {:ok, "reply:" <> msg.content, 0}
    end

    def commit(_msg, turn_state, response, _context_tokens) do
      send(turn_state.test_pid, {:committed, response})
      :ok
    end

    def error_reply(_reason), do: "error reply"
  end

  # Stands in for ConversationStore, capturing the marker the queue appends to
  # close an emoji-only / attachment-only empty turn (§7). Bypasses the real
  # last-message-user? guard, which is ConversationStore's own tested concern.
  defmodule StubStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:append_stopped_marker, _key, content, _opts}, _from, opts) do
      send(opts.test_pid, {:marker_appended, content})
      {:reply, :marked, opts}
    end
  end

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, %{test_pid: self(), task_supervisor: task_supervisor}}
  end

  defp start_queue(ctx, opts \\ []) do
    agent_opts = Keyword.merge([test_pid: ctx.test_pid], Keyword.take(opts, [:error]))
    agent = start_supervised!({StubAgent, agent_opts}, id: :stub_agent)

    queue_opts =
      [
        name: :"queue_#{System.unique_integer([:positive])}",
        main_agent: Keyword.get(opts, :main_agent, agent),
        turn_runner: Keyword.get(opts, :turn_runner, FakeRunner),
        task_supervisor: Keyword.get(opts, :task_supervisor, ctx.task_supervisor)
      ]
      |> Keyword.merge(Keyword.take(opts, [:conversation_store]))

    start_supervised!({Queue, queue_opts}, id: :gateway_queue)
  end

  defp make_msg(content, chat_id, test_pid) do
    %{
      content: content,
      sender: "user",
      channel: "telegram",
      chat_id: chat_id,
      reply_fn: fn {:text, text} -> send(test_pid, {:reply, text}) end
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  describe "FIFO scheduling" do
    test "enqueues and starts a turn through checkout + runner", ctx do
      queue = start_queue(ctx)

      assert :ok = Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))

      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:hello"}, 5_000
    end

    test "an empty model completion is surfaced honestly and never committed", ctx do
      queue = start_queue(ctx)

      assert :ok = Queue.enqueue(queue, make_msg("anything", "ce", ctx.test_pid))

      assert_receive {:turn_started, "anything", turn_pid}, 5_000
      send(turn_pid, {:proceed, :empty})

      assert_receive {:reply, "I didn't get a response — please try again."}, 5_000
      # The blank completion is dropped pre-commit, so it cannot poison history.
      refute_received {:committed, _response}
    end
  end

  describe "side-effect acks (§7 EMOJI_REACTION_ACKS)" do
    # reply_fn forwards every delivered part to the test and lets a caller pick
    # the result for a reaction (so the "records only on :ok" path is testable).
    defp make_side_effect_msg(content, chat_id, test_pid, react_result \\ :ok) do
      %{
        content: content,
        sender: "user",
        channel: "telegram",
        chat_id: chat_id,
        reply_fn: fn
          {:react, _emoji} = part ->
            send(test_pid, {:delivered, part})
            react_result

          part ->
            send(test_pid, {:delivered, part})
            :ok
        end
      }
    end

    test "a reaction-then-empty turn suppresses the retry and appends a reacted marker", ctx do
      store = start_supervised!({StubStore, %{test_pid: ctx.test_pid}}, id: :stub_store)
      queue = start_queue(ctx, turn_runner: SideEffectRunner, conversation_store: store)

      Queue.enqueue(queue, make_side_effect_msg("thanks", "cr", ctx.test_pid))
      assert_receive {:turn_started, "thanks", turn_pid}, 5_000
      send(turn_pid, {:proceed, {:deliver_then_empty, {:react, "🙏"}}})

      assert_receive {:delivered, {:react, "🙏"}}, 5_000
      assert_receive {:marker_appended, "(Reacted to the previous message.)"}, 5_000
      # No canned retry text, and the empty response is never committed.
      refute_receive {:delivered, {:text, _}}, 300
      refute_received {:committed, _response}
    end

    test "an attachment-then-empty turn also suppresses the retry (regression)", ctx do
      store = start_supervised!({StubStore, %{test_pid: ctx.test_pid}}, id: :stub_store)
      queue = start_queue(ctx, turn_runner: SideEffectRunner, conversation_store: store)

      Queue.enqueue(queue, make_side_effect_msg("here", "cm", ctx.test_pid))
      assert_receive {:turn_started, "here", turn_pid}, 5_000
      send(turn_pid, {:proceed, {:deliver_then_empty, {:media, %{kind: :document, path: "x"}}}})

      assert_receive {:delivered, {:media, _part}}, 5_000
      assert_receive {:marker_appended, "(Sent an attachment in reply.)"}, 5_000
      refute_receive {:delivered, {:text, _}}, 300
    end

    test "a side-effect the channel REJECTS still yields the honest retry", ctx do
      store = start_supervised!({StubStore, %{test_pid: ctx.test_pid}}, id: :stub_store)
      queue = start_queue(ctx, turn_runner: SideEffectRunner, conversation_store: store)

      msg = make_side_effect_msg("thanks", "cf", ctx.test_pid, {:error, :reaction_unsupported})
      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "thanks", turn_pid}, 5_000
      send(turn_pid, {:proceed, {:deliver_then_empty, {:react, "🙏"}}})

      # Delivery failed → ledger unrecorded → the empty turn is genuinely empty.
      assert_receive {:delivered, {:text, "I didn't get a response — please try again."}}, 5_000
      refute_received {:marker_appended, _marker}
    end

    test "sends a compaction notice after the reply when the turn compacted", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("compact_me", "c1", ctx.test_pid))
      assert_receive {:turn_started, "compact_me", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      # Reply first, then the trailing compaction notice (commit ran :compacted).
      assert_receive {:reply, "reply:compact_me"}, 5_000
      assert_receive {:reply, notice}, 5_000
      assert notice =~ "Trimmed older conversation history"
    end

    test "sends no compaction notice on an ordinary turn", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))
      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:hello"}, 5_000
      refute_receive {:reply, _notice}, 200
    end

    test "reports active counts while a turn runs", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))
      assert_receive {:turn_started, "hello", turn_pid}, 5_000

      status = Queue.status(queue)
      assert status.active_conversations == 1
      assert status.active_requests == 1
      assert status.pending_requests == 0
      assert status.activity == :running

      send(turn_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:hello"}, 5_000
    end

    test "queues same-conversation turns FIFO without canceling the active turn", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("first", "c1", ctx.test_pid))
      assert_receive {:turn_started, "first", first_pid}, 5_000

      Queue.enqueue(queue, make_msg("second", "c1", ctx.test_pid))
      assert Process.alive?(first_pid)

      status = Queue.status(queue)
      assert status.active_requests == 1
      assert status.pending_requests == 1

      send(first_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:first"}, 5_000
      assert_receive {:committed, "reply:first"}, 5_000

      assert_receive {:turn_started, "second", second_pid}, 5_000
      send(second_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:second"}, 5_000
      assert_receive {:committed, "reply:second"}, 5_000
    end

    test "preserves FIFO order for multiple queued same-conversation turns", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("one", "c1", ctx.test_pid))
      assert_receive {:turn_started, "one", one_pid}, 5_000

      Queue.enqueue(queue, make_msg("two", "c1", ctx.test_pid))
      Queue.enqueue(queue, make_msg("three", "c1", ctx.test_pid))

      assert Queue.status(queue).pending_requests == 2

      send(one_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:one"}, 5_000

      assert_receive {:turn_started, "two", two_pid}, 5_000
      send(two_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:two"}, 5_000

      assert_receive {:turn_started, "three", three_pid}, 5_000
      send(three_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:three"}, 5_000

      assert eventually(fn -> Queue.status(queue).active_requests == 0 end)
    end

    test "runs different conversations independently", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("a", "c1", ctx.test_pid))
      assert_receive {:turn_started, "a", pid_a}, 5_000

      Queue.enqueue(queue, make_msg("b", "c2", ctx.test_pid))
      assert_receive {:turn_started, "b", pid_b}, 5_000

      assert Process.alive?(pid_a)
      send(pid_b, {:proceed, :reply})
      assert_receive {:reply, "reply:b"}, 5_000

      assert Process.alive?(pid_a)
      send(pid_a, {:proceed, :reply})
      assert_receive {:reply, "reply:a"}, 5_000
    end

    test "clears the active slot and replies when a turn crashes", ctx do
      queue = start_queue(ctx)

      capture_log(fn ->
        Queue.enqueue(queue, make_msg("boom", "c1", ctx.test_pid))
        assert_receive {:turn_started, "boom", turn_pid}, 5_000
        ref = Process.monitor(turn_pid)

        send(turn_pid, {:proceed, :crash})
        assert_receive {:DOWN, ^ref, :process, ^turn_pid, _reason}, 5_000
        assert_receive {:reply, reply}, 5_000
        assert reply =~ "error processing your message"
        assert eventually(fn -> Queue.status(queue).active_requests == 0 end)
      end)
    end

    test "does not send a crash fallback after the final reply was delivered", ctx do
      queue = start_queue(ctx)

      capture_log(fn ->
        Queue.enqueue(queue, make_msg("commit_crash", "c1", ctx.test_pid))
        assert_receive {:turn_started, "commit_crash", turn_pid}, 5_000
        ref = Process.monitor(turn_pid)

        send(turn_pid, {:proceed, :reply})
        assert_receive {:reply, "reply:commit_crash"}, 5_000
        assert_receive {:DOWN, ^ref, :process, ^turn_pid, _reason}, 5_000
        refute_receive {:reply, _reply}, 300
        assert eventually(fn -> Queue.status(queue).active_requests == 0 end)
      end)
    end
  end

  # A failed turn commits no assistant message, so the user message the runner
  # persisted before the loop is left dangling. A retry — durable, or a client
  # re-running the prompt — would then reach a model with no record of what the
  # failed turn already did, and repeat it.
  describe "a failed turn's orphaned user message" do
    test "is closed with the stopped-turn marker", ctx do
      store = start_supervised!({StubStore, %{test_pid: ctx.test_pid}}, id: :stub_store)
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner, conversation_store: store)

      Queue.enqueue(queue, make_msg("boom", "cfail", ctx.test_pid))
      assert_receive {:turn_started, "boom", turn_pid}, 5_000
      send(turn_pid, {:proceed, :error})

      assert_receive {:reply, "error reply"}, 5_000
      assert_receive {:marker_appended, marker}, 5_000
      assert marker =~ "stopped before I finished it"
      refute_received {:committed, _response}
    end

    test "a successful turn commits and appends no marker", ctx do
      store = start_supervised!({StubStore, %{test_pid: ctx.test_pid}}, id: :stub_store)
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner, conversation_store: store)

      Queue.enqueue(queue, make_msg("fine", "cok", ctx.test_pid))
      assert_receive {:turn_started, "fine", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:fine"}, 5_000
      assert_receive {:committed, "reply:fine"}, 5_000
      refute_receive {:marker_appended, _marker}, 300
    end

    test "a turn stopped mid-run writes exactly one marker, from the stop path", ctx do
      store = start_supervised!({StubStore, %{test_pid: ctx.test_pid}}, id: :stub_store)
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner, conversation_store: store)

      Queue.enqueue(queue, make_msg("stop me", "cstop", ctx.test_pid))
      assert_receive {:turn_started, "stop me", _turn_pid}, 5_000

      assert {:ok, %{active_stopped: 1}} = Queue.stop_conversation(key("cstop"), queue)

      assert_receive {:marker_appended, marker}, 5_000
      assert marker =~ "stopped before I finished it"
      refute_receive {:marker_appended, _second}, 300
    end
  end

  describe "failure handling" do
    test "delivers a generic error reply when checkout fails", ctx do
      queue = start_queue(ctx, error: :build_failed)

      capture_log(fn ->
        Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))
        assert_receive {:reply, reply}, 5_000
        assert reply =~ "error processing your message"
      end)

      assert eventually(fn -> Queue.status(queue).pending_requests == 0 end)
    end

    test "delivers a restart reply and emits telemetry when the agent is unavailable", ctx do
      attach_telemetry([:fermix, :gateway, :queue, :agent_unavailable])
      queue = start_queue(ctx, main_agent: :gateway_queue_test_no_such_agent)

      capture_log(fn ->
        Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))
        assert_receive {:reply, reply}, 5_000
        assert reply =~ "restarting"
      end)

      assert_receive {:telemetry, [:fermix, :gateway, :queue, :agent_unavailable], %{count: 1},
                      %{channel: "telegram"}},
                     5_000
    end

    test "clears pending and replies when the turn task cannot start", ctx do
      bad_supervisor =
        start_supervised!({Task.Supervisor, [max_children: 0]}, id: :bad_supervisor)

      queue = start_queue(ctx, task_supervisor: bad_supervisor)

      capture_log(fn ->
        Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))
        assert_receive {:reply, reply}, 5_000
        assert reply =~ "error processing your message"
      end)

      assert eventually(fn -> Queue.status(queue).pending_requests == 0 end)
      assert Queue.status(queue).active_requests == 0
    end
  end

  describe "stop_all" do
    test "terminates active turns, clears pending, returns counts, suppresses delivery", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("first", "c1", ctx.test_pid))
      assert_receive {:turn_started, "first", first_pid}, 5_000
      # "second" on the same conversation stays pending behind the active turn.
      Queue.enqueue(queue, make_msg("second", "c1", ctx.test_pid))
      # "other" on a different conversation runs concurrently.
      Queue.enqueue(queue, make_msg("other", "c2", ctx.test_pid))
      assert_receive {:turn_started, "other", other_pid}, 5_000

      assert eventually(fn -> Queue.status(queue).pending_requests == 1 end)

      ref1 = Process.monitor(first_pid)
      ref2 = Process.monitor(other_pid)

      counts = Queue.stop_all(queue)
      assert counts.active_stopped == 2
      assert counts.pending_cleared == 1

      assert_receive {:DOWN, ^ref1, :process, ^first_pid, _reason}, 5_000
      assert_receive {:DOWN, ^ref2, :process, ^other_pid, _reason}, 5_000

      # Neither stopped turn delivers a reply, and the cleared pending never starts.
      refute_receive {:reply, _text}, 300
      refute_receive {:turn_started, "second", _pid}, 300

      status = Queue.status(queue)
      assert status.active_requests == 0
      assert status.pending_requests == 0
    end

    test "returns zero counts when nothing is running", ctx do
      queue = start_queue(ctx)
      assert Queue.stop_all(queue) == %{active_stopped: 0, pending_cleared: 0}
    end

    test "appends a stopped marker after the active turn's user message", ctx do
      store =
        start_supervised!(
          {FermixCore.Memory.ConversationStore,
           name: :"queue_cs_#{System.unique_integer([:positive])}", repo: nil},
          id: :stop_marker_store
        )

      queue = start_queue(ctx, conversation_store: store)
      key = {"telegram", "c1", :root}

      # The real TurnRunner persists the user message at turn start; the fake
      # runner does not, so stand in for that persisted-but-unanswered turn.
      ConversationStore.add_message(key, "user", "stopped query",
        server: store,
        sender: "user"
      )

      Queue.enqueue(queue, make_msg("stopped query", "c1", ctx.test_pid))
      assert_receive {:turn_started, "stopped query", _pid}, 5_000

      assert %{active_stopped: 1} = Queue.stop_all(queue)

      assert eventually(fn ->
               match?(
                 [%{role: "user", content: "stopped query"}, %{role: "assistant"}],
                 ConversationStore.get_history(key, server: store)
               )
             end)

      [_user, marker] = ConversationStore.get_history(key, server: store)
      assert marker.content =~ "stopped"
    end
  end

  describe "telemetry" do
    test "emits enqueue telemetry with depth and mailbox latency", ctx do
      attach_telemetry([:fermix, :gateway, :queue, :enqueue])
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))

      assert_receive {:telemetry, [:fermix, :gateway, :queue, :enqueue], measurements, metadata},
                     5_000

      assert measurements.duration_us >= 0
      assert is_integer(measurements.depth)
      assert metadata.channel == "telegram"

      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})
    end

    test "emits request_start and request_complete around a turn", ctx do
      attach_telemetry([:fermix, :gateway, :queue, :request_start])
      attach_telemetry([:fermix, :gateway, :queue, :request_complete])
      queue = start_queue(ctx)
      channel = "queue_test_#{System.unique_integer([:positive])}"
      msg = make_msg("hello", "c1", ctx.test_pid) |> Map.put(:channel, channel)

      Queue.enqueue(queue, msg)

      assert_receive {:telemetry, [:fermix, :gateway, :queue, :request_start], %{count: 1},
                      %{request_id: 1, channel: ^channel}},
                     5_000

      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})
      assert_receive {:reply, "reply:hello"}, 5_000
      assert_receive {:committed, "reply:hello"}, 5_000

      assert_receive {:telemetry, [:fermix, :gateway, :queue, :request_complete], measurements,
                      %{request_id: 1, reason: :normal, channel: ^channel}},
                     5_000

      assert measurements.duration_us >= 0
    end
  end

  defp attach_telemetry(event) do
    test_pid = self()
    handler_id = "queue-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn evt, measurements, metadata, _config ->
        send(test_pid, {:telemetry, evt, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # -- Streaming turns (docs/design/CHANNEL_STREAMING.md §5.6-§5.8) --

  defp make_stream_spec(test_pid, overrides \\ []) do
    base = %DraftStream.Spec{
      channel: "telegram",
      open: fn text ->
        send(test_pid, {:draft_open, text})
        {:ok, 555}
      end,
      edit: fn handle, text ->
        send(test_pid, {:draft_edit, handle, text})
        :ok
      end,
      seal: fn handle, text ->
        send(test_pid, {:draft_seal, handle, text})
        {:ok, nil}
      end,
      discard: fn handle ->
        send(test_pid, {:draft_discard, handle})
        :ok
      end
    }

    struct!(base, overrides)
  end

  defp make_stream_msg(content, chat_id, test_pid, spec) do
    content
    |> make_msg(chat_id, test_pid)
    |> Map.put(:stream_spec, spec)
  end

  describe "streaming turns" do
    test "deltas open a draft and the final reply seals in place — no duplicate send", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      spec = make_stream_spec(ctx.test_pid)

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))

      assert_receive {:turn_started, "stream me", turn_pid}, 5_000
      assert_receive {:draft_open, text}, 5_000
      assert text =~ "thirty characters"

      send(turn_pid, {:proceed, :reply})

      assert_receive {:draft_seal, 555, "reply:stream me"}, 5_000
      assert_receive {:committed, "reply:stream me"}, 5_000
      refute_received {:reply, _text}
    end

    test "no deltas ⇒ no draft ⇒ the normal final delivery path", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      spec = make_stream_spec(ctx.test_pid)

      Queue.enqueue(queue, make_stream_msg("no_deltas", "c1", ctx.test_pid, spec))

      assert_receive {:turn_started, "no_deltas", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:no_deltas"}, 5_000
      assert_receive {:committed, "reply:no_deltas"}, 5_000
      refute_received {:draft_open, _text}
      refute_received {:draft_seal, _handle, _text}
    end

    test "seal overflow remainder goes out through the normal reply path", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      test_pid = ctx.test_pid

      spec =
        make_stream_spec(test_pid,
          seal: fn handle, text ->
            send(test_pid, {:draft_seal, handle, text})
            {:ok, "overflow tail"}
          end
        )

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))

      assert_receive {:turn_started, "stream me", turn_pid}, 5_000
      assert_receive {:draft_open, _text}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:draft_seal, 555, "reply:stream me"}, 5_000
      assert_receive {:reply, "overflow tail"}, 5_000
      assert_receive {:committed, "reply:stream me"}, 5_000
    end

    test "seal failure delivers the full response as one fresh message", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      test_pid = ctx.test_pid

      spec =
        make_stream_spec(test_pid,
          seal: fn _handle, _text -> {:error, :seal_boom} end
        )

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))

      assert_receive {:turn_started, "stream me", turn_pid}, 5_000
      assert_receive {:draft_open, _text}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:stream me"}, 5_000
      assert_receive {:committed, "reply:stream me"}, 5_000
    end

    test "turn error discards the draft and sends the error reply", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      spec = make_stream_spec(ctx.test_pid)

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))

      assert_receive {:turn_started, "stream me", turn_pid}, 5_000
      assert_receive {:draft_open, _text}, 5_000

      send(turn_pid, {:proceed, :error})

      assert_receive {:draft_discard, 555}, 5_000
      assert_receive {:reply, "error reply"}, 5_000
      refute_received {:committed, _response}
    end

    test "stop_all mid-stream reaps the turn and the engine discards the draft", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      spec = make_stream_spec(ctx.test_pid)

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))

      assert_receive {:turn_started, "stream me", _turn_pid}, 5_000
      assert_receive {:draft_open, _text}, 5_000

      assert %{active_stopped: 1} = Queue.stop_all(queue)

      assert_receive {:draft_discard, 555}, 5_000
      refute_received {:committed, _response}
      refute_received {:reply, _text}
    end

    test "turn crash mid-stream still discards the draft through the trap-exit path", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      spec = make_stream_spec(ctx.test_pid)

      capture_log(fn ->
        Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))

        assert_receive {:turn_started, "stream me", turn_pid}, 5_000
        assert_receive {:draft_open, _text}, 5_000

        send(turn_pid, {:proceed, :crash})

        assert_receive {:draft_discard, 555}, 5_000
        # The generic crash reply still goes out (final reply never delivered).
        assert_receive {:reply, "Sorry, I encountered an error" <> _rest}, 5_000
        refute_received {:committed, _response}
      end)
    end
  end

  # -- M29 Stage 2 seams (docs/design/MILESTONE_29_ACP_AGENT_SURFACE.md §6.3) --

  defp with_turn_result(msg, test_pid) do
    Map.put(msg, :turn_result_fn, fn outcome -> send(test_pid, {:turn_result, outcome}) end)
  end

  defp with_terminal_error_owner(msg), do: Map.put(msg, :terminal_error_owner?, true)

  defp key(chat_id), do: {"telegram", chat_id, :root}

  describe "stop_conversation/2" do
    test "stops only the target conversation; a sibling turn keeps running", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("a", "c1", ctx.test_pid))
      assert_receive {:turn_started, "a", pid_a}, 5_000
      Queue.enqueue(queue, make_msg("b", "c2", ctx.test_pid))
      assert_receive {:turn_started, "b", pid_b}, 5_000
      # A second c1 message waits behind the active turn and must be cleared.
      Queue.enqueue(queue, make_msg("a2", "c1", ctx.test_pid))
      assert eventually(fn -> Queue.status(queue).pending_requests == 1 end)

      ref_a = Process.monitor(pid_a)

      assert {:ok, %{active_stopped: 1, pending_cleared: 1}} =
               Queue.stop_conversation(key("c1"), queue)

      assert_receive {:DOWN, ^ref_a, :process, ^pid_a, _reason}, 5_000
      refute_receive {:turn_started, "a2", _pid}, 300

      # The sibling conversation was untouched and still completes normally.
      assert Process.alive?(pid_b)
      send(pid_b, {:proceed, :reply})
      assert_receive {:reply, "reply:b"}, 5_000
      assert_receive {:committed, "reply:b"}, 5_000
      refute_received {:reply, "reply:a"}

      # The sibling's slot clears on its task DOWN, which the queue processes
      # asynchronously (same wait the stop_all/FIFO tests use).
      assert eventually(fn -> Queue.status(queue).active_requests == 0 end)
      assert Queue.status(queue).pending_requests == 0
    end

    test "appends the stopped marker to the target conversation only", ctx do
      store =
        start_supervised!(
          {ConversationStore, name: :"queue_cs_#{System.unique_integer([:positive])}", repo: nil},
          id: :stop_one_store
        )

      queue = start_queue(ctx, conversation_store: store)

      # The real TurnRunner persists the user message at turn start; the fake
      # runner does not, so stand in for both persisted-but-unanswered turns.
      ConversationStore.add_message(key("c1"), "user", "stop me", server: store, sender: "user")
      ConversationStore.add_message(key("c2"), "user", "leave me", server: store, sender: "user")

      Queue.enqueue(queue, make_msg("stop me", "c1", ctx.test_pid))
      assert_receive {:turn_started, "stop me", _pid}, 5_000
      Queue.enqueue(queue, make_msg("leave me", "c2", ctx.test_pid))
      assert_receive {:turn_started, "leave me", sibling_pid}, 5_000

      assert {:ok, %{active_stopped: 1}} = Queue.stop_conversation(key("c1"), queue)

      assert eventually(fn ->
               match?(
                 [%{role: "user"}, %{role: "assistant"}],
                 ConversationStore.get_history(key("c1"), server: store)
               )
             end)

      [_user, marker] = ConversationStore.get_history(key("c1"), server: store)
      assert marker.content =~ "stopped"

      assert [%{role: "user", content: "leave me"}] =
               ConversationStore.get_history(key("c2"), server: store)

      assert Process.alive?(sibling_pid)
    end

    test "returns :not_found for a conversation with nothing active or pending", ctx do
      queue = start_queue(ctx)
      assert {:ok, :not_found} = Queue.stop_conversation(key("never_seen"), queue)
    end
  end

  describe "turn_result_fn" do
    test "fires {:completed} exactly once on a normal turn", ctx do
      queue = start_queue(ctx)
      msg = with_turn_result(make_msg("hello", "c1", ctx.test_pid), ctx.test_pid)

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:hello"}, 5_000
      assert_receive {:turn_result, {:completed}}, 5_000
      refute_receive {:turn_result, _outcome}, 300
    end

    test "fires {:completed} for a delivered canned empty completion", ctx do
      queue = start_queue(ctx)
      msg = with_turn_result(make_msg("anything", "ce", ctx.test_pid), ctx.test_pid)

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "anything", turn_pid}, 5_000
      send(turn_pid, {:proceed, :empty})

      assert_receive {:reply, "I didn't get a response — please try again."}, 5_000
      assert_receive {:turn_result, {:completed}}, 5_000
      refute_receive {:turn_result, _outcome}, 300
    end

    test "fires {:failed, raw_reason} once on the error path, before stringification", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      msg = with_turn_result(make_msg("boom", "c1", ctx.test_pid), ctx.test_pid)

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "boom", turn_pid}, 5_000
      send(turn_pid, {:proceed, :error})

      # The channel still gets today's rendered text; the callback gets the raw
      # reason the runner returned.
      assert_receive {:reply, "error reply"}, 5_000
      assert_receive {:turn_result, {:failed, :boom}}, 5_000
      refute_receive {:turn_result, _outcome}, 300
    end

    test "fires {:failed, {:crashed, reason}} once when the turn task dies", ctx do
      queue = start_queue(ctx)
      msg = with_turn_result(make_msg("boom", "c1", ctx.test_pid), ctx.test_pid)

      capture_log(fn ->
        Queue.enqueue(queue, msg)
        assert_receive {:turn_started, "boom", turn_pid}, 5_000
        send(turn_pid, {:proceed, :crash})

        assert_receive {:turn_result, {:failed, {:crashed, _reason}}}, 5_000
        refute_receive {:turn_result, _outcome}, 300
      end)
    end

    test "fires {:cancelled} once when the conversation is stopped", ctx do
      queue = start_queue(ctx)
      msg = with_turn_result(make_msg("hello", "c1", ctx.test_pid), ctx.test_pid)

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "hello", _turn_pid}, 5_000

      assert {:ok, %{active_stopped: 1}} = Queue.stop_conversation(key("c1"), queue)

      assert_receive {:turn_result, {:cancelled}}, 5_000
      refute_receive {:turn_result, _outcome}, 300
      refute_received {:reply, _text}
    end

    test "stop_all fires {:cancelled} for every active turn it kills", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, with_turn_result(make_msg("a", "c1", ctx.test_pid), ctx.test_pid))
      assert_receive {:turn_started, "a", _pid_a}, 5_000
      Queue.enqueue(queue, with_turn_result(make_msg("b", "c2", ctx.test_pid), ctx.test_pid))
      assert_receive {:turn_started, "b", _pid_b}, 5_000

      assert %{active_stopped: 2} = Queue.stop_all(queue)

      assert_receive {:turn_result, {:cancelled}}, 5_000
      assert_receive {:turn_result, {:cancelled}}, 5_000
      refute_receive {:turn_result, _outcome}, 300
    end

    # Race pin, direction 1: the turn reaches its own terminal invocation first
    # (it is parked INSIDE the callback, so its conversation is still active),
    # and a stop lands on top. Deterministic — the stop cannot run until the
    # test issues it.
    test "a stop landing after the turn already fired does not fire again", ctx do
      queue = start_queue(ctx)
      test_pid = ctx.test_pid

      msg =
        Map.put(make_msg("hello", "c1", test_pid), :turn_result_fn, fn outcome ->
          send(test_pid, {:turn_result, outcome})

          receive do
            :release -> :ok
          end
        end)

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:hello"}, 5_000
      assert_receive {:turn_result, {:completed}}, 5_000

      assert {:ok, %{active_stopped: 1}} = Queue.stop_conversation(key("c1"), queue)
      refute_receive {:turn_result, _outcome}, 300
    end

    # Race pin, direction 2: the stop lands while the turn is parked in its
    # delivery closure — before it can claim — so only the stop fires.
    test "a stop landing before the turn's terminal claim fires only {:cancelled}", ctx do
      queue = start_queue(ctx)
      test_pid = ctx.test_pid

      msg =
        make_msg("hello", "c1", test_pid)
        |> Map.put(:reply_fn, fn {:text, text} ->
          send(test_pid, {:delivering, text})

          receive do
            :release -> :ok
          end
        end)
        |> with_turn_result(test_pid)

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})
      assert_receive {:delivering, "reply:hello"}, 5_000

      assert {:ok, %{active_stopped: 1}} = Queue.stop_conversation(key("c1"), queue)

      assert_receive {:turn_result, {:cancelled}}, 5_000
      refute_receive {:turn_result, _outcome}, 300
    end

    test "a raising callback takes down neither the turn task nor the queue", ctx do
      queue = start_queue(ctx)

      msg =
        Map.put(make_msg("hello", "c1", ctx.test_pid), :turn_result_fn, fn _outcome ->
          raise "callback boom"
        end)

      log =
        capture_log(fn ->
          Queue.enqueue(queue, msg)
          assert_receive {:turn_started, "hello", turn_pid}, 5_000
          send(turn_pid, {:proceed, :reply})
          assert_receive {:committed, "reply:hello"}, 5_000

          # The queue keeps scheduling, and no crash fallback reply goes out.
          Queue.enqueue(queue, make_msg("next", "c1", ctx.test_pid))
          assert_receive {:turn_started, "next", next_pid}, 5_000
          send(next_pid, {:proceed, :reply})
          assert_receive {:reply, "reply:next"}, 5_000
        end)

      assert log =~ "Turn result callback raised"
      assert log =~ "callback boom"
    end

    test "fires {:failed, reason} once when the turn-state checkout fails", ctx do
      queue = start_queue(ctx, error: :build_failed)
      msg = with_turn_result(make_msg("hello", "c1", ctx.test_pid), ctx.test_pid)

      capture_log(fn ->
        Queue.enqueue(queue, msg)
        assert_receive {:reply, reply}, 5_000
        assert reply =~ "error processing your message"
        assert_receive {:turn_result, {:failed, :build_failed}}, 5_000
        refute_receive {:turn_result, _outcome}, 300
      end)
    end

    test "fires {:failed, reason} once when the turn task cannot start", ctx do
      bad_supervisor =
        start_supervised!({Task.Supervisor, [max_children: 0]}, id: :bad_supervisor_result)

      queue = start_queue(ctx, task_supervisor: bad_supervisor)
      msg = with_turn_result(make_msg("hello", "c1", ctx.test_pid), ctx.test_pid)

      capture_log(fn ->
        Queue.enqueue(queue, msg)
        assert_receive {:reply, reply}, 5_000
        assert reply =~ "error processing your message"
        assert_receive {:turn_result, {:failed, _reason}}, 5_000
        refute_receive {:turn_result, _outcome}, 300
      end)
    end

    test "a message without turn_result_fn runs today's path with no callback", ctx do
      queue = start_queue(ctx)

      Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))
      assert_receive {:turn_started, "hello", turn_pid}, 5_000
      send(turn_pid, {:proceed, :reply})

      assert_receive {:reply, "reply:hello"}, 5_000
      assert_receive {:committed, "reply:hello"}, 5_000
      refute_received {:turn_result, _outcome}
    end
  end

  # A channel whose `terminal_error_capability` is `:turn_result` renders terminal
  # errors itself from the raw reason, so the queue suppresses its canned text —
  # and ONLY that text. The plain-channel canned replies stay pinned by the
  # "failure handling" describe above.
  describe "terminal_error_owner? suppression" do
    test "a checkout failure suppresses the text but still logs and emits telemetry", ctx do
      attach_telemetry([:fermix, :gateway, :queue, :agent_unavailable])
      queue = start_queue(ctx, main_agent: :gateway_queue_test_terminal_owner_agent)

      msg =
        make_msg("hello", "c1", ctx.test_pid)
        |> with_turn_result(ctx.test_pid)
        |> with_terminal_error_owner()

      log =
        capture_log(fn ->
          Queue.enqueue(queue, msg)
          assert_receive {:turn_result, {:failed, {:checkout_unavailable, _reason}}}, 5_000
          refute_receive {:reply, _text}, 300
        end)

      assert log =~ "checkout failed"

      assert_receive {:telemetry, [:fermix, :gateway, :queue, :agent_unavailable], %{count: 1},
                      %{channel: "telegram"}},
                     5_000
    end

    test "a runner error suppresses the error text and hands over the raw reason", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)

      msg =
        make_msg("boom", "c1", ctx.test_pid)
        |> with_turn_result(ctx.test_pid)
        |> with_terminal_error_owner()

      Queue.enqueue(queue, msg)
      assert_receive {:turn_started, "boom", turn_pid}, 5_000
      send(turn_pid, {:proceed, :error})

      assert_receive {:turn_result, {:failed, :boom}}, 5_000
      refute_receive {:reply, _text}, 300
      refute_received {:committed, _response}
    end

    test "a crashed turn task suppresses the canned crash text", ctx do
      queue = start_queue(ctx)

      msg =
        make_msg("boom", "c1", ctx.test_pid)
        |> with_turn_result(ctx.test_pid)
        |> with_terminal_error_owner()

      capture_log(fn ->
        Queue.enqueue(queue, msg)
        assert_receive {:turn_started, "boom", turn_pid}, 5_000
        send(turn_pid, {:proceed, :crash})

        assert_receive {:turn_result, {:failed, {:crashed, _reason}}}, 5_000
        refute_receive {:reply, _text}, 300
      end)
    end
  end

  describe "raw stream tier" do
    test "forwards loop stream events verbatim and spawns no draft engine", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      test_pid = ctx.test_pid
      spec = %{mode: :raw, callback: fn event -> send(test_pid, {:raw_event, event}) end}

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", test_pid, spec))
      assert_receive {:turn_started, "stream me", turn_pid}, 5_000

      # No DraftStream engine: the engine is spawn_linked by the turn task
      # before the runner is called, so the task's only link is its supervisor.
      assert {:links, [ctx.task_supervisor]} == Process.info(turn_pid, :links)

      assert_receive {:raw_event, {:session_started, "sess-q"}}, 5_000
      assert_receive {:raw_event, {:iteration_started, 1}}, 5_000
      assert_receive {:raw_event, {:text_delta, delta}}, 5_000
      assert delta =~ "thirty characters"

      send(turn_pid, {:proceed, :reply})
      # Final delivery is the ordinary reply path (nothing to seal).
      assert_receive {:reply, "reply:stream me"}, 5_000
      assert_receive {:committed, "reply:stream me"}, 5_000
    end

    test "a DraftStream spec still drives the engine (regression)", ctx do
      queue = start_queue(ctx, turn_runner: StreamingFakeRunner)
      spec = make_stream_spec(ctx.test_pid)

      Queue.enqueue(queue, make_stream_msg("stream me", "c1", ctx.test_pid, spec))
      assert_receive {:turn_started, "stream me", turn_pid}, 5_000
      assert_receive {:draft_open, _text}, 5_000

      send(turn_pid, {:proceed, :reply})
      assert_receive {:draft_seal, 555, "reply:stream me"}, 5_000
    end
  end

  describe "activity_callback threading" do
    test "a message with an activity_callback reaches run/5 and gets its events", ctx do
      queue = start_queue(ctx, turn_runner: ArityRunner)
      test_pid = ctx.test_pid

      msg =
        make_msg("hello", "c1", test_pid)
        |> Map.put(:activity_callback, fn event -> send(test_pid, {:activity, event}) end)

      Queue.enqueue(queue, msg)

      assert_receive {:runner_arity, 5}, 5_000
      assert_receive {:activity, {:tool_start, "shell"}}, 5_000
      assert_receive {:activity, {:tool_finish, "shell", %{status: :error}}}, 5_000
      assert_receive {:reply, "reply:hello"}, 5_000
    end

    test "a message with neither callback still dispatches to run/3", ctx do
      queue = start_queue(ctx, turn_runner: ArityRunner)

      Queue.enqueue(queue, make_msg("hello", "c1", ctx.test_pid))

      assert_receive {:runner_arity, 3}, 5_000
      refute_received {:activity, _event}
    end

    test "a stream spec without an activity callback still dispatches to run/4", ctx do
      queue = start_queue(ctx, turn_runner: ArityRunner)
      test_pid = ctx.test_pid
      spec = %{mode: :raw, callback: fn event -> send(test_pid, {:raw_event, event}) end}

      Queue.enqueue(queue, make_stream_msg("hello", "c1", test_pid, spec))

      assert_receive {:runner_arity, 4}, 5_000
    end
  end
end
