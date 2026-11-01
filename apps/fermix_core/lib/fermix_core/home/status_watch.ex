defmodule FermixCore.Home.StatusWatch do
  @moduledoc """
  Tells the apps when Always On changed, so they never poll it (companion
  protocol 6, M75 lean v1 §7).

  The apps draw Always On from `home.status`'s summary
  (`FermixCore.Management.HomeSummary`). This process reads that summary only
  when something it rests on happens, and tells each subscriber
  `:home_status_changed` when its key (`HomeSummary.watch/1`) moved; a
  subscriber (a version 6 companion connection, `Companion.Connection`, or a
  desktop's tunnel, `Desktop.Tunnel`) then writes `home_status_changed`, and
  the app reads `home.status` itself.

  **When it reads.** On `changed/2` from the writes that feed the summary:
  `:ledger` (the provisioner's file, `Provision.Ledger.update/3`), `:move`
  (a move's phase, `Move.put_phase/4`), `:enrollment` (the enrollment window
  opened, used, enrolled, withdrawn or expired, `FermixChannels.Home.Enrollment`),
  `:snapshots` (a backup run finished,
  `Snapshot.Scheduler`), `:link` (the desktop's session to its server up or
  down, `FermixChannels.Desktop.Relay`) and `:server` (a desktop's tunnel
  heard its server's own notice, so the server's part of `home.status` may
  have moved). Then at the summary's next change by the clock alone
  (`next_change_ms`), on one timer, replaced at each read and never sooner
  than a second; and when the runtime's time offset moves (`:clock`: a wake
  from sleep, since the monotonic clock its timers count stops while the
  computer sleeps, which is right for the awake-time rules and late for the
  time-of-day ones). Events that arrive together are one read.

  **Only while someone listens.** With no subscriber it reads nothing and
  arms nothing; the first subscriber's arrival reads the summary and is told
  at once unless Always On is off, and a later one is told from the last
  read. When the last subscriber goes, the timer is cancelled and the last
  read forgotten.

  **Off is quiet.** An app forgets Always On while it is off (the owner's
  rule): an `off` summary has one key (`HomeSummary.watch/1`), so nothing is
  told while it stays off, a settings write that changes the line naming what
  stops included (no write of settings tells this process at all; the app
  reads that line when its pane opens). Nothing is armed, and only an event
  that could end `off` is read (`:ledger`, `:enrollment`, `:move`); a backup
  run, the link and the clock are not. Entering `off` from another state is a
  change, told once.

  It never calls the cloud provider: the provider is read by a job of its
  family (a step, or the reconcile a stale `home.status` read starts), and
  every write of its ledger
  (`Provision.Ledger.update/3`, through which `Provision.Driver` and the
  management family write) tells the watch `:ledger`. A read that fails is logged;
  the last read stands, with no deadline until the next read.

  It runs beside the companion socket (`FermixChannels.Companion.Supervisor`),
  before its connections, so a restart of this process, which forgets its
  subscribers, takes the connections down with it and they subscribe again.
  `changed/2` and `subscribe/2` to a watch that does not run (a test tree, a
  verb with no engine) do nothing.

  Seams: `:read` (a 0-arity function answering `HomeSummary.watch/1`'s map;
  by default the summary's facts gathered as `home.status` gathers them,
  through the server on a linked desktop, decided once at start as the
  daemon decides its forwarding), `:timer` (a 2-arity `Process.send_after/3`
  to this process, given the message and the delay), `:cancel_timer` and
  `:clock_monitor` (false: no time-offset monitor).
  """

  use GenServer

  require Logger

  alias FermixCore.Home.Link
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary

  @kinds [:ledger, :move, :enrollment, :snapshots, :link, :server]
  # While Always On is off, only these can end it.
  @off_wakes [:ledger, :move, :enrollment]
  @min_delay_ms 1_000
  # Within the runtime's timer bound; a deadline further off is looked at
  # again then.
  @max_delay_ms 7 * 86_400_000

  @type kind :: :ledger | :move | :enrollment | :snapshots | :link | :server
  @type read :: %{key: term(), off: boolean(), next_change_ms: pos_integer() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Something the summary rests on changed: read it again if anyone listens."
  @spec changed(GenServer.server(), kind()) :: :ok
  def changed(server \\ __MODULE__, kind) when kind in @kinds,
    do: GenServer.cast(server, {:changed, kind})

  @doc """
  `pid` is told `:home_status_changed` at once unless Always On is off, and
  at each change after, until it exits.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server \\ __MODULE__, pid) when is_pid(pid),
    do: GenServer.cast(server, {:subscribe, pid})

  @impl true
  def init(opts) do
    if Keyword.get(opts, :clock_monitor, true),
      do: _ref = :erlang.monitor(:time_offset, :clock_service)

    {:ok,
     %{
       read: Keyword.get_lazy(opts, :read, &default_read/0),
       timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
       cancel_timer: Keyword.get(opts, :cancel_timer, &Process.cancel_timer/1),
       subscribers: %{},
       last: nil,
       deadline: nil,
       pending: false
     }}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    if Map.has_key?(state.subscribers, pid),
      do: {:noreply, state},
      else: {:noreply, join(pid, state)}
  end

  def handle_cast({:changed, kind}, state), do: {:noreply, wake(kind, state)}

  @impl true
  def handle_info(:read, state), do: {:noreply, reread(%{state | pending: false})}

  def handle_info({:deadline, token}, %{deadline: {token, _timer}} = state),
    do: {:noreply, reread(%{state | deadline: nil})}

  # A deadline another read replaced.
  def handle_info({:deadline, _token}, state), do: {:noreply, state}

  def handle_info({:CHANGE, _ref, :time_offset, :clock_service, _offset}, state),
    do: {:noreply, wake(:clock, state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, leave(pid, state)}

  # -- subscribers ---------------------------------------------------------------

  # The first subscriber reads; a later one is told from the last read.
  defp join(pid, state) do
    state = %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
    state = if state.last, do: state, else: first_read(state)
    if told?(state.last), do: send(pid, :home_status_changed)
    state
  end

  defp leave(pid, state) do
    subscribers = Map.delete(state.subscribers, pid)

    if subscribers == %{},
      do: %{disarm(state) | subscribers: subscribers, last: nil},
      else: %{state | subscribers: subscribers}
  end

  defp told?(%{off: off}), do: not off
  defp told?(nil), do: false

  # -- reading -------------------------------------------------------------------

  # Events that arrive together are one read: the read is queued behind them.
  defp wake(_kind, %{subscribers: subscribers} = state) when subscribers == %{}, do: state
  defp wake(_kind, %{pending: true} = state), do: state
  defp wake(kind, %{last: %{off: true}} = state) when kind not in @off_wakes, do: state

  defp wake(_kind, state) do
    send(self(), :read)
    %{state | pending: true}
  end

  defp first_read(state) do
    case read(state) do
      nil -> state
      read -> arm(read, %{state | last: read})
    end
  end

  # A read that fails leaves the last one standing, with no deadline until
  # the next read.
  defp reread(%{subscribers: subscribers} = state) when subscribers == %{}, do: state

  defp reread(state) do
    case read(state) do
      nil -> disarm(state)
      read -> arm(read, tell(state, read))
    end
  end

  # A subscriber that has heard nothing yet is told as at its arrival.
  defp tell(%{last: last} = state, read) do
    changed = if last, do: last.key != read.key, else: told?(read)
    if changed, do: Enum.each(Map.keys(state.subscribers), &send(&1, :home_status_changed))
    %{state | last: read}
  end

  # A read is the map `HomeSummary.watch/1` answers; anything else is a fault
  # of the read, logged.
  defp read(state) do
    case state.read.() do
      %{key: _key, off: off, next_change_ms: next} = read
      when is_boolean(off) and (next == nil or (is_integer(next) and next > 0)) ->
        read

      other ->
        unread(inspect(other))
    end
  rescue
    exception -> unread(Exception.format(:error, exception, __STACKTRACE__))
  catch
    :exit, reason -> unread(inspect(reason))
  end

  defp unread(why) do
    Logger.error("home status watch: the Always On status could not be read: #{why}")
    nil
  end

  # -- the one timer -------------------------------------------------------------

  # Armed afresh at each read; nothing while Always On is off.
  defp arm(read, state) do
    state = disarm(state)

    case read do
      %{off: false, next_change_ms: ms} when is_integer(ms) ->
        token = make_ref()
        delay = ms |> max(@min_delay_ms) |> min(@max_delay_ms)
        %{state | deadline: {token, state.timer.({:deadline, token}, delay)}}

      _off_or_none ->
        state
    end
  end

  defp disarm(%{deadline: nil} = state), do: state

  defp disarm(%{deadline: {_token, timer}} = state) do
    _left = state.cancel_timer.(timer)
    %{state | deadline: nil}
  end

  # As the daemon decides its management forwarding: once, at start. A
  # linked desktop's summary composes its server's part, as `home.status`'s.
  defp default_read do
    opts = Link.forwarding()
    fn -> HomeSummary.watch(Home.summary_facts(opts)) end
  end
end
