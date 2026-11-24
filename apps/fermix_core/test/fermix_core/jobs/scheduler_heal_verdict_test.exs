defmodule FermixCore.Jobs.SchedulerHealVerdictTest do
  # M106 §5.9 (stage S3, decision D8: the owner is told only when a fix did
  # not work), end to end through the Scheduler: a heal whose run decided to
  # rerun the job watches it. The next run settling ok closes it healed with
  # nothing sent; a failure concludes it once more, by the same claim, lease
  # and outbox and with no model, then closes it still failing, and a third
  # failure is kept quiet. The model is a scripted adapter and each job run a
  # runner the test settles; every time is injected.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.HealRun
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Jobs.RunnerSupervisor
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.JobHealRespond
  alias FermixCore.Tools.ListJobRuns
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @created ~U[2031-03-03 06:00:00.000000Z]
  @failed_at ~U[2031-03-04 07:10:00.000000Z]
  @now ~U[2031-03-04 07:30:00.000000Z]
  @heal_event [:fermix, :job, :heal]
  @note "The run stopped before it finished; one more run should tell whether it holds."

  defmodule ScriptedChannel do
    @moduledoc false

    def send_message(destination, text, _opts) do
      destination |> String.to_existing_atom() |> Agent.update(&(&1 ++ [text]))
    end
  end

  # One scripted model turn: the decision to rerun. Every chat is reported.
  # With a `:gate`, the loop first tells the gate who it is and waits for
  # `:go`, so a test can act while the heal run is mid-diagnosis.
  defmodule RerunProvider do
    @moduledoc false

    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), :provider_chat)
      opts |> Keyword.get(:gate) |> wait_at_gate()
      decision = Jason.encode!(%{"decision" => "rerun", "note" => Keyword.fetch!(opts, :note)})
      call = %{id: "fc_1", call_id: "call_1", name: "job_heal_respond", arguments: decision}
      {:ok, turn([call])}
    end

    @impl true
    def continue(_state, _tool_results, _opts), do: {:ok, turn([])}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp wait_at_gate(nil), do: :ok

    defp wait_at_gate(gate) do
      send(gate, {:diagnosing, self()})

      receive do
        :go -> :ok
      end
    end

    defp turn(tool_calls) do
      %{
        content: "",
        tool_calls: tool_calls,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock",
        provider_state: %{}
      }
    end
  end

  # A runner that publishes its run id as the real one does, reports, and
  # settles its run as the test tells it, tracing the heal's move as the real
  # runner's settle does, then ends.
  defmodule SettlingRunner do
    @moduledoc false

    alias FermixCore.Jobs.Telemetry, as: JobTelemetry
    alias FermixCore.Memory.Repo

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :run).id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      run = Keyword.fetch!(opts, :run)
      repo = Keyword.fetch!(opts, :repo)
      notify = Keyword.fetch!(opts, :notify)
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Runner.put_run_id(run.id)
          send(parent, {:labelled, self()})
          send(notify, {:run_started, run, self()})

          receive do
            {:settle, attrs, settle_by} ->
              {:ok, {settled, job, settlement}} =
                Repo.settle_job_run(Map.merge(run, attrs), settle_by, server: repo)

              JobTelemetry.heal_settled(job, settled, settlement)
          end
        end)

      receive do
        {:labelled, ^pid} -> {:ok, pid}
      end
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-heal-verdict")
    repo = :"heal_verdict_repo_#{unique}"
    store = :"heal_verdict_store_#{unique}"
    tasks = :"heal_verdict_tasks_#{unique}"
    caps = :"heal_verdict_caps_#{unique}"
    runners = :"heal_verdict_runners_#{unique}"
    scheduler = :"heal_verdict_scheduler_#{unique}"
    channel = :"heal_verdict_channel_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Task.Supervisor, name: tasks})

    start_supervised!(
      {ConversationStore, name: store, repo: repo, durable_task_supervisor: tasks}
    )

    start_supervised!({CapabilityRegistry, name: caps})

    for module <- [JobHealRespond, ListJobRuns, GetJobRun] do
      :ok = CapabilityRegistry.register(caps, Builtin.from_tool_module(module))
    end

    start_supervised!({RunnerSupervisor, name: runners})

    start_supervised!(%{
      id: channel,
      start: {Agent, :start_link, [fn -> [] end, [name: channel]]}
    })

    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    scheduler_opts = [
      name: scheduler,
      repo: repo,
      runner_supervisor: runners,
      scheduler_enabled: true,
      timer_enabled: false,
      runner_module: SettlingRunner,
      heal_run_module: HealRun,
      runner_notify: self(),
      cues_running?: fn -> false end,
      clock: fn -> @now end,
      capability_registry: caps,
      adapter: RerunProvider,
      adapter_opts: [test_pid: self(), note: @note],
      delivery_adapter: ScriptedChannel,
      conversation_store: store,
      heal_inbox_opts: [
        jobs_config: [],
        configured_owners: %{"telegram" => Atom.to_string(channel)}
      ]
    ]

    start_supervised!({Scheduler, scheduler_opts}, id: :scheduler)

    %{repo: repo, scheduler: scheduler, scheduler_opts: scheduler_opts, channel: channel}
  end

  # A heal run lives under the runner supervisor, so it outlives a Scheduler
  # that crashes or restarts alone; its rerun must reach the Scheduler running
  # then, by the name it is registered under, never the one that started it.
  test "a heal run that outlives a Scheduler restart starts its rerun through the new one", ctx do
    {_job, heal_id} = open_heal!(ctx)
    TelemetryCapture.attach([@heal_event], heal_id: heal_id)
    stop_supervised!(:scheduler)

    gated =
      Keyword.put(ctx.scheduler_opts, :adapter_opts, test_pid: self(), note: @note, gate: self())

    start_supervised!({Scheduler, gated}, id: :first_scheduler)

    assert :ok = Scheduler.tick(ctx.scheduler, now: @now)
    assert_receive {:diagnosing, loop}, 10_000

    stop_supervised!(:first_scheduler)
    start_supervised!({Scheduler, gated}, id: :second_scheduler)
    send(loop, :go)

    assert_receive {:run_started, %{trigger: "manual"}, _runner}, 10_000

    assert_receive {:telemetry, @heal_event, _m, %{phase: "rerun", rerun_outcome: "started"}},
                   10_000

    assert {:ok, %{state: "watching", rerun_outcome: "started"}} = get_heal(ctx, heal_id)
    assert [message] = sent(ctx)
    assert message =~ "Fermix has asked for it to run again now."
  end

  test "a clean run after the rerun closes the heal healed, and nothing more is sent", ctx do
    {_job, heal_id} = open_heal!(ctx)
    TelemetryCapture.attach([@heal_event], heal_id: heal_id)

    assert :ok = Scheduler.tick(ctx.scheduler, now: @now)
    assert_receive :provider_chat, 10_000
    assert_receive {:run_started, %{trigger: "manual"} = rerun, runner}, 10_000

    assert {:ok, %{state: "watching", rerun_at: %DateTime{}}} = get_heal(ctx, heal_id)
    assert {:ok, %{trigger: "manual"}} = Repo.get_job_run(rerun.id, server: ctx.repo)
    send(runner, {:settle, ok_attrs(1), :ok})

    assert_receive {:telemetry, @heal_event, _m, %{phase: "closed", outcome: "healed"}}, 10_000
    assert {:ok, %{state: "closed", outcome: "healed"}} = get_heal(ctx, heal_id)
    assert {:ok, []} = Repo.job_heals_call(:open_heals, server: ctx.repo)
    assert [_one_message] = sent(ctx)
  end

  test "a failure after the rerun sends one more message, with no model, and closes it", ctx do
    {job, heal_id} = open_heal!(ctx)
    TelemetryCapture.attach([@heal_event], heal_id: heal_id)

    assert :ok = Scheduler.tick(ctx.scheduler, now: @now)
    assert_receive :provider_chat, 10_000
    assert_receive {:run_started, _rerun, runner}, 10_000

    send(runner, {:settle, failed_attrs(1, "crashed"), {:failed, :other}})

    assert_receive {:telemetry, @heal_event, _m, %{phase: "verdict"}}, 10_000

    assert_receive {:telemetry, @heal_event, _m, %{phase: "closed", outcome: "still_failing"}},
                   10_000

    refute_received :provider_chat
    assert [first, second] = sent(ctx)
    assert first =~ @note
    assert second =~ "is still failing after Fermix asked for it to run again"
    refute second =~ @note

    # A third failure of the same kind is kept quiet: nothing opens, nothing goes.
    TelemetryCapture.attach([@heal_event], job_id: job.id)
    assert {:ok, _run} = Scheduler.run_now(ctx.scheduler, job.id, now: DateTime.add(@now, 120))
    assert_receive {:run_started, _third, third_runner}, 10_000
    ref = Process.monitor(third_runner)
    send(third_runner, {:settle, failed_attrs(3, "crashed"), {:failed, :other}})
    assert_receive {:DOWN, ^ref, :process, ^third_runner, _reason}, 10_000

    for phase <- ["opened", "joined", "verdict"] do
      refute_received {:telemetry, @heal_event, _m, %{phase: ^phase}}
    end

    assert {:ok, []} = Repo.job_heals_call(:open_heals, server: ctx.repo)
    assert [_first, _second] = sent(ctx)

    assert {:ok, %{state: "closed", outcome: "still_failing", run_count: 2}} =
             get_heal(ctx, heal_id)
  end

  defp ok_attrs(minutes) do
    at = DateTime.add(@now, minutes * 60, :second)
    %{status: "ok", completed_at: at, updated_at: at, final_response: "Tides fetched."}
  end

  defp failed_attrs(minutes, kind) do
    at = DateTime.add(@now, minutes * 60, :second)
    text = "The run stopped before it finished: the process running it ended."

    %{
      status: "error",
      error: text,
      failure_kind: kind,
      completed_at: at,
      updated_at: at,
      heal_facts: %{failure_text: text, provider: nil}
    }
  end

  defp sent(ctx), do: Agent.get(ctx.channel, & &1)

  # A job of the owner's whose run failed, its heal open; its next run a day
  # on, so no due scan here runs it.
  defp open_heal!(ctx) do
    {:ok, job} =
      Registry.create_job(
        %{
          name: "Harbour tide table #{System.unique_integer([:positive])}",
          schedule: "every 1 hour",
          timezone: "UTC",
          task_prompt: "Fetch this morning's tides.",
          created_by_trust: "operator"
        },
        repo: ctx.repo,
        now: @created,
        scheduler: nil
      )

    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job.id,
      session_id: "cron_#{job.id}_20310304_070000_a1b2c3",
      trigger: "schedule",
      status: "queued",
      claimed_at: @failed_at,
      delivery_status: "none",
      created_at: @failed_at,
      updated_at: @failed_at
    }

    patch = %{
      state: "running",
      next_run_at: DateTime.add(@failed_at, 86_400, :second),
      updated_at: @failed_at
    }

    {:ok, {_job, run}} = Repo.claim_job_now(job.id, patch, run_attrs, server: ctx.repo)

    attrs =
      Map.merge(run, %{
        status: "timeout",
        error: "wall-clock timeout after 600000ms",
        failure_kind: "time_limit",
        completed_at: @failed_at,
        updated_at: @failed_at,
        heal_facts: %{failure_text: "wall-clock timeout after 600000ms", provider: nil}
      })

    {:ok, {_run, _job, %{heal: {:opened, heal_id}}}} =
      Repo.settle_job_run(attrs, {:failed, :other}, server: ctx.repo)

    {job, heal_id}
  end

  defp get_heal(ctx, id), do: Repo.job_heals_call({:get, id}, server: ctx.repo)
end
