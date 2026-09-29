defmodule FermixChannels.Channels.CompanionTest do
  # The adapter broadcasts through the one application-wide companion registry,
  # and each test joins it under the only profile, so the tests run alone.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source

  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  # The queue a tracked turn is handed to: it takes the message and reports it.
  defmodule QueueSink do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast({:enqueue, message}, test_pid) do
      send(test_pid, {:enqueued, message.id})
      {:noreply, test_pid}
    end

    @impl true
    def handle_call({:stop_turn, key, message_id}, _from, test_pid) do
      send(test_pid, {:stop_turn, key, message_id})
      {:reply, {:ok, :dequeued}, test_pid}
    end
  end

  # A queue busy in its stop callback (a stopped-marker write on a stalled
  # store): the stop is answered only when the test releases it.
  defmodule SlowQueueSink do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast({:enqueue, message}, test_pid) do
      send(test_pid, {:enqueued, message.id})
      {:noreply, test_pid}
    end

    @impl true
    def handle_call({:stop_turn, _key, message_id}, from, test_pid) do
      send(test_pid, {:stop_waiting, message_id, self()})

      receive do
        :release -> GenServer.reply(from, {:ok, :stopped})
      after
        10_000 -> :ok
      end

      {:noreply, test_pid}
    end
  end

  # Reports to the test by name: `Companion.Turns` writes from its own process.
  defmodule StoreStub do
    def append(profile, attrs, _opts) do
      send(:companion_adapter_test, {:append, profile, attrs})
      {:ok, row(profile, attrs, 41)}
    end

    def append_client_output(profile, client_id, attempt, key, attrs, _opts) do
      send(:companion_adapter_test, {:client_output, profile, client_id, attempt, key, attrs})
      {:ok, {:created, row(profile, Map.put(attrs, :role, "assistant"), 42)}}
    end

    def append_proactive(profile, key, attrs, _opts) do
      send(:companion_adapter_test, {:proactive, profile, key, attrs})
      {:ok, {:existing, row(profile, attrs, 43)}}
    end

    defp row(profile, attrs, seq),
      do:
        Map.merge(attrs, %{
          profile_id: profile,
          server_seq: seq,
          created_at: ~U[2026-09-26 09:00:00Z]
        })

    def complete_client_request(profile, client_id, attempt, _fields, _opts) do
      send(:companion_adapter_test, {:completed, profile, client_id, attempt})
      {:ok, %{status: "completed"}}
    end

    def fail_client_request(profile, client_id, attempt, fields, _opts) do
      send(:companion_adapter_test, {:failed, profile, client_id, attempt, fields})
      {:ok, %{status: "failed"}}
    end

    # A request is cancelled when the test recorded a cancel on it.
    def get_client_request(profile, client_id, _opts) do
      cancelled = :persistent_term.get({__MODULE__, :cancelled}, [])
      mark = if client_id in cancelled, do: ~U[2026-09-26 09:00:00Z]

      {:ok,
       %{profile_id: profile, client_msg_id: client_id, status: "running", cancelled_at: mark}}
    end
  end

  setup do
    previous = Application.fetch_env(:fermix_channels, :companion_store)
    previous_approvals = Application.fetch_env(:fermix_channels, :companion_approvals)
    Application.put_env(:fermix_channels, :companion_store, StoreStub)

    approvals =
      start_supervised!(
        {Approvals, name: nil, schedule: fn _message, _delay -> make_ref() end},
        id: :companion_test_approvals
      )

    Application.put_env(:fermix_channels, :companion_approvals, approvals)
    Process.register(self(), :companion_adapter_test)
    {:ok, _owner} = Registry.register(Companion.registry(), "main", nil)
    start_supervised!(Turns)

    on_exit(fn ->
      :persistent_term.erase({StoreStub, :cancelled})

      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :companion_store, value)
        :error -> Application.delete_env(:fermix_channels, :companion_store)
      end

      case previous_approvals do
        {:ok, value} -> Application.put_env(:fermix_channels, :companion_approvals, value)
        :error -> Application.delete_env(:fermix_channels, :companion_approvals)
      end
    end)

    {:ok, approvals: approvals}
  end

  describe "registry entry" do
    test "carries the local-operator shape with slash commands on" do
      entry = Enum.find(ChannelRegistry.channels(), &(&1.name == "companion"))

      assert entry == %{
               name: "companion",
               config_key: nil,
               adapter: Companion,
               remote?: true,
               trust: :local_operator,
               transport: :loopback,
               child: nil
             }

      assert ChannelRegistry.commands?("companion")

      refute "companion" in Enum.map(
               ChannelRegistry.transport_children(%{status: :ready}),
               &elem(&1, 0)
             )
    end

    test "authorizes as the operator with no sender id and no ingress list" do
      source = Source.from_message(%{channel: "companion", chat_id: "main", metadata: %{}})
      assert {:ok, %{role: :operator, trust: :operator}} = Authorizer.resolve(source)
    end

    test "the shipped config delivers scheduled jobs back into the companion timeline" do
      channels =
        @config_exs
        |> Config.Reader.read!(env: :prod, target: :host)
        |> Keyword.fetch!(:fermix_core)
        |> Keyword.fetch!(:jobs)
        |> Keyword.fetch!(:delivery_channels)

      assert channels["companion"] == Companion
    end
  end

  test "parses a message and a command onto the companion conversation" do
    assert {:ok, [message]} =
             Companion.parse_event(%{
               type: "msg",
               payload: %{
                 "client_msg_id" => "mac-1",
                 "profile_id" => "main",
                 "text" => "hi",
                 "attach_ids" => []
               }
             })

    assert %Message{channel: "companion", chat_id: "main", reply_target: "main"} = message
    assert message.metadata.turn_id == "turn-mac-1"
    assert Companion.conversation_key("main") == {"companion", "main", :root}

    assert {:ok, [command]} =
             Companion.parse_event(%{
               type: "command",
               payload: %{
                 "client_msg_id" => "mac-2",
                 "profile_id" => "main",
                 "name" => "confirm",
                 "args" => "TOKEN"
               }
             })

    assert command.content == "/confirm TOKEN"

    assert {:error, :unsupported_profile} =
             Companion.parse_event(%{type: "msg", payload: %{"profile_id" => "work"}})

    assert {:error, :attachments_unsupported} =
             Companion.parse_event(%{
               type: "msg",
               payload: %{
                 "client_msg_id" => "mac-3",
                 "profile_id" => "main",
                 "text" => "x",
                 "attach_ids" => ["a"]
               }
             })
  end

  test "a message ingests as the operator with the raw stream and every turn closure" do
    {:ok, [message]} =
      Companion.parse_event(%{
        type: "msg",
        payload: %{
          "client_msg_id" => "mac-7",
          "profile_id" => "main",
          "text" => "what is on today",
          "attach_ids" => []
        }
      })

    assert :ok =
             Gateway.ingest([message],
               channel: Companion,
               agent: CapturingAgent,
               agent_server: self(),
               ingress_context: %{transport: :companion}
             )

    assert_receive {:agent_message, agent_message}
    assert agent_message.channel == "companion"
    assert agent_message.source_trust == :operator
    assert %{mode: :raw, callback: callback} = agent_message.stream_spec
    assert is_function(callback, 1)
    assert is_function(agent_message.activity_callback, 1)
    assert is_function(agent_message.turn_result_fn, 1)
  end

  test "the raw stream announces the turn and relays cumulative snapshots" do
    message = request_message()
    assert Companion.stream_capability() == :raw
    stream = Companion.build_raw_stream_callback(message)

    stream.({:session_started, "session-1"})

    assert_receive {:companion_event,
                    %{
                      "t" => "turn_started",
                      "profile_id" => "main",
                      "turn_id" => "turn-mac-1",
                      "in_reply_to" => "mac-1"
                    }}

    stream.({:text_delta, "Hel"})
    stream.({:iteration_started, 2})
    stream.({:reasoning_delta, "thinking"})
    stream.({:text_done, "Hello"})

    assert_receive {:companion_stream, "turn-mac-1", {:snapshot, "Hel"}}
    assert_receive {:companion_stream, "turn-mac-1", :reset}
    assert_receive {:companion_stream, "turn-mac-1", {:snapshot, "Hello"}}
    refute_receive {:companion_stream, _turn, {:snapshot, "thinking"}}
  end

  test "a turn's replies are written and announced only once the queue completes it" do
    handler = attach_message_telemetry()
    on_exit(fn -> :telemetry.detach(handler) end)
    message = track(request_message())
    reply = Companion.build_text_reply(message)

    assert :ok = reply.("first part")
    assert :ok = reply.("the answer")
    refute_receive {:client_output, _profile, _id, _attempt, _key, _attrs}, 100
    refute_received {:companion_event, %{"t" => "text_done"}}

    assert :ok = Companion.build_turn_result(message).({:completed})

    assert_receive {:client_output, "main", "mac-1", 3, "text:" <> _digest,
                    %{content: "first part"}}

    assert_receive {:client_output, "main", "mac-1", 3, _key, %{content: "the answer"} = attrs}
    assert attrs.in_reply_to == "mac-1"

    assert_receive {:companion_event,
                    %{"t" => "text_done", "turn_id" => "turn-mac-1", "text" => "first part"}}

    assert_receive {:companion_event,
                    %{"t" => "text_done", "text" => "the answer", "server_seq" => 42}}

    assert_receive {:completed, "main", "mac-1", 3}

    for _row <- 1..2 do
      assert_receive {:telemetry, %{count: 1, duration_us: us},
                      %{channel: :companion, direction: :outbound}}

      assert is_integer(us) and us >= 0
    end

    refute_received {:telemetry, _measurements, %{direction: :outbound}}
  end

  test "a cancelled turn ends once, as cancelled, and keeps nothing it held" do
    handler = attach_message_telemetry()
    on_exit(fn -> :telemetry.detach(handler) end)
    message = track(request_message())
    reply = Companion.build_text_reply(message)
    result = Companion.build_turn_result(message)

    assert :ok = reply.("partial")
    assert :ok = result.({:cancelled})

    assert_receive {:failed, "main", "mac-1", 3, _fields}

    assert_receive {:companion_event,
                    %{"t" => "turn_error", "turn_id" => "turn-mac-1", "code" => "cancelled"}}

    # A reply or an outcome that arrives after the turn ended is dropped.
    assert :ok = reply.("late")
    assert :ok = result.({:completed})
    refute_receive {:client_output, _profile, _id, _attempt, _key, _attrs}, 100
    refute_received {:completed, _profile, _id, _attempt}
    refute_received {:companion_event, %{"t" => "text_done"}}
    refute_received {:telemetry, _measurements, %{direction: :outbound}}
  end

  test "a request cancelled before its hand-off never reaches the queue" do
    :persistent_term.put({StoreStub, :cancelled}, ["mac-1"])
    queue = start_supervised!({QueueSink, self()}, id: :queue_sink)
    message = request_message()

    assert :ok = Turns.handle_message(Map.from_struct(message), queue)
    handed_off(queue)

    refute_received {:enqueued, "mac-1"}
    assert_received {:failed, "main", "mac-1", 3, %{error: ":cancelled"}}

    assert_received {:companion_event,
                     %{"t" => "turn_error", "turn_id" => "turn-mac-1", "code" => "cancelled"}}

    # Its turn has ended: a stop finds nothing to stop, and a late outcome is dropped.
    assert :ok = Turns.cancel(Turns, "main", "mac-1")
    refute_received {:stop_turn, _key, _id}
    assert :ok = Companion.build_turn_result(message).({:completed})
    refute_receive {:completed, _profile, _id, _attempt}, 100
  end

  # Boot recovery hands a request off through the same step, as a new attempt.
  test "a recovered request with a cancel on it ends cancelled instead of running again" do
    :persistent_term.put({StoreStub, :cancelled}, ["mac-1"])
    queue = start_supervised!({QueueSink, self()}, id: :queue_sink)
    recovered = request_message()
    recovered = %{recovered | metadata: %{recovered.metadata | companion_attempt: 4}}

    assert :ok = Turns.handle_message(Map.from_struct(recovered), queue)
    handed_off(queue)

    refute_received {:enqueued, "mac-1"}
    assert_received {:failed, "main", "mac-1", 4, _fields}
    assert_received {:companion_event, %{"t" => "turn_error", "code" => "cancelled"}}
  end

  test "a cancel for a turn already handed off is stopped in the queue by the hand-off's owner" do
    queue = start_supervised!({QueueSink, self()}, id: :queue_sink)
    track(request_message(), queue)

    assert :ok = Turns.cancel(Turns, "main", "mac-1")
    assert_receive {:stop_turn, {"companion", "main", :root}, "mac-1"}

    # Another request's cancel never stops this turn.
    assert :ok = Turns.cancel(Turns, "main", "mac-2")
    refute_receive {:stop_turn, _key, "mac-2"}, 100
  end

  test "a failed turn ends with its failure's code" do
    message = track(request_message())
    assert :ok = Companion.build_turn_result(message).({:failed, {:provider_error, 500}})
    assert_receive {:companion_event, %{"t" => "turn_error", "code" => "turn_failed"}}
  end

  test "a turn whose queue dies ends once, as interrupted" do
    queue = start_supervised!({QueueSink, self()}, id: :dying_queue)
    message = track(request_message(), queue)

    Process.exit(queue, :kill)

    assert_receive {:companion_event,
                    %{"t" => "turn_error", "turn_id" => "turn-mac-1", "code" => "interrupted"}}

    assert_receive {:failed, "main", "mac-1", 3, _fields}
    assert :ok = Companion.build_turn_result(message).({:completed})
    refute_receive {:completed, _profile, _id, _attempt}, 100
  end

  # Turns is held while a cancel and then its queue's death reach it, so it
  # reads the cancel before the `:DOWN`: the stop goes to a queue that is gone.
  test "a cancel that finds its turn's queue gone leaves the :DOWN to end the turn" do
    queue = start_supervised!({QueueSink, self()}, id: :dying_queue)
    message = track(request_message(), queue)
    turns = GenServer.whereis(Turns)

    :ok = :sys.suspend(turns)
    cancel = Task.async(fn -> Turns.cancel(Turns, "main", "mac-1") end)
    wait_until(fn -> mailbox_size(turns) >= 1 end)
    queue_ref = Process.monitor(queue)
    Process.exit(queue, :kill)
    assert_receive {:DOWN, ^queue_ref, :process, ^queue, :killed}
    wait_until(fn -> mailbox_size(turns) >= 2 end)
    :ok = :sys.resume(turns)

    assert :ok = Task.await(cancel)
    assert GenServer.whereis(Turns) == turns

    assert_receive {:companion_event,
                    %{"t" => "turn_error", "turn_id" => "turn-mac-1", "code" => "interrupted"}}

    assert_receive {:failed, "main", "mac-1", 3, _fields}
    assert :ok = Companion.build_turn_result(message).({:cancelled})
    refute_receive {:companion_event, %{"t" => "turn_error"}}, 100
  end

  # The stop waits for the queue's answer, and so do the socket that asked
  # and a reply that reaches Turns meanwhile. The queue is held only until the
  # stop is seen waiting: no test waits out a production call budget. Each of
  # the three calls is traced instead, and carries no timeout to run out.
  test "a cancel waits for a queue busy in its stop, and so does a reply behind it" do
    queue = start_supervised!({SlowQueueSink, self()}, id: :slow_queue)
    message = track(request_message(), queue)
    turns = GenServer.whereis(Turns)
    trace = call_trace()
    trace_calls(trace, turns)

    cancel = traced_task(trace, fn -> Turns.cancel(Turns, "main", "mac-1") end)
    assert_receive {:stop_waiting, "mac-1", ^queue}
    reply = traced_task(trace, fn -> Companion.build_text_reply(message).("partial") end)
    wait_until(fn -> mailbox_size(turns) >= 1 end)
    send(queue, :release)

    assert :ok = Task.await(cancel)
    assert :ok = Task.await(reply)
    assert call_timeout(cancel.pid, :cancel) == :infinity
    assert call_timeout(turns, :stop_turn) == :infinity
    assert call_timeout(reply.pid, :reply) == :infinity
  end

  test "a reply that is no queue turn, a slash command's answer, is written at once as a row" do
    reply = Companion.build_text_reply(request_message())
    assert :ok = reply.("Approved.")

    assert_receive {:client_output, "main", "mac-1", 3, "text:" <> _digest,
                    %{content: "Approved."}}

    assert_receive {:companion_event,
                    %{
                      "t" => "row",
                      "server_seq" => 42,
                      "role" => "assistant",
                      "text" => "Approved.",
                      "ts" => "2026-09-26T09:00:00Z"
                    } = row}

    refute Map.has_key?(row, "client_msg_id")
    refute_received {:companion_event, %{"t" => "text_done"}}
  end

  test "a scheduled job's delivery is a plain row, announced whether or not anyone listens" do
    handler = attach_message_telemetry()
    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Companion.send_message("main", "your 9am summary", [])

    assert_receive {:append, "main", %{role: "assistant", content: "your 9am summary"}}

    assert_receive {:companion_event,
                    %{"t" => "row", "server_seq" => 41, "text" => "your 9am summary"}}

    assert_receive {:telemetry, %{count: 1}, %{channel: :companion, direction: :outbound}}

    assert :ok = Companion.send_message("main", "again", proactive_key: "reminder-1")
    assert_receive {:proactive, "main", "reminder-1", _attrs}
    refute_receive {:companion_event, %{"t" => "row", "server_seq" => 43}}

    assert {:error, :unsupported_profile} = Companion.send_message("work", "x", [])
  end

  test "tool activity and approvals reach the profile, with no null fields", %{
    approvals: approvals
  } do
    message = request_message()
    activity = Companion.build_activity_callback(message)
    assert :ok = activity.({:tool_start, "shell"})

    assert_receive {:companion_event,
                    %{"t" => "tool_event", "tool" => "shell", "phase" => "start"}}

    assert :ok = Companion.send_approval(message, "Allow this? /confirm TOK", "TOK")
    assert_receive {:companion_event, %{"t" => "approval"} = approval}

    assert approval["approve_command"] == "/confirm TOK"
    assert approval["deny_command"] == "/deny TOK"
    assert approval["text"] == "Allow this?"
    refute Map.has_key?(approval, "detail")

    # FEAT-2: kept for a Mac client that connects after it went out.
    assert [%{"approval_id" => id}] = Approvals.pending(approvals, "main", :companion)
    assert Approvals.pending(approvals, "main", :mobile) == []
    assert id == approval["approval_id"]
  end

  test "a provider call is not a tool event" do
    message = request_message()
    activity = Companion.build_activity_callback(message)

    assert :ok = activity.(:provider_start)
    assert :ok = activity.(:provider_response)
    refute_receive {:companion_event, %{"t" => "tool_event"}}

    assert :ok = activity.({:tool_start, "shell"})

    assert_receive {:companion_event,
                    %{"t" => "tool_event", "tool" => "shell", "phase" => "start"}}
  end

  test "media does not travel on this socket" do
    assert {:error, :unsupported_media} =
             Companion.send_media("main", %{kind: :image, path: "/tmp/x.png"}, [])
  end

  # The hand-off is sent to Turns, not awaited: once Turns and then the queue
  # have answered, whatever the hand-off did has happened.
  defp handed_off(queue) do
    _turns = :sys.get_state(Turns)
    _queue = :sys.get_state(queue)
    :ok
  end

  # Hand the message to a queue through Turns, as the gateway does for every
  # companion message that becomes a turn.
  defp track(message, queue \\ nil) do
    queue = queue || start_supervised!({QueueSink, self()}, id: :queue_sink)
    assert :ok = Turns.handle_message(Map.from_struct(message), queue)
    assert_receive {:enqueued, "mac-1"}
    message
  end

  defp request_message do
    Message.new!(%{
      id: "mac-1",
      content: "hello",
      sender: "Companion owner",
      channel: "companion",
      chat_id: "main",
      reply_target: "main",
      metadata: %{client_msg_id: "mac-1", companion_attempt: 3, turn_id: "turn-mac-1"}
    })
  end

  defp attach_message_telemetry do
    handler_id = "companion-message-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :message],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  defp mailbox_size(pid) do
    {:message_queue_len, size} = Process.info(pid, :message_queue_len)
    size
  end

  # A trace session of this test's own on `GenServer.call/3`, local calls
  # included, so `call/2`'s default timeout shows too. No other tracer sees
  # it, and it ends with the test.
  defp call_trace do
    session = :trace.session_create(:companion_test_calls, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)
    1 = :trace.function(session, {GenServer, :call, 3}, true, [:local])
    session
  end

  defp trace_calls(session, pid), do: 1 = :trace.process(session, pid, true, [:call])

  # Runs `fun` in a task that starts only once its calls are traced.
  defp traced_task(session, fun) do
    task =
      Task.async(fn ->
        receive do
          :traced -> fun.()
        after
          5_000 -> :never_traced
        end
      end)

    trace_calls(session, task.pid)
    send(task.pid, :traced)
    task
  end

  # The timeout `pid`'s traced call carried, for the request tagged `tag`.
  defp call_timeout(pid, tag) do
    receive do
      {:trace, ^pid, :call, {GenServer, :call, [_server, request, timeout]}}
      when is_tuple(request) and elem(request, 0) == tag ->
        timeout
    after
      5_000 -> flunk("#{inspect(pid)} made no traced #{inspect(tag)} call")
    end
  end

  defp wait_until(fun, attempts \\ 150)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
