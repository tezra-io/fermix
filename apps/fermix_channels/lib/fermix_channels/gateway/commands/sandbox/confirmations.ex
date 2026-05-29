defmodule FermixChannels.Gateway.Commands.Sandbox.Confirmations do
  @moduledoc false

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec store(String.t(), map()) :: :ok
  def store(token, record) when is_binary(token) and is_map(record) do
    :ets.insert(@table, {token, record})
    :ok
  end

  @spec take(String.t()) :: {:ok, map()} | :error
  def take(token) when is_binary(token) do
    case :ets.take(@table, token) do
      [{^token, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
