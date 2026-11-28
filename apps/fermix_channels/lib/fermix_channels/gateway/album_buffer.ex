defmodule FermixChannels.Gateway.AlbumBuffer do
  @moduledoc """
  Coalesces a multi-attachment "album" into one turn, channel-agnostically.

  Some channels deliver a multi-image album as several *separate* inbound
  messages instead of one. Telegram sends album parts as distinct updates that
  share a `media_group_id` (often across poll cycles); WhatsApp — a stateless
  webhook with no group id — sends each image as its own webhook message. Without
  coalescing each part becomes its own one-image turn and the agent never sees
  the set together (M14).

  This is a *non-blocking* GenServer: it owns the debounce timers and the order
  deliveries run in, never the transport, and it never waits on a dispatch. That
  separation is load-bearing for Telegram — the poller blocks for tens of
  seconds inside getUpdates long-polling, so an in-poller flush timer could not
  fire until the poll returned (the original ~50s album delay). Buffering in
  this separate process flushes on time regardless of what the transport is
  doing. Each delivery's dispatch (`Gateway.ingest/2`: download, render and
  transcribe its attachments, then hand the turn to the queue) runs in a task
  of the buffer's own `Task.Supervisor`, so one chat's slow attachment holds
  neither another chat nor any flush timer.

  ## Per-channel policy

  Each buffering channel classifies its own inbound messages via the optional
  `c:FermixChannels.Gateway.Channel.album_classify/1` callback:

    * `{:coalesce, key}` — buffer under `key` with a reset-on-each-part debounce.
    * `{:flush, key}` — flush a pending album under `key` first, then dispatch
      this message as its own turn (a trailing text that shares the album's key).
    * `:passthrough` — dispatch immediately, touching no buffer (a message whose
      key can never collide with an album, e.g. a lone Telegram message).

  ## Merge

  Buffered parts flush as ONE message: every non-empty caption joined with `"\\n"`
  in arrival order, all attachments concatenated. Other fields come from the
  first part. The existing `Gateway.Attachments → TurnRunner → encoder` path turns that
  into one multi-image turn — no downstream change.

  ## Ingress lanes

  Every delivery (a flushed album, a passthrough, a trailing message) goes
  through `Gateway.IngressLanes` under its conversation's key,
  `Gateway.conversation_key/2`: the key the queue gives the turn, threads
  included. A message that does not normalize names no conversation and runs
  in one fixed lane, where `Gateway.ingest/2` rejects it.

    * Within a conversation, deliveries run one at a time in arrival order: one
      starts only after the previous one's ingest has ended, so it reached the
      queue first, which rests on one node delivering the two tasks' casts into
      `Gateway.Queue`'s default on-heap mailbox in the order they were sent (an
      off-heap one, `message_queue_data: :off_heap` with parallel signal
      delivery, does not promise it, and `Gateway.QueueTest` fails if the Queue
      ever takes one). The queue cannot restore an order two ingests finished
      in.
    * Across conversations, up to 8 run at once. A conversation waiting for a
      free slot is served in the order it became ready, behind those already
      waiting, so one busy chat cannot starve the others.
    * Up to 200 deliveries wait in all. Past that a delivery is refused,
      loudly: an error log naming the channel and the bounds,
      `[:fermix, :dispatcher, :ingress_failed]` with
      `reason: :ingress_lanes_full`, then the failed-dispatch path below.
    * A dispatch that raises or exits ends only its own task. It settles as a
      failed dispatch (`{:ingress_exit, reason}`); the buffer, its timers and
      the other conversations' parts carry on, and its lane's next delivery
      runs. The task supervisor is linked to the buffer, so a dispatch in
      flight stops with it, as it did when it ran inside it, and none can
      outlive a restart to deliver behind the new buffer.

  ## Ordering, idempotency, durability

    * **Ordering** within a conversation is kept by its lane, then by the
      gateway's per-conversation FIFO queue. A coalesce key is a subset of the
      conversation key, so a flushed album and a trailing message stay in
      arrival order.
    * **Idempotency** stays where the transport records it, *before*
      buffering. Webhook channels record per message id (pass
      `idempotency_key:`); on a dispatch error (a failed or crashed dispatch,
      or a delivery refused at capacity) the buffer `Idempotency.forget/2`s
      every buffered part id so a provider re-delivery can re-run. Telegram's
      poller records each update by its update id, which the buffer does not
      hold, so its buffer has no key (`idempotency_key: nil` — no forget):
      Telegram sends an update again only when the poller stopped before its
      next call confirmed it, and a dispatch error leaves the update recorded
      and logged.
    * **At-most-once across restart.** A daemon restart inside the (sub-second)
      debounce window drops unflushed parts, as it drops the deliveries waiting
      in the lanes and those in flight; webhook acks are already sent, and a
      part Telegram sends again is skipped as already recorded, so there is no
      re-delivery backstop. Acceptable for a rare restart vs. a short window;
      documented, not silently degraded.
  """

  use GenServer

  require Logger

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.IngressLanes
  alias FermixChannels.Gateway.Queue

  @default_debounce_ms 3_000
  # A single album is bounded by max_parts; the number of distinct concurrently
  # buffering keys is bounded by max_keys (excess keys dispatch uncoalesced
  # rather than growing the buffer without limit).
  @default_max_parts 10
  @default_max_keys 200
  # The lanes' bounds: dispatches running at once, and deliveries waiting in
  # all. Internal constants; the `start_link/1` options exist for tests.
  @max_active 8
  @max_waiting 200
  # The one lane of messages that do not normalize (`Gateway.ingest/2` rejects
  # each, and logs it, as before the lanes).
  @no_conversation :no_conversation

  @doc "Registered name of the album buffer for `channel` (one instance per buffering channel)."
  @spec name_for(module()) :: atom()
  def name_for(channel) when is_atom(channel), do: Module.concat(channel, AlbumBuffer)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Route one inbound message through the album buffer for its channel."
  @spec ingest(map(), GenServer.server()) :: :ok
  def ingest(message, server) when is_map(message) do
    GenServer.cast(server, {:ingest, message})
  end

  @impl true
  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    ensure_classifiable!(channel)
    # Linked: a dispatch in flight lives and dies with this buffer.
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    state = %{
      buffers: %{},
      channel: channel,
      idempotency_key: Keyword.get(opts, :idempotency_key),
      debounce_ms: Keyword.get(opts, :debounce_ms) || configured_debounce_ms(opts),
      max_parts: Keyword.get(opts, :max_parts, @default_max_parts),
      max_keys: Keyword.get(opts, :max_keys, @default_max_keys),
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      # Dispatch seam (default = the real gateway); tests inject a capturing fun.
      dispatch: Keyword.get(opts, :dispatch, &Gateway.ingest/2),
      # The lane key seam (default = the gateway's conversation, the queue's key).
      conversation_key: Keyword.get(opts, :conversation_key, &Gateway.conversation_key/2),
      lanes:
        IngressLanes.new(
          max_active: Keyword.get(opts, :max_active, @max_active),
          max_waiting: Keyword.get(opts, :max_waiting, @max_waiting)
        ),
      task_supervisor: task_supervisor,
      # Each running dispatch's task ref => its lane key and the ids to forget.
      tasks: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:ingest, message}, state) do
    {:noreply, route(message, state)}
  end

  @impl true
  def handle_info({:flush, key, token}, state) do
    {:noreply, flush_if_current(key, token, state)}
  end

  # A flush with no current token — a timer that fired after its entry was
  # superseded (Process.cancel_timer can't recall an already-delivered message),
  # or a bare legacy {:flush, key} — is stale; ignore it so it can't dispatch a
  # since-extended album early and split a later part into its own turn.
  def handle_info({:flush, _key}, state) do
    {:noreply, state}
  end

  # A dispatch task answered; it is done, so its monitor goes with it.
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(ref, result, state)}
  end

  # A dispatch task died before it answered: a raise or an exit in the ingest.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, settle(ref, {:error, {:ingress_exit, reason}}, state)}
  end

  # --- routing ---

  defp route(message, %{debounce_ms: ms} = state) when ms <= 0 do
    deliver_single(message, state)
  end

  defp route(message, state) do
    case state.channel.album_classify(message) do
      {:coalesce, key} -> buffer(message, key, state)
      {:flush, key} -> flush_then_dispatch(message, key, state)
      :passthrough -> passthrough(message, state)
    end
  end

  defp passthrough(message, state) do
    deliver_single(message, state)
  end

  defp flush_then_dispatch(message, key, state) do
    state = flush_now(key, state)
    deliver_single(message, state)
  end

  defp buffer(message, key, state) do
    case Map.get(state.buffers, key) do
      nil -> start_new(key, message, state)
      entry -> extend(key, entry, message, state)
    end
  end

  defp start_new(key, message, %{buffers: buffers, max_keys: max_keys} = state)
       when map_size(buffers) >= max_keys do
    Logger.warning(
      "#{inspect(state.channel)} album buffer at max_keys (#{max_keys}); " <>
        "dispatching #{inspect(key)} uncoalesced"
    )

    deliver_single(message, state)
  end

  defp start_new(key, message, state) do
    {timer, token} = arm(key, state.debounce_ms)
    put_in(state, [:buffers, key], %{messages: [message], timer: timer, token: token})
  end

  defp extend(key, %{messages: messages, timer: timer}, message, state) do
    if timer, do: Process.cancel_timer(timer)
    messages = messages ++ [message]

    if length(messages) >= state.max_parts do
      deliver_album(messages, %{state | buffers: Map.delete(state.buffers, key)})
    else
      {new_timer, token} = arm(key, state.debounce_ms)
      put_in(state, [:buffers, key], %{messages: messages, timer: new_timer, token: token})
    end
  end

  # Arm a debounce timer carrying a unique token so a stale flush (from a timer
  # that fired before extend/4 could cancel it) is recognizable and ignored.
  defp arm(key, debounce_ms) do
    token = make_ref()
    timer = Process.send_after(self(), {:flush, key, token}, debounce_ms)
    {timer, token}
  end

  # Timer-driven flush: only fire if the token still matches the entry's current
  # timer (a superseded timer's token won't match → ignored).
  defp flush_if_current(key, token, state) do
    case Map.get(state.buffers, key) do
      %{token: ^token} -> flush_now(key, state)
      _stale_or_absent -> state
    end
  end

  # Unconditional flush of whatever is buffered under `key` (used by the timer
  # path via flush_if_current, and directly when a non-image message flushes a
  # pending album before dispatching).
  defp flush_now(key, state) do
    case Map.pop(state.buffers, key) do
      {nil, _buffers} ->
        state

      {%{messages: messages, timer: timer}, buffers} ->
        if timer, do: Process.cancel_timer(timer)
        deliver_album(messages, %{state | buffers: buffers})
    end
  end

  # --- merge + dispatch ---

  # Merge album parts into one message: keep every non-empty caption (WhatsApp
  # attaches a caption per message; Telegram carries one group caption — both
  # collapse to the right thing here), join them in arrival order, and
  # concatenate all attachments, each keeping its part's `forwarded?`; a
  # forwarded part's caption keeps its own label. The album is forwarded when
  # any part is. Other fields come from the first part.
  defp merge_album([first | _] = messages) do
    content =
      messages
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    %{
      first
      | content: content,
        attachments: Enum.flat_map(messages, & &1.attachments),
        metadata: merged_metadata(first.metadata, messages)
    }
  end

  defp merged_metadata(metadata, messages) do
    if Enum.any?(messages, &(Map.get(&1.metadata, :forwarded) == true)),
      do: Map.put(metadata, :forwarded, true),
      else: metadata
  end

  defp deliver_album([single], state), do: deliver([single], [part_id(single)], state)

  defp deliver_album(messages, state),
    do: deliver([merge_album(messages)], Enum.map(messages, &part_id/1), state)

  defp deliver_single(message, state), do: deliver([message], [part_id(message)], state)

  # A delivery joins its conversation's lane: it runs now, waits its turn, or is
  # refused when the lanes are full.
  defp deliver([message] = messages, forget_ids, state) do
    key = lane_key(message, state)
    work = %{messages: messages, forget_ids: forget_ids}

    case IngressLanes.push(state.lanes, key, work) do
      {:start, started, lanes} -> start_dispatch(key, started, %{state | lanes: lanes})
      {:queued, lanes} -> %{state | lanes: lanes}
      {:full, lanes} -> refuse(work, %{state | lanes: lanes})
    end
  end

  # No conversation is no error here: `Gateway.ingest/2` rejects and logs the
  # message when its turn in the fixed lane comes.
  defp lane_key(message, state) do
    case state.conversation_key.(state.channel, message) do
      {:ok, conversation_key} -> conversation_key
      {:error, {:invalid_message, _field}} -> @no_conversation
    end
  end

  # The dispatch runs in a task of the buffer's own supervisor, which answers
  # the buffer with `{ref, result}`, or `:DOWN` if it dies first.
  defp start_dispatch(key, %{messages: messages, forget_ids: forget_ids}, state) do
    dispatch = state.dispatch
    opts = [channel: state.channel, agent: state.agent, agent_server: state.agent_server]

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn -> dispatch.(messages, opts) end)

    %{state | tasks: Map.put(state.tasks, task.ref, %{key: key, forget_ids: forget_ids})}
  end

  # Settled before its lane moves on, so a failed delivery's ids are forgotten
  # before the next delivery of its conversation starts.
  defp settle(ref, result, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        unknown_task(ref, result, state)

      {%{key: key, forget_ids: forget_ids}, tasks} ->
        settle_result(result, forget_ids, state)
        start_next(key, %{state | tasks: tasks})
    end
  end

  defp settle_result(:ok, _forget_ids, _state), do: :ok
  defp settle_result({:error, reason}, forget_ids, state), do: forget(forget_ids, reason, state)

  defp settle_result(other, forget_ids, state),
    do: forget(forget_ids, {:unexpected_dispatch_result, other}, state)

  defp start_next(key, state) do
    case IngressLanes.finish(state.lanes, key) do
      {:start, next_key, work, lanes} -> start_dispatch(next_key, work, %{state | lanes: lanes})
      {:idle, lanes} -> %{state | lanes: lanes}
    end
  end

  # Every dispatch the buffer starts stays in `tasks` until it settles, so an
  # answer or a death it does not know is a defect: named loudly, never dropped.
  defp unknown_task(ref, result, state) do
    Logger.error(
      "#{inspect(state.channel)} album buffer got #{inspect(result, limit: 20, printable_limit: 200)} " <>
        "from #{inspect(ref)}, a dispatch it is not running"
    )

    state
  end

  # Full lanes refuse the delivery and take the failed-dispatch path, so a
  # webhook's ids are forgotten and the provider's re-delivery runs.
  defp refuse(%{messages: [message], forget_ids: forget_ids}, state) do
    %{max_active: max_active, max_waiting: max_waiting} = state.lanes

    Logger.error(
      "#{inspect(state.channel)} album buffer refused a delivery: its ingress lanes are full " <>
        "(max_waiting #{max_waiting} reached, max_active #{max_active})"
    )

    :telemetry.execute(
      [:fermix, :dispatcher, :ingress_failed],
      %{count: 1},
      %{channel: message_channel(message), reason: :ingress_lanes_full}
    )

    forget(forget_ids, :ingress_lanes_full, state)
    state
  end

  # A buffer with no key has nothing to forget: Telegram's poller records update
  # ids, which the buffer does not hold. Webhook channels forget every buffered
  # part id so a re-delivery can re-run (the ack is already committed, so the
  # flush is the only chance).
  defp forget(_ids, reason, %{idempotency_key: nil} = state) do
    Logger.error("#{inspect(state.channel)} album-buffer dispatch failed: #{inspect(reason)}")
    :ok
  end

  defp forget(ids, reason, %{idempotency_key: key} = state) do
    Logger.error(
      "#{inspect(state.channel)} album-buffer dispatch failed: #{inspect(reason)}; " <>
        "forgetting #{length(ids)} message id(s) so a re-delivery can re-run"
    )

    Enum.each(ids, &Idempotency.forget(key, &1))
    :ok
  end

  # --- helpers ---

  defp ensure_classifiable!(channel) do
    if Code.ensure_loaded?(channel) and function_exported?(channel, :album_classify, 1) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(channel)} must implement album_classify/1 to use Gateway.AlbumBuffer"
    end
  end

  defp part_id(message), do: Map.get(message, :id) || Map.get(message, "id")

  defp message_channel(message), do: Map.get(message, :channel) || Map.get(message, "channel")

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp configured_debounce_ms(opts) do
    with key when is_atom(key) and not is_nil(key) <- Keyword.get(opts, :config_key),
         {:ok, cfg} <- FermixCore.Config.channel(key) do
      Keyword.get(cfg, :album_debounce_ms, @default_debounce_ms)
    else
      _ -> @default_debounce_ms
    end
  end
end
