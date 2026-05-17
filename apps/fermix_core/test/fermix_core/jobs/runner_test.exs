defmodule FermixCore.Jobs.RunnerTest do
  use ExUnit.Case, async: true

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

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-jobs-runner-#{unique}.db")
    output_base_dir = Path.join(System.tmp_dir!(), "fermix-jobs-runner-output-#{unique}")
    repo = :"jobs_runner_repo_#{unique}"
    capability_registry = :"jobs_runner_capability_registry_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({CapabilityRegistry, name: capability_registry})

    on_exit(fn ->
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

  test "scheduled runs apply local trust defaults to capability selection", %{
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
               task_prompt: "Use only allowed local-safe tools.",
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
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
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
                 task_prompt: "Run."
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
end
