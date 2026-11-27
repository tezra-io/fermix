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

  # In-memory history is unbounded by default (`:infinity`); token-based
  # auto-compaction in `TurnRunner` is the real bound. A DB cache-miss still
  # reads only the most recent `@repo_backfill_limit` rows so an unbounded
  # in-memory window never turns into an unbounded SQLite scan.
  @max_messages_default :infinity
  @repo_backfill_limit 1_000
  @durable_max_attempts 3
  @durable_retry_initial_ms 100

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {max_messages, opts} = Keyword.pop(opts, :max_messages, configured_max_messages())
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {max_messages, opts}, name: name)
  end

  # `:max_conversation_history` is operator-configurable: `:infinity` (default,
  # no message-count cap — token compaction is the bound) or a positive integer.
  defp configured_max_messages do
    case Application.get_env(:fermix_core, :max_conversation_history, @max_messages_default) do
      :infinity ->
        :infinity

      messages when is_integer(messages) and messages > 0 ->
        messages

      other ->
        raise ArgumentError,
              "invalid :max_conversation_history #{inspect(other)}; " <>
                "expected :infinity or a positive integer"
    end
  end

  @spec add_message(conversation_key(), String.t(), String.t(), keyword()) :: :ok
  def add_message({channel, chat_id, _thread_scope} = key, role, content, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) and
             is_binary(role) and is_binary(content) do
    if blank_chat_turn?(content) do
      # A content-less chat turn carries nothing to replay — a captionless image
      # upload persisted with no text (the image rides transiently, never into
      # `content`), or an empty model completion. Replayed, it makes Anthropic
      # reject the whole call ("messages: text content blocks must be non-empty")
      # and is fragile on the OpenAI/xAI Responses shape. The store never holds
      # one — drop it at the boundary, for any role.
      :ok
    else
      server = Keyword.get(opts, :server, __MODULE__)
      GenServer.call(server, {:add_message, key, role, content, opts})
    end
  end

  @doc """
  Close an orphaned (stopped) user turn by appending an assistant marker.

  When `/stop` halts a turn mid-run, the turn's user message has already been
  persisted but no assistant reply ever commits — leaving a trailing user
  message the next turn would replay and answer. This appends a short assistant
  marker after it, but only when the conversation's last stored message is a user
  message (the orphaned turn). The query stays in history/memory; the marker
  closes the turn so it is not re-answered. Returns `:marked` when a marker was
  appended, `:skipped` when there was no orphaned user turn to close.
  """
  @spec append_stopped_marker(conversation_key(), String.t(), keyword()) :: :marked | :skipped
  def append_stopped_marker({channel, chat_id, _thread_scope} = key, content, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) and is_binary(content) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:append_stopped_marker, key, content, opts})
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
  def init({max_messages, opts})
      when max_messages == :infinity or (is_integer(max_messages) and max_messages > 0) do
    {:ok,
     %{
       conversations: %{},
       history_versions: %{},
       # Per conversation with a durable step running: that step's monitor and
       # the steps queued behind it, in call order (`enqueue_durable/3`).
       durable: %{},
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
  def handle_call({:add_message, key, role, content, opts}, _from, state) do
    state = ensure_loaded(state, key)
    bump_history_version({:reply, :ok, append_and_persist(state, key, role, content, opts)}, key)
  end

  # Guarded close for a stopped turn: append the assistant marker only when the
  # last stored message is the orphaned user turn, so we never break role
  # alternation or mark a turn that already has a reply.
  def handle_call({:append_stopped_marker, key, content, opts}, _from, state) do
    state = ensure_loaded(state, key)

    if last_message_user?(state, key) do
      marker_opts = Keyword.put_new(opts, :sender, "main")
      next_state = append_and_persist(state, key, "assistant", content, marker_opts)
      bump_history_version({:reply, :marked, next_state}, key)
    else
      {:reply, :skipped, state}
    end
  end

  def handle_call({:clear, key}, _from, state) do
    # A cleared conversation is loaded and empty, not absent: its stored rows
    # are deleted asynchronously, so they must never be read back in
    # (`ensure_loaded/2`) by a read or write that comes before the delete lands.
    next_state = %{
      state
      | conversations: Map.put(state.conversations, key, []),
        history_versions: bump_history_versions(state.history_versions, key)
    }

    {_durable?, next_state} = enqueue_delete_history(next_state, key)
    {:reply, :ok, next_state}
  end

  def handle_call({:replace_history, key, messages, opts}, _from, state) do
    if stale_history?(state, key, Keyword.get(opts, :expected_version)) do
      {:reply, {:error, :stale_history}, state}
    else
      normalized = Enum.map(messages, &normalize_history_message/1)
      cached = cache_window(normalized, state.max_messages)

      next_state = %{
        state
        | conversations: Map.put(state.conversations, key, cached),
          history_versions: bump_history_versions(state.history_versions, key)
      }

      {_durable?, next_state} = enqueue_replace_history(next_state, key, normalized, opts)
      {:reply, :ok, next_state}
    end
  end

  def handle_call({:get_history, key, nil}, from, state) do
    handle_call({:get_history, key, state.max_messages}, from, state)
  end

  def handle_call({:get_history, key, limit}, _from, state)
      when is_integer(limit) or limit == :infinity do
    {messages, next_state} = history_from_state(state, key, limit)
    {:reply, messages, next_state}
  end

  def handle_call({:get_history_snapshot, key, nil}, from, state) do
    handle_call({:get_history_snapshot, key, state.max_messages}, from, state)
  end

  def handle_call({:get_history_snapshot, key, limit}, _from, state)
      when is_integer(limit) or limit == :infinity do
    {messages, next_state} = history_from_state(state, key, limit)

    {:reply, %{messages: messages, version: Map.get(next_state.history_versions, key, 0)},
     next_state}
  end

  # A cleared conversation stays in memory as an empty history; it has no
  # messages, so it is not listed.
  def handle_call(:list_conversations, _from, state) do
    {:reply, for({key, [_ | _]} <- state.conversations, do: key), state}
  end

  # A conversation's durable step exited: start the next one, in call order.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.durable, fn {_key, running} -> running.ref == ref end) do
      {key, running} ->
        log_step_exit(key, reason)
        {:noreply, start_next_step(state, key, running.pending)}

      nil ->
        Logger.error("conversation store got a DOWN for no durable step: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.error("conversation store received an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp append_and_persist(state, {channel, chat_id, _thread_scope} = key, role, content, opts) do
    start = System.monotonic_time()
    message = new_message(role, content, opts)
    updated = append_message(state, key, message)

    {durable?, state} =
      enqueue_persist_message(state, key, role, content, opts, message.timestamp)

    :telemetry.execute(
      [:fermix, :memory, :message],
      %{count: 1, duration_us: elapsed_us(start), durable_write_us: 0},
      %{channel: channel, chat_id: chat_id, durable?: durable?}
    )

    put_in(state, [:conversations, key], updated)
  end

  # In-memory history is newest-first, so the head is the most recent message.
  defp last_message_user?(state, key) do
    case Map.get(state.conversations, key) do
      [%{role: "user"} | _rest] -> true
      _other -> false
    end
  end

  defp new_message(role, content, opts) do
    %{
      role: role,
      content: content,
      timestamp: DateTime.utc_now()
    }
    |> maybe_mark_tainted(Keyword.get(opts, :metadata))
    |> maybe_mark_guest(Keyword.get(opts, :metadata))
    |> maybe_mark_continuation(Keyword.get(opts, :metadata))
    |> maybe_mark_phone_call_result(Keyword.get(opts, :metadata))
    |> maybe_mark_forwarded(Keyword.get(opts, :metadata))
    |> maybe_mark_spoken(Keyword.get(opts, :metadata))
  end

  # Carry the Computer History taint marker on the in-memory hot path so a
  # same-process replay before any repo round-trip still sees it (MILESTONE_32
  # §13.6). Only the one narrow flag is surfaced — other metadata stays out of
  # the history maps (unchanged for every existing consumer).
  defp maybe_mark_tainted(message, %{history_tainted: true}),
    do: Map.put(message, :history_tainted, true)

  defp maybe_mark_tainted(message, _metadata), do: message

  # A guest's message keeps its marker for the same reason: compaction replaces
  # the durable history from these maps, and a retained guest message that lost
  # the marker would be re-inserted as if the owner had said it — and then read
  # by the memory review (`Repo.get_user_messages_after/4`).
  defp maybe_mark_guest(message, %{guest: true}), do: Map.put(message, :guest, true)
  defp maybe_mark_guest(message, _metadata), do: message

  # A finished coding run's notice is the vendor CLI's text, stored as a user
  # message: it keeps its marker for the same reason, so the memory review
  # never reads it as the owner's words.
  defp maybe_mark_continuation(message, %{harness_continuation: true}),
    do: Map.put(message, :harness_continuation, true)

  defp maybe_mark_continuation(message, _metadata), do: message

  # A finished phone call's report, a continuation notice too, keeps a flag of
  # its own (a boolean, never the call's id): the owner's message that answers
  # it is told by it that it answers a call's report (`Agents.TurnRunner`), so
  # a compaction's retained tail and a reload must keep it as well.
  defp maybe_mark_phone_call_result(message, %{phone_call_result: true}),
    do: Map.put(message, :phone_call_result, true)

  defp maybe_mark_phone_call_result(message, _metadata), do: message

  # A message the owner forwarded keeps its marker for the same reason: someone
  # else wrote it, and a retained one that lost the marker would be read by the
  # memory review as the owner's own words.
  defp maybe_mark_forwarded(message, %{forwarded: true}), do: Map.put(message, :forwarded, true)
  defp maybe_mark_forwarded(message, _metadata), do: message

  # A request asked aloud on a Live call keeps its marker and the call it came
  # from, for the same reason (M56 D10): a retained spoken request that lost
  # the marker would be re-inserted as something the owner typed, and then
  # read by the memory review.
  defp maybe_mark_spoken(message, %{spoken: true, call_uuid: call_uuid})
       when is_binary(call_uuid),
       do: Map.merge(message, %{spoken: true, call_uuid: call_uuid})

  defp maybe_mark_spoken(message, _metadata), do: message

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
    |> carry_taint(message)
    |> carry_guest(message)
    |> carry_continuation(message)
    |> carry_phone_call_result(message)
    |> carry_forwarded(message)
    |> carry_spoken(message)
  end

  # The Computer History taint marker (MILESTONE_32 §13.6) must survive a
  # history replacement: compaction's verbatim-retained tail rides through
  # here, and a stripped marker would let the activity-derived turn be re-sent
  # unmasked on an ungranted-remote chain once the grant lapses.
  defp carry_taint(normalized, message) do
    if Map.get(message, :history_tainted, Map.get(message, "history_tainted")) == true do
      Map.put(normalized, :history_tainted, true)
    else
      normalized
    end
  end

  defp carry_guest(normalized, message) do
    if Map.get(message, :guest, Map.get(message, "guest")) == true do
      Map.put(normalized, :guest, true)
    else
      normalized
    end
  end

  defp carry_continuation(normalized, message) do
    marked = Map.get(message, :harness_continuation, Map.get(message, "harness_continuation"))

    if marked == true do
      Map.put(normalized, :harness_continuation, true)
    else
      normalized
    end
  end

  defp carry_phone_call_result(normalized, message) do
    if Map.get(message, :phone_call_result, Map.get(message, "phone_call_result")) == true do
      Map.put(normalized, :phone_call_result, true)
    else
      normalized
    end
  end

  defp carry_forwarded(normalized, message) do
    if Map.get(message, :forwarded, Map.get(message, "forwarded")) == true do
      Map.put(normalized, :forwarded, true)
    else
      normalized
    end
  end

  defp carry_spoken(normalized, message) do
    spoken = Map.get(message, :spoken, Map.get(message, "spoken"))
    call_uuid = Map.get(message, :call_uuid, Map.get(message, "call_uuid"))

    if spoken == true and is_binary(call_uuid) do
      Map.merge(normalized, %{spoken: true, call_uuid: call_uuid})
    else
      normalized
    end
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp
  defp normalize_timestamp(_timestamp), do: DateTime.utc_now()

  defp append_message(state, key, message) do
    state.conversations
    |> Map.get(key, [])
    |> then(&[message | &1])
    |> take_limit(state.max_messages)
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
    {messages, next_state} = load_conversation(state, key, limit)
    {take_recent_chronological(messages, limit), next_state}
  end

  # Every write takes this step before it touches a conversation, as every read
  # does on a miss: a conversation absent from memory is loaded first, so a
  # message added outside any turn lands after the stored history instead of
  # standing in for it (M106 §5.8).
  defp ensure_loaded(state, key) do
    if Map.has_key?(state.conversations, key) do
      state
    else
      {_messages, next_state} = load_conversation(state, key, state.max_messages)
      next_state
    end
  end

  # The one place a conversation's entry is filled from the repo. The entry is
  # either absent or the conversation's whole history up to the store's bound,
  # never a fragment: the read takes at least that bound whatever the caller
  # asked for (`repo_read_limit/2`), and nothing is cached when there is
  # nothing stored or no repo.
  defp load_conversation(state, key, limit) do
    case load_messages_from_repo(state, key, repo_read_limit(limit, state.max_messages)) do
      {:ok, []} ->
        {[], state}

      {:ok, messages} ->
        cached = cache_window(messages, state.max_messages)
        {messages, put_in(state, [:conversations, key], cached)}

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
    |> take_limit(limit)
    |> Enum.reverse()
  end

  defp enqueue_persist_message(state, key, role, content, opts, timestamp) do
    case configured_repo(state.repo) do
      nil ->
        {false, state}

      repo ->
        ctx = %{
          operation: :insert,
          repo: repo,
          attrs: message_attrs(state, key, role, content, opts, timestamp),
          max_attempts: state.durable_max_attempts,
          retry_initial_ms: state.durable_retry_initial_ms
        }

        enqueue_durable(state, key, ctx)
    end
  end

  defp enqueue_delete_history(state, key) do
    case configured_repo(state.repo) do
      nil ->
        {false, state}

      repo ->
        ctx = history_operation_context(state, key, repo, :delete, [], [])
        enqueue_durable(state, key, ctx)
    end
  end

  defp enqueue_replace_history(state, key, messages, opts) do
    case configured_repo(state.repo) do
      nil ->
        {false, state}

      repo ->
        attrs =
          Enum.map(messages, fn message ->
            message_attrs(
              state,
              key,
              message.role,
              message.content,
              replace_message_opts(opts, message),
              message.timestamp
            )
          end)

        ctx = history_operation_context(state, key, repo, :replace, opts, attrs)
        enqueue_durable(state, key, ctx)
    end
  end

  # Per-message metadata on the durable replace: a retained message persists
  # the markers it carries — Computer History taint, guest authorship, a coding
  # run's or a phone call's notice, a forwarded message, a spoken request and
  # its call — and the backfill side re-derives them from the row's metadata;
  # an unmarked message keeps the caller's opts.
  defp replace_message_opts(opts, message) do
    markers = [
      :history_tainted,
      :guest,
      :harness_continuation,
      :phone_call_result,
      :forwarded,
      :spoken,
      :call_uuid
    ]

    case Map.take(message, markers) do
      markers when map_size(markers) == 0 -> opts
      markers -> Keyword.put(opts, :metadata, markers)
    end
  end

  defp history_operation_context(state, key, repo, operation, opts, attrs) do
    %{
      operation: operation,
      repo: repo,
      selector: history_selector(operation, state, key, opts),
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

  # A conversation's durable steps run one at a time, in the order the store's
  # calls made them: a step starts only once the step before it has exited, so
  # a later write can neither cancel an earlier replace or clear nor land
  # before it, and the database ends as the calls describe (M106 §5.8). The
  # store never waits on the database for this: a step that has to wait is
  # queued, and `handle_info/2` starts it when the step before it exits.
  # Returns whether the step was taken: started now, or queued behind one.
  defp enqueue_durable(state, key, ctx) do
    case Map.fetch(state.durable, key) do
      {:ok, running} ->
        queued = %{running | pending: :queue.in(ctx, running.pending)}
        {true, put_in(state, [:durable, key], queued)}

      :error ->
        next_state = start_next_step(state, key, :queue.from_list([ctx]))
        {Map.has_key?(next_state.durable, key), next_state}
    end
  end

  # Starts the first of `pending` that will start. One that cannot is logged
  # and dropped, so the walk is bounded by the queue.
  defp start_next_step(state, key, pending) do
    case :queue.out(pending) do
      {:empty, _pending} ->
        %{state | durable: Map.delete(state.durable, key)}

      {{:value, ctx}, rest} ->
        case start_step(state.durable_task_supervisor, ctx) do
          {:ok, ref} -> put_in(state, [:durable, key], %{ref: ref, pending: rest})
          :error -> start_next_step(state, key, rest)
        end
    end
  end

  defp start_step(supervisor, ctx) do
    case start_child(supervisor, fn -> run_step(ctx) end) do
      {:ok, pid} ->
        {:ok, Process.monitor(pid)}

      {:error, reason} ->
        log_start_failure(ctx, reason)
        :error
    end
  end

  defp run_step(%{operation: :insert} = ctx), do: do_persist_message(ctx, 1)
  defp run_step(ctx), do: do_persist_history_operation(ctx, 1)

  defp log_start_failure(%{operation: :insert} = ctx, reason) do
    Logger.error(
      "failed to start conversation durable write task for #{ctx.attrs.channel}/#{ctx.attrs.chat_id}: #{inspect(reason)}"
    )
  end

  defp log_start_failure(ctx, reason) do
    Logger.error(
      "failed to start conversation durable #{ctx.operation} task for #{ctx.selector.channel}/#{ctx.selector.chat_id}: #{inspect(reason)}"
    )
  end

  # A step ends `:normal`, or `:noproc` when it had already ended before the
  # store monitored it. Anything else is a crash, said here before the next
  # step starts.
  defp log_step_exit(_key, reason) when reason in [:normal, :noproc], do: :ok

  defp log_step_exit({channel, chat_id, _thread_scope}, reason) do
    Logger.error(
      "conversation durable write step for #{channel}/#{chat_id} exited: #{inspect(reason)}"
    )
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

  # A durable step is a background task nobody waits on, so its Repo call
  # waits its turn in the Repo's queue with no deadline: a call that timed out
  # would still run when the Repo reached it (`Repo.periodic_opts/2`), and the
  # retry would write it a second time. A Repo that is down or dies mid-call
  # still exits the call, and the bounded retry covers it.
  defp safe_insert_message(repo, attrs) do
    Repo.insert_message(attrs, server: repo, timeout: :infinity)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_delete_messages(repo, selector) do
    Repo.delete_messages(selector, server: repo, timeout: :infinity)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_replace_messages(repo, selector, rows) do
    Repo.replace_messages(selector, rows, server: repo, timeout: :infinity)
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
    safe_replace_messages(ctx.repo, ctx.selector, ctx.attrs)
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

      do_persist_message(ctx, attempt + 1)
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

      do_persist_history_operation(ctx, attempt + 1)
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

  # A clear deletes every row of the conversation, its compaction checkpoints
  # too (`Repo.delete_messages/2` reads no kind); a replace rewrites only its
  # chat messages, so the checkpoint a compaction wrote beside them survives.
  defp history_selector(:delete, state, key, opts), do: conversation_selector(state, key, opts)

  defp history_selector(:replace, state, key, opts),
    do: Map.put(conversation_selector(state, key, opts), :kind, "chat_message")

  defp conversation_selector(state, key, opts) do
    %{
      agent_id: Keyword.get(opts, :agent_id, state.agent_id),
      channel: elem(key, 0),
      chat_id: elem(key, 1),
      thread_scope: elem(key, 2)
    }
  end

  defp cache_window(messages, max_messages) do
    messages
    |> Enum.reverse()
    |> take_limit(max_messages)
  end

  defp take_recent_chronological(messages, limit) do
    messages
    |> Enum.reverse()
    |> take_limit(limit)
    |> Enum.reverse()
  end

  # `:infinity` keeps the whole list (no message-count cap); an integer caps it.
  defp take_limit(list, :infinity), do: list
  defp take_limit(list, n) when is_integer(n), do: Enum.take(list, n)

  # Bound the DB cache-miss read even when in-memory history is unbounded. The
  # read never takes less than the store's own bound (the backfill floor when
  # that is `:infinity`): what it returns is cached as the whole window, so a
  # small `limit` must not shrink it to the caller's slice. A larger `limit`
  # still reads that many rows, as `max(limit, max_messages)` always did.
  defp repo_read_limit(limit, max_messages) do
    bound = if is_integer(max_messages), do: max_messages, else: @repo_backfill_limit
    if is_integer(limit), do: max(limit, bound), else: bound
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
          # Drop any content-less rows persisted before the write guard landed,
          # so an already-poisoned history un-wedges on the next backfill instead
          # of failing every request (see `add_message/4`).
          messages =
            rows
            |> Enum.map(&to_history_message/1)
            |> Enum.reject(&blank_chat_turn?(&1.content))

          {:ok, messages}
        end
    end
  end

  # A content-less chat turn is never valid history — a captionless image upload
  # persisted with no text, or an empty model completion. It carries nothing to
  # replay and, sent to a provider, breaks Anthropic (empty text block 400) and
  # is fragile on the OpenAI/xAI Responses shape. The store neither persists one
  # (write side) nor serves one from the repo (read side), for any role.
  defp blank_chat_turn?(content) when is_binary(content), do: String.trim(content) == ""
  defp blank_chat_turn?(_content), do: false

  defp to_history_message(row) do
    %{
      role: row.role,
      content: row.content,
      timestamp: row.created_at
    }
    |> maybe_mark_tainted_from_row(row)
    |> maybe_mark_guest_from_row(row)
    |> maybe_mark_continuation_from_row(row)
    |> maybe_mark_phone_call_result_from_row(row)
    |> maybe_mark_forwarded_from_row(row)
    |> maybe_mark_spoken_from_row(row)
  end

  # The repo backfill path: the row's decoded metadata carries string keys, so
  # surface the Computer History taint marker from `"history_tainted"`
  # (MILESTONE_32 §13.6). All other metadata stays dropped, as before.
  defp maybe_mark_tainted_from_row(message, %{metadata: %{"history_tainted" => true}}),
    do: Map.put(message, :history_tainted, true)

  defp maybe_mark_tainted_from_row(message, _row), do: message

  defp maybe_mark_guest_from_row(message, %{metadata: %{"guest" => true}}),
    do: Map.put(message, :guest, true)

  defp maybe_mark_guest_from_row(message, _row), do: message

  defp maybe_mark_continuation_from_row(message, %{metadata: %{"harness_continuation" => true}}),
    do: Map.put(message, :harness_continuation, true)

  defp maybe_mark_continuation_from_row(message, _row), do: message

  defp maybe_mark_phone_call_result_from_row(
         message,
         %{metadata: %{"phone_call_result" => true}}
       ),
       do: Map.put(message, :phone_call_result, true)

  # A report stored before the flag was its own holds the call's id under the
  # same key, beside the continuation's: it is the same report.
  defp maybe_mark_phone_call_result_from_row(
         message,
         %{metadata: %{"phone_call_result" => "pc_" <> _id, "harness_continuation" => true}}
       ),
       do: Map.put(message, :phone_call_result, true)

  defp maybe_mark_phone_call_result_from_row(message, _row), do: message

  defp maybe_mark_forwarded_from_row(message, %{metadata: %{"forwarded" => true}}),
    do: Map.put(message, :forwarded, true)

  defp maybe_mark_forwarded_from_row(message, _row), do: message

  defp maybe_mark_spoken_from_row(
         message,
         %{metadata: %{"spoken" => true, "call_uuid" => call_uuid}}
       )
       when is_binary(call_uuid),
       do: Map.merge(message, %{spoken: true, call_uuid: call_uuid})

  defp maybe_mark_spoken_from_row(message, _row), do: message

  defp elapsed_us(start) do
    System.monotonic_time()
    |> Kernel.-(start)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp repo_server(nil), do: nil
  defp repo_server(repo), do: Repo.enabled_server(repo)
end
