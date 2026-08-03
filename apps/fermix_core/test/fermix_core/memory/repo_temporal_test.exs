defmodule FermixCore.Memory.RepoTemporalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.TemporalSql
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.Planner

  @tz "America/New_York"
  @now ~U[2026-08-02 12:00:00Z]

  @reminder_columns_sql "SELECT name FROM pragma_table_info('reminder_occurrences')"
  @reminder_indexes_sql "SELECT name FROM sqlite_master WHERE type = 'index' AND " <>
                          "tbl_name = 'reminder_occurrences'"
  @snooze_indexes ~w(
    idx_reminder_occurrences_snooze_dedupe
    idx_reminder_occurrences_snooze_source
    idx_reminder_occurrences_target_sent
  )

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-temporal-#{unique}.db")
    repo_name = :"memory_repo_temporal_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name, db_path: db_path}
  end

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # Stored instants come back at the fixed-width microsecond precision the
  # schema serializes (§7.2), so expectations are stated at that precision.
  defp utc(%DateTime{microsecond: {value, _precision}} = at), do: %{at | microsecond: {value, 6}}

  defp birthday_spec(overrides \\ %{}) do
    {:ok, plan} = Defaults.plan_for("birthday", "date")

    Map.merge(
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
        reminder_plan: plan
      },
      overrides
    )
  end

  defp appointment_spec(overrides \\ %{}) do
    {:ok, plan} = Defaults.plan_for("appointment", "datetime")

    Map.merge(
      %{
        title: "Dentist appointment",
        description: nil,
        kind: "appointment",
        time_kind: "datetime",
        local_date: ~D[2026-08-16],
        local_time: ~T[15:00:00],
        timezone: @tz,
        occurrence_at: ~U[2026-08-16 19:00:00Z],
        recurrence_kind: "once",
        recurrence_month: nil,
        recurrence_day: nil,
        leap_day_policy: nil,
        reminder_plan: plan
      },
      overrides
    )
  end

  # The event attrs the Repo persists: the planner spec plus identity,
  # snapshotted delivery target, and provenance.
  defp event_attrs(spec, overrides \\ %{}) do
    spec
    |> Map.put(:reminder_plan, Defaults.encode_plan(spec.reminder_plan))
    |> Map.merge(%{
      id: uid("evt"),
      agent_id: "main",
      owner_id: "default",
      dedupe_key: "dedupe-#{spec.kind}-#{spec.title}",
      delivery_platform: "telegram",
      delivery_destination: "12345",
      delivery_thread_scope: "root",
      source_channel: "telegram",
      source_chat_id: "12345",
      source_thread_scope: "root",
      source_session_id: "sess-1",
      created_by_trust: "operator",
      created_by_origin: "interactive"
    })
    |> Map.merge(overrides)
  end

  defp plan_with_ids(plan) do
    Map.update!(plan, :occurrences, fn occurrences ->
      Enum.map(occurrences, &Map.put(&1, :id, uid("rem")))
    end)
  end

  defp create(repo, spec, overrides, now) do
    {:ok, plan} = Planner.materialize(spec, now)
    attrs = event_attrs(spec, overrides)
    {attrs, Repo.create_temporal_event(attrs, plan_with_ids(plan), now, server: repo)}
  end

  defp create!(repo, spec, overrides \\ %{}, now \\ @now) do
    {attrs, {:ok, {:created, event, occurrences}}} = create(repo, spec, overrides, now)
    {attrs, event, occurrences}
  end

  describe "create_temporal_event/4" do
    test "persists the event and its planner occurrences in one transaction", %{repo: repo} do
      {_attrs, event, occurrences} = create!(repo, birthday_spec())

      assert event.status == "active"
      assert event.revision == 1
      assert event.title == "Sarah's birthday"
      assert event.recurrence_kind == "yearly"
      assert event.next_occurrence_on == ~D[2026-09-14]
      assert event.materialized_through_on == ~D[2027-09-14]

      assert event.reminder_plan ==
               Defaults.encode_plan(elem(Defaults.plan_for("birthday", "date"), 1))

      assert Enum.map(occurrences, &{&1.occurrence_key, &1.reminder_rule_id}) == [
               {"2026-09-14", "week_before"},
               {"2026-09-14", "day_of"},
               {"2027-09-14", "week_before"},
               {"2027-09-14", "day_of"}
             ]

      first = hd(occurrences)
      assert first.status == "pending"
      assert first.attempt_count == 0
      assert first.event_revision == 1
      assert first.ready_at == first.scheduled_for
      assert first.delivery_platform == "telegram"
      assert first.delivery_destination == "12345"
      assert first.payload["title"] == "Sarah's birthday"
      assert is_nil(first.sent_at)
    end

    test "an identical repeat create returns the existing event instead of duplicating", %{
      repo: repo
    } do
      {attrs, event, _occurrences} = create!(repo, birthday_spec())

      {:ok, plan} = Planner.materialize(birthday_spec(), @now)

      assert {:ok, {:existing, existing, occurrences}} =
               Repo.create_temporal_event(
                 Map.put(attrs, :id, uid("evt")),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      assert existing.id == event.id
      assert length(occurrences) == 4

      assert {:ok, %{events: [_only_one]}} =
               Repo.list_temporal_events(%{}, server: repo)
    end

    test "an identity collision with a different date fails and directs to an update", %{
      repo: repo
    } do
      {attrs, _event, _occurrences} = create!(repo, birthday_spec())

      moved = birthday_spec(%{recurrence_day: 15})
      {:ok, plan} = Planner.materialize(moved, @now)

      assert {:error, :identity_conflict} =
               Repo.create_temporal_event(
                 event_attrs(moved, %{dedupe_key: attrs.dedupe_key}),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )
    end

    test "a cancelled event does not block a new active event with the same identity", %{
      repo: repo
    } do
      {attrs, event, _occurrences} = create!(repo, birthday_spec())
      assert {:ok, _cancelled} = Repo.cancel_temporal_event(event.id, @now, server: repo)

      {:ok, plan} = Planner.materialize(birthday_spec(), @now)

      assert {:ok, {:created, fresh, _rows}} =
               Repo.create_temporal_event(
                 Map.put(attrs, :id, uid("evt")),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      refute fresh.id == event.id
    end

    test "an empty plan stores the event with no reminder rows", %{repo: repo} do
      spec = birthday_spec(%{reminder_plan: []})
      {_attrs, event, occurrences} = create!(repo, spec)

      assert occurrences == []
      assert event.next_occurrence_on == ~D[2026-09-14]
    end

    test "timestamps are stored fixed-width so lexical order is chronological", %{
      repo: repo,
      db_path: db_path
    } do
      {_attrs, _event, occurrences} = create!(repo, birthday_spec())

      raw = raw_column(db_path, "SELECT scheduled_for FROM reminder_occurrences ORDER BY id")

      assert Enum.all?(raw, &Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/, &1))
      assert length(raw) == length(occurrences)
    end

    test "a non-UTC input instant is normalized to UTC", %{repo: repo} do
      {:ok, local} = DateTime.new(~D[2026-08-16], ~T[15:00:00], @tz)
      spec = appointment_spec(%{occurrence_at: local})

      {_attrs, event, _occurrences} = create!(repo, spec)

      assert event.occurrence_at == utc(~U[2026-08-16 19:00:00Z])
      assert event.occurrence_at.time_zone == "Etc/UTC"
    end

    test "a variable-width timestamp string is rejected, never coerced", %{repo: repo} do
      spec = appointment_spec()
      {:ok, plan} = Planner.materialize(spec, @now)
      attrs = event_attrs(spec, %{occurrence_at: "2026-08-16T19:00:00Z"})

      assert {:error, {:invalid, :occurrence_at, :not_fixed_width}} =
               Repo.create_temporal_event(attrs, plan_with_ids(plan), @now, server: repo)
    end

    test "byte caps are enforced with clear errors and never truncate", %{repo: repo} do
      spec = appointment_spec()
      {:ok, plan} = Planner.materialize(spec, @now)

      assert {:error, {:invalid, :title, :empty}} =
               Repo.create_temporal_event(
                 event_attrs(spec, %{title: ""}),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      assert {:error, {:invalid, :title, :too_long}} =
               Repo.create_temporal_event(
                 event_attrs(spec, %{title: String.duplicate("a", 241)}),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      assert {:error, {:invalid, :description, :too_long}} =
               Repo.create_temporal_event(
                 event_attrs(spec, %{description: String.duplicate("b", 2_001)}),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      huge = [
        %{"rule_id" => "x", "kind" => "at_occurrence", "pad" => String.duplicate("c", 17_000)}
      ]

      assert {:error, {:invalid, :reminder_plan, :too_large}} =
               Repo.create_temporal_event(
                 event_attrs(spec, %{reminder_plan: huge}),
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )
    end

    test "the schema refuses a sixth attempt or a delivered row without sent_at", %{
      repo: repo,
      db_path: db_path
    } do
      {_attrs, _event, [first | _rest]} = create!(repo, birthday_spec())

      assert {:error, attempts} =
               raw_execute(
                 db_path,
                 "UPDATE reminder_occurrences SET attempt_count = 6 WHERE id = '#{first.id}'"
               )

      assert attempts =~ "CHECK constraint failed"

      assert {:error, delivered} =
               raw_execute(
                 db_path,
                 "UPDATE reminder_occurrences SET status = 'delivered' WHERE id = '#{first.id}'"
               )

      assert delivered =~ "CHECK constraint failed"
    end

    test "an oversized occurrence payload is rejected", %{repo: repo} do
      spec = appointment_spec()
      {:ok, plan} = Planner.materialize(spec, @now)

      fat =
        Map.update!(plan_with_ids(plan), :occurrences, fn [first | rest] ->
          [Map.put(first, :payload, %{"pad" => String.duplicate("d", 17_000)}) | rest]
        end)

      assert {:error, {:invalid, :payload, :too_large}} =
               Repo.create_temporal_event(event_attrs(spec), fat, @now, server: repo)
    end
  end

  describe "update_temporal_event/5" do
    test "bumps the revision, cancels older pending rows, and materializes the new plan", %{
      repo: repo
    } do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      moved =
        appointment_spec(%{local_time: ~T[16:00:00], occurrence_at: ~U[2026-08-16 20:00:00Z]})

      {:ok, plan} = Planner.materialize(moved, @now)

      assert {:ok, {updated, rows}} =
               Repo.update_temporal_event(
                 event.id,
                 %{local_time: ~T[16:00:00], occurrence_at: ~U[2026-08-16 20:00:00Z]},
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      assert updated.revision == 2
      assert updated.occurrence_at == utc(~U[2026-08-16 20:00:00Z])
      assert Enum.all?(rows, &(&1.event_revision == 2))

      assert {:ok, all} = Repo.list_temporal_reminders(%{event_id: event.id}, server: repo)
      old = Enum.filter(all, &(&1.event_revision == 1))
      assert Enum.all?(old, &(&1.status == "cancelled"))
      assert length(old) == 2
    end

    test "delivered history from an older revision is immutable", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      due = ~U[2026-08-15 19:00:00Z]
      assert {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      assert {:ok, delivered} = Repo.temporal_reminder_delivered(claimed.id, due, server: repo)
      assert delivered.status == "delivered"

      {:ok, plan} = Planner.materialize(appointment_spec(), due)

      assert {:ok, {updated, _rows}} =
               Repo.update_temporal_event(event.id, %{title: "Dentist"}, plan_with_ids(plan), due,
                 server: repo
               )

      assert updated.revision == 2

      assert {:ok, kept} = Repo.get_temporal_reminder(claimed.id, server: repo)
      assert kept.status == "delivered"
      assert kept.sent_at == utc(due)
    end

    test "refuses while a reminder of that event is being delivered", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      due = ~U[2026-08-15 19:00:00Z]
      assert {:ok, [_claimed]} = Repo.claim_due_reminders(due, 10, server: repo)

      {:ok, plan} = Planner.materialize(appointment_spec(), due)

      assert {:error, :delivery_in_progress} =
               Repo.update_temporal_event(event.id, %{title: "Dentist"}, plan_with_ids(plan), due,
                 server: repo
               )

      assert {:error, :delivery_in_progress} =
               Repo.cancel_temporal_event(event.id, due, server: repo)
    end

    test "validates the merged event at the boundary", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())
      {:ok, plan} = Planner.materialize(appointment_spec(), @now)

      assert {:error, {:invalid, :title, :too_long}} =
               Repo.update_temporal_event(
                 event.id,
                 %{title: String.duplicate("a", 241)},
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )

      assert {:error, {:unknown_field, :status}} =
               Repo.update_temporal_event(
                 event.id,
                 %{status: "completed"},
                 plan_with_ids(plan),
                 @now,
                 server: repo
               )
    end

    test "an unknown or inactive event fails loudly", %{repo: repo} do
      {:ok, plan} = Planner.materialize(appointment_spec(), @now)

      assert {:error, :not_found} =
               Repo.update_temporal_event("evt_missing", %{title: "x"}, plan_with_ids(plan), @now,
                 server: repo
               )

      {_attrs, event, _occurrences} = create!(repo, appointment_spec())
      assert {:ok, _} = Repo.cancel_temporal_event(event.id, @now, server: repo)

      assert {:error, :not_active} =
               Repo.update_temporal_event(event.id, %{title: "x"}, plan_with_ids(plan), @now,
                 server: repo
               )
    end
  end

  describe "cancel_temporal_event/3" do
    test "soft-cancels the event and its unsent reminders while keeping history", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      due = ~U[2026-08-15 19:00:00Z]
      assert {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      assert {:ok, _} = Repo.temporal_reminder_delivered(claimed.id, due, server: repo)

      assert {:ok, cancelled} = Repo.cancel_temporal_event(event.id, due, server: repo)
      assert cancelled.status == "cancelled"

      assert {:ok, rows} = Repo.list_temporal_reminders(%{event_id: event.id}, server: repo)
      assert Enum.sort(Enum.map(rows, & &1.status)) == ["cancelled", "delivered"]
    end

    test "an unknown event fails loudly", %{repo: repo} do
      assert {:error, :not_found} = Repo.cancel_temporal_event("evt_missing", @now, server: repo)
    end
  end

  describe "materialize_temporal_occurrences/5" do
    test "is idempotent through conflict-ignore inserts and advances the horizon", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, birthday_spec())

      later = ~U[2026-09-20 12:00:00Z]
      {:ok, plan} = Planner.materialize(birthday_spec(), later)

      assert {:ok, %{inserted: 2, event: advanced}} =
               Repo.materialize_temporal_occurrences(event.id, 1, plan_with_ids(plan), later,
                 server: repo
               )

      assert advanced.next_occurrence_on == ~D[2027-09-14]
      assert advanced.materialized_through_on == ~D[2028-09-14]

      assert {:ok, %{inserted: 0}} =
               Repo.materialize_temporal_occurrences(event.id, 1, plan_with_ids(plan), later,
                 server: repo
               )

      assert {:ok, rows} = Repo.list_temporal_reminders(%{event_id: event.id}, server: repo)
      assert length(rows) == 6
    end

    test "a stale revision writes nothing and says so", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, birthday_spec())

      {:ok, edit_plan} = Planner.materialize(birthday_spec(), @now)

      assert {:ok, {updated, _rows}} =
               Repo.update_temporal_event(
                 event.id,
                 %{title: "Sarah B"},
                 plan_with_ids(edit_plan),
                 @now,
                 server: repo
               )

      assert updated.revision == 2

      {:ok, plan} = Planner.materialize(birthday_spec(), ~U[2026-09-20 12:00:00Z])

      assert {:error, :stale_event_revision} =
               Repo.materialize_temporal_occurrences(
                 event.id,
                 1,
                 plan_with_ids(plan),
                 ~U[2026-09-20 12:00:00Z],
                 server: repo
               )

      assert {:ok, reread} = Repo.get_temporal_event(event.id, server: repo)
      assert reread.next_occurrence_on == ~D[2026-09-14]
    end

    test "an unknown event fails loudly", %{repo: repo} do
      {:ok, plan} = Planner.materialize(birthday_spec(), @now)

      assert {:error, :not_found} =
               Repo.materialize_temporal_occurrences("evt_missing", 1, plan_with_ids(plan), @now,
                 server: repo
               )
    end
  end

  describe "claim_due_reminders/3" do
    test "claims only due, unexpired, pending rows and consumes an attempt", %{repo: repo} do
      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())

      assert {:ok, []} = Repo.claim_due_reminders(@now, 10, server: repo)

      due = ~U[2026-08-15 19:00:00Z]
      assert {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      assert claimed.reminder_rule_id == "hours_24_before"
      assert claimed.status == "delivering"
      assert claimed.attempt_count == 1

      assert {:ok, []} = Repo.claim_due_reminders(due, 10, server: repo)
    end

    test "honors the row limit and orders by ready_at", %{repo: repo} do
      {_attrs, _first_event, _rows} = create!(repo, appointment_spec())

      later =
        appointment_spec(%{title: "Second appointment", occurrence_at: ~U[2026-08-16 21:00:00Z]})

      {_attrs2, _second_event, _rows2} = create!(repo, later, %{dedupe_key: "dedupe-second"})

      due = ~U[2026-08-15 21:00:00Z]
      assert {:ok, [only]} = Repo.claim_due_reminders(due, 1, server: repo)
      assert only.scheduled_for == utc(~U[2026-08-15 19:00:00Z])

      assert {:ok, [next]} = Repo.claim_due_reminders(due, 1, server: repo)
      assert next.scheduled_for == utc(~U[2026-08-15 21:00:00Z])
    end

    test "does not claim a row past its validity boundary", %{repo: repo} do
      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())

      # 18:00Z is when the 1-hour rule becomes due, so the 24-hour row expired.
      assert {:ok, claimed} = Repo.claim_due_reminders(~U[2026-08-16 18:00:00Z], 10, server: repo)
      assert Enum.map(claimed, & &1.reminder_rule_id) == ["hour_1_before"]
    end

    test "does not claim rows of a cancelled event", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())
      assert {:ok, _} = Repo.cancel_temporal_event(event.id, @now, server: repo)

      assert {:ok, []} = Repo.claim_due_reminders(~U[2026-08-15 19:00:00Z], 10, server: repo)
    end

    test "never claims a sixth attempt", %{repo: repo} do
      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())
      due = ~U[2026-08-15 19:00:00Z]

      row_id =
        Enum.reduce(1..4, nil, fn attempt, _acc ->
          assert {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
          assert claimed.attempt_count == attempt

          assert {:ok, {:pending, _}} =
                   Repo.temporal_reminder_retry(claimed.id, due, "boom", due, server: repo)

          claimed.id
        end)

      assert {:ok, [fifth]} = Repo.claim_due_reminders(due, 10, server: repo)
      assert fifth.id == row_id
      assert fifth.attempt_count == 5

      # A retry at the cap terminalizes instead of parking an unclaimable row.
      assert {:ok, {:failed, failed}} =
               Repo.temporal_reminder_retry(fifth.id, due, "boom", due, server: repo)

      assert failed.status == "failed"
      assert {:ok, []} = Repo.claim_due_reminders(due, 10, server: repo)
    end
  end

  describe "settlement" do
    setup %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())
      due = ~U[2026-08-15 19:00:00Z]
      {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      %{event: event, claimed: claimed, due: due}
    end

    test "delivered requires a sent_at and is guarded on delivering", %{
      repo: repo,
      claimed: claimed,
      due: due
    } do
      assert {:ok, delivered} = Repo.temporal_reminder_delivered(claimed.id, due, server: repo)
      assert delivered.status == "delivered"
      assert delivered.sent_at == utc(due)

      assert {:error, :not_delivering} =
               Repo.temporal_reminder_delivered(claimed.id, due, server: repo)
    end

    test "retry moves ready_at forward inside the validity boundary", %{
      repo: repo,
      claimed: claimed,
      due: due
    } do
      next = DateTime.add(due, 60, :second)

      assert {:ok, {:pending, retried}} =
               Repo.temporal_reminder_retry(claimed.id, next, "econnrefused", due, server: repo)

      assert retried.status == "pending"
      assert retried.ready_at == utc(next)
      assert retried.last_error == "econnrefused"
      assert retried.attempt_count == 1

      assert {:error, :not_delivering} =
               Repo.temporal_reminder_retry(claimed.id, next, "econnrefused", due, server: repo)
    end

    test "a retry past the validity boundary expires the row instead of parking it", %{
      repo: repo,
      claimed: claimed,
      due: due
    } do
      assert {:ok, {:expired, expired}} =
               Repo.temporal_reminder_retry(
                 claimed.id,
                 ~U[2026-08-16 19:00:00Z],
                 "timeout",
                 due,
                 server: repo
               )

      assert expired.status == "expired"
      assert expired.last_error == "timeout"
    end

    test "failed is terminal and bounded", %{repo: repo, claimed: claimed, due: due} do
      assert {:ok, failed} =
               Repo.temporal_reminder_failed(claimed.id, "unauthorized", due, server: repo)

      assert failed.status == "failed"
      assert failed.failed_at == utc(due)
      assert failed.last_error == "unauthorized"

      assert {:error, :not_delivering} =
               Repo.temporal_reminder_failed(claimed.id, "unauthorized", due, server: repo)
    end

    test "an over-long last_error is refused rather than truncated", %{
      repo: repo,
      claimed: claimed,
      due: due
    } do
      assert {:error, {:invalid, :last_error, :too_long}} =
               Repo.temporal_reminder_failed(claimed.id, String.duplicate("e", 501), due,
                 server: repo
               )
    end

    test "recovery returns a crashed worker's row to pending with the attempt consumed", %{
      repo: repo,
      claimed: claimed,
      due: due
    } do
      next = DateTime.add(due, 5, :second)

      assert {:ok, {:pending, recovered}} =
               Repo.recover_delivering_reminder(claimed.id, next, "worker_crash", due,
                 server: repo
               )

      assert recovered.attempt_count == 1
      assert recovered.ready_at == utc(next)
    end

    test "recovery after settlement changes nothing", %{repo: repo, claimed: claimed, due: due} do
      assert {:ok, _} = Repo.temporal_reminder_delivered(claimed.id, due, server: repo)

      assert {:ok, {:settled, row}} =
               Repo.recover_delivering_reminder(claimed.id, due, "worker_crash", due,
                 server: repo
               )

      assert row.status == "delivered"
    end

    test "an unknown reminder fails loudly", %{repo: repo, due: due} do
      assert {:error, :not_found} =
               Repo.temporal_reminder_delivered("rem_missing", due, server: repo)

      assert {:error, :not_found} =
               Repo.recover_delivering_reminder("rem_missing", due, "x", due, server: repo)
    end
  end

  describe "sweep_delivering_reminders/2" do
    test "returns stranded rows to pending, terminalizes at the cap, and expires past validity",
         %{
           repo: repo
         } do
      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())
      due = ~U[2026-08-15 19:00:00Z]

      assert {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)

      assert {:ok, %{pending: [pending_id], failed: [], expired: []}} =
               Repo.sweep_delivering_reminders(due, server: repo)

      assert pending_id == claimed.id
      assert {:ok, reread} = Repo.get_temporal_reminder(claimed.id, server: repo)
      assert reread.status == "pending"
      assert reread.attempt_count == 1

      # A stranded row past its validity boundary is expired, not retried.
      assert {:ok, [again]} = Repo.claim_due_reminders(due, 10, server: repo)

      assert {:ok, %{expired: [expired_id], pending: [], failed: []}} =
               Repo.sweep_delivering_reminders(~U[2026-08-16 18:30:00Z], server: repo)

      assert expired_id == again.id
    end

    test "a stranded row at the attempt cap becomes failed", %{repo: repo} do
      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())
      due = ~U[2026-08-15 19:00:00Z]

      Enum.each(1..4, fn _attempt ->
        {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)

        {:ok, {:pending, _}} =
          Repo.temporal_reminder_retry(claimed.id, due, "boom", due, server: repo)
      end)

      assert {:ok, [fifth]} = Repo.claim_due_reminders(due, 10, server: repo)
      assert fifth.attempt_count == 5

      assert {:ok, %{failed: [failed_id], pending: [], expired: []}} =
               Repo.sweep_delivering_reminders(due, server: repo)

      assert failed_id == fifth.id
      assert {:ok, row} = Repo.get_temporal_reminder(fifth.id, server: repo)
      assert row.status == "failed"
      assert row.attempt_count == 5
    end

    test "an empty sweep reports nothing", %{repo: repo} do
      assert {:ok, %{pending: [], failed: [], expired: []}} =
               Repo.sweep_delivering_reminders(@now, server: repo)
    end
  end

  describe "reconcile_temporal_boundaries/4" do
    test "supersedes an earlier rule once a later rule is due", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      now = ~U[2026-08-16 18:05:00Z]

      assert {:ok, result} = Repo.reconcile_temporal_boundaries(now, nil, 20, server: repo)
      assert result.superseded != []
      assert result.expired == []

      assert {:ok, rows} = Repo.list_temporal_reminders(%{event_id: event.id}, server: repo)
      by_rule = Map.new(rows, &{&1.reminder_rule_id, &1})
      assert by_rule["hours_24_before"].status == "superseded"
      assert by_rule["hour_1_before"].status == "pending"
    end

    test "expires a row whose validity passed with no later rule due", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      now = ~U[2026-08-16 20:00:00Z]

      assert {:ok, result} = Repo.reconcile_temporal_boundaries(now, nil, 20, server: repo)
      assert length(result.expired ++ result.superseded) == 2

      assert {:ok, rows} = Repo.list_temporal_reminders(%{event_id: event.id}, server: repo)
      assert Enum.all?(rows, &(&1.status in ["expired", "superseded"]))
    end

    test "completes a passed one-time event only when every reminder is terminal", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      during = ~U[2026-08-16 18:30:00Z]
      assert {:ok, [claimed]} = Repo.claim_due_reminders(during, 10, server: repo)

      after_event = ~U[2026-08-16 20:00:00Z]

      assert {:ok, %{completed_events: []}} =
               Repo.reconcile_temporal_boundaries(after_event, nil, 20, server: repo)

      assert {:ok, _} = Repo.temporal_reminder_delivered(claimed.id, during, server: repo)

      assert {:ok, %{completed_events: [completed_id]}} =
               Repo.reconcile_temporal_boundaries(after_event, nil, 20, server: repo)

      assert completed_id == event.id
      assert {:ok, reread} = Repo.get_temporal_event(event.id, server: repo)
      assert reread.status == "completed"
      assert is_nil(reread.next_occurrence_on)
    end

    test "a date-only event completes only after its local day ends", %{repo: repo} do
      spec =
        appointment_spec(%{
          kind: "deadline",
          time_kind: "date",
          local_time: nil,
          occurrence_at: nil,
          reminder_plan: []
        })

      {_attrs, event, _occurrences} = create!(repo, spec)

      # 2026-08-16 23:00 local is still inside the event's day.
      assert {:ok, %{completed_events: []}} =
               Repo.reconcile_temporal_boundaries(~U[2026-08-17 03:00:00Z], nil, 20, server: repo)

      assert {:ok, %{completed_events: [id]}} =
               Repo.reconcile_temporal_boundaries(~U[2026-08-17 05:00:00Z], nil, 20, server: repo)

      assert id == event.id
    end

    test "a yearly event never auto-completes", %{repo: repo} do
      {_attrs, _event, _occurrences} = create!(repo, birthday_spec())

      assert {:ok, %{completed_events: []}} =
               Repo.reconcile_temporal_boundaries(~U[2030-01-01 00:00:00Z], nil, 20, server: repo)
    end

    test "pages with a keyset cursor and wraps when the page is short", %{repo: repo} do
      Enum.each(1..3, fn index ->
        spec =
          appointment_spec(%{
            title: "Appointment #{index}",
            local_date: ~D[2026-08-16],
            occurrence_at: DateTime.add(~U[2026-08-16 19:00:00Z], index * 3600, :second)
          })

        {_attrs, _event, _rows} = create!(repo, spec, %{dedupe_key: "dedupe-#{index}"})
      end)

      now = ~U[2026-08-17 12:00:00Z]

      assert {:ok, first} = Repo.reconcile_temporal_boundaries(now, nil, 4, server: repo)
      assert length(first.expired ++ first.superseded) == 4
      assert first.cursor != nil

      assert {:ok, second} =
               Repo.reconcile_temporal_boundaries(now, first.cursor, 4, server: repo)

      assert length(second.expired ++ second.superseded) == 2
      assert is_nil(second.cursor)

      assert {:ok, rows} = Repo.list_temporal_reminders(%{}, server: repo)
      assert Enum.all?(rows, &(&1.status in ["expired", "superseded"]))
    end
  end

  describe "annual_horizon_events/4" do
    test "returns yearly events behind the horizon and pages by keyset", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, birthday_spec())

      assert {:ok, %{events: [], cursor: nil}} =
               Repo.annual_horizon_events(~D[2027-08-02], nil, 20, server: repo)

      assert {:ok, %{events: [behind]}} =
               Repo.annual_horizon_events(~D[2027-09-15], nil, 20, server: repo)

      assert behind.id == event.id
    end

    test "skips cancelled and one-time events", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, birthday_spec())
      {_attrs2, _once, _rows} = create!(repo, appointment_spec())
      assert {:ok, _} = Repo.cancel_temporal_event(event.id, @now, server: repo)

      assert {:ok, %{events: []}} =
               Repo.annual_horizon_events(~D[2030-01-01], nil, 20, server: repo)
    end
  end

  describe "reads" do
    test "next_pending_reminder_ready_at returns the earliest claimable instant", %{repo: repo} do
      assert {:ok, nil} = Repo.next_pending_reminder_ready_at(@now, server: repo)

      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())

      assert {:ok, ready_at} = Repo.next_pending_reminder_ready_at(@now, server: repo)
      assert ready_at == utc(~U[2026-08-15 19:00:00Z])
    end

    test "next_pending_reminder_ready_at skips rows past their validity boundary", %{repo: repo} do
      # The predicate that keeps the due timer honest: a row the claim would
      # refuse must not set the alarm, or the tick it wakes claims nothing and
      # re-arms at 0ms for as long as the row survives.
      {_attrs, _event, _occurrences} = create!(repo, appointment_spec())

      # 18:00Z is when the 1-hour rule becomes due, so the 24-hour row is past
      # its validity boundary and only the later rule is claimable.
      assert {:ok, ready_at} =
               Repo.next_pending_reminder_ready_at(~U[2026-08-16 18:00:00Z], server: repo)

      assert ready_at == utc(~U[2026-08-16 18:00:00Z])

      assert {:ok, nil} =
               Repo.next_pending_reminder_ready_at(~U[2026-08-16 19:00:00Z], server: repo)
    end

    test "get_temporal_event returns the parsed row or not_found", %{repo: repo} do
      {_attrs, event, _occurrences} = create!(repo, appointment_spec())

      assert {:ok, row} = Repo.get_temporal_event(event.id, server: repo)
      assert row.local_date == ~D[2026-08-16]
      assert row.local_time == ~T[15:00:00]
      assert row.timezone == @tz
      assert row.delivery_platform == "telegram"
      assert row.created_by_origin == "interactive"

      assert {:error, :not_found} = Repo.get_temporal_event("evt_missing", server: repo)
    end

    test "list_temporal_events filters, caps, and reports delivery state", %{repo: repo} do
      {_attrs, birthday, _rows} = create!(repo, birthday_spec())

      {_attrs2, appointment, _rows2} =
        create!(repo, appointment_spec(), %{dedupe_key: "dedupe-appointment"})

      due = ~U[2026-08-15 19:00:00Z]
      {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      {:ok, _} = Repo.temporal_reminder_failed(claimed.id, "unauthorized", due, server: repo)

      assert {:ok, %{events: events, cursor: nil}} = Repo.list_temporal_events(%{}, server: repo)
      assert Enum.map(events, & &1.id) == [appointment.id, birthday.id]

      failed = hd(events)
      assert failed.last_delivery_status == "failed"
      assert failed.last_delivery_error == "unauthorized"
      assert failed.next_reminder_at == utc(~U[2026-08-16 18:00:00Z])

      assert {:ok, %{events: [only]}} =
               Repo.list_temporal_events(%{kind: "birthday"}, server: repo)

      assert only.id == birthday.id

      assert {:ok, %{events: [found]}} =
               Repo.list_temporal_events(%{text: "dentist"}, server: repo)

      assert found.id == appointment.id

      assert {:ok, %{events: windowed}} =
               Repo.list_temporal_events(%{from: ~D[2026-08-01], to: ~D[2026-08-31]},
                 server: repo
               )

      assert Enum.map(windowed, & &1.id) == [appointment.id]
    end

    test "list_temporal_events floors on upcoming_from but never hides a NULL occurrence", %{
      repo: repo,
      db_path: db_path
    } do
      {_attrs, passed, _rows} = create!(repo, at_time_spec())

      {_attrs2, uncached, _rows2} =
        create!(repo, at_time_spec(%{title: "No horizon"}), %{dedupe_key: uid("dedupe")})

      raw_execute(
        db_path,
        "UPDATE temporal_events SET next_occurrence_on = NULL WHERE id = '#{uncached.id}';"
      )

      assert {:ok, %{events: floored}} =
               Repo.list_temporal_events(%{upcoming_from: "2026-08-20"}, server: repo)

      # The passed row is out of the default window; the row whose cache is
      # unexpectedly missing stays visible rather than being silently dropped.
      ids = Enum.map(floored, & &1.id)
      refute passed.id in ids
      assert uncached.id in ids

      assert {:ok, %{events: unfloored}} = Repo.list_temporal_events(%{}, server: repo)
      assert passed.id in Enum.map(unfloored, & &1.id)
    end

    test "list_temporal_events pages with an opaque keyset cursor", %{repo: repo} do
      {_a, birthday, _r} = create!(repo, birthday_spec())
      {_b, appointment, _r2} = create!(repo, appointment_spec(), %{dedupe_key: "dedupe-appt"})

      assert {:ok, %{events: [first], cursor: cursor}} =
               Repo.list_temporal_events(%{limit: 1}, server: repo)

      assert first.id == appointment.id
      assert cursor != nil

      assert {:ok, %{events: [second], cursor: _}} =
               Repo.list_temporal_events(%{limit: 1, cursor: cursor}, server: repo)

      assert second.id == birthday.id
    end

    test "list_temporal_events refuses an over-wide date window and clamps the limit", %{
      repo: repo
    } do
      assert {:error, :date_window_too_wide} =
               Repo.list_temporal_events(%{from: ~D[2026-01-01], to: ~D[2029-01-01]},
                 server: repo
               )

      assert {:error, :invalid_date_window} =
               Repo.list_temporal_events(%{from: ~D[2026-06-01], to: ~D[2026-01-01]},
                 server: repo
               )

      assert {:ok, %{events: []}} = Repo.list_temporal_events(%{limit: 5_000}, server: repo)
    end

    test "list_temporal_events defaults to active events", %{repo: repo} do
      {_attrs, event, _rows} = create!(repo, appointment_spec())
      assert {:ok, _} = Repo.cancel_temporal_event(event.id, @now, server: repo)

      assert {:ok, %{events: []}} = Repo.list_temporal_events(%{}, server: repo)

      assert {:ok, %{events: [cancelled]}} =
               Repo.list_temporal_events(%{status: "cancelled"}, server: repo)

      assert cancelled.id == event.id
    end

    test "a non-string text filter is refused at the boundary, never inside the writer", %{
      repo: repo
    } do
      # `event_list` copies `text` verbatim out of model JSON. An unvalidated
      # non-string reaches the LIKE-escaper inside the single writer and takes
      # the Repo — and, under `:rest_for_one`, the whole lower half of the
      # application tree — down with it.
      writer = Process.whereis(repo)
      ref = Process.monitor(writer)

      assert {:error, {:invalid, :text, :not_a_string}} =
               Repo.list_temporal_events(%{text: 123}, server: repo)

      assert {:error, {:invalid, :text, :not_a_string}} =
               Repo.list_temporal_events(%{text: %{"a" => 1}}, server: repo)

      refute_receive {:DOWN, ^ref, :process, ^writer, _reason}, 100
      assert {:ok, %{events: []}} = Repo.list_temporal_events(%{}, server: repo)
    end
  end

  describe "a failed reminder is scoped to its own row" do
    test "failing this year's birthday leaves the event, its sibling rule, and next year alone",
         %{repo: repo} do
      # §18.1 / §18.5 acceptance #5: one failed delivery must not disable the
      # rest of the plan, and a birthday must survive it forever.
      {_attrs, event, occurrences} = create!(repo, birthday_spec())

      week_before =
        Enum.find(
          occurrences,
          &(&1.reminder_rule_id == "week_before" and &1.occurrence_key == "2026-09-14")
        )

      due = week_before.scheduled_for
      assert {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      assert claimed.id == week_before.id

      assert {:ok, failed} =
               Repo.temporal_reminder_failed(claimed.id, "permanent:authentication", due,
                 server: repo
               )

      assert failed.status == "failed"

      assert {:ok, still_active} = Repo.get_temporal_event(event.id, server: repo)
      assert still_active.status == "active"
      assert still_active.next_occurrence_on == ~D[2026-09-14]

      day_of_due = ~U[2026-09-14 13:00:00Z]
      assert {:ok, [next_rule]} = Repo.claim_due_reminders(day_of_due, 10, server: repo)
      assert next_rule.reminder_rule_id == "day_of"
      assert next_rule.occurrence_key == "2026-09-14"

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: event.id, status: ["pending"]},
                 server: repo
               )

      assert Enum.uniq(Enum.map(rows, & &1.occurrence_key)) == ["2027-09-14"]
      assert length(rows) == 2
    end
  end

  # --- snooze (MILESTONE_30 §20) -------------------------------------------

  # One reminder rule exactly at the event instant, so a test that needs a
  # single deterministic row does not have to pick one out of a default plan.
  defp at_time_spec(overrides \\ %{}) do
    appointment_spec(
      Map.merge(
        %{reminder_plan: [%{rule_id: "at_time", kind: :at_occurrence}]},
        overrides
      )
    )
  end

  defp snooze_attrs(source, overrides \\ %{}) do
    Map.merge(
      %{
        id: uid("rem"),
        source_reminder_id: source.id,
        scheduled_for: DateTime.add(source.scheduled_for, 7_200, :second),
        valid_until: DateTime.add(source.scheduled_for, 14_400, :second),
        owner_id: "default",
        selection: :explicit
      },
      overrides
    )
  end

  # Creates one at-time event, claims its single row, and settles it delivered.
  defp delivered!(repo, overrides \\ %{}, sent_at \\ ~U[2026-08-16 19:00:00Z]) do
    {_attrs, event, [row]} =
      create!(repo, at_time_spec(), Map.merge(%{dedupe_key: uid("dedupe")}, overrides))

    {:ok, claimed} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)
    target = Enum.find(claimed, &(&1.id == row.id))
    {:ok, delivered} = Repo.temporal_reminder_delivered(target.id, sent_at, server: repo)
    {event, delivered}
  end

  describe "migration v18 (snooze columns)" do
    test "adds the source link and its three indexes", %{repo: repo, db_path: db_path} do
      assert :ok = Repo.migrate(server: repo)

      columns =
        raw_column(db_path, "SELECT name FROM pragma_table_info('reminder_occurrences')")

      assert "source_reminder_id" in columns
      # Appended, never inserted mid-body, so a migrated database and a fresh one
      # agree on column order.
      assert List.last(columns) == "source_reminder_id"

      indexes =
        raw_column(
          db_path,
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'reminder_occurrences'"
        )

      assert "idx_reminder_occurrences_snooze_dedupe" in indexes
      assert "idx_reminder_occurrences_snooze_source" in indexes
      assert "idx_reminder_occurrences_target_sent" in indexes
    end

    # The property the ALTER exists for, asserted as a comparison rather than by
    # inspection: a database that reached these columns by migrating an existing
    # v17 one must end up byte-identical in column ORDER to a database created
    # today. `reminder_occurrences` is read positionally, so a mid-body column
    # would silently corrupt every row on an upgraded host.
    test "replaying v18 against a v17 database matches a fresh one exactly", %{
      repo: repo,
      db_path: db_path
    } do
      assert :ok = Repo.migrate(server: repo)
      fresh = raw_column(db_path, @reminder_columns_sql)
      assert "source_reminder_id" in fresh

      rewind_to_v17!(db_path)

      rewound = raw_column(db_path, @reminder_columns_sql)
      refute "source_reminder_id" in rewound
      assert Enum.all?(@snooze_indexes, &(&1 not in raw_column(db_path, @reminder_indexes_sql)))

      assert :ok = Repo.migrate(server: repo)

      assert raw_column(db_path, @reminder_columns_sql) == fresh
      indexes = raw_column(db_path, @reminder_indexes_sql)
      assert Enum.all?(@snooze_indexes, &(&1 in indexes))
    end

    test "an ordinary planner row carries no source link", %{repo: repo} do
      {_attrs, _event, [row]} = create!(repo, at_time_spec())

      assert is_nil(row.source_reminder_id)
    end
  end

  describe "snooze_temporal_reminder/3" do
    test "creates a source-linked row that copies the source's target and payload", %{repo: repo} do
      {event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, snoozed, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      assert snoozed.id == attrs.id
      assert snoozed.source_reminder_id == source.id
      assert snoozed.event_id == source.event_id
      assert snoozed.event_revision == event.revision
      assert snoozed.occurrence_key == source.occurrence_key
      assert snoozed.event_occurrence_at == source.event_occurrence_at
      assert snoozed.payload == source.payload
      assert snoozed.delivery_platform == source.delivery_platform
      assert snoozed.delivery_destination == source.delivery_destination
      assert snoozed.delivery_thread_scope == source.delivery_thread_scope
      assert snoozed.status == "pending"
      assert snoozed.attempt_count == 0
      assert snoozed.ready_at == utc(attrs.scheduled_for)
      assert snoozed.scheduled_for == utc(attrs.scheduled_for)
      assert snoozed.valid_until == utc(attrs.valid_until)
      assert snoozed.reminder_rule_id =~ "snooze:#{source.id}:"
    end

    test "an identical re-snooze returns the existing row and writes nothing", %{repo: repo} do
      {_event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      assert {:ok, {:existing, again}} =
               Repo.snooze_temporal_reminder(
                 Map.put(attrs, :id, uid("rem")),
                 @now,
                 server: repo
               )

      assert again.id == first.id

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: source.event_id}, server: repo)

      assert length(Enum.filter(rows, &(&1.source_reminder_id == source.id))) == 1
    end

    test "a different time supersedes the prior pending snooze, leaving exactly one active", %{
      repo: repo
    } do
      {_event, source} = delivered!(repo)
      first_attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(first_attrs, @now, server: repo)

      later =
        snooze_attrs(source, %{
          scheduled_for: DateTime.add(source.scheduled_for, 10_800, :second),
          valid_until: DateTime.add(source.scheduled_for, 18_000, :second)
        })

      assert {:ok, {:created, second, [superseded_id]}} =
               Repo.snooze_temporal_reminder(later, @now, server: repo)

      assert superseded_id == first.id

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: source.event_id}, server: repo)

      snoozes = Enum.filter(rows, &(&1.source_reminder_id == source.id))
      assert length(snoozes) == 2
      assert Enum.count(snoozes, &(&1.status == "pending")) == 1
      assert Enum.find(snoozes, &(&1.id == first.id)).status == "superseded"
      assert Enum.find(snoozes, &(&1.id == second.id)).status == "pending"

      # The delivered source's own history is untouched by either snooze.
      assert {:ok, reread} = Repo.get_temporal_reminder(source.id, server: repo)
      assert reread.status == "delivered"
      assert reread.sent_at == utc(~U[2026-08-16 19:00:00Z])
    end

    test "an explicitly selected pending source is superseded and reported", %{repo: repo} do
      {_attrs, _event, [source]} = create!(repo, at_time_spec())

      # Every row this transaction retires comes back, so each one is traceable.
      assert {:ok, {:created, _snoozed, [retired]}} =
               Repo.snooze_temporal_reminder(snooze_attrs(source), @now, server: repo)

      assert retired == source.id
      assert {:ok, reread} = Repo.get_temporal_reminder(source.id, server: repo)
      assert reread.status == "superseded"
    end

    test "a resolved (non-explicit) pending source is left pending", %{repo: repo} do
      {_attrs, _event, [source]} = create!(repo, at_time_spec())

      assert {:ok, {:created, _snoozed, []}} =
               Repo.snooze_temporal_reminder(
                 snooze_attrs(source, %{selection: :resolved}),
                 @now,
                 server: repo
               )

      assert {:ok, reread} = Repo.get_temporal_reminder(source.id, server: repo)
      assert reread.status == "pending"
    end

    test "a failed source is refused", %{repo: repo} do
      {_attrs, _event, [row]} = create!(repo, at_time_spec())
      due = row.scheduled_for
      {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)
      {:ok, failed} = Repo.temporal_reminder_failed(claimed.id, "unauthorized", due, server: repo)

      assert {:error, :source_terminal} =
               Repo.snooze_temporal_reminder(snooze_attrs(failed), @now, server: repo)
    end

    test "an expired source is refused", %{repo: repo} do
      {_attrs, _event, [row]} = create!(repo, at_time_spec())
      due = row.scheduled_for
      {:ok, [claimed]} = Repo.claim_due_reminders(due, 10, server: repo)

      {:ok, {:expired, expired}} =
        Repo.temporal_reminder_retry(claimed.id, row.valid_until, "timeout", due, server: repo)

      assert {:error, :source_terminal} =
               Repo.snooze_temporal_reminder(snooze_attrs(expired), @now, server: repo)
    end

    test "a cancelled source is refused", %{repo: repo} do
      {_attrs, event, [source]} = create!(repo, at_time_spec())
      {:ok, _cancelled} = Repo.cancel_temporal_event(event.id, @now, server: repo)
      {:ok, row} = Repo.get_temporal_reminder(source.id, server: repo)
      assert row.status == "cancelled"

      # The parent guard fires first for a cancelled event; a cancelled row under
      # an active parent is the terminal case.
      assert {:error, :parent_cancelled} =
               Repo.snooze_temporal_reminder(snooze_attrs(row), @now, server: repo)
    end

    test "a delivering source is refused", %{repo: repo} do
      {_attrs, _event, [row]} = create!(repo, at_time_spec())
      {:ok, [claimed]} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)

      assert {:error, :source_delivering} =
               Repo.snooze_temporal_reminder(snooze_attrs(claimed), @now, server: repo)
    end

    test "an unknown source is not_found", %{repo: repo} do
      {_event, source} = delivered!(repo)

      assert {:error, :not_found} =
               Repo.snooze_temporal_reminder(
                 snooze_attrs(source, %{source_reminder_id: "rem_missing"}),
                 @now,
                 server: repo
               )
    end

    test "another owner's reminder is not addressable", %{repo: repo} do
      {_event, source} = delivered!(repo, %{owner_id: "someone_else"})

      assert {:error, :not_found} =
               Repo.snooze_temporal_reminder(snooze_attrs(source), @now, server: repo)
    end

    test "a cancelled twin at the same instant is REVIVED, never acknowledged as live", %{
      repo: repo
    } do
      {event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      # An event edit bumps the revision and cancels every pending row of the
      # older one — the snooze row included.
      {:ok, plan} = Planner.materialize(at_time_spec(%{title: "Moved"}), @now)

      {:ok, {updated, _rows}} =
        Repo.update_temporal_event(event.id, %{title: "Moved"}, plan_with_ids(plan), @now,
          server: repo
        )

      assert {:ok, corpse} = Repo.get_temporal_reminder(first.id, server: repo)
      assert corpse.status == "cancelled"

      # The identical re-snooze must hand back a row the scheduler can claim.
      assert {:ok, {:created, revived, []}} =
               Repo.snooze_temporal_reminder(Map.put(attrs, :id, uid("rem")), @now, server: repo)

      assert revived.id == first.id
      assert revived.status == "pending"
      assert revived.attempt_count == 0
      assert revived.event_revision == updated.revision
      assert revived.ready_at == revived.scheduled_for
      assert revived.valid_until == utc(attrs.valid_until)

      assert {:ok, claimed} =
               Repo.claim_due_reminders(attrs.scheduled_for, 10, server: repo)

      assert Enum.any?(claimed, &(&1.id == first.id))
    end

    test "a failed twin is revived with its attempts and error cleared", %{repo: repo} do
      {_event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      {:ok, [claimed]} = Repo.claim_due_reminders(first.scheduled_for, 10, server: repo)

      {:ok, failed} =
        Repo.temporal_reminder_failed(claimed.id, "permanent:authentication", first.scheduled_for,
          server: repo
        )

      assert failed.status == "failed"

      assert {:ok, {:created, revived, []}} =
               Repo.snooze_temporal_reminder(Map.put(attrs, :id, uid("rem")), @now, server: repo)

      assert revived.id == first.id
      assert revived.status == "pending"
      assert revived.attempt_count == 0
      assert is_nil(revived.last_error)
      assert is_nil(revived.failed_at)
    end

    test "a superseded twin is revived and the snooze that replaced it is retired", %{repo: repo} do
      {_event, source} = delivered!(repo)
      early = snooze_attrs(source)

      later =
        snooze_attrs(source, %{
          scheduled_for: DateTime.add(source.scheduled_for, 10_800, :second),
          valid_until: DateTime.add(source.scheduled_for, 18_000, :second)
        })

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(early, @now, server: repo)

      assert {:ok, {:created, second, [_superseded]}} =
               Repo.snooze_temporal_reminder(later, @now, server: repo)

      assert {:ok, {:created, revived, [retired]}} =
               Repo.snooze_temporal_reminder(Map.put(early, :id, uid("rem")), @now, server: repo)

      assert revived.id == first.id
      assert revived.status == "pending"
      assert retired == second.id

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: source.event_id}, server: repo)

      snoozes = Enum.filter(rows, &(&1.source_reminder_id == source.id))
      assert Enum.count(snoozes, &(&1.status == "pending")) == 1
      assert Enum.find(snoozes, &(&1.id == second.id)).status == "superseded"
    end

    test "a pending twin at the same instant is still returned untouched", %{repo: repo} do
      {_event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      assert {:ok, {:existing, again}} =
               Repo.snooze_temporal_reminder(Map.put(attrs, :id, uid("rem")), @now, server: repo)

      assert again.id == first.id
      assert again.status == "pending"
    end

    test "a twin mid-send at the same instant is reported as existing, not revived", %{repo: repo} do
      {_event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      {:ok, [claimed]} = Repo.claim_due_reminders(first.scheduled_for, 10, server: repo)
      assert claimed.status == "delivering"

      assert {:ok, {:existing, again}} =
               Repo.snooze_temporal_reminder(Map.put(attrs, :id, uid("rem")), @now, server: repo)

      assert again.id == first.id
      assert again.status == "delivering"
    end

    test "a sibling snooze mid-send refuses the whole call and writes nothing", %{repo: repo} do
      {_event, source} = delivered!(repo)
      first_attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(first_attrs, @now, server: repo)

      {:ok, [claimed]} = Repo.claim_due_reminders(first.scheduled_for, 10, server: repo)
      assert claimed.status == "delivering"

      later =
        snooze_attrs(source, %{
          scheduled_for: DateTime.add(source.scheduled_for, 10_800, :second),
          valid_until: DateTime.add(source.scheduled_for, 18_000, :second)
        })

      assert {:error, :snooze_delivery_in_progress} =
               Repo.snooze_temporal_reminder(later, @now, server: repo)

      # The in-flight row is untouched and no second row was written.
      assert {:error, :not_found} = Repo.get_temporal_reminder(later.id, server: repo)
      assert {:ok, reread} = Repo.get_temporal_reminder(first.id, server: repo)
      assert reread.status == "delivering"
    end

    # One active snooze per source makes a full supersede page impossible, so a
    # full page means the invariant broke. It is logged loudly and every pending
    # row is still retired — never quietly paged over.
    test "a full supersede page is reported as the broken invariant it is", %{
      repo: repo,
      db_path: db_path
    } do
      {_event, source} = delivered!(repo)

      instants =
        Enum.map(1..10, fn step ->
          snooze_attrs(source, %{
            scheduled_for: DateTime.add(source.scheduled_for, step * 3_600, :second),
            valid_until: DateTime.add(source.scheduled_for, (step + 2) * 3_600, :second)
          })
        end)

      Enum.each(instants, fn attrs ->
        assert {:ok, {:created, _row, _superseded}} =
                 Repo.snooze_temporal_reminder(attrs, @now, server: repo)
      end)

      # Force the impossible state directly: ten live snoozes of one source.
      raw_execute(
        db_path,
        "UPDATE reminder_occurrences SET status = 'pending' " <>
          "WHERE source_reminder_id = '#{source.id}';"
      )

      eleventh =
        snooze_attrs(source, %{
          scheduled_for: DateTime.add(source.scheduled_for, 40_000, :second),
          valid_until: DateTime.add(source.scheduled_for, 47_200, :second)
        })

      log =
        capture_log(fn ->
          assert {:ok, {:created, created, superseded}} =
                   Repo.snooze_temporal_reminder(eleventh, @now, server: repo)

          assert length(superseded) == 10
          assert created.status == "pending"
        end)

      assert log =~ "one-active-snooze invariant is broken"
      assert log =~ source.id

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: source.event_id}, server: repo)

      snoozes = Enum.filter(rows, &(&1.source_reminder_id == source.id))
      assert Enum.count(snoozes, &(&1.status == "pending")) == 1
    end

    # Unreachable through the Registry, whose `:snooze_in_past` guard refuses a
    # past instant — and a delivered row's instant is always past. Reached here
    # by calling the Repo directly, because an impossible state must fail the
    # call rather than crash the single writer and every `:rest_for_one` child
    # behind it.
    test "a delivered twin is refused without taking the writer down", %{repo: repo} do
      {_event, source} = delivered!(repo)
      attrs = snooze_attrs(source)

      assert {:ok, {:created, first, []}} =
               Repo.snooze_temporal_reminder(attrs, @now, server: repo)

      {:ok, [claimed]} = Repo.claim_due_reminders(first.scheduled_for, 10, server: repo)

      {:ok, _sent} =
        Repo.temporal_reminder_delivered(claimed.id, first.scheduled_for, server: repo)

      assert {:error, {:snooze_twin_unexpected_status, "delivered"}} =
               Repo.snooze_temporal_reminder(Map.put(attrs, :id, uid("rem")), @now, server: repo)

      assert {:ok, still_serving} = Repo.get_temporal_reminder(first.id, server: repo)
      assert still_serving.status == "delivered"
    end

    test "the snooze row carries the parent's CURRENT revision", %{repo: repo} do
      {_attrs, event, [source]} = create!(repo, at_time_spec())

      {:ok, plan} = Planner.materialize(at_time_spec(%{title: "Moved"}), @now)

      {:ok, {updated, _rows}} =
        Repo.update_temporal_event(event.id, %{title: "Moved"}, plan_with_ids(plan), @now,
          server: repo
        )

      assert updated.revision == 2
      assert {:ok, stale} = Repo.get_temporal_reminder(source.id, server: repo)
      assert stale.event_revision == 1

      # The source row is cancelled by the revision bump, so a still-live sibling
      # from the new revision is the snooze source.
      {:ok, current} =
        Repo.list_temporal_reminders(%{event_id: event.id, status: ["pending"]}, server: repo)

      assert {:ok, {:created, snoozed, _}} =
               Repo.snooze_temporal_reminder(snooze_attrs(hd(current)), @now, server: repo)

      assert snoozed.event_revision == 2
    end
  end

  describe "snooze reactivation of a completed one-time parent" do
    test "restores next_occurrence_on, delivers, and reconciliation re-completes it", %{
      repo: repo
    } do
      {event, source} = delivered!(repo)

      after_event = ~U[2026-08-16 21:30:00Z]

      assert {:ok, %{completed_events: [completed_id]}} =
               Repo.reconcile_temporal_boundaries(after_event, nil, 20, server: repo)

      assert completed_id == event.id
      assert {:ok, done} = Repo.get_temporal_event(event.id, server: repo)
      assert done.status == "completed"
      assert is_nil(done.next_occurrence_on)

      attrs =
        snooze_attrs(source, %{
          scheduled_for: ~U[2026-08-16 22:00:00Z],
          valid_until: ~U[2026-08-17 00:00:00Z]
        })

      assert {:ok, {:created, snoozed, []}} =
               Repo.snooze_temporal_reminder(attrs, after_event, server: repo)

      assert {:ok, reactivated} = Repo.get_temporal_event(event.id, server: repo)
      assert reactivated.status == "active"
      # Restored to the snooze row's occurrence date, NOT left NULL: the
      # completion scan pre-filters on next_occurrence_on, so a NULL would leave
      # the event active forever once the snooze terminated.
      assert reactivated.next_occurrence_on == Date.from_iso8601!(snoozed.occurrence_key)

      assert {:ok, [claimed]} =
               Repo.claim_due_reminders(~U[2026-08-16 22:00:00Z], 10, server: repo)

      assert claimed.id == snoozed.id

      assert {:ok, _} =
               Repo.temporal_reminder_delivered(claimed.id, ~U[2026-08-16 22:00:01Z],
                 server: repo
               )

      assert {:ok, %{completed_events: [again]}} =
               Repo.reconcile_temporal_boundaries(~U[2026-08-17 02:00:00Z], nil, 20, server: repo)

      assert again == event.id
      assert {:ok, recompleted} = Repo.get_temporal_event(event.id, server: repo)
      assert recompleted.status == "completed"
      assert is_nil(recompleted.next_occurrence_on)
    end

    test "a reactivation dedupe conflict fails the whole transaction with no snooze row", %{
      repo: repo
    } do
      {event, source} = delivered!(repo, %{dedupe_key: "shared-identity"})

      after_event = ~U[2026-08-16 21:30:00Z]

      {:ok, %{completed_events: [_id]}} =
        Repo.reconcile_temporal_boundaries(after_event, nil, 20, server: repo)

      # A NEW active event now owns that identity; reactivating the completed one
      # would violate the active-dedupe partial unique index.
      {_attrs, _twin, _rows} =
        create!(repo, at_time_spec(%{title: "Replacement"}), %{dedupe_key: "shared-identity"})

      attrs =
        snooze_attrs(source, %{
          scheduled_for: ~U[2026-08-16 22:00:00Z],
          valid_until: ~U[2026-08-17 00:00:00Z]
        })

      assert {:error, :dedupe_conflict} =
               Repo.snooze_temporal_reminder(attrs, after_event, server: repo)

      assert {:error, :not_found} = Repo.get_temporal_reminder(attrs.id, server: repo)
      assert {:ok, still_completed} = Repo.get_temporal_event(event.id, server: repo)
      assert still_completed.status == "completed"
    end

    test "an active parent is not touched", %{repo: repo} do
      {event, source} = delivered!(repo)

      assert {:ok, {:created, _snoozed, []}} =
               Repo.snooze_temporal_reminder(snooze_attrs(source), @now, server: repo)

      assert {:ok, unchanged} = Repo.get_temporal_event(event.id, server: repo)
      assert unchanged.status == "active"
      assert unchanged.next_occurrence_on == ~D[2026-08-16]
    end
  end

  describe "latest_delivered_reminder/2" do
    setup %{repo: repo} do
      {_event, older} =
        delivered!(
          repo,
          %{delivery_destination: "chat-1"},
          ~U[2026-08-16 19:00:00Z]
        )

      {_event2, newer} =
        delivered!(
          repo,
          %{delivery_destination: "chat-1"},
          ~U[2026-08-16 20:00:00Z]
        )

      %{older: older, newer: newer}
    end

    defp target(overrides \\ %{}) do
      Map.merge(
        %{
          platform: "telegram",
          destination: "chat-1",
          thread_scope: "root",
          owner_id: "default",
          since: ~U[2026-08-15 21:00:00Z]
        },
        overrides
      )
    end

    test "returns the most recent delivered row in the exact target", %{repo: repo, newer: newer} do
      assert {:ok, row} =
               Repo.latest_delivered_reminder(target(), server: repo)

      assert row.id == newer.id
    end

    test "never crosses platform, destination, thread, owner, or the lookback", %{repo: repo} do
      for override <- [
            %{platform: "slack"},
            %{destination: "chat-2"},
            %{thread_scope: "17"},
            %{owner_id: "someone_else"},
            %{since: ~U[2026-08-16 20:30:00Z]}
          ] do
        assert {:ok, nil} = Repo.latest_delivered_reminder(target(override), server: repo),
               "resolution crossed #{inspect(override)}"
      end
    end

    test "a near-miss row in another thread of the same chat is not matched", %{repo: repo} do
      {_event, threaded} =
        delivered!(
          repo,
          %{delivery_destination: "chat-1", delivery_thread_scope: "17"},
          ~U[2026-08-16 21:00:00Z]
        )

      assert {:ok, root_row} = Repo.latest_delivered_reminder(target(), server: repo)
      refute root_row.id == threaded.id

      assert {:ok, thread_row} =
               Repo.latest_delivered_reminder(target(%{thread_scope: "17"}), server: repo)

      assert thread_row.id == threaded.id
    end

    test "a pending or failed row is never resolvable", %{repo: repo} do
      {_attrs, _event, [pending]} =
        create!(repo, at_time_spec(), %{
          dedupe_key: uid("dedupe"),
          delivery_destination: "chat-9"
        })

      assert pending.status == "pending"

      assert {:ok, nil} =
               Repo.latest_delivered_reminder(target(%{destination: "chat-9"}), server: repo)
    end
  end

  # Rebuilds `reminder_occurrences` in its pre-v18 shape from the SAME DDL the
  # v17 migration applies — a hand-copied fixture would rot the moment that
  # schema changes — and drops the v18 marker so the next migrate replays the
  # ALTER an existing operator database takes.
  defp rewind_to_v17!(db_path) do
    assert :ok =
             raw_execute(db_path, """
             DROP TABLE reminder_occurrences;
             #{TemporalSql.schema_sql()}
             DELETE FROM schema_migrations WHERE version = 18;
             """)
  end

  defp raw_execute(db_path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readwrite)

    try do
      Exqlite.Sqlite3.execute(conn, sql)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp raw_column(db_path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readwrite)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      Enum.map(rows, fn [value] -> value end)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end
end
