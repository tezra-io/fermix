defmodule FermixCore.Memory.ConversationStore do
  @moduledoc """
  Stores conversation history per chat/thread.

  Each conversation is keyed by {channel, chat_id, thread_scope}.
  Maintains a rolling window of messages with automatic compaction.
  """

  use GenServer

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo

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
    GenServer.start_link(__MODULE__, {max_messages, opts}, name: name)
  end

  @spec add_message(conversation_key(), String.t(), String.t(), keyword()) :: :ok
  def add_message({channel, chat_id, _thread_scope} = key, role, content, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) and
             is_binary(role) and is_binary(content) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:add_message, key, role, content, opts})
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
    GenServer.call(server, {:clear, key})
  end

  @spec list_conversations(keyword()) :: [conversation_key()]
  def list_conversations(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_conversations)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({max_messages, opts}) when is_integer(max_messages) and max_messages > 0 do
    {:ok,
     %{
       conversations: %{},
       max_messages: max_messages,
       repo: Keyword.get(opts, :repo, Repo),
       agent_id: Config.agent_id(opts),
       owner_id: Config.owner_id(opts)
     }}
  end

  @impl true
  def handle_call(
        {:add_message, {channel, chat_id, _thread_scope} = key, role, content, opts},
        _from,
        state
      ) do
    message = new_message(role, content)

    persist_message!(state, key, role, content, opts, message.timestamp)
    updated = append_message(state, key, message)

    :telemetry.execute(
      [:fermix, :memory, :message],
      %{count: 1},
      %{channel: channel, chat_id: chat_id}
    )

    {:reply, :ok, put_in(state, [:conversations, key], updated)}
  end

  def handle_call({:clear, key}, _from, state) do
    delete_messages!(state, key)
    {:reply, :ok, %{state | conversations: Map.delete(state.conversations, key)}}
  end

  @impl true
  def handle_call({:get_history, key, nil}, from, state) do
    handle_call({:get_history, key, state.max_messages}, from, state)
  end

  def handle_call({:get_history, key, limit}, _from, state) when is_integer(limit) do
    case Map.fetch(state.conversations, key) do
      {:ok, messages} ->
        {:reply, history_slice(messages, limit), state}

      :error ->
        reply_from_repo(state, key, limit)
    end
  end

  def handle_call(:list_conversations, _from, state) do
    {:reply, Map.keys(state.conversations), state}
  end

  defp new_message(role, content) do
    %{
      role: role,
      content: content,
      timestamp: DateTime.utc_now()
    }
  end

  defp append_message(state, key, message) do
    state.conversations
    |> Map.get(key, [])
    |> then(&[message | &1])
    |> Enum.take(state.max_messages)
  end

  defp reply_from_repo(state, key, limit) do
    repo_limit = max(limit, state.max_messages)

    case load_messages_from_repo(state, key, repo_limit) do
      {:ok, []} ->
        {:reply, [], state}

      {:ok, messages} ->
        cached = cache_window(messages, state.max_messages)
        next_state = put_in(state, [:conversations, key], cached)
        {:reply, take_recent_chronological(messages, limit), next_state}

      {:error, :disabled} ->
        {:reply, [], state}

      {:error, reason} ->
        raise "conversation repo load failed: #{inspect(reason)}"
    end
  end

  defp history_slice(messages, limit) do
    messages
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp persist_message!(state, key, role, content, opts, timestamp) do
    case repo_server(state.repo) do
      nil ->
        :ok

      repo ->
        case Repo.insert_message(
               %{
                 agent_id: Keyword.get(opts, :agent_id, state.agent_id),
                 owner_id: Keyword.get(opts, :owner_id, state.owner_id),
                 channel: elem(key, 0),
                 chat_id: elem(key, 1),
                 thread_scope: elem(key, 2),
                 sender: Keyword.get(opts, :sender, role),
                 role: role,
                 kind: Keyword.get(opts, :kind, "chat_message"),
                 content: content,
                 metadata: Keyword.get(opts, :metadata),
                 created_at: timestamp
               },
               server: repo
             ) do
          {:ok, _message} -> :ok
          {:error, :disabled} -> :ok
          {:error, reason} -> raise "conversation repo write failed: #{inspect(reason)}"
        end
    end
  end

  defp delete_messages!(state, key) do
    case repo_server(state.repo) do
      nil ->
        :ok

      repo ->
        case Repo.delete_messages(
               %{
                 agent_id: state.agent_id,
                 channel: elem(key, 0),
                 chat_id: elem(key, 1),
                 thread_scope: elem(key, 2)
               },
               server: repo
             ) do
          :ok -> :ok
          {:error, :disabled} -> :ok
          {:error, reason} -> raise "conversation repo delete failed: #{inspect(reason)}"
        end
    end
  end

  defp cache_window(messages, max_messages) do
    messages
    |> Enum.reverse()
    |> Enum.take(max_messages)
  end

  defp take_recent_chronological(messages, limit) do
    messages
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp load_messages_from_repo(state, key, limit) do
    case repo_server(state.repo) do
      nil ->
        {:error, :disabled}

      repo ->
        with {:ok, rows} <-
               Repo.get_messages(
                 %{
                   agent_id: state.agent_id,
                   channel: elem(key, 0),
                   chat_id: elem(key, 1),
                   thread_scope: elem(key, 2)
                 },
                 limit: limit,
                 server: repo
               ) do
          {:ok, Enum.map(rows, &to_history_message/1)}
        end
    end
  end

  defp to_history_message(row) do
    %{
      role: row.role,
      content: row.content,
      timestamp: row.created_at
    }
  end

  defp repo_server(repo) when is_pid(repo), do: repo

  defp repo_server(repo) when is_atom(repo) do
    if Process.whereis(repo) && Repo.enabled?(server: repo) do
      repo
    end
  end
end
