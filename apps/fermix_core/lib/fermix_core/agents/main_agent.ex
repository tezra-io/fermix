defmodule FermixCore.Agents.MainAgent do
  @moduledoc """
  Persistent Main Agent GenServer.

  Receives channel messages, builds conversation context from history,
  runs the agent loop in a non-blocking Task, and sends responses
  back via the message's reply_fn callback.

  Same-conversation requests are single-flight. Each conversation keeps at most
  one active request task plus one pending replacement. If a newer message
  arrives while that conversation already has work in flight, the active task is
  canceled, the pending slot is replaced with the newest message, and only that
  newest message is started once the older task exits. Different conversations
  continue independently.

  Conversation identity is `{channel, chat_id, thread_scope}`. `thread_ts` is
  the canonical threaded-conversation identifier when present. `thread_scope` is
  accepted only as a fallback conversation-key segment for direct callers that
  do not provide `thread_ts`; channel adapters should put platform thread IDs in
  `thread_ts`.

  Started by Application supervisor with :permanent restart.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Tools.Registry

  @type thread_scope :: :root | String.t() | integer()

  @type channel_message :: %{
          :content => String.t(),
          :sender => String.t(),
          :channel => String.t(),
          :chat_id => String.t(),
          :reply_fn => (String.t() -> any()),
          optional(:thread_ts) => String.t() | integer() | nil,
          optional(:thread_scope) => thread_scope() | nil
        }

  @type conversation_key :: {
          channel :: String.t(),
          chat_id :: String.t(),
          thread_scope()
        }

  @type pending_request :: %{
          request_id: pos_integer(),
          message: channel_message()
        }

  @type active_request :: %{
          request_id: pos_integer(),
          pid: pid(),
          monitor_ref: reference()
        }

  @type conversation_runtime :: %{
          next_request_id: non_neg_integer(),
          active: active_request() | nil,
          pending: pending_request() | nil
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec handle_message(channel_message(), GenServer.server()) :: :ok
  def handle_message(
        %{
          content: content,
          sender: sender,
          channel: channel,
          chat_id: chat_id,
          reply_fn: reply_fn
        } =
          msg,
        server \\ __MODULE__
      )
      when is_binary(content) and is_binary(sender) and is_binary(channel) and
             is_binary(chat_id) and is_function(reply_fn, 1) do
    GenServer.cast(server, {:handle_message, msg})
  end

  @spec reload_skills(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def reload_skills(server \\ __MODULE__) do
    GenServer.call(server, :reload_skills)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Logger.info("Main Agent started")

    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry)

    state = %{
      provider: Keyword.get(opts, :provider, FermixCore.Providers.OpenAI),
      registry: Keyword.get(opts, :registry, Registry),
      agent_supervisor: Keyword.get(opts, :agent_supervisor, AgentSupervisor),
      skill_registry: skill_registry,
      available_skills: load_available_skills(skill_registry),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      journal_base_dir: Keyword.get(opts, :journal_base_dir),
      conversations: %{},
      task_refs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_message, msg}, state) do
    conversation_key = conversation_key(msg)
    state = enqueue_latest_message(conversation_key, msg, state)

    Logger.info(
      "Main Agent received message from #{msg.channel}/#{msg.chat_id} and queued latest request"
    )

    state =
      state
      |> maybe_cancel_active_request(conversation_key)
      |> maybe_start_next_request(conversation_key)

    {:noreply, state}
  end

  @impl true
  def handle_call(:reload_skills, _from, state) do
    case reload_available_skills(state.skill_registry) do
      {:ok, names, available_skills} ->
        {:reply, {:ok, names}, %{state | available_skills: available_skills}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _task_refs} ->
        {:noreply, state}

      {conversation_key, task_refs} ->
        state =
          state
          |> Map.put(:task_refs, task_refs)
          |> clear_active_request(conversation_key, ref, reason)
          |> maybe_start_next_request(conversation_key)

        {:noreply, state}
    end
  end

  # --- Internals ---

  defp conversation_key(%{channel: channel, chat_id: chat_id} = msg) do
    {channel, chat_id, thread_scope(msg)}
  end

  defp thread_scope(%{thread_ts: thread_ts}) when not is_nil(thread_ts), do: thread_ts

  defp thread_scope(%{thread_scope: thread_scope})
       when thread_scope == :root or is_binary(thread_scope) or is_integer(thread_scope),
       do: thread_scope

  defp thread_scope(_msg), do: :root

  defp empty_conversation_runtime do
    %{next_request_id: 0, active: nil, pending: nil}
  end

  defp enqueue_latest_message(conversation_key, msg, state) do
    conversation =
      state.conversations
      |> Map.get(conversation_key, empty_conversation_runtime())
      |> Map.update!(:next_request_id, &(&1 + 1))

    pending = %{request_id: conversation.next_request_id, message: msg}

    put_conversation_runtime(state, conversation_key, %{conversation | pending: pending})
  end

  defp maybe_cancel_active_request(state, conversation_key) do
    case get_in(state, [:conversations, conversation_key, :active]) do
      nil ->
        state

      %{pid: pid, request_id: request_id} ->
        Logger.info(
          "Canceling in-flight Main Agent request #{request_id} for #{format_conversation_key(conversation_key)}"
        )

        case Task.Supervisor.terminate_child(state.task_supervisor, pid) do
          :ok ->
            state

          {:error, :not_found} ->
            state
        end
    end
  end

  defp maybe_start_next_request(state, conversation_key) do
    case Map.get(state.conversations, conversation_key, empty_conversation_runtime()) do
      %{active: nil, pending: pending_request} = conversation when not is_nil(pending_request) ->
        start_pending_request(state, conversation_key, conversation, pending_request)

      _conversation ->
        state
    end
  end

  defp start_pending_request(
         state,
         conversation_key,
         conversation,
         %{request_id: request_id, message: msg}
       ) do
    task_state = task_runtime_state(state)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           process_message(msg, task_state)
         end) do
      {:ok, pid} ->
        mark_request_started(state, conversation_key, conversation, request_id, pid)

      {:error, reason} ->
        handle_request_start_error(
          state,
          conversation_key,
          conversation,
          request_id,
          msg,
          reason
        )
    end
  end

  defp mark_request_started(state, conversation_key, conversation, request_id, pid) do
    monitor_ref = Process.monitor(pid)

    Logger.info(
      "Starting Main Agent request #{request_id} for #{format_conversation_key(conversation_key)}"
    )

    conversation = %{
      conversation
      | active: %{request_id: request_id, pid: pid, monitor_ref: monitor_ref},
        pending: nil
    }

    state
    |> put_conversation_runtime(conversation_key, conversation)
    |> update_in([:task_refs], &Map.put(&1, monitor_ref, conversation_key))
  end

  defp handle_request_start_error(
         state,
         conversation_key,
         conversation,
         request_id,
         msg,
         reason
       ) do
    Logger.error(
      "Failed to start Main Agent request #{request_id} for #{format_conversation_key(conversation_key)}: #{inspect(reason)}"
    )

    send_reply_async(msg, "Sorry, I encountered an error processing your message.")

    state
    |> put_conversation_runtime(conversation_key, %{conversation | pending: nil})
  end

  defp send_reply_async(msg, response) do
    spawn(fn -> deliver_reply(msg, response) end)
    :ok
  end

  defp clear_active_request(state, conversation_key, monitor_ref, reason) do
    case Map.get(state.conversations, conversation_key) do
      %{active: %{monitor_ref: ^monitor_ref, request_id: request_id}} = conversation ->
        Logger.info(
          "Main Agent request #{request_id} exited for #{format_conversation_key(conversation_key)} with reason #{inspect(reason)}"
        )

        put_conversation_runtime(state, conversation_key, %{conversation | active: nil})

      _conversation ->
        state
    end
  end

  defp put_conversation_runtime(state, conversation_key, %{active: nil, pending: nil}) do
    update_in(state.conversations, &Map.delete(&1, conversation_key))
  end

  defp put_conversation_runtime(state, conversation_key, conversation_runtime) do
    update_in(state.conversations, &Map.put(&1, conversation_key, conversation_runtime))
  end

  defp task_runtime_state(state) do
    %{
      provider: state.provider,
      registry: state.registry,
      skill_registry: state.skill_registry,
      agent_supervisor: state.agent_supervisor,
      available_skills: state.available_skills,
      conversation_store: state.conversation_store,
      task_supervisor: state.task_supervisor,
      journal_base_dir: state.journal_base_dir
    }
  end

  defp format_conversation_key({channel, chat_id, :root}), do: "#{channel}/#{chat_id}"

  defp format_conversation_key({channel, chat_id, thread_scope}) do
    "#{channel}/#{chat_id}/#{inspect(thread_scope)}"
  end

  defp process_message(msg, state) do
    start = System.monotonic_time(:millisecond)
    conversation_key = conversation_key(msg)

    history = ConversationStore.get_history(conversation_key, server: state.conversation_store)

    system_message = %{role: "system", content: system_prompt(state.available_skills)}
    user_message = %{role: "user", content: msg.content}
    messages = [system_message] ++ history ++ [user_message]

    tools = Registry.all_tools_for_llm(state.registry)

    context = %{
      agent_name: "main",
      conversation_key: conversation_key,
      session_id: "main-#{System.unique_integer([:positive, :monotonic])}",
      registry: state.registry,
      provider: state.provider,
      skill_registry: state.skill_registry,
      agent_supervisor: state.agent_supervisor,
      task_supervisor: state.task_supervisor,
      journal_base_dir: state.journal_base_dir
    }

    case AgentLoop.run(
           messages: messages,
           tools: tools,
           provider: state.provider,
           context: context,
           registry: state.registry
         ) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        ConversationStore.add_message(
          conversation_key,
          "user",
          msg.content,
          server: state.conversation_store
        )

        ConversationStore.add_message(
          conversation_key,
          "assistant",
          result.response,
          server: state.conversation_store
        )

        :telemetry.execute(
          [:fermix, :agent, :message],
          %{
            iterations: result.iterations,
            total_tokens: result.total_tokens,
            duration_ms: duration_ms
          },
          %{channel: msg.channel, chat_id: msg.chat_id, sender: msg.sender}
        )

        Logger.info(
          "Agent loop completed in #{result.iterations} iterations, #{result.total_tokens} tokens"
        )

        deliver_reply(msg, result.response)

      {:error, reason} ->
        Logger.error("Agent loop failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :message_error],
          %{count: 1},
          %{channel: msg.channel, chat_id: msg.chat_id, reason: reason}
        )

        deliver_reply(msg, "Sorry, I encountered an error processing your message.")
    end
  end

  defp deliver_reply(msg, response) do
    case msg.reply_fn.(response) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Main Agent reply delivery failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :reply_error],
          %{count: 1},
          %{channel: msg.channel, chat_id: msg.chat_id, reason: reason}
        )

        error

      _other ->
        :ok
    end
  end

  defp system_prompt(available_skills) do
    skill_catalog =
      case available_skills do
        [] ->
          "Available skills snapshot: none loaded."

        skills ->
          "Available skills snapshot:\n#{Enum.map_join(skills, "\n", &format_skill_summary/1)}"
      end

    """
    You are a helpful AI assistant with access to tools.
    You can execute shell commands, read and write files, and store/recall memories.
    Skills are discovered from a cached registry snapshot and only change after an explicit reload.
    Use the `invoke_skill` tool when a specialized skill is a better fit than handling the work directly.
    #{skill_catalog}
    When you need to perform an action, use the appropriate tool. Think step by step.\
    """
  end

  defp load_available_skills(skill_registry) do
    case safe_skill_registry_call(fn -> SkillRegistry.list_detailed(skill_registry) end) do
      {:ok, skills} -> skills
      {:error, _reason} -> []
    end
  end

  defp reload_available_skills(skill_registry) do
    with {:ok, {:ok, names}} <-
           safe_skill_registry_call(fn -> SkillRegistry.reload(skill_registry) end),
         {:ok, skills} <-
           safe_skill_registry_call(fn -> SkillRegistry.list_detailed(skill_registry) end) do
      {:ok, names, skills}
    else
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:skill_registry_unavailable, reason}}
    end
  end

  defp format_skill_summary(%AgentDefinition{} = skill) do
    capabilities =
      case skill.capabilities do
        [] -> "capabilities: none declared"
        list -> "capabilities: #{Enum.join(list, ", ")}"
      end

    tools =
      case skill.allowed_tools do
        [] -> "tools: none declared"
        list -> "tools: #{Enum.join(list, ", ")}"
      end

    "- #{skill.name}: #{capabilities}; #{tools}"
  end

  defp safe_skill_registry_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, reason}
  end
end
