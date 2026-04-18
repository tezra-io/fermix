defmodule FermixCore.Memory.Store do
  @moduledoc """
  ETS-backed key-value memory store scoped by conversation.

  Each memory is keyed by {conversation_key, key} and stores a value
  with a timestamp. Designed for agent fact storage during conversations.

  The M3 runtime uses `{channel, chat_id, thread_scope}` keys for thread-aware
  conversations. `{channel, chat_id}` remains supported as a legacy namespace
  for existing tool contexts and callers; the store does not normalize between
  the two arities.
  """

  use GenServer

  @table :fermix_memory

  @type thread_scope :: :root | String.t() | integer()
  @type conversation_key :: {String.t(), String.t()} | {String.t(), String.t(), thread_scope()}

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], [{:name, name} | opts])
  end

  @spec store(conversation_key(), String.t(), String.t(), keyword()) :: :ok
  def store(conv_key, key, value, opts \\ [])
      when is_binary(key) and is_binary(value) do
    assert_conversation_key!(conv_key)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:store, conv_key, key, value})
  end

  @spec recall(conversation_key(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found}
  def recall(conv_key, key, opts \\ []) when is_binary(key) do
    assert_conversation_key!(conv_key)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:recall, conv_key, key})
  end

  @spec recall_all(conversation_key(), keyword()) :: %{String.t() => String.t()}
  def recall_all(conv_key, opts \\ []) do
    assert_conversation_key!(conv_key)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:recall_all, conv_key})
  end

  @spec delete(conversation_key(), String.t(), keyword()) :: :ok
  def delete(conv_key, key, opts \\ []) when is_binary(key) do
    assert_conversation_key!(conv_key)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:delete, conv_key, key})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init([]) do
    table = :ets.new(@table, [:set, :private])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:store, conv_key, key, value}, _from, state) do
    :ets.insert(state.table, {{conv_key, key}, value, DateTime.utc_now()})
    {:reply, :ok, state}
  end

  def handle_call({:recall, conv_key, key}, _from, state) do
    result =
      case :ets.lookup(state.table, {conv_key, key}) do
        [{_, value, _timestamp}] -> {:ok, value}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:recall_all, conv_key}, _from, state) do
    pattern = {{conv_key, :"$1"}, :"$2", :_}
    matches = :ets.match(state.table, pattern)

    memories =
      matches
      |> Enum.into(%{}, fn [key, value] -> {key, value} end)

    {:reply, memories, state}
  end

  def handle_call({:delete, conv_key, key}, _from, state) do
    :ets.delete(state.table, {conv_key, key})
    {:reply, :ok, state}
  end

  defp assert_conversation_key!({channel, chat_id})
       when is_binary(channel) and is_binary(chat_id) do
    :ok
  end

  defp assert_conversation_key!({channel, chat_id, _thread_scope})
       when is_binary(channel) and is_binary(chat_id) do
    :ok
  end
end
