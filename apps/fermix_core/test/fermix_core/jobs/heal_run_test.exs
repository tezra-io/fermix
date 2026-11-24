defmodule FermixCore.Jobs.HealRunTest do
  # M106 §5.4: a heal run tells the owner once, in their inbox, with a message
  # built by code. It resolves the inbox once, sends once under the heal's own
  # key, marks the delivery before it writes history, and backs off on a failed
  # send by the harness ladder. Every time is injected; nothing waits on time.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Jobs.HealRun
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @created ~U[2026-11-20 06:00:00.000000Z]
  @failed_at ~U[2026-11-20 07:10:00.000000Z]
  @now ~U[2026-11-20 07:30:00.000000Z]
  @lease_s 300
  @heal_event [:fermix, :job, :heal]

  # The channel seam: the inbox's destination IS a named Agent, so the one
  # send is observed without any test-only option.
  defmodule ScriptedChannel do
    @moduledoc false

    def send_message(destination, text, opts) do
      destination
      |> String.to_existing_atom()
      |> Agent.get_and_update(fn state ->
        {result, rest} = next(state.script)
        {result, %{state | script: rest, calls: state.calls ++ [%{text: text, opts: opts}]}}
      end)
    end

    defp next([]), do: :ok
    defp next([head | tail]), do: {head, tail}
  end

  # A store that takes the history write and never answers it, so a test can
  # end the heal run between its delivered mark and its history row.
  defmodule HeldStore do
    @moduledoc false

    use GenServer

    def start_link({name, test_pid}), do: GenServer.start_link(__MODULE__, test_pid, name: name)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:add_message, _key, _role, _content, _opts} = request, from, test_pid) do
      send(test_pid, {:history_write, from, request})
      {:noreply, test_pid}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-heal-run")
    db_path = Path.join(dir, "memory.db")
    repo = :"job_heal_run_repo_#{unique}"
    store = :"job_heal_run_store_#{unique}"
    tasks = :"job_heal_run_tasks_#{unique}"
    channel = :"job_heal_run_channel_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({Task.Supervisor, name: tasks})

    start_supervised!(
      {ConversationStore, name: store, repo: repo, durable_task_supervisor: tasks}
    )

    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    %{repo: repo, store: store, tasks: tasks, channel: channel}
  end

  describe "the one send" do
    test "resolves the inbox, sends once with the heal's key and origin, then writes history",
         ctx do
      start_channel(ctx, [:ok])
      {job, heal} = claimed_heal!(ctx)
      TelemetryCapture.attach([@heal_event], heal_id: heal.id)

      run!(ctx, heal)

      assert [%{text: text, opts: opts}] = calls(ctx)
      assert text =~ ~s(Job "#{job.name}")
      assert Keyword.fetch!(opts, :proactive_key) == "job_heal:#{heal.id}"
      assert Keyword.fetch!(opts, :link_previews) == false
      assert Keyword.fetch!(opts, :origin) == %{"kind" => "job", "name" => job.name}

      assert {:ok, stored} = get_heal(ctx, heal.id)

      assert %{
               state: "waiting",
               delivery_status: "delivered",
               message: ^text,
               inbox_platform: "telegram",
               inbox_destination: destination,
               inbox_thread_scope: "root",
               lease_token: nil
             } = stored

      assert destination == Atom.to_string(ctx.channel)
      assert DateTime.compare(stored.delivered_at, @now) == :eq

      key = {"telegram", destination, :root}

      assert [%{role: "assistant", content: ^text}] =
               ConversationStore.get_history(key, server: ctx.store)

      :ok = await_durable_writes(ctx)

      {:ok, [row]} =
        Repo.get_messages(
          %{agent_id: "main", channel: "telegram", chat_id: destination, thread_scope: :root},
          server: ctx.repo
        )

      assert row.kind == "chat_message"
      assert row.metadata["job_heal"] == heal.id
      assert_received {:telemetry, @heal_event, _measurements, %{phase: "delivered", heal_id: _}}
    end

    test "an inbox the row holds is used as it is, never resolved again", ctx do
      start_channel(ctx, [{:error, {:transport, :timeout}}, :ok])
      {_job, heal} = claimed_heal!(ctx)
      run!(ctx, heal)

      assert {:ok, %{inbox_destination: first, message: text, state: "open"}} =
               get_heal(ctx, heal.id)

      # The owner's configured inbox moved since; the heal keeps the one it chose.
      {:ok, reclaimed} = claim(ctx, DateTime.add(@now, 30, :second))
      run!(ctx, reclaimed, inbox_opts: owners_on("signal", "elsewhere"))

      assert [%{text: ^text}, %{text: ^text}] = calls(ctx)
      assert {:ok, %{inbox_destination: ^first, state: "waiting"}} = get_heal(ctx, heal.id)
    end

    test "an inbox not keyed as a turn is gets the message and no history row", ctx do
      start_channel(ctx, [:ok])
      {_job, heal} = claimed_heal!(ctx)
      destination = Atom.to_string(ctx.channel)

      inbox_opts = [
        jobs_config: [
          default_delivery_target: %{"channel" => "slack", "channel_id" => destination}
        ],
        configured_owners: %{"slack" => destination}
      ]

      run!(ctx, heal, inbox_opts: inbox_opts)

      assert [%{text: _text}] = calls(ctx)
      assert {:ok, %{inbox_platform: "slack", state: "waiting"}} = get_heal(ctx, heal.id)
      assert [] = ConversationStore.get_history({"slack", destination, :root}, server: ctx.store)
    end

    test "with no inbox the delivery is a dead letter, logged, and nothing is sent", ctx do
      start_channel(ctx, [])
      {_job, heal} = claimed_heal!(ctx)

      {_result, log} =
        with_log(fn -> run!(ctx, heal, inbox_opts: [jobs_config: [], configured_owners: %{}]) end)

      assert log =~ heal.id
      assert calls(ctx) == []

      assert {:ok,
              %{delivery_status: "dead_letter", state: "waiting", last_delivery_error: error}} =
               get_heal(ctx, heal.id)

      assert error =~ "no_delivery_target"
    end

    # A run that ends between its mark and its history leaves a delivered
    # heal: the next pass finds nothing to send.
    test "delivered is marked before the history row, so a run ended between them never resends",
         ctx do
      start_channel(ctx, [:ok])
      held = :"held_store_#{System.unique_integer([:positive])}"
      start_supervised!({HeldStore, {held, self()}})
      {_job, heal} = claimed_heal!(ctx)

      pid = start_heal_run!(ctx, heal, conversation_store: held)
      ref = Process.monitor(pid)

      assert_receive {:history_write, _from, {:add_message, _key, "assistant", _text, _opts}}
      assert {:ok, %{delivery_status: "delivered", state: "waiting"}} = get_heal(ctx, heal.id)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert {:ok, nil} = claim(ctx, DateTime.add(@now, @lease_s * 2, :second))
      assert length(calls(ctx)) == 1
    end
  end

  describe "a failed send" do
    test "backs off by the ladder and resends the same text", ctx do
      start_channel(ctx, [{:error, {:transport, :timeout}}, {:error, {:http_status, 503}}, :ok])
      {_job, heal} = claimed_heal!(ctx)

      run!(ctx, heal)

      assert {:ok,
              %{state: "open", delivery_attempts: 1, next_delivery_at: next, message: text} =
                after_one} =
               get_heal(ctx, heal.id)

      assert DateTime.compare(next, DateTime.add(@now, 30, :second)) == :eq
      assert after_one.last_delivery_error =~ "timeout"
      assert after_one.delivery_status == "pending"

      assert {:ok, nil} = claim(ctx, DateTime.add(@now, 29, :second))
      second_at = DateTime.add(@now, 30, :second)
      {:ok, second} = claim(ctx, second_at)
      run!(ctx, second, clock: fn -> second_at end)

      assert {:ok, %{delivery_attempts: 2, next_delivery_at: next}} = get_heal(ctx, heal.id)
      assert DateTime.compare(next, DateTime.add(second_at, 60, :second)) == :eq

      third_at = DateTime.add(second_at, 60, :second)
      {:ok, third} = claim(ctx, third_at)
      run!(ctx, third, clock: fn -> third_at end)

      assert [%{text: ^text}, %{text: ^text}, %{text: ^text}] = calls(ctx)
      assert {:ok, %{state: "waiting", delivery_status: "delivered"}} = get_heal(ctx, heal.id)
    end

    test "a rate limit's wait is the floor", ctx do
      start_channel(ctx, [{:error, {:rate_limited, 90_000}}])
      {_job, heal} = claimed_heal!(ctx)
      run!(ctx, heal)

      assert {:ok, %{next_delivery_at: next, state: "open"}} = get_heal(ctx, heal.id)
      assert DateTime.compare(next, DateTime.add(@now, 90, :second)) == :eq
    end

    test "a dead letter on an error no wait clears, at the attempt cap and after a day", ctx do
      # The claimed row is what the run reads: a heal at its 19th attempt, or
      # one opened a day ago, as the claim would hand it over.
      for {script, as_claimed} <- [
            {[{:error, {:permanent, :invalid_destination}}], & &1},
            {[{:error, {:transport, :timeout}}], &%{&1 | delivery_attempts: 19}},
            {[{:error, {:transport, :timeout}}],
             &%{&1 | opened_at: DateTime.add(@now, -86_400, :second)}}
          ] do
        channel = :"job_heal_run_channel_#{System.unique_integer([:positive])}"
        ctx = %{ctx | channel: channel}
        start_channel(ctx, script)
        {_job, heal} = claimed_heal!(ctx)

        TelemetryCapture.attach([@heal_event], heal_id: heal.id)
        {_result, _log} = with_log(fn -> run!(ctx, as_claimed.(heal)) end)

        assert {:ok, %{delivery_status: "dead_letter", state: "waiting"}} = get_heal(ctx, heal.id)

        assert_received {:telemetry, @heal_event, _measurements,
                         %{phase: "delivery_failed", dead_letter: true}}
      end
    end
  end

  defp start_channel(ctx, script) do
    start_supervised!(%{
      id: {:channel, ctx.channel},
      start: {Agent, :start_link, [fn -> %{script: script, calls: []} end, [name: ctx.channel]]},
      restart: :temporary
    })
  end

  defp calls(ctx), do: Agent.get(ctx.channel, & &1.calls)

  defp owners_on(platform, destination),
    do: [jobs_config: [], configured_owners: %{platform => destination}]

  defp run!(ctx, heal, overrides \\ []) do
    pid = start_heal_run!(ctx, heal, overrides)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    :ok
  end

  defp start_heal_run!(ctx, heal, overrides) do
    opts =
      Keyword.merge(
        [
          heal: heal,
          repo: ctx.repo,
          conversation_store: ctx.store,
          delivery_opts: [adapter: ScriptedChannel],
          inbox_opts: owners_on("telegram", Atom.to_string(ctx.channel)),
          clock: fn -> @now end,
          clock_opts: [personalization: [timezone: "Europe/Lisbon"]]
        ],
        overrides
      )

    start_supervised!({HealRun, opts}, id: {:heal_run, System.unique_integer([:positive])})
  end

  # A job of the owner's that failed once, its heal open and claimed by the
  # pass that starts this run.
  defp claimed_heal!(ctx) do
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
      session_id: "cron_#{job.id}_1",
      trigger: "manual",
      status: "queued",
      claimed_at: @failed_at,
      delivery_status: "none",
      created_at: @failed_at,
      updated_at: @failed_at
    }

    patch = %{state: "running", updated_at: @failed_at}
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

    {:ok, {_run, _job, %{heal: {:opened, _id}}}} =
      Repo.settle_job_run(attrs, {:failed, :other}, server: ctx.repo)

    {:ok, heal} = claim(ctx, @now)
    {job, heal}
  end

  defp claim(ctx, now),
    do: Repo.job_heals_call({:claim, now, DateTime.add(now, @lease_s, :second)}, server: ctx.repo)

  defp get_heal(ctx, id), do: Repo.job_heals_call({:get, id}, server: ctx.repo)

  defp await_durable_writes(ctx) do
    for pid <- Task.Supervisor.children(ctx.tasks) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
    end

    :ok
  end
end
