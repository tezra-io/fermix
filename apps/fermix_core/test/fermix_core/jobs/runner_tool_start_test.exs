defmodule FermixCore.Jobs.RunnerToolStartTest do
  # M106 §5.1, §5.3 (TLA job_runs JOB-9): a failed run is retried only when no
  # tool had started in it, so a tool of a scheduled run never starts before
  # its run's first tool start is on the row. The runner's own mailbox is held
  # (the runner process suspended) wherever the order matters, so no test here
  # can pass by the runner handling the loop's message first.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @exit_ms 10_000

  # The model asks for one tool once the test says go, then answers. It runs in
  # the run's loop process, which it reports to the test.
  defmodule GatedToolAdapter do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:loop_waiting, self()})

      receive do
        :go -> :ok
      end

      {:ok, turn([%{id: "fc_1", call_id: "call_1", name: "harbour_fetch", arguments: "{}"}], "")}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:ok, turn([], "Fetched.")}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp turn(tool_calls, content) do
      %{
        content: content,
        tool_calls: tool_calls,
        provider_state: %{},
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock"
      }
    end
  end

  # A transparent proxy in front of the real Repo that refuses the stamp of a
  # run's first tool start, as a store that cannot write would.
  defmodule RefuseToolStampRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{real: Keyword.fetch!(opts, :real)}}

    @impl true
    def handle_call({:mark_job_run_tools_started, _run_id, _at}, _from, state),
      do: {:reply, {:error, :injected_fault}, state}

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.real, request), state}
  end

  # A heal run that does nothing: the heal itself is `HealRunTest`'s.
  defmodule IdleHealRun do
    @moduledoc false

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :heal).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(_opts), do: {:ok, spawn_link(fn -> :ok end)}
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-runner-tool-start")
    repo = :"runner_tool_start_repo_#{unique}"
    registry = :"runner_tool_start_caps_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, held_capability(self()))
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    %{repo: repo, registry: registry, output: Path.join(dir, "output")}
  end

  test "the first tool start is on the row before the tool's executor is entered", ctx do
    {job, run} = claimed_run!(ctx.repo)
    Process.flag(:trap_exit, true)
    {:ok, runner} = start_runner(ctx, job, run, ctx.repo)

    assert_receive {:loop_waiting, loop}, @exit_ms
    true = :erlang.suspend_process(runner)
    send(loop, :go)

    assert_receive {:tool_entered, ^loop}, @exit_ms
    assert {:ok, %{tools_started_at: %DateTime{}}} = Repo.get_job_run(run.id, server: ctx.repo)

    true = :erlang.resume_process(runner)
    send(loop, :release)
    assert_receive {:EXIT, ^runner, :normal}, @exit_ms
    assert {:ok, %{status: "ok"}} = Repo.get_job_run(run.id, server: ctx.repo)
  end

  test "a run killed in its first tool, its runner's mailbox never drained, is settled with the start and not retried",
       ctx do
    {:ok, job} = create_job(ctx.repo)
    supervisor = :"runner_tool_start_runners_#{System.unique_integer([:positive])}"
    start_supervised!({RunnerSupervisor, name: supervisor})
    scheduler = start_scheduler(ctx, supervisor)

    {_result, _log} =
      with_log(fn ->
        assert {:ok, run} = Scheduler.run_now(scheduler, job.id)
        TelemetryCapture.attach([[:fermix, :job, :run_error]], run_id: run.id)

        assert_receive {:loop_waiting, loop}, @exit_ms
        [{_id, runner, _type, _modules}] = DynamicSupervisor.which_children(supervisor)
        true = :erlang.suspend_process(runner)
        send(loop, :go)
        assert_receive {:tool_entered, ^loop}, @exit_ms

        Process.exit(runner, :kill)

        assert_receive {:telemetry, [:fermix, :job, :run_error], _measurements, settled}, @exit_ms
        assert settled.retry_disposition == "none"

        assert {:ok, crashed} = Repo.get_job_run(run.id, server: ctx.repo)
        assert crashed.error == "runner crashed: :killed"
        assert %DateTime{} = crashed.tools_started_at
      end)

    assert {:ok, nil} = Repo.get_job_retry(job.id, server: ctx.repo)
  end

  test "a start the store refuses ends the run before the tool runs: not retried, and a heal takes it",
       ctx do
    {job, run} = claimed_run!(ctx.repo)
    proxy = start_supervised!({RefuseToolStampRepo, real: ctx.repo})
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: run.session_id)
    Process.flag(:trap_exit, true)

    {_result, log} =
      with_log(fn ->
        {:ok, runner} = start_runner(ctx, job, run, proxy)
        assert_receive {:loop_waiting, loop}, @exit_ms
        send(loop, :go)

        receive do
          {:tool_entered, _pid} -> flunk("the tool ran on a start the store refused")
          {:EXIT, ^runner, :normal} -> :ok
        after
          @exit_ms -> flunk("the runner did not end")
        end
      end)

    assert log =~ run.id
    assert log =~ ":injected_fault"

    assert {:ok, failed} = Repo.get_job_run(run.id, server: ctx.repo)
    assert failed.status == "error"
    assert failed.failure_kind == "tool_start_unrecorded"
    assert failed.tools_started_at == nil
    assert {:ok, nil} = Repo.get_job_retry(job.id, server: ctx.repo)

    assert {:ok, [%{subject_kind: "job", failure_kind: "tool_start_unrecorded"}]} =
             Repo.job_heals_call(:open_heals, server: ctx.repo)

    # The call the model made is still one tool event, unexecuted.
    assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                     %{tool: "harbour_fetch", success: false}}
  end

  def held_fetch(_args, _context, test_pid) do
    send(test_pid, {:tool_entered, self()})

    receive do
      :release -> {:ok, %{success: true, output: "High water at 06:12."}}
    end
  end

  defp held_capability(test_pid) do
    Capability.new(%{
      name: "harbour_fetch",
      description: "Fetches the harbour's tide table",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :held_fetch, [test_pid]},
      policy_class: :read_only
    })
  end

  defp start_runner(ctx, job, run, repo) do
    Runner.start_link(
      repo: repo,
      job: job,
      run: run,
      notify: self(),
      capability_registry: ctx.registry,
      adapter: GatedToolAdapter,
      adapter_opts: [test_pid: self()],
      output_base_dir: ctx.output,
      network_readiness_enabled: false
    )
  end

  defp start_scheduler(ctx, supervisor) do
    name = :"runner_tool_start_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         repo: ctx.repo,
         runner_supervisor: supervisor,
         scheduler_enabled: true,
         timer_enabled: false,
         runner_module: Runner,
         heal_run_module: IdleHealRun,
         capability_registry: ctx.registry,
         adapter: GatedToolAdapter,
         adapter_opts: [test_pid: self()],
         output_base_dir: ctx.output,
         runner_notify: self(),
         cues_running?: fn -> false end
       ]},
      id: name
    )

    name
  end

  # A job of the owner's whose next run is far off, so a retry of its run
  # would be set with a time of its own.
  defp create_job(repo) do
    Registry.create_job(
      %{
        name: "Harbour tide table #{System.unique_integer([:positive])}",
        schedule: "every 1 hour",
        timezone: "UTC",
        task_prompt: "Fetch this morning's tides.",
        allowed_tools: ["harbour_fetch"],
        created_by_trust: "operator"
      },
      repo: repo,
      now: DateTime.utc_now(),
      scheduler: nil
    )
  end

  defp claimed_run!(repo) do
    {:ok, job} = create_job(repo)
    now = DateTime.utc_now()

    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_#{System.unique_integer([:positive])}",
      trigger: "manual",
      status: "queued",
      claimed_at: now,
      delivery_status: "none",
      created_at: now,
      updated_at: now
    }

    {:ok, {claimed, run}} =
      Repo.claim_job_now(job.id, %{state: "running", updated_at: now}, run_attrs, server: repo)

    {claimed, run}
  end
end
