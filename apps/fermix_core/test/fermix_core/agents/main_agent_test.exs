defmodule FermixCore.Agents.MainAgentTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Tools.Registry

  # -- Mock provider backed by named Agent for cross-process access --

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider

    @responses :main_agent_mock_responses
    @calls :main_agent_mock_calls

    def init do
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      {:ok, _} = Agent.start_link(fn -> [] end, name: @calls)
      :ok
    end

    def set_responses(responses) do
      Agent.update(@responses, fn _ -> responses end)
    end

    def get_calls do
      Agent.get(@calls, & &1)
    end

    def reset_calls do
      Agent.update(@calls, fn _ -> [] end)
    end

    def cleanup do
      for name <- [@responses, @calls] do
        if Process.whereis(name), do: Agent.stop(name)
      end
    end

    @impl true
    def chat(messages, opts) do
      Agent.update(@calls, fn calls -> calls ++ [{messages, opts}] end)

      Agent.get_and_update(@responses, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, "No mock responses left"}, []}
      end)
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  # -- Helpers --

  defp mock_response(content, opts \\ []) do
    tokens = Keyword.get(opts, :total_tokens, 10)

    {:ok,
     %{
       content: content,
       tool_calls: Keyword.get(opts, :tool_calls, []),
       usage: %{prompt_tokens: tokens, completion_tokens: 0, total_tokens: tokens}
     }}
  end

  defp make_message(content, opts \\ []) do
    test_pid = self()

    %{
      content: content,
      sender: Keyword.get(opts, :sender, "user123"),
      channel: Keyword.get(opts, :channel, "telegram"),
      chat_id: Keyword.get(opts, :chat_id, "chat_#{System.unique_integer([:positive])}"),
      reply_fn:
        Keyword.get(opts, :reply_fn, fn response ->
          send(test_pid, {:reply, response})
        end)
    }
  end

  defp flush_conv_store(conv_store) do
    # Synchronous call ensures all prior casts have been processed
    ConversationStore.list_conversations(server: conv_store)
  end

  defp write_skill(skills_dir, name, body \\ "You are helpful.") do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      model: gpt-5.4-mini
      capabilities: ["code"]
      allowed_tools: ["file_read"]
      max_iterations: 12
      ---
      #{body}
      """
    )
  end

  setup do
    :ok = MockProvider.init()

    suffix = System.unique_integer([:positive])
    registry_name = :"test_registry_#{suffix}"
    skill_registry_name = :"test_skill_registry_#{suffix}"
    conv_name = :"test_conv_#{suffix}"
    agent_name = :"test_main_agent_#{suffix}"
    task_sup_name = :"test_task_sup_#{suffix}"
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skills-#{suffix}")

    File.mkdir_p!(skills_dir)

    {:ok, _} =
      start_supervised({Task.Supervisor, name: task_sup_name}, id: :test_task_sup)

    {:ok, _} = start_supervised({Registry, [name: registry_name]}, id: :test_registry)

    {:ok, _} =
      start_supervised(
        {SkillRegistry, [name: skill_registry_name, skills_dir: skills_dir]},
        id: :test_skill_registry
      )

    {:ok, _} = start_supervised({ConversationStore, [name: conv_name]}, id: :test_conv)

    {:ok, _} =
      start_supervised(
        {MainAgent,
         [
           name: agent_name,
           provider: MockProvider,
           registry: registry_name,
           skill_registry: skill_registry_name,
           conversation_store: conv_name,
           task_supervisor: task_sup_name
         ]},
        id: :test_main_agent
      )

    on_exit(fn ->
      MockProvider.cleanup()
      File.rm_rf!(skills_dir)
    end)

    %{
      agent: agent_name,
      registry: registry_name,
      skill_registry: skill_registry_name,
      conv_store: conv_name,
      skills_dir: skills_dir
    }
  end

  # -- Client API --

  describe "handle_message/2" do
    test "returns response via reply_fn", %{agent: agent} do
      MockProvider.set_responses([mock_response("Hello back!")])

      msg = make_message("Hello")
      assert :ok = MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Hello back!"}, 5_000
    end

    test "stores user and assistant messages in conversation store", %{
      agent: agent,
      conv_store: conv_store
    } do
      MockProvider.set_responses([mock_response("I'm fine")])

      chat_id = "chat_#{System.unique_integer([:positive])}"
      msg = make_message("How are you?", chat_id: chat_id)
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "I'm fine"}, 5_000
      flush_conv_store(conv_store)

      history = ConversationStore.get_history({"telegram", chat_id}, server: conv_store)
      assert length(history) == 2
      [user_msg, assistant_msg] = history
      assert user_msg.role == "user"
      assert user_msg.content == "How are you?"
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == "I'm fine"
    end

    test "includes conversation history in LLM messages", %{
      agent: agent,
      conv_store: conv_store
    } do
      chat_id = "chat_#{System.unique_integer([:positive])}"
      conv_key = {"telegram", chat_id}

      # Pre-populate conversation history
      ConversationStore.add_message(conv_key, "user", "First question", server: conv_store)
      ConversationStore.add_message(conv_key, "assistant", "First answer", server: conv_store)
      flush_conv_store(conv_store)

      MockProvider.set_responses([mock_response("Follow-up answer")])

      msg = make_message("Follow-up question", chat_id: chat_id)
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Follow-up answer"}, 5_000

      # Verify provider received messages including history
      [{messages, _opts}] = MockProvider.get_calls()

      # Should have: system + 2 history messages + new user message
      assert length(messages) == 4

      [system, hist_user, hist_assistant, new_user] = messages
      assert system.role == "system"
      assert hist_user.role == "user"
      assert hist_user.content == "First question"
      assert hist_assistant.role == "assistant"
      assert hist_assistant.content == "First answer"
      assert new_user.role == "user"
      assert new_user.content == "Follow-up question"
    end

    test "sends error message via reply_fn on agent loop failure", %{agent: agent} do
      MockProvider.set_responses([{:error, "API down"}])

      msg = make_message("Hello")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, error_msg}, 5_000
      assert error_msg =~ "error"
    end

    test "is non-blocking — returns :ok before processing completes", %{agent: agent} do
      MockProvider.set_responses([mock_response("OK")])

      msg = make_message("Hello")
      assert :ok = MainAgent.handle_message(msg, agent)

      # Clean up the Task
      assert_receive {:reply, _}, 5_000
    end

    test "keeps the skill list static until reload_skills/1 is called", %{
      agent: agent,
      skills_dir: skills_dir
    } do
      MockProvider.set_responses([
        mock_response("first"),
        mock_response("second"),
        mock_response("third")
      ])

      MainAgent.handle_message(make_message("hello"), agent)
      assert_receive {:reply, "first"}, 5_000

      [{messages_before, _opts}] = MockProvider.get_calls()
      refute hd(messages_before).content =~ "coding-skill"

      write_skill(skills_dir, "coding-skill")
      MockProvider.reset_calls()

      MainAgent.handle_message(make_message("hello again"), agent)
      assert_receive {:reply, "second"}, 5_000

      [{messages_without_reload, _opts}] = MockProvider.get_calls()
      refute hd(messages_without_reload).content =~ "coding-skill"

      assert {:ok, ["coding-skill"]} = MainAgent.reload_skills(agent)
      MockProvider.reset_calls()

      MainAgent.handle_message(make_message("after reload"), agent)
      assert_receive {:reply, "third"}, 5_000

      [{messages_after_reload, _opts}] = MockProvider.get_calls()
      assert hd(messages_after_reload).content =~ "coding-skill"
    end
  end

  # -- Telemetry --

  describe "telemetry" do
    test "emits [:fermix, :agent, :message] on success", %{agent: agent} do
      test_pid = self()
      handler_id = "test-agent-message-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:fermix, :agent, :message],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      MockProvider.set_responses([mock_response("OK", total_tokens: 42)])

      msg = make_message("Test")
      MainAgent.handle_message(msg, agent)

      assert_receive {:telemetry, [:fermix, :agent, :message], measurements, metadata}, 5_000
      assert measurements.iterations == 1
      assert measurements.total_tokens == 42
      assert is_integer(measurements.duration_ms)
      assert metadata.channel == "telegram"
      assert metadata.sender == "user123"

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :agent, :message_error] on failure", %{agent: agent} do
      test_pid = self()
      handler_id = "test-agent-error-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:fermix, :agent, :message_error],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      MockProvider.set_responses([{:error, "API fail"}])

      msg = make_message("Test")
      MainAgent.handle_message(msg, agent)

      assert_receive {:telemetry, [:fermix, :agent, :message_error], _, metadata}, 5_000
      assert metadata.channel == "telegram"

      :telemetry.detach(handler_id)
    end
  end

  # -- Validation --

  describe "message validation" do
    test "rejects messages missing required fields", %{agent: agent} do
      assert_raise FunctionClauseError, fn ->
        apply(MainAgent, :handle_message, [%{content: "hi"}, agent])
      end
    end

    test "rejects non-binary content", %{agent: agent} do
      msg = %{
        content: 123,
        sender: "user",
        channel: "telegram",
        chat_id: "chat_1",
        reply_fn: fn _ -> :ok end
      }

      assert_raise FunctionClauseError, fn ->
        MainAgent.handle_message(msg, agent)
      end
    end

    test "rejects non-function reply_fn", %{agent: agent} do
      msg = %{
        content: "hi",
        sender: "user",
        channel: "telegram",
        chat_id: "chat_1",
        reply_fn: "not a function"
      }

      assert_raise FunctionClauseError, fn ->
        MainAgent.handle_message(msg, agent)
      end
    end
  end

  # -- GenServer lifecycle --

  describe "start_link/1" do
    test "starts with custom name" do
      name = :"main_agent_lifecycle_#{System.unique_integer()}"
      {:ok, pid} = MainAgent.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
