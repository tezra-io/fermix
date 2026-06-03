defmodule FermixChannels.Gateway.Queue do
  @moduledoc """
  FIFO turn scheduler for the Main Agent.

  Owns conversation identity and turn-task lifecycle for inbound messages. Each
  conversation runs at most one active turn plus a FIFO pending queue. Newer
  same-conversation messages wait behind the active turn instead of canceling
  it. Different conversations run independently.

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
  Emergency stop: terminate every active turn and clear every pending FIFO
  queue across all conversations. Returns `%{active_stopped, pending_cleared}`.

  Stale-delivery suppression is the active turn's identity (its task pid): a
  stopped turn's pid is no longer the conversation's active pid, so its
  freshness check (run before delivering/committing) fails and it neither
  delivers a reply nor commits. This is the single freshness authority a future
  superseding turn would also invalidate — no separate "stopped" flag.
  """
  @spec stop_all(GenServer.server()) ::
          %{active_stopped: non_neg_integer(), pending_cleared: non_neg_integer()}
  def stop_all(server \\ __MODULE__) do
    GenServer.call(server, :stop_all)
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
      |> enqueue_message(conversation_key, msg)
      |> maybe_start_next_request(conversation_key)

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call(:stop_all, _from, state) do
    {state, counts} = stop_all_conversations(state)
    {:reply, counts, state}
  end

  # Freshness authority: a turn is fresh iff its task pid is still the active
  # pid for its conversation. After `stop_all` (or a future superseding turn)
  # the conversation is gone or holds a different pid, so the check fails.
  def handle_call({:fresh?, conversation_key, pid}, _from, state) do
    fresh? =
      case Map.get(state.conversations, conversation_key) do
        %{active: %{pid: ^pid}} -> true
        _conversation -> false
      end

    {:reply, fresh?, state}
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
    %{next_request_id: 0, active: nil, pending: :queue.new()}
  end

  defp enqueue_message(state, conversation_key, msg) do
    conversation =
      state.conversations
      |> Map.get(conversation_key, empty_conversation_runtime())
      |> Map.update!(:next_request_id, &(&1 + 1))

    pending_request = %{request_id: conversation.next_request_id, message: msg}
    pending = :queue.in(pending_request, conversation.pending)

    put_conversation_runtime(state, conversation_key, %{conversation | pending: pending})
  end

  defp maybe_start_next_request(state, conversation_key) do
    case Map.get(state.conversations, conversation_key, empty_conversation_runtime()) do
      %{active: nil, pending: pending} = conversation ->
        start_next_pending_request(state, conversation_key, conversation, pending)

      _conversation ->
        state
    end
  end

  defp start_next_pending_request(state, conversation_key, conversation, pending) do
    case :queue.out(pending) do
      {{:value, pending_request}, rest} ->
        start_pending_request(
          state,
          conversation_key,
          %{conversation | pending: rest},
          pending_request
        )

      {:empty, _pending} ->
        put_conversation_runtime(state, conversation_key, conversation)
    end
  end

  defp start_pending_request(
         state,
         conversation_key,
         conversation,
         %{request_id: request_id, message: msg}
       ) do
    fun =
      turn_task(
        self(),
        state.main_agent,
        state.turn_runner,
        conversation_key,
        request_id,
        msg
      )

    case Task.Supervisor.start_child(state.task_supervisor, fun) do
      {:ok, pid} ->
        # Monitor the task BEFORE releasing it (the `{self(), :run}` signal),
        # so a near-instant turn can never exit before we monitor it — which
        # would deliver a spurious `{:DOWN, _, _, _, :noproc}` and mislabel an
        # ordinary turn as crashed. See `await_run_signal/1`.
        state = mark_request_started(state, conversation_key, conversation, request_id, pid)
        send(pid, {self(), :run})
        state

      {:error, reason} ->
        Logger.error(
          "Failed to start turn #{request_id} for #{format_conversation_key(conversation_key)}: #{inspect(reason)}"
        )

        send_error_reply_async(msg, "Sorry, I encountered an error processing your message.")

        state
        |> put_conversation_runtime(conversation_key, conversation)
        |> maybe_start_next_request(conversation_key)
    end
  end

  # The turn task: checkout the turn-state snapshot, type while the core turn
  # runs, then deliver its reply and commit the assistant history. Checkout runs
  # HERE, in the task (not the queue loop), so a slow runtime-context build never
  # blocks other conversations.
  defp turn_task(owner, main_agent, runner, conversation_key, request_id, msg) do
    typing_fn = Map.get(msg, :typing_fn)

    typing_opts = [
      interval_ms: Map.get(msg, :typing_interval_ms),
      timeout_ms: Map.get(msg, :typing_timeout_ms)
    ]

    turn = %{
      owner: owner,
      main_agent: main_agent,
      runner: runner,
      conversation_key: conversation_key,
      request_id: request_id,
      deliver: Map.fetch!(msg, :reply_fn),
      msg: msg
    }

    fn ->
      await_run_signal(owner)
      Typing.with_indicator(typing_fn, typing_opts, fn -> checkout_and_run(turn) end)
    end
  end

  # Block until the queue (owner) has registered its monitor and released us
  # with `{owner, :run}`. Monitoring the owner makes the handshake total: if it
  # dies before releasing us, the `:DOWN` arrives instead and we exit cleanly —
  # so the signal can never be lost and the task can never leak. This is the
  # same race-free pattern `Task.async/2` uses, with no timeout and no window
  # in which an instant turn could finish unmonitored.
  defp await_run_signal(owner) do
    owner_ref = Process.monitor(owner)

    receive do
      {^owner, :run} -> Process.demonitor(owner_ref, [:flush])
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> exit(:normal)
    end
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
      {:ok, response, context_tokens} ->
        # A turn stopped by `/stop` mid-run must neither deliver nor commit.
        if fresh?(turn) do
          turn.deliver.({:text, response})

          core_msg
          |> runner.commit(turn_state, response, context_tokens)
          |> maybe_notify_compacted(turn.deliver)
        else
          :stopped
        end

      {:error, reason} ->
        if fresh?(turn), do: turn.deliver.({:text, runner.error_reply(reason)}), else: :stopped
    end
  end

  # Is this turn still the conversation's active turn? Asked once, before final
  # delivery/commit. A dead queue (or a `/stop` that cleared this turn) means
  # not fresh — suppress.
  defp fresh?(%{owner: owner, conversation_key: conversation_key}) do
    GenServer.call(owner, {:fresh?, conversation_key, self()})
  catch
    :exit, _reason -> false
  end

  # `commit/4` returns `:compacted` when it summarized the history; surface a
  # one-line notice so the user knows older context was trimmed. Delivery is the
  # gateway's job, so the notice is sent here rather than from core.
  defp maybe_notify_compacted(:compacted, deliver) when is_function(deliver, 1) do
    deliver.(
      {:text,
       "🗜️ Trimmed older conversation history to stay within the context window — " <>
         "long-term memory is kept."}
    )

    :ok
  end

  defp maybe_notify_compacted(_result, _deliver), do: :ok

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

    turn.deliver.({:text, text})
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
        }
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

  defp put_conversation_runtime(
         state,
         conversation_key,
         %{active: nil, pending: pending} = conversation
       ) do
    if :queue.is_empty(pending) do
      update_in(state.conversations, &Map.delete(&1, conversation_key))
    else
      update_in(state.conversations, &Map.put(&1, conversation_key, conversation))
    end
  end

  defp put_conversation_runtime(state, conversation_key, conversation_runtime) do
    update_in(state.conversations, &Map.put(&1, conversation_key, conversation_runtime))
  end

  defp send_error_reply_async(msg, text) do
    spawn(fn -> msg.reply_fn.({:text, text}) end)
    :ok
  end

  # Terminate every active turn task and drop all conversation runtime. Pending
  # DOWNs from the killed tasks become no-ops (task_refs cleared); a stopped
  # turn's freshness check fails because its conversation no longer holds its
  # pid, so it cannot deliver or commit after this returns.
  #
  # Subagent workers parented to a killed coordinator are reaped via AgentServer's
  # parent-down monitor — prompt and eventual, but NOT synchronous: this returns
  # once the coordinator tasks are dead, not once every child AgentServer has
  # processed its parent :DOWN. A strict "all spawned workers gone before the ack"
  # guarantee (a synchronous AgentSupervisor.terminate_for/1 sweep) is deferred to
  # the /ultra phase (§17.5), where fan-out makes it worth the plumbing.
  defp stop_all_conversations(state) do
    counts =
      Enum.reduce(state.conversations, %{active_stopped: 0, pending_cleared: 0}, fn
        {_key, runtime}, counts ->
          terminate_active(state.task_supervisor, runtime)
          tally_stopped(runtime, counts)
      end)

    {%{state | conversations: %{}, task_refs: %{}}, counts}
  end

  defp terminate_active(task_supervisor, %{active: %{pid: pid}}) when is_pid(pid) do
    Task.Supervisor.terminate_child(task_supervisor, pid)
  end

  defp terminate_active(_task_supervisor, _runtime), do: :ok

  defp tally_stopped(runtime, counts) do
    pending_count = :queue.len(Map.get(runtime, :pending, :queue.new()))

    counts
    |> increment_if(:active_stopped, Map.get(runtime, :active) != nil)
    |> Map.update!(:pending_cleared, &(&1 + pending_count))
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
        pending = Map.get(runtime, :pending, :queue.new())
        pending_count = :queue.len(pending)

        counts
        |> increment_if(:active_conversations, active?)
        |> increment_if(:pending_conversations, pending_count > 0)
        |> increment_if(:active_requests, active?)
        |> Map.update!(:pending_requests, &(&1 + pending_count))
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
