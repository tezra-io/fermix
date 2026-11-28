defmodule FermixChannels.PhoneCalls.Bridge do
  @moduledoc """
  The channels side of `FermixCore.PhoneCalls.Delegate` (M94 §05, §07): runs
  one scoped backend turn for a phone call's delegation, and answers the
  call's worker with exactly one message.

  A delegation is an internal submission, so it enters the gateway's turn
  queue (`Gateway.Queue`) directly rather than through `Gateway.ingest/2`,
  whose stages admit outside input: a sender's authorization, attachments,
  slash commands. Its message (`Agents.PhoneCallTurn.message/1`) is on the
  `phone_call` channel at `phone_call` trust, which the gateway never assigns
  and whose channel it does not know, so no transport can hand in a message
  the turn runner reads as a phone call's turn: a real channel's message that
  claims to be one is an ordinary message of that channel, and one on the
  `phone_call` channel is refused at ingest as an unknown channel. The handle
  the worker minted rides only inside that message, to the turn's in-call
  controls, which present it back to the worker.

  The queue then runs it as any turn, through `MainAgent`'s snapshot (a
  device engine refuses it there) and `TurnRunner`, which hands it to
  `Agents.PhoneCallTurn`. Its conversation, and so its queue lane, is the
  call's own (`{"phone_call", call_id, :root}`): an owner's long chat turn
  never holds a call's answer behind it, nor the reverse. Its message id names
  the delegation (`PhoneCallTurn.message_id/2`), so a stop names it.

  Each delegation has a watcher, a task of `FermixCore.TaskSupervisor` started
  before the turn is queued, which is the one sender of the delegation's
  result:

      {:phone_call_delegation, call_id, delegation_id,
       {:ok, %{reply: String.t(), backend_usage: map()}} | {:error, reason}}

  It answers on the first of: the turn's reply (told on the raw stream
  callback after `PhoneCalls.Disclosure` passed it, never through text
  delivery, so nothing the queue itself says, a canned error included, can
  reach the call), the turn's end without one (`{:failed, reason}`,
  `{:cancelled}`), the request's deadline (`deadline_ms` from submission: the
  watcher stops the turn, then answers `:deadline_exceeded`), or the queue
  going down (`{:queue_down, reason}`). The worker going down stops the turn
  and answers nobody. Every way it ends sends at most that one message, and
  the turn's own late events reach a watcher that is gone.

  `cancel/2` stops the delegation's queue turns by its message id, a running
  one killed and a waiting one dropped; the watcher then answers `:cancelled`.
  A turn already past its claim answers with its own result. Fencing a stale
  answer is the worker's (`PhoneCalls.Delegate`).

  Seams (tests): `:queue` (a `Gateway.Queue` server), `:task_supervisor` and
  `:arm_deadline` (`(pid, message, ms -> term)`, default
  `Process.send_after/3`).
  """

  @behaviour FermixCore.PhoneCalls.Delegate

  require Logger

  alias FermixChannels.Gateway.Queue
  alias FermixCore.Agents.PhoneCallTurn
  alias FermixCore.PhoneCalls.Delegate
  alias FermixCore.PhoneCalls.Limits

  @impl true
  @spec run(Delegate.request()) :: :ok | {:error, term()}
  def run(request), do: run(request, [])

  @doc "`run/1` with the seams in `opts` (see the moduledoc)."
  @spec run(Delegate.request(), keyword()) :: :ok | {:error, term()}
  def run(%{reply_to: reply_to, deadline_ms: deadline_ms} = request, opts)
      when is_pid(reply_to) and is_integer(deadline_ms) and deadline_ms > 0 and is_list(opts) do
    message = PhoneCallTurn.message(request)
    tag = make_ref()

    with {:ok, queue} <- live_queue(Keyword.get(opts, :queue, Queue)),
         {:ok, watcher} <- start_watcher(request, message.id, queue, tag, opts) do
      Queue.enqueue(queue, with_answers(message, watcher, tag))
    end
  end

  @impl true
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(call_id, delegation_id), do: cancel(call_id, delegation_id, [])

  @doc "`cancel/2` against the queue `opts[:queue]` names."
  @spec cancel(String.t(), String.t(), keyword()) :: :ok
  def cancel(call_id, delegation_id, opts)
      when is_binary(call_id) and is_binary(delegation_id) and is_list(opts) do
    queue = Keyword.get(opts, :queue, Queue)
    outcomes = stop_turns(queue, call_id, delegation_id)
    Logger.info("phone call bridge cancelled #{call_id}/#{delegation_id}: #{inspect(outcomes)}")
    :ok
  end

  # --- submission -------------------------------------------------------------

  defp live_queue(queue) do
    case GenServer.whereis(queue) do
      pid when is_pid(pid) -> {:ok, pid}
      _gone -> {:error, {:queue_unavailable, queue}}
    end
  end

  defp start_watcher(request, message_id, queue, tag, opts) do
    watch = %{
      request: request,
      message_id: message_id,
      queue: queue,
      tag: tag,
      arm: Keyword.get(opts, :arm_deadline, &Process.send_after/3)
    }

    supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)

    case Task.Supervisor.start_child(supervisor, fn -> watch(watch) end) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:delegation_not_started, reason}}
    end
  end

  # The queue's closures for this turn, each a message to the watcher. Text
  # delivery answers nothing: the reply comes on the raw stream callback.
  defp with_answers(message, watcher, tag) do
    notify = fn event ->
      send(watcher, {:phone_call_turn, tag, event})
      :ok
    end

    Map.merge(message, %{
      reply_fn: &delivered/1,
      turn_result_fn: fn outcome -> notify.({:outcome, outcome}) end,
      stream_spec: %{mode: :raw, callback: told(notify)},
      terminal_error_owner?: true
    })
  end

  defp told(notify) do
    fn
      {:phone_call_reply, reply, usage} when is_binary(reply) -> notify.({:reply, reply, usage})
      _other_event -> :ok
    end
  end

  defp delivered({:text, _text}), do: :ok
  defp delivered(_part), do: {:error, :not_deliverable_on_a_phone_call}

  # --- the watcher -------------------------------------------------------------

  defp watch(%{request: request, tag: tag} = watch) do
    worker = Process.monitor(request.reply_to)
    queue = Process.monitor(watch.queue)
    # A timer to this process is cancelled by the runtime when it exits.
    _timer = watch.arm.(self(), {:phone_call_deadline, tag}, request.deadline_ms)
    await(Map.merge(watch, %{worker_ref: worker, queue_ref: queue}))
  end

  defp await(%{tag: tag, worker_ref: worker, queue_ref: queue} = watch) do
    receive do
      {:phone_call_turn, ^tag, event} ->
        answer(watch, result(event))

      {:phone_call_deadline, ^tag} ->
        stop_watched(watch)
        answer(watch, {:error, :deadline_exceeded})

      {:DOWN, ^worker, :process, _pid, _reason} ->
        stop_watched(watch)

      {:DOWN, ^queue, :process, _pid, reason} ->
        answer(watch, {:error, {:queue_down, reason}})
    end
  end

  defp result({:reply, reply, usage}), do: {:ok, %{reply: reply, backend_usage: usage}}
  defp result({:outcome, {:failed, reason}}), do: {:error, reason}
  defp result({:outcome, {:cancelled}}), do: {:error, :cancelled}
  # A turn that ran to its end and told no reply: never a reply to speak.
  defp result({:outcome, {:completed}}), do: {:error, :no_reply}

  defp answer(%{request: request}, result) do
    log_result(request, result)

    send(
      request.reply_to,
      {:phone_call_delegation, request.call_id, request.delegation_id, result}
    )

    :ok
  end

  defp log_result(_request, {:ok, _reply}), do: :ok

  defp log_result(request, {:error, reason}) do
    Logger.info(
      "phone call #{request.call_id} delegation #{request.delegation_id} answered with an " <>
        "error: #{inspect(reason, limit: 20)}"
    )
  end

  defp stop_watched(%{request: request, queue: queue}) do
    outcomes = stop_turns(queue, request.call_id, request.delegation_id)

    Logger.info(
      "phone call bridge stopped #{request.call_id}/#{request.delegation_id}: " <>
        inspect(outcomes)
    )
  end

  # Stops every queue turn of the delegation, at most
  # `Limits.max_delegation_stops/0` times (each turn it can hold, and once
  # more): a stopped running turn lets its waiting successor start, which the
  # next stop ends. A queue that is gone has nothing left to stop.
  defp stop_turns(queue, call_id, delegation_id) do
    key = PhoneCallTurn.conversation_key(call_id)
    message_id = PhoneCallTurn.message_id(call_id, delegation_id)

    Enum.reduce_while(1..Limits.max_delegation_stops(), [], fn _attempt, outcomes ->
      case stop_turn(queue, key, message_id) do
        outcome when outcome in [:stopped, :dequeued] -> {:cont, [outcome | outcomes]}
        outcome -> {:halt, [outcome | outcomes]}
      end
    end)
  end

  defp stop_turn(queue, key, message_id) do
    {:ok, outcome} = Queue.stop_turn(key, message_id, queue)
    outcome
  catch
    :exit, reason ->
      Logger.warning("phone call bridge could not stop #{message_id}: #{inspect(reason)}")
      :queue_gone
  end
end
