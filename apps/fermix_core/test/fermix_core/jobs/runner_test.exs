defmodule FermixCore.Jobs.RunnerTest do
  # async: false — the cron-routing tests mutate the shared :routing app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Memory.Repo

  defmodule RecordingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:adapter_chat, messages, Enum.map(capabilities, & &1.name)}
      )

      maybe_sleep(opts)
      next_turn(Keyword.fetch!(opts, :script), opts)
    end

    @impl true
    def continue(provider_state, tool_results, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:adapter_continue, tool_results})
      next_turn(provider_state.rest, opts)
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp maybe_sleep(opts) do
      case Keyword.get(opts, :sleep_ms, 0) do
        ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
        _ms -> :ok
      end
    end

    defp next_turn([turn | rest], _opts) do
      {:ok,
       Map.merge(
         %{
           content: "",
           tool_calls: [],
           usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
           model: "mock"
         },
         Map.put(turn, :provider_state, %{rest: rest})
       )}
    end

    defp next_turn([], _opts), do: {:error, "No mock responses left"}
  end

  defmodule SkillRegistryStub do
    @moduledoc false
    # Minimal stand-in for FermixCore.Agents.SkillRegistry: the Runner only
    # ever calls `GenServer.call(registry, {:load, name})`, so a tiny map-backed
    # GenServer keeps the skill-confinement tests hermetic (no fixture files,
    # no default-skill seeding).
    use GenServer

    def start_link(skills) when is_map(skills) do
      GenServer.start_link(__MODULE__, skills)
    end

    @impl true
    def init(skills), do: {:ok, skills}

    @impl true
    def handle_call({:load, name}, _from, skills) do
      reply =
        case Map.fetch(skills, name) do
          {:ok, definition} -> {:ok, definition}
          :error -> {:error, {:unknown_skill, name}}
        end

      {:reply, reply, skills}
    end
  end

  defmodule RecordingDelivery do
    def send_message(target, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delivery_send, target, text, opts})
      maybe_sleep(opts)

      case Keyword.get(opts, :result, :ok) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_sleep(opts) do
      case Keyword.get(opts, :sleep_ms, 0) do
        ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
        _ms -> :ok
      end
    end
  end

  defmodule TransientAdapter do
    @moduledoc false
    # Drives the runner's transient-infrastructure retry: each fresh AgentLoop
    # run calls `chat/3` once, so a shared counter lets us fail the first N
    # whole-loop attempts with a `:connection_unavailable` transport error
    # (the wake-from-sleep pool-checkout signature) then succeed — or fail
    # forever to exercise the bounded-attempts ceiling.
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      counter = Keyword.fetch!(opts, :counter)
      parent = Keyword.fetch!(opts, :test_pid)
      n = Agent.get_and_update(counter, fn x -> {x + 1, x + 1} end)
      send(parent, {:transient_chat, n})

      cond do
        n <= Keyword.get(opts, :fail_until, 0) ->
          Keyword.get(opts, :transient_error, connection_unavailable_error())

        error = Keyword.get(opts, :fail_with) ->
          {:error, error}

        true ->
          success_turn(n)
      end
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, "no continue expected"}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp connection_unavailable_error do
      {:error,
       {:provider_transport_error,
        %{
          provider: :openai_codex,
          adapter: :codex,
          reason: :connection_unavailable,
          kind: :connection_unavailable,
          message: "Codex could not obtain an HTTP connection (transient).",
          stage: :before_response
        }}}
    end

    defp success_turn(n) do
      {:ok,
       %{
         content: "recovered after #{n - 1} transient retries",
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "mock",
         provider_state: %{rest: []}
       }}
    end
  end

  defmodule ToolThenTransientAdapter do
    @moduledoc false
    # First LLM call requests a tool; after the tool executes, the follow-up
    # `continue/3` fails with the connection-unavailable transport signature.
    # This exercises the retry idempotency gate: a transient loss AFTER a tool
    # ran must NOT replay the whole loop (and its side effects).
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_then_transient, :chat})

      {:ok,
       %{
         content: "",
         tool_calls: [%{id: "fc_1", call_id: "call_1", name: "gate_tool", arguments: "{}"}],
         usage: %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1},
         model: "mock",
         provider_state: %{}
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_then_transient, :continue})

      {:error,
       {:provider_transport_error,
        %{
          provider: :openai_codex,
          adapter: :codex,
          reason: :connection_unavailable,
          kind: :connection_unavailable,
          message: "Codex could not obtain an HTTP connection (transient).",
          stage: :before_response
        }}}
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defmodule ToolThenSilentAdapter do
    @moduledoc false
    # First LLM call requests a tool; the post-tool `continue/3` then goes
    # silent well past the inactivity window. The watchdog suspends that window
    # only while a tool is in flight, so this run must still time out — which is
    # false unless the `{:tool_finish, name, outcome}` event decrements the
    # in-flight count (a mismatched arity would fall through to the generic
    # activity clause and pin `active_tools` at 1 forever).
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_then_silent, :chat})

      {:ok,
       %{
         content: "",
         tool_calls: [%{id: "fc_1", call_id: "call_1", name: "stage3_echo", arguments: "{}"}],
         usage: %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1},
         model: "mock",
         provider_state: %{}
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_then_silent, :continue})
      Process.sleep(Keyword.fetch!(opts, :silence_ms))
      {:error, "the watchdog should have killed this run"}
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  defmodule FanoutAdapter do
    @moduledoc false
    # Serves BOTH the main cron loop and its `subagents` workers off one module
    # (the loop-context routing seam threads it to workers as `:provider`). The
    # main loop carries `test_pid` in its adapter_opts (from the Runner) and is
    # scripted to request a two-task fan-out, then synthesize; workers carry no
    # test_pid (AgentServer's adapter path passes only `model`), are identified
    # by their subagent system prompt, return findings, and record their
    # advertised capability surface into a named Agent for confinement asserts.
    @behaviour FermixCore.Providers.Adapter

    @worker_caps :fanout_worker_caps

    def reset_worker_caps do
      case Process.whereis(@worker_caps) do
        nil -> Agent.start_link(fn -> [] end, name: @worker_caps)
        _pid -> Agent.update(@worker_caps, fn _ -> [] end)
      end

      :ok
    end

    def worker_caps, do: Agent.get(@worker_caps, & &1)

    @impl true
    def chat(messages, capabilities, opts) do
      names = Enum.map(capabilities, & &1.name)

      if worker?(messages) do
        record_worker_caps(names)
        {:ok, terminal_turn("worker findings")}
      else
        report(opts, {:main_caps, names})
        {:ok, main_first_turn(names)}
      end
    end

    @impl true
    def continue(_provider_state, tool_results, opts) do
      report(opts, {:aggregated, tool_results})
      {:ok, terminal_turn("fan-out synthesized")}
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response
    @impl true
    def supports_streaming?, do: false

    defp worker?(messages) do
      Enum.any?(messages, fn m ->
        content = Map.get(m, :content, Map.get(m, "content", ""))
        is_binary(content) and String.contains?(content, "temporary Fermix subagent")
      end)
    end

    defp main_first_turn(names) do
      if "subagents" in names do
        args = %{"tasks" => [%{"id" => "a", "task" => "do a"}, %{"id" => "b", "task" => "do b"}]}

        %{
          content: "",
          tool_calls: [
            %{id: "fc_1", call_id: "call_1", name: "subagents", arguments: Jason.encode!(args)}
          ],
          provider_state: %{rest: []},
          usage: %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1},
          model: "mock"
        }
      else
        terminal_turn("no subagents available")
      end
    end

    defp terminal_turn(content) do
      %{
        content: content,
        tool_calls: [],
        provider_state: %{rest: []},
        usage: %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1},
        model: "mock"
      }
    end

    defp record_worker_caps(names) do
      case Process.whereis(@worker_caps) do
        nil -> :ok
        _pid -> Agent.update(@worker_caps, fn prior -> prior ++ [names] end)
      end
    end

    defp report(opts, message) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-jobs-runner-#{unique}.db")
    output_base_dir = Path.join(System.tmp_dir!(), "fermix-jobs-runner-output-#{unique}")
    repo = :"jobs_runner_repo_#{unique}"
    capability_registry = :"jobs_runner_capability_registry_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({CapabilityRegistry, name: capability_registry})

    # Reset [fermix_core.routing] so a leaked host cron_* config can't change
    # which route an unpinned job resolves (known mix test host-config leak).
    routing = Application.get_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :routing, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :routing, routing)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      FermixTestSupport.SafeRm.rm_rf!(output_base_dir)
    end)

    %{repo: repo, capability_registry: capability_registry, output_base_dir: output_base_dir}
  end

  test "runs AgentLoop with isolated cron prompt and stores output artifact", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Stage 3 Check",
               schedule: "every 15 minutes",
               task_prompt: "Summarize the repository status."
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      script: [
        %{
          content: "Scheduled job completed.",
          usage: %{prompt_tokens: 7, completion_tokens: 4, total_tokens: 11}
        }
      ]
    )

    assert_receive {:adapter_chat, messages, []}, 1_000

    assert Enum.any?(
             messages,
             &(&1.role == "system" and &1.content =~ "You are running as a scheduled Fermix job.")
           )

    assert Enum.any?(
             messages,
             &(&1.role == "system" and &1.content =~ "Do not call messaging tools")
           )

    assert Enum.any?(
             messages,
             &(&1.role == "system" and &1.content =~ "Fermix owns job lifecycle")
           )

    assert Enum.any?(
             messages,
             &(&1.role == "system" and &1.content =~ "Current date:")
           )

    assert Enum.any?(
             messages,
             &(&1.role == "user" and &1.content == "Summarize the repository status.")
           )

    assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
    assert stored_run.status == "ok"
    assert stored_run.final_response == "Scheduled job completed."
    assert stored_run.iterations == 1
    assert stored_run.token_usage == %{"total" => 11}
    assert stored_run.output_ref == "job_runs/#{run.id}/output.md"
    assert stored_run.prompt_snapshot =~ "You are running as a scheduled Fermix job."

    assert {:ok, artifact} = File.read(Path.join(output_base_dir, stored_run.output_ref))
    assert artifact =~ "Scheduled job completed."
  end

  test "writes successful run summary memory with job source provenance", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Daily Digest",
               description: "Summarizes the morning project state.",
               schedule: "every 15 minutes",
               task_prompt: "Summarize what changed."
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      script: [
        %{
          content: "The digest found a queue regression and a storage warning.",
          usage: %{prompt_tokens: 7, completion_tokens: 4, total_tokens: 11}
        }
      ]
    )

    assert {:ok, memory} =
             Repo.get_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "job",
                 scope_id: job.memory_source_id,
                 key: "latest"
               },
               server: repo
             )

    assert memory.category == "job_run_summary"
    assert memory.value =~ "queue regression"
    assert memory.source_id == job.memory_source_id
    assert memory.source_type == "scheduled_job"
    assert memory.source_name == "Daily Digest"
    assert memory.source_description == "Summarizes the morning project state."
    assert memory.session_id == run.session_id
    assert memory.run_id == run.id
  end

  test "passes job allowlist to AgentLoop and records max iteration failure", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("stage3_echo"))
    :ok = CapabilityRegistry.register(capability_registry, test_capability("stage3_blocked"))

    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Max Iteration Check",
               schedule: "every 15 minutes",
               task_prompt: "Use one tool.",
               allowed_tools: ["stage3_echo"],
               max_iterations: 1
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      script: [
        %{
          tool_calls: [
            %{
              id: "fc_1",
              call_id: "call_1",
              name: "stage3_echo",
              arguments: Jason.encode!(%{"text" => "hello"})
            }
          ],
          usage: %{prompt_tokens: 1, completion_tokens: 0, total_tokens: 1}
        }
      ]
    )

    assert_receive {:adapter_chat, _messages, ["stage3_echo"]}, 1_000

    assert {:ok, failed_run} = Repo.get_job_run(run.id, server: repo)
    assert failed_run.status == "error"
    assert failed_run.error =~ "Maximum iterations (1) reached"
    assert failed_run.output_ref == "job_runs/#{run.id}/error.md"

    assert {:ok, updated_job} = Registry.get_job(job.id, repo: repo)
    assert updated_job.last_status == "error"
    assert updated_job.last_error =~ "Maximum iterations"

    assert {:ok, source} = Registry.get_memory_source(job.memory_source_id, repo: repo)
    assert source.last_status == "error"
  end

  test "records inactivity timeout without leaving an active run", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Timeout Check",
               schedule: "every 15 minutes",
               task_prompt: "This adapter will stop responding."
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      inactivity_timeout_ms: 20,
      adapter_opts: [sleep_ms: 200],
      script: [%{content: "too late"}]
    )

    assert {:ok, timed_out_run} = Repo.get_job_run(run.id, server: repo)
    assert timed_out_run.status == "timeout"
    assert timed_out_run.error =~ "inactivity timeout"
    assert timed_out_run.output_ref == "job_runs/#{run.id}/error.md"

    assert {:ok, []} = Repo.list_job_runs(%{job_id: job.id, status: "running"}, server: repo)
    assert {:ok, []} = Repo.list_job_runs(%{job_id: job.id, status: "queued"}, server: repo)
  end

  test "a finished tool re-arms the inactivity watchdog", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("stage3_echo"))

    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Post Tool Silence",
               schedule: "every 15 minutes",
               task_prompt: "Use one tool, then go quiet.",
               allowed_tools: ["stage3_echo"]
             )

    parent = self()

    {:ok, pid} =
      Runner.start_link(
        repo: repo,
        job: job,
        run: run,
        notify: parent,
        capability_registry: capability_registry,
        adapter: ToolThenSilentAdapter,
        adapter_opts: [test_pid: parent, silence_ms: 2_000],
        output_base_dir: output_base_dir,
        inactivity_timeout_ms: 20,
        network_readiness_enabled: false
      )

    ref = Process.monitor(pid)

    assert_receive {:tool_then_silent, :chat}, 1_000
    assert_receive {:tool_then_silent, :continue}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {:ok, timed_out_run} = Repo.get_job_run(run.id, server: repo)
    assert timed_out_run.status == "timeout"
    assert timed_out_run.error =~ "inactivity timeout"
  end

  test "applies default wall-clock watchdog when no timeout is configured", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Default Watchdog Check",
               schedule: "every 15 minutes",
               task_prompt: "This adapter will hang past the default watchdog."
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      default_timeout_ms: 20,
      adapter_opts: [sleep_ms: 200],
      script: [%{content: "too late"}]
    )

    assert {:ok, timed_out_run} = Repo.get_job_run(run.id, server: repo)
    assert timed_out_run.status == "timeout"
    assert timed_out_run.error =~ "wall-clock timeout after 20ms"
  end

  test "job timeout_seconds is honored when the caller passes timeout_ms: nil", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Job Wall Clock",
               schedule: "every 15 minutes",
               task_prompt: "This adapter hangs past the job's own wall-clock timeout.",
               timeout_seconds: 1
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      timeout_ms: nil,
      adapter_opts: [sleep_ms: 5_000],
      script: [%{content: "too late"}],
      exit_timeout_ms: 3_000
    )

    assert {:ok, timed_out_run} = Repo.get_job_run(run.id, server: repo)
    assert timed_out_run.status == "timeout"
    assert timed_out_run.error =~ "wall-clock timeout after 1000ms"
  end

  test "job inactivity_timeout_seconds is honored when the caller passes inactivity_timeout_ms: nil",
       %{
         repo: repo,
         capability_registry: capability_registry,
         output_base_dir: output_base_dir
       } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Job Inactivity",
               schedule: "every 15 minutes",
               task_prompt: "This adapter goes silent past the job's inactivity timeout.",
               inactivity_timeout_seconds: 1
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      inactivity_timeout_ms: nil,
      adapter_opts: [sleep_ms: 5_000],
      script: [%{content: "too late"}],
      exit_timeout_ms: 3_000
    )

    assert {:ok, timed_out_run} = Repo.get_job_run(run.id, server: repo)
    assert timed_out_run.status == "timeout"
    assert timed_out_run.error =~ "inactivity timeout after 1000ms"
  end

  test "an explicit caller timeout_ms still overrides the job's timeout_seconds", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Caller Override",
               schedule: "every 15 minutes",
               task_prompt: "The caller's explicit timeout wins over the job column.",
               timeout_seconds: 3_600
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      timeout_ms: 20,
      adapter_opts: [sleep_ms: 200],
      script: [%{content: "too late"}]
    )

    assert {:ok, timed_out_run} = Repo.get_job_run(run.id, server: repo)
    assert timed_out_run.status == "timeout"
    assert timed_out_run.error =~ "wall-clock timeout after 20ms"
  end

  test "guest-trust scheduled runs are narrowed to read-only capabilities", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("stage3_read"))

    :ok =
      CapabilityRegistry.register(capability_registry, test_capability("stage3_exec", :exec))

    :ok =
      CapabilityRegistry.register(
        capability_registry,
        test_capability("stage3_external", :external_api)
      )

    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Trust Check",
               schedule: "every 15 minutes",
               task_prompt: "Use only allowed read-only tools.",
               created_by_trust: "guest",
               allowed_tools: ["stage3_read", "stage3_exec", "stage3_external"]
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      script: [%{content: "done"}]
    )

    assert_receive {:adapter_chat, _messages, ["stage3_read"]}, 1_000
  end

  test "operator-created scheduled runs preserve the operator capability surface", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("owner_read"))

    :ok =
      CapabilityRegistry.register(
        capability_registry,
        test_capability("owner_external", :external_api)
      )

    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Owner Job",
               schedule: "every 15 minutes",
               task_prompt: "Use the full owner surface.",
               created_by_trust: "operator",
               allowed_tools: ["owner_read", "owner_external"]
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      script: [%{content: "done"}]
    )

    assert_receive {:adapter_chat, _messages, tool_names}, 1_000
    assert "owner_read" in tool_names
    assert "owner_external" in tool_names
  end

  test "a scheduled job inherits its skill's tool allowlist", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("skill_read"))
    :ok = CapabilityRegistry.register(capability_registry, test_capability("skill_blocked"))

    {:ok, skills} =
      SkillRegistryStub.start_link(%{
        "research" => skill_definition("research", allowed_tools: ["skill_read"])
      })

    # Operator job, no own allowlist -> full operator surface absent a skill.
    # Naming a skill that allowlists only skill_read must confine the run.
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Skill Allowlist",
               schedule: "every 15 minutes",
               task_prompt: "Run as the research skill.",
               created_by_trust: "operator",
               skill_name: "research"
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      skill_registry: skills,
      output_base_dir: output_base_dir,
      script: [%{content: "done"}]
    )

    assert_receive {:adapter_chat, _messages, ["skill_read"]}, 1_000
  end

  test "a scheduled job inherits its skill's capability policy", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("policy_read"))

    :ok =
      CapabilityRegistry.register(capability_registry, test_capability("policy_exec", :exec))

    {:ok, skills} =
      SkillRegistryStub.start_link(%{
        "reader" => skill_definition("reader", policy: ["read_only"])
      })

    # Operator job, no own allowlist or policy -> full operator surface absent a
    # skill. A skill declaring read_only policy must drop the exec capability.
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Skill Policy",
               schedule: "every 15 minutes",
               task_prompt: "Run as the reader skill.",
               created_by_trust: "operator",
               skill_name: "reader"
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      skill_registry: skills,
      output_base_dir: output_base_dir,
      script: [%{content: "done"}]
    )

    assert_receive {:adapter_chat, _messages, ["policy_read"]}, 1_000
  end

  test "a skill narrows a guest job below its own trust default", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    :ok = CapabilityRegistry.register(capability_registry, test_capability("guest_read"))

    :ok =
      CapabilityRegistry.register(capability_registry, test_capability("guest_net", :network))

    {:ok, skills} =
      SkillRegistryStub.start_link(%{
        "narrow" => skill_definition("narrow", policy: ["read_only"])
      })

    # A guest job runs with the scheduled-job default policy ([:read_only,
    # :network]) absent a skill. Naming a read_only-only skill must drop the
    # network capability — the skill narrows further than the job would alone.
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Guest Narrow",
               schedule: "every 15 minutes",
               task_prompt: "Run as the narrow skill.",
               created_by_trust: "guest",
               skill_name: "narrow"
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      skill_registry: skills,
      output_base_dir: output_base_dir,
      script: [%{content: "done"}]
    )

    assert_receive {:adapter_chat, _messages, ["guest_read"]}, 1_000
  end

  test "a guest job naming a skill that demands only forbidden classes fails loudly", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    {:ok, skills} =
      SkillRegistryStub.start_link(%{
        "exec_only" => skill_definition("exec_only", policy: ["exec"])
      })

    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Forbidden Skill",
               schedule: "every 15 minutes",
               task_prompt: "Run as an exec-only skill.",
               created_by_trust: "guest",
               skill_name: "exec_only"
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      skill_registry: skills,
      output_base_dir: output_base_dir,
      script: [%{content: "unreachable"}]
    )

    assert {:ok, failed_run} = Repo.get_job_run(run.id, server: repo)
    assert failed_run.status == "error"
    assert failed_run.error =~ "grants no"
  end

  test "delivers successful channel output after persisting the run", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Delivery Check",
               schedule: "every 15 minutes",
               task_prompt: "Send the digest.",
               delivery_mode: "channel",
               delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      delivery_adapter: RecordingDelivery,
      delivery_opts: [test_pid: self()],
      script: [%{content: "Digest ready."}]
    )

    assert_receive {:delivery_send, "123", "Digest ready.", _opts}, 1_000

    assert {:ok, delivered_run} = Repo.get_job_run(run.id, server: repo)
    assert delivered_run.status == "ok"
    assert delivered_run.delivery_status == "sent"
    assert delivered_run.delivery_error == nil
    assert delivered_run.output_ref == "job_runs/#{run.id}/output.md"
  end

  test "skips delivery when the final response is the silent marker", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Silent Delivery Check",
               schedule: "every 15 minutes",
               task_prompt: "Only report changes.",
               delivery_mode: "channel",
               delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      delivery_adapter: RecordingDelivery,
      delivery_opts: [test_pid: self()],
      script: [%{content: "[SILENT]"}]
    )

    refute_receive {:delivery_send, _target, _text, _opts}, 100

    assert {:ok, delivered_run} = Repo.get_job_run(run.id, server: repo)
    assert delivered_run.status == "ok"
    assert delivered_run.delivery_status == "skipped"
    assert delivered_run.delivery_error == nil
  end

  test "delivery failure does not change successful run status", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Delivery Failure Check",
               schedule: "every 15 minutes",
               task_prompt: "Send the digest.",
               delivery_mode: "channel",
               delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      delivery_adapter: RecordingDelivery,
      delivery_opts: [test_pid: self(), result: {:error, :network_down}],
      script: [%{content: "Digest ready."}]
    )

    assert_receive {:delivery_send, "123", "Digest ready.", _opts}, 1_000

    assert {:ok, delivered_run} = Repo.get_job_run(run.id, server: repo)
    assert delivered_run.status == "ok"
    assert delivered_run.delivery_status == "failed"
    assert delivered_run.delivery_error =~ "network_down"
  end

  test "delivery timeout marks delivery failed and exits cleanly", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Delivery Timeout Check",
               schedule: "every 15 minutes",
               task_prompt: "Send the digest.",
               delivery_mode: "channel",
               delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
             )

    started_at = System.monotonic_time(:millisecond)

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      delivery_adapter: RecordingDelivery,
      delivery_opts: [test_pid: self(), sleep_ms: 200],
      delivery_timeout_ms: 20,
      script: [%{content: "Digest ready."}]
    )

    duration_ms = System.monotonic_time(:millisecond) - started_at
    assert duration_ms < 150
    assert_receive {:delivery_send, "123", "Digest ready.", _opts}, 1_000

    assert {:ok, delivered_run} = Repo.get_job_run(run.id, server: repo)
    assert delivered_run.status == "ok"
    assert delivered_run.delivery_status == "failed"
    assert delivered_run.delivery_error =~ "delivery_timeout"
  end

  test "local delivery mode marks delivery sent without a channel send", %{
    repo: repo,
    capability_registry: capability_registry,
    output_base_dir: output_base_dir
  } do
    assert {:ok, {job, run}} =
             create_claimed_job(repo,
               name: "Local Delivery Check",
               schedule: "every 15 minutes",
               task_prompt: "Save locally.",
               delivery_mode: "local"
             )

    assert_runner_exits_normally(
      job,
      run,
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir,
      delivery_adapter: RecordingDelivery,
      delivery_opts: [test_pid: self()],
      script: [%{content: "Local digest ready."}]
    )

    refute_receive {:delivery_send, _target, _text, _opts}, 100

    assert {:ok, delivered_run} = Repo.get_job_run(run.id, server: repo)
    assert delivered_run.status == "ok"
    assert delivered_run.delivery_status == "sent"
    assert delivered_run.delivery_error == nil
  end

  # The `Keyword.get(opts, :timeout_ms)` shape below is load-bearing: it mirrors
  # Jobs.Scheduler, which always passes these keys and lets the value be nil when
  # unset. Do not "clean it up" into conditional puts — that would stop exercising
  # the caller shape that shadowed per-job timeouts.
  defp assert_runner_exits_normally(job, run, opts) do
    parent = self()
    script = Keyword.fetch!(opts, :script)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    {:ok, pid} =
      Runner.start_link(
        repo: Keyword.fetch!(opts, :repo),
        job: job,
        run: run,
        notify: parent,
        capability_registry: Keyword.fetch!(opts, :capability_registry),
        skill_registry: Keyword.get(opts, :skill_registry),
        adapter: RecordingAdapter,
        adapter_opts: Keyword.merge([test_pid: parent, script: script], adapter_opts),
        output_base_dir: Keyword.fetch!(opts, :output_base_dir),
        timeout_ms: Keyword.get(opts, :timeout_ms),
        default_timeout_ms: Keyword.get(opts, :default_timeout_ms),
        inactivity_timeout_ms: Keyword.get(opts, :inactivity_timeout_ms),
        delivery_adapter: Keyword.get(opts, :delivery_adapter),
        delivery_opts: Keyword.get(opts, :delivery_opts, []),
        delivery_timeout_ms: Keyword.get(opts, :delivery_timeout_ms)
      )

    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal},
                   Keyword.get(opts, :exit_timeout_ms, 1_000)
  end

  defp create_claimed_job(repo, attrs) do
    now = ~U[2026-05-02 14:00:00Z]
    due_at = ~U[2026-05-02 14:15:00Z]

    with {:ok, job} <-
           Registry.create_job(
             Map.merge(
               %{
                 name: "Scheduled Job",
                 schedule: "every 15 minutes",
                 task_prompt: "Run.",
                 created_by_trust: "operator"
               },
               Enum.into(attrs, %{})
             ),
             repo: repo,
             now: now
           ),
         {:ok, {claimed_job, run}} <-
           Repo.claim_due_job(
             job.id,
             %{state: "running", next_run_at: ~U[2026-05-02 14:30:00Z], updated_at: due_at},
             %{
               id: "run_#{System.unique_integer([:positive])}",
               job_id: job.id,
               session_id: "cron_#{job.id}_20260502_141500",
               trigger: "schedule",
               status: "queued",
               claimed_at: due_at,
               delivery_status: "none",
               created_at: due_at,
               updated_at: due_at
             },
             due_at,
             server: repo
           ) do
      {:ok, {claimed_job, run}}
    end
  end

  defp skill_definition(name, opts) do
    attrs =
      %{
        "name" => name,
        "description" => "Test skill #{name}",
        "system_prompt" => "You are the #{name} skill."
      }
      |> maybe_put_attr("allowed_tools", Keyword.get(opts, :allowed_tools))
      |> maybe_put_attr("policy", Keyword.get(opts, :policy))

    {:ok, definition} = AgentDefinition.new(attrs)
    AgentDefinition.with_trust(definition, :operator)
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp test_capability(name, policy_class \\ :read_only) do
    Capability.new(%{
      name: name,
      description: "Test capability #{name}",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :execute_test_capability, []},
      policy_class: policy_class
    })
  end

  def execute_test_capability(args, _context) do
    {:ok, %{success: true, output: "echo #{inspect(args)}"}}
  end

  describe "provider_atom/1" do
    test "maps catalog provider strings, passes atoms, rejects unknowns" do
      assert Runner.provider_atom(nil) == nil
      assert Runner.provider_atom("xai") == :xai
      assert Runner.provider_atom("anthropic") == :anthropic
      assert Runner.provider_atom(:openai_codex) == :openai_codex

      assert_raise ArgumentError, ~r/unsupported scheduled job provider/, fn ->
        Runner.provider_atom("gemini")
      end

      # M12 §2.3-6: unknown atoms get the same gate as strings instead of
      # passing through to a later, less specific RouteResolver raise.
      assert_raise ArgumentError, ~r/unsupported scheduled job provider/, fn ->
        Runner.provider_atom(:gemini)
      end
    end
  end

  describe "effective_trust/1" do
    test "maps the stored vocabulary and raises on anything else" do
      assert Runner.effective_trust(%{created_by_trust: "operator"}) == :operator
      assert Runner.effective_trust(%{created_by_trust: "guest"}) == :guest

      # Post-migration the schema only stores operator/guest; an out-of-
      # vocabulary value can only be a corrupt row, so the run fails loudly.
      assert_raise FunctionClauseError, fn ->
        Runner.effective_trust(%{created_by_trust: "core"})
      end
    end
  end

  describe "scheduled-run delegation (§11)" do
    setup do
      :ok = FanoutAdapter.reset_worker_caps()
      :ok
    end

    test "an operator job fans out via subagents; workers nest under the run session", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      :ok =
        CapabilityRegistry.register(
          capability_registry,
          BuiltinCapability.from_tool_module(FermixCore.Tools.Subagents)
        )

      test_pid = self()
      handler = "runner-fanout-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:fermix, :agent, :start],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:agent_start, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Fan Out",
                 task_prompt: "Delegate two independent parts.",
                 created_by_trust: "operator"
               )

      start_fanout_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir
      )

      # subagents is both advertised (operator, depth 0) and executable now.
      assert_receive {:main_caps, main_names}, 1_000
      assert "subagents" in main_names

      # Both workers nest under the run's session_id (cron_<job>_<ts>), not an
      # orphan trace — proof the routing seam threaded parent_session.
      assert_receive {:agent_start, %{name: "subagent:a", parent_session: parent_a}}, 2_000
      assert_receive {:agent_start, %{name: "subagent:b", parent_session: parent_b}}, 2_000
      assert parent_a == run.session_id
      assert parent_b == run.session_id

      # Results aggregate: the fan-out result handed back to the main loop's
      # continuation carries both workers, both completed.
      assert_receive {:aggregated, [%{output: json}]}, 2_000
      summary = Jason.decode!(json)["summary"]
      assert summary["requested"] == 2
      assert summary["completed"] == 2

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "ok"
      assert stored_run.final_response == "fan-out synthesized"
    end

    test "a tool-confined operator job bounds its workers to the same allowlist", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      :ok =
        CapabilityRegistry.register(
          capability_registry,
          BuiltinCapability.from_tool_module(FermixCore.Tools.Subagents)
        )

      :ok =
        CapabilityRegistry.register(capability_registry, test_capability("web_like", :network))

      :ok =
        CapabilityRegistry.register(
          capability_registry,
          test_capability("blocked_tool", :network)
        )

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Confined Fanout",
                 task_prompt: "Delegate within the ceiling.",
                 created_by_trust: "operator",
                 allowed_tools: ["subagents", "web_like"]
               )

      start_fanout_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir
      )

      assert_receive {:main_caps, main_names}, 1_000
      assert "subagents" in main_names
      assert "web_like" in main_names
      refute "blocked_tool" in main_names

      assert_receive {:aggregated, _tool_results}, 2_000

      # Both workers inherit exactly the job's tool ceiling: web_like is
      # advertised, subagents is inert in a worker (depth guard + §12 gate drops
      # it from the wire), and blocked_tool was never in the allowlist.
      worker_caps = FanoutAdapter.worker_caps()
      assert length(worker_caps) == 2
      assert Enum.all?(worker_caps, &(&1 == ["web_like"]))
    end

    test "a skill-confined operator job bounds its workers to the skill allowlist", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      :ok =
        CapabilityRegistry.register(
          capability_registry,
          BuiltinCapability.from_tool_module(FermixCore.Tools.Subagents)
        )

      :ok =
        CapabilityRegistry.register(capability_registry, test_capability("web_like", :network))

      :ok =
        CapabilityRegistry.register(
          capability_registry,
          test_capability("blocked_tool", :network)
        )

      # Operator job with no own allowlist, confined only by the named skill's
      # allowlist. The run's effective allowlist is the skill ∩ job intersection,
      # and §11.2 stamps that same value into the tool context the workers read.
      {:ok, skills} =
        SkillRegistryStub.start_link(%{
          "research" => skill_definition("research", allowed_tools: ["subagents", "web_like"])
        })

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Skill Confined Fanout",
                 task_prompt: "Delegate as the research skill.",
                 created_by_trust: "operator",
                 skill_name: "research"
               )

      start_fanout_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        skill_registry: skills,
        output_base_dir: output_base_dir
      )

      assert_receive {:main_caps, main_names}, 1_000
      assert "subagents" in main_names
      assert "web_like" in main_names
      refute "blocked_tool" in main_names

      assert_receive {:aggregated, _tool_results}, 2_000

      # The skill ∩ job intersection reaches the workers: web_like is advertised,
      # subagents is inert in a worker (depth guard + §12 gate drops it from the
      # wire), and blocked_tool was never in the skill allowlist.
      worker_caps = FanoutAdapter.worker_caps()
      assert length(worker_caps) == 2
      assert Enum.all?(worker_caps, &(&1 == ["web_like"]))
    end

    test "a guest job never sees subagents (policy-class exclusion)", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      :ok =
        CapabilityRegistry.register(
          capability_registry,
          BuiltinCapability.from_tool_module(FermixCore.Tools.Subagents)
        )

      :ok = CapabilityRegistry.register(capability_registry, test_capability("guest_read"))

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Guest No Fanout",
                 task_prompt: "Try to delegate.",
                 created_by_trust: "guest"
               )

      start_fanout_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir
      )

      # subagents is policy class :external_api, which the guest surface excludes
      # — asserted at the cron seam, so guest cron fan-out is impossible.
      assert_receive {:main_caps, names}, 1_000
      refute "subagents" in names
      assert "guest_read" in names

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "ok"
    end

    test "a provider-pinned job threads its own route to workers, not the global primary", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      {:ok, _} = Agent.start_link(fn -> nil end, name: :runner_route_probe)
      on_exit(fn -> stop_probe_agent() end)

      :ok = CapabilityRegistry.register(capability_registry, route_probe_capability())

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Pinned Fanout",
                 task_prompt: "Delegate on the pinned route.",
                 created_by_trust: "operator",
                 provider: "xai",
                 model: "grok-4.3"
               )

      # A probe tool records the loop context's ordered_routes — the exact seam
      # `subagents.base_spawn_opts` reads to place workers. The main loop uses
      # the injected stub adapter, so this is hermetic; the pin still resolves
      # into the worker route chain rather than falling back to the primary.
      assert_runner_exits_normally(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        script: [
          %{tool_calls: [route_probe_call()]},
          %{content: "done"}
        ]
      )

      routes = Agent.get(:runner_route_probe, & &1)
      assert [{%{provider: :xai, model: "grok-4.3"}, _opts} | _] = routes
    end

    defp start_fanout_runner(job, run, opts) do
      parent = self()

      {:ok, pid} =
        Runner.start_link(
          repo: Keyword.fetch!(opts, :repo),
          job: job,
          run: run,
          notify: parent,
          capability_registry: Keyword.fetch!(opts, :capability_registry),
          skill_registry: Keyword.get(opts, :skill_registry),
          adapter: FanoutAdapter,
          adapter_opts: [test_pid: parent],
          output_base_dir: Keyword.fetch!(opts, :output_base_dir)
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    end

    defp route_probe_call do
      %{id: "fc_probe", call_id: "call_probe", name: "route_probe", arguments: "{}"}
    end

    defp route_probe_capability do
      Capability.new(%{
        name: "route_probe",
        description: "records the loop context's ordered_routes",
        parameters: %{"type" => "object", "properties" => %{}},
        kind: :builtin,
        executor: {__MODULE__, :execute_route_probe, []},
        policy_class: :read_only
      })
    end

    defp stop_probe_agent do
      case Process.whereis(:runner_route_probe) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end
  end

  def execute_route_probe(_args, context) do
    Agent.update(:runner_route_probe, fn _ -> Map.get(context, :ordered_routes) end)
    {:ok, %{success: true, output: "probed"}}
  end

  describe "cron model routing" do
    @script [
      %{content: "done", usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}}
    ]

    test "an unpinned job resolves the configured cron_* default and records route_used", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      Application.put_env(:fermix_core, :routing,
        cron_model: "claude-haiku-4-5",
        cron_reasoning_effort: "low"
      )

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Cron Default", task_prompt: "Run.")

      assert_runner_exits_normally(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        script: @script
      )

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.job_config_snapshot["task_prompt"] == "Run."
      route_used = stored_run.job_config_snapshot["route_used"]
      # cron_model carries no cron_provider, so the provider defaults to the primary
      # (:openai in the test env) — NOT the claude slug's catalog owner. A
      # cross-provider cron worker needs an explicit cron_provider.
      assert route_used["provider"] == "openai"
      assert route_used["model"] == "claude-haiku-4-5"
      assert route_used["reasoning_effort"] == "low"
    end

    test "a pinned job ignores the cron_* default", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      Application.put_env(:fermix_core, :routing, cron_model: "claude-haiku-4-5")

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Pinned",
                 task_prompt: "Run.",
                 provider: "xai",
                 model: "grok-4.3"
               )

      assert_runner_exits_normally(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        script: @script
      )

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      route_used = stored_run.job_config_snapshot["route_used"]
      assert route_used["provider"] == "xai"
      assert route_used["model"] == "grok-4.3"
    end

    test "an unpinned job with no cron config uses the primary chain", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      Application.put_env(:fermix_core, :routing, [])

      assert {:ok, {job, run}} = create_claimed_job(repo, name: "No Cron", task_prompt: "Run.")

      assert_runner_exits_normally(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        script: @script
      )

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      # No cron override -> today's primary/fallback chain (default :openai in test env).
      assert stored_run.job_config_snapshot["route_used"]["provider"] == "openai"
    end
  end

  describe "network readiness gate" do
    @readiness_script [
      %{
        content: "ran after network came up",
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      }
    ]

    test "waits for the network before the first attempt, then runs the job", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      probe = fn _host, _port, _timeout ->
        n = Agent.get_and_update(counter, fn x -> {x + 1, x + 1} end)
        send(parent, {:readiness_probe, n})
        if n >= 3, do: :ok, else: {:error, :ehostunreach}
      end

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Readiness Recover", task_prompt: "Run.")

      start_readiness_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        readiness_host: "api.test",
        readiness_port: 443,
        readiness_opts: [probe_fn: probe, interval_ms: 10, budget_ms: 10_000]
      )

      # Two failed probes, then the third succeeds and the run starts.
      assert_receive {:readiness_probe, 1}, 1_000
      assert_receive {:readiness_probe, 2}, 1_000
      assert_receive {:readiness_probe, 3}, 1_000
      refute_receive {:readiness_probe, 4}, 100

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "ok"
      assert stored_run.final_response == "ran after network came up"
    end

    test "skips the readiness probe when the gate is disabled", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      parent = self()

      probe = fn _host, _port, _timeout ->
        send(parent, :readiness_probe)
        :ok
      end

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Readiness Disabled", task_prompt: "Run.")

      start_readiness_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        network_readiness_enabled: false,
        readiness_host: "api.test",
        readiness_port: 443,
        readiness_opts: [probe_fn: probe]
      )

      refute_receive :readiness_probe, 200

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "ok"
    end

    # Mirrors `assert_runner_exits_normally` but forwards the readiness-gate
    # injection points (host/port/probe + disable flag) and a no-op delay so the
    # backoff between probes never sleeps for real.
    defp start_readiness_runner(job, run, opts) do
      parent = self()

      {:ok, pid} =
        Runner.start_link(
          repo: Keyword.fetch!(opts, :repo),
          job: job,
          run: run,
          notify: parent,
          capability_registry: Keyword.fetch!(opts, :capability_registry),
          adapter: RecordingAdapter,
          adapter_opts: [test_pid: parent, script: @readiness_script],
          output_base_dir: Keyword.fetch!(opts, :output_base_dir),
          delay_fn: fn _ms -> :ok end,
          network_readiness_enabled: Keyword.get(opts, :network_readiness_enabled, true),
          readiness_host: Keyword.get(opts, :readiness_host),
          readiness_port: Keyword.get(opts, :readiness_port),
          readiness_opts: Keyword.get(opts, :readiness_opts, [])
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  describe "transient-infrastructure retry" do
    test "retries a transient connection-unavailable failure and recovers", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      {:ok, counter} = start_counter()

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Wake Race Recover", task_prompt: "Run.")

      run_transient_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        adapter_opts: [counter: counter, fail_until: 2]
      )

      # First whole-loop attempt + two retries: the third attempt succeeds.
      assert_receive {:transient_chat, 1}, 1_000
      assert_receive {:transient_chat, 2}, 1_000
      assert_receive {:transient_chat, 3}, 1_000
      refute_receive {:transient_chat, 4}, 100

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "ok"
      assert stored_run.final_response == "recovered after 2 transient retries"
    end

    test "retries a bare connection-unavailable RuntimeError (non-Codex provider) and recovers",
         %{
           repo: repo,
           capability_registry: capability_registry,
           output_base_dir: output_base_dir
         } do
      {:ok, counter} = start_counter()

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Wake Race Recover Bare", task_prompt: "Run.")

      # Non-Codex adapters return the Finch pool-checkout timeout as a bare
      # %RuntimeError{}, not the typed transport error Codex mints. The runner
      # must still treat it as transient and retry — provider-agnostic recovery.
      bare =
        {:error,
         %RuntimeError{
           message:
             "Finch was unable to provide a connection within the timeout due to excess " <>
               "queuing for connections."
         }}

      run_transient_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        adapter_opts: [counter: counter, fail_until: 2, transient_error: bare]
      )

      assert_receive {:transient_chat, 1}, 1_000
      assert_receive {:transient_chat, 2}, 1_000
      assert_receive {:transient_chat, 3}, 1_000
      refute_receive {:transient_chat, 4}, 100

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "ok"
      assert stored_run.final_response == "recovered after 2 transient retries"
    end

    test "does NOT retry a provider :timeout — that would blow past the configured job timeout",
         %{
           repo: repo,
           capability_registry: capability_registry,
           output_base_dir: output_base_dir
         } do
      {:ok, counter} = start_counter()

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Provider Timeout Terminal", task_prompt: "Run.")

      # A provider timeout means the call already burned its full receive-timeout
      # budget; retrying it (with a fresh per-attempt watchdog) lets the run exceed
      # `[fermix_core.jobs] timeout_seconds` by multiple slow attempts. Cron only
      # retries the fast wake-from-sleep pool-checkout race, so this is terminal.
      provider_timeout =
        {:error,
         {:provider_transport_error,
          %{
            provider: :openai_codex,
            adapter: :codex,
            reason: :timeout,
            kind: :timeout,
            message: "Codex request timed out.",
            stage: :before_response
          }}}

      run_transient_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        adapter_opts: [counter: counter, fail_until: 1, transient_error: provider_timeout]
      )

      assert_receive {:transient_chat, 1}, 1_000
      refute_receive {:transient_chat, 2}, 200

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "error"
    end

    test "waits the assigned startup delay before its first network call (burst stagger)", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      {:ok, counter} = start_counter()
      parent = self()

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Stagger", task_prompt: "Run.")

      {:ok, pid} =
        Runner.start_link(
          repo: repo,
          job: job,
          run: run,
          notify: parent,
          capability_registry: capability_registry,
          adapter: TransientAdapter,
          adapter_opts: [test_pid: parent, counter: counter, fail_until: 0],
          output_base_dir: output_base_dir,
          network_readiness_enabled: false,
          start_delay_ms: 750,
          delay_fn: fn ms -> send(parent, {:delay, ms}) end
        )

      ref = Process.monitor(pid)

      # The startup stagger is slept (via delay_fn) BEFORE the first chat call.
      assert_receive {:delay, 750}, 1_000
      assert_receive {:transient_chat, 1}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "fails the run after the bounded retry ceiling without looping forever", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      {:ok, counter} = start_counter()

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Wake Race Exhaust", task_prompt: "Run.")

      log =
        capture_log(fn ->
          run_transient_runner(job, run,
            repo: repo,
            capability_registry: capability_registry,
            output_base_dir: output_base_dir,
            max_transient_attempts: 2,
            adapter_opts: [counter: counter, fail_until: 999]
          )
        end)

      # 1 initial attempt + exactly 2 retries, then the run fails — bounded.
      assert_receive {:transient_chat, 1}, 1_000
      assert_receive {:transient_chat, 2}, 1_000
      assert_receive {:transient_chat, 3}, 1_000
      refute_receive {:transient_chat, 4}, 100

      assert log =~ "exhausted transient-infrastructure retries"

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "error"
      assert stored_run.error =~ "connection_unavailable"
    end

    test "does not retry a non-transient error", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      {:ok, counter} = start_counter()

      assert {:ok, {job, run}} =
               create_claimed_job(repo, name: "Hard Error", task_prompt: "Run.")

      run_transient_runner(job, run,
        repo: repo,
        capability_registry: capability_registry,
        output_base_dir: output_base_dir,
        adapter_opts: [counter: counter, fail_with: "deterministic provider bug"]
      )

      # Exactly one attempt — a non-transient error must not enter the backoff.
      assert_receive {:transient_chat, 1}, 1_000
      refute_receive {:transient_chat, 2}, 100

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "error"
      assert stored_run.error =~ "deterministic provider bug"
    end

    test "does NOT retry a connection-unavailable failure after a tool has executed", %{
      repo: repo,
      capability_registry: capability_registry,
      output_base_dir: output_base_dir
    } do
      :ok = CapabilityRegistry.register(capability_registry, test_capability("gate_tool"))

      assert {:ok, {job, run}} =
               create_claimed_job(repo,
                 name: "Post Tool Loss",
                 task_prompt: "Run.",
                 allowed_tools: ["gate_tool"]
               )

      parent = self()

      {:ok, pid} =
        Runner.start_link(
          repo: repo,
          job: job,
          run: run,
          notify: parent,
          capability_registry: capability_registry,
          adapter: ToolThenTransientAdapter,
          adapter_opts: [test_pid: parent],
          output_base_dir: output_base_dir,
          network_readiness_enabled: false,
          delay_fn: fn _ms -> :ok end
        )

      ref = Process.monitor(pid)

      # A tool ran, then the follow-up call lost its connection. The gate stops
      # the whole-loop retry, so the loop is never replayed — no second chat.
      assert_receive {:tool_then_transient, :chat}, 1_000
      assert_receive {:tool_then_transient, :continue}, 1_000
      refute_receive {:tool_then_transient, :chat}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      assert {:ok, stored_run} = Repo.get_job_run(run.id, server: repo)
      assert stored_run.status == "error"
    end

    defp start_counter, do: Agent.start_link(fn -> 0 end)

    # Mirrors `assert_runner_exits_normally` but injects TransientAdapter, a
    # no-op delay (no real backoff sleep in tests), and any retry-ceiling
    # overrides. Only keys actually present are forwarded so the Runner's own
    # production defaults still apply for the rest.
    defp run_transient_runner(job, run, opts) do
      parent = self()
      adapter_opts = Keyword.merge([test_pid: parent], Keyword.fetch!(opts, :adapter_opts))

      base = [
        repo: Keyword.fetch!(opts, :repo),
        job: job,
        run: run,
        notify: parent,
        capability_registry: Keyword.fetch!(opts, :capability_registry),
        adapter: TransientAdapter,
        adapter_opts: adapter_opts,
        output_base_dir: Keyword.fetch!(opts, :output_base_dir),
        delay_fn: fn _ms -> :ok end
      ]

      overrides =
        Keyword.take(opts, [
          :max_transient_attempts,
          :transient_backoff_ms,
          :max_transient_retry_ms
        ])

      {:ok, pid} = Runner.start_link(base ++ overrides)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end
end
