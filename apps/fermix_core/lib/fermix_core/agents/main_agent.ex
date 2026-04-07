defmodule FermixCore.Agents.MainAgent do
  @moduledoc """
  Persistent Main Agent GenServer.

  Receives channel messages, builds conversation context from history,
  runs the agent loop in a non-blocking Task, and sends responses
  back via the message's reply_fn callback.

  Started by Application supervisor with :permanent restart.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Tools.Registry

  @type channel_message :: %{
          content: String.t(),
          sender: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          reply_fn: (String.t() -> any())
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
      skill_registry: skill_registry,
      available_skills: load_available_skills(skill_registry),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_message, msg}, state) do
    Logger.info("Main Agent received message from #{msg.channel}/#{msg.chat_id}")

    task_state = state

    Task.Supervisor.start_child(state.task_supervisor, fn ->
      process_message(msg, task_state)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:reload_skills, _from, state) do
    case reload_available_skills(state.skill_registry) do
      {:ok, available_skills} ->
        {:reply, {:ok, available_skills}, %{state | available_skills: available_skills}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- Internals ---

  defp process_message(msg, state) do
    start = System.monotonic_time(:millisecond)
    conversation_key = {msg.channel, msg.chat_id}

    history = ConversationStore.get_history(conversation_key, server: state.conversation_store)

    system_message = %{role: "system", content: system_prompt(state.available_skills)}
    user_message = %{role: "user", content: msg.content}
    messages = [system_message] ++ history ++ [user_message]

    tools = Registry.all_tools_for_llm(state.registry)

    context = %{
      agent_name: "main",
      conversation_key: conversation_key
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

        msg.reply_fn.(result.response)

      {:error, reason} ->
        Logger.error("Agent loop failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :message_error],
          %{count: 1},
          %{channel: msg.channel, chat_id: msg.chat_id, reason: reason}
        )

        msg.reply_fn.("Sorry, I encountered an error processing your message.")
    end
  end

  defp system_prompt(available_skills) do
    skill_catalog =
      case available_skills do
        [] -> "Available skills snapshot: none loaded."
        skills -> "Available skills snapshot: #{Enum.join(skills, ", ")}."
      end

    """
    You are a helpful AI assistant with access to tools.
    You can execute shell commands, read and write files, and store/recall memories.
    Skills are discovered from a cached registry snapshot and only change after an explicit reload.
    #{skill_catalog}
    When you need to perform an action, use the appropriate tool. Think step by step.\
    """
  end

  defp load_available_skills(skill_registry) do
    case safe_skill_registry_call(fn -> SkillRegistry.list(skill_registry) end) do
      {:ok, skills} -> skills
      {:error, _reason} -> []
    end
  end

  defp reload_available_skills(skill_registry) do
    case safe_skill_registry_call(fn -> SkillRegistry.reload(skill_registry) end) do
      {:ok, {:ok, skills}} -> {:ok, skills}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, {:skill_registry_unavailable, reason}}
    end
  end

  defp safe_skill_registry_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, reason}
  end
end
