defmodule FermixCore.ComputerUse.Seat do
  @moduledoc """
  This computer's screen while Fermix on its server drives it (M97 §6.4,
  §7.4), on the computer. The session that decides what to do next, its
  action budget, its images and its pause live on the server
  (`ComputerUse.Session`, whose driver is `ComputerDriver`); what must be
  decided where the person and the screen are lives here, in one process:

    * **who holds the screen.** One server session at a time (its `cua_` id,
      the seat). Another is refused `busy` while one holds it; a holder that
      sent nothing for #{div(120_000, 1_000)} seconds lets go (`idle`), so a
      server that went away never leaves the screen held.
    * **the helper.** The holder's driver is started here, so this process is
      its owner: the helper's exit, and its own on-screen Stop, arrive here.
      Each action runs in the invocation's own process with the handle
      `acquire/2` answers; this process never waits on an action.
    * **the person's Stop.** `stop/1` (the app's mark, through
      `computer.screen.stop`), the helper's own Stop button, and this
      computer's master or `computer_use` switch going off (told as the
      switches' third listener, `Computers.Switches.screen_listener/0`) end
      the seat at once: held input is released, the helper stopped, the
      server's watch answered (`watch/2`), and that seat refused from then on
      (`acquire/2`'s `:stopped`), so the server hears `stopped_here`.
    * **the mark.** `view/1` is what the app draws while the server holds
      the screen (`home.status`'s `screen`), and every change tells the app
      (`:changed`, the Always On watch by default).
    * **the record.** Each stretch the server held the screen is written for
      the computer-history recorder (`ServerControl`).

  Seams: `:name`, `:driver` (0-arity, the driver spec or an error,
  `ComputerUse.driver_spec/0`), `:config` (0-arity, this computer's computer
  use config, whose courtesy the actions follow), `:switches` (0-arity),
  `:home`, `:clock` (0-arity wall clock), `:timer` (2-arity
  `Process.send_after/3` to this process), `:changed` (0-arity) and
  `:idle_lapse_ms`.
  """

  use GenServer

  require Logger

  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.Capabilities
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Courtesy
  alias FermixCore.ComputerUse.ServerControl
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Setup.ConfigStore

  @idle_lapse_ms 120_000
  @release_budget_ms 1_000
  # The seats the person stopped that are still refused: the newest few, so a
  # server that asks again for one it held is told, and the record stays small.
  @max_stopped 16

  @typedoc "Why the server let go of the screen (`ServerControl.why/0`)."
  @type why :: ServerControl.why()

  @typedoc "What an action needs from the seat it runs under."
  @type held :: %{
          driver: {module(), term()},
          capabilities: map(),
          config: Config.t(),
          last_action_at: integer() | :never
        }

  @doc "The name this computer's seat runs under: the switches' screen listener."
  @spec name() :: atom()
  def name, do: Switches.screen_listener()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, name()))

  @doc """
  The screen for `seat`, taken if no other seat holds it: the helper is
  started on the first one. `:stopped` once the person stopped that seat,
  `{:busy, since}` while another holds it, `{:helper, reason}` when the
  helper would not start. Each call counts as activity for the idle lapse.
  """
  @spec acquire(GenServer.server(), String.t()) ::
          {:ok, held()} | {:error, :stopped | {:busy, DateTime.t()} | {:helper, term()}}
  def acquire(server \\ Switches.screen_listener(), seat) when is_binary(seat),
    do: GenServer.call(server, {:acquire, seat}, 30_000)

  @doc "The held seat's driver, for a control: never starts a helper."
  @spec driver(GenServer.server(), String.t()) :: {:ok, {module(), term()}} | :none
  def driver(server \\ Switches.screen_listener(), seat) when is_binary(seat),
    do: GenServer.call(server, {:driver, seat})

  @doc "Records that `seat` just sent `action`: a disturbing one stamps the time."
  @spec acted(GenServer.server(), String.t(), String.t()) :: :ok
  def acted(server \\ Switches.screen_listener(), seat, action)
      when is_binary(seat) and is_binary(action),
      do: GenServer.cast(server, {:acted, seat, action, System.monotonic_time(:millisecond)})

  @doc """
  Waits until `seat` lets go of the screen and answers why. Answered at once
  when it does not hold it: `:stopped` for a seat the person stopped, else
  `:closed`.
  """
  @spec watch(GenServer.server(), String.t()) :: why()
  def watch(server \\ Switches.screen_listener(), seat) when is_binary(seat),
    do: GenServer.call(server, {:watch, seat}, :infinity)

  @doc "The server let go of `seat`'s screen, or of the screen the watch run `pid` waits on."
  @spec close(GenServer.server(), String.t() | pid(), why()) :: :ok
  def close(server \\ Switches.screen_listener(), seat_or_watcher, why \\ :closed)
      when (is_binary(seat_or_watcher) or is_pid(seat_or_watcher)) and
             why in [:closed, :helper_exited],
      do: GenServer.call(server, {:close, seat_or_watcher, why})

  @doc """
  Where `seat` stands: `:held` while it holds the screen, `:stopped` once the
  person stopped it or its switch went off, `:gone` otherwise.
  """
  @spec watch_state(GenServer.server(), String.t()) :: :held | :stopped | :gone
  def watch_state(server \\ Switches.screen_listener(), seat) when is_binary(seat),
    do: GenServer.call(server, {:watch_state, seat})

  @doc "The person at this computer stopped the server's use of its screen."
  @spec stop(GenServer.server()) :: :stopped | :none
  def stop(server \\ Switches.screen_listener()), do: GenServer.call(server, :stop)

  @doc """
  What the app draws (`home.status`'s `screen`): `%{since}` while the server
  holds this screen, nil otherwise, and nil where no seat runs.
  """
  @spec view(GenServer.server()) :: %{since: DateTime.t()} | nil
  def view(server \\ Switches.screen_listener()) do
    GenServer.call(server, :view)
  catch
    :exit, {:noproc, _call} -> nil
  end

  @impl true
  def init(opts) do
    # So a shutdown runs `terminate/2`, which releases the helper the server drove.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       driver: Keyword.get(opts, :driver, &ComputerUse.driver_spec/0),
       config: Keyword.get(opts, :config, &Config.current/0),
       switches: Keyword.get(opts, :switches, &Switches.current/0),
       home: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
       changed: Keyword.get(opts, :changed, fn -> StatusWatch.changed(:screen) end),
       idle_lapse_ms: Keyword.get(opts, :idle_lapse_ms, @idle_lapse_ms),
       held: nil,
       stopped: []
     }}
  end

  @impl true
  def handle_call({:acquire, seat}, _from, state) do
    cond do
      seat in state.stopped -> {:reply, {:error, :stopped}, state}
      match?(%{seat: ^seat}, state.held) -> reply_held(touched(state))
      state.held != nil -> {:reply, {:error, {:busy, state.held.since}}, state}
      true -> take(seat, state)
    end
  end

  def handle_call({:driver, seat}, _from, %{held: %{seat: seat} = held} = state),
    do: {:reply, {:ok, held.driver}, state}

  def handle_call({:driver, _seat}, _from, state), do: {:reply, :none, state}

  def handle_call({:watch, seat}, {pid, _tag} = from, %{held: %{seat: seat} = held} = state) do
    _ref = Process.monitor(pid)
    {:noreply, %{state | held: %{held | watchers: [{pid, from} | held.watchers]}}}
  end

  def handle_call({:watch, seat}, _from, state),
    do: {:reply, if(seat in state.stopped, do: :stopped, else: :closed), state}

  def handle_call({:close, seat_or_watcher, why}, _from, state) do
    if holds?(state.held, seat_or_watcher),
      do: {:reply, :ok, ended(state, why)},
      else: {:reply, :ok, state}
  end

  def handle_call({:watch_state, seat}, _from, state) do
    cond do
      match?(%{seat: ^seat}, state.held) -> {:reply, :held, state}
      seat in state.stopped -> {:reply, :stopped, state}
      true -> {:reply, :gone, state}
    end
  end

  def handle_call(:stop, _from, %{held: nil} = state), do: {:reply, :none, state}
  def handle_call(:stop, _from, state), do: {:reply, :stopped, ended(state, :stopped)}

  def handle_call(:view, _from, %{held: nil} = state), do: {:reply, nil, state}
  def handle_call(:view, _from, %{held: held} = state), do: {:reply, %{since: held.since}, state}

  @impl true
  def handle_cast({:acted, seat, action, at}, %{held: %{seat: seat} = held} = state) do
    if Courtesy.disturbing?(action),
      do: {:noreply, %{state | held: %{held | last_action_at: at}}},
      else: {:noreply, state}
  end

  def handle_cast({:acted, _seat, _action, _at}, state), do: {:noreply, state}

  # The master or the screen switch went off: the server's use ends at once.
  def handle_cast(:switches_changed, %{held: nil} = state), do: {:noreply, state}

  def handle_cast(:switches_changed, state) do
    if Switches.on?(state.switches.(), :computer_use),
      do: {:noreply, state},
      else: {:noreply, ended(state, :switched_off)}
  end

  @impl true
  def handle_info({:lapse, ref}, %{held: %{lapse: ref}} = state),
    do: {:noreply, ended(state, :idle)}

  def handle_info({:lapse, _stale}, state), do: {:noreply, state}

  # The helper ended: nothing more can run under this seat.
  def handle_info({:compux_sidecar_exit, _transport, status}, %{held: %{}} = state) do
    Logger.warning("computer_use: the helper the server drove ended (#{inspect(status)})")
    {:noreply, ended(state, :helper_exited, released?: true)}
  end

  # The helper's own on-screen Stop, which it has applied to its gate already.
  def handle_info(
        {:compux_session_event, _transport, %{"kind" => "indicator", "event" => "operator_stop"}},
        %{held: %{}} = state
      ),
      do: {:noreply, ended(state, :stopped)}

  # A watcher that went away waits on nothing.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{held: %{} = held} = state) do
    watchers = Enum.reject(held.watchers, fn {watcher, _from} -> watcher == pid end)
    {:noreply, %{state | held: %{held | watchers: watchers}}}
  end

  def handle_info(message, state) do
    Logger.debug("computer_use: the screen seat ignores #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{held: nil}), do: :ok

  def terminate(_reason, state) do
    _state = ended(state, :closed)
    :ok
  end

  # -- holding -------------------------------------------------------------------

  defp take(seat, state) do
    with {:ok, {mod, opts}} <- state.driver.(),
         {:ok, driver_state} <- mod.start(Keyword.put_new(opts, :session_id, seat)) do
      at = state.clock.()

      held = %{
        seat: seat,
        driver: {mod, driver_state},
        capabilities: helper_reading(mod, driver_state),
        since: at,
        last_action_at: :never,
        lapse: nil,
        watchers: []
      }

      record(ServerControl.started(state.home, seat, at))
      state.changed.()
      reply_held(touched(%{state | held: held}))
    else
      {:error, reason} -> {:reply, {:error, {:helper, reason}}, state}
    end
  end

  defp reply_held(%{held: held} = state) do
    {:reply,
     {:ok,
      %{
        driver: held.driver,
        capabilities: held.capabilities,
        config: state.config.(),
        last_action_at: held.last_action_at
      }}, state}
  end

  # Each request counts as activity: the idle lapse starts again.
  defp touched(%{held: held} = state) do
    ref = make_ref()
    _timer = state.timer.({:lapse, ref}, state.idle_lapse_ms)
    %{state | held: %{held | lapse: ref}}
  end

  defp holds?(%{seat: seat}, seat), do: true

  defp holds?(%{watchers: watchers}, pid) when is_pid(pid),
    do: Enum.any?(watchers, fn {watcher, _from} -> watcher == pid end)

  defp holds?(_held, _seat_or_watcher), do: false

  # The courtesy step reads the helper's input methods (`Courtesy.ax_addressed?/2`).
  defp helper_reading(mod, driver_state) do
    case Capabilities.hello(mod, driver_state) do
      {:ok, capabilities} -> capabilities
      {:error, _reason} -> Capabilities.none()
    end
  end

  # -- letting go ----------------------------------------------------------------

  defp ended(state, why, opts \\ []) do
    held = state.held
    :ok = release_and_stop(held.driver, Keyword.get(opts, :released?, false))

    for {_pid, from} <- held.watchers, do: GenServer.reply(from, why)
    record(ServerControl.ended(state.home, held.seat, state.clock.(), why))
    state = %{state | held: nil, stopped: stopped(state.stopped, held.seat, why)}
    state.changed.()
    state
  end

  defp stopped(stopped, seat, why) when why in [:stopped, :switched_off],
    do: Enum.take([seat | stopped], @max_stopped)

  defp stopped(stopped, _seat, _why), do: stopped

  # Held input released first, bounded, in an unlinked process: the stop that
  # follows kills the helper, which runs none of its own release guards
  # (`Session`'s teardown, for the same reason). Then the helper is stopped.
  defp release_and_stop({mod, driver_state}, released?) do
    if not released? and function_exported?(mod, :control, 2), do: release(mod, driver_state)
    mod.stop(driver_state)
  end

  defp release(mod, driver_state) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:released, self(), mod.control(driver_state, :release)})
      end)

    receive do
      {:released, ^pid, _result} ->
        Process.demonitor(ref, [:flush])

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning("computer_use: held input was not released (#{inspect(reason)})")
    after
      @release_budget_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        Logger.warning("computer_use: held input was not released in time")
    end
  end

  defp record(:ok), do: :ok

  defp record({:error, reason}),
    do:
      Logger.warning(
        "computer_use: the screen control record was not written: #{inspect(reason)}"
      )
end
