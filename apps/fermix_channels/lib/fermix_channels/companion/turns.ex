defmodule FermixChannels.Companion.Turns do
  @moduledoc """
  Ends every turn of the two companion transports, the Mac's `companion.sock`
  and the phone's mobile channel, from the Gateway queue's outcome, and only
  from it.

  Both transports ingest their requests with this module as the Gateway's
  agent (`handle_message/2`), so it knows every one that became a queue turn,
  waiting or running. A message the gateway answered without a turn (a slash
  command's answer, an empty or unauthorized message, an ingress failure the
  gateway replied to) never passes here; once its ingest returned,
  `Companion.Requests` hands its settlement here too
  (`settle_unless_handed_off/5`), and it runs only if no turn was handed off
  for that attempt. For each tracked turn:

    * a companion turn's reply text is held, not written, until the queue fires
      the turn's outcome: a reply callback runs before the turn commits and
      claims its outcome, and a stop in that window would leave the timeline
      holding an answer the conversation's history marks as stopped. A phone
      turn streams and writes its own rows as it runs (`Channels.Mobile`'s
      draft and `send_message`), so here it is only settled;
    * `{:completed}` writes each held reply as a timeline row, announces it as
      `text_done` at its `server_seq` to the companion connections and as a
      `row` to the phones, and completes the request; a companion turn that
      holds no reply ends with `turn_done` instead (companion protocol 2);
    * `{:cancelled}` and `{:failed, _}` settle the request as failed and
      announce `turn_error` to the transport that ran the turn; held text is
      dropped;
    * the queue it was handed to dying (a restart loses every outcome it held)
      ends the turn the same way, with code `interrupted`.

  During a Live call in the chat, a turn of the chat's own conversation is
  told to the call as it is handed off, and its answer as it completes
  (`Voice.ChatMirror`, M56 §4.3). Such a turn may end with no reply (M56
  §4.4): when its runner says so (`silent/1`, before the reply arrives, from
  the turn's own process), its reply, exactly the sentinel, is dropped rather
  than held, it ends with `turn_done`, and the call is told no answer.

  This process also owns the hand-off to the queue and every stop of a turn
  handed to it, so a `cancel` is never lost between the two. `cancel` records
  its mark on the request before asking here; a hand-off reads that mark and
  enqueues in one step of this process, so a request cancelled before it was
  queued never is (it ends with `turn_error`, code `cancelled`), and a stop for
  a turn already handed off is sent to the queue by the process that sent the
  turn, so it can never overtake it. A request recovered at boot is handed off
  here too, so recovery respects the mark. A revoked phone's requests are
  marked and their turns stopped here as well, in one step, so the device
  registry that revoked it never waits on the store.

  The queue fires one outcome per turn, so the wire carries one ending: a
  turn is never announced as cancelled and answered. A reply or an outcome
  that arrives after its turn ended (a turn of a dead queue that still
  commits, or a result behind the queue's `:DOWN`) is dropped. A reply for a
  message that is not a tracked turn (a slash command's answer) is written and
  announced at once.

  This process is the settlement owner of every request of both transports
  once its ingest returned: the request coordinator's liveness fence moves
  here, so a dead queue fails the request here, once, and never races a
  release that would rerun it.

  Because every fenced request would be released to run again if this
  process died, and every turn it tracks would lose its ending, no failure
  of what it calls may crash it. A stop waits for the queue however busy it
  is, so only a queue that is gone ends that wait, and its `:DOWN` then ends
  the turn. A store call that exits (a Repo timeout or restart) is logged as
  that request's error while the turn still ends on the wire, once. A
  request answered without a turn whose settlement fails, in the store or by
  a raise in the request path's settle code (logged whole, as the defect it
  is), is failed for its attempt and its client is told, so it is not left
  running for the next boot to run again (unless the store cannot record the
  failure either, which is logged). A raise in this process's own code, or
  in a store call it makes, is a defect and no store failure: it crashes
  this process to its supervisor.

  Nobody waits on this process to learn what became of a request: the
  hand-off and the settlement of a request answered without a turn are both
  casts, so a slow answer here can never fail a request whose turn this
  process may already hold. A worker's two casts reach it in the order they
  were sent, so the settlement is decided after the hand-off it follows.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixChannels.Voice.ChatMirror
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.LiveCallTurn
  alias FermixCore.Telemetry

  @max_ended 64
  @channels ["companion", "mobile"]

  @typedoc """
  The request path's settlement of a request answered without a turn:
  `settle` completes it, and if that fails, `fail` fails its attempt and
  `report` tells its client, each with the failure's cause.
  """
  @type settlement :: %{
          settle: (-> :ok | {:error, term()}),
          fail: (term() -> :ok),
          report: (term() -> :ok)
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # Every call into this process waits with no timeout, because every callback
  # here is bounded: its store calls end within their own timeouts, and a stop
  # waits on the queue, whose callbacks are bounded (`Gateway.Queue`'s client
  # API note). A slow stop then delays the socket that asked and the turns that
  # reply meanwhile, instead of crashing them.

  @doc """
  The Gateway's agent contract (`agent.handle_message(message, agent_server)`):
  hand the turn to the queue and track it, unless its request carries a cancel.
  The hand-off is sent, never awaited; only a Turns that is not running at all
  is refused here.
  """
  @spec handle_message(map(), GenServer.server()) :: :ok | {:error, term()}
  def handle_message(%{channel: channel} = message, queue) when channel in @channels do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, {:settlement_owner_unavailable, __MODULE__}}
      turns -> GenServer.cast(turns, {:hand_off, message, queue})
    end
  end

  # A grant is confirmed only on the transport that raised it (its token is
  # bound to that origin), and resumes its request on the request's own
  # channel through that transport's agent. One on any other channel has no
  # request of these transports behind it, so it reaches the queue as any
  # other channel's turn does.
  def handle_message(%{channel: channel} = message, queue) when is_binary(channel),
    do: Queue.handle_message(message, queue)

  @doc """
  Settle, with `settlement`, a request of this attempt that the gateway
  answered without a turn: it runs here, after every hand-off sent before it,
  and only if none of them handed off a turn for this attempt, which then
  settles from its outcome instead. Sent, never awaited.
  """
  @spec settle_unless_handed_off(
          GenServer.server(),
          String.t(),
          String.t(),
          pos_integer(),
          settlement()
        ) :: :ok
  def settle_unless_handed_off(
        server,
        profile_id,
        client_msg_id,
        attempt,
        %{settle: settle, fail: fail, report: report} = settlement
      )
      when is_binary(profile_id) and is_binary(client_msg_id) and is_integer(attempt) and
             attempt > 0 and is_function(settle, 0) and is_function(fail, 1) and
             is_function(report, 1) do
    GenServer.cast(
      server,
      {:settle_unless_handed_off, {profile_id, client_msg_id}, attempt, settlement}
    )
  end

  @doc """
  Stop the turn of a request whose cancel is already recorded on it: a turn
  handed to the queue is stopped there, running or waiting. A request not
  handed off yet needs nothing more, because its hand-off reads the mark.
  """
  @spec cancel(GenServer.server(), String.t(), String.t()) :: :ok
  def cancel(server, profile_id, client_msg_id)
      when is_binary(profile_id) and is_binary(client_msg_id) do
    GenServer.call(server, {:cancel, profile_id, client_msg_id}, :infinity)
  end

  @doc """
  Stop everything a revoked device asked for, without waiting: every
  unsettled request it claimed is marked cancelled, so no hand-off or boot
  recovery runs it, and a turn already handed off is stopped as `cancel/3`
  stops one. The device is gone from the trust store before this is asked,
  so no new request of its passes ingest, and a revocation that fails here
  (a store that exits, or no `Turns` running) leaves boot recovery and the
  ingest check to refuse its work; that failure is logged, the operator's to
  read.
  """
  @spec revoke_device(GenServer.server(), String.t()) :: :ok
  def revoke_device(server, device_id) when is_binary(device_id) and device_id != "" do
    case GenServer.whereis(server) do
      nil -> log_unrevoked(device_id, {:settlement_owner_unavailable, server})
      turns -> GenServer.cast(turns, {:revoke_device, device_id})
    end
  end

  @doc """
  The tracked turn of `message` ends with no reply: its runner said so, its
  snapshot having allowed it (M56 §4.4). Its reply that is exactly the
  sentinel is then dropped, not held. Sent, never awaited; sent from the
  turn's own process before its reply, so it is handled first.
  """
  @spec silent(Message.t()) :: :ok
  def silent(%Message{} = message), do: GenServer.cast(__MODULE__, {:silent, message})

  @doc "Hold one reply of a tracked turn, or write it now for anything else."
  @spec reply(Message.t(), String.t()) :: :ok | {:error, term()}
  def reply(%Message{} = message, text) when is_binary(text) do
    GenServer.call(__MODULE__, {:reply, message, text}, :infinity)
  end

  @doc """
  End a tracked turn on the wire from the queue's outcome. Answers the request
  as it completed, for the channel's own effects after the outcome (the phone's
  push), or `nil` for any other ending, or for no tracked turn.
  """
  @spec outcome(Message.t(), term()) :: {:ok, map() | nil}
  def outcome(%Message{} = message, outcome) do
    GenServer.call(__MODULE__, {:outcome, message, outcome}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       store: Keyword.get(opts, :store),
       queues: %{},
       turns: %{},
       ended: []
     }}
  end

  # Sent from here, after the enqueue this process sent, so the stop cannot
  # reach the queue ahead of the turn it names.
  @impl true
  def handle_call({:cancel, profile, client_id}, _from, state) do
    :ok = stop(state, {profile, client_id})
    {:reply, :ok, state}
  end

  def handle_call({:reply, message, text}, _from, state) do
    key = turn_key(message)
    attempt = message_attempt(message)

    cond do
      silent_ending?(state, key, attempt, text) -> {:reply, :ok, state}
      tracked?(state, key, attempt) -> {:reply, :ok, hold(state, key, text)}
      {key, attempt} in state.ended -> {:reply, :ok, state}
      true -> {:reply, write_untracked(message, text), state}
    end
  end

  def handle_call({:outcome, message, outcome}, _from, state) do
    key = turn_key(message)

    if tracked?(state, key, message_attempt(message)) do
      {turn, turns} = Map.pop!(state.turns, key)
      {settled, state} = finish(%{state | turns: turns}, turn, outcome)
      {:reply, {:ok, settled}, state}
    else
      {:reply, {:ok, nil}, state}
    end
  end

  @impl true
  def handle_cast({:hand_off, message, queue}, state) do
    case GenServer.whereis(queue) do
      pid when is_pid(pid) -> {:noreply, hand_off(state, new_turn(message, pid), message)}
      nil -> {:noreply, fail(state, new_turn(message, queue), {:queue_unavailable, queue})}
    end
  end

  def handle_cast({:silent, message}, state) do
    key = turn_key(message)

    if tracked?(state, key, message_attempt(message)),
      do: {:noreply, put_in(state.turns[key].silent?, true)},
      else: {:noreply, state}
  end

  def handle_cast({:settle_unless_handed_off, key, attempt, settlement}, state) do
    if tracked?(state, key, attempt) or {key, attempt} in state.ended,
      do: :ok,
      else: settle_inline(key, attempt, settlement)

    {:noreply, state}
  end

  def handle_cast({:revoke_device, device_id}, state) do
    cancel = fn -> store(state, %{transport: :mobile}).cancel_device_requests(device_id, []) end

    case guarded(device_id, "device revocation", cancel) do
      {:ok, requests} ->
        Enum.each(requests, &(:ok = stop(state, {&1.profile_id, &1.client_msg_id})))

      {:error, reason} ->
        log_unrevoked(device_id, reason)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, queue, _reason}, state) do
    {dead, alive} = Enum.split_with(state.turns, fn {_key, turn} -> turn.queue == queue end)
    state = %{state | turns: Map.new(alive), queues: Map.delete(state.queues, queue)}

    {:noreply,
     Enum.reduce(dead, state, fn {_key, turn}, acc -> fail(acc, turn, :interrupted) end)}
  end

  def handle_info(message, state) do
    Logger.debug("companion turns ignored #{inspect(message)}")
    {:noreply, state}
  end

  # The mark is read and the turn enqueued in this one step, so a cancel
  # recorded before it is always seen, and one recorded after it finds the turn
  # tracked here and stops it in the queue. A mark that cannot be read ends the
  # turn before it is queued: the request may carry a cancel.
  defp hand_off(state, turn, message) do
    case cancel_recorded(state, turn) do
      {:ok, true} ->
        fail(state, turn, :cancelled)

      {:ok, false} ->
        state = track(state, turn)
        :ok = Queue.handle_message(message, turn.queue)
        :ok = ChatMirror.typed(turn.conversation, message.content)
        state

      {:error, reason} ->
        fail(state, turn, reason)
    end
  end

  # A turn with no request behind it (a re-ingested resume) has no mark to read.
  defp cancel_recorded(_state, %{attempt: nil}), do: {:ok, false}

  defp cancel_recorded(state, turn) do
    read = fn -> store(state, turn).get_client_request(turn.profile, turn.client_id, []) end

    with {:ok, request} <- guarded(turn.client_id, "cancel mark read", read) do
      {:ok, not is_nil(Map.get(request, :cancelled_at))}
    end
  end

  # A request answered without a turn, settled by the request path's own
  # functions. One they could not settle is failed once for its attempt, and
  # its client is told whether or not that write took: its worker has
  # returned, and a request left running would run its command again at the
  # next boot. Each step's own failure is logged where it happens: an error
  # the failure write returns by the request path, an exit by `guarded/3`.
  defp settle_inline({_profile, client_id}, attempt, settlement) do
    case run_settle(client_id, settlement.settle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "companion request #{client_id} attempt #{attempt} was not settled, so it is " <>
            "failed: #{inspect(reason)}"
        )

        _failed = guarded(client_id, "failure", fn -> settlement.fail.(reason) end)
        _told = guarded(client_id, "failure report", fn -> settlement.report.(reason) end)
        :ok
    end
  end

  # The settle code is the request path's, not the store's: a raise in it, an
  # answer outside its contract included, is a defect, not a Repo that timed
  # out. It is logged whole, at error level, and its request is failed as a
  # store failure's is, because re-raising it here would crash this process
  # and release every fenced request to run again.
  defp run_settle(client_id, settle) do
    case guarded(client_id, "inline settlement", settle) do
      :ok -> :ok
      {:error, _reason} = not_settled -> not_settled
    end
  rescue
    exception ->
      Logger.error(
        "companion inline settlement for #{client_id} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:raised, exception}}
  end

  defp new_turn(message, queue) do
    metadata = Map.get(message, :metadata) || %{}

    %{
      key: turn_key(message),
      transport: transport(message.channel),
      conversation: ConversationKey.from(message),
      profile: Map.fetch!(message, :chat_id),
      client_id: Map.get(metadata, :client_msg_id) || Map.fetch!(message, :id),
      attempt: message_attempt(message),
      turn_id: Map.get(metadata, :turn_id) || "turn-" <> Map.fetch!(message, :id),
      queue: queue,
      replies: [],
      silent?: false
    }
  end

  defp track(state, turn) do
    %{
      state
      | turns: Map.put(state.turns, turn.key, turn),
        queues: watch(state.queues, turn.queue)
    }
  end

  defp watch(queues, queue) do
    if Map.has_key?(queues, queue),
      do: queues,
      else: Map.put(queues, queue, Process.monitor(queue))
  end

  defp tracked?(state, key, attempt), do: match?(%{attempt: ^attempt}, state.turns[key])

  defp silent_ending?(state, key, attempt, text) do
    match?(%{attempt: ^attempt, silent?: true}, state.turns[key]) and
      LiveCallTurn.sentinel?(text)
  end

  defp stop(state, key) do
    case Map.get(state.turns, key) do
      nil -> :ok
      turn -> stop_in_queue(turn, elem(key, 1))
    end
  end

  # The queue the turn was handed to answers the stop, however busy it is
  # (`Gateway.Queue`'s client API note), so this call exits only when that
  # queue is gone: `:noproc` for one already dead, its exit reason for one
  # that died in the stop. Either took the turn with it, and its `:DOWN`,
  # already on its way here, ends the turn as `interrupted`. Any other exit is
  # not a dead queue and is not caught.
  defp stop_in_queue(%{queue: queue} = turn, message_id) do
    {:ok, _stopped} = Queue.stop_turn(turn.conversation, message_id, queue)
    :ok
  catch
    :exit, {reason, {GenServer, :call, [^queue, {:stop_turn, _key, _id}, :infinity]}} ->
      Logger.warning(
        "companion turns could not stop #{turn.turn_id}: the queue that held it is gone " <>
          "(#{inspect(reason)}); its :DOWN ends the turn"
      )

      :ok
  end

  defp hold(state, key, text),
    do: update_in(state.turns[key].replies, &[text | &1])

  defp finish(state, turn, {:completed}) do
    turn.replies |> Enum.reverse() |> Enum.each(&write_reply(state, turn, &1))
    :ok = announce_no_reply(turn)
    :ok = mirror_answer(turn)
    {settle_completed(state, turn), ended(state, turn)}
  end

  defp finish(state, turn, {:cancelled}), do: {nil, fail(state, turn, :cancelled)}
  defp finish(state, turn, {:failed, reason}), do: {nil, fail(state, turn, reason)}

  # A companion turn that completed holding no reply has no `text_done` to end
  # it: it ends with `turn_done`, which only a version 2 client is sent. A
  # phone turn wrote its own rows and is only settled.
  defp announce_no_reply(%{transport: :companion, replies: []} = turn),
    do: Fanout.announce(turn.profile, Output.turn_done(turn.turn_id), audience: :companion)

  defp announce_no_reply(_turn), do: :ok

  # A turn that ended silently answered nothing for the call to hear.
  defp mirror_answer(%{silent?: true}), do: :ok
  defp mirror_answer(turn), do: ChatMirror.answered(turn.conversation)

  defp fail(state, turn, reason) do
    settle_failed(state, turn, reason)
    event = Output.turn_error(turn.turn_id, reason)
    :ok = Fanout.announce(turn.profile, event, audience: turn.transport)
    ended(state, turn)
  end

  # One held reply becomes its row, fenced to the turn's attempt, and is
  # announced at that row: as the turn's `text_done` to the connections that
  # streamed it, and as a `row` to the phones, which did not. A failed write is
  # the operator's to read: the turn still completes, as it did in the
  # conversation's own history. The row is the outbound message, counted as
  # `Companion.send_message/3` counts its own.
  defp write_reply(state, turn, text) do
    attrs = %{in_reply_to: turn.client_id, attempt: turn.attempt, turn_id: turn.turn_id}

    write = fn -> Output.persist_text(store(state, turn), turn.profile, text, attrs) end
    {written, duration_us} = Telemetry.timed_us(fn -> guarded(turn.client_id, "reply", write) end)

    case written do
      {:ok, {:created, row}} ->
        ChannelTelemetry.emit_message(:companion, :outbound, 1, duration_us)
        done = Output.text_done(turn.turn_id, row.server_seq, text)
        :ok = Fanout.announce(turn.profile, done, audience: :companion)
        Fanout.announce(turn.profile, Output.row(turn.profile, row), audience: :mobile)

      {:ok, {:existing, _row}} ->
        :ok

      {:error, reason} ->
        Logger.error("companion reply for #{turn.turn_id} was not written: #{inspect(reason)}")
    end
  end

  # A turn with no request behind it (a re-ingested resume) has nothing to
  # settle; every other one settles its request exactly once, here.
  defp settle_completed(_state, %{attempt: nil}), do: nil

  defp settle_completed(state, turn) do
    complete = fn ->
      Output.complete_request(store(state, turn), turn.profile, turn.client_id, turn.attempt)
    end

    case guarded(turn.client_id, "completion", complete) do
      {:ok, request} -> request
      :ok -> nil
      {:error, reason} -> log_settle(turn, reason)
    end
  end

  defp settle_failed(_state, %{attempt: nil}, _reason), do: :ok

  defp settle_failed(state, turn, reason) do
    store = store(state, turn)

    fail = fn ->
      Output.fail_request(store, turn.profile, turn.client_id, turn.attempt, reason)
    end

    case guarded(turn.client_id, "failure", fail) do
      :ok -> :ok
      {:error, error} -> log_settle(turn, error)
    end
  end

  # A store call is a GenServer call into the Repo, as a failure report to a
  # phone is one into its device registry, and it fails in one of two ways: it
  # returns an error, which its caller here answers, or it exits because the
  # callee timed out or is restarting. That exit is the request's error,
  # logged whole, never this process's crash, which would release every
  # fenced request to run again and lose the ending of every turn tracked
  # here. A raise is no store failure, and is not caught.
  defp guarded(client_id, what, fun) do
    fun.()
  catch
    :exit, reason ->
      Logger.error(
        "companion #{what} for #{client_id} failed: " <>
          Exception.format(:exit, reason, __STACKTRACE__)
      )

      {:error, {:exit, reason}}
  end

  defp log_settle(turn, reason) do
    Logger.error("companion request #{turn.client_id} was not settled: #{inspect(reason)}")
    nil
  end

  defp log_unrevoked(device_id, reason) do
    Logger.error(
      "mobile device #{device_id} was revoked but its requests were not stopped: " <>
        inspect(reason)
    )
  end

  # Not a queue turn: a slash command's answer, written as the request's
  # output and announced at once, exactly as a delivery is.
  defp write_untracked(message, text) do
    write = fn ->
      Companion.send_message(message.reply_target, text, Companion.reply_opts(message))
    end

    guarded(message.id, "reply", write)
  end

  defp ended(state, turn),
    do: %{state | ended: Enum.take([{turn.key, turn.attempt} | state.ended], @max_ended)}

  defp turn_key(message), do: {Map.fetch!(message, :chat_id), Map.fetch!(message, :id)}

  # Where each transport's request attempt rides in the message metadata.
  defp message_attempt(%{channel: "companion"} = message),
    do: Map.get(Map.get(message, :metadata) || %{}, :companion_attempt)

  defp message_attempt(%{channel: "mobile"} = message),
    do: Map.get(Map.get(message, :metadata) || %{}, :mobile_attempt)

  defp transport("companion"), do: :companion
  defp transport("mobile"), do: :mobile

  defp store(%{store: nil}, %{transport: :companion}), do: Companion.store()
  defp store(%{store: nil}, %{transport: :mobile}), do: Mobile.store()
  defp store(%{store: store}, _turn), do: store
end
