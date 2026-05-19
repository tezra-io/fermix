defmodule FermixCore.Agents.MainAgentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults

  # -- Mock provider backed by named Agent for cross-process access --

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @responses :main_agent_mock_responses
    @calls :main_agent_mock_calls
    @test_pid :main_agent_mock_test_pid

    def init(test_pid \\ self()) do
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      {:ok, _} = Agent.start_link(fn -> [] end, name: @calls)
      {:ok, _} = Agent.start_link(fn -> test_pid end, name: @test_pid)
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
      for name <- [@responses, @calls, @test_pid] do
        case Process.whereis(name) do
          nil ->
            :ok

          _pid ->
            try do
              Agent.stop(name)
            catch
              :exit, _reason -> :ok
            end
        end
      end
    end

    @impl FermixCore.Providers.Provider
    def chat(messages, opts) do
      record_and_reply(messages, opts)
    end

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    # --- Adapter interface ---

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, opts) do
      adapter_opts = Keyword.put(opts, :capabilities, capabilities)

      case record_and_reply(messages, adapter_opts) do
        {:ok, response} -> {:ok, to_turn(response, messages, capabilities)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl FermixCore.Providers.Adapter
    def continue(provider_state, tool_results, opts) do
      capabilities = Map.get(provider_state, :capabilities, [])

      tool_messages =
        Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
          %{role: "tool", tool_call_id: call_id, content: to_string(output)}
        end)

      prior = Map.get(provider_state, :messages, [])
      next_messages = prior ++ tool_messages

      adapter_opts = Keyword.put(opts, :capabilities, capabilities)

      case record_and_reply(next_messages, adapter_opts) do
        {:ok, response} -> {:ok, to_turn(response, next_messages, capabilities)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp to_turn(%{content: content, usage: usage} = response, messages, capabilities) do
      tool_calls = normalize_tool_calls(Map.get(response, :tool_calls, []))
      assistant = build_assistant_message(content, tool_calls)

      %{
        content: content || "",
        tool_calls: tool_calls,
        provider_state: %{
          messages: messages ++ [assistant],
          capabilities: capabilities
        },
        usage: usage,
        model: Map.get(response, :model, "mock-model")
      }
    end

    defp build_assistant_message(content, []) do
      %{role: "assistant", content: content || ""}
    end

    defp build_assistant_message(content, tool_calls) do
      %{role: "assistant", content: content || "", tool_calls: tool_calls}
    end

    defp normalize_tool_calls(calls) do
      Enum.map(calls, fn
        %{"id" => id, "function" => %{"name" => name, "arguments" => args}} ->
          %{id: id, call_id: id, name: name, arguments: args}

        %{name: _name, arguments: _args} = call ->
          Map.put_new(call, :call_id, Map.get(call, :id))
      end)
    end

    defp record_and_reply(messages, opts) do
      Agent.update(@calls, fn calls -> calls ++ [{messages, opts}] end)

      user_content =
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: "user", content: content} -> content
          _ -> nil
        end)

      test_pid = Agent.get(@test_pid, & &1)
      send(test_pid, {:mock_provider_called, user_content, self(), messages, opts})

      Agent.get_and_update(@responses, fn
        [{:block, tag, next} | rest] ->
          send(test_pid, {:mock_provider_blocked, tag, self()})

          result =
            receive do
              {:continue, ^tag} -> next
            end

          {result, rest}

        [next | rest] ->
          {next, rest}

        [] ->
          {{:error, "No mock responses left"}, []}
      end)
    end
  end

  defmodule ControlledProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @state :main_agent_controlled_provider

    def init(test_pid \\ self()) do
      cleanup()

      {:ok, _} =
        Agent.start_link(
          fn -> %{calls: [], plans: %{}, test_pid: test_pid} end,
          name: @state
        )

      :ok
    end

    def set_plans(plans) when is_map(plans) do
      Agent.update(@state, fn state -> %{state | plans: plans, calls: []} end)
    end

    def get_calls do
      Agent.get(@state, & &1.calls)
    end

    def cleanup do
      if Process.whereis(@state), do: Agent.stop(@state)
    end

    @impl FermixCore.Providers.Provider
    def chat(messages, opts), do: dispatch(messages, opts)

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["controlled-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, opts) do
      case dispatch(messages, Keyword.put(opts, :capabilities, capabilities)) do
        {:ok, response} -> {:ok, to_turn(response, messages, capabilities)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl FermixCore.Providers.Adapter
    def continue(provider_state, tool_results, opts) do
      capabilities = Map.get(provider_state, :capabilities, [])

      tool_messages =
        Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
          %{role: "tool", tool_call_id: call_id, content: to_string(output)}
        end)

      prior = Map.get(provider_state, :messages, [])
      next_messages = prior ++ tool_messages

      case dispatch(next_messages, Keyword.put(opts, :capabilities, capabilities)) do
        {:ok, response} -> {:ok, to_turn(response, next_messages, capabilities)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp to_turn(%{content: content, usage: usage} = response, messages, capabilities) do
      tool_calls = normalize_tool_calls(Map.get(response, :tool_calls, []))
      assistant = build_assistant_message(content, tool_calls)

      %{
        content: content || "",
        tool_calls: tool_calls,
        provider_state: %{
          messages: messages ++ [assistant],
          capabilities: capabilities
        },
        usage: usage,
        model: Map.get(response, :model, "controlled-model")
      }
    end

    defp build_assistant_message(content, []) do
      %{role: "assistant", content: content || ""}
    end

    defp build_assistant_message(content, tool_calls) do
      %{role: "assistant", content: content || "", tool_calls: tool_calls}
    end

    defp normalize_tool_calls(calls) do
      Enum.map(calls, fn
        %{"id" => id, "function" => %{"name" => name, "arguments" => args}} ->
          %{id: id, call_id: id, name: name, arguments: args}

        %{name: _name, arguments: _args} = call ->
          Map.put_new(call, :call_id, Map.get(call, :id))
      end)
    end

    defp dispatch(messages, opts) do
      user_content =
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: "user", content: content} -> content
          _ -> nil
        end)

      {plan, test_pid} =
        Agent.get_and_update(@state, fn state ->
          updated_calls = state.calls ++ [{user_content, messages, opts}]
          plan = Map.fetch!(state.plans, user_content)
          {{plan, state.test_pid}, %{state | calls: updated_calls}}
        end)

      send(test_pid, {:controlled_provider_called, user_content, self(), messages, opts})

      case plan do
        {:block, response} ->
          receive do
            {:continue, ^user_content} -> response
          end

        response ->
          response
      end
    end
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

    raw_reply_fn =
      Keyword.get(opts, :reply_fn, fn response ->
        send(test_pid, {:reply, response})
      end)

    message = %{
      content: content,
      sender: Keyword.get(opts, :sender, "user123"),
      channel: Keyword.get(opts, :channel, "telegram"),
      chat_id: Keyword.get(opts, :chat_id, "chat_#{System.unique_integer([:positive])}"),
      reply_fn: fn response -> raw_reply_fn.(reply_payload(response)) end
    }

    opts
    |> Keyword.take([
      :thread_ts,
      :thread_scope,
      :metadata,
      :chat_mode,
      :typing_fn,
      :typing_interval_ms,
      :typing_timeout_ms,
      :source_trust
    ])
    |> Enum.into(message)
    # Mirror the dispatcher: an authorized inbound message arrives at
    # MainAgent with `:source_trust` set. Tests that don't care about
    # trust default to `:operator` (the human owner's surface).
    |> Map.put_new(:source_trust, :operator)
  end

  defp reply_payload({:text, text}), do: text
  defp reply_payload(response), do: response

  defp tool_call(id, name, arguments) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
    }
  end

  defp mcp_capability(name) do
    Capability.new(%{
      name: name,
      description: "MCP fixture",
      parameters: %{type: "object", properties: %{}},
      kind: :mcp,
      executor: {__MODULE__, :unused_capability_execute, []},
      policy_class: :external_api
    })
  end

  def unused_capability_execute(_args, _context), do: {:ok, %{success: true, output: "unused"}}

  defp flush_conv_store(conv_store) do
    # Synchronous call ensures all prior casts have been processed
    ConversationStore.list_conversations(server: conv_store)
  end

  defp runtime_message(messages) do
    Enum.find(messages, &(&1.role == "system" and &1.content =~ "## Runtime Contract"))
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

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
    skill_registry_name = :"test_skill_registry_#{suffix}"
    capability_registry_name = :"test_capability_registry_#{suffix}"
    conv_name = :"test_conv_#{suffix}"
    agent_name = :"test_main_agent_#{suffix}"
    task_sup_name = :"test_task_sup_#{suffix}"
    agent_supervisor_name = :"test_agent_supervisor_#{suffix}"
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skills-#{suffix}")
    journal_dir = Path.join(System.tmp_dir!(), "fermix-journals-#{suffix}")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-prompt-memory-#{suffix}")
    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-bootstrap-#{suffix}")
    previous_memory_config = Application.get_env(:fermix_core, :memory, [])
    previous_compaction_config = Application.get_env(:fermix_core, :compaction, [])
    previous_bootstrap_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])

    File.mkdir_p!(skills_dir)
    File.mkdir_p!(prompt_dir)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory_config, prompt_base_dir: prompt_dir, agent_id: "main")
    )

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: bootstrap_dir,
      accounting_enabled: true
    )

    {:ok, _} =
      start_supervised({Task.Supervisor, name: task_sup_name}, id: :test_task_sup)

    {:ok, _} =
      start_supervised({CapabilityRegistry, [name: capability_registry_name]},
        id: :test_capability_registry
      )

    {:ok, _} =
      start_supervised(
        {SkillRegistry,
         [
           name: skill_registry_name,
           skills_dir: skills_dir,
           seed_defaults: false,
           capability_registry: capability_registry_name
         ]},
        id: :test_skill_registry
      )

    {:ok, _} = start_supervised({ConversationStore, [name: conv_name]}, id: :test_conv)

    {:ok, _} =
      start_supervised({AgentSupervisor, [name: agent_supervisor_name]},
        id: :test_agent_supervisor
      )

    {:ok, _} =
      start_supervised(
        {MainAgent,
         [
           name: agent_name,
           provider: MockProvider,
           capability_registry: capability_registry_name,
           agent_supervisor: agent_supervisor_name,
           skill_registry: skill_registry_name,
           conversation_store: conv_name,
           task_supervisor: task_sup_name,
           journal_base_dir: journal_dir
         ]},
        id: :test_main_agent
      )

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_memory_config)
      Application.put_env(:fermix_core, :compaction, previous_compaction_config)
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap_config)
      MockProvider.cleanup()
      FermixTestSupport.SafeRm.rm_rf!(skills_dir)
      FermixTestSupport.SafeRm.rm_rf!(journal_dir)
      FermixTestSupport.SafeRm.rm_rf!(prompt_dir)
      FermixTestSupport.SafeRm.rm_rf!(bootstrap_dir)
    end)

    %{
      agent: agent_name,
      skill_registry: skill_registry_name,
      capability_registry: capability_registry_name,
      conv_store: conv_name,
      skills_dir: skills_dir,
      task_supervisor: task_sup_name,
      agent_supervisor: agent_supervisor_name,
      journal_dir: journal_dir,
      prompt_dir: prompt_dir,
      bootstrap_dir: bootstrap_dir
    }
  end

  defp stub_chat_and_summary(summary) do
    test_pid = self()
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      kind = request_kind(decoded)
      send(test_pid, {:provider_request, kind, decoded})

      response =
        case kind do
          :summary -> chat_completion_response(summary, decoded["model"])
          :chat -> chat_completion_response("assistant reply", decoded["model"])
        end

      Req.Test.json(conn, response)
    end)
  end

  defp request_kind(%{"messages" => messages}) do
    if Enum.any?(messages, &(get_in(&1, ["content"]) =~ "Summarize older conversation")) do
      :summary
    else
      :chat
    end
  end

  defp request_kind(_decoded), do: :chat

  defp chat_completion_response(content, model) do
    %{
      "model" => model || "custom-small",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
    }
  end

  # -- Client API --

  describe "status/1" do
    test "reports active request counts without exposing message content", %{agent: agent} do
      MockProvider.set_responses([{:block, :status_probe, mock_response("done")}])

      msg = make_message("private status content")
      assert :ok = MainAgent.handle_message(msg, agent)

      assert_receive {:mock_provider_blocked, :status_probe, provider_pid}, 5_000

      status = MainAgent.status(agent)

      assert status.name == "main"
      assert status.health == :online
      assert status.activity == :running
      assert status.status == :running
      assert is_pid(status.pid)
      assert status.active_conversations == 1
      assert status.pending_conversations == 0
      assert status.active_requests == 1
      assert status.pending_requests == 0
      assert status.available_skills == ["self_knowledge"]
      assert status.memory.agent_id == "main"
      assert status.memory.owner_id == "default"
      refute inspect(status) =~ "private status content"

      send(provider_pid, {:continue, :status_probe})
      assert_receive {:reply, "done"}, 5_000
    end
  end

  describe "handle_message/2" do
    test "returns response via reply_fn", %{agent: agent} do
      MockProvider.set_responses([mock_response("Hello back!")])

      msg = make_message("Hello")
      assert :ok = MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Hello back!"}, 5_000
    end

    test "runs typing_fn while a request is active and stops after reply", %{agent: agent} do
      test_pid = self()

      MockProvider.set_responses([{:block, :typing_probe, mock_response("done")}])

      msg =
        make_message("Slow request",
          typing_interval_ms: 20,
          typing_timeout_ms: 500,
          typing_fn: fn ->
            send(test_pid, :typing_tick)
            :ok
          end
        )

      assert :ok = MainAgent.handle_message(msg, agent)

      assert_receive :typing_tick, 500
      assert_receive {:mock_provider_blocked, :typing_probe, provider_pid}, 5_000
      assert_receive :typing_tick, 200

      send(provider_pid, {:continue, :typing_probe})
      assert_receive {:reply, "done"}, 5_000
      refute_receive :typing_tick, 100
    end

    test "continues the request when typing_fn reports an expected adapter error", %{agent: agent} do
      MockProvider.set_responses([mock_response("done")])

      msg =
        make_message("Request with typing transport failure",
          typing_fn: fn -> {:error, %Req.TransportError{reason: :econnrefused}} end
        )

      assert :ok = MainAgent.handle_message(msg, agent)
      assert_receive {:reply, "done"}, 5_000
    end

    test "does not swallow unexpected typing_fn exceptions as healthy requests", %{agent: agent} do
      test_pid = self()
      MockProvider.set_responses([{:block, :typing_raise_probe, mock_response("done")}])

      msg =
        make_message("Request with broken typing callback",
          typing_fn: fn ->
            send(test_pid, :typing_called)
            raise ArgumentError, "broken typing callback"
          end
        )

      capture_log(fn ->
        assert :ok = MainAgent.handle_message(msg, agent)
        assert_receive :typing_called, 500
        assert eventually(fn -> MainAgent.status(agent).active_requests == 0 end)
      end)

      refute_receive {:reply, _response}, 100

      receive do
        {:mock_provider_blocked, :typing_raise_probe, provider_pid} ->
          send(provider_pid, {:continue, :typing_raise_probe})
      after
        0 -> :ok
      end
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

      history = ConversationStore.get_history({"telegram", chat_id, :root}, server: conv_store)
      assert length(history) == 2
      [user_msg, assistant_msg] = history
      assert user_msg.role == "user"
      assert user_msg.content == "How are you?"
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == "I'm fine"
    end

    test "auto-compacts stored history after a turn when threshold is crossed", %{
      capability_registry: capability_registry,
      skill_registry: skill_registry,
      agent_supervisor: agent_supervisor,
      conv_store: conv_store,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      stub_chat_and_summary("auto summary")

      memory_config = Application.get_env(:fermix_core, :memory, [])

      # Disable the M4 in-loop compactor so this test isolates M7.1 post-turn
      # durable history compaction.
      Application.put_env(
        :fermix_core,
        :memory,
        Keyword.put(memory_config, :compaction_enabled, false)
      )

      Application.put_env(:fermix_core, :compaction, enabled: true, threshold: 0.1)

      agent_name = :"auto_compaction_agent_#{System.unique_integer([:positive])}"

      start_supervised!(
        {MainAgent,
         [
           name: agent_name,
           provider: nil,
           adapter_overrides: [
             provider: :openai,
             model: "custom-small",
             base_url: "https://openrouter.ai/api/v1",
             api_key: "sk-test",
             req_options: [plug: {Req.Test, __MODULE__}]
           ],
           capability_registry: capability_registry,
           agent_supervisor: agent_supervisor,
           skill_registry: skill_registry,
           conversation_store: conv_store,
           task_supervisor: task_supervisor,
           journal_base_dir: journal_dir,
           extraction_enabled: false
         ]},
        id: agent_name
      )

      chat_id = "auto_chat_#{System.unique_integer([:positive])}"
      long_content = String.duplicate("older turn ", 25_000)

      assert :ok =
               MainAgent.handle_message(
                 make_message(long_content, chat_id: chat_id),
                 agent_name
               )

      assert_receive {:provider_request, :chat, _decoded}, 5_000
      assert_receive {:reply, "assistant reply"}, 5_000
      assert_receive {:provider_request, :summary, _decoded}, 5_000

      assert eventually(fn ->
               history =
                 ConversationStore.get_history({"telegram", chat_id, :root}, server: conv_store)

               Enum.any?(history, &(&1.content =~ "auto summary")) and
                 not Enum.any?(history, &(&1.content == long_content))
             end)

      history = ConversationStore.get_history({"telegram", chat_id, :root}, server: conv_store)
      assert Enum.map(history, & &1.role) == ["system", "assistant"]
      assert List.last(history).content == "assistant reply"
    end

    test "auto-compaction follows direct adapter wiring", %{
      agent: agent,
      conv_store: conv_store
    } do
      memory_config = Application.get_env(:fermix_core, :memory, [])

      Application.put_env(
        :fermix_core,
        :memory,
        Keyword.put(memory_config, :compaction_enabled, false)
      )

      Application.put_env(:fermix_core, :compaction, enabled: true, threshold: 0.1)

      MockProvider.set_responses([
        mock_response("assistant reply"),
        mock_response("direct summary")
      ])

      chat_id = "direct_auto_chat_#{System.unique_integer([:positive])}"
      long_content = String.duplicate("direct adapter turn ", 25_000)

      assert :ok =
               MainAgent.handle_message(
                 make_message(long_content, chat_id: chat_id),
                 agent
               )

      assert_receive {:mock_provider_called, ^long_content, _pid, _messages, _opts}, 5_000
      assert_receive {:reply, "assistant reply"}, 5_000
      assert_receive {:mock_provider_called, summary_prompt, _pid, _messages, summary_opts}, 5_000

      assert summary_prompt =~ "Older messages:"
      refute Keyword.has_key?(summary_opts, :temperature)

      assert eventually(fn ->
               history =
                 ConversationStore.get_history({"telegram", chat_id, :root}, server: conv_store)

               Enum.any?(history, &(&1.content =~ "direct summary")) and
                 not Enum.any?(history, &(&1.content == long_content))
             end)
    end

    test "bounds remembered auto-compaction failures", %{agent: agent} do
      for index <- 1..600 do
        assert :ok =
                 GenServer.call(
                   agent,
                   {:record_auto_compaction_failure, {"telegram", "chat-#{index}", :root}, index}
                 )
      end

      state = :sys.get_state(agent)
      assert map_size(state.compaction_failures) <= 512
      refute Map.has_key?(state.compaction_failures, {"telegram", "chat-1", :root})
      assert Map.has_key?(state.compaction_failures, {"telegram", "chat-600", :root})
    end

    test "includes conversation history in LLM messages", %{
      agent: agent,
      conv_store: conv_store
    } do
      chat_id = "chat_#{System.unique_integer([:positive])}"
      conv_key = {"telegram", chat_id, :root}

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

      # Should have: composed systems + 2 history messages + new user message
      assert length(messages) == 6

      [identity, agents, runtime, hist_user, hist_assistant, new_user] = messages
      assert identity.role == "system"
      assert identity.content == Defaults.identity_md()
      assert agents.role == "system"
      assert agents.content == Defaults.agents_md()
      assert runtime.role == "system"
      assert runtime.content =~ "## Runtime Contract"
      assert hist_user.role == "user"
      assert hist_user.content == "First question"
      assert hist_assistant.role == "assistant"
      assert hist_assistant.content == "First answer"
      assert new_user.role == "user"
      assert new_user.content == "Follow-up question"
    end

    test "continues without prompt-memory injection when files are missing", %{agent: agent} do
      MockProvider.set_responses([mock_response("No prompt files")])

      msg = make_message("Hello without memory files")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "No prompt files"}, 5_000

      [{messages, _opts}] = MockProvider.get_calls()
      [identity, agents, runtime, user] = messages
      assert identity.role == "system"
      assert agents.role == "system"
      assert runtime.role == "system"
      refute Enum.any?(messages, &(&1.content =~ "## Preferences"))
      refute Enum.any?(messages, &(&1.content =~ "## Working Rules"))
      assert user.content == "Hello without memory files"
    end

    test "uses in-memory bootstrap fallbacks without writing to disk", %{
      agent: agent,
      bootstrap_dir: bootstrap_dir
    } do
      identity_path = BootstrapPaths.identity_path("main")
      agents_path = BootstrapPaths.agents_path("main")
      refute File.exists?(identity_path)
      refute File.exists?(agents_path)

      MockProvider.set_responses([mock_response("Fallback prompt")])

      MainAgent.handle_message(make_message("Hello first run"), agent)

      assert_receive {:reply, "Fallback prompt"}, 5_000

      [{messages, _opts}] = MockProvider.get_calls()
      [identity, agents, runtime, user] = messages

      refute File.exists?(identity_path)
      refute File.exists?(agents_path)
      refute File.exists?(bootstrap_dir)

      assert identity.content == Defaults.identity_md()
      assert agents.content == Defaults.agents_md()
      assert runtime.content =~ "## Runtime Contract"
      assert user.content == "Hello first run"
    end

    test "ignores empty prompt-memory files", %{agent: agent} do
      File.mkdir_p!(Path.dirname(PromptFiles.user_path("main")))
      File.write!(PromptFiles.user_path("main"), "\n\n")
      File.write!(PromptFiles.memory_path("main"), "")

      MockProvider.set_responses([mock_response("Empty prompt files")])

      msg = make_message("Hello with empty files")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Empty prompt files"}, 5_000

      [{messages, _opts}] = MockProvider.get_calls()
      [identity, agents, runtime, user] = messages
      assert identity.role == "system"
      assert agents.role == "system"
      assert runtime.role == "system"
      refute Enum.any?(messages, &(&1.content =~ "## Preferences"))
      refute Enum.any?(messages, &(&1.content =~ "## Working Rules"))
      assert user.content == "Hello with empty files"
    end

    test "injects prompt-memory file contents as ordered system prompts", %{agent: agent} do
      File.mkdir_p!(Path.dirname(PromptFiles.user_path("main")))
      File.write!(PromptFiles.user_path("main"), "## Preferences\n- editor: vim\n")
      File.write!(PromptFiles.memory_path("main"), "## Working Rules\n- warnings are errors\n")

      MockProvider.set_responses([mock_response("Prompt memory loaded")])

      msg = make_message("Hello with prompt memory")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Prompt memory loaded"}, 5_000

      [{messages, _opts}] = MockProvider.get_calls()
      [identity, agents, memory_context, runtime, user] = messages
      assert identity.role == "system"
      assert agents.role == "system"
      assert memory_context.content =~ "<memory-context>"
      assert memory_context.content =~ "USER PROFILE (who the user is)"
      assert memory_context.content =~ "## Preferences\n- editor: vim"
      assert memory_context.content =~ "MEMORY (agent's working notes)"
      assert memory_context.content =~ "## Working Rules\n- warnings are errors"
      assert runtime.content =~ "## Runtime Contract"
      assert user.content == "Hello with prompt memory"
    end

    test "sends composed bootstrap and runtime prompts through the live request path", %{
      agent: agent
    } do
      File.mkdir_p!(BootstrapPaths.agent_dir("main"))
      File.write!(BootstrapPaths.identity_path("main"), "IDENTITY bootstrap")
      File.write!(BootstrapPaths.soul_path("main"), "SOUL bootstrap")
      File.write!(BootstrapPaths.agents_path("main"), "AGENTS bootstrap")
      File.mkdir_p!(Path.dirname(PromptFiles.user_path("main")))
      File.write!(PromptFiles.user_path("main"), "USER memory")
      File.write!(PromptFiles.memory_path("main"), "AGENT memory")

      MockProvider.set_responses([mock_response("Composed prompt loaded")])

      MainAgent.handle_message(make_message("Hello with bootstrap"), agent)

      assert_receive {:reply, "Composed prompt loaded"}, 5_000

      [{messages, _opts}] = MockProvider.get_calls()

      assert Enum.map(messages, & &1.role) == [
               "system",
               "system",
               "system",
               "system",
               "system",
               "user"
             ]

      memory_context = Enum.at(messages, 3).content

      assert Enum.map(messages, & &1.content) == [
               "IDENTITY bootstrap",
               "SOUL bootstrap",
               "AGENTS bootstrap",
               memory_context,
               runtime_message(messages).content,
               "Hello with bootstrap"
             ]

      assert memory_context =~ "<memory-context>"
      assert memory_context =~ "USER memory"
      assert memory_context =~ "AGENT memory"
    end

    test "sends error message via reply_fn on agent loop failure", %{agent: agent} do
      MockProvider.set_responses([{:error, "API down"}])

      msg = make_message("Hello")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, error_msg}, 5_000
      assert error_msg =~ "error"
      refute error_msg =~ "Authentication failed"
    end

    test "sends an auth-specific reply when the provider returns :no_auth_file", %{agent: agent} do
      MockProvider.set_responses([{:error, :no_auth_file}])

      msg = make_message("Hello")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, error_msg}, 5_000
      assert error_msg =~ "Authentication failed"
      assert error_msg =~ "fermix auth login"
    end

    test "sends an auth-specific reply when the provider returns an HTTP 401 string", %{
      agent: agent
    } do
      MockProvider.set_responses([{:error, "OpenAI returned 401 Unauthorized"}])

      msg = make_message("Hello")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, error_msg}, 5_000
      assert error_msg =~ "Authentication failed"
      assert error_msg =~ "fermix auth login"
    end

    test "sends an auth-specific reply when the Codex refresh chain fails", %{agent: agent} do
      MockProvider.set_responses([{:error, {:auth_invalidated, %{"error" => "invalid_grant"}}}])

      msg = make_message("Hello")
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, error_msg}, 5_000
      assert error_msg =~ "Authentication failed"
    end

    test "uses thread-aware conversation identity", %{
      agent: agent,
      conv_store: conv_store
    } do
      chat_id = "chat_#{System.unique_integer([:positive])}"

      ConversationStore.add_message(
        {"telegram", chat_id, 456},
        "user",
        "Thread history",
        server: conv_store
      )

      flush_conv_store(conv_store)
      MockProvider.set_responses([mock_response("Thread answer")])

      msg = make_message("Thread follow-up", chat_id: chat_id, thread_ts: 456)
      MainAgent.handle_message(msg, agent)

      assert_receive {:reply, "Thread answer"}, 5_000

      [{messages, _opts}] = MockProvider.get_calls()

      assert Enum.any?(messages, &(&1.content == "Thread history"))
      assert ConversationStore.get_history({"telegram", chat_id, :root}, server: conv_store) == []
      assert ConversationStore.get_history({"telegram", chat_id, 456}, server: conv_store) != []
    end

    test "clears pending state and replies when request task cannot start", %{
      skill_registry: skill_registry,
      conv_store: conv_store
    } do
      agent_name = :"start_error_main_agent_#{System.unique_integer([:positive])}"
      task_sup_name = :"start_error_task_sup_#{System.unique_integer([:positive])}"
      chat_id = "chat_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {Task.Supervisor, [name: task_sup_name, max_children: 0]},
          id: task_sup_name
        )

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: MockProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_sup_name
           ]},
          id: agent_name
        )

      MainAgent.handle_message(make_message("Hello", chat_id: chat_id), agent_name)

      assert_receive {:reply, error_msg}, 5_000
      assert error_msg =~ "error"

      state = :sys.get_state(agent_name)

      refute Map.has_key?(state.conversations, {"telegram", chat_id, :root})
      assert state.task_refs == %{}
    end

    test "is non-blocking — returns :ok before processing completes", %{agent: agent} do
      MockProvider.set_responses([mock_response("OK")])

      msg = make_message("Hello")
      assert :ok = MainAgent.handle_message(msg, agent)

      # Clean up the Task
      assert_receive {:reply, _}, 5_000
    end

    test "skips background extraction when extraction is disabled", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      agent_name = :"extract_disabled_main_agent_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: MockProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor,
             extraction_enabled: false
           ]},
          id: agent_name
        )

      MockProvider.set_responses([mock_response("No extraction")])

      MainAgent.handle_message(make_message("Hello"), agent_name)

      assert_receive {:reply, "No extraction"}, 5_000
      assert eventually(fn -> length(MockProvider.get_calls()) == 1 end)
      refute eventually(fn -> length(MockProvider.get_calls()) > 1 end)
    end

    test "does not block reply delivery while background extraction is slow", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      agent_name = :"extract_slow_main_agent_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: MockProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor,
             extraction_enabled: true,
             extraction_debounce_ms: 0
           ]},
          id: agent_name
        )

      MockProvider.set_responses([
        mock_response("Reply first"),
        {:block, :extract, mock_response("[]")}
      ])

      MainAgent.handle_message(make_message("Hello with slow extraction"), agent_name)

      assert_receive {:reply, "Reply first"}, 5_000
      assert_receive {:mock_provider_blocked, :extract, extraction_pid}, 5_000
      send(extraction_pid, {:continue, :extract})
    end

    test "passes Telegram shared-chat metadata through to background extraction", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      agent_name = :"extract_shared_mode_main_agent_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: MockProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor,
             extraction_enabled: true,
             extraction_debounce_ms: 0
           ]},
          id: agent_name
        )

      MockProvider.set_responses([
        mock_response("Shared chat reply"),
        mock_response("[]")
      ])

      MainAgent.handle_message(
        make_message("Remember this from the group chat",
          metadata: %{chat_type: "group"}
        ),
        agent_name
      )

      assert_receive {:reply, "Shared chat reply"}, 5_000
      assert eventually(fn -> length(MockProvider.get_calls()) == 2 end, 80)

      [{main_messages, _main_opts}, {extraction_messages, _extraction_opts}] =
        MockProvider.get_calls()

      assert Enum.any?(
               main_messages,
               &(&1.role == "user" and &1.content == "Remember this from the group chat")
             )

      assert Enum.any?(
               extraction_messages,
               &(&1.role == "system" and &1.content =~ "Current chat mode: shared.")
             )
    end

    test "keeps reply handling successful when background extraction fails", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      agent_name = :"extract_fail_main_agent_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: MockProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor,
             extraction_enabled: true,
             extraction_debounce_ms: 0
           ]},
          id: agent_name
        )

      MockProvider.set_responses([
        mock_response("Reply survives extraction failure"),
        {:error, :extraction_failed}
      ])

      MainAgent.handle_message(make_message("Hello with failing extraction"), agent_name)

      assert_receive {:reply, "Reply survives extraction failure"}, 5_000
      assert eventually(fn -> length(MockProvider.get_calls()) == 2 end)
    end

    test "debounces rapid-fire extraction without blocking replies", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      agent_name = :"extract_debounce_main_agent_#{System.unique_integer([:positive])}"
      chat_id = "chat_#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: MockProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor,
             extraction_enabled: true,
             extraction_debounce_ms: 80
           ]},
          id: agent_name
        )

      MockProvider.set_responses([
        mock_response("Reply one"),
        mock_response("Reply two"),
        {:block, :extract, mock_response("[]")}
      ])

      MainAgent.handle_message(make_message("first", chat_id: chat_id), agent_name)
      assert_receive {:reply, "Reply one"}, 5_000

      MainAgent.handle_message(make_message("second", chat_id: chat_id), agent_name)
      assert_receive {:reply, "Reply two"}, 5_000

      refute_receive {:mock_provider_blocked, :extract, _pid}, 40
      assert_receive {:mock_provider_blocked, :extract, extraction_pid}, 1_000
      send(extraction_pid, {:continue, :extract})

      assert eventually(fn -> length(MockProvider.get_calls()) == 3 end)

      [_first_main, _second_main, {extraction_messages, _opts}] = MockProvider.get_calls()

      assert Enum.any?(
               extraction_messages,
               &(&1.role == "user" and &1.content =~ "[user] second")
             )
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
      refute runtime_message(messages_before).content =~ "coding-skill"

      write_skill(skills_dir, "coding-skill")
      MockProvider.reset_calls()

      MainAgent.handle_message(make_message("hello again"), agent)
      assert_receive {:reply, "second"}, 5_000

      [{messages_without_reload, _opts}] = MockProvider.get_calls()
      refute runtime_message(messages_without_reload).content =~ "coding-skill"

      assert {:ok, ["coding-skill", "self_knowledge"]} = MainAgent.reload_skills(agent)
      MockProvider.reset_calls()

      MainAgent.handle_message(make_message("after reload"), agent)
      assert_receive {:reply, "third"}, 5_000

      [{messages_after_reload, _opts}] = MockProvider.get_calls()
      runtime = runtime_message(messages_after_reload)
      assert runtime.content =~ "coding-skill"
      assert runtime.content =~ "capabilities=code"
      assert runtime.content =~ "tools=file_read"
    end

    test "delegates to a skill capability when the LLM picks one by name", %{
      agent: agent,
      skills_dir: skills_dir,
      journal_dir: journal_dir
    } do
      write_skill(skills_dir, "coding-skill", "You solve code tasks.")
      assert {:ok, ["coding-skill", "self_knowledge"]} = MainAgent.reload_skills(agent)

      MockProvider.set_responses([
        mock_response("",
          tool_calls: [
            tool_call("call_1", "coding-skill", %{"task" => "Inspect the README"})
          ]
        ),
        mock_response("Inspected the README and found the issue."),
        mock_response("Done. The coding skill inspected the README and found the issue.")
      ])

      # Skill capabilities are policy_class :exec, so :guest trust would
      # not see them. The test exercises the skill-routing mechanic, not
      # channel trust — use the local "cli" channel so the dispatcher
      # gateway classifies the message as :operator and keeps the full
      # capability surface visible.
      MainAgent.handle_message(make_message("Use the coding skill.", channel: "cli"), agent)

      assert_receive {:reply, "Done. The coding skill inspected the README and found the issue."},
                     5_000

      journal_path =
        Path.join([journal_dir, "coding-skill"])
        |> Path.join("*.md")
        |> Path.wildcard()
        |> List.first()

      assert is_binary(journal_path)
      assert File.read!(journal_path) =~ "**Status:** completed"

      calls = MockProvider.get_calls()
      assert length(calls) == 3

      {_main_messages, main_opts} = hd(calls)
      coding_cap = Enum.find(main_opts[:capabilities], &(&1.name == "coding-skill"))
      assert coding_cap.kind == :skill

      {skill_messages, skill_opts} = Enum.at(calls, 1)
      assert hd(skill_messages).content == "You solve code tasks."
      assert skill_opts[:model] == "gpt-5.4-mini"
    end

    test "operator trust gets skill and MCP capability surface", %{
      agent: agent,
      skills_dir: skills_dir,
      capability_registry: capability_registry
    } do
      write_skill(skills_dir, "coding-skill", "You solve code tasks.")
      assert {:ok, ["coding-skill", "self_knowledge"]} = MainAgent.reload_skills(agent)
      :ok = CapabilityRegistry.register(capability_registry, mcp_capability("mcp_demo_tool"))

      MockProvider.set_responses([mock_response("owner surface")])

      MainAgent.handle_message(
        make_message("What can you use?", source_trust: :operator),
        agent
      )

      assert_receive {:reply, "owner surface"}, 5_000

      [{_messages, opts}] = MockProvider.get_calls()
      names = Enum.map(opts[:capabilities], & &1.name)

      assert "coding-skill" in names
      assert "mcp_demo_tool" in names
    end

    test "guest trust hides skill and MCP capabilities", %{
      agent: agent,
      skills_dir: skills_dir,
      capability_registry: capability_registry
    } do
      write_skill(skills_dir, "coding-skill", "You solve code tasks.")
      assert {:ok, ["coding-skill", "self_knowledge"]} = MainAgent.reload_skills(agent)
      :ok = CapabilityRegistry.register(capability_registry, mcp_capability("mcp_demo_tool"))

      MockProvider.set_responses([mock_response("helper surface")])

      MainAgent.handle_message(
        make_message("What can you use?", source_trust: :guest),
        agent
      )

      assert_receive {:reply, "helper surface"}, 5_000

      [{_messages, opts}] = MockProvider.get_calls()
      names = Enum.map(opts[:capabilities], & &1.name)

      refute "coding-skill" in names
      refute "mcp_demo_tool" in names
    end

    test "supersedes an in-flight request with the newest same-conversation message", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      test_pid = self()
      chat_id = "chat_#{System.unique_integer([:positive])}"
      agent_name = :"controlled_main_agent_#{System.unique_integer([:positive])}"

      :ok = ControlledProvider.init(test_pid)

      on_exit(fn ->
        ControlledProvider.cleanup()
      end)

      ControlledProvider.set_plans(%{
        "first" => {:block, mock_response("stale reply")},
        "second" => mock_response("fresh reply")
      })

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: ControlledProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor
           ]},
          id: agent_name
        )

      first_msg =
        make_message("first",
          chat_id: chat_id,
          reply_fn: fn response ->
            send(test_pid, {:reply, :first, response})
          end
        )

      second_msg =
        make_message("second",
          chat_id: chat_id,
          reply_fn: fn response ->
            send(test_pid, {:reply, :second, response})
          end
        )

      MainAgent.handle_message(first_msg, agent_name)

      assert_receive {:controlled_provider_called, "first", first_pid, first_messages, _opts},
                     5_000

      assert Enum.map(Enum.filter(first_messages, &(&1.role == "user")), & &1.content) == [
               "first"
             ]

      first_ref = Process.monitor(first_pid)

      MainAgent.handle_message(second_msg, agent_name)

      assert_receive {:DOWN, ^first_ref, :process, ^first_pid, reason}, 5_000
      refute reason == :normal

      assert_receive {:controlled_provider_called, "second", _second_pid, second_messages, _opts},
                     5_000

      assert Enum.map(Enum.filter(second_messages, &(&1.role == "user")), & &1.content) == [
               "second"
             ]

      assert_receive {:reply, :second, "fresh reply"}, 5_000
      refute_receive {:reply, :first, _response}, 200

      flush_conv_store(conv_store)

      assert ConversationStore.get_history({"telegram", chat_id, :root}, server: conv_store)
             |> Enum.map(&{&1.role, &1.content}) == [
               {"user", "second"},
               {"assistant", "fresh reply"}
             ]

      assert Enum.map(ControlledProvider.get_calls(), fn {content, _messages, _opts} ->
               content
             end) == [
               "first",
               "second"
             ]
    end

    test "keeps different conversations independent while one chat has blocked work", %{
      skill_registry: skill_registry,
      conv_store: conv_store,
      task_supervisor: task_supervisor
    } do
      test_pid = self()
      agent_name = :"controlled_main_agent_#{System.unique_integer([:positive])}"
      first_chat_id = "chat_#{System.unique_integer([:positive])}"
      second_chat_id = "chat_#{System.unique_integer([:positive])}"

      :ok = ControlledProvider.init(test_pid)

      on_exit(fn ->
        ControlledProvider.cleanup()
      end)

      ControlledProvider.set_plans(%{
        "blocked" => {:block, mock_response("chat one reply")},
        "other" => mock_response("chat two reply")
      })

      {:ok, _} =
        start_supervised(
          {MainAgent,
           [
             name: agent_name,
             provider: ControlledProvider,
             skill_registry: skill_registry,
             conversation_store: conv_store,
             task_supervisor: task_supervisor
           ]},
          id: agent_name
        )

      blocked_msg =
        make_message("blocked",
          chat_id: first_chat_id,
          reply_fn: fn response ->
            send(test_pid, {:reply, :blocked, response})
          end
        )

      other_msg =
        make_message("other",
          chat_id: second_chat_id,
          reply_fn: fn response ->
            send(test_pid, {:reply, :other, response})
          end
        )

      MainAgent.handle_message(blocked_msg, agent_name)

      assert_receive {:controlled_provider_called, "blocked", blocked_pid, _messages, _opts},
                     5_000

      assert Process.alive?(blocked_pid)

      MainAgent.handle_message(other_msg, agent_name)

      assert_receive {:controlled_provider_called, "other", _other_pid, _messages, _opts}, 5_000
      assert_receive {:reply, :other, "chat two reply"}, 5_000
      assert Process.alive?(blocked_pid)

      send(blocked_pid, {:continue, "blocked"})
      assert_receive {:reply, :blocked, "chat one reply"}, 5_000

      flush_conv_store(conv_store)

      assert ConversationStore.get_history({"telegram", second_chat_id, :root},
               server: conv_store
             )
             |> Enum.map(&{&1.role, &1.content}) == [
               {"user", "other"},
               {"assistant", "chat two reply"}
             ]

      assert ConversationStore.get_history({"telegram", first_chat_id, :root}, server: conv_store)
             |> Enum.map(&{&1.role, &1.content}) == [
               {"user", "blocked"},
               {"assistant", "chat one reply"}
             ]
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

  describe "init/1 — adapter override sourcing from config" do
    setup do
      original_agent = Application.get_env(:fermix_core, :agent, [])
      original_providers = Application.get_env(:fermix_core, :providers, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :agent, original_agent)
        Application.put_env(:fermix_core, :providers, original_providers)
      end)

      :ok
    end

    test "bakes provider/model/reasoning_effort from config into adapter_overrides" do
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)

      Application.put_env(:fermix_core, :providers,
        openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high]
      )

      name = :"main_agent_config_overrides_#{System.unique_integer([:positive])}"
      {:ok, pid} = MainAgent.start_link(name: name)
      state = :sys.get_state(pid)

      assert Keyword.get(state.adapter_overrides, :provider) == :openai_codex
      assert Keyword.get(state.adapter_overrides, :model) == "gpt-5.5"
      assert Keyword.get(state.adapter_overrides, :reasoning_effort) == :high

      GenServer.stop(pid)
    end

    test "explicit :provider in opts wins whole — config is dropped to avoid cross-provider leak" do
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)

      Application.put_env(:fermix_core, :providers,
        openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high]
      )

      name = :"main_agent_opts_win_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        MainAgent.start_link(
          name: name,
          adapter_overrides: [provider: :anthropic, model: "claude-opus-4-7"]
        )

      state = :sys.get_state(pid)

      assert Keyword.get(state.adapter_overrides, :provider) == :anthropic
      assert Keyword.get(state.adapter_overrides, :model) == "claude-opus-4-7"
      # reasoning_effort from openai_codex config block must NOT leak into
      # the anthropic route — the Anthropic Messages API has no such field.
      refute Keyword.has_key?(state.adapter_overrides, :reasoning_effort)

      GenServer.stop(pid)
    end

    test "explicit :model without :provider lets config-derived provider+effort fill in" do
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)

      Application.put_env(:fermix_core, :providers,
        openai_codex: [default_model: "gpt-5.5", reasoning_effort: :medium]
      )

      name = :"main_agent_partial_opts_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        MainAgent.start_link(name: name, adapter_overrides: [model: "gpt-5.4"])

      state = :sys.get_state(pid)

      assert Keyword.get(state.adapter_overrides, :provider) == :openai_codex
      assert Keyword.get(state.adapter_overrides, :model) == "gpt-5.4"
      assert Keyword.get(state.adapter_overrides, :reasoning_effort) == :medium

      GenServer.stop(pid)
    end

    test "no agent.provider configured → empty config-derived overrides" do
      Application.delete_env(:fermix_core, :agent)
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])

      name = :"main_agent_no_provider_#{System.unique_integer([:positive])}"
      {:ok, pid} = MainAgent.start_link(name: name)
      state = :sys.get_state(pid)

      assert state.adapter_overrides == []

      GenServer.stop(pid)
    end

    test "garbage provider in agent.provider is logged and ignored" do
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openia)
      Application.put_env(:fermix_core, :providers, [])

      name = :"main_agent_bad_provider_#{System.unique_integer([:positive])}"

      {pid, log} =
        with_log(fn ->
          {:ok, pid} = MainAgent.start_link(name: name)
          pid
        end)

      state = :sys.get_state(pid)
      assert state.adapter_overrides == []
      assert log =~ "ignoring unknown provider :openia"

      GenServer.stop(pid)
    end

    test "provider configured but per-provider block has no defaults yields provider-only overrides" do
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)
      Application.put_env(:fermix_core, :providers, openai_codex: [])

      name = :"main_agent_provider_only_#{System.unique_integer([:positive])}"
      {:ok, pid} = MainAgent.start_link(name: name)
      state = :sys.get_state(pid)

      assert state.adapter_overrides == [provider: :openai_codex]

      GenServer.stop(pid)
    end
  end
end
