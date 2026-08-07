defmodule FermixCore.Capabilities.MCP.Registry do
  @moduledoc """
  In-memory map from a **source-qualified** MCP server identity to what dispatch
  may reach for it.

  Keys are `{:plugin, "eden"}` / `{:operator, "eden"}`, never the bare name. Two
  servers may share a name; they can never share an identity, so a plugin
  "eden" and a `[mcp.servers.eden]` TOML server cannot resolve to each other's
  client. Keying on the bare name made that collision reachable from dispatch.

  Two visibilities (M27 §7.6):

    * **public** — a local stdio client. `lookup_client/2` returns its pid and
      `Caller.Anubis` calls it directly.
    * **private** — a remote client. The raw client is never published; the
      registry publishes the allowlisted `Remote.Proxy` instead, and
      `lookup_client/2` answers `{:error, :client_private}`. A direct internal
      caller therefore cannot reach a remote peer without passing the proxy's
      allowlist, profile, and resource-scope gate.

  Lookup failures return `{:error, :not_found}` so capability execution surfaces
  a clean error instead of crashing. The backing ETS table is derived from the
  registered GenServer name so multiple registries (e.g. one per test) don't
  collide on a shared table.
  """

  use GenServer

  @type source_id :: {atom(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Publish a public (stdio) client for a source-qualified identity."
  @spec register(GenServer.server(), source_id(), pid()) :: :ok
  def register(server \\ __MODULE__, source_id, pid)

  def register(server, {kind, name} = source_id, pid)
      when is_atom(kind) and is_binary(name) and is_pid(pid) do
    GenServer.call(
      server,
      {:register, source_id, %{client: pid, proxy: nil, visibility: :public}}
    )
  end

  @doc """
  Publish a remote source's allowlisted call proxy. The raw client stays
  private: only the proxy is reachable.
  """
  @spec register_proxy(GenServer.server(), source_id(), pid()) :: :ok
  def register_proxy(server \\ __MODULE__, source_id, proxy)

  def register_proxy(server, {kind, name} = source_id, proxy)
      when is_atom(kind) and is_binary(name) and is_pid(proxy) do
    GenServer.call(
      server,
      {:register, source_id, %{client: nil, proxy: proxy, visibility: :private}}
    )
  end

  @spec unregister(GenServer.server(), source_id()) :: :ok
  def unregister(server \\ __MODULE__, source_id)

  def unregister(server, {kind, name} = source_id) when is_atom(kind) and is_binary(name) do
    GenServer.call(server, {:unregister, source_id})
  end

  @doc """
  The public client for a source, or why there isn't one.

  `{:error, :client_private}` is a refusal, not an absence: the source exists and
  is remote, and its raw client is deliberately unreachable.
  """
  @spec lookup_client(GenServer.server(), source_id()) ::
          {:ok, pid()} | {:error, :not_found | :client_private}
  def lookup_client(server \\ __MODULE__, source_id)

  def lookup_client(server, {kind, name} = source_id) when is_atom(kind) and is_binary(name) do
    case fetch(server, source_id) do
      {:ok, %{visibility: :public, client: pid}} when is_pid(pid) -> {:ok, pid}
      {:ok, %{visibility: :private}} -> {:error, :client_private}
      _absent -> {:error, :not_found}
    end
  end

  @spec lookup_proxy(GenServer.server(), source_id()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_proxy(server \\ __MODULE__, source_id)

  def lookup_proxy(server, {kind, name} = source_id) when is_atom(kind) and is_binary(name) do
    case fetch(server, source_id) do
      {:ok, %{proxy: pid}} when is_pid(pid) -> {:ok, pid}
      _absent -> {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table_name = table_name(name)

    table =
      :ets.new(table_name, [:named_table, :protected, :set, read_concurrency: true])

    {:ok, %{table: table, name: name, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, source_id, entry}, _from, state) do
    state = drop_existing(source_id, state)
    ref = Process.monitor(entry.proxy || entry.client)
    :ets.insert(state.table, {source_id, entry})
    monitors = Map.put(state.monitors, ref, source_id)
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:unregister, source_id}, _from, state) do
    state = drop_existing(source_id, state)
    {:reply, :ok, state}
  end

  def handle_call(:table_name, _from, state), do: {:reply, state.table, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {source_id, monitors} ->
        :ets.delete(state.table, source_id)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  defp fetch(server, source_id) do
    case table_for(server) do
      nil ->
        :error

      table ->
        case :ets.lookup(table, source_id) do
          [{^source_id, entry}] -> {:ok, entry}
          [] -> :error
        end
    end
  end

  defp drop_existing(source_id, state) do
    case :ets.lookup(state.table, source_id) do
      [{^source_id, _entry}] ->
        :ets.delete(state.table, source_id)
        demonitor_source(source_id, state)

      [] ->
        state
    end
  end

  defp demonitor_source(source_id, state) do
    {ref, monitors} =
      Enum.reduce(state.monitors, {nil, %{}}, fn
        {existing_ref, ^source_id}, {_acc_ref, acc} ->
          {existing_ref, acc}

        {other_ref, other_source}, {acc_ref, acc} ->
          {acc_ref, Map.put(acc, other_ref, other_source)}
      end)

    if ref, do: Process.demonitor(ref, [:flush])
    %{state | monitors: monitors}
  end

  defp table_for(server) when is_atom(server) do
    case :ets.whereis(table_name(server)) do
      :undefined -> nil
      _tid -> table_name(server)
    end
  end

  defp table_for(server) when is_pid(server) do
    GenServer.call(server, :table_name)
  end

  defp table_name(name) when is_atom(name), do: :"#{name}.Table"
end
