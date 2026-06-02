defmodule FermixCore.Tools.SubagentsTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.Subagents

  @probe_ctx :subagents_probe_ctx

  defmodule MockAdapter do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @turns :subagents_mock_turns
    @caps :subagents_mock_caps

    def init do
      cleanup()
      {:ok, _} = Agent.start_link(fn -> [] end, name: @turns)
      {:ok, _} = Agent.start_link(fn -> [] end, name: @caps)
      :ok
    end

    def set_turns(turns), do: Agent.update(@turns, fn _ -> turns end)
    def captured_capabilities, do: Agent.get(@caps, & &1)

    def cleanup do
      Enum.each([@turns, @caps], fn name ->
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

    @impl true
    def chat(messages, capabilities, _opts) do
      Agent.update(@caps, fn prior -> prior ++ [Enum.map(capabilities, & &1.name)] end)
      maybe_slow(messages)
      {:ok, build_turn(pop_turn(), messages, capabilities)}
    end

    # A worker whose task contains "SLOWWORKER" sleeps past any sane timeout, so
    # a fanout can have one fast and one slow worker deterministically.
    defp maybe_slow(messages) do
      slow? =
        Enum.any?(messages, fn msg ->
          content = Map.get(msg, :content, Map.get(msg, "content", ""))
          is_binary(content) and String.contains?(content, "SLOWWORKER")
        end)

      if slow?, do: Process.sleep(6_500), else: :ok
    end

    @impl true
    def continue(provider_state, tool_results, opts) do
      prior = Map.get(provider_state, :messages, [])
      caps = Map.get(provider_state, :capabilities, [])

      tool_messages =
        Enum.map(tool_results, fn %{call_id: id, output: out} ->
          %{role: "tool", tool_call_id: id, content: to_string(out)}
        end)

      chat(prior ++ tool_messages, caps, opts)
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response
    @impl true
    def supports_streaming?, do: false

    defp pop_turn do
      Agent.get_and_update(@turns, fn
        [next | rest] -> {next, rest}
        [] -> {%{content: "done", tool_calls: []}, []}
      end)
    end

    defp build_turn(%{content: content, tool_calls: tool_calls}, messages, capabilities) do
      assistant = %{role: "assistant", content: content}

      %{
        content: content,
        tool_calls: tool_calls,
        provider_state: %{messages: messages ++ [assistant], capabilities: capabilities},
        usage: %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1},
        model: "mock-model"
      }
    end
  end

  # --- capability executors used by seeded stub capabilities ---

  def ok_tool(_args, _context), do: {:ok, %{success: true, output: "ok", error: nil}}

  def record_ctx(_args, context) do
    Agent.update(@probe_ctx, fn _ -> context end)
    {:ok, %{success: true, output: "probed", error: nil}}
  end

  defp stub_cap(name, class) do
    Capability.new(%{
      name: name,
      description: name,
      parameters: %{type: "object", properties: %{}},
      kind: :builtin,
      executor: {__MODULE__, :ok_tool, []},
      policy_class: class
    })
  end

  defp probe_cap do
    Capability.new(%{
      name: "probe",
      description: "records its received context",
      parameters: %{type: "object", properties: %{}},
      kind: :builtin,
      executor: {__MODULE__, :record_ctx, []},
      policy_class: :read_only
    })
  end

  defp tool_call(call_id, name, args) do
    %{id: "fc_#{call_id}", call_id: call_id, name: name, arguments: Jason.encode!(args)}
  end

  defp text_turn(content), do: %{content: content, tool_calls: []}

  defp tool_turns(count) do
    for step <- 1..count do
      call_turn("c#{step}", "missing_tool", %{"step" => step})
    end
  end

  defp call_turn(call_id, name, args),
    do: %{content: "", tool_calls: [tool_call(call_id, name, args)]}

  setup do
    :ok = MockAdapter.init()
    suffix = System.unique_integer([:positive])
    registry = :"subagents_registry_#{suffix}"
    agent_supervisor = :"subagents_agent_sup_#{suffix}"
    task_supervisor = :"subagents_task_sup_#{suffix}"

    {:ok, _} = start_supervised({Task.Supervisor, name: task_supervisor})
    {:ok, _} = start_supervised({AgentSupervisor, name: agent_supervisor})
    {:ok, _} = start_supervised({CapabilityRegistry, name: registry})

    ensure_probe_holder()

    on_exit(fn -> MockAdapter.cleanup() end)

    %{registry: registry, agent_supervisor: agent_supervisor, task_supervisor: task_supervisor}
  end

  defp ensure_probe_holder do
    case Process.whereis(@probe_ctx) do
      nil -> {:ok, _} = Agent.start_link(fn -> nil end, name: @probe_ctx)
      _pid -> Agent.update(@probe_ctx, fn _ -> nil end)
    end
  end

  defp context(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        agent_name: "main",
        session_id: "main-session",
        source_trust: :operator,
        provider: MockAdapter,
        capability_registry: ctx.registry,
        agent_supervisor: ctx.agent_supervisor,
        task_supervisor: ctx.task_supervisor
      },
      overrides
    )
  end

  defp decode_output({:ok, %{success: true, output: json}}), do: Jason.decode!(json)

  describe "validation (rejected before spawn)" do
    test "missing tasks", ctx do
      assert {:ok, %{success: false, error: error}} = Subagents.execute(%{}, context(ctx))
      assert error =~ "tasks must be a non-empty array"
    end

    test "empty tasks", ctx do
      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => []}, context(ctx))

      assert error =~ "non-empty"
    end

    test "too many tasks", ctx do
      tasks = for n <- 1..9, do: %{"id" => "t#{n}", "task" => "do #{n}"}

      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => tasks}, context(ctx))

      assert error =~ "Too many tasks"
    end

    test "duplicate ids", ctx do
      tasks = [%{"id" => "dup", "task" => "a"}, %{"id" => "dup", "task" => "b"}]

      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => tasks}, context(ctx))

      assert error =~ "unique"
    end

    test "missing source_trust (main-agent only)", ctx do
      bare = ctx |> context() |> Map.delete(:source_trust)
      tasks = [%{"id" => "t1", "task" => "a"}]

      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => tasks}, bare)

      assert error =~ "source_trust"
    end

    test "recursion: subagent_depth > 0", ctx do
      nested = context(ctx, %{subagent_depth: 1})
      tasks = [%{"id" => "t1", "task" => "a"}]

      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => tasks}, nested)

      assert error =~ "within a subagent"
    end

    test "max_concurrency out of range", ctx do
      tasks = [%{"id" => "t1", "task" => "a"}]

      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => tasks, "max_concurrency" => 99}, context(ctx))

      assert error =~ "max_concurrency"
    end

    test "timeout out of range", ctx do
      tasks = [%{"id" => "t1", "task" => "a"}]

      assert {:ok, %{success: false, error: error}} =
               Subagents.execute(%{"tasks" => tasks, "timeout_seconds" => 99_999}, context(ctx))

      assert error =~ "timeout_seconds"
    end
  end

  describe "fanout execution" do
    test "single worker completes with a structured result", ctx do
      tasks = [%{"id" => "research", "task" => "Find the answer."}]
      result = Subagents.execute(%{"tasks" => tasks}, context(ctx)) |> decode_output()

      assert result["status"] == "completed"
      assert [worker] = result["results"]
      assert worker["id"] == "research"
      assert worker["status"] == "completed"
      assert worker["output"] == "done"
      assert worker["agent_name"] == "subagent:research"
      assert is_integer(worker["duration_ms"])
      assert worker["iterations"] == 1
      assert result["summary"]["requested"] == 1
      assert result["summary"]["completed"] == 1
    end

    test "temporary workers have enough iterations for deeper delegated work", ctx do
      MockAdapter.set_turns(tool_turns(99) ++ [text_turn("finished at 100")])

      tasks = [%{"id" => "deep", "task" => "Investigate a complex issue."}]
      result = Subagents.execute(%{"tasks" => tasks}, context(ctx)) |> decode_output()

      assert [worker] = result["results"]
      assert worker["status"] == "completed"
      assert worker["iterations"] == 100
      assert worker["output"] == "finished at 100"
    end

    test "partial timeout: a slow worker times out while a fast one completes", ctx do
      tasks = [
        %{"id" => "fast", "task" => "be quick"},
        %{"id" => "slow", "task" => "SLOWWORKER take your time"}
      ]

      result =
        Subagents.execute(
          %{"tasks" => tasks, "max_concurrency" => 2, "timeout_seconds" => 5},
          context(ctx)
        )
        |> decode_output()

      by_id = Map.new(result["results"], &{&1["id"], &1})
      assert by_id["fast"]["status"] == "completed"
      assert by_id["slow"]["status"] == "timed_out"
      assert result["summary"]["completed"] == 1
      assert result["summary"]["timed_out"] == 1
    end

    test "oversized worker output is truncated and stays valid UTF-8", ctx do
      # 59_999 ASCII bytes + two 3-byte checkmarks straddles the 60_000-byte cap
      # (single task -> per_worker_bytes = 60_000). A naive binary_part would
      # split the multibyte char and crash JSON encoding.
      big = String.duplicate("a", 59_999) <> "✓✓"
      MockAdapter.set_turns([text_turn(big)])

      tasks = [%{"id" => "t1", "task" => "produce a lot"}]
      result = Subagents.execute(%{"tasks" => tasks}, context(ctx)) |> decode_output()

      [worker] = result["results"]
      assert worker["truncated"] == true
      assert byte_size(worker["output"]) <= 60_000
      assert String.valid?(worker["output"])
    end

    test "multiple workers run and all complete in input order", ctx do
      tasks = [
        %{"id" => "a", "task" => "task a"},
        %{"id" => "b", "task" => "task b"},
        %{"id" => "c", "task" => "task c"}
      ]

      result =
        Subagents.execute(%{"tasks" => tasks, "max_concurrency" => 2}, context(ctx))
        |> decode_output()

      assert Enum.map(result["results"], & &1["id"]) == ["a", "b", "c"]
      assert Enum.all?(result["results"], &(&1["status"] == "completed"))
      assert result["summary"]["completed"] == 3
    end
  end

  describe "access model" do
    test "worker surface includes read/network/external_api/exec but excludes read_write", ctx do
      Enum.each(
        [
          stub_cap("reader", :read_only),
          stub_cap("writer", :read_write),
          stub_cap("net", :network),
          stub_cap("api", :external_api),
          stub_cap("runner", :exec)
        ],
        &CapabilityRegistry.register(ctx.registry, &1)
      )

      tasks = [%{"id" => "t1", "task" => "inspect"}]
      _ = Subagents.execute(%{"tasks" => tasks}, context(ctx)) |> decode_output()

      [worker_caps | _] = MockAdapter.captured_capabilities()

      assert "reader" in worker_caps
      assert "net" in worker_caps
      assert "api" in worker_caps
      assert "runner" in worker_caps
      refute "writer" in worker_caps
    end

    test "a :guest parent narrows the worker to read-only (cannot be widened)", ctx do
      Enum.each(
        [
          stub_cap("reader", :read_only),
          stub_cap("writer", :read_write),
          stub_cap("net", :network),
          stub_cap("api", :external_api),
          stub_cap("runner", :exec)
        ],
        &CapabilityRegistry.register(ctx.registry, &1)
      )

      tasks = [%{"id" => "t1", "task" => "inspect"}]

      _ =
        Subagents.execute(%{"tasks" => tasks}, context(ctx, %{source_trust: :guest}))
        |> decode_output()

      [worker_caps | _] = MockAdapter.captured_capabilities()

      assert "reader" in worker_caps
      refute "writer" in worker_caps
      refute "net" in worker_caps
      refute "api" in worker_caps
      refute "runner" in worker_caps
    end
  end

  describe "context sanitizing and recursion depth" do
    test "worker context drops reply_fn/conversation_key and sets subagent_depth", ctx do
      CapabilityRegistry.register(ctx.registry, probe_cap())
      MockAdapter.set_turns([call_turn("c1", "probe", %{}), text_turn("done")])

      parent =
        context(ctx, %{
          reply_fn: fn _ -> :ok end,
          channel: :telegram,
          source_channel: :telegram,
          sandbox_config: %{mode: :open},
          conversation_key: "conv-1",
          memory_agent_id: "main",
          memory_owner_id: "owner",
          memory_store: :some_store,
          memory_repo: :some_repo
        })

      tasks = [%{"id" => "t1", "task" => "probe the context"}]
      result = Subagents.execute(%{"tasks" => tasks}, parent) |> decode_output()
      assert result["summary"]["completed"] == 1

      worker_ctx = Agent.get(@probe_ctx, & &1)
      assert is_map(worker_ctx)
      assert worker_ctx[:subagent_depth] == 1

      # every stripped key is gone — channel-reply targeting, sandbox relaxation,
      # parent trust, and all memory handles
      for key <- [
            :reply_fn,
            :channel,
            :source_channel,
            :source_trust,
            :sandbox_config,
            :conversation_key,
            :memory_agent_id,
            :memory_owner_id,
            :memory_store,
            :memory_repo
          ] do
        refute Map.has_key?(worker_ctx, key), "expected #{inspect(key)} to be stripped"
      end
    end
  end
end
