defmodule FermixCore.Jobs.RunnerFollowUpTest do
  @moduledoc """
  A watcher's follow-up run end to end in the runner (M60_WATCHER_CODING_RUNS.md
  §4.2, §9): a scheduled run's context and surface, its job's prompt and one
  line naming the watcher, nothing of the item, no `cue_history`, a coding tool
  admitted by `Harness.Authorization`'s scheduled branch, and a trace that
  carries the cue and the trigger.
  """
  # async: false — the runner reads the shared :routing app env.
  use ExUnit.Case, async: false

  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Watchers
  alias FermixCore.Harness.Authorization
  alias FermixCore.Jobs.Runner
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixCore.Tools.CueHistory
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-30 12:00:00.000000Z]
  @runner_exit_ms 10_000
  @prompt "Review the last day's commits on dev and report the findings."
  @item_text "Codex usage limits have been reset for Plus and Pro"

  defmodule ScriptAdapter do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:adapter_chat, messages, Enum.map(capabilities, & &1.name)}
      )

      next_turn(Keyword.fetch!(opts, :script))
    end

    @impl true
    def continue(provider_state, _tool_results, _opts), do: next_turn(provider_state.rest)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp next_turn([turn | rest]) do
      {:ok,
       Map.merge(
         %{
           content: "",
           tool_calls: [],
           usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
           model: "mock"
         },
         Map.put(turn, :provider_state, %{rest: rest})
       )}
    end

    defp next_turn([]), do: {:error, "No mock responses left"}
  end

  defmodule RecordingDelivery do
    @moduledoc false
    def send_message(target, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delivery_send, target, text})
      :ok
    end
  end

  setup do
    ctx = start_repo("runner_follow_up")
    registry = :"runner_follow_up_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(CueHistory))
    :ok = CapabilityRegistry.register(registry, probe("codex_run"))

    output_base_dir =
      Path.join(
        System.tmp_dir!(),
        "fermix-runner-follow-up-#{System.unique_integer([:positive])}"
      )

    routing = Application.get_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :routing, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :routing, routing)
      FermixTestSupport.SafeRm.rm_rf!(output_base_dir)
    end)

    Map.merge(ctx, %{registry: registry, output_base_dir: output_base_dir})
  end

  test "the run is a scheduled run told only its prompt and which watcher set it off", ctx do
    claim = claimed_follow_up!(ctx)
    TelemetryCapture.attach([[:fermix, :job, :run_start]], session_id: claim.run.session_id)

    run!(ctx, claim, [%{tool_calls: [call("c1", "codex_run")]}, %{content: "Reviewed."}])

    assert_receive {:adapter_chat, [_guidance, _job_context, _date, user], offered}
    assert [_now_line, task] = String.split(user.content, "\n\n", parts: 2)
    assert [@prompt, line] = String.split(task, "\n\n")
    assert line =~ ~r/\AWatcher codex-limits set this off at \d{1,2}:\d{2} [AP]M \S+\.\z/
    refute user.content =~ "Codex usage limits"
    assert offered == ["codex_run"]
    refute "cue_history" in offered

    assert_receive {:probe_context, context}
    assert context.trigger == "watcher"
    assert context.conversation_key == {:scheduled_job, claim.job.id, claim.run.id}
    assert context.source_trust == :operator
    refute Map.has_key?(context, :cue)
    assert :ok = Authorization.authorize("codex_run", context)

    assert_receive {:telemetry, [:fermix, :job, :run_start], _measurements, meta}
    assert meta.trigger == "watcher"
    assert meta.trigger_id == claim.trigger.id
    assert meta.cue_id == claim.trigger.cue_id
    assert meta.watcher_id == claim.trigger.watcher_id
  end

  # --- fixtures --------------------------------------------------------------------------

  # A task-less watcher with an ask-first follow-up, its item passed, its card
  # confirmed, and the run claimed as the scheduler claims it.
  defp claimed_follow_up!(ctx) do
    params = %{
      name: "codex-limits",
      filter: "none",
      daily_cap: 5,
      sources: ["x-feed"],
      follow_up: %{prompt: @prompt, allowed_tools: ["codex_run"]}
    }

    opts = [repo: ctx.repo, now: @now, scheduler: nil, cues_config: []]
    {:ok, %{watcher: _watcher}} = Watchers.create(params, context(), opts)

    item = item!(%{item_id: "post-1", data: %{"text" => @item_text}, occurred_at: @now}, @now)

    {:ok, _results} =
      Ingest.accept(%{ref: "x-feed", daily_budget: 0}, [item],
        now: @now,
        repo: ctx.repo,
        wake_scheduler: fn -> :ok end,
        wake_filters: fn -> :ok end
      )

    {:ok, [trigger]} =
      Repo.cues_call(CuesFollowUpSql, {:claim_offers, @now, 10}, server: ctx.repo)

    {:ok, _waiting} =
      FollowUps.decide(trigger.id, :confirm, "companion", opts ++ [wake_scheduler: fn -> :ok end])

    run_attrs = %{
      id: "run_follow_up_#{System.unique_integer([:positive])}",
      job_id: trigger.job_id,
      session_id: "cron_#{trigger.job_id}_20261030_120000_abc123",
      status: "queued",
      claimed_at: @now,
      delivery_status: "none",
      created_at: @now,
      updated_at: @now
    }

    {:ok, {:started, claim}} =
      Repo.claim_follow_up_run(trigger.id, run_attrs, @now, server: ctx.repo)

    claim
  end

  defp run!(ctx, claim, script) do
    parent = self()
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      Runner.start_link(
        repo: ctx.repo,
        job: claim.job,
        run: claim.run,
        notify: parent,
        capability_registry: ctx.registry,
        adapter: ScriptAdapter,
        adapter_opts: [test_pid: parent, script: script],
        output_base_dir: ctx.output_base_dir,
        timeout_ms: nil,
        inactivity_timeout_ms: nil,
        network_readiness_enabled: false,
        delivery_adapter: RecordingDelivery,
        delivery_opts: [test_pid: parent],
        delivery_timeout_ms: nil
      )

    assert_receive {:EXIT, ^pid, :normal}, @runner_exit_ms
  end

  defp context do
    %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1", :root},
      session_id: "telegram:chat-1:root",
      source_trust: :operator,
      memory_agent_id: "main"
    }
  end

  defp probe(name) do
    Capability.new(%{
      name: name,
      description: "records the loop context",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :execute_probe, [self()]},
      policy_class: :read_only
    })
  end

  def execute_probe(_args, context, test_pid) do
    send(test_pid, {:probe_context, context})
    {:ok, %{success: true, output: "probed"}}
  end

  defp call(call_id, name),
    do: %{id: "fc_#{call_id}", call_id: call_id, name: name, arguments: "{}"}
end
