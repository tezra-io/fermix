defmodule FermixCore.Home.ServerRestart do
  @moduledoc """
  `home.restart` on the server (M97 D28c, §19.6): a linked computer's
  Restart <server>, which `home.act`'s `restart_server` sends over the link.
  The server takes it as `fermix restart` would there, after its restart
  hold (`Home.RestartHold`, M97 §3.4 rule 6):

    * nothing holds it: it restarts right after it answers (`when` `now`);
    * work in progress on a computer: it answers at once that it waits
      (`when` `after_work`, `wait_s`, the hold's own sentence), reads the
      hold again every 5 seconds, and restarts once nothing holds it, the
      hold's own wait has run out (the oldest work ran ten minutes), or 10
      minutes passed since the request, whichever comes first. Work that
      starts while it waits holds it too, within those 10 minutes. One
      waiter at a time: a request while one waits is a look of its own with
      the hold it read, so it restarts now once nothing holds it any more,
      and otherwise answers the same wait, `wait_s` the live hold's, never
      past the request's 10 minutes;
    * a move under way: refused, `unavailable` with the hold's sentence. A
      move that starts while it waits ends the wait without a restart: the
      move restarts the engine itself, and a restart mid-move would undo it;
    * Fermix run from a terminal, which nothing starts again
      (`Lifecycle.restarts_itself?/1`): refused, since the stop would be the
      end there.

  **Nothing it is given can stop it.** It is an early child of the engine's
  `:rest_for_one` root, so a raise here would restart every child after it,
  the daemon socket among them, and forget the wait a computer was told of.
  A request's hold is read in the caller, before the call. A look's hold is
  read in a task of its own (`:task_supervisor`), its answer matched: a read
  that raises, exits, takes past 10 seconds or answers no hold is a hold that
  still holds,
  said in the log once when the reads start failing and once when one reads
  again, and the 10 minutes still end the wait. The waiter never blocks on a
  read, so it answers a request at once.

  **One mechanism.** The restart is the world's `restart` (by default
  `Management.Lifecycle.restart_self/0`, as `Management.Home.restart/1`
  gives it): the daemon's one stop path, answer first and then stop, which
  the service manager brings back (every unit Fermix installs runs with
  `Restart=always` or launchd's `KeepAlive`), with a systemd user unit's
  start budget reset first, so restarts asked from an app never spend the
  starts a crash loop is held to. It is the restart a move, a join and
  Restore here already take; `lifecycle.commit`'s stopper is the same stop
  without that reset.

  Seams, at start: `:name`, `:now_ms` (0-arity, a monotonic clock in
  milliseconds), `:timer` (2-arity, given the message and the delay, as
  `Process.send_after/3` to this process) and `:task_supervisor` (where a
  look's read runs). Each request brings its world: `hold` (0-arity: the
  hold now, `RestartHold.hold()` or nil), `restart` (0-arity) and
  `restarts_itself` (a boolean).
  """

  use GenServer

  alias FermixCore.Home.RestartHold

  require Logger

  @capability "home"
  @tick_ms 5_000
  @call_ms 5_000
  # The longest one look's read may take: the hold asks the computers' calls
  # within 5 s and reads the move's files.
  @read_ms 10_000
  # The longest a request waits, from the request, and so the most looks it
  # takes: the hold's own bound (`RestartHold.max_wait_s/0`).
  @max_wait_ms RestartHold.max_wait_s() * 1_000
  @max_ticks div(@max_wait_ms, @tick_ms) + 1

  @now_sentence "Fermix on your server restarts now, with the changes that waited for it."
  @terminal_sentence "Fermix on your server runs from a terminal, so nothing would start it " <>
                       "again. Restart it there."
  @not_running_sentence "Fermix on your server cannot be restarted from here right now. Its " <>
                          "log says why."

  @typedoc "What a request brings: the hold now, the restart, and whether it comes back."
  @type world :: %{
          hold: (-> RestartHold.hold() | nil),
          restart: (-> :ok),
          restarts_itself: boolean()
        }

  @type answer :: {:ok, map()} | {:error, {:unavailable, String.t(), String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Every sentence its answers and refusals say of their own, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@now_sentence, @terminal_sentence, @not_running_sentence]

  @doc "Takes one `home.restart` in `server`, as the moduledoc says; the hold is read here."
  @spec request(GenServer.server(), world()) :: answer()
  def request(server, %{hold: hold, restart: restart, restarts_itself: restarts?} = world)
      when is_function(hold, 0) and is_function(restart, 0) and is_boolean(restarts?) do
    cond do
      GenServer.whereis(server) == nil ->
        Logger.error("home restart: no waiter runs here, so a computer's restart was refused")
        unavailable(@not_running_sentence)

      not restarts? ->
        Logger.warning("home restart: refused, since nothing would start Fermix again here")
        unavailable(@terminal_sentence)

      true ->
        GenServer.call(server, {:request, world, hold!(hold.())}, @call_ms)
    end
  end

  # What a hold must be before the waiter decides on it: a caller's hold that
  # is not one fails loud in the caller.
  defp hold!(hold) do
    case checked(hold) do
      {:ok, hold} ->
        hold

      {:error, {:not_a_hold, other}} ->
        raise ArgumentError, "not a restart hold: #{inspect(other)}"
    end
  end

  defp checked(nil), do: {:ok, nil}

  defp checked(%{reason: reason, count: count, wait_s: wait_s, sentence: sentence} = hold)
       when reason in [:move, :computer_work] and is_integer(count) and count >= 0 and
              is_integer(wait_s) and wait_s >= 0 and is_binary(sentence),
       do: {:ok, hold}

  defp checked(other), do: {:error, {:not_a_hold, other}}

  @impl true
  def init(opts) do
    {:ok,
     %{
       now_ms: Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end),
       timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
       waiting: nil,
       unread: nil
     }}
  end

  @impl true
  def handle_call({:request, world, hold}, _from, %{waiting: nil} = state) do
    {answer, waiting} = decide(world, hold, state)
    {:reply, answer, %{state | waiting: waiting}}
  end

  def handle_call({:request, _world, hold}, _from, %{waiting: waiting} = state) do
    state = said_read({:ok, hold}, state)

    case again(hold, waiting, state) do
      {answer, nil} -> {:reply, answer, unwaited(state)}
      {answer, waiting} -> {:reply, answer, %{state | waiting: waiting}}
    end
  end

  @impl true
  def handle_info({:restart_tick, token}, %{waiting: %{token: token} = waiting} = state),
    do: {:noreply, %{state | waiting: read(waiting, state)}}

  def handle_info({:restart_tick, _stale}, state), do: {:noreply, state}

  def handle_info({ref, hold}, %{waiting: %{reading: %Task{ref: ref}} = waiting} = state) do
    Process.demonitor(ref, [:flush])
    looked(%{waiting | reading: nil}, checked(hold), state)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{waiting: %{reading: %Task{ref: ref}} = waiting} = state
      ),
      do: looked(%{waiting | reading: nil}, {:error, reason}, state)

  def handle_info({:hold_read_late, ref}, %{waiting: %{reading: %Task{ref: ref} = task}} = state) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, hold} -> looked(%{state.waiting | reading: nil}, checked(hold), state)
      _late -> looked(%{state.waiting | reading: nil}, {:error, :read_timed_out}, state)
    end
  end

  # A late mark, a reply or an exit of a read this waiter no longer waits on.
  def handle_info({:hold_read_late, _stale}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({ref, _hold}, state) when is_reference(ref), do: {:noreply, state}

  # -- the decision ------------------------------------------------------------

  defp decide(world, hold, state) do
    case hold do
      nil -> {restart_now(world, "nothing holds it"), nil}
      %{reason: :move, sentence: said} -> {unavailable(said), nil}
      %{reason: :computer_work, wait_s: 0} -> {restart_now(world, "its hold ran out"), nil}
      %{reason: :computer_work} -> wait(world, hold, state)
    end
  end

  defp wait(world, %{wait_s: wait_s, count: count} = hold, state) do
    Logger.info("home restart: waits for the work on a computer (#{count}), #{wait_s} s at most")
    deadline = state.now_ms.() + @max_wait_ms
    waiting = arm(%{world: world, deadline: deadline, ticks: 0, reading: nil}, state)
    {waits(hold, waiting, state), waiting}
  end

  # A request while one waits: a look with the hold its caller read.
  defp again(hold, waiting, state) do
    case judge({:ok, hold}, waiting, state) do
      :move -> {unavailable(hold.sentence), ended(waiting)}
      :done -> {restart_now(waiting.world, "nothing holds it any more"), ended(waiting)}
      :wait -> {waits(hold, waiting, state), waiting}
    end
  end

  defp restart_now(world, why) do
    Logger.info("home restart: restarting now, as a computer asked (#{why})")

    case world.restart.() do
      :ok ->
        :ok

      other ->
        Logger.error("home restart: the restart answered #{inspect(other)}, not :ok")
    end

    {:ok, %{"when" => "now", "wait_s" => 0, "sentence" => @now_sentence}}
  end

  # The live hold's wait, never past the request's ten minutes.
  defp waits(%{wait_s: wait_s, sentence: said}, waiting, state) do
    left = max(div(waiting.deadline - state.now_ms.(), 1_000), 0)
    {:ok, %{"when" => "after_work", "wait_s" => min(wait_s, left), "sentence" => said}}
  end

  # -- the looks ---------------------------------------------------------------

  defp read(waiting, state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, waiting.world.hold)
    _timer = state.timer.({:hold_read_late, task.ref}, @read_ms)
    %{waiting | reading: task}
  end

  defp looked(waiting, result, state) do
    state = said_read(result, state)

    case judge(result, waiting, state) do
      :move ->
        Logger.info("home restart: a move started while it waited, and restarts Fermix itself")
        {:noreply, unwaited(state)}

      :done ->
        _answer = restart_now(waiting.world, "the work it waited for ended or ran out of time")
        {:noreply, unwaited(state)}

      :wait ->
        {:noreply, %{state | waiting: arm(waiting, state)}}
    end
  end

  # A read that failed is a hold that still holds: only the clock ends it.
  defp judge({:ok, %{reason: :move}}, _waiting, _state), do: :move
  defp judge({:ok, nil}, _waiting, _state), do: :done
  defp judge({:ok, %{wait_s: 0}}, _waiting, _state), do: :done
  defp judge(_held, waiting, state), do: if(timed_out?(waiting, state), do: :done, else: :wait)

  defp timed_out?(waiting, state),
    do: waiting.ticks >= @max_ticks or state.now_ms.() >= waiting.deadline

  # Said once when the reads start failing, and once when one reads again.
  defp said_read({:error, reason}, %{unread: nil} = state) do
    Logger.error(
      "home restart: the restart hold could not be read (#{inspect(reason)}), so it still " <>
        "waits as held; it looks again in #{div(@tick_ms, 1_000)} s"
    )

    %{state | unread: reason}
  end

  defp said_read({:error, _reason}, state), do: state
  defp said_read({:ok, _hold}, %{unread: nil} = state), do: state

  defp said_read({:ok, _hold}, state) do
    Logger.warning("home restart: the restart hold reads again")
    %{state | unread: nil}
  end

  # The wait is over; reads that were failing end with it, and are said to.
  defp unwaited(%{unread: nil} = state), do: %{state | waiting: nil}

  defp unwaited(state) do
    Logger.warning("home restart: the wait ended while the restart hold could not be read")
    %{state | waiting: nil, unread: nil}
  end

  defp arm(waiting, state) do
    token = make_ref()
    _timer = state.timer.({:restart_tick, token}, @tick_ms)
    waiting |> Map.put(:token, token) |> Map.update!(:ticks, &(&1 + 1))
  end

  # A wait a request ended while a look's read ran: that read is shut down.
  defp ended(%{reading: %Task{} = task}) do
    _result = Task.shutdown(task, :brutal_kill)
    nil
  end

  defp ended(_waiting), do: nil

  defp unavailable(sentence), do: {:error, {:unavailable, @capability, sentence}}
end
