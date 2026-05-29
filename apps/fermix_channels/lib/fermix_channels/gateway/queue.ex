defmodule FermixChannels.Gateway.Queue do
  @moduledoc """
  Single-flight turn scheduler for the Main Agent.

  Owns conversation identity and turn-task lifecycle for inbound messages. Each
  conversation runs at most one active turn plus one pending replacement. If a
  newer same-conversation message arrives while work is in flight, the active
  task is canceled, the pending slot is replaced with the newest message, and
  only that newest message starts once the older task exits. Different
  conversations run independently.

  Conversation identity is `{channel, chat_id, thread_scope}` via
  `FermixCore.Agents.ConversationKey`.

  The dispatcher hands an authorized, normalized message here through the
  `handle_message/2` delivery seam (or `enqueue/2`). To start a turn the queue
  checks out a built turn-state snapshot from `FermixCore.Agents.MainAgent`
  (which owns the runtime-context cache) and runs the turn in a supervised task
  via `FermixCore.Agents.TurnRunner`. Reply delivery happens inside the turn via
  the message's `reply_fn` closure.

  Started :permanent by `FermixChannels.Application`.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixChannels.Gateway.Typing
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.TurnRunner

  @type status :: %{
          active_conversations: non_neg_integer(),
          pending_conversations: non_neg_integer(),
          active_requests: non_neg_integer(),
          pending_requests: non_neg_integer(),
          activity: :idle | :running
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Dispatcher delivery seam: enqueue an authorized agent message."
  @spec handle_message(map(), GenServer.server()) :: :ok
  def handle_message(msg, server \\ __MODULE__), do: enqueue(server, msg)

  @spec enqueue(GenServer.server(), map()) :: :ok
  def enqueue(server, msg) do
    msg = Map.put(msg, :__fermix_enqueued_at_us, System.monotonic_time(:microsecond))
    GenServer.cast(server, {:enqueue, msg})
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Whether a turn's reply may still be delivered: true only if it is the active
  request for its conversation and no newer message has superseded it. The turn
  task checks this before delivering, so a superseded turn's reply is rejected
  before delivery. (Cancellation also kills the task; this guards the
  post-`run` race.)
  """
  @spec deliverable?(GenServer.server(), ConversationKey.t(), pos_integer()) :: boolean()
  def deliverable?(server, conversation_key, request_id) do
    GenServer.call(server, {:deliverable?, conversation_key, request_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      main_agent: Keyword.get(opts, :main_agent, MainAgent),
      turn_runner: Keyword.get(opts, :turn_runner, TurnRunner),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      conversations: %{},
      task_refs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, msg}, state) do
    emit_enqueue_telemetry(msg, state)
    msg = Map.delete(msg, :__fermix_enqueued_at_us)
    conversation_key = ConversationKey.from(msg)

    Logger.info("Gateway queue received message from #{msg.channel}/#{msg.chat_id}")

    state =
      state
      |> enqueue_latest_message(conversation_key, msg)
      |> maybe_cancel_active_request(conversation_key)
      |> maybe_start_next_request(conversation_key)

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call({:deliverable?, conversation_key, request_id}, _from, state) do
    deliverable =
      case Map.get(state.conversations, conversation_key) do
        %{active: %{request_id: ^request_id}, pending: nil} -> true
        _conversation -> false
      end

    {:reply, deliverable, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _task_refs} ->
        {:noreply, state}

      {conversation_key, task_refs} ->
        state =
          state
          |> Map.put(:task_refs, task_refs)
          |> clear_active_request(conversation_key, ref, reason)
          |> maybe_start_next_request(conversation_key)

        {:noreply, state}
    end
  end

  # --- Queue internals ---

  defp empty_conversation_runtime do
    %{next_request_id: 0, active: nil, pending: nil}
  end

  defp enqueue_latest_message(state, conversation_key, msg) do
    conversation =
      state.conversations
      |> Map.get(conversation_key, empty_conversation_runtime())
      |> Map.update!(:next_request_id, &(&1 + 1))

    pending = %{request_id: conversation.next_request_id, message: msg}

    put_conversation_runtime(state, conversation_key, %{conversation | pending: pending})
  end

  defp maybe_cancel_active_request(state, conversation_key) do
    case get_in(state, [:conversations, conversation_key, :active]) do
      nil ->
        state

      %{pid: pid, request_id: request_id} ->
        Logger.info(
          "Canceling in-flight turn #{request_id} for #{format_conversation_key(conversation_key)}"
        )

        emit_request_event(:request_cancel, conversation_key, request_id, %{count: 1}, %{})

        case Task.Supervisor.terminate_child(state.task_supervisor, pid) do
          :ok -> state
          {:error, :not_found} -> state
        end
    end
  end

  defp maybe_start_next_request(state, conversation_key) do
    case Map.get(state.conversations, conversation_key, empty_conversation_runtime()) do
      %{active: nil, pending: pending_request} = conversation when not is_nil(pending_request) ->
        start_pending_request(state, conversation_key, conversation, pending_request)

      _conversation ->
        state
    end
  end

  defp start_pending_request(
         state,
         conversation_key,
         conversation,
         %{request_id: request_id, message: msg}
       ) do
    task =
      turn_task(state.main_agent, state.turn_runner, self(), conversation_key, request_id, msg)

    case Task.Supervisor.start_child(state.task_supervisor, task) do
      {:ok, pid} ->
        mark_request_started(state, conversation_key, conversation, request_id, pid)

      {:error, reason} ->
        Logger.error(
          "Failed to start turn #{request_id} for #{format_conversation_key(conversation_key)}: #{inspect(reason)}"
        )

        send_error_reply_async(msg, "Sorry, I encountered an error processing your message.")
        put_conversation_runtime(state, conversation_key, %{conversation | pending: nil})
    end
  end

  # The turn task: checkout the turn-state snapshot, type while the core turn
  # runs, deliver its returned reply (rejecting it if a newer message superseded
  # this turn), then finalize (memory review + auto-compaction). Checkout runs
  # HERE, in the task — not in the queue loop — so a slow runtime-context build
  # (cold start or a post-invalidation cache miss) never blocks other
  # conversations from enqueuing/canceling. Finalize runs after delivery so
  # compaction never delays the reply, and only on the success path.
  defp turn_task(main_agent, runner, queue, conversation_key, request_id, msg) do
    typing_fn = Map.get(msg, :typing_fn)

    typing_opts = [
      interval_ms: Map.get(msg, :typing_interval_ms),
      timeout_ms: Map.get(msg, :typing_timeout_ms)
    ]

    turn = %{
      main_agent: main_agent,
      runner: runner,
      queue: queue,
      conversation_key: conversation_key,
      request_id: request_id,
      deliver: Map.fetch!(msg, :reply_fn),
      msg: msg
    }

    fn -> Typing.with_indicator(typing_fn, typing_opts, fn -> checkout_and_run(turn) end) end
  end

  defp checkout_and_run(%{main_agent: main_agent, msg: msg} = turn) do
    case checkout(main_agent, msg) do
      {:ok, turn_state, cache_status} ->
        core_msg =
          msg
          |> Map.drop([:reply_fn, :typing_fn, :typing_interval_ms, :typing_timeout_ms])
          |> Map.put(:__runtime_context_cache_status, cache_status)

        run_and_deliver(Map.merge(turn, %{turn_state: turn_state, core_msg: core_msg}))

      {:error, reason} ->
        deliver_checkout_error(turn, reason)
    end
  end

  # Blocks only this task while a runtime-context cache miss builds; hits return
  # immediately. A dead/restarting MainAgent surfaces as
  # {:error, {:checkout_unavailable, _}} rather than crashing the task.
  defp checkout(main_agent, msg) do
    MainAgent.checkout_turn_state(main_agent, msg)
  catch
    :exit, reason -> {:error, {:checkout_unavailable, reason}}
  end

  defp run_and_deliver(%{runner: runner, core_msg: core_msg, turn_state: turn_state} = turn) do
    case runner.run(core_msg, turn_state, turn.deliver) do
      {:ok, response} ->
        maybe_deliver(turn, response)
        runner.finalize(core_msg, turn_state)

      {:error, reason} ->
        maybe_deliver(turn, runner.error_reply(reason))
    end
  end

  defp maybe_deliver(turn, text) do
    if deliverable?(turn.queue, turn.conversation_key, turn.request_id) do
      turn.deliver.({:text, text})
    else
      :ok
    end
  end

  defp deliver_checkout_error(turn, reason) do
    {text, agent_unavailable?} = checkout_error_reply(reason)

    Logger.error(
      "Turn #{turn.request_id} checkout failed for #{format_conversation_key(turn.conversation_key)}: #{inspect(reason)}"
    )

    if agent_unavailable? do
      :telemetry.execute(
        [:fermix, :gateway, :queue, :agent_unavailable],
        %{count: 1},
        %{channel: turn.msg.channel}
      )
    end

    maybe_deliver(turn, text)
  end

  defp checkout_error_reply({:checkout_unavailable, _reason}),
    do: {"I'm restarting — please send your message again in a moment.", true}

  defp checkout_error_reply(_reason),
    do: {"Sorry, I encountered an error processing your message.", false}

  defp mark_request_started(state, conversation_key, conversation, request_id, pid) do
    monitor_ref = Process.monitor(pid)

    Logger.info("Starting turn #{request_id} for #{format_conversation_key(conversation_key)}")

    emit_request_event(:request_start, conversation_key, request_id, %{count: 1}, %{})

    conversation = %{
      conversation
      | active: %{
          request_id: request_id,
          pid: pid,
          monitor_ref: monitor_ref,
          started_at_us: System.monotonic_time(:microsecond)
        },
        pending: nil
    }

    state
    |> put_conversation_runtime(conversation_key, conversation)
    |> update_in([:task_refs], &Map.put(&1, monitor_ref, conversation_key))
  end

  defp clear_active_request(state, conversation_key, monitor_ref, reason) do
    case Map.get(state.conversations, conversation_key) do
      %{active: %{monitor_ref: ^monitor_ref} = active} = conversation ->
        Logger.info(
          "Turn #{active.request_id} exited for #{format_conversation_key(conversation_key)} with reason #{inspect(reason)}"
        )

        emit_request_event(
          :request_complete,
          conversation_key,
          active.request_id,
          %{duration_us: max(System.monotonic_time(:microsecond) - active.started_at_us, 0)},
          %{reason: completion_reason(reason)}
        )

        put_conversation_runtime(state, conversation_key, %{conversation | active: nil})

      _conversation ->
        state
    end
  end

  defp completion_reason(:normal), do: :normal
  defp completion_reason(_other), do: :crashed

  defp put_conversation_runtime(state, conversation_key, %{active: nil, pending: nil}) do
    update_in(state.conversations, &Map.delete(&1, conversation_key))
  end

  defp put_conversation_runtime(state, conversation_key, conversation_runtime) do
    update_in(state.conversations, &Map.put(&1, conversation_key, conversation_runtime))
  end

  defp send_error_reply_async(msg, text) do
    spawn(fn -> msg.reply_fn.({:text, text}) end)
    :ok
  end

  defp format_conversation_key({channel, chat_id, :root}), do: "#{channel}/#{chat_id}"

  defp format_conversation_key({channel, chat_id, thread_scope}) do
    "#{channel}/#{chat_id}/#{inspect(thread_scope)}"
  end

  # --- Status + telemetry ---

  defp status_from_state(state) do
    counts = conversation_counts(state.conversations)
    Map.put(counts, :activity, request_activity(counts))
  end

  defp request_activity(%{active_requests: active_requests}) when active_requests > 0,
    do: :running

  defp request_activity(_counts), do: :idle

  defp conversation_counts(conversations) when is_map(conversations) do
    Enum.reduce(
      conversations,
      %{
        active_conversations: 0,
        pending_conversations: 0,
        active_requests: 0,
        pending_requests: 0
      },
      fn {_key, runtime}, counts ->
        active? = Map.get(runtime, :active) != nil
        pending? = Map.get(runtime, :pending) != nil

        counts
        |> increment_if(:active_conversations, active?)
        |> increment_if(:pending_conversations, pending?)
        |> increment_if(:active_requests, active?)
        |> increment_if(:pending_requests, pending?)
      end
    )
  end

  defp increment_if(counts, key, true), do: Map.update!(counts, key, &(&1 + 1))
  defp increment_if(counts, _key, false), do: counts

  defp emit_enqueue_telemetry(msg, state) do
    counts = conversation_counts(state.conversations)

    :telemetry.execute(
      [:fermix, :gateway, :queue, :enqueue],
      %{
        duration_us: mailbox_duration_us(Map.get(msg, :__fermix_enqueued_at_us)),
        depth: counts.active_requests + counts.pending_requests
      },
      %{channel: Map.get(msg, :channel)}
    )
  end

  defp mailbox_duration_us(enqueued_at) when is_integer(enqueued_at) do
    System.monotonic_time(:microsecond)
    |> Kernel.-(enqueued_at)
    |> max(0)
  end

  defp mailbox_duration_us(_missing_timestamp), do: 0

  defp emit_request_event(
         event,
         {channel, _chat_id, _scope} = conversation_key,
         request_id,
         measurements,
         extra
       ) do
    metadata =
      Map.merge(
        %{channel: channel, conversation_key: inspect(conversation_key), request_id: request_id},
        extra
      )

    :telemetry.execute([:fermix, :gateway, :queue, event], measurements, metadata)
  end
end
