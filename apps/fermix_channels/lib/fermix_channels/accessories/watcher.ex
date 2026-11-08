defmodule FermixChannels.Accessories.Watcher do
  @moduledoc """
  The accessory port watcher (M91 §05; `priv/accessory/PROTOCOL.md`, *Opening
  the port*): it enumerates the attached USB-Serial-JTAG ports (Espressif's
  303A:1001) on a fixed poll, every 2 s, and starts one link
  (`FermixChannels.Accessories.Link`) per port it may open:

    * the port the owner selected for pairing (`pair/2`), opened in pairing
      mode;
    * a port whose USB serial string an enrolled accessory's `port_hint`
      names (A0: the K151 reports its MAC there, the same across replugs),
      opened in attach mode.

  The IDs are shared by every board on this controller and identify nothing,
  so any other 303A:1001 port is `:unrelated` and never opened; a port of any
  other vendor is not listed at all. Identity comes only from the link's
  attach proofs.

  Each port reads as one state: `:linked` (with the link's own view),
  `:busy` (another program holds it: five more opens, 1, 2, 4, 8 and 15 s
  apart, then it waits for `retry/2`), `:unrelated`, `:vanished` (it went
  while linked or watched), `:released` (closed for a firmware update until
  `reconnect/2`, since an open port blocks the installer), `:no_answer` (the
  selected port gave no Fermix answer in the attach bound: the step ended),
  and `:failed` (its link failed; reopened by the next poll, five times, then
  it waits for `retry/2`).

  Links run under the subtree's link supervisor, each on its own, so one
  link's crash ends only its own call. A watcher that starts again ends every
  link it finds there and opens afresh, so no port is held by a link nobody
  watches. Every change of the view bumps `version` (the update key a status
  long poll waits on) and, for a test, tells `:observer`.
  """

  use GenServer

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.Readiness
  alias FermixCore.Accessories.Store

  require Logger

  @poll_ms 2_000
  @espressif 0x303A
  @usb_serial_jtag 0x1001
  @busy_delays [1_000, 2_000, 4_000, 8_000, 15_000]
  @max_failures 5
  @max_vanished 16
  @call_timeout_ms 5_000

  @type port_state ::
          :linked | :busy | :unrelated | :vanished | :released | :no_answer | :failed

  # -- the API ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Every watched port and its state, with the view's update key."
  @spec status(GenServer.server(), timeout()) :: %{version: non_neg_integer(), ports: [map()]}
  def status(watcher, timeout \\ @call_timeout_ms), do: GenServer.call(watcher, :status, timeout)

  @doc """
  Opens the port the owner selected, for pairing. It must be an attached
  303A:1001 port (`{:error, :not_present}`) and not released for a firmware
  update (`{:error, :released}`: reconnect it first).
  """
  @spec pair(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def pair(watcher, path, timeout \\ @call_timeout_ms) when is_binary(path),
    do: GenServer.call(watcher, {:pair, path}, timeout)

  @doc "The owner's Retry for a busy or failed port: it is opened again now."
  @spec retry(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def retry(watcher, path, timeout \\ @call_timeout_ms) when is_binary(path),
    do: GenServer.call(watcher, {:retry, path}, timeout)

  @doc "Releases a port for a firmware update: closed, and ignored until `reconnect/2`."
  @spec release(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def release(watcher, path, timeout \\ @call_timeout_ms) when is_binary(path),
    do: GenServer.call(watcher, {:release, path}, timeout)

  @doc "Watches a released port again; it is opened at once if it may be."
  @spec reconnect(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def reconnect(watcher, path, timeout \\ @call_timeout_ms) when is_binary(path),
    do: GenServer.call(watcher, {:reconnect, path}, timeout)

  @doc "The link an accessory is attached on, by its ID."
  @spec link_for(GenServer.server(), String.t(), timeout()) ::
          {:ok, pid()} | {:error, :not_attached}
  def link_for(watcher, accessory_id, timeout \\ @call_timeout_ms) when is_binary(accessory_id),
    do: GenServer.call(watcher, {:link_for, accessory_id}, timeout)

  @doc "The link on a port, attached or not (the pairing link, say)."
  @spec link_on(GenServer.server(), String.t(), timeout()) :: {:ok, pid()} | {:error, :not_linked}
  def link_on(watcher, path, timeout \\ @call_timeout_ms) when is_binary(path),
    do: GenServer.call(watcher, {:link_on, path}, timeout)

  # -- the process ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      transport: Keyword.fetch!(opts, :transport),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      home: Keyword.fetch!(opts, :home),
      link_supervisor: Keyword.fetch!(opts, :link_supervisor),
      link_opts: Keyword.get(opts, :link_opts, []),
      send_after: Keyword.get(opts, :send_after, &Process.send_after/3),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      observer: Keyword.get(opts, :observer),
      ports: %{},
      entries: %{},
      released: MapSet.new(),
      selected: nil,
      version: 0,
      last_ports: nil,
      enumerate_error: nil
    }

    :ok = end_stale_links(state.link_supervisor)
    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, view(state), state}

  # A released port stays closed for its installer: pairing it is refused by
  # name, and the owner reconnects it first.
  def handle_call({:pair, path}, _from, state) do
    case Map.fetch(state.ports, path) do
      {:ok, info} ->
        if MapSet.member?(state.released, info.serial || path),
          do: {:reply, {:error, :released}, state},
          else: pair_port(state, path, info)

      :error ->
        {:reply, {:error, :not_present}, state}
    end
  end

  def handle_call({:retry, path}, _from, state) do
    case Map.fetch(state.ports, path) do
      {:ok, info} ->
        {:reply, :ok, state |> forget_entry(path) |> consider(path, info) |> changed()}

      :error ->
        {:reply, {:error, :not_present}, state}
    end
  end

  def handle_call({:release, path}, _from, state) do
    state = stop_link(state, path)
    key = release_key(state, path)
    entry = %{state: :released, serial: serial_of(state, path)}

    {:reply, :ok,
     %{state | released: MapSet.put(state.released, key)} |> put_entry(path, entry) |> changed()}
  end

  def handle_call({:reconnect, path}, _from, state) do
    state = %{state | released: MapSet.delete(state.released, release_key(state, path))}
    state = forget_entry(state, path)
    {:reply, :ok, state |> consider_present(path) |> changed()}
  end

  def handle_call({:link_for, accessory_id}, _from, state),
    do:
      {:reply, find_link(state, &(&1.accessory_id == accessory_id and &1.phase == :attached)),
       state}

  def handle_call({:link_on, path}, _from, state) do
    case Map.get(state.entries, path) do
      %{state: :linked, pid: pid} -> {:reply, {:ok, pid}, state}
      _other -> {:reply, {:error, :not_linked}, state}
    end
  end

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> schedule_poll() |> poll()}

  def handle_info({:retry_open, path}, state), do: {:noreply, retry_busy(state, path)}

  def handle_info({:link_view, path, pid, view}, state),
    do: {:noreply, link_view(state, path, pid, view)}

  def handle_info({:link_ended, path, pid, reason}, state),
    do: {:noreply, state |> link_ended(path, pid, reason) |> changed()}

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: {:noreply, state |> link_down(ref, pid, reason) |> changed()}

  def handle_info(message, state) do
    Logger.warning(
      "accessory watcher ignored an unexpected message: #{inspect(message, limit: 8)}"
    )

    {:noreply, state}
  end

  # -- the poll --------------------------------------------------------------------------

  defp schedule_poll(state) do
    _ref = state.send_after.(self(), :poll, state.poll_ms)
    state
  end

  defp poll(state) do
    case state.transport.enumerate(state.transport_opts) do
      {:ok, ports} -> %{state | enumerate_error: nil} |> reconcile(usj_ports(ports))
      {:error, reason} -> enumerate_failed(state, reason)
    end
  end

  # Said once per failure, not once per poll.
  defp enumerate_failed(%{enumerate_error: reason} = state, reason), do: state

  defp enumerate_failed(state, reason) do
    Logger.error("accessory watcher could not enumerate serial ports: #{inspect(reason)}")
    %{state | enumerate_error: reason}
  end

  defp usj_ports(ports) do
    for %{vendor_id: @espressif, product_id: @usb_serial_jtag} = port <- ports,
        into: %{},
        do: {port.path, %{serial: port.serial}}
  end

  defp reconcile(state, ports) do
    state = Enum.reduce(Map.keys(state.ports) -- Map.keys(ports), state, &gone/2)
    state = bound_vanished(%{state | ports: ports})
    hints = hints(state.home)

    ports
    |> Enum.sort()
    |> Enum.reduce(state, fn {path, info}, acc -> consider(acc, path, info, hints) end)
    |> changed()
  end

  defp hints(home) do
    case Store.list(home) do
      {:ok, records} -> MapSet.new(records, & &1.port_hint)
      {:error, reason} -> hints_unreadable(reason)
    end
  end

  defp hints_unreadable(reason) do
    Logger.error("accessory watcher could not read the pairing store: #{inspect(reason)}")
    MapSet.new()
  end

  # Every port that left the listing reads as vanished, whatever it read
  # before, and a bounded few are kept (`bound_vanished/1`); a linked one says
  # so through its link's own end. A released port's release is kept by its
  # serial string, so it reads as released again when it comes back.
  defp gone(path, state) do
    case Map.get(state.entries, path) do
      %{state: :linked} -> state
      %{state: :vanished} -> state
      %{} = entry -> put_entry(state, path, %{state: :vanished, serial: entry.serial})
      nil -> state
    end
  end

  defp consider_present(state, path) do
    case Map.fetch(state.ports, path) do
      {:ok, info} -> consider(state, path, info)
      :error -> state
    end
  end

  defp consider(state, path, info), do: consider(state, path, info, hints(state.home))

  # What the watcher does with one attached port this poll.
  defp consider(state, path, info, hints) do
    entry = Map.get(state.entries, path)

    cond do
      waits?(entry) ->
        state

      MapSet.member?(state.released, info.serial || path) ->
        put_entry(state, path, %{state: :released, serial: info.serial})

      state.selected == path ->
        open(state, path, info, :pairing)

      info.serial != nil and MapSet.member?(hints, info.serial) ->
        open(state, path, info, :attach)

      true ->
        put_entry(state, path, %{state: :unrelated, serial: info.serial})
    end
  end

  # A link running, a busy retry scheduled or given up, a port that ended its
  # step, or one that failed past its bound: none is opened by a poll.
  defp waits?(%{state: :linked}), do: true
  defp waits?(%{state: :busy}), do: true
  defp waits?(%{state: :no_answer}), do: true
  defp waits?(%{state: :failed, failures: failures}), do: failures >= @max_failures
  defp waits?(_entry), do: false

  # -- links -----------------------------------------------------------------------------

  defp open(state, path, info, mode) do
    watcher = self()

    opts =
      state.link_opts
      |> Keyword.put_new(:readiness, &Readiness.voice/0)
      |> Keyword.merge(
        path: path,
        serial: info.serial,
        mode: mode,
        transport: state.transport,
        transport_opts: state.transport_opts,
        home: state.home,
        notify: fn view -> send(watcher, {:link_view, path, self(), view}) end,
        ended: fn reason -> send(watcher, {:link_ended, path, self(), reason}) end
      )

    case start_link_child(state.link_supervisor, opts) do
      {:ok, pid} -> linked(state, path, info, pid, mode)
      {:error, reason} -> link_not_started(state, path, info, reason)
    end
  end

  # The watcher never raises on its own children: a link supervisor that is
  # gone (it restarts the watcher after it) is a refusal like any other.
  defp start_link_child(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {Link, opts})
  catch
    :exit, reason -> {:error, {:link_supervisor, reason}}
  end

  defp linked(state, path, info, pid, mode) do
    entry = Map.get(state.entries, path, %{})

    put_entry(state, path, %{
      state: :linked,
      serial: info.serial,
      pid: pid,
      ref: Process.monitor(pid),
      mode: mode,
      link: nil,
      busy: Map.get(entry, :busy),
      failures: Map.get(entry, :failures, 0)
    })
  end

  defp link_not_started(state, path, info, reason) do
    Logger.error("accessory watcher could not start a link on #{path}: #{inspect(reason)}")
    failed(state, path, %{serial: info.serial}, reason)
  end

  defp link_view(state, path, pid, view) do
    case Map.get(state.entries, path) do
      %{pid: ^pid} = entry ->
        state |> put_entry(path, %{entry | link: view}) |> paired(path, view) |> changed()

      _stale ->
        state
    end
  end

  # The selection is for one pairing: once it commits, or the port attaches
  # as an enrolled accessory's, the port is opened by its hint from then on.
  defp paired(%{selected: path} = state, path, view) do
    if view.phase == :attached or match?(%{phase: :done}, view.enrollment),
      do: %{state | selected: nil},
      else: state
  end

  defp paired(state, _path, _view), do: state

  defp link_down(state, ref, pid, reason) do
    case Enum.find(state.entries, fn {_path, entry} -> Map.get(entry, :ref) == ref end) do
      {path, entry} -> ended(state, path, entry, reason)
      nil -> stale_down(state, pid)
    end
  end

  defp stale_down(state, _pid), do: state

  # The link's own word on why it ended; its monitor's later `:DOWN` is
  # dropped with the monitor.
  defp link_ended(state, path, pid, reason) do
    case Map.get(state.entries, path) do
      %{state: :linked, pid: ^pid, ref: ref} = entry ->
        Process.demonitor(ref, [:flush])
        ended(state, path, entry, reason)

      _stale ->
        state
    end
  end

  defp ended(state, path, entry, {:shutdown, {:open_failed, :busy}}), do: busy(state, path, entry)

  defp ended(state, path, entry, {:shutdown, {:open_failed, :not_found}}),
    do: put_entry(state, path, %{state: :vanished, serial: entry.serial})

  defp ended(state, path, entry, {:shutdown, {:transport_closed, :vanished}}),
    do: put_entry(state, path, %{state: :vanished, serial: entry.serial})

  defp ended(state, path, entry, {:shutdown, :no_answer}) do
    state = if state.selected == path, do: %{state | selected: nil}, else: state
    put_entry(state, path, %{state: :no_answer, serial: entry.serial})
  end

  defp ended(state, path, entry, reason) do
    Logger.warning("accessory link on #{path} ended: #{inspect(reason)}")
    failed(state, path, entry, reason)
  end

  defp failed(state, path, entry, reason) do
    failures = Map.get(entry, :failures, 0) + 1

    put_entry(state, path, %{
      state: :failed,
      serial: entry.serial,
      failures: failures,
      reason: reason
    })
  end

  # Five more opens, 1, 2, 4, 8 and 15 s apart, then the owner's Retry.
  defp busy(state, path, entry) do
    attempts = Map.get(Map.get(entry, :busy) || %{}, :attempts, 0) + 1
    delay = Enum.at(@busy_delays, attempts - 1)
    if delay, do: state.send_after.(self(), {:retry_open, path}, delay)
    busy = %{attempts: attempts, waiting?: delay != nil}
    put_entry(state, path, %{state: :busy, serial: entry.serial, busy: busy})
  end

  defp retry_busy(state, path) do
    with %{state: :busy, busy: %{waiting?: true}} = entry <- Map.get(state.entries, path),
         {:ok, info} <- Map.fetch(state.ports, path) do
      state |> put_entry(path, %{entry | state: :retrying}) |> consider(path, info) |> changed()
    else
      _gone_or_given_up -> state
    end
  end

  defp pair_port(state, path, info) do
    state = stop_link(%{state | selected: path}, path) |> forget_entry(path)
    {:reply, :ok, state |> consider(path, info) |> changed()}
  end

  defp stop_link(state, path) do
    case Map.get(state.entries, path) do
      %{state: :linked, pid: pid, ref: ref} -> terminate_link(state, path, pid, ref)
      _other -> state
    end
  end

  defp terminate_link(state, path, pid, ref) do
    Process.demonitor(ref, [:flush])
    _ = DynamicSupervisor.terminate_child(state.link_supervisor, pid)
    forget_entry(state, path)
  end

  defp end_stale_links(supervisor) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(supervisor, pid)

    :ok
  end

  defp find_link(state, match) do
    Enum.find_value(state.entries, {:error, :not_attached}, fn
      {_path, %{state: :linked, pid: pid, link: %{} = view}} -> if match.(view), do: {:ok, pid}
      _other -> nil
    end)
  end

  # -- the view --------------------------------------------------------------------------

  defp put_entry(state, path, entry),
    do: %{state | entries: Map.put(state.entries, path, entry)} |> bound_vanished()

  defp forget_entry(state, path), do: %{state | entries: Map.delete(state.entries, path)}

  # Ports that went are kept to say so, a bounded few, the oldest dropped.
  defp bound_vanished(state) do
    vanished =
      for {path, %{state: :vanished}} <- state.entries,
          not Map.has_key?(state.ports, path),
          do: path

    extra = length(vanished) - @max_vanished

    if extra > 0,
      do: %{state | entries: Map.drop(state.entries, Enum.take(Enum.sort(vanished), extra))},
      else: state
  end

  defp serial_of(state, path) do
    case Map.fetch(state.ports, path) do
      {:ok, info} -> info.serial
      :error -> state.entries |> Map.get(path, %{}) |> Map.get(:serial)
    end
  end

  # A released port is known by its serial string, which survives the
  # installer's resets and re-enumeration; a port with none by its path.
  defp release_key(state, path), do: serial_of(state, path) || path

  # The update key moves only when what a reader sees moved.
  defp changed(state) do
    ports = view(state).ports

    if ports == state.last_ports,
      do: state,
      else: announce(%{state | version: state.version + 1, last_ports: ports})
  end

  defp announce(state) do
    if state.observer, do: send(state.observer, {:watcher_changed, self()})
    state
  end

  defp view(state) do
    ports =
      state.entries
      |> Enum.sort()
      |> Enum.map(fn {path, entry} ->
        %{
          path: path,
          serial: entry.serial,
          state: public_state(entry.state),
          pid: Map.get(entry, :pid),
          link: Map.get(entry, :link),
          busy: Map.get(entry, :busy),
          failures: Map.get(entry, :failures, 0)
        }
      end)

    %{version: state.version, ports: ports}
  end

  # A busy port being opened again is still busy to the owner.
  defp public_state(:retrying), do: :busy
  defp public_state(word), do: word
end
