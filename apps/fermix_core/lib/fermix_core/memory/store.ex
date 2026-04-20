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

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo

  @table :fermix_memory

  @type thread_scope :: :root | String.t() | integer()
  @type conversation_key :: {String.t(), String.t()} | {String.t(), String.t(), thread_scope()}

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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
  def init(opts) do
    table = :ets.new(@table, [:set, :private])

    {:ok,
     %{
       table: table,
       repo: Keyword.get(opts, :repo, Repo),
       agent_id: Config.agent_id(opts),
       owner_id: Config.owner_id(opts)
     }}
  end

  @impl true
  def handle_call({:store, conv_key, key, value}, _from, state) do
    persist_memory!(state, conv_key, key, value)
    :ets.insert(state.table, {{conv_key, key}, value, DateTime.utc_now()})
    {:reply, :ok, state}
  end

  def handle_call({:recall, conv_key, key}, _from, state) do
    result =
      case :ets.lookup(state.table, {conv_key, key}) do
        [{_, value, _timestamp}] -> {:ok, value}
        [] -> recall_from_repo(state, conv_key, key)
      end

    {:reply, result, state}
  end

  def handle_call({:recall_all, conv_key}, _from, state) do
    hydrate_conversation_from_repo(state, conv_key)

    memories =
      state.table
      |> recall_all_from_table(conv_key)

    {:reply, memories, state}
  end

  def handle_call({:delete, conv_key, key}, _from, state) do
    delete_memory!(state, conv_key, key)
    :ets.delete(state.table, {conv_key, key})
    {:reply, :ok, state}
  end

  defp recall_all_from_table(table, conv_key) do
    pattern = {{conv_key, :"$1"}, :"$2", :_}

    table
    |> :ets.match(pattern)
    |> Enum.into(%{}, fn [key, value] -> {key, value} end)
  end

  defp recall_from_repo(state, conv_key, key) do
    case repo_lookup(state, conv_key, key) do
      {:ok, memory} ->
        :ets.insert(state.table, {{conv_key, key}, memory.value, DateTime.utc_now()})
        {:ok, memory.value}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        raise "memory repo recall failed: #{inspect(reason)}"
    end
  end

  defp hydrate_conversation_from_repo(state, conv_key) do
    case repo_list(state, conv_key) do
      {:ok, memories} ->
        Enum.each(memories, fn memory ->
          :ets.insert(state.table, {{conv_key, memory.key}, memory.value, DateTime.utc_now()})
        end)

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        raise "memory repo recall_all failed: #{inspect(reason)}"
    end
  end

  defp persist_memory!(state, conv_key, key, value) do
    case maybe_upsert_repo(state, conv_key, key, value) do
      :ok -> :ok
      {:error, :disabled} -> :ok
      {:error, reason} -> raise "memory repo write failed: #{inspect(reason)}"
    end
  end

  defp delete_memory!(state, conv_key, key) do
    case maybe_delete_repo(state, conv_key, key) do
      :ok -> :ok
      {:error, :disabled} -> :ok
      {:error, reason} -> raise "memory repo delete failed: #{inspect(reason)}"
    end
  end

  defp maybe_upsert_repo(state, conv_key, key, value) do
    case repo_server(state.repo) do
      nil ->
        {:error, :disabled}

      repo ->
        Repo.upsert_memory(
          %{
            agent_id: state.agent_id,
            owner_id: state.owner_id,
            scope_type: "conversation",
            scope_id: scope_id(conv_key),
            category: "fact",
            key: key,
            value: value
          },
          server: repo
        )
        |> to_ok()
    end
  end

  defp maybe_delete_repo(state, conv_key, key) do
    case repo_server(state.repo) do
      nil ->
        {:error, :disabled}

      repo ->
        Repo.delete_memory(
          %{
            agent_id: state.agent_id,
            owner_id: state.owner_id,
            scope_type: "conversation",
            scope_id: scope_id(conv_key),
            key: key
          },
          server: repo
        )
    end
  end

  defp repo_lookup(state, conv_key, key) do
    case repo_server(state.repo) do
      nil ->
        {:error, :not_found}

      repo ->
        Repo.get_memory(
          %{
            agent_id: state.agent_id,
            owner_id: state.owner_id,
            scope_type: "conversation",
            scope_id: scope_id(conv_key),
            key: key
          },
          server: repo
        )
    end
  end

  defp repo_list(state, conv_key) do
    case repo_server(state.repo) do
      nil ->
        {:error, :disabled}

      repo ->
        Repo.get_memories(
          %{
            agent_id: state.agent_id,
            owner_id: state.owner_id,
            scope_type: "conversation",
            scope_id: scope_id(conv_key)
          },
          server: repo
        )
    end
  end

  defp repo_server(repo) when is_pid(repo), do: repo

  defp repo_server(repo) when is_atom(repo) do
    if Process.whereis(repo) && Repo.enabled?(server: repo) do
      repo
    end
  end

  defp to_ok({:ok, _value}), do: :ok
  defp to_ok(other), do: other

  defp scope_id({channel, chat_id}), do: Enum.join([channel, chat_id, "root"], ":")

  defp scope_id({channel, chat_id, thread_scope}) do
    Enum.join([channel, chat_id, normalize_thread_scope(thread_scope)], ":")
  end

  defp normalize_thread_scope(:root), do: "root"
  defp normalize_thread_scope(value) when is_binary(value), do: value
  defp normalize_thread_scope(value) when is_integer(value), do: Integer.to_string(value)

  defp assert_conversation_key!({channel, chat_id})
       when is_binary(channel) and is_binary(chat_id) do
    :ok
  end

  defp assert_conversation_key!({channel, chat_id, _thread_scope})
       when is_binary(channel) and is_binary(chat_id) do
    :ok
  end
end
