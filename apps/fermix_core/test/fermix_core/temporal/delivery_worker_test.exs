defmodule FermixCore.Temporal.DeliveryWorkerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.DeliverySupervisor
  alias FermixCore.Temporal.DeliveryWorker
  alias FermixCore.Temporal.Planner

  @tz "America/New_York"
  # Well before the September occurrence, so no lead rule is skipped as past.
  @created_at ~U[2026-09-01 12:00:00Z]
  # 2026-09-14 09:00 EDT — the day-of rule's wall time.
  @day_of_due ~U[2026-09-14 13:00:00Z]

  # A fake channel adapter that answers from a script held by a named Agent.
  # The reminder's destination IS that agent's name, which is the only routing
  # coordinate `Temporal.Delivery` may pass to a channel — no test-only send
  # option is smuggled through the send path.
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

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-temporal-worker-#{unique}.db")
    repo = :"temporal_worker_repo_#{unique}"
    supervisor = :"temporal_worker_sup_#{unique}"
    channel = :"temporal_fake_channel_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({DeliverySupervisor, name: supervisor})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, supervisor: supervisor, channel: channel, unique: unique}
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

  defp birthday_spec(rules) do
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
      reminder_plan: rules
    }
  end

  defp explicit_spec(occurrence_at) do
    local = DateTime.shift_zone!(occurrence_at, @tz)

    %{
      title: "Submit the report",
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

  defp create!(ctx, spec, target \\ %{}, now \\ @created_at) do
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

    {:ok, {:created, event, _rows}} =
      Repo.create_temporal_event(attrs, %{plan | occurrences: occurrences}, now, server: ctx.repo)

    event
  end

  defp claim!(ctx, now) do
    {:ok, [row]} = Repo.claim_due_reminders(now, 1, server: ctx.repo)
    row
  end

  defp deliver!(ctx, row, now) do
    {:ok, pid} =
      DeliverySupervisor.start_delivery(ctx.supervisor, DeliveryWorker, %{
        reminder: row,
        repo: ctx.repo,
        now_fn: fn -> now end,
        delivery_opts: [adapter: ScriptedAdapter]
      })

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000

    {:ok, settled} = Repo.get_temporal_reminder(row.id, server: ctx.repo)
    {reason, settled}
  end

  defp run_attempt(ctx, now) do
    ctx |> claim!(now) |> then(&deliver!(ctx, &1, now))
  end

  defp day_of_rules, do: [%{rule_id: "day_of", kind: :days_before, days: 0, at: ~T[09:00:00]}]

  describe "a successful send" do
    test "marks the reminder delivered and sends the rendered message once", ctx do
      start_channel(ctx, [:ok])
      create!(ctx, birthday_spec(day_of_rules()))

      {exit_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert exit_reason == :normal
      assert row.status == "delivered"
      assert row.attempt_count == 1
      assert DateTime.compare(row.sent_at, @day_of_due) == :eq
      assert [%{text: text, opts: opts}] = calls(ctx)
      assert text == "Today: Sarah's birthday — September 14."
      assert opts == []
    end
  end

  describe "thread scope" do
    test "a telegram thread scope becomes an integer message_thread_id", ctx do
      start_channel(ctx, [:ok])
      create!(ctx, birthday_spec(day_of_rules()), %{delivery_thread_scope: "42"})

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "delivered"
      assert [%{opts: [message_thread_id: 42]}] = calls(ctx)
    end

    test "a slack thread scope becomes a thread_ts string", ctx do
      start_channel(ctx, [:ok])

      create!(ctx, birthday_spec(day_of_rules()), %{
        delivery_platform: "slack",
        delivery_thread_scope: "1710000000.000100"
      })

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "delivered"
      assert [%{opts: [thread_ts: "1710000000.000100"]}] = calls(ctx)
    end

    test "a thread scope on a platform that has none fails terminally instead of guessing", ctx do
      start_channel(ctx, [:ok])

      create!(ctx, birthday_spec(day_of_rules()), %{
        delivery_platform: "discord",
        delivery_thread_scope: "some-thread"
      })

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "failed"
      assert row.last_error == "permanent:malformed_request"
      assert calls(ctx) == []
    end
  end

  describe "retryable failures" do
    test "a transport failure re-arms the row one minute later with the attempt consumed", ctx do
      start_channel(ctx, [{:error, %Req.TransportError{reason: :closed}}])
      create!(ctx, birthday_spec(day_of_rules()))

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "pending"
      assert row.attempt_count == 1
      assert row.last_error == "transport:closed"
      assert DateTime.compare(row.ready_at, DateTime.add(@day_of_due, 60, :second)) == :eq
    end

    test "a rate limit hint longer than the plan delay wins", ctx do
      start_channel(ctx, [{:error, {:rate_limited, 300_000}}])
      create!(ctx, birthday_spec(day_of_rules()))

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "pending"
      assert row.last_error == "rate_limited:300000"
      assert DateTime.compare(row.ready_at, DateTime.add(@day_of_due, 300, :second)) == :eq
    end

    test "a rate limit hint shorter than the plan delay never shortens the schedule", ctx do
      start_channel(ctx, [{:error, {:rate_limited, 1_000}}])
      create!(ctx, birthday_spec(day_of_rules()))

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert DateTime.compare(row.ready_at, DateTime.add(@day_of_due, 60, :second)) == :eq
    end

    test "a retry that would land past the validity boundary expires the row instead", ctx do
      start_channel(ctx, [{:error, {:http_status, 503}}])
      occurrence_at = ~U[2026-09-20 17:00:00Z]
      create!(ctx, explicit_spec(occurrence_at))

      # Claimed 30 seconds before the two-hour validity boundary: the next plan
      # delay cannot fit, so an unclaimable pending row must never be written.
      late = DateTime.add(occurrence_at, 7_170, :second)
      {_reason, row} = deliver!(ctx, claim!(ctx, late), late)

      assert row.status == "expired"
      assert row.attempt_count == 1
    end

    test "the fifth claim is terminal: five delays, never a sixth attempt", ctx do
      start_channel(ctx, List.duplicate({:error, {:transport, :connection_reset}}, 5))
      create!(ctx, birthday_spec(day_of_rules()))

      {_r1, first} = run_attempt(ctx, @day_of_due)
      assert first.status == "pending"
      assert first.attempt_count == 1

      second_at = DateTime.add(@day_of_due, 60, :second)
      {_r2, second} = run_attempt(ctx, second_at)
      assert second.attempt_count == 2

      third_at = DateTime.add(second_at, 300, :second)
      {_r3, third} = run_attempt(ctx, third_at)
      assert third.attempt_count == 3

      fourth_at = DateTime.add(third_at, 900, :second)
      {_r4, fourth} = run_attempt(ctx, fourth_at)
      assert fourth.attempt_count == 4

      fifth_at = DateTime.add(fourth_at, 3_600, :second)
      {_r5, fifth} = run_attempt(ctx, fifth_at)

      assert fifth.status == "failed"
      assert fifth.attempt_count == 5
      assert fifth.last_error == "transport:connection_reset"
      assert length(calls(ctx)) == 5

      assert Repo.claim_due_reminders(DateTime.add(fifth_at, 3_600, :second), 5, server: ctx.repo) ==
               {:ok, []}
    end

    test "exhaustion at the cap is failed and visible, even on a two-hour validity", ctx do
      # §11.4/§16: exhaustion is `failed`, and `event_list` must expose it. An
      # explicit reminder is valid for two hours (§8.3), so the delay after the
      # fifth attempt (t+4860s -> t+8460s) always overshoots that boundary —
      # settling `expired` there would hide the exhausted reminder from the
      # owner-visible delivery summary entirely.
      start_channel(ctx, List.duplicate({:error, {:transport, :connection_reset}}, 5))
      occurrence_at = ~U[2026-09-20 17:00:00Z]
      create!(ctx, explicit_spec(occurrence_at))

      {settled, fifth_at} =
        Enum.reduce([0, 60, 300, 900, 3_600], {nil, occurrence_at}, fn delay, {_row, at} ->
          next = DateTime.add(at, delay, :second)
          {_reason, row} = run_attempt(ctx, next)
          {row, next}
        end)

      assert DateTime.diff(fifth_at, occurrence_at) == 4_860
      assert DateTime.diff(settled.valid_until, occurrence_at) == 7_200

      assert settled.status == "failed"
      assert settled.attempt_count == 5
      assert settled.last_error == "transport:connection_reset"
      assert DateTime.compare(settled.failed_at, fifth_at) == :eq

      assert {:ok, %{events: [listed]}} =
               Repo.list_temporal_events(%{status: :any}, server: ctx.repo)

      assert listed.last_delivery_status == "failed"
      assert listed.last_delivery_error == "transport:connection_reset"
    end
  end

  describe "terminal failures" do
    test "a permanent error fails the row on the first attempt", ctx do
      start_channel(ctx, [{:error, {:permanent, :authentication}}])
      create!(ctx, birthday_spec(day_of_rules()))

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "failed"
      assert row.attempt_count == 1
      assert row.last_error == "permanent:authentication"
      assert DateTime.compare(row.failed_at, @day_of_due) == :eq
    end

    test "a result outside the closed vocabulary fails as an invalid contract", ctx do
      start_channel(ctx, [{:error, "Slack API error: 429"}])
      create!(ctx, birthday_spec(day_of_rules()))

      {_reason, row} = deliver!(ctx, claim!(ctx, @day_of_due), @day_of_due)

      assert row.status == "failed"
      assert row.last_error == "unexpected_delivery_result:invalid_contract"
    end

    test "a crashing adapter is reduced to the bounded worker-crash reason", ctx do
      start_channel(ctx, [])
      create!(ctx, birthday_spec(day_of_rules()))
      row = claim!(ctx, @day_of_due)

      # The scripted agent is stopped, so the send exits inside the watchdog
      # child; the raw crash payload must never reach SQLite.
      :ok = Agent.stop(ctx.channel)

      {_reason, settled} = deliver!(ctx, row, @day_of_due)

      assert settled.status == "failed"
      assert settled.last_error == "delivery_crashed:worker_crash"
    end
  end

  describe "validity clamp" do
    test "a row claimed past its validity boundary is expired loudly, never sent", ctx do
      start_channel(ctx, [:ok])
      create!(ctx, birthday_spec(day_of_rules()))
      row = claim!(ctx, @day_of_due)

      # The worker's own clock has moved past `valid_until` (a claim this stale
      # should be impossible): no channel send may happen.
      past = DateTime.add(row.valid_until, 5, :second)
      {_reason, settled} = deliver!(ctx, row, past)

      assert settled.status == "expired"
      assert calls(ctx) == []
    end

    # Sub-millisecond truncation is not expiry. A row whose validity has NOT
    # passed was legitimately claimed, and taking the unclaimable path reports a
    # boundary breach that never happened. The assertions are on that path, not
    # on the send's outcome: a 1ms watchdog may legitimately time the send out,
    # which is an ordinary retry and not what this pins.
    test "a row with sub-millisecond validity left is attempted, never called unclaimable", ctx do
      start_channel(ctx, [:ok])
      create!(ctx, birthday_spec(day_of_rules()))
      row = claim!(ctx, @day_of_due)

      # 500 microseconds before the boundary: still inside it, but zero whole
      # milliseconds remain.
      almost = DateTime.add(row.valid_until, -500, :microsecond)
      assert DateTime.compare(row.valid_until, almost) == :gt

      {{_reason, settled}, log} = with_log(fn -> deliver!(ctx, row, almost) end)

      refute log =~ "claimed at or past its validity boundary"
      refute settled.status == "expired"
      refute settled.last_error == "expired_before_send"
    end
  end
end
