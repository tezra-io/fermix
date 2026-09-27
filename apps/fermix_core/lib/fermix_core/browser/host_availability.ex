defmodule FermixCore.Browser.HostAvailability do
  @moduledoc """
  The last word the Fermix app gave about its browser pane.

  The app's browser host connects to an endpoint the engine serves on a local
  wire, then reports whether its pane can take work (`available`) and, when it
  cannot, why (`reason`). This process holds that last report, with whether
  anything is listening for a host at all, for the two readers that act on it:
  the routing decision when a conversation's browser use starts (`Routing`),
  and a pane profile before each operation (`HostServer`).

  Only the wire's endpoint writes it (`listening/2`, `attached/1`, `report/3`,
  `detached/2`). Until that endpoint exists nothing does, so it stays empty —
  nothing listening, nothing attached — and every decision it feeds is the one
  made before it existed.
  """

  use GenServer

  @reason_chars 200

  defstruct listening: false, attached: false, available: false, reason: nil, updated_at: nil

  @typedoc """
  `listening`: an endpoint is serving the wire. `attached`: a host is connected
  to it. `available` and `reason`: the host's last report, and `updated_at`
  when it arrived — `nil` until the first report after an attach, so a host
  that has connected but not yet spoken is not mistaken for one that said no.
  """
  @type t :: %__MODULE__{
          listening: boolean(),
          attached: boolean(),
          available: boolean(),
          reason: String.t() | nil,
          updated_at: DateTime.t() | nil
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

  @doc "A host connected. Any report from an earlier connection is void."
  @spec attached(GenServer.server()) :: :ok
  def attached(server \\ __MODULE__), do: GenServer.call(server, :attached)

  @doc "The attached host's report: whether its pane can take work, and why not."
  @spec report(GenServer.server(), boolean(), String.t() | nil) :: :ok
  def report(server \\ __MODULE__, available, reason)
      when is_boolean(available) and (is_nil(reason) or is_binary(reason)),
      do: GenServer.call(server, {:report, available, reason})

  @doc "The host went away, and why."
  @spec detached(GenServer.server(), String.t()) :: :ok
  def detached(server \\ __MODULE__, reason) when is_binary(reason),
    do: GenServer.call(server, {:detached, reason})

  @doc "Whether a pane can take work now: a host is attached and its last report says so."
  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{attached: attached, available: available, updated_at: at}),
    do: attached and available and not is_nil(at)

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
  defp reason_text(%__MODULE__{updated_at: nil}), do: "the app has not reported its browser yet"
  defp reason_text(%__MODULE__{reason: reason}) when is_binary(reason), do: reason
  defp reason_text(%__MODULE__{}), do: "the app reported its browser unavailable"

  defp bounded(text), do: String.slice(text, 0, @reason_chars)

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {:ok, %{host: %__MODULE__{}, endpoint: nil, clock: clock}}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.host, state}

  def handle_call({:listening, endpoint}, _from, state) do
    {:reply, :ok, watch(state, endpoint)}
  end

  def handle_call(:attached, _from, state) do
    host = %{state.host | attached: true, available: false, reason: nil, updated_at: nil}
    {:reply, :ok, %{state | host: host}}
  end

  def handle_call({:report, available, reason}, _from, state) do
    host = %{state.host | available: available, reason: reason, updated_at: state.clock.()}
    {:reply, :ok, %{state | host: host}}
  end

  def handle_call({:detached, reason}, _from, state) do
    host = %{state.host | attached: false, available: false, reason: reason, updated_at: nil}
    {:reply, :ok, %{state | host: host}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{endpoint: {pid, ref}} = state) do
    {:noreply, %{state | host: %__MODULE__{}, endpoint: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # One endpoint at a time: a new one replaces the last, whose report goes with it.
  defp watch(state, endpoint) do
    case state.endpoint do
      {_pid, ref} -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end

    host = %__MODULE__{listening: true}
    %{state | host: host, endpoint: {endpoint, Process.monitor(endpoint)}}
  end
end
