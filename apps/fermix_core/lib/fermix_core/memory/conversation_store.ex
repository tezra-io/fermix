defmodule FermixCore.Memory.ConversationStore do
  @moduledoc """
  Stores conversation history per chat/thread.

  Each conversation is keyed by {channel, chat_id, thread_scope}.
  Maintains a rolling window of messages with automatic compaction.
  """

  use GenServer

  @type thread_scope :: :root | String.t() | integer()
  @type conversation_key :: {channel :: String.t(), chat_id :: String.t(), thread_scope()}
  @type message :: %{
          role: String.t(),
          content: String.t(),
          timestamp: DateTime.t()
        }

  @max_messages_default 50

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {max_messages, opts} = Keyword.pop(opts, :max_messages, @max_messages_default)
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, max_messages, [{:name, name} | opts])
  end

  @spec add_message(conversation_key(), String.t(), String.t(), keyword()) :: :ok
  def add_message({channel, chat_id, _thread_scope} = key, role, content, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) and
             is_binary(role) and is_binary(content) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:add_message, key, role, content})
  end

  @spec get_history(conversation_key(), non_neg_integer() | keyword()) :: [message()]
  def get_history(key, limit_or_opts \\ [])

  def get_history(key, opts) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    limit = Keyword.get(opts, :limit)
    GenServer.call(server, {:get_history, key, limit})
  end

  def get_history(key, limit) when is_integer(limit) and limit > 0 do
    get_history(key, limit, [])
  end

  @spec get_history(conversation_key(), pos_integer(), keyword()) :: [message()]
  def get_history(key, limit, opts) when is_integer(limit) and limit > 0 do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_history, key, limit})
  end

  @spec clear(conversation_key(), keyword()) :: :ok
  def clear({channel, chat_id, _thread_scope} = key, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:clear, key})
  end

  @spec list_conversations(keyword()) :: [conversation_key()]
  def list_conversations(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_conversations)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(max_messages) when is_integer(max_messages) and max_messages > 0 do
    {:ok, %{conversations: %{}, max_messages: max_messages}}
  end

  @impl true
  def handle_cast({:add_message, {channel, chat_id, _thread_scope} = key, role, content}, state) do
    message = %{
      role: role,
      content: content,
      timestamp: DateTime.utc_now()
    }

    messages = Map.get(state.conversations, key, [])
    updated = [message | messages] |> Enum.take(state.max_messages)

    :telemetry.execute(
      [:fermix, :memory, :message],
      %{count: 1},
      %{channel: channel, chat_id: chat_id}
    )

    {:noreply, put_in(state, [:conversations, key], updated)}
  end

  def handle_cast({:clear, key}, state) do
    {:noreply, %{state | conversations: Map.delete(state.conversations, key)}}
  end

  @impl true
  def handle_call({:get_history, key, nil}, from, state) do
    handle_call({:get_history, key, state.max_messages}, from, state)
  end

  def handle_call({:get_history, key, limit}, _from, state) when is_integer(limit) do
    messages =
      state.conversations
      |> Map.get(key, [])
      |> Enum.take(limit)
      |> Enum.reverse()

    {:reply, messages, state}
  end

  def handle_call(:list_conversations, _from, state) do
    {:reply, Map.keys(state.conversations), state}
  end
end
