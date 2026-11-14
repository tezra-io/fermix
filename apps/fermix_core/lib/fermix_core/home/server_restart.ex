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
      hold's own wait has run out, or 10 minutes passed since the request,
      whichever comes first. One waiter at a time: a request while one waits
      answers the same wait;
    * a move under way: refused, `unavailable` with the hold's sentence. A
      move that starts while it waits ends the wait without a restart: the
      move restarts the engine itself, and a restart mid-move would undo it;
    * Fermix run from a terminal, which nothing starts again
      (`Lifecycle.restarts_itself?/1`): refused, since the stop would be the
      end there.

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
  milliseconds) and `:timer` (2-arity, given the message and the delay, as
  `Process.send_after/3` to this process). Each request brings its world:
  `hold` (0-arity: the hold now, `RestartHold.hold()` or nil), `restart`
  (0-arity) and `restarts_itself` (a boolean).
  """

  use GenServer

  alias FermixCore.Home.RestartHold

  require Logger

  @capability "home"
  @tick_ms 5_000
  @call_ms 5_000
  # The longest a request waits, and so the most looks it takes: the hold's
  # own bound (`RestartHold.max_wait_s/0`).
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

  @doc "Takes one `home.restart` in `server`, as the moduledoc says."
  @spec request(GenServer.server(), world()) :: answer()
  def request(server, %{hold: hold, restart: restart, restarts_itself: restarts?} = world)
      when is_function(hold, 0) and is_function(restart, 0) and is_boolean(restarts?) do
    if GenServer.whereis(server) do
      GenServer.call(server, {:request, world}, @call_ms)
    else
      Logger.error("home restart: no waiter runs here, so a computer's restart was refused")
      unavailable(@not_running_sentence)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       now_ms: Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end),
       timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
       waiting: nil
     }}
  end

  @impl true
  def handle_call({:request, world}, _from, %{waiting: nil} = state) do
    {answer, waiting} = decide(world, state)
    {:reply, answer, %{state | waiting: waiting}}
  end

  def handle_call({:request, _world}, _from, %{waiting: waiting} = state),
    do: {:reply, waits(waiting, state), state}

  @impl true
  def handle_info({:restart_tick, token}, %{waiting: %{token: token} = waiting} = state),
    do: {:noreply, %{state | waiting: look(waiting, state)}}

  def handle_info({:restart_tick, _stale}, state), do: {:noreply, state}

  # -- the decision ------------------------------------------------------------

  defp decide(%{restarts_itself: false}, _state) do
    Logger.warning("home restart: refused, since nothing would start Fermix again here")
    {unavailable(@terminal_sentence), nil}
  end

  defp decide(world, state) do
    case world.hold.() do
      nil -> {restart_now(world, "nothing holds it"), nil}
      %{reason: :move, sentence: said} -> {unavailable(said), nil}
      %{reason: :computer_work, wait_s: 0} -> {restart_now(world, "its hold ran out"), nil}
      %{reason: :computer_work} = hold -> wait(world, hold, state)
    end
  end

  defp restart_now(world, why) do
    Logger.info("home restart: restarting now, as a computer asked (#{why})")
    :ok = world.restart.()
    {:ok, %{"when" => "now", "wait_s" => 0, "sentence" => @now_sentence}}
  end

  defp wait(world, %{wait_s: wait_s, sentence: said, count: count}, state) do
    Logger.info("home restart: waits for the work on a computer (#{count}), #{wait_s} s at most")
    deadline = state.now_ms.() + min(wait_s * 1_000, @max_wait_ms)
    waiting = arm(%{world: world, deadline: deadline, sentence: said, ticks: 0}, state)
    {waits(waiting, state), waiting}
  end

  defp waits(waiting, state) do
    left = max(div(waiting.deadline - state.now_ms.(), 1_000), 0)
    {:ok, %{"when" => "after_work", "wait_s" => left, "sentence" => waiting.sentence}}
  end

  # -- the looks ---------------------------------------------------------------

  defp look(waiting, state) do
    hold = waiting.world.hold.()

    cond do
      match?(%{reason: :move}, hold) ->
        Logger.info("home restart: a move started while it waited, and restarts Fermix itself")
        nil

      done?(hold, waiting, state) ->
        _answer = restart_now(waiting.world, "the work it waited for ended or ran out of time")
        nil

      true ->
        arm(waiting, state)
    end
  end

  defp done?(hold, waiting, state) do
    hold == nil or hold.wait_s == 0 or waiting.ticks >= @max_ticks or
      state.now_ms.() >= waiting.deadline
  end

  defp arm(waiting, state) do
    token = make_ref()
    _timer = state.timer.({:restart_tick, token}, @tick_ms)
    waiting |> Map.put(:token, token) |> Map.update!(:ticks, &(&1 + 1))
  end

  defp unavailable(sentence), do: {:error, {:unavailable, @capability, sentence}}
end
