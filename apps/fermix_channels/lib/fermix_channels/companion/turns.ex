defmodule FermixChannels.Companion.Turns do
  @moduledoc """
  Ends every companion turn on the wire from the Gateway queue's outcome, and
  only from it.

  The companion socket's turns are handed to the queue through this module
  (`handle_message/2`, the Gateway's agent contract), so it knows every one
  that became a queue turn, waiting or running; a message the gateway handled
  as a slash command never passes here. For each tracked turn:

    * its reply text is held, not written, until the queue fires the turn's
      outcome: a reply callback runs before the turn commits and claims its
      outcome, and a stop in that window would leave the timeline holding an
      answer the conversation's history marks as stopped;
    * `{:completed}` writes each held reply as a timeline row, announces it as
      `text_done` at its `server_seq`, and completes the request;
    * `{:cancelled}` and `{:failed, _}` settle the request as failed and
      announce `turn_error`; the held text is dropped;
    * the queue it was handed to dying (a restart loses every outcome it held)
      ends the turn the same way, with code `interrupted`.

  This process also owns the hand-off to the queue and every stop of a turn
  handed to it, so a `cancel` is never lost between the two. `cancel` records
  its mark on the request before asking here; a hand-off reads that mark and
  enqueues in one step of this process, so a request cancelled before it was
  queued never is (it ends with `turn_error`, code `cancelled`), and a stop for
  a turn already handed off is sent to the queue by the process that sent the
  turn, so it can never overtake it. A request recovered at boot is handed off
  here too, so recovery respects the mark.

  The queue fires one outcome per turn, so the wire carries one ending: a
  turn is never announced as cancelled and answered. A reply or an outcome
  that arrives after its turn ended (a turn of a dead queue that still
  commits, or a result behind the queue's `:DOWN`) is dropped. A reply for a
  message that is not a tracked turn (a slash command's answer) is written and
  announced at once.

  This process is the settlement owner of every companion request once it
  reaches the queue: the request coordinator's liveness fence moves here, so
  a dead queue fails the request here, once, and never races a release that
  would rerun it.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Output
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Telemetry

  @max_ended 64

  @type turn_key :: {String.t(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The Gateway's agent contract (`agent.handle_message(message, agent_server)`):
  hand the turn to the queue and track it, unless its request carries a cancel.
  """
  @spec handle_message(map(), GenServer.server()) :: :ok | {:error, term()}
  def handle_message(message, queue) when is_map(message) do
    GenServer.call(__MODULE__, {:hand_off, message, queue})
  end

  @doc """
  Stop the turn of a request whose cancel is already recorded on it: a turn
  handed to the queue is stopped there, running or waiting. A request not
  handed off yet needs nothing more, because its hand-off reads the mark.
  """
  @spec cancel(String.t(), String.t(), GenServer.server()) :: :ok
  def cancel(profile_id, client_msg_id, server \\ __MODULE__)
      when is_binary(profile_id) and is_binary(client_msg_id) do
    GenServer.call(server, {:cancel, profile_id, client_msg_id})
  end

  @doc "Hold one reply of a tracked turn, or write it now for anything else."
  @spec reply(Message.t(), String.t()) :: :ok | {:error, term()}
  def reply(%Message{} = message, text) when is_binary(text) do
    GenServer.call(__MODULE__, {:reply, message, text})
  end

  @doc "End a tracked turn on the wire from the queue's outcome."
  @spec outcome(Message.t(), term()) :: :ok | {:error, term()}
  def outcome(%Message{} = message, outcome) do
    GenServer.call(__MODULE__, {:outcome, message, outcome})
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

  @impl true
  def handle_call({:hand_off, message, queue}, _from, state) do
    case GenServer.whereis(queue) do
      pid when is_pid(pid) -> hand_off(state, new_turn(message, pid), message)
      nil -> {:reply, {:error, {:queue_unavailable, queue}}, state}
    end
  end

  # Sent from here, after the enqueue this process sent, so the stop cannot
  # reach the queue ahead of the turn it names.
  def handle_call({:cancel, profile, client_id}, _from, state) do
    case Map.get(state.turns, {profile, client_id}) do
      nil ->
        {:reply, :ok, state}

      turn ->
        {:ok, _stopped} =
          Queue.stop_turn(Companion.conversation_key(profile), client_id, turn.queue)

        {:reply, :ok, state}
    end
  end

  def handle_call({:reply, message, text}, _from, state) do
    key = turn_key(message)

    cond do
      Map.has_key?(state.turns, key) -> {:reply, :ok, hold(state, key, text)}
      key in state.ended -> {:reply, :ok, state}
      true -> {:reply, write_untracked(message, text), state}
    end
  end

  def handle_call({:outcome, message, outcome}, _from, state) do
    case Map.pop(state.turns, turn_key(message)) do
      {nil, _turns} -> {:reply, :ok, state}
      {turn, turns} -> {:reply, :ok, finish(%{state | turns: turns}, turn, outcome)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, queue, _reason}, state) do
    {dead, alive} = Enum.split_with(state.turns, fn {_key, turn} -> turn.queue == queue end)
    state = %{state | turns: Map.new(alive), queues: Map.delete(state.queues, queue)}

    {:noreply,
     Enum.reduce(dead, state, fn {_key, turn}, acc ->
       finish(acc, turn, {:failed, :interrupted})
     end)}
  end

  def handle_info(message, state) do
    Logger.debug("companion turns ignored #{inspect(message)}")
    {:noreply, state}
  end

  # The mark is read and the turn enqueued in this one step, so a cancel
  # recorded before it is always seen, and one recorded after it finds the turn
  # tracked here and stops it in the queue.
  defp hand_off(state, turn, message) do
    case cancel_recorded(state, turn) do
      {:ok, true} ->
        {:reply, :ok, fail(state, turn, :cancelled)}

      {:ok, false} ->
        state = track(state, turn)
        {:reply, Queue.handle_message(message, turn.queue), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A turn with no request behind it (a re-ingested resume) has no mark to read.
  defp cancel_recorded(_state, %{attempt: nil}), do: {:ok, false}

  defp cancel_recorded(state, turn) do
    with {:ok, request} <- store(state).get_client_request(turn.profile, turn.client_id, []) do
      {:ok, not is_nil(Map.get(request, :cancelled_at))}
    end
  end

  defp new_turn(message, queue) do
    metadata = Map.get(message, :metadata) || %{}

    %{
      key: turn_key(message),
      profile: Map.fetch!(message, :chat_id),
      client_id: Map.get(metadata, :client_msg_id) || Map.fetch!(message, :id),
      attempt: Map.get(metadata, :companion_attempt),
      turn_id: Map.get(metadata, :turn_id) || "turn-" <> Map.fetch!(message, :id),
      queue: queue,
      replies: []
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

  defp hold(state, key, text),
    do: update_in(state.turns[key].replies, &[text | &1])

  defp finish(state, turn, {:completed}) do
    turn.replies |> Enum.reverse() |> Enum.each(&write_reply(state, turn, &1))
    settle(state, turn, :completed)
    ended(state, turn.key)
  end

  defp finish(state, turn, {:cancelled}), do: fail(state, turn, :cancelled)
  defp finish(state, turn, {:failed, reason}), do: fail(state, turn, reason)

  defp fail(state, turn, reason) do
    settle(state, turn, {:failed, reason})
    _ = Companion.broadcast(turn.profile, Output.turn_error(turn.turn_id, reason))
    ended(state, turn.key)
  end

  # One held reply becomes its row, fenced to the turn's attempt, and is
  # announced at that row. A failed write is the operator's to read: the turn
  # still completes, as it did in the conversation's own history. The row is the
  # outbound message, counted as `Companion.send_message/3` counts its own.
  defp write_reply(state, turn, text) do
    attrs = %{in_reply_to: turn.client_id, attempt: turn.attempt, turn_id: turn.turn_id}

    {written, duration_us} =
      Telemetry.timed_us(fn -> Output.persist_text(store(state), turn.profile, text, attrs) end)

    case written do
      {:ok, {:created, row}} ->
        ChannelTelemetry.emit_message(:companion, :outbound, 1, duration_us)
        Companion.broadcast(turn.profile, Output.text_done(turn.turn_id, row.server_seq, text))

      {:ok, {:existing, _row}} ->
        :ok

      {:error, reason} ->
        Logger.error("companion reply for #{turn.turn_id} was not written: #{inspect(reason)}")
    end
  end

  # A turn with no request behind it (a re-ingested resume) has nothing to
  # settle; every other one settles its request exactly once, here.
  defp settle(_state, %{attempt: nil}, _result), do: :ok

  defp settle(state, turn, :completed) do
    case Output.complete_request(store(state), turn.profile, turn.client_id, turn.attempt) do
      {:error, reason} -> log_settle(turn, reason)
      _settled -> :ok
    end
  end

  defp settle(state, turn, {:failed, reason}) do
    case Output.fail_request(store(state), turn.profile, turn.client_id, turn.attempt, reason) do
      :ok -> :ok
      {:error, error} -> log_settle(turn, error)
    end
  end

  defp log_settle(turn, reason) do
    Logger.error("companion request #{turn.client_id} was not settled: #{inspect(reason)}")
  end

  # Not a queue turn: a slash command's answer, written as the request's
  # output and announced at once, exactly as a delivery is.
  defp write_untracked(message, text),
    do: Companion.send_message(message.reply_target, text, Companion.reply_opts(message))

  defp ended(state, key), do: %{state | ended: Enum.take([key | state.ended], @max_ended)}

  defp turn_key(message), do: {Map.fetch!(message, :chat_id), Map.fetch!(message, :id)}

  defp store(%{store: nil}), do: Companion.store()
  defp store(%{store: store}), do: store
end
