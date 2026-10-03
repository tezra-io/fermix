defmodule FermixChannels.Voice.TypedTurnTest do
  @moduledoc """
  M56 §4.4: a message typed in the chat is judged against the Live call when
  its turn runs, not when it was typed. The real queue checks the turn out of a
  real `MainAgent`, which asks the registered `Voice.Bridge`, which reads Core's
  call registry; only the runner is a stand-in, reporting the snapshot it was
  handed and holding its turn until the test lets it end. This test process
  holds the call's claim in a Live session's stead.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.DeviceIdentity

  defmodule HeldRunner do
    def run(msg, turn_state, _deliver) do
      send(msg.metadata.test_pid, {:running, msg.content, turn_state.live_call, self()})

      receive do
        :finish -> {:ok, "done", 0}
      after
        5_000 -> {:ok, "done", 0}
      end
    end

    def commit(_msg, _turn_state, _response, _context_tokens), do: :ok
    def error_reply(reason), do: inspect(reason)
  end

  # A provider that answers every typed message with the sentinel, streaming
  # it as a provider streams, a piece at a time.
  defmodule SilentAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      stream = Keyword.get(opts, :stream_callback)

      if is_function(stream, 1),
        do: Enum.each(["[", "[SIL", "[SILENT]"], &stream.({:text_delta, &1}))

      {:ok,
       %{
         content: "[SILENT]",
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 10, completion_tokens: 1, total_tokens: 11},
         model: "mock-model"
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :unexpected_continue}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: true
  end

  # The companion timeline, standing in: it reports each row a reply becomes.
  # A typed turn with no request behind it writes a plain row.
  defmodule RowSink do
    def append(profile, attrs, _opts) do
      send(:typed_turn_test, {:row_written, attrs.content})

      {:ok,
       Map.merge(attrs, %{profile_id: profile, server_seq: 7, created_at: DateTime.utc_now()})}
    end
  end

  setup do
    start_supervised!({CallRegistry, name: CallRegistry})
    agent = :"typed_turn_main_agent_#{System.unique_integer([:positive])}"
    start_supervised!({MainAgent, name: agent})
    task_supervisor = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Queue,
         name: :"typed_turn_queue_#{System.unique_integer([:positive])}",
         main_agent: agent,
         turn_runner: HeldRunner,
         task_supervisor: task_supervisor}
      )

    %{queue: queue}
  end

  test "a message queued before the call starts and run during it is told of the call", ctx do
    :ok = Queue.handle_message(typed("first"), ctx.queue)
    assert_receive {:running, "first", nil, first}, 5_000

    :ok = Queue.handle_message(typed("queued before the call"), ctx.queue)
    holder = hold_call()
    send(first, :finish)

    assert_receive {:running, "queued before the call", %{started_at: _started_at} = call,
                    second},
                   5_000

    assert call.silence_allowed? == true
    send(second, :finish)
    send(holder, :release)
  end

  test "a message queued during the call and run after it ended is told of none", ctx do
    holder = hold_call()
    :ok = Queue.handle_message(typed("during"), ctx.queue)
    assert_receive {:running, "during", %{started_at: _started_at}, first}, 5_000

    :ok = Queue.handle_message(typed("queued during the call"), ctx.queue)
    end_call(holder)
    send(first, :finish)

    assert_receive {:running, "queued during the call", nil, second}, 5_000
    send(second, :finish)
  end

  # The whole path, every piece real but the provider: a message typed in the
  # chat during a call, answered with the sentinel, is committed to the chat's
  # history, shows no draft, writes no row and ends with turn_done.
  describe "a typed message the agent leaves unanswered" do
    setup do
      previous = Application.fetch_env(:fermix_channels, :companion_store)
      Application.put_env(:fermix_channels, :companion_store, RowSink)

      on_exit(fn ->
        case previous do
          {:ok, store} -> Application.put_env(:fermix_channels, :companion_store, store)
          :error -> Application.delete_env(:fermix_channels, :companion_store)
        end
      end)

      Process.register(self(), :typed_turn_test)
      start_supervised!(Turns)
      chat_key = Companion.chat_conversation_key()
      :ok = ConversationStore.clear(chat_key)
      on_exit(fn -> ConversationStore.clear(chat_key) end)

      agent = :"silent_turn_main_agent_#{System.unique_integer([:positive])}"
      start_supervised!({MainAgent, name: agent, adapter: SilentAdapter}, id: agent)
      task_supervisor = start_supervised!({Task.Supervisor, []}, id: :silent_turn_tasks)

      queue =
        start_supervised!(
          {Queue,
           name: :"silent_turn_queue_#{System.unique_integer([:positive])}",
           main_agent: agent,
           task_supervisor: task_supervisor},
          id: :silent_turn_queue
        )

      # This test process is the one companion client attached, at version 2.
      {:ok, _owner} = Registry.register(Companion.registry(), "main", 2)
      %{chat_key: chat_key, silent_queue: queue}
    end

    test "is committed, shows no draft, writes no row and ends with turn_done", ctx do
      holder = hold_call()
      {:ok, [message]} = Companion.parse_event(typed_event("e2e-silent", "https://x.test/lease"))

      assert :ok =
               Gateway.ingest([message],
                 channel: Companion,
                 agent: Turns,
                 agent_server: ctx.silent_queue,
                 ingress_context: %{transport: :companion}
               )

      assert_receive {:companion_event, %{"t" => "turn_done", "turn_id" => "turn-e2e-silent"}},
                     5_000

      assert [%{role: "user"}, %{role: "assistant", content: "[SILENT]"}] =
               ConversationStore.get_history(ctx.chat_key)

      refute_received {:companion_stream, _turn, {:snapshot, _text}}
      refute_received {:companion_event, %{"t" => "text_done"}}
      refute_received {:row_written, _text}
      send(holder, :release)
    end

    test "outside a call the sentinel is ordinary text, shown as the turn's answer", ctx do
      {:ok, [message]} = Companion.parse_event(typed_event("e2e-plain", "hello"))

      assert :ok =
               Gateway.ingest([message],
                 channel: Companion,
                 agent: Turns,
                 agent_server: ctx.silent_queue,
                 ingress_context: %{transport: :companion}
               )

      assert_receive {:companion_event, %{"t" => "text_done", "text" => "[SILENT]"}}, 5_000
      assert_received {:row_written, "[SILENT]"}
      refute_received {:companion_event, %{"t" => "turn_done"}}
    end
  end

  defp typed_event(client_msg_id, text) do
    %{
      type: "msg",
      payload: %{
        "client_msg_id" => client_msg_id,
        "profile_id" => "main",
        "text" => text,
        "attach_ids" => []
      }
    }
  end

  defp typed(content) do
    {channel, chat_id, :root} = Companion.chat_conversation_key()

    %{
      id: "typed-#{System.unique_integer([:positive])}",
      content: content,
      sender: "Companion owner",
      channel: channel,
      chat_id: chat_id,
      source_trust: :operator,
      metadata: %{test_pid: self()},
      reply_fn: fn _part -> :ok end
    }
  end

  # A Live session's stand-in: claims a call in the chat until released.
  defp hold_call do
    test_pid = self()

    holder =
      spawn(fn ->
        call = %{
          call_uuid: DeviceIdentity.generate_uuid(),
          conversation: "chat",
          started_at: DateTime.utc_now()
        }

        :ok = CallRegistry.claim(CallRegistry, call)
        send(test_pid, :claimed)

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end
      end)

    assert_receive :claimed
    holder
  end

  # The registry skips an owner that has exited, so the call is over once its
  # holder is down.
  defp end_call(holder) do
    ref = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}
    assert CallRegistry.active(CallRegistry) == :none
  end
end
