defmodule FermixChannels.Voice.Bridge do
  @moduledoc """
  The Live voice engine's seam into the Fermix agent
  (MILESTONE_41_OPENAI_LIVE_VOICE.md §5.2/§7).

  Under `openai_live` the provider speaks but never runs a tool: every task is
  delegated back to Core through `FermixCore.Realtime.VoiceBridge`, which this
  module implements and `FermixChannels.Application` registers at boot. Core
  therefore never names a Channels module; it resolves one.

  A delegation is an ordinary turn. It goes through `Gateway.ingest/2` — the one
  production ingress — so it is authorized, queued, and run by the same
  `TurnRunner` a chat message is, with the same sandbox gates and the same
  single-flight FIFO. What makes it a VOICE turn is one trusted map on the
  message's metadata (`FermixCore.Agents.VoiceCall`), which names the
  conversation the turn runs in and its store, the call and its trace session,
  and the backend prompt addendum. The message itself stays on the `voice`
  channel with the call id as its chat, so authorization, commands off, the
  voice adapter and that trust gate are the same in both modes below.

  The call's `conversation` (M56 §5) picks where its hand-offs run:

  - **`"chat"`** (the default): in the chat's own conversation,
    `Channels.Companion.chat_conversation_key/0`, on the durable store every
    typed turn uses. The call opens no store. A hand-off then reads what was
    typed before it, a typed turn reads the hand-offs before it, and the two
    share one queue lane, so neither runs beside the other (M56 §4.1).
  - **`"private"`**: in a conversation of the call's own, keyed by its UUID,
    `{"voice", call_uuid, :root}`. A non-persisting call runs it on its own
    in-memory `ConversationStore` (`repo: nil`, 128 messages), started here and
    linked to the session, so nothing a caller says reaches the durable history
    and the whole thing is released when the call ends. A persisting call uses
    the global store. The key is the UUID, not the call id, because the call id
    restarts with the daemon and a later call must never inherit an earlier
    one's history.

  Two lifetimes are call-scoped either way:

  - **The turns.** The queue serializes one call's delegations in their
    conversation — the session allows one active and one pending delegation,
    and the queue enforces the same shape. Each delegation runs as the queue
    turn named by its message id, `voice-delegation-<id>-<revision>`, and
    `cancel/2` and `close_call/1` stop those turns by name
    (`Queue.stop_turn/3`), never the conversation, so nothing else running or
    waiting in it is touched (M56 §4.1); the session's `LiveDelegation` is the
    authority on which delegations exist.
  - **The routing entries.** One Registry key per call plus one per delegation,
    all owned by the session process, released by `close_call/1` (or by the
    session dying). They are what the channel adapter's closures read, and
    unregistering them is what makes an answer arriving after the call closed a
    dropped event rather than a spoken one.
  """

  @behaviour FermixCore.Realtime.VoiceBridge

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Realtime.LivePrompt
  alias FermixCore.Realtime.VoiceBridge

  # Design §8: "history capped at 128 messages plus a token limit". The token
  # limit is TurnRunner's ordinary auto-compaction, which reads whichever store
  # the snapshot names — so this is the message-count half only.
  @ephemeral_max_messages 128

  @typedoc """
  What `open_call/1` hands back; opaque to the session.

  `queue` is the turn scheduler this call ingests through — `Gateway.Queue`
  unless the caller named another, the same injection seam
  `Channels.Acp.Peer` takes as `agent_server`. It is resolved ONCE, at open,
  so every delegation, cancel and close of one call reaches the same scheduler.
  `conversation_key` and `store` are resolved once too, from the call's mode.
  """
  @type handle :: %{
          call_id: String.t(),
          call_uuid: String.t(),
          conversation_key: ConversationKey.t(),
          store: GenServer.server(),
          owner: pid(),
          persist?: boolean(),
          queue: GenServer.server()
        }

  @typedoc """
  What `submit/3` hands back; the session passes it to `cancel/2`. The
  conversation the turn runs in and the turn's own message id, which the queue
  stops it by.
  """
  @type task_ref :: {ConversationKey.t(), message_id :: String.t()}

  @doc """
  Open one call: claim the call id, then name the conversation its hand-offs
  run in and stand up the history it needs.

  Registration comes FIRST so a second session cannot half-open the same call
  and leave an orphaned store behind; a failed store start releases the claim.
  """
  @impl true
  @spec open_call(VoiceBridge.call()) :: {:ok, handle()} | {:error, term()}
  def open_call(
        %{call_id: call_id, call_uuid: call_uuid, conversation: conversation, persist?: persist?} =
          call
      )
      when is_binary(call_id) and call_id != "" and is_binary(call_uuid) and call_uuid != "" and
             conversation in ["chat", "private"] and is_boolean(persist?) do
    queue = Map.get(call, :agent_server, Queue)

    case Registry.register(Voice.registry(), call_id, %{persist?: persist?}) do
      {:ok, _owner} -> open_conversation(call, queue)
      {:error, {:already_registered, pid}} -> {:error, {:call_already_open, pid}}
    end
  end

  @doc """
  Submit one delegation as an agent turn.

  The callbacks are recorded under `{call_id, delegation_id}` BEFORE the ingest,
  because a fast turn can deliver its answer before `ingest/2` returns — and a
  result that found no route would be dropped as late.
  """
  @impl true
  @spec submit(handle(), VoiceBridge.request(), VoiceBridge.callbacks()) ::
          {:ok, task_ref()} | {:error, term()}
  def submit(%{call_id: call_id, owner: owner} = handle, request, callbacks)
      when is_pid(owner) and is_map(request) and is_map(callbacks) do
    %{delegation_id: delegation_id, revision: revision} = request

    with :ok <- ensure_owner(call_id, owner),
         :ok <- put_delegation(call_id, delegation_id, revision, callbacks) do
      ingest_delegation(handle, request)
    end
  end

  @doc """
  Cancel a delegation by stopping its own queue turn, named by the message id
  it was ingested under. A running turn is killed and a waiting one dropped;
  either way the queue hands the turn's channel a `{:cancelled}` outcome, and
  THAT is what reaches the session — so there is exactly one place a delegation
  is answered from. Every other turn of the conversation, running or waiting,
  is left alone.

  A cancel that races an enqueue the queue has not processed yet finds nothing
  to stop; the turn then completes normally and answers with its result. A turn
  that already claimed its outcome is likewise left to answer with it. That is
  the truth of what happened, so it is reported rather than papered over.
  """
  @impl true
  @spec cancel(handle(), task_ref()) :: :ok | {:error, term()}
  def cancel(%{call_id: call_id, queue: queue}, {conversation_key, message_id})
      when is_tuple(conversation_key) and is_binary(message_id) do
    {:ok, outcome} = Queue.stop_turn(conversation_key, message_id, queue)

    Logger.info("voice bridge cancelled #{call_id}/#{message_id}: #{inspect(outcome)}")

    :ok
  end

  @doc """
  Close the call: stop routing first, then stop the work, then release the
  history.

  Unregistering before the stop is what makes a late answer a DROPPED answer —
  the closures have no route the moment the call is closed. The work is the
  turns the call registered, each stopped by its own message id; the
  conversation they run in is never stopped. A stop still writes its marker
  into the call's own store (the queue resolves the store from the message),
  which is why the store is released last.
  """
  @impl true
  @spec close_call(handle()) :: :ok
  def close_call(%{
        call_id: call_id,
        conversation_key: conversation_key,
        store: store,
        owner: owner,
        queue: queue
      })
      when is_pid(owner) do
    turns = registered_turns(call_id)
    unregister_all(call_id)
    outcomes = Enum.map(turns, &stop_turn(conversation_key, &1, queue))
    stop_store(store)

    Logger.info("voice bridge closed call #{call_id}: #{inspect(outcomes)}")
    :ok
  end

  # --- Call lifetime ---

  # The chat's own conversation on the durable store every typed turn uses: the
  # call opens no store of its own (M56 §4.1).
  defp open_conversation(%{conversation: "chat"} = call, queue),
    do: {:ok, handle(call, Companion.chat_conversation_key(), ConversationStore, queue)}

  defp open_conversation(%{conversation: "private", call_uuid: call_uuid} = call, queue) do
    key = {Voice.channel(), call_uuid, :root}

    case private_store(call.persist?) do
      {:ok, store} -> {:ok, handle(call, key, store, queue)}
      {:error, reason} -> release_claim(call.call_id, reason)
    end
  end

  # `name: nil` starts an ANONYMOUS store, addressed by pid — the global name
  # belongs to the durable conversation store. Linked to the caller (the Live
  # session), so a session that dies without closing leaves no orphan; a store
  # that dies takes the call with it, which is honest: a call that lost its
  # history cannot answer the next delegation from context.
  defp private_store(false) do
    ConversationStore.start_link(name: nil, repo: nil, max_messages: @ephemeral_max_messages)
  end

  defp private_store(true), do: {:ok, ConversationStore}

  defp handle(call, conversation_key, store, queue) do
    Logger.info(
      "voice bridge opened call #{call.call_id} in #{inspect(conversation_key)} " <>
        "(persist?: #{call.persist?})"
    )

    %{
      call_id: call.call_id,
      call_uuid: call.call_uuid,
      conversation_key: conversation_key,
      store: store,
      owner: self(),
      persist?: call.persist?,
      queue: queue
    }
  end

  defp release_claim(call_id, reason) do
    Registry.unregister(Voice.registry(), call_id)
    {:error, {:conversation_store_unavailable, reason}}
  end

  # Only a store the call started is the call's to release; the durable store
  # holds every conversation.
  defp stop_store(store) when is_pid(store) do
    if Process.alive?(store), do: GenServer.stop(store, :normal), else: :ok
  end

  defp stop_store(_durable_store), do: :ok

  # `Registry.keys/2` answers with every key this process registered, which is
  # the call id plus one entry per delegation it submitted. Bounded by the
  # call's own length (the session caps concurrent delegations, and a call is
  # capped by `max_session_minutes`).
  defp unregister_all(call_id) do
    registry = Voice.registry()

    registry
    |> Registry.keys(self())
    |> Enum.filter(&owned_by_call?(&1, call_id))
    |> Enum.each(&Registry.unregister(registry, &1))
  end

  # The queue turn of every delegation the call registered, by message id: one
  # per delegation, at its latest revision, since a correction replaces its
  # entry. A turn that already ended answers `:not_found` to its stop.
  defp registered_turns(call_id) do
    registry = Voice.registry()

    for {^call_id, delegation_id} = key <- Registry.keys(registry, self()),
        %{revision: revision} <- Registry.values(registry, key, self()),
        do: delegation_message_id(%{delegation_id: delegation_id, revision: revision})
  end

  defp stop_turn(conversation_key, message_id, queue) do
    {:ok, outcome} = Queue.stop_turn(conversation_key, message_id, queue)
    {message_id, outcome}
  end

  defp owned_by_call?(call_id, call_id), do: true
  defp owned_by_call?({call_id, _delegation_id}, call_id), do: true
  defp owned_by_call?(_key, _call_id), do: false

  # --- Delegation ---

  # `submit/3` registers in the caller's name, so a caller that is not the call
  # owner would write routing entries the owner can neither update nor release.
  # Refuse instead: the Live session opens, submits, and closes from one process.
  defp ensure_owner(_call_id, owner) when owner == self(), do: :ok

  defp ensure_owner(call_id, owner) do
    Logger.error(
      "voice bridge refusing a submit for #{call_id} from #{inspect(self())}; " <>
        "the call is owned by #{inspect(owner)}"
    )

    {:error, :not_call_owner}
  end

  # A re-asked task keeps its delegation id and takes a new revision, so the
  # entry is replaced rather than added to: unregister-then-register is one
  # path for both the first submission and every correction.
  defp put_delegation(call_id, delegation_id, revision, callbacks)
       when is_binary(delegation_id) and delegation_id != "" and
              is_integer(revision) and revision >= 1 do
    key = {call_id, delegation_id}
    registry = Voice.registry()

    Registry.unregister(registry, key)

    case Registry.register(registry, key, %{revision: revision, callbacks: callbacks}) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:delegation_owned_by, pid}}
    end
  end

  # The task ref names the conversation from the handle: before ingest the
  # message has no trust level, so `ConversationKey.from/1` would not yet
  # believe its `voice_call` and would answer the voice channel's own key.
  defp ingest_delegation(%{call_id: call_id, queue: queue} = handle, request) do
    message = build_message(handle, request)

    case Gateway.ingest([message], channel: Voice, agent: Queue, agent_server: queue) do
      :ok ->
        {:ok, {handle.conversation_key, message.id}}

      {:error, reason} ->
        Registry.unregister(Voice.registry(), {call_id, request.delegation_id})
        {:error, reason}
    end
  end

  defp build_message(%{call_id: call_id, store: store, persist?: persist?} = handle, request) do
    Message.new!(%{
      id: delegation_message_id(request),
      content: request.text,
      sender: "voice",
      channel: Voice.channel(),
      chat_id: call_id,
      reply_target: call_id,
      metadata: %{
        source: :voice,
        user_id: "voice",
        chat_type: "private",
        voice_call: %{
          call_id: call_id,
          call_uuid: handle.call_uuid,
          conversation_key: handle.conversation_key,
          delegation_id: request.delegation_id,
          revision: request.revision,
          turn_session_id: request.turn_session_id,
          conversation_store: store,
          prompt_addendum: LivePrompt.backend_addendum(),
          persist?: persist?
        }
      },
      media_parts: media_parts(request)
    })
  end

  defp delegation_message_id(%{delegation_id: delegation_id, revision: revision}) do
    "voice-delegation-#{delegation_id}-#{revision}"
  end

  # The newest screen frame the session buffered, if the call is sharing a
  # screen. Transient like every other inbound image: it rides the turn and is
  # never persisted.
  defp media_parts(request) do
    case Map.get(request, :screen_frame) do
      %{} = frame -> [frame]
      nil -> []
    end
  end
end
