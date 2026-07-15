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

  @doc """
  Look up a pending record without consuming it. Read-only, so origin/TTL
  validation can reject a bad `/confirm` *before* the single-use `take/1`
  burns the owner's live token. `take/1` remains the sole consume authority.
  """
  @spec peek(String.t()) :: {:ok, map()} | :error
  def peek(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @doc """
  Every live `{token, record}` pair. Read-only (never deletes) — used to dedupe
  an agent-initiated grant request against an already-pending one for the same
  mutation + origin, so a re-request returns the existing token instead of
  prompting the owner twice.
  """
  @spec list() :: [{String.t(), map()}]
  def list, do: :ets.tab2list(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
