defmodule FermixChannels.Desktop.HandoffLink do
  @moduledoc """
  The desktop's side of a browser hand-off over the rail (M75 D18), in the
  device role: the implementation of `FermixCore.Browser.Handoff.Link`.

  `send_handoff/1` runs in the caller (the owner's `browser.handoff.send`):
  it registers for the answer, sends `handoff_begin` and the cookies as
  `handoff_chunk`s through the relay, and waits up to 60 s for the primary's
  `handoff_stored` or `handoff_refused`, which the relay hands this process
  (`handle/3`, one line each in `Desktop.Relay`'s `@inbound`). `send_wipe/1`
  runs the same way for `browser.handoffs.wipe`: it sends `handoff_wipe`
  under an id of its own and waits for `handoff_wiped` (how many cookies the
  primary deleted) or `handoff_refused` with that id.

  A relay that is down answers `primary_unreachable`, with the sentence that
  names the primary.
  """

  @behaviour FermixCore.Browser.Handoff.Link

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Relay
  alias FermixCore.Management.Placement

  @events ~w(handoff_stored handoff_refused handoff_wiped)
  @answer_timeout_ms 60_000

  @doc "Serves one of the primary's hand-off answers, from the relay."
  @spec handle(String.t(), map(), binary()) :: :ok | {:error, :not_running}
  def handle(type, fields, payload) when type in @events and is_map(fields),
    do: handle(__MODULE__, type, fields, payload)

  @doc false
  @spec handle(GenServer.server(), String.t(), map(), binary()) :: :ok | {:error, :not_running}
  def handle(server, type, fields, _payload) when type in @events do
    case GenServer.whereis(server) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, {:answer, type, fields})
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @impl FermixCore.Browser.Handoff.Link
  def send_handoff(handoff), do: send_handoff(__MODULE__, handoff, [])

  @doc """
  `send_handoff/1` through `server`. `opts`: `:send` (a 2-arity function in
  place of `Desktop.Relay.send_event/3`), `:answer_timeout_ms`.
  """
  @spec send_handoff(GenServer.server(), FermixCore.Browser.Handoff.Link.handoff(), keyword()) ::
          {:ok, %{cookies: non_neg_integer(), expires_at: DateTime.t()}}
          | {:error, FermixCore.Browser.Handoff.Link.failure()}
  def send_handoff(server, %{handoff_id: id, payload: payload} = handoff, opts) do
    send = Keyword.get(opts, :send, &relay_send/2)
    :ok = GenServer.call(server, {:expect, id})

    begin = %{
      "t" => "handoff_begin",
      "handoff_id" => id,
      "sites" => handoff.sites,
      "expires_at" => handoff.expires_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "count" => handoff.count
    }

    try do
      with :ok <- send.(begin, <<>>),
           :ok <- send.(%{"t" => "handoff_chunk", "handoff_id" => id}, payload) do
        await(id, Keyword.get(opts, :answer_timeout_ms, @answer_timeout_ms))
      end
    after
      GenServer.cast(server, {:forget, id})
    end
  end

  @impl FermixCore.Browser.Handoff.Link
  def send_wipe(sites), do: send_wipe(__MODULE__, sites, [])

  @doc "`send_wipe/1` through `server`, with `opts` as `send_handoff/3` takes them."
  @spec send_wipe(GenServer.server(), [String.t()] | nil, keyword()) ::
          {:ok, %{cookies: non_neg_integer()}}
          | {:error, FermixCore.Browser.Handoff.Link.failure()}
  def send_wipe(server, sites, opts) when is_list(sites) or is_nil(sites) do
    send = Keyword.get(opts, :send, &relay_send/2)
    id = "wp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    :ok = GenServer.call(server, {:expect, id})
    event = %{"t" => "handoff_wipe", "handoff_id" => id}
    event = if sites, do: Map.put(event, "sites", sites), else: event

    try do
      with :ok <- send.(event, <<>>) do
        await(id, Keyword.get(opts, :answer_timeout_ms, @answer_timeout_ms))
      end
    after
      GenServer.cast(server, {:forget, id})
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{waiters: %{}}}

  @impl GenServer
  def handle_call({:expect, id}, {caller, _tag}, state),
    do: {:reply, :ok, put_in(state.waiters[id], caller)}

  @impl GenServer
  def handle_cast({:forget, id}, state),
    do: {:noreply, %{state | waiters: Map.delete(state.waiters, id)}}

  def handle_cast({:answer, type, %{"handoff_id" => id} = fields}, state) do
    case Map.pop(state.waiters, id) do
      {nil, _waiters} ->
        Logger.warning("desktop hand-off: the primary answered #{id}, which nobody waits for")
        {:noreply, state}

      {caller, waiters} ->
        send(caller, {:handoff_answer, id, result(type, fields)})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  defp result("handoff_stored", %{"cookies" => count, "expires_at" => at}) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(at)
    {:ok, %{cookies: count, expires_at: expires_at}}
  end

  defp result("handoff_refused", %{"sentence" => sentence}),
    do: {:error, {:primary_refused, sentence}}

  defp result("handoff_wiped", %{"cookies" => count}), do: {:ok, %{cookies: count}}

  defp await(id, timeout_ms) do
    receive do
      {:handoff_answer, ^id, result} -> result
    after
      timeout_ms -> {:error, :primary_timeout}
    end
  end

  # The relay's own sentence while the primary is unreachable; any other
  # failure to send is the same to the owner, with its reason in the log.
  defp relay_send(event, payload) do
    case Relay.send_event(Relay, event, payload) do
      :ok ->
        :ok

      {:error, {:unreachable, sentence}} ->
        {:error, {:primary_unreachable, sentence}}

      {:error, reason} ->
        Logger.error("desktop hand-off: #{event["t"]} not sent: #{inspect(reason)}")
        {:error, {:primary_unreachable, Placement.unreachable_sentence(nil)}}
    end
  catch
    :exit, reason ->
      Logger.error("desktop hand-off: the relay is not running: #{inspect(reason)}")
      {:error, {:primary_unreachable, Placement.unreachable_sentence(nil)}}
  end
end
