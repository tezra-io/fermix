defmodule FermixCore.Auth.LoopbackRegistry do
  @moduledoc """
  The OAuth loopback listeners open on this engine (M75 D17).

  Every browser sign-in listens on `127.0.0.1` for the provider's redirect
  (`Auth.OAuthFlow`, which the provider, plugin and MCP sign-ins all run). The
  flow records each listener here while it is open (`open/4`): its port, when
  it expires, and the management caller that started the sign-in, and removes
  it when the listener closes (`close/2`), whichever way the sign-in ended. A
  flow that dies without closing is removed too: the registry monitors it.

  **The forward.** A sign-in a desktop started over the rail (the caller
  `{:desktop, device_id}`) answers its authorize url on that desktop, so the
  browser's redirect lands on the desktop's `127.0.0.1`. The channels side
  subscribes here (`subscribe/2`) and tells that desktop to listen on the same
  port for as long as the listener is open; the desktop forwards what its
  browser sends, which is replayed against this engine's own listener, so no
  provider changes. `fermix_core` never calls the channels side: the
  subscriber is told, and it asks back. A desktop that cannot listen on the
  port reports it (`fail/3`), and the sign-in ends with that failure's
  sentence instead of waiting out its deadline for a reply that cannot come.

  **Where it runs.** In the engine tree, every role. A sign-in run by a CLI
  verb that boots no tree (`fermix auth login`) records nothing: no registry
  runs there, and nothing in that process could forward a listener anyway.
  `open/4` says so with a `nil` id, which `close/2` and the flow accept.

  Subscribers get `envelope.(event)` as a message, `event` being
  `{:opened, entry}` or `{:closed, entry}`.
  """

  use GenServer

  require Logger

  @id_bytes 12

  @typedoc "The management caller that started a sign-in, when it was a desktop."
  @type owner :: {:desktop, String.t()} | nil

  @typedoc "One open listener."
  @type entry :: %{
          id: String.t(),
          port: :inet.port_number(),
          expires_at: DateTime.t(),
          owner: owner(),
          flow: pid()
        }

  @typedoc "What a subscriber is told."
  @type event :: {:opened, entry()} | {:closed, entry()}

  @typedoc """
  Why a desktop could not take a listener: its name, the port, and the reason
  (`:port_in_use`, `:not_permitted`, or `:failed`).
  """
  @type failure :: %{
          desktop: String.t(),
          port: :inet.port_number(),
          reason: :port_in_use | :not_permitted | :failed
        }

  @doc "Starts the registry. `opts`: `:name` (default this module)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records the listener the calling process (the flow) opened on `port`, until
  `expires_at`, for `owner`. Answers its id, or `nil` where no registry runs.
  """
  @spec open(:inet.port_number(), owner(), DateTime.t(), GenServer.server()) ::
          {:ok, String.t() | nil}
  def open(port, owner, %DateTime{} = expires_at, server \\ __MODULE__)
      when is_integer(port) and port > 0 and port <= 65_535 do
    :ok = validate_owner!(owner)

    case GenServer.whereis(server) do
      nil -> {:ok, nil}
      pid -> GenServer.call(pid, {:open, port, owner, expires_at, self()})
    end
  end

  @doc "Removes the listener `id`; a `nil` id (nothing recorded) or one already gone is `:ok`."
  @spec close(String.t() | nil, GenServer.server()) :: :ok
  def close(id, server \\ __MODULE__)
  def close(nil, _server), do: :ok

  def close(id, server) when is_binary(id) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.call(pid, {:close, id})
    end
  end

  @doc """
  Subscribes the calling process: it is sent `envelope.(event)` for every
  listener opened and closed from now on, and answered the ones open now.
  """
  @spec subscribe((event() -> term()), GenServer.server()) :: {:ok, [entry()]}
  def subscribe(envelope, server \\ __MODULE__) when is_function(envelope, 1),
    do: GenServer.call(server, {:subscribe, self(), envelope})

  @doc "Ends the calling process's subscription."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  @doc """
  A desktop could not take listener `id`: the flow waiting on it is told
  (`{:loopback_forward_failed, id, failure}`) and ends with that failure.
  """
  @spec fail(String.t(), failure(), GenServer.server()) :: :ok | {:error, :unknown_loopback}
  def fail(id, %{desktop: desktop, port: port, reason: reason} = failure, server \\ __MODULE__)
      when is_binary(id) and is_binary(desktop) and is_integer(port) and
             reason in [:port_in_use, :not_permitted, :failed],
      do: GenServer.call(server, {:fail, id, failure})

  @doc "The listeners open now."
  @spec list(GenServer.server()) :: [entry()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @impl true
  def init(:ok), do: {:ok, %{entries: %{}, flows: %{}, subscribers: %{}}}

  @impl true
  def handle_call({:open, port, owner, expires_at, flow}, _from, state) do
    id = "lb-" <> Base.url_encode64(:crypto.strong_rand_bytes(@id_bytes), padding: false)
    entry = %{id: id, port: port, expires_at: expires_at, owner: owner, flow: flow}
    ref = Process.monitor(flow)
    state = %{state | entries: Map.put(state.entries, id, entry)}
    state = %{state | flows: Map.put(state.flows, ref, id)}
    notify(state, {:opened, entry})
    {:reply, {:ok, id}, state}
  end

  def handle_call({:close, id}, _from, state), do: {:reply, :ok, remove(state, id)}

  def handle_call({:subscribe, pid, envelope}, _from, state) do
    state = drop_subscriber(state, pid)
    ref = Process.monitor(pid)
    subscribers = Map.put(state.subscribers, pid, {ref, envelope})
    {:reply, {:ok, Map.values(state.entries)}, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state),
    do: {:reply, :ok, drop_subscriber(state, pid)}

  def handle_call({:fail, id, failure}, _from, state) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        send(entry.flow, {:loopback_forward_failed, id, failure})
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_loopback}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state.entries), state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.flows, ref) do
      {nil, _flows} -> {:noreply, drop_subscriber(state, pid)}
      {id, flows} -> {:noreply, remove(%{state | flows: flows}, id)}
    end
  end

  def handle_info(message, state) do
    Logger.warning("loopback registry: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  defp remove(state, id) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        notify(state, {:closed, entry})
        %{state | entries: entries, flows: drop_flow(state.flows, id)}
    end
  end

  defp drop_flow(flows, id) do
    case Enum.find(flows, fn {_ref, flow_id} -> flow_id == id end) do
      {ref, _id} ->
        Process.demonitor(ref, [:flush])
        Map.delete(flows, ref)

      nil ->
        flows
    end
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {{ref, _envelope}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {pid, {_ref, envelope}} -> send(pid, envelope.(event)) end)
  end

  defp validate_owner!(nil), do: :ok

  defp validate_owner!({:desktop, device_id}) when is_binary(device_id) and device_id != "",
    do: :ok

  defp validate_owner!(owner),
    do: raise(ArgumentError, "a loopback owner is nil or {:desktop, id}, got #{inspect(owner)}")
end
