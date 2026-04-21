defmodule FermixCore.Memory.Store do
  @moduledoc """
  ETS-backed key-value memory store with durable SQLite backing.

  Existing callers keep using conversation keys directly. Internal callers can
  also address explicit `owner`, `conversation`, or `agent` scopes without
  changing the public function arity.
  """

  use GenServer

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo

  @table :fermix_memory

  @type thread_scope :: :root | String.t() | integer()
  @type conversation_key :: {String.t(), String.t()} | {String.t(), String.t(), thread_scope()}
  @type explicit_scope ::
          {:owner, String.t()}
          | {:conversation, conversation_key()}
          | {:agent, String.t()}
  @type memory_scope :: conversation_key() | explicit_scope()

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec store(memory_scope(), String.t(), String.t(), keyword()) :: :ok
  def store(scope, key, value, opts \\ [])
      when is_binary(key) and is_binary(value) do
    assert_scope!(scope)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:store, scope, key, value})
  end

  @spec recall(memory_scope(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found}
  def recall(scope, key, opts \\ []) when is_binary(key) do
    assert_scope!(scope)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:recall, scope, key})
  end

  @spec recall_all(memory_scope(), keyword()) :: %{String.t() => String.t()}
  def recall_all(scope, opts \\ []) do
    assert_scope!(scope)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:recall_all, scope})
  end

  @spec delete(memory_scope(), String.t(), keyword()) :: :ok
  def delete(scope, key, opts \\ []) when is_binary(key) do
    assert_scope!(scope)

    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:delete, scope, key})
  end

  @spec remember(map(), keyword()) :: :ok | {:error, term()}
  def remember(attrs, opts \\ []) when is_map(attrs) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:remember, attrs})
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
  def handle_call({:store, scope, key, value}, _from, state) do
    scope_ref = normalize_scope!(scope, state)
    persist_memory!(state, scope_ref, key, value)
    put_cached_memory(state.table, scope_ref, key, value)
    {:reply, :ok, state}
  end

  def handle_call({:recall, scope, key}, _from, state) do
    scope_ref = normalize_scope!(scope, state)
    result = recall_value(state, scope_ref, key)
    {:reply, result, state}
  end

  def handle_call({:recall_all, scope}, _from, state) do
    scope_ref = normalize_scope!(scope, state)
    memories = recall_scope(state, scope_ref)
    {:reply, memories, state}
  end

  def handle_call({:delete, scope, key}, _from, state) do
    scope_ref = normalize_scope!(scope, state)
    delete_memory!(state, scope_ref, key)
    delete_cached_memory(state.table, scope_ref, key)
    {:reply, :ok, state}
  end

  def handle_call({:remember, attrs}, _from, state) do
    scope_ref = scope_ref_from_memory_attrs!(attrs)

    case persist_full_memory(state, attrs) do
      :ok ->
        put_cached_memory(
          state.table,
          scope_ref,
          Map.fetch!(attrs, :key),
          Map.fetch!(attrs, :value)
        )

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp recall_value(state, scope_ref, key) do
    case recall_cached_value(state.table, scope_ref, key) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        recall_repo_fallback(state, scope_ref, key)
    end
  end

  defp recall_repo_fallback(state, scope_ref, key) do
    case repo_server(state.repo) do
      nil -> {:error, :not_found}
      repo -> recall_repo_value(state.table, repo, scope_ref, key)
    end
  end

  defp recall_repo_value(table, repo, scope_ref, key) do
    case repo_lookup(repo, scope_ref, key) do
      {:ok, memory} ->
        put_cached_memory(table, scope_ref, key, memory.value)
        {:ok, memory.value}

      {:error, :not_found} ->
        delete_cached_memory(table, scope_ref, key)
        {:error, :not_found}

      {:error, reason} ->
        raise "memory repo recall failed: #{inspect(reason)}"
    end
  end

  defp recall_cached_value(table, scope_ref, key) do
    case :ets.lookup(table, cache_key(scope_ref, key)) do
      [{_, value, _timestamp}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  defp recall_scope(state, scope_ref) do
    case repo_server(state.repo) do
      nil -> cached_scope_memories(state.table, scope_ref)
      repo -> sync_scope_from_repo(state.table, repo, scope_ref)
    end
  end

  defp sync_scope_from_repo(table, repo, scope_ref) do
    case repo_list(repo, scope_ref) do
      {:ok, memories} ->
        replace_cached_scope(table, scope_ref, memories)
        Enum.into(memories, %{}, fn memory -> {memory.key, memory.value} end)

      {:error, reason} ->
        raise "memory repo recall_all failed: #{inspect(reason)}"
    end
  end

  defp cached_scope_memories(table, scope_ref) do
    pattern = {{namespace(scope_ref), :"$1"}, :"$2", :_}

    table
    |> :ets.match(pattern)
    |> Enum.into(%{}, fn [key, value] -> {key, value} end)
  end

  defp replace_cached_scope(table, scope_ref, memories) do
    delete_cached_scope(table, scope_ref)

    Enum.each(memories, fn memory ->
      put_cached_memory(table, scope_ref, memory.key, memory.value)
    end)
  end

  defp delete_cached_scope(table, scope_ref) do
    :ets.match_delete(table, {{namespace(scope_ref), :_}, :_, :_})
  end

  defp persist_memory!(state, scope_ref, key, value) do
    case repo_server(state.repo) do
      nil ->
        :ok

      repo ->
        case Repo.upsert_memory(repo_attrs(scope_ref, key, value), server: repo) do
          {:ok, _memory} -> :ok
          {:error, :disabled} -> :ok
          {:error, reason} -> raise "memory repo write failed: #{inspect(reason)}"
        end
    end
  end

  defp delete_memory!(state, scope_ref, key) do
    case repo_server(state.repo) do
      nil ->
        :ok

      repo ->
        case delete_repo_memory(repo, scope_ref, key) do
          :ok -> :ok
          {:error, :disabled} -> :ok
          {:error, reason} -> raise "memory repo delete failed: #{inspect(reason)}"
        end
    end
  end

  defp repo_lookup(repo, scope_ref, key) do
    case Repo.get_memory(repo_selector(scope_ref, key), server: repo) do
      {:error, :not_found} -> migrate_fallback_lookup(repo, scope_ref, key)
      result -> result
    end
  end

  defp repo_list(repo, scope_ref) do
    case Repo.get_memories(repo_scope_selector(scope_ref), server: repo) do
      {:ok, []} -> migrate_fallback_list(repo, scope_ref)
      result -> result
    end
  end

  defp repo_server(repo) when is_pid(repo), do: repo

  defp repo_server(repo) when is_atom(repo) do
    if Process.whereis(repo) && Repo.enabled?(server: repo) do
      repo
    end
  end

  defp normalize_scope!({:owner, owner_id}, state) when is_binary(owner_id) do
    scope_ref(state.agent_id, owner_id, "owner", owner_id, nil)
  end

  defp normalize_scope!({:agent, agent_id}, state) when is_binary(agent_id) do
    scope_ref(agent_id, state.owner_id, "agent", agent_id, nil)
  end

  defp normalize_scope!({:conversation, conversation_key}, state) do
    conversation_scope_ref(conversation_key, state)
  end

  defp normalize_scope!(conversation_key, state) do
    conversation_scope_ref(conversation_key, state)
  end

  defp conversation_scope_ref({channel, chat_id}, state)
       when is_binary(channel) and is_binary(chat_id) do
    scope_ref(
      state.agent_id,
      state.owner_id,
      "conversation",
      legacy_scope_id(channel, chat_id),
      fallback_scope_ref(state.agent_id, state.owner_id, channel, chat_id)
    )
  end

  defp conversation_scope_ref({channel, chat_id, thread_scope}, state)
       when is_binary(channel) and is_binary(chat_id) do
    scope_ref(
      state.agent_id,
      state.owner_id,
      "conversation",
      conversation_scope_id(channel, chat_id, thread_scope),
      nil
    )
  end

  defp scope_ref(agent_id, owner_id, scope_type, scope_id, fallback_scope_ref) do
    # All scopes stay namespaced by both agent_id and owner_id so future
    # multi-agent or multi-owner installs do not collide in SQLite or ETS.
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: scope_type,
      scope_id: scope_id,
      fallback_scope_ref: fallback_scope_ref
    }
  end

  defp repo_attrs(scope_ref, key, value) do
    %{
      agent_id: scope_ref.agent_id,
      owner_id: scope_ref.owner_id,
      scope_type: scope_ref.scope_type,
      scope_id: scope_ref.scope_id,
      category: "fact",
      key: key,
      value: value
    }
  end

  defp repo_selector(scope_ref, key) do
    repo_scope_selector(scope_ref)
    |> Map.put(:key, key)
  end

  defp repo_scope_selector(scope_ref) do
    %{
      agent_id: scope_ref.agent_id,
      owner_id: scope_ref.owner_id,
      scope_type: scope_ref.scope_type,
      scope_id: scope_ref.scope_id
    }
  end

  defp cache_key(scope_ref, key) do
    {namespace(scope_ref), key}
  end

  defp namespace(scope_ref) do
    {scope_ref.agent_id, scope_ref.owner_id, scope_ref.scope_type, scope_ref.scope_id}
  end

  defp put_cached_memory(table, scope_ref, key, value) do
    :ets.insert(table, {cache_key(scope_ref, key), value, DateTime.utc_now()})
  end

  defp persist_full_memory(state, attrs) do
    case repo_server(state.repo) do
      nil ->
        :ok

      repo ->
        case Repo.upsert_memory(attrs, server: repo) do
          {:ok, _memory} -> :ok
          {:error, :disabled} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp delete_cached_memory(table, scope_ref, key) do
    :ets.delete(table, cache_key(scope_ref, key))
  end

  defp legacy_scope_id(channel, chat_id), do: "legacy:#{channel}:#{chat_id}"

  defp fallback_scope_ref(agent_id, owner_id, channel, chat_id) do
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "conversation",
      scope_id: conversation_scope_id(channel, chat_id, :root),
      fallback_scope_ref: nil
    }
  end

  defp conversation_scope_id(channel, chat_id, thread_scope) do
    Enum.join([channel, chat_id, normalize_thread_scope(thread_scope)], ":")
  end

  defp normalize_thread_scope(:root), do: "root"
  defp normalize_thread_scope(value) when is_binary(value), do: value
  defp normalize_thread_scope(value) when is_integer(value), do: Integer.to_string(value)

  defp scope_ref_from_memory_attrs!(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      owner_id: fetch_string!(attrs, :owner_id),
      scope_type: fetch_string!(attrs, :scope_type),
      scope_id: fetch_string!(attrs, :scope_id),
      fallback_scope_ref: nil
    }
  end

  defp delete_repo_memory(repo, scope_ref, key) do
    Repo.delete_memory(repo_selector(scope_ref, key), server: repo)
  end

  defp migrate_fallback_lookup(_repo, %{fallback_scope_ref: nil}, _key), do: {:error, :not_found}

  defp migrate_fallback_lookup(repo, scope_ref, key) do
    fallback_scope_ref = scope_ref.fallback_scope_ref

    with {:ok, memory} <- Repo.get_memory(repo_selector(fallback_scope_ref, key), server: repo),
         {:ok, migrated} <- migrate_memory(repo, scope_ref, memory),
         :ok <- Repo.delete_memory(repo_selector(fallback_scope_ref, key), server: repo) do
      {:ok, migrated}
    end
  end

  defp migrate_fallback_list(_repo, %{fallback_scope_ref: nil}), do: {:ok, []}

  defp migrate_fallback_list(repo, scope_ref) do
    fallback_scope_ref = scope_ref.fallback_scope_ref

    with {:ok, []} <- Repo.get_memories(repo_scope_selector(fallback_scope_ref), server: repo) do
      {:ok, []}
    else
      {:ok, memories} ->
        with {:ok, migrated} <- migrate_memories(repo, scope_ref, memories),
             :ok <- Repo.delete_memory(repo_scope_selector(fallback_scope_ref), server: repo) do
          {:ok, migrated}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate_memories(repo, scope_ref, memories) do
    Enum.reduce_while(memories, {:ok, []}, fn memory, {:ok, acc} ->
      case migrate_memory(repo, scope_ref, memory) do
        {:ok, migrated} -> {:cont, {:ok, [migrated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, migrated} -> {:ok, Enum.reverse(migrated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_memory(repo, scope_ref, memory) do
    Repo.upsert_memory(
      %{
        agent_id: scope_ref.agent_id,
        owner_id: scope_ref.owner_id,
        scope_type: scope_ref.scope_type,
        scope_id: scope_ref.scope_id,
        category: memory.category,
        key: memory.key,
        value: memory.value,
        confidence: memory.confidence,
        promote_target: memory.promote_target,
        source_message_id: memory.source_message_id,
        created_at: memory.created_at,
        updated_at: memory.updated_at
      },
      server: repo
    )
  end

  defp assert_scope!({:owner, owner_id}) when is_binary(owner_id), do: :ok
  defp assert_scope!({:agent, agent_id}) when is_binary(agent_id), do: :ok

  defp assert_scope!({:conversation, conversation_key}) do
    assert_scope!(conversation_key)
  end

  defp assert_scope!({channel, chat_id})
       when is_binary(channel) and is_binary(chat_id) do
    :ok
  end

  defp assert_scope!({channel, chat_id, _thread_scope})
       when is_binary(channel) and is_binary(chat_id) do
    :ok
  end

  defp fetch_string!(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end
end
