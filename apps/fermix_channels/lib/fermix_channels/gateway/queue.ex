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

  Optional per-message closures the gateway may attach, all absent on channels
  that do not want them: `stream_spec` (a `DraftStream.Spec` for the draft/block
  tiers, or `%{mode: :raw, callback: fun}` for a channel that takes the loop's
  stream events verbatim), `activity_callback` (tool start/finish events), and
  `turn_result_fn` (invoked exactly once per turn with `{:completed}`,
  `{:failed, raw_reason}` or `{:cancelled}`).

  Started :permanent by `FermixChannels.Application`.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.DraftStream
  alias FermixChannels.Gateway.Typing
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Browser
  alias FermixCore.Memory.ConversationStore

  # Appended (as an assistant turn) to a conversation whose active turn was
  # stopped mid-run, closing the orphaned user message so the next turn keeps it
  # in history but does not replay and answer it.
  @stopped_turn_marker "(The previous request was stopped before I finished it. " <>
                         "It is kept here for context only — I should not act on it now " <>
                         "unless asked again.)"

  # Delivered when a successful turn returns blank content (an empty model
  # completion). The empty response is never committed, so it cannot poison
  # replayed history; the user gets an honest prompt to retry.
  @empty_completion_reply "I didn't get a response — please try again."

  # Closes a turn that returned no final text because a channel side-effect WAS
  # the reply (an emoji reaction ack, or an attachment). The user message is
  # persisted before the loop, so an empty turn must commit *something* or leave
  # a dangling user turn the next turn would replay. These compact assistant
  # markers close it (never "" — ConversationStore drops blank turns as history
  # poison) and, on replay, tell the model it already answered
  # (docs/design/EMOJI_REACTION_ACKS.md §7). §17 open question: whether to embed
  # the specific emoji (`(reacted 🙏)`) — kept generic for now.
  @reacted_marker "(Reacted to the previous message.)"
  @attachment_marker "(Sent an attachment in reply.)"
  @reacted_and_attachment_marker "(Reacted and sent an attachment in reply.)"

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

  @doc """
  Stop ONE conversation: terminate its active turn, hand that turn's channel a
  `{:cancelled}` outcome, append the stopped-turn marker, and clear its pending
  FIFO. Every other conversation keeps running.

  The per-key half of `stop_all/1` (same helpers, same suppression rule — the
  killed turn's pid is no longer the conversation's active pid, so its freshness
  check fails and it neither delivers nor commits). Built for the ACP surface's
  `session/cancel` (MILESTONE_29_ACP_AGENT_SURFACE.md §8.5).

  `{:ok, :not_found}` when the conversation has nothing active or pending.
  """
  @spec stop_conversation(ConversationKey.t(), GenServer.server()) ::
          {:ok, %{active_stopped: 0 | 1, pending_cleared: non_neg_integer()}} | {:ok, :not_found}
  def stop_conversation(conversation_key, server \\ __MODULE__)
      when is_tuple(conversation_key) do
    GenServer.call(server, {:stop_conversation, conversation_key})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      main_agent: Keyword.get(opts, :main_agent, MainAgent),
      turn_runner: Keyword.get(opts, :turn_runner, TurnRunner),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore),
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

  def handle_call({:stop_conversation, conversation_key}, _from, state) do
    {state, result} = stop_one_conversation(state, conversation_key)
    {:reply, result, state}
  end

  # The single claim point that makes `turn_result_fn` fire exactly once: the
  # queue process serializes a turn task's terminal claim against a concurrent
  # stop (which takes the closure with the whole conversation) and against the
  # task's own abnormal `:DOWN`. The first claimant gets the closure; every
  # later one gets nil and invokes nothing.
  def handle_call({:claim_turn_result, conversation_key, pid}, _from, state) do
    case Map.get(state.conversations, conversation_key) do
      %{active: %{pid: ^pid, turn_result_fn: fun}} when is_function(fun, 1) ->
        {:reply, fun, clear_turn_result_fn(state, conversation_key, pid)}

      _conversation ->
        {:reply, nil, state}
    end
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

  def handle_call({:final_reply_delivered, conversation_key, pid}, _from, state) do
    state =
      update_active_request(state, conversation_key, pid, fn active ->
        Map.put(active, :final_reply_delivered?, true)
      end)

    {:reply, :ok, state}
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
        msg,
        state.conversation_store
      )

    case Task.Supervisor.start_child(state.task_supervisor, fun) do
      {:ok, pid} ->
        # Monitor the task BEFORE releasing it (the `{self(), :run}` signal),
        # so a near-instant turn can never exit before we monitor it — which
        # would deliver a spurious `{:DOWN, _, _, _, :noproc}` and mislabel an
        # ordinary turn as crashed. See `await_run_signal/1`.
        state = mark_request_started(state, conversation_key, conversation, request_id, pid, msg)
        send(pid, {self(), :run})
        state

      {:error, reason} ->
        Logger.error(
          "Failed to start turn #{request_id} for #{format_conversation_key(conversation_key)}: #{inspect(reason)}"
        )

        maybe_send_error_reply_async(
          msg,
          "Sorry, I encountered an error processing your message."
        )

        # No task ever existed to claim it, so this is the only outcome site for
        # this message — a turn-result consumer must never be left waiting.
        invoke_turn_result_async(Map.get(msg, :turn_result_fn), {:failed, reason})

        state
        |> put_conversation_runtime(conversation_key, conversation)
        |> maybe_start_next_request(conversation_key)
    end
  end

  # The turn task: checkout the turn-state snapshot, type while the core turn
  # runs, then deliver its reply and commit the assistant history. Checkout runs
  # HERE, in the task (not the queue loop), so a slow runtime-context build never
  # blocks other conversations.
  defp turn_task(owner, main_agent, runner, conversation_key, request_id, msg, conversation_store) do
    typing_fn = Map.get(msg, :typing_fn)

    typing_opts = [
      interval_ms: Map.get(msg, :typing_interval_ms),
      timeout_ms: Map.get(msg, :typing_timeout_ms)
    ]

    # Per-turn side-effect ledger (EMOJI_REACTION_ACKS §7). Created here and
    # closed over in the wrapped deliver closure; both the closure (called deep
    # inside `run_turn` when a tool delivers) and `run_and_deliver` run in THIS
    # one task process, so the tally is visible when the empty branch reads it.
    side_effect_ledger = :counters.new(2, [])

    turn = %{
      owner: owner,
      main_agent: main_agent,
      runner: runner,
      conversation_key: conversation_key,
      request_id: request_id,
      deliver: wrap_deliver(Map.fetch!(msg, :reply_fn), side_effect_ledger),
      activity_callback: Map.get(msg, :activity_callback),
      side_effect_ledger: side_effect_ledger,
      conversation_store: conversation_store,
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
          |> Map.drop([
            :reply_fn,
            :typing_fn,
            :typing_interval_ms,
            :typing_timeout_ms,
            :stream_spec,
            :activity_callback,
            :turn_result_fn,
            :terminal_error_owner?
          ])
          |> Map.put(:__runtime_context_cache_status, cache_status)

        turn
        |> Map.merge(%{turn_state: turn_state, core_msg: core_msg})
        |> start_draft_stream()
        |> run_and_deliver()

      {:error, reason} ->
        deliver_checkout_error(turn, reason)
        # A turn that never reached the runner still ended — and failed. Its
        # channel gets the raw checkout reason, same as any other error path.
        finish_turn(turn, {:failed, reason})
    end
  end

  # Spawn the draft engine (linked to this turn task) when the gateway resolved
  # streaming eligibility and attached a spec; otherwise the turn runs today's
  # exact non-streaming path (docs/design/CHANNEL_STREAMING.md §5.6).
  defp start_draft_stream(%{msg: msg} = turn) do
    case Map.get(msg, :stream_spec) do
      %DraftStream.Spec{} = spec ->
        pid = DraftStream.start_link(spec)
        callback = fn event -> DraftStream.push(pid, event) end
        Map.merge(turn, %{draft_pid: pid, stream_callback: callback})

      # The `:raw` tier (MILESTONE_29_ACP_AGENT_SURFACE.md §8.4): the adapter's
      # own callback takes the loop's stream events verbatim — no draft engine,
      # so no throttled edits, no reasoning side-blocks, and nothing the
      # adapter did not ask for. `deliver_final`/`discard_draft` already no-op
      # on a nil draft pid, so the rest of the turn path is unchanged.
      %{mode: :raw, callback: callback} = spec
      when not is_struct(spec) and is_function(callback, 1) ->
        Map.merge(turn, %{draft_pid: nil, stream_callback: callback})

      nil ->
        Map.merge(turn, %{draft_pid: nil, stream_callback: nil})
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
    outcome =
      case run_turn(
             runner,
             core_msg,
             turn_state,
             turn.deliver,
             turn.stream_callback,
             turn.activity_callback
           ) do
        {:ok, response, context_tokens} -> deliver_response(turn, response, context_tokens)
        {:error, reason} -> deliver_turn_error(turn, reason)
      end

    reap_one_shot_browser(turn)
    finish_turn(turn, outcome)
  end

  defp deliver_response(
         %{runner: runner, core_msg: core_msg, turn_state: turn_state} = turn,
         response,
         context_tokens
       ) do
    cond do
      # A turn stopped by `/stop` mid-run must neither deliver nor commit.
      not fresh?(turn) ->
        discard_draft(turn)
        :stopped

      # An empty final completion. Two cases the side-effect ledger tells
      # apart (EMOJI_REACTION_ACKS §7): if the turn already delivered a
      # channel side-effect (a reaction ack, or an attachment), THAT was the
      # reply — suppress the canned retry and close the turn with a compact
      # marker. Otherwise the provider genuinely returned nothing — surface
      # it honestly and let the user retry. Neither commits `response`.
      # Either way the turn ran to completion: a delivered canned outcome is
      # still `{:completed}` for the channel's turn-result callback.
      String.trim(response) == "" ->
        discard_draft(turn)
        handle_empty_completion(turn)
        {:completed}

      true ->
        deliver_final(turn, response)
        mark_final_reply_delivered(turn)

        core_msg
        |> runner.commit(turn_state, response, context_tokens)
        |> maybe_notify_compacted(turn.deliver)

        {:completed}
    end
  end

  # The channel still gets today's `error_reply/1` text; the turn-result callback
  # gets the RAW reason, which is the only form an adapter can classify (an ACP
  # session maps provider-auth failures to a re-authenticate error, M29 §4).
  #
  # A failed turn commits no assistant message, so the user message the runner
  # persisted before the loop would be left dangling. Close it with the same
  # marker (and the same guarded path) a stop uses: a legitimate retry — durable,
  # or a client re-running the prompt — must not reach a model with no record of
  # what the failed turn already did, or it repeats it.
  defp deliver_turn_error(%{runner: runner} = turn, reason) do
    if fresh?(turn) do
      if not terminal_error_owner?(turn) do
        discard_draft(turn)
        turn.deliver.({:text, runner.error_reply(reason)})
      end

      append_marker(turn, @stopped_turn_marker)
      {:failed, reason}
    else
      :stopped
    end
  end

  # The turn's own terminal invocation of `turn_result_fn`, claimed from the
  # queue so it can never race a concurrent stop into a second invocation.
  # `:stopped` means a stop already owns this turn's outcome and fires
  # `{:cancelled}` itself — this task claims nothing.
  defp finish_turn(_turn, :stopped), do: :stopped

  defp finish_turn(turn, outcome) do
    turn
    |> claim_turn_result()
    |> invoke_turn_result(outcome)

    outcome
  end

  defp claim_turn_result(%{owner: owner, conversation_key: conversation_key}) do
    GenServer.call(owner, {:claim_turn_result, conversation_key, self()})
  catch
    :exit, _reason -> nil
  end

  # A one-shot (loopback) conversation — CLI `ask`, daemon — will not send a
  # follow-up, so tear its managed browser down now instead of pinning a Chrome
  # window for the full idle TTL. Remote interactive channels keep their browser
  # warm for the next message (the ProfileServer re-arms its idle timer per
  # request). Gated on `fresh?`: a superseded/`/stop`ped turn is NOT reaped, so
  # the successor turn that now owns the conversation never loses its browser
  # mid-run. Owner scope is per-conversation; this runs off the reply path (the
  # reply was already delivered) and only casts, so it adds no reply latency.
  defp reap_one_shot_browser(%{core_msg: %{channel: channel} = msg} = turn)
       when is_binary(channel) do
    if fresh?(turn) and ChannelRegistry.local?(channel) do
      Browser.reap_conversation(ConversationKey.from(msg))
    end

    :ok
  end

  defp reap_one_shot_browser(_turn), do: :ok

  # Streaming turns thread the engine callback via run/4 and tool-activity
  # surfaces add run/5; everything else keeps the 3-arity call so non-streaming
  # surfaces (and runner stubs) are untouched.
  defp run_turn(runner, core_msg, turn_state, deliver, nil, nil),
    do: runner.run(core_msg, turn_state, deliver)

  defp run_turn(runner, core_msg, turn_state, deliver, stream_callback, nil)
       when is_function(stream_callback, 1),
       do: runner.run(core_msg, turn_state, deliver, stream_callback)

  defp run_turn(runner, core_msg, turn_state, deliver, stream_callback, activity_callback)
       when is_function(activity_callback, 1),
       do: runner.run(core_msg, turn_state, deliver, stream_callback, activity_callback)

  # Final delivery for a streamed turn: seal the draft with the authoritative
  # response. `:no_draft` (no deltas ever arrived) and seal failure both fall
  # through to one fresh normal send — the user always gets the full answer.
  defp deliver_final(%{draft_pid: nil} = turn, response) do
    turn.deliver.({:text, response})
  end

  defp deliver_final(%{draft_pid: pid} = turn, response) when is_pid(pid) do
    case DraftStream.seal(pid, response) do
      {:ok, :no_draft} ->
        turn.deliver.({:text, response})

      {:ok, nil} ->
        :ok

      {:ok, overflow} when is_binary(overflow) ->
        turn.deliver.({:text, overflow})

      {:error, reason} ->
        Logger.warning("Draft seal failed; delivering fresh reply: #{inspect(reason)}")
        turn.deliver.({:text, response})
    end
  end

  defp discard_draft(%{draft_pid: nil}), do: :ok

  defp discard_draft(%{draft_pid: pid}) when is_pid(pid) do
    case DraftStream.discard(pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Draft discard failed: #{inspect(reason)}")
        :ok
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

  defp mark_final_reply_delivered(%{owner: owner, conversation_key: conversation_key}) do
    GenServer.call(owner, {:final_reply_delivered, conversation_key, self()})
  catch
    :exit, _reason -> :ok
  end

  # Wrap the raw channel reply closure so each SUCCESSFULLY-delivered mid-turn
  # non-text side-effect (media, reaction) is tallied in the per-turn ledger.
  # Records only on `:ok` — a channel-rejected side-effect must not suppress the
  # honest empty-completion retry. Text deliveries (terminal reply, canned retry,
  # compaction notice) are never side-effects, so they never record.
  defp wrap_deliver(reply_fn, ledger) when is_function(reply_fn, 1) do
    fn part ->
      result = reply_fn.(part)
      if result == :ok, do: record_side_effect(ledger, part)
      result
    end
  end

  defp record_side_effect(ledger, {:react, _emoji}), do: :counters.add(ledger, 1, 1)
  defp record_side_effect(ledger, {:media, _part}), do: :counters.add(ledger, 2, 1)
  defp record_side_effect(_ledger, _part), do: :ok

  # Empty final text: a delivered side-effect WAS the reply → suppress the canned
  # retry and close the turn with a compact marker (EMOJI_REACTION_ACKS §7).
  # Nothing delivered → the provider returned blank; keep today's honest retry.
  defp handle_empty_completion(turn) do
    case side_effect_marker(turn) do
      nil ->
        emit_empty_completion_telemetry(turn)
        turn.deliver.({:text, @empty_completion_reply})

      marker ->
        append_marker(turn, marker)
    end
  end

  defp side_effect_marker(%{side_effect_ledger: ledger}) do
    marker_for(:counters.get(ledger, 1) > 0, :counters.get(ledger, 2) > 0)
  end

  defp marker_for(false, false), do: nil
  defp marker_for(true, false), do: @reacted_marker
  defp marker_for(false, true), do: @attachment_marker
  defp marker_for(true, true), do: @reacted_and_attachment_marker

  # Close the orphaned user turn with the assistant marker, straight from the turn
  # task (the store ref is threaded in), so the Queue GenServer is never blocked on
  # a store call. Reuses the guarded stopped-marker path (appends only when the last
  # stored message is the user turn) — lighter than a full `runner.commit`, so an
  # emoji ack triggers no memory review or auto-compaction. Best-effort: a down
  # store must not crash the turn task's reply path.
  defp append_marker(%{conversation_store: store, conversation_key: conversation_key}, marker) do
    ConversationStore.append_stopped_marker(conversation_key, marker, server: store)
  catch
    :exit, _reason -> :skipped
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

  # The log line and the `agent_unavailable` event are operator diagnostics and
  # fire for every channel. Only the canned user-facing text is suppressed for a
  # channel that owns terminal error rendering (it gets the raw reason through
  # its turn-result callback instead).
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

    deliver_checkout_text(turn, text)
  end

  defp deliver_checkout_text(%{msg: %{terminal_error_owner?: true}}, _text), do: :ok
  defp deliver_checkout_text(turn, text), do: turn.deliver.({:text, text})

  defp checkout_error_reply({:checkout_unavailable, _reason}),
    do: {"I'm restarting — please send your message again in a moment.", true}

  defp checkout_error_reply(_reason),
    do: {"Sorry, I encountered an error processing your message.", false}

  defp mark_request_started(state, conversation_key, conversation, request_id, pid, msg) do
    monitor_ref = Process.monitor(pid)

    Logger.info("Starting turn #{request_id} for #{format_conversation_key(conversation_key)}")

    emit_request_event(:request_start, conversation_key, request_id, %{count: 1}, %{})

    conversation = %{
      conversation
      | active: %{
          request_id: request_id,
          pid: pid,
          monitor_ref: monitor_ref,
          started_at_us: System.monotonic_time(:microsecond),
          final_reply_delivered?: false,
          # The channel's optional per-turn outcome callback, held HERE rather
          # than in the task so the queue is the one place that decides who
          # invokes it — see the claim handler.
          turn_result_fn: Map.get(msg, :turn_result_fn),
          # Kept so a crashed turn (which dies before its own reply_fn runs) can
          # still deliver the generic error reply from `clear_active_request`.
          message: msg
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

        maybe_reply_on_crash(active, reason)
        maybe_fail_turn_result(active, reason)
        put_conversation_runtime(state, conversation_key, %{conversation | active: nil})

      _conversation ->
        state
    end
  end

  # A crashed turn can die before its own `reply_fn` runs, so the sender would
  # otherwise get silence. If the final reply was already delivered, do not send
  # a second generic error for a later commit/cleanup crash.
  defp maybe_reply_on_crash(active, reason) do
    if completion_reason(reason) == :crashed and
         not Map.get(active, :final_reply_delivered?, false) do
      maybe_send_error_reply_async(
        active.message,
        "Sorry, I encountered an error processing your message."
      )
    end

    :ok
  end

  # A turn that died before reaching its own terminal claim (a raise, a
  # shutdown) still owes its channel an outcome. Nothing can double-fire: a task
  # that already claimed the closure left `turn_result_fn` nil, and clearing the
  # active slot drops it for good.
  defp maybe_fail_turn_result(active, reason) do
    case completion_reason(reason) do
      :crashed ->
        invoke_turn_result_async(Map.get(active, :turn_result_fn), {:failed, {:crashed, reason}})

      :normal ->
        :ok
    end
  end

  defp completion_reason(:normal), do: :normal
  defp completion_reason(_other), do: :crashed

  # Crash-isolated, nil-safe: a raising channel callback must take down neither
  # the turn task nor the queue (same posture as the loop's stream/activity
  # callbacks).
  defp invoke_turn_result(nil, _outcome), do: :ok

  defp invoke_turn_result(fun, outcome) when is_function(fun, 1) do
    fun.(outcome)
    :ok
  rescue
    error ->
      Logger.warning("Turn result callback raised: #{Exception.message(error)}")
      :ok
  end

  # The queue's own invocations (stop, crashed DOWN) run off-process, so a slow
  # channel closure cannot stall the scheduler for every other conversation —
  # the same reason `send_error_reply_async/2` spawns.
  defp invoke_turn_result_async(nil, _outcome), do: :ok

  defp invoke_turn_result_async(fun, outcome) when is_function(fun, 1) do
    spawn(fn -> invoke_turn_result(fun, outcome) end)
    :ok
  end

  defp update_active_request(state, conversation_key, pid, fun) do
    case Map.get(state.conversations, conversation_key) do
      %{active: %{pid: ^pid} = active} = conversation ->
        put_conversation_runtime(state, conversation_key, %{conversation | active: fun.(active)})

      _conversation ->
        state
    end
  end

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

  defp maybe_send_error_reply_async(%{terminal_error_owner?: true}, _text), do: :ok
  defp maybe_send_error_reply_async(msg, text), do: send_error_reply_async(msg, text)

  defp terminal_error_owner?(%{msg: %{terminal_error_owner?: true}}), do: true
  defp terminal_error_owner?(_turn), do: false

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
        {key, runtime}, counts ->
          stop_conversation_runtime(state, key, runtime)
          tally_stopped(runtime, counts)
      end)

    {%{state | conversations: %{}, task_refs: %{}}, counts}
  end

  # The per-key half of the same stop: one conversation's runtime is dropped
  # (with its monitor ref, so the killed task's `:DOWN` is a no-op exactly as in
  # `stop_all`), every other conversation is untouched.
  defp stop_one_conversation(state, conversation_key) do
    case Map.get(state.conversations, conversation_key) do
      nil ->
        {state, {:ok, :not_found}}

      runtime ->
        stop_conversation_runtime(state, conversation_key, runtime)
        counts = tally_stopped(runtime, %{active_stopped: 0, pending_cleared: 0})
        {drop_conversation(state, conversation_key, runtime), {:ok, counts}}
    end
  end

  # Kill the active turn task, hand its channel the `{:cancelled}` outcome (the
  # killed task can never claim its own), then close the orphaned user message.
  # `terminate_child` is synchronous, so the task is already dead when the
  # callback fires and when the marker is written.
  defp stop_conversation_runtime(state, key, runtime) do
    terminate_active(state.task_supervisor, runtime)
    invoke_turn_result_async(active_turn_result_fn(runtime), {:cancelled})
    mark_stopped_turn(state, key, runtime)
  end

  defp active_turn_result_fn(%{active: %{turn_result_fn: fun}}) when is_function(fun, 1), do: fun
  defp active_turn_result_fn(_runtime), do: nil

  defp drop_conversation(state, conversation_key, runtime) do
    %{
      state
      | conversations: Map.delete(state.conversations, conversation_key),
        task_refs: drop_monitor_ref(state.task_refs, runtime)
    }
  end

  defp drop_monitor_ref(task_refs, %{active: %{monitor_ref: ref}}), do: Map.delete(task_refs, ref)
  defp drop_monitor_ref(task_refs, _runtime), do: task_refs

  defp clear_turn_result_fn(state, conversation_key, pid) do
    update_active_request(state, conversation_key, pid, &Map.put(&1, :turn_result_fn, nil))
  end

  defp terminate_active(task_supervisor, %{active: %{pid: pid}}) when is_pid(pid) do
    Task.Supervisor.terminate_child(task_supervisor, pid)
  end

  defp terminate_active(_task_supervisor, _runtime), do: :ok

  # A stopped active turn already persisted its user message but never committed
  # a reply. Append a marker (after the task is dead, so it can't write more) so
  # the next turn keeps the request in history without re-answering it. The
  # ConversationStore guard no-ops if the user message was never persisted (turn
  # killed before it stored). Best-effort: a down store must not crash the stop.
  defp mark_stopped_turn(_state, _key, %{active: nil}), do: :skipped

  defp mark_stopped_turn(state, key, %{active: _active}) do
    ConversationStore.append_stopped_marker(key, @stopped_turn_marker,
      server: state.conversation_store
    )
  catch
    :exit, _reason -> :skipped
  end

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

  defp emit_empty_completion_telemetry(%{core_msg: core_msg}) do
    :telemetry.execute(
      [:fermix, :dispatcher, :empty_completion],
      %{count: 1},
      %{channel: Map.get(core_msg, :channel)}
    )
  end

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
