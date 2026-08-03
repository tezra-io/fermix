defmodule FermixCore.Temporal.TelemetryTest do
  # async: false — the content gate is `Application` env and the trace-registration
  # test attaches the real `Trace.TelemetryHandler`. Both preconditions are
  # established in this file's own setup and restored on exit.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.DeliverySupervisor
  alias FermixCore.Temporal.DeliveryWorker
  alias FermixCore.Temporal.Planner
  alias FermixCore.Temporal.Registry
  alias FermixCore.Temporal.Scheduler
  alias FermixCore.Temporal.Telemetry, as: TemporalTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  @lifecycle_event [:fermix, :reminder, :lifecycle]

  # The phase surface is pinned, not inferred (M30 §15.2): adding a phase must be
  # a deliberate edit that also updates the FermixOpik half of the invariant
  # (apps/fermix_opik/test/fermix_opik/aggregation_test.exs).
  @phases [
    :materialized,
    :claimed,
    :delivered,
    :retry_scheduled,
    :failed,
    :expired,
    :superseded,
    :cancelled,
    :event_completed,
    :scheduler_error
  ]

  @allowed_metadata_keys [
    :attempt,
    :component,
    :content,
    :error_class,
    :event_id,
    :occurrence_key,
    :phase,
    :platform,
    :reminder_id,
    :result,
    :rule_id
  ]

  @tz "America/New_York"
  @created_at ~U[2026-09-01 12:00:00Z]
  @day_of_due ~U[2026-09-14 13:00:00Z]

  # A worker that parks: it holds its claim so `claimed` can be observed without
  # a settlement racing it.
  defmodule ParkedWorker do
    @moduledoc false

    def child_spec(args) do
      %{
        id: {__MODULE__, args.reminder.id},
        start: {__MODULE__, :start_link, [args]},
        restart: :temporary
      }
    end

    def start_link(args) do
      notify = Keyword.fetch!(args.delivery_opts, :notify)
      id = args.reminder.id

      pid =
        spawn_link(fn ->
          send(notify, {:worker_started, id, self()})
          Process.sleep(:infinity)
        end)

      {:ok, pid}
    end
  end

  defmodule FaultingRepo do
    @moduledoc false

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :db_down}, state}
  end

  defmodule ScriptedAdapter do
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

  defmodule FakeAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    handler = "temporal-telemetry-#{unique}"
    test_pid = self()

    :telemetry.attach(
      handler,
      @lifecycle_event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:reminder_lifecycle, event, measurements, metadata})
      end,
      nil
    )

    # Establish the content-gate precondition here rather than inheriting whatever
    # an earlier module left behind (Known Pitfalls: leaked app env).
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, false))

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    %{unique: unique}
  end

  defp capture_content(enabled?) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, enabled?))
  end

  defp await(phase) do
    assert_receive {:reminder_lifecycle, @lifecycle_event, measurements,
                    %{phase: ^phase} = metadata},
                   1_000

    {measurements, metadata}
  end

  defp drain_lifecycle do
    receive do
      {:reminder_lifecycle, _event, _measurements, _metadata} -> drain_lifecycle()
    after
      0 -> :ok
    end
  end

  describe "emit/2 — the fixed metadata allowlist" do
    test "every phase emits the stable event with the fixed component" do
      for phase <- @phases do
        TemporalTelemetry.emit(phase, event_id: "evt_1")

        {measurements, metadata} = await(phase)
        assert measurements == %{count: 1}
        assert metadata.component == "temporal_scheduler"
        assert metadata.phase == phase
        assert metadata.event_id == "evt_1"
      end
    end

    test "phases/0 is the pinned surface both consumers were built against" do
      assert TemporalTelemetry.phases() == @phases
      assert TemporalTelemetry.lifecycle_event() == @lifecycle_event
      assert TemporalTelemetry.component() == "temporal_scheduler"
    end

    test "metadata never carries a key outside the allowlist" do
      TemporalTelemetry.emit(:delivered,
        event_id: "evt_1",
        reminder_id: "rem_1",
        occurrence_key: "2026-09-14",
        rule_id: "day_of",
        platform: "telegram",
        attempt: 2,
        result: :ok,
        duration_ms: 42
      )

      {measurements, metadata} = await(:delivered)

      assert measurements == %{duration_ms: 42}
      assert metadata.reminder_id == "rem_1"
      assert metadata.occurrence_key == "2026-09-14"
      assert metadata.rule_id == "day_of"
      assert metadata.platform == "telegram"
      assert metadata.attempt == 2
      assert metadata.result == :ok

      assert metadata |> Map.keys() |> Enum.sort() |> Enum.all?(&(&1 in @allowed_metadata_keys))
    end

    test "absent fields are dropped rather than emitted as nil" do
      TemporalTelemetry.emit(:claimed, reminder_id: "rem_1")

      {_measurements, metadata} = await(:claimed)

      refute Map.has_key?(metadata, :event_id)
      refute Map.has_key?(metadata, :platform)
      refute Map.has_key?(metadata, :attempt)
      refute Map.has_key?(metadata, :result)
      refute Map.has_key?(metadata, :error_class)
    end

    test "a free-form key is refused loudly instead of riding along" do
      assert_raise ArgumentError, fn ->
        TemporalTelemetry.emit(:failed, reminder_id: "rem_1", reason: %{body: "secret"})
      end

      refute_receive {:reminder_lifecycle, _event, _measurements, _metadata}, 50
    end

    test "a malformed allowlisted value is refused loudly" do
      assert_raise ArgumentError, fn -> TemporalTelemetry.emit(:claimed, reminder_id: 17) end
      assert_raise ArgumentError, fn -> TemporalTelemetry.emit(:claimed, attempt: -1) end
      assert_raise ArgumentError, fn -> TemporalTelemetry.emit(:claimed, duration_ms: -5) end
      assert_raise ArgumentError, fn -> TemporalTelemetry.emit(:claimed, result: :maybe) end
    end

    test "an unknown phase cannot be emitted at all" do
      assert_raise FunctionClauseError, fn -> TemporalTelemetry.emit(:snoozed, []) end
    end
  end

  describe "emit/2 — derived error classes" do
    test "an atom reason becomes its own class" do
      TemporalTelemetry.emit(:failed, result: {:error, :delivery_timeout})

      {_measurements, metadata} = await(:failed)
      assert metadata.result == :error
      assert metadata.error_class == "delivery_timeout"
    end

    test "a tagged tuple keeps only its head" do
      TemporalTelemetry.emit(:retry_scheduled, result: {:error, {:transport, :closed}})

      {_measurements, metadata} = await(:retry_scheduled)
      assert metadata.error_class == "transport"
    end

    test "anything else is unclassified rather than a leaked body" do
      TemporalTelemetry.emit(:failed,
        result: {:error, "Slack API error: 429 for chat 8217352118"}
      )

      {_measurements, metadata} = await(:failed)
      assert metadata.error_class == "unclassified"
    end

    test "a success carries no error class" do
      TemporalTelemetry.emit(:delivered, result: :ok)

      {_measurements, metadata} = await(:delivered)
      assert metadata.result == :ok
      refute Map.has_key?(metadata, :error_class)
    end
  end

  describe "emit/2 — content gate" do
    test "reminder content is dropped while the shared gate is off" do
      TemporalTelemetry.emit(:delivered, reminder_id: "rem_1", content: "Today: Sarah's birthday")

      {_measurements, metadata} = await(:delivered)
      refute Map.has_key?(metadata, :content)
    end

    test "reminder content rides only when the operator opted in" do
      capture_content(true)

      TemporalTelemetry.emit(:delivered, reminder_id: "rem_1", content: "Today: Sarah's birthday")

      {_measurements, metadata} = await(:delivered)
      assert metadata.content == "Today: Sarah's birthday"
    end
  end

  describe "reminder/1" do
    test "derives the correlation fields from a reminder row" do
      row = %{
        id: "rem_1",
        event_id: "evt_1",
        occurrence_key: "2026-09-14",
        reminder_rule_id: "week_before",
        delivery_platform: "telegram",
        attempt_count: 3
      }

      assert TemporalTelemetry.reminder(row) == [
               event_id: "evt_1",
               reminder_id: "rem_1",
               occurrence_key: "2026-09-14",
               rule_id: "week_before",
               platform: "telegram",
               attempt: 3
             ]
    end
  end

  describe "trace registration" do
    test "the shared handler writes the lifecycle event as an agent_event row" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "fermix_reminder_trace_#{System.unique_integer([:positive])}"
        )

      server = :"reminder_trace_#{System.unique_integer([:positive])}"
      prefix = "reminder-test-#{System.unique_integer([:positive])}"

      start_supervised!({Trace, base_dir: dir, name: server})
      TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

      on_exit(fn ->
        TelemetryHandler.detach(prefix)
        FermixTestSupport.SafeRm.rm_rf!(dir)
      end)

      TemporalTelemetry.emit(:delivered,
        event_id: "evt_1",
        reminder_id: "rem_1",
        platform: "telegram",
        result: :ok,
        duration_ms: 12
      )

      :sys.get_state(server)

      entry =
        [dir, Date.to_iso8601(Date.utc_today()), "agent_event.jsonl"]
        |> Path.join()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event"] == "reminder_lifecycle"))

      assert entry, "the reminder lifecycle event is not registered in the trace handler"
      assert entry["agent"] == "temporal_scheduler"
      assert entry["phase"] == "delivered"
      assert entry["reminder_id"] == "rem_1"
      assert entry["duration_ms"] == 12
    end
  end

  # --- call sites ----------------------------------------------------------

  defp start_repo(ctx) do
    db_path = Path.join(System.tmp_dir!(), "fermix-temporal-telemetry-#{ctx.unique}.db")
    repo = :"temporal_tel_repo_#{ctx.unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo
  end

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp explicit_spec(title, occurrence_at) do
    local = DateTime.shift_zone!(occurrence_at, @tz)

    %{
      title: title,
      description: nil,
      kind: "explicit_reminder",
      time_kind: "datetime",
      local_date: DateTime.to_date(local),
      local_time: DateTime.to_time(local),
      timezone: @tz,
      occurrence_at: occurrence_at,
      recurrence_kind: "once",
      recurrence_month: nil,
      recurrence_day: nil,
      leap_day_policy: nil,
      reminder_plan: [%{rule_id: "at_time", kind: :at_occurrence}]
    }
  end

  defp birthday_spec do
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
      reminder_plan: [%{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]}]
    }
  end

  defp create!(repo, spec, destination \\ "12345", now \\ @created_at) do
    {:ok, plan} = Planner.materialize(spec, now)
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
        delivery_destination: destination,
        delivery_thread_scope: "root",
        source_channel: "telegram",
        source_chat_id: "12345",
        source_thread_scope: "root",
        source_session_id: "sess-1",
        created_by_trust: "operator",
        created_by_origin: "interactive"
      })

    {:ok, {:created, event, rows}} =
      Repo.create_temporal_event(attrs, %{plan | occurrences: occurrences}, now, server: repo)

    {event, rows}
  end

  describe "scheduler call sites" do
    test "a claim emits claimed with the row's correlation fields", ctx do
      repo = start_repo(ctx)
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      start_supervised!({DeliverySupervisor, name: supervisor})

      due = ~U[2026-09-20 17:00:00Z]
      {event, [row]} = create!(repo, explicit_spec("Submit the report", due))

      scheduler =
        start_supervised!(
          {Scheduler,
           name: :"temporal_tel_sched_#{ctx.unique}",
           repo: repo,
           delivery_supervisor: supervisor,
           delivery_worker_module: ParkedWorker,
           delivery_opts: [notify: self()],
           now_fn: fn -> due end,
           scheduler_enabled: true,
           timer_enabled: false}
        )

      drain_lifecycle()
      :ok = Scheduler.tick(scheduler, now: due)

      {measurements, metadata} = await(:claimed)
      assert measurements == %{count: 1}
      assert metadata.event_id == event.id
      assert metadata.reminder_id == row.id
      assert metadata.occurrence_key == row.occurrence_key
      assert metadata.rule_id == "at_time"
      assert metadata.platform == "telegram"
      assert metadata.attempt == 1
    end

    test "the boot sweep emits the outcome of every stranded claim", ctx do
      repo = start_repo(ctx)
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      start_supervised!({DeliverySupervisor, name: supervisor})

      due = ~U[2026-09-20 17:00:00Z]
      {_event, [row]} = create!(repo, explicit_spec("Submit the report", due))
      {:ok, [claimed]} = Repo.claim_due_reminders(due, 1, server: repo)
      assert claimed.status == "delivering"

      drain_lifecycle()

      capture_log(fn ->
        start_supervised!(
          {Scheduler,
           name: :"temporal_tel_sched_#{ctx.unique}",
           repo: repo,
           delivery_supervisor: supervisor,
           delivery_worker_module: ParkedWorker,
           delivery_opts: [notify: self()],
           now_fn: fn -> due end,
           scheduler_enabled: true,
           timer_enabled: false}
        )
      end)

      {_measurements, metadata} = await(:retry_scheduled)
      assert metadata.reminder_id == row.id
      assert metadata.error_class == "stranded_claim"
    end

    test "a failing due scan emits scheduler_error rather than failing silently", ctx do
      faulting = :"temporal_tel_faulting_#{ctx.unique}"
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      start_supervised!({FaultingRepo, name: faulting})
      start_supervised!({DeliverySupervisor, name: supervisor})

      now = ~U[2026-09-20 17:00:00Z]

      scheduler =
        capture_log(fn ->
          start_supervised!(
            {Scheduler,
             name: :"temporal_tel_sched_#{ctx.unique}",
             repo: faulting,
             delivery_supervisor: supervisor,
             delivery_worker_module: ParkedWorker,
             delivery_opts: [notify: self()],
             now_fn: fn -> now end,
             scheduler_enabled: true,
             timer_enabled: false}
          )
        end)
        |> then(fn _log -> :"temporal_tel_sched_#{ctx.unique}" end)

      drain_lifecycle()
      capture_log(fn -> :ok = Scheduler.tick(scheduler, now: now) end)

      {measurements, metadata} = await(:scheduler_error)
      assert measurements == %{count: 1}
      assert metadata.result == :error
      assert metadata.error_class == "db_down"
    end

    test "reconciliation emits the boundary transitions it commits", ctx do
      repo = start_repo(ctx)
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      start_supervised!({DeliverySupervisor, name: supervisor})

      due = ~U[2026-09-20 17:00:00Z]
      {event, [row]} = create!(repo, explicit_spec("Submit the report", due))

      scheduler =
        start_supervised!(
          {Scheduler,
           name: :"temporal_tel_sched_#{ctx.unique}",
           repo: repo,
           delivery_supervisor: supervisor,
           delivery_worker_module: ParkedWorker,
           delivery_opts: [notify: self()],
           now_fn: fn -> due end,
           scheduler_enabled: true,
           timer_enabled: false}
        )

      drain_lifecycle()

      # Past the two-hour validity boundary of an at-occurrence rule: the row
      # expires and the one-time event completes.
      later = DateTime.add(due, 3 * 3600, :second)
      capture_log(fn -> :ok = Scheduler.reconcile(scheduler, now: later) end)

      {_measurements, expired} = await(:expired)
      assert expired.reminder_id == row.id

      {_measurements, completed} = await(:event_completed)
      assert completed.event_id == event.id
    end
  end

  describe "delivery worker call sites" do
    test "a delivered reminder emits delivered with its send duration", ctx do
      repo = start_repo(ctx)
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      channel = :"temporal_tel_channel_#{ctx.unique}"
      start_supervised!({DeliverySupervisor, name: supervisor})

      start_supervised!(%{
        id: {:channel, channel},
        start: {Agent, :start_link, [fn -> %{script: [:ok], calls: []} end, [name: channel]]},
        restart: :temporary
      })

      {_event, _rows} = create!(repo, birthday_spec(), Atom.to_string(channel))
      {:ok, [row]} = Repo.claim_due_reminders(@day_of_due, 1, server: repo)

      drain_lifecycle()

      {:ok, pid} =
        DeliverySupervisor.start_delivery(supervisor, DeliveryWorker, %{
          reminder: row,
          repo: repo,
          now_fn: fn -> @day_of_due end,
          delivery_opts: [adapter: ScriptedAdapter]
        })

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      {measurements, metadata} = await(:delivered)
      assert is_integer(measurements.duration_ms) and measurements.duration_ms >= 0
      assert metadata.reminder_id == row.id
      assert metadata.platform == "telegram"
      assert metadata.result == :ok
      refute Map.has_key?(metadata, :content)
    end

    test "a permanent failure emits failed with the typed error class", ctx do
      repo = start_repo(ctx)
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      channel = :"temporal_tel_channel_#{ctx.unique}"
      start_supervised!({DeliverySupervisor, name: supervisor})

      start_supervised!(%{
        id: {:channel, channel},
        start:
          {Agent, :start_link,
           [
             fn -> %{script: [{:error, {:permanent, :authentication}}], calls: []} end,
             [name: channel]
           ]},
        restart: :temporary
      })

      {_event, _rows} = create!(repo, birthday_spec(), Atom.to_string(channel))
      {:ok, [row]} = Repo.claim_due_reminders(@day_of_due, 1, server: repo)

      drain_lifecycle()

      capture_log(fn ->
        {:ok, pid} =
          DeliverySupervisor.start_delivery(supervisor, DeliveryWorker, %{
            reminder: row,
            repo: repo,
            now_fn: fn -> @day_of_due end,
            delivery_opts: [adapter: ScriptedAdapter]
          })

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      end)

      {_measurements, metadata} = await(:failed)
      assert metadata.reminder_id == row.id
      assert metadata.result == :error
      assert metadata.error_class == "permanent"
    end

    test "a retryable failure emits retry_scheduled", ctx do
      repo = start_repo(ctx)
      supervisor = :"temporal_tel_sup_#{ctx.unique}"
      channel = :"temporal_tel_channel_#{ctx.unique}"
      start_supervised!({DeliverySupervisor, name: supervisor})

      start_supervised!(%{
        id: {:channel, channel},
        start:
          {Agent, :start_link,
           [
             fn -> %{script: [{:error, %Req.TransportError{reason: :closed}}], calls: []} end,
             [name: channel]
           ]},
        restart: :temporary
      })

      {_event, _rows} = create!(repo, birthday_spec(), Atom.to_string(channel))
      {:ok, [row]} = Repo.claim_due_reminders(@day_of_due, 1, server: repo)

      drain_lifecycle()

      capture_log(fn ->
        {:ok, pid} =
          DeliverySupervisor.start_delivery(supervisor, DeliveryWorker, %{
            reminder: row,
            repo: repo,
            now_fn: fn -> @day_of_due end,
            delivery_opts: [adapter: ScriptedAdapter]
          })

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      end)

      {_measurements, metadata} = await(:retry_scheduled)
      assert metadata.reminder_id == row.id
      assert metadata.error_class == "transport"
    end
  end

  describe "registry call sites" do
    @registry_channels %{
      "telegram" => FakeAdapter,
      "slack" => FakeAdapter,
      "discord" => FakeAdapter,
      "signal" => FakeAdapter,
      "whatsapp" => FakeAdapter
    }

    defp registry_context(repo, overrides \\ %{}) do
      Map.merge(
        %{
          agent_name: "main",
          conversation_key: {"telegram", "555", :root},
          session_id: "sess-1",
          source_trust: :operator,
          computer_use_origin: :interactive,
          memory_agent_id: "main",
          memory_owner_id: "default",
          memory_repo: repo,
          temporal_scheduler: nil
        },
        overrides
      )
    end

    defp registry_opts do
      [
        now: ~U[2026-08-02 12:00:00Z],
        jobs_config: [
          default_delivery_mode: "channel",
          default_delivery_target: [platform: "telegram", chat_id: "8217352118"],
          delivery_channels: @registry_channels
        ],
        personalization: [timezone: @tz]
      ]
    end

    test "a created event emits materialized", ctx do
      repo = start_repo(ctx)
      drain_lifecycle()

      {:ok, %{event: event}} =
        Registry.create_event(
          %{
            title: "Sarah's birthday",
            kind: "birthday",
            when: %{"type" => "annual", "month" => 9, "day" => 14}
          },
          registry_context(repo),
          registry_opts()
        )

      {measurements, metadata} = await(:materialized)
      assert measurements == %{count: 1}
      assert metadata.event_id == event.id
      assert metadata.platform == "telegram"
      assert metadata.result == :ok
      refute Map.has_key?(metadata, :content)
    end

    test "a cancelled event emits cancelled", ctx do
      repo = start_repo(ctx)

      {:ok, %{event: event}} =
        Registry.create_event(
          %{
            title: "Sarah's birthday",
            kind: "birthday",
            when: %{"type" => "annual", "month" => 9, "day" => 14}
          },
          registry_context(repo),
          registry_opts()
        )

      drain_lifecycle()

      {:ok, _cancelled} = Registry.cancel_event(event.id, registry_context(repo), registry_opts())

      {_measurements, metadata} = await(:cancelled)
      assert metadata.event_id == event.id
    end

    test "an unavailable scheduler emits scheduler_error and keeps the committed write", ctx do
      repo = start_repo(ctx)
      drain_lifecycle()

      log =
        capture_log(fn ->
          assert {:ok, %{event: _event}} =
                   Registry.create_event(
                     %{
                       title: "Sarah's birthday",
                       kind: "birthday",
                       when: %{"type" => "annual", "month" => 9, "day" => 14}
                     },
                     registry_context(repo, %{
                       temporal_scheduler: :temporal_scheduler_definitely_absent
                     }),
                     registry_opts()
                   )
        end)

      assert log =~ "unavailable"

      {_measurements, metadata} = await(:scheduler_error)
      assert metadata.result == :error
      assert metadata.error_class == "scheduler_unavailable"
    end
  end
end
