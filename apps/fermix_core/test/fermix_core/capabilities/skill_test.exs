defmodule FermixCore.Capabilities.SkillTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.Skill
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Tools.ScheduleJob
  alias FermixCore.Tools.UpdateJob

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider
    @behaviour FermixCore.Providers.Adapter

    @responses :skill_capability_mock_responses
    @captured :skill_capability_mock_captured
    @tools :skill_capability_mock_tools

    def init do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> [] end, name: @responses)
      {:ok, _} = Agent.start_link(fn -> [] end, name: @captured)
      {:ok, _} = Agent.start_link(fn -> [] end, name: @tools)
      :ok
    end

    def set_responses(responses), do: Agent.update(@responses, fn _ -> responses end)
    def captured_messages, do: Agent.get(@captured, & &1)

    # The tool names each model call was offered, oldest first; taking them
    # clears the record.
    def take_tools, do: Agent.get_and_update(@tools, &{&1, []})

    def cleanup do
      Enum.each([@responses, @captured, @tools], fn name ->
        case Process.whereis(name) do
          nil -> :ok
          pid -> try_stop(pid)
        end
      end)
    end

    defp try_stop(pid) do
      Agent.stop(pid)
    catch
      :exit, _ -> :ok
    end

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: pop_response()

    @impl FermixCore.Providers.Adapter
    def chat(messages, capabilities, _opts) do
      Agent.update(@captured, fn prior -> prior ++ [messages] end)
      Agent.update(@tools, fn prior -> prior ++ [Enum.map(capabilities, & &1.name)] end)

      case pop_response() do
        {:ok, response} -> {:ok, to_turn(response, messages, capabilities)}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl FermixCore.Providers.Adapter
    def continue(provider_state, tool_results, opts) do
      capabilities = Map.get(provider_state, :capabilities, [])
      prior = Map.get(provider_state, :messages, [])

      tool_messages =
        Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
          %{role: "tool", tool_call_id: call_id, content: to_string(output)}
        end)

      chat(prior ++ tool_messages, capabilities, opts)
    end

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp pop_response do
      Agent.get_and_update(@responses, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, "No mock responses left"}, []}
      end)
    end

    defp to_turn(%{content: content, usage: usage} = response, messages, capabilities) do
      assistant = %{role: "assistant", content: content || ""}

      %{
        content: content || "",
        tool_calls: Map.get(response, :tool_calls, []),
        provider_state: %{
          messages: messages ++ [assistant],
          capabilities: capabilities
        },
        usage: usage,
        model: Map.get(response, :model, "mock-model")
      }
    end
  end

  defp mock_response(content) do
    {:ok,
     %{
       content: content,
       tool_calls: [],
       usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
       model: "mock-model"
     }}
  end

  defp build_definition(name, prompt, attrs \\ %{}) do
    {:ok, definition} =
      %{
        "name" => name,
        "description" => "Use #{name}.",
        "system_prompt" => prompt,
        "model" => "mock-model",
        "allowed_tools" => [],
        "max_iterations" => 4,
        "timeout_seconds" => 30
      }
      |> Map.merge(attrs)
      |> AgentDefinition.new()

    AgentDefinition.with_trust(definition, :operator)
  end

  setup do
    :ok = MockProvider.init()
    suffix = System.unique_integer([:positive])
    agent_supervisor_name = :"skill_capability_agent_supervisor_#{suffix}"
    task_supervisor_name = :"skill_capability_task_supervisor_#{suffix}"
    journal_dir = Path.join(System.tmp_dir!(), "fermix-skill-capability-journals-#{suffix}")

    {:ok, _} = start_supervised({Task.Supervisor, name: task_supervisor_name})
    {:ok, _} = start_supervised({AgentSupervisor, name: agent_supervisor_name})

    on_exit(fn ->
      MockProvider.cleanup()
      FermixTestSupport.SafeRm.rm_rf!(journal_dir)
    end)

    %{
      agent_supervisor: agent_supervisor_name,
      task_supervisor: task_supervisor_name,
      journal_dir: journal_dir
    }
  end

  describe "from_definition/1" do
    test "produces a :skill capability with policy_class :exec and metadata" do
      definition = build_definition("alpha", "Alpha skill body.")
      cap = Skill.from_definition(definition)

      assert %Capability{kind: :skill, policy_class: :exec, name: "alpha"} = cap
      assert cap.metadata.skill == "alpha"
      assert cap.metadata.trust == :operator
      assert {Skill, :invoke, [^definition]} = cap.executor
    end

    test "description comes from the skill definition" do
      definition = build_definition("beta", "Headline line\n\nDetail paragraph here.")
      cap = Skill.from_definition(definition)
      assert cap.description == "Use beta."
    end
  end

  describe "invoke/3" do
    test "spawns sub-agent, returns success tool result, and writes journal", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      definition = build_definition("alpha", "Alpha skill body.")
      MockProvider.set_responses([mock_response("Did the work.")])

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: 0
      }

      assert {:ok, result} =
               Skill.invoke(
                 %{"task" => "Do the thing", "context" => "extra"},
                 context,
                 definition
               )

      assert result.success
      assert result.output =~ "Skill 'alpha' completed"
      assert result.output =~ "Did the work."

      [forced_messages | _] = MockProvider.captured_messages()

      forced_user =
        Enum.find(forced_messages, fn msg ->
          Map.get(msg, :role, Map.get(msg, "role")) == "user"
        end)

      content = Map.get(forced_user, :content, Map.get(forced_user, "content"))
      assert content =~ ~s(running as the "alpha" skill)
      assert content =~ "Do the thing"
      assert content =~ "extra"

      journal =
        Path.join([journal_dir, "alpha"])
        |> Path.join("*.md")
        |> Path.wildcard()
        |> List.first()

      assert is_binary(journal)
      assert File.read!(journal) =~ "Do the thing"
      assert File.read!(journal) =~ "**Status:** completed"

      Process.sleep(50)
      assert AgentSupervisor.list_agents(agent_supervisor) == []
    end

    test "a finalized invocation upserts the skill_usage runs counter", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      suffix = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-skill-usage-#{suffix}.db")
      usage_repo = :"skill_capability_usage_repo_#{suffix}"

      start_supervised!({MemoryRepo, name: usage_repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
          FermixTestSupport.SafeRm.rm(path)
        end)
      end)

      definition = build_definition("alpha", "Alpha skill body.")
      MockProvider.set_responses([mock_response("Did the work.")])

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: 0,
        usage_repo: usage_repo
      }

      assert {:ok, result} = Skill.invoke(%{"task" => "Do the thing"}, context, definition)
      assert result.success

      assert {:ok, usage} = MemoryRepo.get_skill_usage("alpha", server: usage_repo)
      assert usage.runs == 1
      assert usage.views == 0
    end

    test "caps recursion at max_skill_depth and emits telemetry", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      definition = build_definition("alpha", "Alpha skill body.")

      handler_id = :"skill_recursion_capped_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :capability, :recursion_capped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:recursion_capped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: Skill.max_skill_depth()
      }

      assert {:ok, result} = Skill.invoke(%{"task" => "Do work"}, context, definition)
      refute result.success
      assert result.error =~ "Max skill depth"

      assert_receive {:recursion_capped, %{count: 1}, %{skill: "alpha", depth: depth, cap: cap}}
      assert depth == Skill.max_skill_depth()
      assert cap == Skill.max_skill_depth()
    end

    test "missing task arg returns a tool error before spawn", %{
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_dir: journal_dir
    } do
      definition = build_definition("alpha", "Alpha skill body.")

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: journal_dir,
        skill_depth: 0
      }

      assert {:ok, result} = Skill.invoke(%{}, context, definition)
      refute result.success
      assert result.error =~ "missing_argument"
      assert AgentSupervisor.list_agents(agent_supervisor) == []
    end
  end

  # A skill's worker gets at most its parent run's surface, as a `subagents`
  # worker does: the skill's allowlist and policy classes meet the
  # `effective_allowed_tools` and `effective_policy` the parent's loop stamped.
  describe "a skill worker within its parent run" do
    setup %{agent_supervisor: agent_supervisor, task_supervisor: task_supervisor} = ctx do
      registry = :"skill_worker_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})

      for {name, class} <- [
            {"notes_read", :read_only},
            {"web_search", :network},
            {"shell", :exec}
          ] do
        :ok = CapabilityRegistry.register(registry, stand_in(name, class))
      end

      context = %{
        agent_name: "main",
        session_id: "main-session",
        provider: MockProvider,
        agent_supervisor: agent_supervisor,
        task_supervisor: task_supervisor,
        journal_base_dir: ctx.journal_dir,
        skill_depth: 0,
        capability_registry: registry
      }

      %{context: context, tools: %{"allowed_tools" => ["notes_read", "web_search", "shell"]}}
    end

    test "a narrowed parent's worker gets the skill's tools within the parent's", %{
      context: context,
      tools: tools
    } do
      # The last meets no class at all: a tool-less worker, since the registry
      # would read `policy: []` as the trust default.
      for {attrs, stamps, offered} <- [
            {tools, %{effective_allowed_tools: ["web_search", "file_read"]}, ["web_search"]},
            {tools, %{effective_policy: [:read_only, :network]}, ["notes_read", "web_search"]},
            {Map.put(tools, "policy", ["read_only"]), %{effective_policy: [:network]}, []}
          ] do
        definition = build_definition("alpha", "Alpha skill body.", attrs)
        assert {stamps, worker_tools(definition, Map.merge(context, stamps))} == {stamps, offered}
      end
    end

    test "an un-narrowed parent's worker gets the skill's own tools, unchanged", %{
      context: context,
      tools: tools
    } do
      definition = build_definition("alpha", "Alpha skill body.", tools)

      full_trust = %{
        effective_allowed_tools: nil,
        effective_policy: CapabilityRegistry.default_policy_classes(:operator),
        effective_trust: :operator
      }

      for parent <- [context, Map.merge(context, full_trust)] do
        assert worker_tools(definition, parent) == ["notes_read", "shell", "web_search"]
      end
    end

    # A parent loop running at guest (a guest's turn, a guest skill's worker)
    # hands an operator skill no owner-only tool: the worker runs at the lower
    # of the two trusts.
    test "a guest parent's worker runs at guest, whatever the skill's trust", %{
      context: context
    } do
      registry = context.capability_registry

      :ok =
        CapabilityRegistry.register(registry, %{
          stand_in("owner_diary", :read_only)
          | owner_only?: true
        })

      definition =
        build_definition("alpha", "Alpha skill body.", %{
          "allowed_tools" => ["owner_diary", "notes_read", "shell"]
        })

      guest_parent = %{effective_trust: :guest, effective_policy: [:read_only]}
      assert worker_tools(definition, Map.merge(context, guest_parent)) == ["notes_read"]

      # A guest's own turn that no loop stamped runs it at guest the same way:
      # its run trust is its `source_trust` (`CapabilityRegistry.run_trust/1`).
      assert worker_tools(definition, Map.put(context, :source_trust, :guest)) == ["notes_read"]
    end
  end

  # A plugin skill loads at guest trust whoever calls it, so its worker runs at
  # guest under the owner's turn: a job it sets up holds no owner-only tool
  # and records guest trust, never the operator's.
  test "a guest skill's worker gives a job only its own guest-trust tools", %{
    agent_supervisor: agent_supervisor,
    task_supervisor: task_supervisor,
    journal_dir: journal_dir
  } do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-skill-guest-job-#{suffix}.db")
    repo = :"skill_guest_job_repo_#{suffix}"
    start_supervised!({MemoryRepo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    registry = :"skill_guest_caps_#{suffix}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(ScheduleJob))
    :ok = CapabilityRegistry.register(registry, stand_in("file_note", :read_write))
    :ok = CapabilityRegistry.register(registry, stand_in("web_search", :network))

    :ok =
      CapabilityRegistry.register(registry, %{
        stand_in("owner_notes", :read_only)
        | owner_only?: true
      })

    definition =
      "helper"
      |> build_definition("Helper skill body.", %{
        "allowed_tools" => nil,
        "policy" => ["read_only", "read_write"]
      })
      |> AgentDefinition.with_trust(:guest)

    arguments = %{"name" => "Helper Job", "schedule" => "every 15 minutes", "task" => "Note."}

    MockProvider.set_responses([
      {:ok,
       %{
         content: "",
         tool_calls: [
           %{
             id: "fc_1",
             call_id: "call_1",
             name: "schedule_job",
             arguments: Jason.encode!(arguments)
           }
         ],
         usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
         model: "mock-model"
       }},
      mock_response("Scheduled.")
    ])

    context = %{
      agent_name: "main",
      session_id: "main-session",
      provider: MockProvider,
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_base_dir: journal_dir,
      skill_depth: 0,
      capability_registry: registry,
      memory_repo: repo,
      memory_agent_id: "main",
      source_trust: :operator,
      conversation_key: {"telegram", "chat-1", :root},
      outside_sources: MapSet.new()
    }

    assert {:ok, %{success: true}} = Skill.invoke(%{"task" => "Set it up."}, context, definition)

    assert {:ok, [job]} = JobsRegistry.list_jobs(repo: repo)
    assert job.allowed_tools == ["file_note", "schedule_job"]
    assert job.created_by_trust == "guest"
  end

  # A plugin skill's worker runs at guest under the owner's turn, so it may not
  # rewrite an operator job, even one whose tools all fit its own: the job would
  # keep running at operator on guest-authored instructions.
  test "a guest skill's worker cannot change an operator job", %{
    agent_supervisor: agent_supervisor,
    task_supervisor: task_supervisor,
    journal_dir: journal_dir
  } do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-skill-guest-update-#{suffix}.db")
    repo = :"skill_guest_update_repo_#{suffix}"
    start_supervised!({MemoryRepo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    registry = :"skill_guest_update_caps_#{suffix}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(UpdateJob))
    :ok = CapabilityRegistry.register(registry, stand_in("file_note", :read_write))

    {:ok, job} =
      JobsRegistry.create_job(
        %{
          name: "Owner Notes",
          schedule: "every 15 minutes",
          task_prompt: "Tidy the notes.",
          allowed_tools: ["file_note"],
          created_by_trust: "operator"
        },
        repo: repo
      )

    definition =
      "helper"
      |> build_definition("Helper skill body.", %{
        "allowed_tools" => nil,
        "policy" => ["read_only", "read_write"]
      })
      |> AgentDefinition.with_trust(:guest)

    arguments = %{"job_id" => job.id, "task" => "Mail the notes out."}

    MockProvider.set_responses([
      {:ok,
       %{
         content: "",
         tool_calls: [
           %{
             id: "fc_1",
             call_id: "call_1",
             name: "update_job",
             arguments: Jason.encode!(arguments)
           }
         ],
         usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
         model: "mock-model"
       }},
      mock_response("Done.")
    ])

    context = %{
      agent_name: "main",
      session_id: "main-session",
      provider: MockProvider,
      agent_supervisor: agent_supervisor,
      task_supervisor: task_supervisor,
      journal_base_dir: journal_dir,
      skill_depth: 0,
      capability_registry: registry,
      memory_repo: repo,
      source_trust: :operator,
      conversation_key: {"telegram", "chat-1", :root},
      outside_sources: MapSet.new()
    }

    assert {:ok, %{success: true}} = Skill.invoke(%{"task" => "Edit it."}, context, definition)

    assert {:ok, %{task_prompt: "Tidy the notes."}} = JobsRegistry.get_job(job.id, repo: repo)

    tool_replies =
      for messages <- MockProvider.captured_messages(),
          %{role: "tool", content: content} <- messages,
          do: content

    assert Enum.any?(tool_replies, &(&1 =~ "below the operator trust this job was set up at"))
  end

  def stand_in_never_runs(_args, _context), do: raise("a stand-in tool must never run")

  defp stand_in(name, policy_class) do
    Capability.new(%{
      name: name,
      description: "Stands in for #{name}.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :stand_in_never_runs, []},
      policy_class: policy_class
    })
  end

  # The tools the skill's worker was offered on its first model call. Each
  # invocation journals into its own folder, so two in one second never meet.
  defp worker_tools(definition, context) do
    MockProvider.set_responses([mock_response("Done.")])
    journal_dir = Path.join(context.journal_base_dir, "#{System.unique_integer([:positive])}")
    context = Map.put(context, :journal_base_dir, journal_dir)
    assert {:ok, %{success: true}} = Skill.invoke(%{"task" => "Work."}, context, definition)
    [first | _] = MockProvider.take_tools()
    Enum.sort(first)
  end
end
