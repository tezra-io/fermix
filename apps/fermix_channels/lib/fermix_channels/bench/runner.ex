defmodule FermixChannels.Bench.Runner do
  @moduledoc """
  Runs deterministic Fermix latency benchmark scenarios.
  """

  alias FermixChannels.Bench.AdapterRunner
  alias FermixChannels.Bench.ReplyChannel
  alias FermixChannels.Dispatcher
  alias FermixChannels.Gateway.Message
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Bench.MockProvider
  alias FermixCore.Bench.Recorder
  alias FermixCore.Bench.Reporter
  alias FermixCore.Bench.Stats
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Telemetry

  @default_output "bench/current.json"
  @sample_reply_timeout_ms 2_000
  @batch_reply_timeout_ms 30_000
  @multi_conversation_count 100

  @events [
    {[:fermix, :channel, :parse], "channel_parse"},
    {[:fermix, :channel, :authorize], "channel_authorize"},
    {[:fermix, :channel, :render], "channel_render"},
    {[:fermix, :channel, :message], "channel_message"},
    {[:fermix, :dispatcher, :normalize], "dispatcher_normalize"},
    {[:fermix, :ingress, :authorize], "ingress_authorize"},
    {[:fermix, :command, :dispatch], "command_dispatch"},
    {[:fermix, :dispatcher, :agent_delivery], "dispatcher_agent_delivery"},
    {[:fermix, :agent, :mailbox], "agent_mailbox"},
    {[:fermix, :agent, :prompt_context], "prompt_context"},
    {[:fermix, :agent, :history], "history_fetch"},
    {[:fermix, :agent, :loop_runtime], "main_agent_overhead"},
    {[:fermix, :capabilities, :select], "capabilities_select"},
    {[:fermix, :provider, :tool_schema], "provider_tool_schema"},
    {[:fermix, :provider, :call], "provider_call"},
    {[:fermix, :agent, :iteration], "agent_iteration"},
    {[:fermix, :tool, :exec], "tool_exec"},
    {[:fermix, :memory, :message], "memory_message"},
    {[:fermix, :agent, :reply], "agent_reply"},
    {[:fermix, :agent, :message], "agent_message"},
    {[:fermix, :channel, :reply], "channel_reply"},
    {[:fermix, :idempotency, :check], "idempotency_check"},
    {[:fermix, :idempotency, :outbound_media_claim], "outbound_media_claim"}
  ]

  @scenario_specs %{
    "shared_text_minimal" => %{script: :text, caps: 5, samples: 1000},
    "shared_text_with_tools" => %{script: :tool_once, caps: 30, samples: 1000},
    "shared_text_long_history" => %{script: :text, caps: 30, history: 100, samples: 500},
    "shared_text_max_iter" => %{script: :repeat_tool, caps: 5, samples: 200},
    "shared_cold_start" => %{script: :text, caps: 5, samples: 50, cold?: true},
    "shared_single_flight_contention" => %{
      script: :text,
      caps: 5,
      delay_ms: 10,
      samples: 500,
      contention?: true
    },
    "shared_multi_conv_throughput" => %{script: :text, caps: 5, samples: 1000, multi?: true}
  }

  @spec list_scenarios() :: [String.t()]
  def list_scenarios do
    shared = Map.keys(@scenario_specs)
    adapter = AdapterRunner.list_scenarios()
    Enum.sort(shared ++ adapter)
  end

  @spec stage_order() :: [String.t()]
  def stage_order, do: Enum.map(@events, fn {_event, stage} -> stage end)

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    with {:ok, scenario_names} <- scenario_names(opts),
         {:ok, scenario_reports} <- run_scenarios(scenario_names, opts) do
      report = build_report(scenario_reports, opts)
      maybe_write_report(report, Keyword.get(opts, :output, @default_output))
    end
  end

  defp scenario_names(opts) do
    names = Keyword.get(opts, :scenarios, default_scenarios())
    known = MapSet.new(list_scenarios())
    unknown = Enum.reject(names, &MapSet.member?(known, &1))

    case unknown do
      [] -> {:ok, names}
      _list -> {:error, {:unknown_scenarios, unknown}}
    end
  end

  defp default_scenarios, do: Map.keys(@scenario_specs)

  defp run_scenarios(names, opts) do
    reports =
      Enum.map(names, fn name ->
        {name, run_named_scenario!(name, opts)}
      end)

    {:ok, Map.new(reports)}
  end

  defp run_named_scenario!(name, opts) do
    if Map.has_key?(@scenario_specs, name) do
      run_scenario!(name, Map.fetch!(@scenario_specs, name), opts)
    else
      AdapterRunner.run!(name, opts, @events)
    end
  end

  defp run_scenario!(name, spec, opts) do
    samples = sample_count(spec, opts)
    warmup = Keyword.get(opts, :warmup, 20)
    before_snapshot = runtime_snapshot()

    {result, wall_time_us} =
      Telemetry.timed_us(fn ->
        if Map.get(spec, :cold?, false) do
          run_cold_samples(name, spec, samples)
        else
          run_warm_scenario(name, spec, warmup, samples)
        end
      end)

    %{
      messages_dispatched: samples,
      messages_processed: result.processed,
      messages_superseded: max(samples - result.processed, 0),
      wall_time_us: wall_time_us,
      throughput_messages_per_second: throughput(result.processed, wall_time_us),
      setup: result.setup,
      stages: summarize_samples(result.raw_samples),
      memory: memory_delta(before_snapshot, runtime_snapshot())
    }
  end

  defp run_warm_scenario(name, spec, warmup, samples) do
    env = start_env!(name, spec)

    try do
      setup =
        env
        |> preseed_history(spec, warmup, samples)
        |> Map.put(:environments_started, 1)

      Enum.each(1..warmup//1, &run_sample!(env, spec, &1, :warmup))
      {raw_samples, processed} = collect_recorded_samples(env, spec, warmup + 1, samples)
      %{raw_samples: raw_samples, processed: processed, setup: setup}
    after
      stop_env(env)
    end
  end

  defp collect_recorded_samples(env, spec, first_index, samples) do
    {:ok, recorder} = Recorder.start(events: @events)

    try do
      processed =
        cond do
          Map.get(spec, :contention?, false) -> run_contention_samples!(env, spec, first_index, samples)
          Map.get(spec, :multi?, false) -> run_parallel_samples!(env, spec, first_index, samples)
          true -> run_sequential_samples!(env, spec, first_index, samples)
        end

      {Recorder.samples(recorder), processed}
    after
      Recorder.stop(recorder)
    end
  end

  defp run_sequential_samples!(env, spec, first_index, samples) do
    first_index
    |> sample_range(samples)
    |> Enum.reduce(0, fn index, count ->
      run_sample!(env, spec, index, :sample)
      count + 1
    end)
  end

  defp run_parallel_samples!(env, spec, first_index, samples) do
    first_index
    |> sample_range(samples)
    |> Enum.chunk_every(@multi_conversation_count)
    |> Enum.reduce(0, fn indexes, count ->
      Enum.each(indexes, &dispatch_sample!(env, spec, &1, :sample))
      wait_until_idle_or_deadline(env.agent, @batch_reply_timeout_ms)
      count + drain_replies(0)
    end)
  end

  defp run_contention_samples!(env, spec, first_index, samples) do
    first_index
    |> sample_range(samples)
    |> Enum.each(fn index -> dispatch_sample!(env, spec, index, :sample) end)

    wait_until_idle!(env.agent)
    drain_replies(0)
  end

  defp run_cold_samples(name, spec, samples) do
    {:ok, recorder} = Recorder.start(events: @events)

    try do
      processed =
        Enum.reduce(1..samples//1, 0, fn index, count ->
          env = start_env!("#{name}_#{index}", spec)

          try do
            run_sample!(env, spec, index, :sample)
            count + 1
          after
            stop_env(env)
          end
        end)

      setup = %{
        environments_started: samples,
        history_conversations_seeded: 0,
        history_messages_seeded: 0
      }

      %{raw_samples: Recorder.samples(recorder), processed: processed, setup: setup}
    after
      Recorder.stop(recorder)
    end
  end

  defp run_sample!(env, spec, index, label) do
    ref = dispatch_sample!(env, spec, index, label)
    await_reply!(ref)
  end

  defp dispatch_sample!(env, spec, index, label) do
    ref = make_ref()
    parent = self()

    message = bench_message(spec, index, label)

    reply_fn = fn part ->
      send(parent, {:bench_reply, ref, part})
      :ok
    end

    :ok =
      Dispatcher.dispatch([message],
        channel: ReplyChannel,
        agent: MainAgent,
        agent_server: env.agent,
        conversation_store: env.conversation_store,
        reply_fn: reply_fn
      )

    ref
  end

  defp bench_message(spec, index, label) do
    chat_id = chat_id(spec, index, label)

    %Message{
      id: "bench-#{label}-#{index}",
      content: content_for(spec, index),
      sender: "bench",
      channel: "cli",
      chat_id: chat_id,
      reply_target: chat_id,
      metadata: %{}
    }
  end

  defp content_for(%{content_bytes: bytes}, index) when is_integer(bytes) and bytes > 0 do
    String.duplicate("x", bytes) <> "-#{index}"
  end

  defp content_for(_spec, index), do: "bench message #{index}"

  defp chat_id(%{contention?: true}, _index, _label), do: "shared-contention"
  defp chat_id(%{multi?: true}, index, _label), do: "multi-#{rem(index, @multi_conversation_count)}"
  defp chat_id(_spec, index, label), do: "#{label}-#{index}"

  defp await_reply!(ref) do
    receive do
      {:bench_reply, ^ref, _part} -> :ok
    after
      @sample_reply_timeout_ms -> raise "benchmark reply timed out"
    end
  end

  defp wait_until_idle_or_deadline(agent, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_idle_or_deadline_loop(agent, deadline)
  end

  defp wait_until_idle_or_deadline_loop(agent, deadline) do
    status = MainAgent.status(agent)

    cond do
      status.active_requests == 0 and status.pending_requests == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :deadline

      true ->
        Process.sleep(5)
        wait_until_idle_or_deadline_loop(agent, deadline)
    end
  end

  defp wait_until_idle!(agent) do
    deadline = System.monotonic_time(:millisecond) + @batch_reply_timeout_ms
    wait_until_idle!(agent, deadline)
  end

  defp wait_until_idle!(agent, deadline) do
    status = MainAgent.status(agent)

    cond do
      status.active_requests == 0 and status.pending_requests == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "benchmark agent did not become idle"

      true ->
        Process.sleep(5)
        wait_until_idle!(agent, deadline)
    end
  end

  defp drain_replies(count) do
    receive do
      {:bench_reply, _ref, _part} -> drain_replies(count + 1)
    after
      0 -> count
    end
  end

  defp sample_range(_first_index, 0), do: []
  defp sample_range(first_index, samples), do: first_index..(first_index + samples - 1)//1

  defp start_env!(name, spec) do
    unique = System.unique_integer([:positive])
    task_supervisor = :"#{name}_task_supervisor_#{unique}"
    conversation_store = :"#{name}_conversation_store_#{unique}"
    capability_registry = :"#{name}_capability_registry_#{unique}"
    agent = :"#{name}_main_agent_#{unique}"

    {:ok, task_pid} = Task.Supervisor.start_link(name: task_supervisor)
    {:ok, store_pid} = ConversationStore.start_link(name: conversation_store, repo: nil)
    {:ok, registry_pid} = CapabilityRegistry.start_link(name: capability_registry)
    register_capabilities!(capability_registry, Map.fetch!(spec, :caps))

    {:ok, agent_pid} =
      MainAgent.start_link(
        name: agent,
        provider: MockProvider,
        capability_registry: capability_registry,
        conversation_store: conversation_store,
        task_supervisor: task_supervisor,
        extraction_enabled: false,
        memory_repo: nil,
        adapter_opts: adapter_opts(spec)
      )

    %{
      task_supervisor: task_supervisor,
      task_pid: task_pid,
      conversation_store: conversation_store,
      store_pid: store_pid,
      capability_registry: capability_registry,
      registry_pid: registry_pid,
      agent: agent,
      agent_pid: agent_pid
    }
  end

  defp adapter_opts(spec) do
    [
      bench_script: Map.fetch!(spec, :script),
      bench_delay_ms: Map.get(spec, :delay_ms, 0),
      model: "bench-mock"
    ]
  end

  defp register_capabilities!(registry, count) do
    1..count//1
    |> Enum.map(&capability/1)
    |> Enum.each(fn capability -> :ok = CapabilityRegistry.register(registry, capability) end)
  end

  defp capability(1), do: capability("bench_echo")
  defp capability(index) when is_integer(index), do: capability("bench_cap_#{index}")

  defp capability(name) do
    Capability.new(%{
      name: name,
      description: "Benchmark capability #{name}",
      parameters: %{type: "object", properties: %{"text" => %{type: "string"}}},
      kind: :builtin,
      executor: {FermixCore.Bench.Tools, :echo, []},
      policy_class: :read_only,
      metadata: %{category: :bench}
    })
  end

  defp preseed_history(_env, %{history: nil}, _warmup, _samples), do: empty_setup()
  defp preseed_history(_env, spec, _warmup, _samples) when not is_map_key(spec, :history), do: empty_setup()

  defp preseed_history(env, spec, warmup, samples) do
    history_count = Map.fetch!(spec, :history)
    keys = history_keys(spec, warmup, samples)

    Enum.each(keys, fn key ->
      preseed_conversation_history(env.conversation_store, key, history_count)
    end)

    %{
      history_conversations_seeded: length(keys),
      history_messages_seeded: length(keys) * history_count
    }
  end

  defp empty_setup do
    %{history_conversations_seeded: 0, history_messages_seeded: 0}
  end

  defp history_keys(spec, warmup, samples) do
    warmup_keys =
      1
      |> sample_range(warmup)
      |> Enum.map(fn index -> {"cli", chat_id(spec, index, :warmup), :root} end)

    sample_keys =
      (warmup + 1)
      |> sample_range(samples)
      |> Enum.map(fn index -> {"cli", chat_id(spec, index, :sample), :root} end)

    warmup_keys ++ sample_keys
  end

  defp preseed_conversation_history(store, key, history_count) do
    Enum.each(1..history_count//1, fn history_index ->
      role = if rem(history_index, 2) == 0, do: "assistant", else: "user"

      :ok =
        ConversationStore.add_message(key, role, "history #{history_index}",
          server: store
        )
    end)
  end

  defp stop_env(env) do
    Enum.each([env.agent_pid, env.registry_pid, env.store_pid, env.task_pid], &stop_pid/1)
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp sample_count(spec, opts) do
    case Keyword.get(opts, :samples) do
      nil -> Map.fetch!(spec, :samples)
      samples when is_integer(samples) and samples > 0 -> samples
    end
  end

  defp summarize_samples(samples_by_stage) do
    samples_by_stage
    |> Enum.map(fn {stage, samples} -> {stage, Stats.summarize(samples)} end)
    |> Map.new()
  end

  defp build_report(scenarios, opts) do
    %{
      version: 1,
      git_sha: git_sha(),
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      elixir: System.version(),
      otp: System.otp_release(),
      config: %{
        samples: Keyword.get(opts, :samples),
        warmup: Keyword.get(opts, :warmup, 20),
        provider_mode: "mock",
        trace_writes_enabled: false,
        output: Keyword.get(opts, :output, @default_output)
      },
      scenarios: scenarios
    }
  end

  defp maybe_write_report(report, nil), do: {:ok, report}

  defp maybe_write_report(report, output) when is_binary(output) do
    with :ok <- Reporter.write_json(report, output) do
      {:ok, report}
    end
  end

  defp throughput(_processed, 0), do: 0.0

  defp throughput(processed, wall_time_us) do
    Float.round(processed * 1_000_000 / wall_time_us, 2)
  end

  defp runtime_snapshot do
    %{
      beam_total_bytes: :erlang.memory(:total),
      ets_bytes: ets_bytes(),
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp memory_delta(before, after_snapshot) do
    %{
      beam_total_before_bytes: before.beam_total_bytes,
      beam_total_after_bytes: after_snapshot.beam_total_bytes,
      ets_growth_bytes: after_snapshot.ets_bytes - before.ets_bytes,
      process_count_before: before.process_count,
      process_count_after: after_snapshot.process_count
    }
  end

  defp ets_bytes do
    word_size = :erlang.system_info(:wordsize)

    :ets.all()
    |> Enum.reduce(0, fn table, total ->
      total + (:ets.info(table, :memory) || 0) * word_size
    end)
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unknown"
    end
  end
end
