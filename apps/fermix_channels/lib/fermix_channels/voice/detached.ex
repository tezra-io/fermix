defmodule FermixChannels.Voice.Detached do
  @moduledoc """
  The owner of the GPT-Live tasks that outlive their call (M56 §4.6).

  In a call in the chat a hand-off runs in the chat's own conversation, so a
  task still running when the call ends has somewhere to finish. The session
  does not cancel it: it hands it to this process, one under the voice
  supervisor that outlives every session, which owns the task's reply route
  and its wall clock until the task ends, and then writes its result to the
  chat.

  **Why the transfer is ordered.** A reply finds its delegation through the
  voice registry, whose unique keys are owned by the process that registered
  them: no process can take over another's key, and a key is released only
  when its owner unregisters it or dies. So the session cannot hand its route
  over; a second owner must hold a route of its own, under its own key
  (`route/2`), and there is a moment when both hold one. The transfer makes
  that moment the only kind there is, in this order:

    1. the session writes the task `detached` in the call's record, its
       destination the chat;
    2. this process registers its route for `{call_uuid, task_id, revision}`
       (`adopt/2`);
    3. the session releases its own route and closes.

  `Channels.Voice` resolves a reply by the session's route first and this
  route second. Had the session released first, a reply arriving between the
  two would find no route and be dropped as late; in this order it always
  finds one. A reply that reaches the session while it settles is forwarded
  here by the session (the forward `adopt/2` answers), and one that raced the
  release is also routed here by the adapter, so a reply can arrive twice and
  never not at all: the first outcome of a task is the one kept.

  **When a task ends** (its reply, its failure, a cancel, `/stop`, or its wall
  clock), its done row is written to the chat through `Voice.Bridge.show/2`
  (`Realtime.CallRow.task_done/4`, keyed by the task revision so a repeat
  finds it), a phone push is scheduled for it while the phone channel runs
  (no one is on the call to hear it), the task's terminal state is written to
  the record (`CallRecord.settle_task/6`), and `delegation_stop` is emitted
  with `detached: true`. The record is the session's until it exits, since its
  settle closes the record with the task list it holds: an end that arrives
  sooner is held, and written once the session is gone. As the task is
  adopted, one row says it is still running.

  **Provenance** (M56 §9): a reply drawn from Computer History is shown in the
  chat, which is local, and nothing is said, since there is no call; so the
  `history_tainted` word a turn sends changes nothing here.

  **Bounds.** At most `max_tasks/0` tasks at once (the work registry's
  precedent); a ninth is refused and the session cancels it as before. Each
  task has a wall clock of `wall_clock_ms/0` on top of its turn's iteration
  cap: past it the turn is stopped and the task ends `timed_out`. A task whose
  turn is gone from the queue (its queue restarted) ends at its wall clock.

  Nothing here may crash on a failure of what it calls: a stop of a queue that
  is gone, a row the timeline cannot write and a record that cannot be written
  are logged, and the task still ends. A raise in this process's own code is a
  defect, and its supervisor restarts it with no task; their routes go with
  it, and the next boot ends them as restarted (`CallRecord.sweep_detached/3`).
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Channels.Voice
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixChannels.Voice.Bridge
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallRow
  alias FermixCore.Realtime.LiveTelemetry
  alias FermixCore.Realtime.LiveText

  # The work registry's ceiling on concurrently running background work.
  @max_tasks 8
  # The jobs runner's default wall clock for one run.
  @wall_clock_ms 30 * 60 * 1_000

  @summary_max_chars 240
  # `LiveText.split/2`'s bound; nothing is said after the call, so it changes
  # nothing a summary keeps but where a reply with no delimiter is cut.
  @split_max_bytes 1_500

  @typedoc """
  A task handed over as its call ends: its call (trace id and UUID), its ids,
  the request it ran with, its turn's session id, how long it had run, the
  record's Repo options, the queue turn it runs as (`conversation_key`,
  `message_id`, `queue`), and the session that handed it over.
  """
  @type task :: %{
          call_id: String.t(),
          call_uuid: String.t(),
          task_id: String.t(),
          revision: pos_integer(),
          request: String.t(),
          turn_session_id: String.t(),
          elapsed_ms: non_neg_integer(),
          record_opts: keyword(),
          conversation_key: FermixCore.Agents.ConversationKey.t(),
          message_id: String.t(),
          queue: GenServer.server(),
          session: pid()
        }

  @typedoc "A task's three ids, as a companion `cancel.task_ref` names them."
  @type task_ref :: %{required(String.t()) => String.t() | pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The most tasks held at once."
  @spec max_tasks() :: pos_integer()
  def max_tasks, do: @max_tasks

  @doc "How long a detached task may run before its turn is stopped."
  @spec wall_clock_ms() :: pos_integer()
  def wall_clock_ms, do: @wall_clock_ms

  @doc "The voice registry key a detached task's route is held under."
  @spec route(String.t(), String.t()) :: {:detached, String.t(), String.t()}
  def route(call_uuid, task_id) when is_binary(call_uuid) and is_binary(task_id),
    do: {:detached, call_uuid, task_id}

  # Every call into this process waits with no timeout, because every
  # callback here is bounded: a Repo call ends within its own timeout, and a
  # stop waits on the queue, whose callbacks are bounded (`Gateway.Queue`).

  @doc """
  Take over `task`: register its route, start its wall clock, and write the
  row that says it is still running. Answers the function the session
  forwards its own events for the task with, or `{:error, :full}` past
  `max_tasks/0`.
  """
  @spec adopt(GenServer.server(), task()) :: {:ok, (term() -> :ok)} | {:error, term()}
  def adopt(server, %{call_uuid: call_uuid, task_id: task_id, session: session} = task)
      when is_binary(call_uuid) and is_binary(task_id) and is_pid(session) do
    GenServer.call(server, {:adopt, task}, :infinity)
  end

  @doc """
  Stop the task `task_ref` names, only if this process owns exactly that
  `{call_uuid, task_id, revision}`. Its done row, `cancelled` unless it was
  already ending, is the acknowledgement.
  """
  @spec cancel(GenServer.server(), task_ref()) :: :ok | {:error, :task_not_running}
  def cancel(server, %{"call_uuid" => uuid, "task_id" => task_id, "revision" => revision})
      when is_binary(uuid) and is_binary(task_id) and is_integer(revision) do
    GenServer.call(server, {:cancel, {uuid, task_id, revision}}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       registry: Keyword.get(opts, :registry, Voice.registry()),
       wall_clock_ms: Keyword.get(opts, :wall_clock_ms, @wall_clock_ms),
       mobile_running?: Keyword.get(opts, :mobile_running?, &MobileSupervisor.running?/0),
       tasks: %{},
       sessions: %{}
     }}
  end

  @impl true
  def handle_call({:adopt, _task}, _from, state) when map_size(state.tasks) >= @max_tasks,
    do: {:reply, {:error, :full}, state}

  def handle_call({:adopt, task}, _from, state) do
    key = {task.call_uuid, task.task_id, task.revision}
    entry = %{revision: task.revision, callbacks: callbacks(self(), key)}

    case Registry.register(state.registry, route(task.call_uuid, task.task_id), entry) do
      {:ok, _owner} ->
        state = state |> watch(task.session) |> track(key, task)
        {:reply, {:ok, forward(self(), key)}, state, {:continue, {:running_row, key}}}

      {:error, {:already_registered, _owner}} ->
        {:reply, {:error, :already_detached}, state}
    end
  end

  def handle_call({:cancel, key}, _from, state) do
    case Map.fetch(state.tasks, key) do
      {:ok, task} -> {:reply, :ok, stop(state, task, :cancelled)}
      :error -> {:reply, {:error, :task_not_running}, state}
    end
  end

  @impl true
  def handle_continue({:running_row, key}, state) do
    task = Map.fetch!(state.tasks, key)
    {call, text} = CallRow.task_running(task.call_uuid, task.task_id, task.revision, task.request)
    _written = write_row(task, call, text)
    {:noreply, state}
  end

  @impl true
  def handle_info({:detached_event, key, {:result, result}}, state),
    do: {:noreply, ended(state, key, task_end(result))}

  # Progress and tool activity are for a call, and there is none; the
  # Computer History word changes nothing shown (moduledoc).
  def handle_info({:detached_event, _key, _event}, state), do: {:noreply, state}

  def handle_info({:wall_clock, key}, state) do
    case Map.fetch(state.tasks, key) do
      {:ok, %{outcome: nil} = task} -> {:noreply, stop(state, task, :timed_out)}
      _ended_or_gone -> {:noreply, state}
    end
  end

  # The task's turn was not in its queue when it was stopped: its outcome was
  # already on its way here, ahead of this message, or its queue died with it.
  def handle_info({:abandon, key}, state) do
    case Map.fetch(state.tasks, key) do
      {:ok, %{outcome: nil, stopping: stopping}} -> {:noreply, ended(state, key, stopping)}
      _ended_or_gone -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, session, _reason}, state) do
    state = %{state | sessions: Map.delete(state.sessions, session)}

    ready =
      for {key, %{session: ^session, outcome: outcome}} <- state.tasks,
          not is_nil(outcome),
          do: key

    {:noreply, Enum.reduce(ready, state, &finish(&2, &1))}
  end

  def handle_info(message, state) do
    Logger.debug("voice detached tasks ignored #{inspect(message)}")
    {:noreply, state}
  end

  ## Adopting

  # The callbacks the adapter dispatches to on this route, the session's own
  # shape: each only forwards to this process.
  defp callbacks(owner, key) do
    forward = forward(owner, key)

    %{
      progress: fn text -> forward.({:progress, text}) end,
      activity: fn event -> forward.({:activity, event}) end,
      history_tainted: fn -> forward.(:history_tainted) end,
      result: fn result -> forward.({:result, result}) end
    }
  end

  defp forward(owner, key) do
    fn event ->
      send(owner, {:detached_event, key, event})
      :ok
    end
  end

  defp watch(state, session) do
    if Map.has_key?(state.sessions, session),
      do: state,
      else: %{state | sessions: Map.put(state.sessions, session, Process.monitor(session))}
  end

  defp track(state, key, task) do
    timer = Process.send_after(self(), {:wall_clock, key}, state.wall_clock_ms)

    task =
      Map.merge(task, %{
        adopted_ms: System.monotonic_time(:millisecond),
        timer: timer,
        stopping: nil,
        outcome: nil
      })

    %{state | tasks: Map.put(state.tasks, key, task)}
  end

  ## Stopping

  # A stop of the task's own turn and no other. Its outcome then arrives as
  # any other's, unless the turn was no longer in the queue.
  defp stop(state, task, why) do
    key = {task.call_uuid, task.task_id, task.revision}
    state = put_in(state.tasks[key].stopping, task.stopping || why)

    case stop_turn(task) do
      outcome when outcome in [:stopped, :dequeued, :claimed] -> :ok
      outcome when outcome in [:not_found, :queue_gone] -> send(self(), {:abandon, key})
    end

    state
  end

  # A queue that is gone took the turn with it; anything else is not caught.
  defp stop_turn(%{queue: queue} = task) do
    {:ok, outcome} = Queue.stop_turn(task.conversation_key, task.message_id, queue)
    outcome
  catch
    :exit, {reason, {GenServer, :call, [^queue, {:stop_turn, _key, _id}, :infinity]}} ->
      Logger.warning(
        "voice detached task #{task.message_id}: its queue is gone (#{inspect(reason)})"
      )

      :queue_gone
  end

  ## Ending

  defp task_end({:ok, reply}) when is_binary(reply), do: {:completed, reply}
  defp task_end({:error, sentence}) when is_binary(sentence), do: {:failed, sentence}
  defp task_end({:cancelled}), do: :cancelled

  # The first outcome of a task is the one kept. While the session that
  # handed it over lives, the record is still the session's, so the end is
  # held until it exits.
  defp ended(state, key, task_end) do
    case Map.fetch(state.tasks, key) do
      {:ok, %{outcome: nil} = task} -> hold_or_finish(state, key, task, task_end)
      _ended_or_gone -> state
    end
  end

  defp hold_or_finish(state, key, task, task_end) do
    state = put_in(state.tasks[key].outcome, stopped_end(task_end, task.stopping))

    if Map.has_key?(state.sessions, task.session), do: state, else: finish(state, key)
  end

  # A turn this process stopped for its wall clock ends `timed_out`, not
  # `cancelled`.
  defp stopped_end(:cancelled, :timed_out), do: :timed_out
  defp stopped_end(task_end, _stopping), do: task_end

  defp finish(state, key) do
    {task, tasks} = Map.pop!(state.tasks, key)
    Process.cancel_timer(task.timer)
    :ok = Registry.unregister(state.registry, route(task.call_uuid, task.task_id))

    {call, text} = CallRow.task_done(task.call_uuid, task.task_id, task.revision, task.outcome)
    shown = write_row(task, call, text) |> pushed(state)
    record_end(task, call["state"])
    emit_stop(task, call["state"], shown)

    %{state | tasks: tasks}
  end

  defp write_row(task, call, text) do
    case guarded(task, "row", fn -> Bridge.show(call, text) end) do
      {:ok, server_seq} ->
        %{server_seq: server_seq, bytes: byte_size(text)}

      {:error, reason} ->
        Logger.error(
          "voice detached task #{task.message_id}: its #{call["event"]} row was not " <>
            "written: #{inspect(reason)}"
        )

        nil
    end
  end

  # No one is on the call to hear it, so the phone is told, while its channel
  # runs.
  defp pushed(nil, _state), do: nil

  defp pushed(%{server_seq: server_seq} = shown, state) do
    if state.mobile_running?.(),
      do: Mobile.schedule_push(Companion.chat_profile(), server_seq)

    shown
  end

  defp record_end(task, task_state) do
    summary = summary(task.outcome)

    write = fn ->
      CallRecord.settle_task(
        task.call_uuid,
        task.task_id,
        task.revision,
        task_state,
        summary,
        task.record_opts
      )
    end

    case guarded(task, "record", write) do
      :ok -> :ok
      {:error, :disabled} -> :ok
      {:error, reason} -> log_record(task, reason)
    end
  end

  defp log_record(task, reason) do
    Logger.error(
      "voice detached task #{task.message_id}: its end was not recorded: #{inspect(reason)}"
    )
  end

  # The words the record keeps, as the session keeps them for a task that
  # ended on the call: a reply's line to say, a failure's sentence.
  defp summary({:completed, reply}) do
    {spoken, _shown} = LiveText.split(reply, @split_max_bytes)
    LiveText.summary(spoken, @summary_max_chars)
  end

  defp summary({:failed, sentence}), do: LiveText.summary(sentence, @summary_max_chars)
  defp summary(:cancelled), do: "cancelled"
  defp summary(:timed_out), do: "ran past its time limit"

  defp emit_stop(task, task_state, shown) do
    LiveTelemetry.detached_delegation_stop(
      %{session_id: task.call_id, call_uuid: task.call_uuid},
      %{
        delegation_id: task.task_id,
        revision: task.revision,
        turn_session_id: task.turn_session_id
      },
      task_state,
      task.elapsed_ms + System.monotonic_time(:millisecond) - task.adopted_ms,
      shown
    )
  end

  # A write is a call into the Repo, which exits when it times out or is
  # restarting: that is the write's failure, never this process's crash.
  defp guarded(task, what, fun) do
    fun.()
  catch
    :exit, reason ->
      Logger.error(
        "voice detached task #{task.message_id}: its #{what} write exited: " <>
          Exception.format(:exit, reason, __STACKTRACE__)
      )

      {:error, {:exit, reason}}
  end
end
