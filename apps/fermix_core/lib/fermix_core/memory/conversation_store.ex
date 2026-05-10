defmodule FermixCore.Memory.ConversationStore do
  @moduledoc """
  Stores conversation history per chat/thread.

  Each conversation is keyed by {channel, chat_id, thread_scope}.
  Maintains a rolling window of messages with automatic compaction.
  """

  use GenServer

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo

  require Logger

  @type thread_scope :: :root | String.t() | integer()
  @type conversation_key :: {channel :: String.t(), chat_id :: String.t(), thread_scope()}
  @type message :: %{
          role: String.t(),
          content: String.t(),
          timestamp: DateTime.t()
        }
  @type history_snapshot :: %{messages: [message()], version: non_neg_integer()}

  @max_messages_default 50
  @durable_max_attempts 3
  @durable_retry_initial_ms 100

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

  @spec get_history_snapshot(conversation_key(), keyword()) :: history_snapshot()
  def get_history_snapshot({channel, chat_id, _thread_scope} = key, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    limit = Keyword.get(opts, :limit)
    GenServer.call(server, {:get_history_snapshot, key, limit})
  end

  @spec clear(conversation_key(), keyword()) :: :ok
  def clear({channel, chat_id, _thread_scope} = key, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:clear, key})
  end

  @spec replace_history(conversation_key(), [map()], keyword()) :: :ok | {:error, :stale_history}
  def replace_history({channel, chat_id, _thread_scope} = key, messages, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) and is_list(messages) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:replace_history, key, messages, opts})
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
       clear_versions: %{},
       history_versions: %{},
       max_messages: max_messages,
       repo: Keyword.get(opts, :repo, Repo),
       agent_id: Config.agent_id(opts),
       owner_id: Config.owner_id(opts),
       durable_max_attempts: Keyword.get(opts, :durable_max_attempts, @durable_max_attempts),
       durable_retry_initial_ms:
         Keyword.get(opts, :durable_retry_initial_ms, @durable_retry_initial_ms),
       durable_task_supervisor:
         Keyword.get(opts, :durable_task_supervisor, FermixCore.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call(
        {:add_message, {channel, chat_id, _thread_scope} = key, role, content, opts},
        _from,
        state
      ) do
    start = System.monotonic_time()
    message = new_message(role, content)
    updated = append_message(state, key, message)
    version = Map.get(state.clear_versions, key, 0)

    durable? =
      enqueue_persist_message(state, key, role, content, opts, message.timestamp, version)

    duration_us = elapsed_us(start)

    :telemetry.execute(
      [:fermix, :memory, :message],
      %{count: 1, duration_us: duration_us, durable_write_us: 0},
      %{channel: channel, chat_id: chat_id, durable?: durable?}
    )

    {:reply, :ok, put_in(state, [:conversations, key], updated)}
    |> bump_history_version(key)
  end

  def handle_call({:clear, key}, _from, state) do
    next_clear_versions = Map.update(state.clear_versions, key, 1, &(&1 + 1))
    next_history_versions = bump_history_versions(state.history_versions, key)
    clear_version = Map.fetch!(next_clear_versions, key)
    history_version = Map.fetch!(next_history_versions, key)

    next_state = %{
      state
      | conversations: Map.delete(state.conversations, key),
        clear_versions: next_clear_versions,
        history_versions: next_history_versions
    }

    _durable? = enqueue_delete_history(next_state, key, clear_version, history_version)
    {:reply, :ok, next_state}
  end

  def handle_call({:replace_history, key, messages, opts}, _from, state) do
    if stale_history?(state, key, Keyword.get(opts, :expected_version)) do
      {:reply, {:error, :stale_history}, state}
    else
      normalized = Enum.map(messages, &normalize_history_message/1)
      next_clear_versions = Map.update(state.clear_versions, key, 1, &(&1 + 1))
      next_history_versions = bump_history_versions(state.history_versions, key)
      clear_version = Map.fetch!(next_clear_versions, key)
      history_version = Map.fetch!(next_history_versions, key)
      cached = cache_window(normalized, state.max_messages)

      next_state = %{
        state
        | conversations: Map.put(state.conversations, key, cached),
          clear_versions: next_clear_versions,
          history_versions: next_history_versions
      }

      _durable? =
        enqueue_replace_history(next_state, key, normalized, opts, clear_version, history_version)

      {:reply, :ok, next_state}
    end
  end

  def handle_call({:clear_version, key}, _from, state) do
    {:reply, Map.get(state.clear_versions, key, 0), state}
  end

  def handle_call({:durable_version, key}, _from, state) do
    version = {Map.get(state.clear_versions, key, 0), Map.get(state.history_versions, key, 0)}
    {:reply, version, state}
  end

  def handle_call({:get_history, key, nil}, from, state) do
    handle_call({:get_history, key, state.max_messages}, from, state)
  end

  def handle_call({:get_history, key, limit}, _from, state) when is_integer(limit) do
    {messages, next_state} = history_from_state(state, key, limit)
    {:reply, messages, next_state}
  end

  def handle_call({:get_history_snapshot, key, nil}, from, state) do
    handle_call({:get_history_snapshot, key, state.max_messages}, from, state)
  end

  def handle_call({:get_history_snapshot, key, limit}, _from, state) when is_integer(limit) do
    {messages, next_state} = history_from_state(state, key, limit)

    {:reply, %{messages: messages, version: Map.get(next_state.history_versions, key, 0)},
     next_state}
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

  defp normalize_history_message(message) when is_map(message) do
    role = Map.get(message, :role, Map.get(message, "role"))
    content = Map.get(message, :content, Map.get(message, "content"))

    unless is_binary(role) and is_binary(content) do
      raise ArgumentError,
            "replacement history messages must include binary role and content"
    end

    %{
      role: role,
      content: content,
      timestamp: normalize_timestamp(Map.get(message, :timestamp, Map.get(message, "timestamp")))
    }
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: DateTime.utc_now()

  defp append_message(state, key, message) do
    state.conversations
    |> Map.get(key, [])
    |> then(&[message | &1])
    |> Enum.take(state.max_messages)
  end

  defp history_from_state(state, key, limit) do
    case Map.fetch(state.conversations, key) do
      {:ok, messages} ->
        {history_slice(messages, limit), state}

      :error ->
        history_from_repo(state, key, limit)
    end
  end

  defp history_from_repo(state, key, limit) do
    repo_limit = max(limit, state.max_messages)

    case load_messages_from_repo(state, key, repo_limit) do
      {:ok, []} ->
        {[], state}

      {:ok, messages} ->
        cached = cache_window(messages, state.max_messages)
        next_state = put_in(state, [:conversations, key], cached)
        {take_recent_chronological(messages, limit), next_state}

      {:error, :disabled} ->
        {[], state}

      {:error, reason} ->
        raise "conversation repo load failed: #{inspect(reason)}"
    end
  end

  defp stale_history?(_state, _key, nil), do: false

  defp stale_history?(state, key, expected_version) when is_integer(expected_version) do
    Map.get(state.history_versions, key, 0) != expected_version
  end

  defp bump_history_version({:reply, reply, state}, key) do
    {:reply, reply,
     %{state | history_versions: bump_history_versions(state.history_versions, key)}}
  end

  defp bump_history_versions(history_versions, key) do
    Map.update(history_versions, key, 1, &(&1 + 1))
  end

  defp history_slice(messages, limit) do
    messages
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp enqueue_persist_message(state, key, role, content, opts, timestamp, version) do
    case configured_repo(state.repo) do
      nil ->
        false

      repo ->
        ctx = %{
          store: self(),
          key: key,
          version: version,
          repo: repo,
          attrs: message_attrs(state, key, role, content, opts, timestamp),
          max_attempts: state.durable_max_attempts,
          retry_initial_ms: state.durable_retry_initial_ms
        }

        start_persist_task(state.durable_task_supervisor, ctx)
    end
  end

  defp enqueue_delete_history(state, key, clear_version, history_version) do
    case configured_repo(state.repo) do
      nil ->
        false

      repo ->
        ctx =
          history_operation_context(state, key, repo, :delete, [], [],
            clear_version: clear_version,
            history_version: history_version
          )

        start_history_task(state.durable_task_supervisor, ctx)
    end
  end

  defp enqueue_replace_history(state, key, messages, opts, clear_version, history_version) do
    case configured_repo(state.repo) do
      nil ->
        false

      repo ->
        attrs =
          Enum.map(messages, fn message ->
            message_attrs(state, key, message.role, message.content, opts, message.timestamp)
          end)

        ctx =
          history_operation_context(state, key, repo, :replace, opts, attrs,
            clear_version: clear_version,
            history_version: history_version
          )

        start_history_task(state.durable_task_supervisor, ctx)
    end
  end

  defp history_operation_context(state, key, repo, operation, opts, attrs, versions) do
    %{
      operation: operation,
      store: self(),
      key: key,
      version:
        {Keyword.fetch!(versions, :clear_version), Keyword.fetch!(versions, :history_version)},
      repo: repo,
      selector: chat_selector(state, key, opts),
      attrs: attrs,
      max_attempts: state.durable_max_attempts,
      retry_initial_ms: state.durable_retry_initial_ms
    }
  end

  defp configured_repo(nil), do: nil

  defp configured_repo(repo) when is_pid(repo) do
    if Process.alive?(repo), do: Repo.enabled_server(repo)
  end

  defp configured_repo(repo) when is_atom(repo) do
    Repo.enabled_server(repo)
  end

  defp start_persist_task(supervisor, ctx) do
    case start_child(supervisor, fn -> persist_message(ctx, 1) end) do
      {:ok, _pid} ->
        true

      {:error, reason} ->
        Logger.error(
          "failed to start conversation durable write task for #{ctx.attrs.channel}/#{ctx.attrs.chat_id}: #{inspect(reason)}"
        )

        false
    end
  end

  defp start_history_task(supervisor, ctx) do
    case start_child(supervisor, fn -> persist_history_operation(ctx, 1) end) do
      {:ok, _pid} ->
        true

      {:error, reason} ->
        Logger.error(
          "failed to start conversation durable #{ctx.operation} task for #{ctx.selector.channel}/#{ctx.selector.chat_id}: #{inspect(reason)}"
        )

        false
    end
  end

  # `nil` means the caller explicitly opted out of supervision (test wiring,
  # mostly). Anything else is a real supervisor and a missing/dead supervisor
  # should surface as an error — we don't silently degrade to an unsupervised
  # task because that hides the supervision-tree problem and lies in the
  # `durable?` telemetry flag.
  defp start_child(nil, task), do: Task.start(task)

  defp start_child(supervisor, task) do
    Task.Supervisor.start_child(supervisor, task)
  catch
    :exit, reason -> {:error, {:task_supervisor_exit, reason}}
  end

  defp persist_message(ctx, attempt) do
    if current_clear_version(ctx.store, ctx.key) == ctx.version do
      do_persist_message(ctx, attempt)
    end
  end

  defp persist_history_operation(ctx, attempt) do
    if current_durable_version(ctx.store, ctx.key) == ctx.version do
      do_persist_history_operation(ctx, attempt)
    end
  end

  defp do_persist_message(ctx, attempt) do
    start = System.monotonic_time()

    case safe_insert_message(ctx.repo, ctx.attrs) do
      {:ok, _message} ->
        emit_persist_telemetry(ctx.attrs, attempt, elapsed_us(start), :ok, nil)

      {:error, :disabled} ->
        emit_persist_telemetry(ctx.attrs, attempt, elapsed_us(start), :disabled, :disabled)

      {:error, reason} ->
        duration_us = elapsed_us(start)
        emit_persist_telemetry(ctx.attrs, attempt, duration_us, :error, reason)
        retry_or_log_persist_failure(ctx, attempt, reason)
    end
  end

  defp current_clear_version(store, key) do
    GenServer.call(store, {:clear_version, key})
  catch
    :exit, _reason -> :cleared
  end

  defp current_durable_version(store, key) do
    GenServer.call(store, {:durable_version, key})
  catch
    :exit, _reason -> :stale
  end

  defp safe_insert_message(repo, attrs) do
    Repo.insert_message(attrs, server: repo)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_delete_messages(repo, selector) do
    Repo.delete_messages(selector, server: repo)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp do_persist_history_operation(ctx, attempt) do
    case safe_history_operation(ctx) do
      :ok ->
        :ok

      {:error, :disabled} ->
        Logger.debug(
          "conversation durable #{ctx.operation} skipped because repo is disabled for #{ctx.selector.channel}/#{ctx.selector.chat_id}"
        )

      {:error, reason} ->
        retry_or_log_history_failure(ctx, attempt, reason)
    end
  end

  defp safe_history_operation(%{operation: :delete} = ctx) do
    safe_delete_messages(ctx.repo, ctx.selector)
  end

  defp safe_history_operation(%{operation: :replace} = ctx) do
    with :ok <- safe_delete_messages(ctx.repo, ctx.selector) do
      insert_replacement_attrs(ctx.repo, ctx.attrs)
    end
  end

  defp insert_replacement_attrs(repo, attrs) do
    Enum.reduce_while(attrs, :ok, fn attrs, :ok ->
      case safe_insert_message(repo, attrs) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp retry_or_log_persist_failure(ctx, attempt, reason) do
    if attempt < ctx.max_attempts do
      delay_ms = retry_delay_ms(ctx.retry_initial_ms, attempt)

      Logger.warning(
        "conversation durable write failed; retrying attempt #{attempt + 1}/#{ctx.max_attempts} for #{ctx.attrs.channel}/#{ctx.attrs.chat_id}: #{inspect(reason)}"
      )

      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end

      persist_message(ctx, attempt + 1)
    else
      Logger.error(
        "conversation durable write failed after #{attempt} attempts for #{ctx.attrs.channel}/#{ctx.attrs.chat_id}: #{inspect(reason)}"
      )
    end
  end

  defp retry_or_log_history_failure(ctx, attempt, reason) do
    if attempt < ctx.max_attempts do
      delay_ms = retry_delay_ms(ctx.retry_initial_ms, attempt)

      Logger.warning(
        "conversation durable #{ctx.operation} failed; retrying attempt #{attempt + 1}/#{ctx.max_attempts} for #{ctx.selector.channel}/#{ctx.selector.chat_id}: #{inspect(reason)}"
      )

      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end

      persist_history_operation(ctx, attempt + 1)
    else
      Logger.error(
        "conversation durable #{ctx.operation} failed after #{attempt} attempts for #{ctx.selector.channel}/#{ctx.selector.chat_id}: #{inspect(reason)}"
      )
    end
  end

  defp retry_delay_ms(initial_ms, attempt) do
    initial_ms * Integer.pow(2, max(attempt - 1, 0))
  end

  defp emit_persist_telemetry(attrs, attempt, duration_us, status, reason) do
    metadata = %{
      channel: attrs.channel,
      chat_id: attrs.chat_id,
      role: attrs.role,
      kind: attrs.kind,
      attempt: attempt,
      status: status,
      reason: reason
    }

    :telemetry.execute(
      [:fermix, :memory, :message_persist],
      %{count: 1, duration_us: duration_us},
      metadata
    )
  end

  defp message_attrs(state, key, role, content, opts, timestamp) do
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
    }
  end

  defp chat_selector(state, key, opts) do
    %{
      agent_id: Keyword.get(opts, :agent_id, state.agent_id),
      channel: elem(key, 0),
      chat_id: elem(key, 1),
      thread_scope: elem(key, 2),
      kind: "chat_message"
    }
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
                   thread_scope: elem(key, 2),
                   kind: "chat_message"
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

  defp elapsed_us(start) do
    System.monotonic_time()
    |> Kernel.-(start)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp repo_server(nil), do: nil
  defp repo_server(repo), do: Repo.enabled_server(repo)
end
