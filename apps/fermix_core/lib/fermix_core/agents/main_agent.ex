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

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Logger.info("Main Agent started")

    state = %{
      provider: Keyword.get(opts, :provider, FermixCore.Providers.OpenAI),
      registry: Keyword.get(opts, :registry, Registry),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_message, msg}, state) do
    Logger.info("Main Agent received message from #{msg.channel}/#{msg.chat_id}")

    task_state = state
    Task.start(fn -> process_message(msg, task_state) end)

    {:noreply, state}
  end

  # --- Internals ---

  defp process_message(msg, state) do
    start = System.monotonic_time(:millisecond)
    conversation_key = {msg.channel, msg.chat_id}

    history = ConversationStore.get_history(conversation_key, server: state.conversation_store)

    system_message = %{role: "system", content: system_prompt()}
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

  defp system_prompt do
    """
    You are a helpful AI assistant with access to tools.
    You can execute shell commands, read and write files, and store/recall memories.
    When you need to perform an action, use the appropriate tool. Think step by step.\
    """
  end
end
