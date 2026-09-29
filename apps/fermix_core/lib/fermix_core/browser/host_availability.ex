defmodule FermixCore.Browser.HostAvailability do
  @moduledoc """
  The last word the Fermix app gave about its browser pane.

  The app's browser host connects to `browser_host.sock`
  (`FermixChannels.BrowserHost`), then reports whether its pane can take work
  (`available`) and, when it cannot, why (`reason`). This process holds that
  last report, with whether anything is listening for a host at all and which
  connection the host is on, for the readers that act on it: the routing
  decision when a conversation's browser use starts (`Routing`,
  `HostLauncher`), and a pane task before each operation (`HostServer`), which
  sends its requests on the connection recorded here.

  Only the wire's endpoint and connection write it (`listening/2`,
  `attached/3`, `report/3`, `stopping/2`), and the launcher records the one
  launch it has made (`launching/2`). A connection's exit is watched here, so
  however it ends, the host is detached.

  `host_stopping` is final for its connection: once the app said it is
  quitting, no later report on that connection makes the pane available again,
  and the app is not opened again until it attaches by itself.
  """

  use GenServer

  @reason_chars 200

  defstruct listening: false,
            attached: false,
            connection: nil,
            connection_id: nil,
            available: false,
            reason: nil,
            updated_at: nil,
            stopping: false,
            quit: false,
            launch_until: nil

  @typedoc """
  `listening`: an endpoint is serving the wire. `attached`: a host is connected
  to it, on `connection` (its process) numbered `connection_id` by the
  endpoint. `available` and `reason`: the host's last report, and `updated_at`
  when it arrived — `nil` until the first report after an attach, so a host
  that has connected but not yet spoken is not mistaken for one that said no.
  `stopping`: the host said it is quitting. `quit`: the last host quit, so the
  app is not opened on demand until one attaches again. `launch_until`: the
  deadline of the last launch on demand (a monotonic millisecond), until the
  next attach.
  """
  @type t :: %__MODULE__{
          listening: boolean(),
          attached: boolean(),
          connection: pid() | nil,
          connection_id: pos_integer() | nil,
          available: boolean(),
          reason: String.t() | nil,
          updated_at: DateTime.t() | nil,
          stopping: boolean(),
          quit: boolean(),
          launch_until: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The last report. A tree with no availability process (a CLI verb, an
  isolated test tree) has no host either, so it answers the empty report.
  """
  @spec current(GenServer.server()) :: t()
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, {:noproc, _call} -> %__MODULE__{}
  end

  @doc "The wire's endpoint is serving; its exit empties the report."
  @spec listening(GenServer.server(), pid()) :: :ok
  def listening(server \\ __MODULE__, endpoint) when is_pid(endpoint),
    do: GenServer.call(server, {:listening, endpoint})

  @doc """
  A host attached on `connection`. Any report from an earlier connection is
  void, and so are an earlier quit and launch: the app is running again.
  """
  @spec attached(GenServer.server(), pid(), pos_integer()) :: :ok
  def attached(server \\ __MODULE__, connection, connection_id)
      when is_pid(connection) and is_integer(connection_id) and connection_id > 0,
      do: GenServer.call(server, {:attached, connection, connection_id})

  @doc """
  The attached host's report: whether its pane can take work, and why not.
  Ignored once the host said it is stopping.
  """
  @spec report(GenServer.server(), boolean(), String.t() | nil) :: :ok
  def report(server \\ __MODULE__, available, reason)
      when is_boolean(available) and (is_nil(reason) or is_binary(reason)),
      do: GenServer.call(server, {:report, available, reason})

  @doc "The host on `connection` is quitting. Final for that connection."
  @spec stopping(GenServer.server(), pid()) :: :ok
  def stopping(server \\ __MODULE__, connection) when is_pid(connection),
    do: GenServer.call(server, {:stopping, connection})

  @doc """
  The app was opened on demand and must attach by `until_ms` (a monotonic
  millisecond). A launch that ended at once passes the moment it ended.
  """
  @spec launching(GenServer.server(), integer()) :: :ok
  def launching(server \\ __MODULE__, until_ms) when is_integer(until_ms),
    do: GenServer.call(server, {:launching, until_ms})

  @doc "Whether a pane can take work now: a host is attached and its last report says so."
  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{} = host) do
    host.attached and host.available and not host.stopping and not is_nil(host.updated_at)
  end

  @doc "Whether the attached host has reported since it connected."
  @spec reported?(t()) :: boolean()
  def reported?(%__MODULE__{attached: attached, updated_at: at}), do: attached and not is_nil(at)

  @doc """
  Why the pane cannot take work, in words that finish the sentence "the Fermix
  app's browser is no longer available: …". Bounded: a host's reason is its
  own text.
  """
  @spec unavailable_reason(t()) :: String.t()
  def unavailable_reason(%__MODULE__{} = host), do: host |> reason_text() |> bounded()

  defp reason_text(%__MODULE__{listening: false}), do: "nothing in this engine serves it"

  defp reason_text(%__MODULE__{attached: false, reason: reason}) when is_binary(reason),
    do: reason

  defp reason_text(%__MODULE__{attached: false}), do: "the app is not connected"
  defp reason_text(%__MODULE__{stopping: true}), do: "the app is quitting"
  defp reason_text(%__MODULE__{updated_at: nil}), do: "the app has not reported its browser yet"
  defp reason_text(%__MODULE__{reason: reason}) when is_binary(reason), do: reason
  defp reason_text(%__MODULE__{}), do: "the app reported its browser unavailable"

  defp bounded(text), do: String.slice(text, 0, @reason_chars)

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {:ok, %{host: %__MODULE__{}, endpoint: nil, connection_ref: nil, clock: clock}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.host, state}

  def handle_call({:listening, endpoint}, _from, state) do
    {:reply, :ok, watch(state, endpoint)}
  end

  def handle_call({:attached, connection, connection_id}, _from, state) do
    {:reply, :ok, attach(state, connection, connection_id)}
  end

  def handle_call({:report, _available, _reason}, _from, %{host: %{stopping: true}} = state),
    do: {:reply, :ok, state}

  def handle_call({:report, available, reason}, _from, state) do
    host = %{state.host | available: available, reason: reason, updated_at: state.clock.()}
    {:reply, :ok, %{state | host: host}}
  end

  def handle_call({:stopping, connection}, _from, %{host: %{connection: connection}} = state) do
    host = %{state.host | available: false, reason: nil, stopping: true, quit: true}
    {:reply, :ok, %{state | host: host}}
  end

  def handle_call({:stopping, _connection}, _from, state), do: {:reply, :ok, state}

  def handle_call({:launching, until_ms}, _from, state) do
    {:reply, :ok, %{state | host: %{state.host | launch_until: until_ms}}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{endpoint: {pid, ref}} = state) do
    forget(state.connection_ref)
    {:noreply, %{state | host: %__MODULE__{}, endpoint: nil, connection_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connection_ref: ref} = state) do
    {:noreply, %{state | host: detached(state.host), connection_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # One endpoint at a time: a new one replaces the last, whose report goes with it.
  defp watch(state, endpoint) do
    case state.endpoint do
      {_pid, ref} -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end

    forget(state.connection_ref)
    host = %__MODULE__{listening: true}
    %{state | host: host, endpoint: {endpoint, Process.monitor(endpoint)}, connection_ref: nil}
  end

  defp attach(state, connection, connection_id) do
    forget(state.connection_ref)

    host = %__MODULE__{
      listening: state.host.listening,
      attached: true,
      connection: connection,
      connection_id: connection_id
    }

    %{state | host: host, connection_ref: Process.monitor(connection)}
  end

  # The connection is gone however it ended; what the app last said about
  # quitting is kept, because it decides whether the app may be opened again.
  defp detached(host) do
    %__MODULE__{
      listening: host.listening,
      reason: if(host.stopping, do: "the app quit", else: "the app disconnected"),
      quit: host.quit,
      launch_until: host.launch_until
    }
  end

  defp forget(nil), do: :ok
  defp forget(ref), do: Process.demonitor(ref, [:flush])
end
