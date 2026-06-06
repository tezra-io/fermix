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
end
