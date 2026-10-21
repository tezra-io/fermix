defmodule FermixCore.Native.HostAvailability do
  @moduledoc """
  The last word the Fermix app gave the native host wire (M76 §4.4, §4.6):
  whether anything serves `native_host.sock`, which connection the app is
  attached on, its last grant report, whether it said it is quitting, and the
  one launch on demand made for it.

  The wire's server and connection write it (`listening/2`, `attached/4`,
  `report/2`, `stopping/2`). A connection's exit is watched here, so however
  it ends, the app is detached; the endpoint's exit empties the record.

  `step/2` is the table a caller reads the record by, the browser host's
  (`Browser.HostLauncher.step/2`) without its pane: an attached app is used, a
  quitting one is not, an app that is not attached is opened once and waited
  for under the launch's deadline, a launch that never attached is not
  repeated within the cooldown after it, and a caller with no time left opens
  nothing. A caller takes that step with
  `claim/3`, which reads the record and records a launch in one call, so two
  callers that come at once open the app once, and the second waits on the
  first's deadline; a launch that failed at once is recorded at the moment it
  ended (`launching/2`), which starts its cooldown there. A quit does not stop a later launch,
  unlike the browser host's: a reminder stored for this Mac has no other place
  to ring, and storing it was the owner's consent to open the app for it.

  The grant report is held for whoever reads the record; a caller that must
  know the grant now asks the app (`host.status`), since after a restart with
  the app closed the last report is unknown.
  """

  use GenServer

  defstruct listening: false,
            attached: false,
            connection: nil,
            connection_id: nil,
            host_version: nil,
            notifications: nil,
            updated_at: nil,
            stopping: false,
            launch_until: nil

  @typedoc """
  `listening`: an endpoint is serving the wire. `attached`: an app is connected
  to it, on `connection` (its process) numbered `connection_id` by the
  endpoint, at `host_version`. `notifications` and `updated_at`: its last
  grant report and when it arrived, `nil` until the first. `stopping`: the app
  said it is quitting. `launch_until`: the deadline of the last launch on
  demand (a monotonic millisecond), until the next attach.
  """
  @type t :: %__MODULE__{
          listening: boolean(),
          attached: boolean(),
          connection: pid() | nil,
          connection_id: pos_integer() | nil,
          host_version: String.t() | nil,
          notifications: String.t() | nil,
          updated_at: DateTime.t() | nil,
          stopping: boolean(),
          launch_until: integer() | nil
        }

  @typedoc """
  What a step knows besides the record: the monotonic millisecond now, how
  long the caller has left, and the cooldown after a launch that did not
  attach.
  """
  @type clock :: %{now_ms: integer(), remaining_ms: integer(), cooldown_ms: pos_integer()}

  @typedoc "Why no app can take a request: nothing serves the wire, the app is quitting, or it never attached."
  @type unavailable :: :not_served | :stopping | :not_attached

  @typedoc """
  `{:attached, link}`: ask the app on `link`. `:launch`: open the app; the
  claim that answered it has recorded the launch. `{:wait, until_ms}`: a launch
  is pending until that monotonic millisecond. `{:unavailable, why}`: no app
  can take a request.
  """
  @type step ::
          {:attached, pid()} | :launch | {:wait, integer()} | {:unavailable, unavailable()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The record. A tree with no availability process (a CLI verb, a build that
  serves no native host) has no app either, so it answers the empty record.
  """
  @spec current(GenServer.server()) :: t()
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, {:noproc, _call} -> %__MODULE__{}
  end

  @doc "The wire's endpoint is serving; its exit empties the record."
  @spec listening(GenServer.server(), pid()) :: :ok
  def listening(server \\ __MODULE__, endpoint) when is_pid(endpoint),
    do: GenServer.call(server, {:listening, endpoint})

  @doc """
  An app attached on `connection`. A report from an earlier connection is
  void, and so is an earlier launch: the app is running.
  """
  @spec attached(GenServer.server(), pid(), pos_integer(), String.t()) :: :ok
  def attached(server \\ __MODULE__, connection, connection_id, host_version)
      when is_pid(connection) and is_integer(connection_id) and connection_id > 0 and
             is_binary(host_version),
      do: GenServer.call(server, {:attached, connection, connection_id, host_version})

  @doc "The attached app's notification grant. Ignored once the app said it is quitting."
  @spec report(GenServer.server(), String.t()) :: :ok
  def report(server \\ __MODULE__, notifications) when is_binary(notifications),
    do: GenServer.call(server, {:report, notifications})

  @doc "The app on `connection` is quitting. Final for that connection."
  @spec stopping(GenServer.server(), pid()) :: :ok
  def stopping(server \\ __MODULE__, connection) when is_pid(connection),
    do: GenServer.call(server, {:stopping, connection})

  @doc """
  One step of a caller's wait, read and taken in one call: a `:launch` answer
  has already recorded the launch, due to attach by `until_ms` (a monotonic
  millisecond), so a caller that asks a moment later finds it pending. A tree
  with no availability process has nothing serving the wire.
  """
  @spec claim(GenServer.server(), clock(), integer()) :: step()
  def claim(server \\ __MODULE__, clock, until_ms) when is_map(clock) and is_integer(until_ms) do
    GenServer.call(server, {:claim, clock, until_ms})
  catch
    :exit, {:noproc, _call} -> step(%__MODULE__{}, clock)
  end

  @doc """
  The app was opened on demand and must attach by `until_ms` (a monotonic
  millisecond). A launch that ended at once passes the moment it ended.
  """
  @spec launching(GenServer.server(), integer()) :: :ok
  def launching(server \\ __MODULE__, until_ms) when is_integer(until_ms),
    do: GenServer.call(server, {:launching, until_ms})

  @doc "One step of a caller's wait for the app, from the record and the clock."
  @spec step(t(), clock()) :: step()
  def step(%__MODULE__{} = host, %{now_ms: now, remaining_ms: remaining, cooldown_ms: cooldown})
      when is_integer(now) and is_integer(remaining) and is_integer(cooldown) do
    cond do
      host.attached and host.stopping -> {:unavailable, :stopping}
      host.attached -> {:attached, host.connection}
      not host.listening -> {:unavailable, :not_served}
      true -> unattached_step(host, now, remaining, cooldown)
    end
  end

  # Served, and no app attached: wait on a pending launch, give up within the
  # cooldown after one that never attached, and launch only with time left.
  defp unattached_step(host, now, remaining, cooldown) do
    cond do
      pending?(host, now) -> wait_or_give_up(host, remaining)
      cooling?(host, now, cooldown) -> {:unavailable, :not_attached}
      remaining > 0 -> :launch
      true -> {:unavailable, :not_attached}
    end
  end

  defp pending?(%{launch_until: until}, now), do: is_integer(until) and now < until

  defp wait_or_give_up(host, remaining) when remaining > 0, do: {:wait, host.launch_until}
  defp wait_or_give_up(_host, _remaining), do: {:unavailable, :not_attached}

  defp cooling?(%{launch_until: until}, now, cooldown),
    do: is_integer(until) and now < until + cooldown

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {:ok, %{host: %__MODULE__{}, endpoint: nil, connection_ref: nil, clock: clock}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.host, state}

  def handle_call({:listening, endpoint}, _from, state),
    do: {:reply, :ok, watch(state, endpoint)}

  def handle_call({:attached, connection, connection_id, host_version}, _from, state),
    do: {:reply, :ok, attach(state, connection, connection_id, host_version)}

  def handle_call({:report, _notifications}, _from, %{host: %{stopping: true}} = state),
    do: {:reply, :ok, state}

  def handle_call({:report, notifications}, _from, state) do
    host = %{state.host | notifications: notifications, updated_at: state.clock.()}
    {:reply, :ok, %{state | host: host}}
  end

  def handle_call({:stopping, connection}, _from, %{host: %{connection: connection}} = state),
    do: {:reply, :ok, %{state | host: %{state.host | stopping: true}}}

  def handle_call({:stopping, _connection}, _from, state), do: {:reply, :ok, state}

  def handle_call({:claim, clock, until_ms}, _from, state) do
    case step(state.host, clock) do
      :launch -> {:reply, :launch, %{state | host: %{state.host | launch_until: until_ms}}}
      step -> {:reply, step, state}
    end
  end

  def handle_call({:launching, until_ms}, _from, state),
    do: {:reply, :ok, %{state | host: %{state.host | launch_until: until_ms}}}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{endpoint: {pid, ref}} = state) do
    forget(state.connection_ref)
    {:noreply, %{state | host: %__MODULE__{}, endpoint: nil, connection_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connection_ref: ref} = state) do
    {:noreply, %{state | host: detached(state.host), connection_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # One endpoint at a time: a new one replaces the last, whose record goes with it.
  defp watch(state, endpoint) do
    case state.endpoint do
      {_pid, ref} -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end

    forget(state.connection_ref)
    host = %__MODULE__{listening: true}
    %{state | host: host, endpoint: {endpoint, Process.monitor(endpoint)}, connection_ref: nil}
  end

  defp attach(state, connection, connection_id, host_version) do
    forget(state.connection_ref)

    host = %__MODULE__{
      listening: state.host.listening,
      attached: true,
      connection: connection,
      connection_id: connection_id,
      host_version: host_version
    }

    %{state | host: host, connection_ref: Process.monitor(connection)}
  end

  # The connection is gone however it ended; a launch still pending is kept,
  # because it decides whether the app is opened again.
  defp detached(host), do: %__MODULE__{listening: host.listening, launch_until: host.launch_until}

  defp forget(nil), do: :ok
  defp forget(ref), do: Process.demonitor(ref, [:flush])
end
