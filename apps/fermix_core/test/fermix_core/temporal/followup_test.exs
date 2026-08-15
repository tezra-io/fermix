defmodule FermixCore.Temporal.FollowupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.Followup
  alias FermixCore.Temporal.FollowupSupervisor
  alias FermixCore.Temporal.Planner

  @tz "America/New_York"
  @created_at ~U[2026-09-01 12:00:00Z]
  @delivered_text "Today: Sarah's birthday — September 14."
  @lifecycle_event [:fermix, :reminder, :lifecycle]

  # The channel seam: the reminder's destination IS a named Agent, so the run's
  # one message can be observed without any test-only send option.
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

    defp next([]), do: {:ok, []}
    defp next([head | tail]), do: {head, tail}
  end

  # The provider seam (the jobs-runner precedent): one scripted turn, no
  # network, and the composed prompt echoed back so the instructions can be
  # asserted at the boundary the model actually sees.
  defmodule ScriptedProvider do
    @moduledoc false

    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_chat, messages})
      maybe_sleep(Keyword.get(opts, :sleep_ms, 0))

      {:ok,
       %{
         content: Keyword.fetch!(opts, :reply),
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "mock",
         provider_state: %{}
       }}
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

    defp maybe_sleep(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
    defp maybe_sleep(_ms), do: :ok
  end

  defmodule FailingProvider do
    @moduledoc false

    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts), do: {:error, :provider_down}

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :provider_down}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-temporal-followup-#{unique}.db")
    repo = :"temporal_followup_repo_#{unique}"
    registry = :"temporal_followup_registry_#{unique}"
    supervisor = :"temporal_followup_sup_#{unique}"
    channel = :"temporal_followup_channel_#{unique}"
    handler = "temporal-followup-#{unique}"
    test_pid = self()

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({CapabilityRegistry, name: registry})
    start_supervised!({FollowupSupervisor, name: supervisor})

    :telemetry.attach_many(
      handler,
      [
        [:fermix, :reminder, :followup_start],
        [:fermix, :reminder, :followup_complete],
        [:fermix, :reminder, :followup_error],
        @lifecycle_event
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:followup_telemetry, List.last(event), measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{
      repo: repo,
      capability_registry: registry,
      supervisor: supervisor,
      channel: channel,
      unique: unique
    }
  end

  defp start_channel(ctx, script) do
    start_supervised!(%{
      id: {:channel, ctx.channel},
      start: {Agent, :start_link, [fn -> %{script: script, calls: []} end, [name: ctx.channel]]},
      restart: :temporary
    })

    ctx.channel
  end

  defp calls(ctx), do: Agent.get(ctx.channel, & &1.calls)

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp birthday_spec(followup) do
    %{
      title: "Sarah's birthday",
      description: nil,
      kind: "birthday",
      time_kind: "date",
      local_date: nil,
      local_time: nil,
      timezone: @tz,
      occurrence_at: nil,
      recurrence_kind: "yearly",
      recurrence_month: 9,
      recurrence_day: 14,
      leap_day_policy: nil,
      reminder_plan: [%{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]}],
      followup: followup
    }
  end

  defp create!(ctx, followup \\ true, target \\ %{}) do
    spec = birthday_spec(followup)
    {:ok, plan} = Planner.materialize(spec, @created_at)
    occurrences = Enum.map(plan.occurrences, &Map.put(&1, :id, uid("rem")))

    attrs =
      spec
      |> Map.put(:reminder_plan, Defaults.encode_plan(spec.reminder_plan))
      |> Map.merge(%{
        id: uid("evt"),
        agent_id: "main",
        owner_id: "default",
        dedupe_key: uid("dedupe"),
        delivery_platform: "telegram",
        delivery_destination: Atom.to_string(ctx.channel),
        delivery_thread_scope: "root",
        source_channel: "telegram",
        source_chat_id: "12345",
        source_thread_scope: "root",
        source_session_id: "sess-1",
        created_by_trust: "operator",
        created_by_origin: "interactive"
      })
      |> Map.merge(target)

    {:ok, {:created, event, [first | _rest]}} =
      Repo.create_temporal_event(attrs, %{plan | occurrences: occurrences}, @created_at,
        server: ctx.repo
      )

    {:ok, row} = Repo.get_temporal_reminder(first.id, server: ctx.repo)
    {event, row}
  end

  defp args(ctx, row, overrides) do
    Map.merge(
      %{
        reminder: row,
        delivered_text: @delivered_text,
        repo: ctx.repo,
        delivery_opts: [adapter: ScriptedChannel],
        capability_registry: ctx.capability_registry,
        adapter: ScriptedProvider,
        adapter_opts: [test_pid: self(), reply: "Want me to help you pick something out?"]
      },
      overrides
    )
  end

  # The closing bookend is the run's completion signal. The monitor is a
  # secondary check: a run this fast can finish before `Process.monitor/1`
  # installs, and `:noproc` there is not a failure.
  defp run!(ctx, row, overrides \\ %{}) do
    {:ok, pid} = FollowupSupervisor.start_followup(ctx.supervisor, args(ctx, row, overrides))
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    assert reason in [:normal, :noproc], "the follow-up exited #{inspect(reason)}"
    pid
  end

  defp await_close do
    assert_receive {:followup_telemetry, phase, measurements, metadata}
                   when phase in [:followup_complete, :followup_error],
                   5_000

    {phase, measurements, metadata}
  end

  describe "the output contract" do
    test "an exact [SILENT] declines: nothing is sent", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx)

      run!(ctx, row, %{adapter_opts: [test_pid: self(), reply: "  [SILENT]\n"]})

      assert {:followup_complete, _measurements, metadata} = await_close()
      assert metadata.outcome == "declined"
      assert calls(ctx) == []
    end

    test "an empty final text is an anomaly, not silence", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx)

      {_pid, log} =
        with_log(fn -> run!(ctx, row, %{adapter_opts: [test_pid: self(), reply: "   \n"]}) end)

      assert {:followup_complete, _measurements, metadata} = await_close()
      assert metadata.outcome == "empty"
      assert calls(ctx) == []
      assert log =~ "empty"
    end

    test "a non-empty reply is sent exactly once with the row's own thread options", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx, true, %{delivery_thread_scope: "42"})

      run!(ctx, row)

      assert {:followup_complete, measurements, metadata} = await_close()
      assert metadata.outcome == "sent"
      assert is_integer(measurements.duration_ms)

      assert [%{text: text, opts: opts}] = calls(ctx)
      assert text == "Want me to help you pick something out?"
      assert opts == [message_thread_id: 42]
    end

    test "an over-long reply is clamped to the one-message bound at a grapheme boundary", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx)
      long = String.duplicate("é", 2_000)

      run!(ctx, row, %{adapter_opts: [test_pid: self(), reply: long]})

      assert {:followup_complete, _measurements, metadata} = await_close()
      assert metadata.outcome == "sent"

      assert [%{text: text}] = calls(ctx)
      assert byte_size(text) <= 1_800
      assert String.valid?(text)
    end

    test "a send failure settles delivery_failed with no second attempt", ctx do
      start_channel(ctx, [{:error, {:permanent, :authentication}}])
      {_event, row} = create!(ctx)

      {_pid, _log} = with_log(fn -> run!(ctx, row) end)

      assert {:followup_complete, _measurements, metadata} = await_close()
      assert metadata.outcome == "delivery_failed"
      assert length(calls(ctx)) == 1
    end
  end

  describe "the run" do
    test "the composed instructions quote the delivered reminder verbatim", ctx do
      start_channel(ctx, [:ok])
      {event, row} = create!(ctx)

      run!(ctx, row)

      assert_receive {:provider_chat, messages}, 5_000
      prompt = Enum.map_join(messages, "\n", & &1.content)

      assert prompt =~ @delivered_text
      assert prompt =~ event.title
      assert prompt =~ "[SILENT]"
    end

    test "a provider failure closes the run as an error rather than a bare crash", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx)

      {_pid, _log} = with_log(fn -> run!(ctx, row, %{adapter: FailingProvider}) end)

      assert {:followup_error, _measurements, metadata} = await_close()
      assert metadata.status == "error"
      assert calls(ctx) == []
    end

    test "a run past its wall clock is killed and closed as a timeout", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx)

      {:ok, pid} =
        FollowupSupervisor.start_followup(
          ctx.supervisor,
          args(ctx, row, %{
            timeout_ms: 50,
            adapter_opts: [test_pid: self(), reply: "too late", sleep_ms: 2_000]
          })
        )

      ref = Process.monitor(pid)

      {_result, _log} =
        with_log(fn ->
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
        end)

      assert {:followup_error, _measurements, metadata} = await_close()
      assert metadata.status == "timeout"

      assert_received {:followup_telemetry, :followup_start, _start_measurements, start_metadata}
      assert start_metadata.max_duration_ms == 50
      assert calls(ctx) == []
    end
  end

  describe "the pre-run event check" do
    test "an event cancelled since delivery skips before any model call", ctx do
      start_channel(ctx, [:ok])
      {event, row} = create!(ctx)
      {:ok, _cancelled} = Repo.cancel_temporal_event(event.id, @created_at, server: ctx.repo)

      {_pid, _log} = with_log(fn -> run!(ctx, row) end)

      reminder_id = row.id

      assert_receive {:followup_telemetry, :lifecycle, _measurements,
                      %{phase: :followup_skipped, reminder_id: ^reminder_id} = metadata},
                     5_000

      assert metadata.error_class == "event_inactive"
      refute_received {:provider_chat, _messages}
      refute_received {:followup_telemetry, :followup_start, _measurements, _metadata}
      assert calls(ctx) == []
    end

    test "an unflagged event skips with its own reason", ctx do
      start_channel(ctx, [:ok])
      {_event, row} = create!(ctx, false)

      {_pid, _log} = with_log(fn -> run!(ctx, row) end)

      reminder_id = row.id

      assert_receive {:followup_telemetry, :lifecycle, _measurements,
                      %{phase: :followup_skipped, reminder_id: ^reminder_id} = metadata},
                     5_000

      assert metadata.error_class == "event_unflagged"
      refute_received {:provider_chat, _messages}
      assert calls(ctx) == []
    end
  end

  describe "the loop context" do
    test "carries the delivery-target triple and no computer-use origin", ctx do
      {_event, row} = create!(ctx)
      {:ok, event} = Repo.get_temporal_event(row.event_id, server: ctx.repo)

      context =
        Followup.loop_context(%{
          reminder: row,
          event: event,
          repo: ctx.repo,
          capability_registry: ctx.capability_registry
        })

      assert context.conversation_key ==
               {row.delivery_platform, row.delivery_destination, row.delivery_thread_scope}

      assert context.session_id == "followup_" <> row.id
      assert context.agent_name == "followup:" <> row.event_id
      assert context.source_trust == :operator
      assert context.route_transient_retry == false
      refute Map.has_key?(context, :computer_use_origin)

      refute Enum.any?(
               Map.keys(context),
               &String.starts_with?(Atom.to_string(&1), "memory_source")
             )
    end
  end
end
