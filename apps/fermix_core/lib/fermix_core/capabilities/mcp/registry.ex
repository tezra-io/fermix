defmodule FermixCore.Capabilities.MCP.Registry do
  @moduledoc """
  In-memory map from MCP server name to its `Hermes.Client.Base` pid.

  Per-server supervisors register themselves here when their client
  comes up so dispatch can resolve `server_name → client_pid` without
  walking supervisor trees. Lookup failures return `{:error, :not_found}`
  so capability execution surfaces a clean error instead of crashing.

  The backing ETS table is derived from the registered GenServer name so
  multiple registries (e.g., one per test, or per umbrella test setup)
  don't collide on a shared table.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec register(GenServer.server(), String.t(), pid()) :: :ok
  def register(server \\ __MODULE__, name, pid)
      when is_binary(name) and is_pid(pid) do
    GenServer.call(server, {:register, name, pid})
  end

  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:unregister, name})
  end

  @spec lookup_client(GenServer.server(), String.t()) ::
          {:ok, pid()} | {:error, :not_found}
  def lookup_client(server \\ __MODULE__, name) when is_binary(name) do
    case table_for(server) do
      nil ->
        {:error, :not_found}

      table ->
        case :ets.lookup(table, name) do
          [{^name, pid}] when is_pid(pid) -> {:ok, pid}
          [] -> {:error, :not_found}
        end
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
  def handle_call({:register, name, pid}, _from, state) do
    state = drop_existing(name, state)
    ref = Process.monitor(pid)
    :ets.insert(state.table, {name, pid})
    monitors = Map.put(state.monitors, ref, name)
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:unregister, name}, _from, state) do
    state = drop_existing(name, state)
    {:reply, :ok, state}
  end

  def handle_call(:table_name, _from, state), do: {:reply, state.table, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {name, monitors} ->
        :ets.delete(state.table, name)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  defp drop_existing(name, state) do
    case :ets.lookup(state.table, name) do
      [{^name, _pid}] ->
        :ets.delete(state.table, name)

        {ref, monitors} =
          Enum.reduce(state.monitors, {nil, %{}}, fn
            {existing_ref, ^name}, {_acc_ref, acc} ->
              {existing_ref, acc}

            {other_ref, other_name}, {acc_ref, acc} ->
              {acc_ref, Map.put(acc, other_ref, other_name)}
          end)

        if ref, do: Process.demonitor(ref, [:flush])
        %{state | monitors: monitors}

      [] ->
        state
    end
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
