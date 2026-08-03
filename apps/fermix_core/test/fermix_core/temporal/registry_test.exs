defmodule FermixCore.Temporal.RegistryTest do
  # async: true — every seam (repo server, clock, jobs config, personalization,
  # scheduler) is injected; nothing reads or mutates host/global state.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Registry

  @tz "America/New_York"
  @now ~U[2026-08-02 12:00:00Z]

  defmodule FakeAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  defmodule FakeScheduler do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :test_pid),
        name: Keyword.fetch!(opts, :name)
      )
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast(message, test_pid) do
      send(test_pid, {:scheduler_cast, message})
      {:noreply, test_pid}
    end
  end

  @channels %{
    "telegram" => FakeAdapter,
    "slack" => FakeAdapter,
    "discord" => FakeAdapter,
    "signal" => FakeAdapter,
    "whatsapp" => FakeAdapter,
    "cli" => FakeAdapter
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-temporal-registry-#{unique}.db")
    repo_name = :"temporal_registry_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp context(repo, overrides \\ %{}) do
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

  defp jobs_config(overrides \\ []) do
    Keyword.merge(
      [
        default_delivery_mode: "channel",
        default_delivery_target: [platform: "telegram", chat_id: "8217352118"],
        delivery_channels: @channels
      ],
      overrides
    )
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [now: @now, jobs_config: jobs_config(), personalization: [timezone: @tz]],
      overrides
    )
  end

  defp birthday_params(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Sarah's birthday",
        kind: "birthday",
        when: %{"type" => "annual", "month" => 9, "day" => 14}
      },
      overrides
    )
  end

  defp create(repo, params, extra_opts \\ []) do
    Registry.create_event(params, context(repo), opts(extra_opts))
  end

  defp with_target(target), do: [jobs_config: jobs_config(default_delivery_target: target)]

  describe "create_event/3 — identity and stored shape" do
    test "stores a yearly birthday with its default plan and the snapshotted target", %{
      repo: repo
    } do
      assert {:ok, %{status: :created, event: event, reminders: reminders}} =
               create(repo, birthday_params())

      assert event.recurrence_kind == "yearly"
      assert event.recurrence_month == 9
      assert event.recurrence_day == 14
      assert event.time_kind == "date"
      assert is_nil(event.local_date)
      assert event.timezone == @tz
      assert event.status == "active"
      assert event.revision == 1
      assert event.next_occurrence_on == ~D[2026-09-14]
      assert event.materialized_through_on == ~D[2027-09-14]

      assert event.delivery_platform == "telegram"
      assert event.delivery_destination == "8217352118"
      assert event.delivery_thread_scope == "root"

      assert event.source_channel == "telegram"
      assert event.source_chat_id == "555"
      assert event.source_session_id == "sess-1"
      assert event.created_by_trust == "operator"
      assert event.created_by_origin == "interactive"

      assert Enum.map(reminders, &{&1.occurrence_key, &1.reminder_rule_id}) == [
               {"2026-09-14", "week_before"},
               {"2026-09-14", "day_of"},
               {"2027-09-14", "week_before"},
               {"2027-09-14", "day_of"}
             ]

      assert Enum.all?(reminders, &(&1.delivery_platform == "telegram"))
    end

    test "a voice turn is stored with its own origin", %{repo: repo} do
      assert {:ok, %{event: event}} =
               Registry.create_event(
                 birthday_params(),
                 context(repo, %{computer_use_origin: :voice}),
                 opts()
               )

      assert event.created_by_origin == "voice"
    end

    test "an identical repeat create returns the existing event, never a duplicate", %{repo: repo} do
      assert {:ok, %{status: :created, event: first}} = create(repo, birthday_params())

      assert {:ok, %{status: :existing, event: second, reminders: reminders}} =
               create(repo, birthday_params())

      assert second.id == first.id
      assert length(reminders) == 4
    end

    test "a same-identity create with a different date is an identity conflict", %{repo: repo} do
      assert {:ok, _created} = create(repo, birthday_params())

      moved = birthday_params(%{when: %{"type" => "annual", "month" => 9, "day" => 15}})

      assert {:error, :identity_conflict} = create(repo, moved)
      assert Registry.describe_error(:identity_conflict) =~ "event_update"
    end

    test "the dedupe key is tool-derived: the same title on another date is a new event", %{
      repo: repo
    } do
      first = %{
        title: "Submit the report",
        kind: "deadline",
        when: %{"type" => "date", "date" => "2026-08-14"}
      }

      second = %{first | when: %{"type" => "date", "date" => "2026-09-14"}}

      assert {:ok, %{status: :created, event: a}} = create(repo, first)
      assert {:ok, %{status: :created, event: b}} = create(repo, second)

      assert a.id != b.id
      assert a.dedupe_key != b.dedupe_key
    end
  end

  describe "create_event/3 — structured time input (§12.2)" do
    test "a relative reminder resolves against the owner's local date at execution", %{repo: repo} do
      params = %{
        title: "Submit the report",
        kind: "explicit_reminder",
        when: %{"type" => "relative", "amount" => 2, "unit" => "weeks"}
      }

      assert {:ok, %{event: event, reminders: [reminder]}} = create(repo, params)

      assert event.time_kind == "date"
      assert event.recurrence_kind == "once"
      assert event.local_date == ~D[2026-08-16]
      assert reminder.scheduled_for == ~U[2026-08-16 13:00:00.000000Z]
    end

    test "a relative reminder with a time yields a timed event resolved through the zone", %{
      repo: repo
    } do
      params = %{
        title: "Call the clinic",
        kind: "explicit_reminder",
        when: %{"type" => "relative", "amount" => 3, "unit" => "days", "time" => "15:00:00"}
      }

      assert {:ok, %{event: event}} = create(repo, params)

      assert event.time_kind == "datetime"
      assert event.local_date == ~D[2026-08-05]
      assert event.local_time == ~T[15:00:00]
      assert event.occurrence_at == ~U[2026-08-05 19:00:00.000000Z]
    end

    test "a one-time local datetime persists the resolved UTC instant", %{repo: repo} do
      params = %{
        title: "Dentist appointment",
        kind: "appointment",
        when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "15:00:00"}
      }

      assert {:ok, %{event: event, reminders: reminders}} = create(repo, params)

      assert event.occurrence_at == ~U[2026-08-16 19:00:00.000000Z]
      assert Enum.map(reminders, & &1.reminder_rule_id) == ["hours_24_before", "hour_1_before"]
    end

    test "a nonexistent DST-gap local time is refused, never shifted", %{repo: repo} do
      params = %{
        title: "Spring meeting",
        kind: "appointment",
        when: %{"type" => "datetime", "date" => "2026-03-08", "time" => "02:30:00"}
      }

      assert {:error, {:dst_gap, @tz, ~D[2026-03-08], ~T[02:30:00]}} = create(repo, params)
      assert Registry.describe_error({:dst_gap, @tz, ~D[2026-03-08], ~T[02:30:00]}) =~ "not exist"
    end

    test "an ambiguous DST-fold time needs an offset selecting exactly one instant", %{repo: repo} do
      base = %{
        title: "Late shift",
        kind: "appointment",
        when: %{"type" => "datetime", "date" => "2026-11-01", "time" => "01:30:00"}
      }

      assert {:error, {:dst_ambiguous, offsets}} = create(repo, base)
      assert "-04:00" in offsets
      assert Registry.describe_error({:dst_ambiguous, offsets}) =~ "-04:00"

      resolved = %{base | when: Map.put(base.when, "utc_offset", "-04:00")}

      assert {:ok, %{event: event}} = create(repo, resolved)
      assert event.occurrence_at == ~U[2026-11-01 05:30:00.000000Z]
    end

    test "an owner-named zone overrides the configured personalization zone", %{repo: repo} do
      params = %{
        title: "Berlin standup",
        kind: "appointment",
        timezone: "Europe/Berlin",
        when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "15:00:00"}
      }

      assert {:ok, %{event: event}} = create(repo, params)
      assert event.timezone == "Europe/Berlin"
      assert event.occurrence_at == ~U[2026-08-16 13:00:00.000000Z]
    end

    test "a missing configured timezone fails with setup guidance and never assumes UTC", %{
      repo: repo
    } do
      assert {:error, :timezone_not_configured} =
               create(repo, birthday_params(), personalization: [])

      assert Registry.describe_error(:timezone_not_configured) =~ "timezone"
      assert {:ok, %{events: []}} = Registry.list_events(%{}, context(repo))
    end

    test "an invalid configured timezone is refused with the offending value", %{repo: repo} do
      assert {:error, {:invalid_timezone, "Mars/Olympus"}} =
               create(repo, birthday_params(), personalization: [timezone: "Mars/Olympus"])

      assert Registry.describe_error({:invalid_timezone, "Mars/Olympus"}) =~ "Mars/Olympus"
    end

    test "a yearly February 29 event requires an explicit leap-day policy", %{repo: repo} do
      params = birthday_params(%{when: %{"type" => "annual", "month" => 2, "day" => 29}})

      assert {:error, :leap_day_policy_required} = create(repo, params)

      assert {:ok, %{event: event}} =
               create(repo, Map.put(params, :leap_day_policy, "feb_28"))

      assert event.leap_day_policy == "feb_28"
    end
  end

  describe "create_event/3 — default target snapshot (§11.1)" do
    test "a missing default delivery target leaves no event row", %{repo: repo} do
      assert {:error, :no_default_delivery_target} =
               create(repo, birthday_params(), jobs_config: [delivery_channels: @channels])

      assert Registry.describe_error(:no_default_delivery_target) =~ "default_delivery_target"
      assert {:ok, %{events: []}} = Registry.list_events(%{}, context(repo))
    end

    test "delivery modes none, origin, and local are invalid for events", %{repo: repo} do
      for mode <- ["none", "origin", "local"] do
        config = jobs_config(default_delivery_mode: mode)

        assert {:error, {:invalid_delivery_mode, ^mode}} =
                 create(repo, birthday_params(), jobs_config: config)

        assert Registry.describe_error({:invalid_delivery_mode, mode}) =~ mode
      end
    end

    test "a cli default target is refused with the documented jobs divergence", %{repo: repo} do
      config =
        jobs_config(default_delivery_target: [platform: "cli", chat_id: "stdout"])

      assert {:error, {:cli_delivery_platform, "cli"}} =
               create(repo, birthday_params(), jobs_config: config)

      message = Registry.describe_error({:cli_delivery_platform, "cli"})
      assert message =~ "cli"
      assert message =~ "schedule_job"
    end

    test "a platform outside the proactive allowlist is refused", %{repo: repo} do
      config = jobs_config(default_delivery_target: [platform: "acp", chat_id: "x"])

      assert {:error, {:unsupported_delivery_platform, "acp"}} =
               create(repo, birthday_params(), jobs_config: config)
    end

    test "a missing destination is refused", %{repo: repo} do
      config = jobs_config(default_delivery_target: [platform: "telegram"])

      assert {:error, :no_default_delivery_destination} =
               create(repo, birthday_params(), jobs_config: config)
    end

    test "an unresolvable adapter is refused at acceptance", %{repo: repo} do
      config = jobs_config(delivery_channels: %{})

      assert {:error, {:unsupported_delivery_platform, "telegram"}} =
               create(repo, birthday_params(), jobs_config: config)
    end
  end

  describe "create_event/3 — thread normalization (§11.1)" do
    test "a telegram message_thread_id is snapshotted as its decimal string", %{repo: repo} do
      assert {:ok, %{event: event}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "telegram", chat_id: "1", message_thread_id: 42)
               )

      assert event.delivery_thread_scope == "42"
    end

    test "a telegram decimal-string thread id is kept verbatim", %{repo: repo} do
      assert {:ok, %{event: event}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "telegram", chat_id: "1", message_thread_id: "42")
               )

      assert event.delivery_thread_scope == "42"
    end

    test "a slack thread_ts is stored unchanged", %{repo: repo} do
      assert {:ok, %{event: event}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "slack", channel_id: "C1", thread_ts: "1712345.6789")
               )

      assert event.delivery_thread_scope == "1712345.6789"
    end

    test "discord, signal, and whatsapp normalize to root", %{repo: repo} do
      for {platform, index} <- Enum.with_index(["discord", "signal", "whatsapp"]) do
        params = birthday_params(%{title: "Anniversary #{index}"})

        assert {:ok, %{event: event}} =
                 create(repo, params, with_target(platform: platform, chat_id: "c#{index}"))

        assert event.delivery_platform == platform
        assert event.delivery_thread_scope == "root"
      end
    end

    test "an irrelevant thread field for the platform is refused", %{repo: repo} do
      assert {:error, {:irrelevant_thread_field, "telegram", "thread_ts"}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "telegram", chat_id: "1", thread_ts: "1712.1")
               )

      assert {:error, {:irrelevant_thread_field, "slack", "message_thread_id"}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "slack", channel_id: "C1", message_thread_id: "42")
               )

      assert {:error, {:irrelevant_thread_field, "discord", "message_thread_id"}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "discord", chat_id: "1", message_thread_id: "42")
               )
    end

    test "supplying both thread fields is refused rather than guessed", %{repo: repo} do
      assert {:error, {:conflicting_thread_fields, "telegram"}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(
                   platform: "telegram",
                   chat_id: "1",
                   message_thread_id: "42",
                   thread_ts: "1712.1"
                 )
               )
    end

    test "an invalid telegram thread value is refused", %{repo: repo} do
      assert {:error, {:invalid_thread_value, "telegram", "abc"}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "telegram", chat_id: "1", message_thread_id: "abc")
               )
    end

    test "ephemeral per-message extras are refused instead of persisted", %{repo: repo} do
      assert {:error, {:unsupported_target_field, "reply_to"}} =
               create(
                 repo,
                 birthday_params(),
                 with_target(platform: "telegram", chat_id: "1", reply_to: "9")
               )
    end
  end

  describe "create_event/3 — reminder plans (§8)" do
    test "a custom bounded plan replaces the defaults instead of appending", %{repo: repo} do
      params =
        birthday_params(%{
          reminders: [%{"type" => "days_before", "days" => 1, "at" => "08:00:00"}]
        })

      assert {:ok, %{reminders: reminders}} = create(repo, params)

      assert Enum.map(reminders, & &1.reminder_rule_id) == ["days_before_1", "days_before_1"]
      assert length(reminders) == 2
    end

    test "an explicitly notification-free event stores no reminders but keeps a target", %{
      repo: repo
    } do
      assert {:ok, %{event: event, reminders: []}} =
               create(repo, birthday_params(%{no_reminders: true}))

      assert event.delivery_platform == "telegram"
      assert event.reminder_plan == []
    end

    test "past lead rules are skipped rather than replayed", %{repo: repo} do
      assert {:ok, %{reminders: reminders}} =
               create(repo, birthday_params(), now: ~U[2026-09-10 12:00:00Z])

      assert Enum.map(reminders, &{&1.occurrence_key, &1.reminder_rule_id}) == [
               {"2026-09-14", "day_of"},
               {"2027-09-14", "week_before"},
               {"2027-09-14", "day_of"}
             ]
    end

    test "more than ten reminder rules is refused", %{repo: repo} do
      rules =
        Enum.map(1..11, fn days ->
          %{"type" => "days_before", "days" => days, "at" => "09:00:00"}
        end)

      assert {:error, {:too_many_rules, 11}} = create(repo, birthday_params(%{reminders: rules}))
    end

    test "an unrecognized reminder rule is refused, never guessed", %{repo: repo} do
      params = birthday_params(%{reminders: [%{"type" => "whenever"}]})

      assert {:error, {:invalid_reminder_rule, %{"type" => "whenever"}}} = create(repo, params)
    end
  end

  describe "update_event/4" do
    test "patches the plan under a new revision and cancels superseded pending rows", %{
      repo: repo
    } do
      assert {:ok, %{event: event}} = create(repo, birthday_params())

      assert {:ok, %{event: updated, reminders: reminders}} =
               Registry.update_event(
                 event.id,
                 %{
                   title: "Sarah's birthday party",
                   reminders: [%{"type" => "days_before", "days" => 0, "at" => "07:30:00"}]
                 },
                 context(repo),
                 opts()
               )

      assert updated.id == event.id
      assert updated.revision == 2
      assert updated.title == "Sarah's birthday party"
      assert Enum.map(reminders, & &1.reminder_rule_id) == ["days_before_0", "days_before_0"]

      assert {:ok, cancelled} =
               Repo.list_temporal_reminders(
                 %{event_id: event.id, status: ["cancelled"]},
                 server: repo
               )

      assert length(cancelled) == 4
    end

    test "moving the time re-resolves the UTC instant", %{repo: repo} do
      params = %{
        title: "Dentist appointment",
        kind: "appointment",
        when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "15:00:00"}
      }

      assert {:ok, %{event: event}} = create(repo, params)

      assert {:ok, %{event: updated}} =
               Registry.update_event(
                 event.id,
                 %{when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "16:00:00"}},
                 context(repo),
                 opts()
               )

      assert updated.local_time == ~T[16:00:00]
      assert updated.occurrence_at == ~U[2026-08-16 20:00:00.000000Z]
    end

    test "rebind_delivery_to_default snapshots the current default target", %{repo: repo} do
      assert {:ok, %{event: event}} = create(repo, birthday_params())
      assert event.delivery_destination == "8217352118"

      rebound =
        jobs_config(default_delivery_target: [platform: "slack", channel_id: "C99"])

      assert {:ok, %{event: updated, reminders: reminders}} =
               Registry.update_event(
                 event.id,
                 %{rebind_delivery_to_default: true},
                 context(repo),
                 opts(jobs_config: rebound)
               )

      assert updated.delivery_platform == "slack"
      assert updated.delivery_destination == "C99"
      assert Enum.all?(reminders, &(&1.delivery_platform == "slack"))
    end

    test "changing the configured default target does not rewrite a stored destination", %{
      repo: repo
    } do
      # §11.1's headline guarantee, the direction the rebind test cannot prove:
      # without an explicit rebind, an operator's later `default_delivery_target`
      # edit must not redirect an already-stored personal reminder.
      assert {:ok, %{event: event, reminders: created}} = create(repo, birthday_params())
      assert event.delivery_platform == "telegram"
      assert Enum.all?(created, &(&1.delivery_destination == "8217352118"))

      moved = jobs_config(default_delivery_target: [platform: "slack", channel_id: "C99"])

      assert {:ok, %{event: updated, reminders: reminders}} =
               Registry.update_event(
                 event.id,
                 %{title: "Sarah's birthday party"},
                 context(repo),
                 opts(jobs_config: moved)
               )

      assert updated.delivery_platform == "telegram"
      assert updated.delivery_destination == "8217352118"
      assert updated.delivery_thread_scope == "root"
      assert Enum.all?(reminders, &(&1.delivery_platform == "telegram"))
      assert Enum.all?(reminders, &(&1.delivery_destination == "8217352118"))

      assert {:ok, %{events: [listed]}} = Registry.list_events(%{}, context(repo), opts())

      assert listed.delivery_platform == "telegram"
      assert listed.delivery_destination == "8217352118"
    end

    test "a mutation during an in-flight send fails visibly with the ask-again contract", %{
      repo: repo
    } do
      params = %{
        title: "Call the clinic",
        kind: "explicit_reminder",
        when: %{"type" => "datetime", "date" => "2026-08-03", "time" => "09:00:00"}
      }

      assert {:ok, %{event: event}} = create(repo, params)

      assert {:ok, [_claimed]} =
               Repo.claim_due_reminders(~U[2026-08-03 13:30:00Z], 5, server: repo)

      assert {:error, :delivery_in_progress} =
               Registry.update_event(
                 event.id,
                 %{title: "Call the dentist"},
                 context(repo),
                 opts()
               )

      assert Registry.describe_error(:delivery_in_progress) =~ "try again"
    end

    test "an unknown event id is not found", %{repo: repo} do
      assert {:error, :not_found} =
               Registry.update_event("evt_missing", %{title: "x"}, context(repo), opts())
    end
  end

  describe "cancel_event/3" do
    test "soft-cancels the event and its unsent reminders", %{repo: repo} do
      assert {:ok, %{event: event}} = create(repo, birthday_params())

      assert {:ok, cancelled} = Registry.cancel_event(event.id, context(repo), opts())
      assert cancelled.status == "cancelled"

      assert {:ok, rows} = Repo.list_temporal_reminders(%{event_id: event.id}, server: repo)
      assert Enum.all?(rows, &(&1.status == "cancelled"))
    end

    test "an unknown event id is not found", %{repo: repo} do
      assert {:error, :not_found} = Registry.cancel_event("evt_missing", context(repo), opts())
    end
  end

  describe "scheduler notification (§10.3)" do
    test "a committed write casts :event_changed to the registered scheduler", %{repo: repo} do
      name = :"temporal_registry_fake_scheduler_#{System.unique_integer([:positive])}"
      start_supervised!({FakeScheduler, name: name, test_pid: self()})

      assert {:ok, %{event: event}} =
               Registry.create_event(
                 birthday_params(),
                 context(repo, %{temporal_scheduler: name}),
                 opts()
               )

      assert_receive {:scheduler_cast, :event_changed}

      assert {:ok, _cancelled} =
               Registry.cancel_event(event.id, context(repo, %{temporal_scheduler: name}), opts())

      assert_receive {:scheduler_cast, :event_changed}
    end

    test "an unavailable scheduler cannot turn a committed write into a tool error", %{repo: repo} do
      missing = :"temporal_registry_absent_scheduler_#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:ok, %{event: event}} =
                   Registry.create_event(
                     birthday_params(),
                     context(repo, %{temporal_scheduler: missing}),
                     opts()
                   )

          assert {:ok, _stored} = Repo.get_temporal_event(event.id, server: repo)
        end)

      assert log =~ "scheduler"
    end
  end

  describe "list_events/3" do
    test "lists the owner's active events with their delivery state", %{repo: repo} do
      assert {:ok, _created} = create(repo, birthday_params())

      assert {:ok, %{events: [event], cursor: nil}} =
               Registry.list_events(%{}, context(repo), opts())

      assert event.title == "Sarah's birthday"
      assert event.delivery_platform == "telegram"
      assert event.next_reminder_at == ~U[2026-09-07 13:00:00.000000Z]
      assert is_nil(event.last_delivery_status)
    end

    test "a date window wider than two years is refused", %{repo: repo} do
      filter = %{from: "2026-01-01", to: "2030-01-01"}

      assert {:error, :date_window_too_wide} = Registry.list_events(filter, context(repo))
      assert Registry.describe_error(:date_window_too_wide) =~ "two years"
    end

    # A post-boundary snooze reactivates a completed one-time parent and restores
    # its already-passed occurrence date. With no floor that row sorts FIRST in
    # the owner's default listing — presented as their next upcoming event — for
    # as long as the snooze pends.
    test "a parent reactivated by a post-boundary snooze is not the owner's next event", %{
      repo: repo
    } do
      {event, delivered} = delivered_reminder!(repo)
      after_event = ~U[2026-08-16 21:30:00Z]

      assert {:ok, %{completed_events: [_id]}} =
               Repo.reconcile_temporal_boundaries(after_event, nil, 20, server: repo)

      assert {:ok, _snoozed} =
               snooze(
                 repo,
                 %{reminder_id: delivered.id, snooze: hours(1), confirm_past_boundary: true},
                 now: after_event
               )

      assert {:ok, reactivated} = Repo.get_temporal_event(event.id, server: repo)
      assert reactivated.status == "active"

      # A genuinely upcoming event, so an empty list cannot pass by accident.
      assert {:ok, _future} = create(repo, birthday_params(), caller_target_opts())

      later = [now: ~U[2026-08-20 12:00:00Z]]

      assert {:ok, %{events: listed}} =
               Registry.list_events(%{}, context(repo), opts(later))

      titles = Enum.map(listed, & &1.title)
      refute event.title in titles
      assert "Sarah's birthday" in titles

      # History stays one explicit window — or one explicit status — away.
      assert {:ok, %{events: windowed}} =
               Registry.list_events(%{from: "2026-08-01"}, context(repo), opts(later))

      assert event.title in Enum.map(windowed, & &1.title)

      assert {:ok, %{events: any_status}} =
               Registry.list_events(%{status: :any}, context(repo), opts(later))

      assert event.title in Enum.map(any_status, & &1.title)
    end

    test "pages with an opaque cursor the caller passes back verbatim", %{repo: repo} do
      for {date, index} <- Enum.with_index(["2026-10-01", "2026-11-01", "2026-12-01"], 1) do
        params = %{
          title: "Deadline #{index}",
          kind: "deadline",
          when: %{"type" => "date", "date" => date}
        }

        assert {:ok, _created} = create(repo, params)
      end

      assert {:ok, %{events: first_page, cursor: cursor}} =
               Registry.list_events(%{limit: 2}, context(repo), opts())

      assert length(first_page) == 2
      assert is_binary(cursor)

      assert {:ok, %{events: second_page, cursor: nil}} =
               Registry.list_events(%{limit: 2, cursor: cursor}, context(repo), opts())

      assert length(second_page) == 1
      assert Enum.map(second_page, & &1.title) == ["Deadline 3"]
    end
  end

  # --- snooze (§20) --------------------------------------------------------

  # The caller's own conversation IS the delivery target, which is the only
  # configuration in which "snooze that" can resolve anything.
  defp caller_target_opts, do: with_target(platform: "telegram", chat_id: "555")

  defp report_params(overrides) do
    Map.merge(
      %{
        title: "Submit the report",
        kind: "explicit_reminder",
        when: %{"type" => "datetime", "date" => "2026-08-16", "time" => "15:00:00"},
        reminders: [%{"type" => "at_time"}]
      },
      overrides
    )
  end

  # 2026-08-16 15:00 EDT.
  @report_at ~U[2026-08-16 19:00:00Z]

  defp pending_reminder!(repo, params_overrides \\ %{}) do
    {:ok, %{event: event, reminders: [row]}} =
      create(repo, report_params(params_overrides), caller_target_opts())

    {event, row}
  end

  defp delivered_reminder!(repo, sent_at \\ @report_at, params_overrides \\ %{}) do
    {event, row} = pending_reminder!(repo, params_overrides)
    {:ok, claimed} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)
    target = Enum.find(claimed, &(&1.id == row.id))
    {:ok, delivered} = Repo.temporal_reminder_delivered(target.id, sent_at, server: repo)
    {event, delivered}
  end

  defp snooze(repo, args, extra_opts), do: snooze(repo, args, extra_opts, %{})

  defp snooze(repo, args, extra_opts, context_overrides) do
    Registry.snooze_reminder(
      args,
      context(repo, context_overrides),
      opts(Keyword.merge(caller_target_opts(), extra_opts))
    )
  end

  defp hours(count), do: %{"type" => "duration", "amount" => count, "unit" => "hours"}

  describe "snooze_reminder/3 — new-time forms (§12.2 style)" do
    test "a duration defers the reminder from now", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)

      assert {:ok, result} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)},
                 now: ~U[2026-08-16 12:00:00Z]
               )

      assert result.status == :created
      assert result.reminder.scheduled_for == ~U[2026-08-16 13:00:00.000000Z]
    end

    test "minutes and days are accepted, and the total is bounded at 90 days", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)
      now = ~U[2026-08-14 12:00:00Z]

      assert {:ok, %{reminder: minutes}} =
               snooze(
                 repo,
                 %{
                   reminder_id: row.id,
                   snooze: %{"type" => "duration", "amount" => 30, "unit" => "minutes"}
                 },
                 now: now
               )

      assert minutes.scheduled_for == ~U[2026-08-14 12:30:00.000000Z]

      assert {:error, :snooze_too_far} =
               snooze(
                 repo,
                 %{
                   reminder_id: row.id,
                   snooze: %{"type" => "duration", "amount" => 91, "unit" => "days"},
                   confirm_past_boundary: true
                 },
                 now: now
               )

      assert Registry.describe_error(:snooze_too_far) =~ "90 days"
    end

    test "a datetime resolves through the configured zone", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)

      assert {:ok, result} =
               snooze(
                 repo,
                 %{
                   reminder_id: row.id,
                   snooze: %{
                     "type" => "datetime",
                     "date" => "2026-08-16",
                     "time" => "14:30:00"
                   }
                 },
                 now: ~U[2026-08-16 12:00:00Z]
               )

      assert result.reminder.scheduled_for == ~U[2026-08-16 18:30:00.000000Z]
    end

    # The horizon is a property of the resolved instant, not of the form the
    # owner used to name it, and confirming a past-boundary reminder says
    # nothing about how far out it is.
    test "a datetime past the 90-day horizon is refused, confirmed or not", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)
      now = ~U[2026-08-16 12:00:00Z]
      # 300 days out.
      far = %{"type" => "datetime", "date" => "2027-06-12", "time" => "09:00:00"}

      assert {:error, :snooze_too_far} =
               snooze(repo, %{reminder_id: row.id, snooze: far}, now: now)

      assert {:error, :snooze_too_far} =
               snooze(
                 repo,
                 %{reminder_id: row.id, snooze: far, confirm_past_boundary: true},
                 now: now
               )
    end

    test "a datetime just inside the horizon is still accepted", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)
      # 89 days out.
      near = %{"type" => "datetime", "date" => "2026-11-13", "time" => "09:00:00"}

      assert {:ok, %{reminder: reminder}} =
               snooze(
                 repo,
                 %{reminder_id: row.id, snooze: near, confirm_past_boundary: true},
                 now: ~U[2026-08-16 12:00:00Z]
               )

      assert reminder.scheduled_for == ~U[2026-11-13 14:00:00.000000Z]
    end

    test "a DST gap is refused rather than shifted", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)

      assert {:error, {:dst_gap, @tz, ~D[2027-03-14], ~T[02:30:00]}} =
               snooze(
                 repo,
                 %{
                   reminder_id: row.id,
                   snooze: %{
                     "type" => "datetime",
                     "date" => "2027-03-14",
                     "time" => "02:30:00"
                   },
                   confirm_past_boundary: true
                 },
                 now: ~U[2026-08-16 12:00:00Z]
               )
    end

    test "an instant that is not strictly in the future is refused", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)
      now = ~U[2026-08-16 12:00:00Z]

      assert {:error, :snooze_in_past} =
               snooze(
                 repo,
                 %{
                   reminder_id: row.id,
                   snooze: %{"type" => "datetime", "date" => "2026-08-16", "time" => "07:00:00"}
                 },
                 now: now
               )

      assert Registry.describe_error(:snooze_in_past) =~ "future"
    end

    test "an unsupported form names the two it accepts", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)

      assert {:error, {:invalid_snooze, %{"type" => "relative"}}} =
               snooze(repo, %{reminder_id: row.id, snooze: %{"type" => "relative"}},
                 now: ~U[2026-08-16 12:00:00Z]
               )

      assert Registry.describe_error({:invalid_snooze, %{}}) =~ "duration"
      assert Registry.describe_error({:invalid_snooze, %{}}) =~ "datetime"
    end
  end

  describe "snooze_reminder/3 — validity (§8.3)" do
    test "clamps to the event boundary when two hours would overshoot it", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)

      # 18:00Z + 2h = 20:00Z, but the event itself begins at 19:00Z.
      assert {:ok, result} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)},
                 now: ~U[2026-08-16 17:00:00Z]
               )

      assert result.reminder.scheduled_for == ~U[2026-08-16 18:00:00.000000Z]
      assert result.reminder.valid_until == ~U[2026-08-16 19:00:00.000000Z]
    end

    test "keeps the full two hours when they fit before the boundary", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)

      assert {:ok, result} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)},
                 now: ~U[2026-08-16 12:00:00Z]
               )

      assert result.reminder.scheduled_for == ~U[2026-08-16 13:00:00.000000Z]
      assert result.reminder.valid_until == ~U[2026-08-16 15:00:00.000000Z]
    end

    test "a time at or past the event boundary needs the owner's confirmation", %{repo: repo} do
      {_event, row} = delivered_reminder!(repo)
      now = ~U[2026-08-16 19:05:00Z]

      assert {:error, :snooze_past_boundary_unconfirmed} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)}, now: now)

      assert Registry.describe_error(:snooze_past_boundary_unconfirmed) =~ "confirm"

      assert {:ok, result} =
               snooze(
                 repo,
                 %{reminder_id: row.id, snooze: hours(1), confirm_past_boundary: true},
                 now: now
               )

      assert result.reminder.scheduled_for == ~U[2026-08-16 20:05:00.000000Z]
      assert result.reminder.valid_until == ~U[2026-08-16 22:05:00.000000Z]
    end
  end

  describe "snooze_reminder/3 — \"snooze that\" resolution (§20)" do
    test "resolves the latest delivered reminder in the caller's own conversation", %{repo: repo} do
      {_older_event, older} = delivered_reminder!(repo, ~U[2026-08-16 19:00:00Z])

      {_newer_event, newer} =
        delivered_reminder!(repo, ~U[2026-08-16 19:30:00Z], %{title: "Call the vet"})

      assert {:ok, result} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 now: ~U[2026-08-16 20:00:00Z]
               )

      assert result.source.id == newer.id
      refute result.source.id == older.id
    end

    test "never crosses platform, destination, thread, owner, or the lookback", %{repo: repo} do
      {_event, _row} = delivered_reminder!(repo, ~U[2026-08-16 19:00:00Z])

      crossings = [
        {"platform", %{conversation_key: {"slack", "555", :root}}},
        {"destination", %{conversation_key: {"telegram", "999", :root}}},
        {"thread", %{conversation_key: {"telegram", "555", "17"}}},
        {"owner", %{memory_owner_id: "someone_else"}}
      ]

      for {axis, overrides} <- crossings do
        assert {:error, :no_recent_reminder} =
                 snooze(
                   repo,
                   %{snooze: hours(1), confirm_past_boundary: true},
                   [now: ~U[2026-08-16 20:00:00Z]],
                   overrides
                 ),
               "resolution crossed #{axis}"
      end

      # More than 24 hours later, the same row is out of the lookback.
      assert {:error, :no_recent_reminder} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 now: ~U[2026-08-17 19:30:00Z]
               )
    end

    test "no match asks which event instead of guessing", %{repo: repo} do
      assert {:error, :no_recent_reminder} =
               snooze(repo, %{snooze: hours(1)}, now: ~U[2026-08-16 20:00:00Z])

      assert Registry.describe_error(:no_recent_reminder) =~ "which event"
    end

    test "a turn with no conversation cannot resolve \"that\"", %{repo: repo} do
      {_event, _row} = delivered_reminder!(repo)

      assert {:error, :no_conversation_target} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 [now: ~U[2026-08-16 20:00:00Z]],
                 %{conversation_key: nil}
               )

      assert Registry.describe_error(:no_conversation_target) =~ "reminder_id"
    end

    # Every key below comes from the REAL ingress constructor, because the whole
    # finding lives in what that constructor produces: a Slack channel-root
    # mention carries no `thread_ts`, so the adapter keys it by the mention's own
    # (always fresh) `ts`, and a hand-written `{"slack", "C1", :root}` tuple
    # silently tests a conversation that can never exist.
    defp key(fields), do: ConversationKey.from(fields)

    defp delivered_into!(repo, target, sent_at, title) do
      {:ok, %{reminders: [row]}} =
        create(repo, report_params(%{title: title}), with_target(target))

      {:ok, claimed} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)
      hit = Enum.find(claimed, &(&1.id == row.id))
      {:ok, delivered} = Repo.temporal_reminder_delivered(hit.id, sent_at, server: repo)
      delivered
    end

    test "a Slack channel-root mention resolves a reminder delivered at channel root", %{
      repo: repo
    } do
      delivered =
        delivered_into!(
          repo,
          [platform: "slack", channel_id: "C1"],
          ~U[2026-08-16 19:00:00Z],
          "Submit the slack report"
        )

      caller = key(%{channel: "slack", chat_id: "C1", thread_ts: "1770000000.000100"})

      assert {:ok, result} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 [now: ~U[2026-08-16 20:00:00Z]],
                 %{conversation_key: caller}
               )

      assert result.source.id == delivered.id
    end

    test "a Slack in-thread reply still prefers its own thread over channel root", %{repo: repo} do
      threaded =
        delivered_into!(
          repo,
          [platform: "slack", channel_id: "C1", thread_ts: "1769999999.000001"],
          ~U[2026-08-16 19:00:00Z],
          "Threaded report"
        )

      # Delivered LATER at channel root: recency must not beat an exact thread.
      _rooted =
        delivered_into!(
          repo,
          [platform: "slack", channel_id: "C1"],
          ~U[2026-08-16 19:30:00Z],
          "Rooted report"
        )

      caller = key(%{channel: "slack", chat_id: "C1", thread_ts: "1769999999.000001"})

      assert {:ok, result} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 [now: ~U[2026-08-16 20:00:00Z]],
                 %{conversation_key: caller}
               )

      assert result.source.id == threaded.id
    end

    test "a Slack mention never reaches into a different thread", %{repo: repo} do
      _threaded =
        delivered_into!(
          repo,
          [platform: "slack", channel_id: "C1", thread_ts: "1769999999.000001"],
          ~U[2026-08-16 19:00:00Z],
          "Threaded report"
        )

      caller = key(%{channel: "slack", chat_id: "C1", thread_ts: "1770000000.000900"})

      assert {:error, :no_recent_reminder} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 [now: ~U[2026-08-16 20:00:00Z]],
                 %{conversation_key: caller}
               )
    end

    test "Telegram root and forum-topic keys each match only their own target", %{repo: repo} do
      rooted =
        delivered_into!(
          repo,
          [platform: "telegram", chat_id: "555"],
          ~U[2026-08-16 19:00:00Z],
          "Rooted report"
        )

      threaded =
        delivered_into!(
          repo,
          [platform: "telegram", chat_id: "555", message_thread_id: "17"],
          ~U[2026-08-16 19:30:00Z],
          "Topic report"
        )

      pairs = [
        {key(%{channel: "telegram", chat_id: "555"}), rooted.id},
        {key(%{channel: "telegram", chat_id: "555", thread_ts: 17}), threaded.id}
      ]

      for {caller, expected} <- pairs do
        assert {:ok, result} =
                 snooze(
                   repo,
                   %{snooze: hours(1), confirm_past_boundary: true},
                   [now: ~U[2026-08-16 20:00:00Z]],
                   %{conversation_key: caller}
                 )

        assert result.source.id == expected, "telegram #{inspect(caller)} matched the wrong row"
      end
    end

    test "a resolved delivered source stays delivered", %{repo: repo} do
      {_event, delivered} = delivered_reminder!(repo)

      assert {:ok, _result} =
               snooze(
                 repo,
                 %{snooze: hours(1), confirm_past_boundary: true},
                 now: ~U[2026-08-16 20:00:00Z]
               )

      assert {:ok, reread} = Repo.get_temporal_reminder(delivered.id, server: repo)
      assert reread.status == "delivered"
    end
  end

  describe "snooze_reminder/3 — acknowledgement and idempotence (§5.2)" do
    test "the view carries the event, the absolute local time, and the platform", %{repo: repo} do
      {event, row} = pending_reminder!(repo)

      assert {:ok, result} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)},
                 now: ~U[2026-08-16 12:00:00Z]
               )

      view = Registry.snooze_view(result)

      assert view["status"] == "snoozed"
      assert view["event_id"] == event.id
      assert view["title"] == "Submit the report"
      assert view["kind"] == "explicit_reminder"
      assert view["timezone"] == @tz
      assert view["scheduled_for"] == "2026-08-16T13:00:00.000000Z"
      assert view["scheduled_for_local"] == "2026-08-16T09:00:00.000000-04:00"
      assert view["zone_abbr"] == "EDT"
      assert view["delivery"]["platform"] == "telegram"
      assert view["delivery"]["destination"] == "555"
      assert view["replaced_earlier_snooze"] == false
      assert view["source_reminder_id"] == row.id
    end

    test "an identical re-snooze says so instead of implying a second reminder", %{repo: repo} do
      {_event, row} = delivered_reminder!(repo)
      now = ~U[2026-08-16 19:30:00Z]
      args = %{reminder_id: row.id, snooze: hours(1), confirm_past_boundary: true}

      assert {:ok, first} = snooze(repo, args, now: now)
      assert first.status == :created

      assert {:ok, repeat} = snooze(repo, args, now: now)
      assert repeat.status == :existing
      assert repeat.reminder.id == first.reminder.id

      view = Registry.snooze_view(repeat)
      assert view["status"] == "already_snoozed"
      assert view["note"] =~ "already"
    end

    test "a later snooze reports that it replaced the earlier one", %{repo: repo} do
      {_event, row} = delivered_reminder!(repo)
      now = ~U[2026-08-16 19:30:00Z]

      assert {:ok, _first} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1), confirm_past_boundary: true},
                 now: now
               )

      assert {:ok, second} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(2), confirm_past_boundary: true},
                 now: now
               )

      assert length(second.superseded) == 1
      assert Registry.snooze_view(second)["replaced_earlier_snooze"] == true
    end

    test "a removed event, an in-flight send, and a terminal source are refused", %{repo: repo} do
      {event, row} = pending_reminder!(repo)
      now = ~U[2026-08-16 12:00:00Z]

      assert {:ok, [claimed]} = Repo.claim_due_reminders(row.scheduled_for, 10, server: repo)

      assert {:error, :source_delivering} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)}, now: now)

      assert Registry.describe_error(:source_delivering) =~ "recalled"

      {:ok, _failed} =
        Repo.temporal_reminder_failed(claimed.id, "unauthorized", @report_at, server: repo)

      assert {:error, :source_terminal} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)}, now: now)

      {:ok, _cancelled} = Repo.cancel_temporal_event(event.id, @now, server: repo)

      assert {:error, :parent_cancelled} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)}, now: now)

      assert Registry.describe_error(:parent_cancelled) =~ "removed"
    end

    test "an unknown reminder id is refused", %{repo: repo} do
      assert {:error, :not_found} =
               snooze(repo, %{reminder_id: "rem_missing", snooze: hours(1)},
                 now: ~U[2026-08-16 12:00:00Z]
               )
    end
  end

  describe "snooze_reminder/3 — telemetry and scheduler signal" do
    setup do
      handler = "registry-snooze-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:fermix, :reminder, :lifecycle],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:reminder_lifecycle, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp lifecycle_phases do
      receive do
        {:reminder_lifecycle, metadata} -> [metadata | lifecycle_phases()]
      after
        0 -> []
      end
    end

    test "a created snooze emits materialized, and a replaced one emits superseded", %{repo: repo} do
      {_event, row} = delivered_reminder!(repo)
      now = ~U[2026-08-16 19:30:00Z]

      assert {:ok, first} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1), confirm_past_boundary: true},
                 now: now
               )

      # Drop the create-time materialized events the fixture produced.
      _fixture = lifecycle_phases()

      assert {:ok, second} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(2), confirm_past_boundary: true},
                 now: now
               )

      events = lifecycle_phases()
      phases = events |> Enum.map(& &1.phase) |> Enum.sort()

      assert phases == [:materialized, :superseded]

      materialized = Enum.find(events, &(&1.phase == :materialized))
      assert materialized.reminder_id == second.reminder.id
      assert materialized.rule_id =~ "snooze:"
      assert materialized.platform == "telegram"

      superseded = Enum.find(events, &(&1.phase == :superseded))
      assert superseded.reminder_id == first.reminder.id
    end

    # Retiring the pending source is a real supersession the trace must show,
    # but it is NOT a replaced snooze and the acknowledgement must not say it was.
    test "retiring the pending source is traced without being called a replacement", %{repo: repo} do
      {_event, row} = pending_reminder!(repo)
      _fixture = lifecycle_phases()

      assert {:ok, result} =
               snooze(repo, %{reminder_id: row.id, snooze: hours(1)},
                 now: ~U[2026-08-16 12:00:00Z]
               )

      events = lifecycle_phases()
      assert events |> Enum.map(& &1.phase) |> Enum.sort() == [:materialized, :superseded]
      assert Enum.find(events, &(&1.phase == :superseded)).reminder_id == row.id

      assert result.superseded == [row.id]
      assert Registry.snooze_view(result)["replaced_earlier_snooze"] == false
      assert is_nil(Registry.snooze_view(result)["note"])
    end

    test "an idempotent repeat emits nothing", %{repo: repo} do
      {_event, row} = delivered_reminder!(repo)
      now = ~U[2026-08-16 19:30:00Z]
      args = %{reminder_id: row.id, snooze: hours(1), confirm_past_boundary: true}

      assert {:ok, _first} = snooze(repo, args, now: now)
      _drain = lifecycle_phases()

      assert {:ok, %{status: :existing}} = snooze(repo, args, now: now)
      assert lifecycle_phases() == []
    end

    test "the committed snooze notifies the scheduler", %{repo: repo} do
      scheduler = :"snooze_scheduler_#{System.unique_integer([:positive])}"
      start_supervised!({FakeScheduler, name: scheduler, test_pid: self()})

      {_event, row} = pending_reminder!(repo)

      assert {:ok, _result} =
               Registry.snooze_reminder(
                 %{reminder_id: row.id, snooze: hours(1)},
                 context(repo, %{temporal_scheduler: scheduler}),
                 opts(Keyword.merge(caller_target_opts(), now: ~U[2026-08-16 12:00:00Z]))
               )

      assert_receive {:scheduler_cast, :event_changed}
    end
  end

  # --- implicit "cancel that" (§8.4 resolution, cancel semantics) -----------

  describe "cancel_referent/2" do
    setup do
      handler = "registry-cancel-referent-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:fermix, :reminder, :lifecycle],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:reminder_lifecycle, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp cancel_referent(repo, extra_opts, context_overrides \\ %{}) do
      Registry.cancel_referent(
        context(repo, context_overrides),
        opts(Keyword.merge(caller_target_opts(), extra_opts))
      )
    end

    # One event, one delivered reminder and one still-pending one, so a single
    # call can prove both halves of soft-cancel.
    defp delivered_and_pending!(repo, sent_at) do
      overrides = %{
        reminders: [
          %{"type" => "days_before", "days" => 1, "at" => "09:00:00"},
          %{"type" => "at_time"}
        ]
      }

      {:ok, %{event: event, reminders: rows}} =
        create(repo, report_params(overrides), caller_target_opts())

      early = Enum.min_by(rows, &DateTime.to_unix(&1.scheduled_for))
      later = Enum.find(rows, &(&1.id != early.id))

      {:ok, [claimed]} = Repo.claim_due_reminders(early.scheduled_for, 10, server: repo)
      {:ok, delivered} = Repo.temporal_reminder_delivered(claimed.id, sent_at, server: repo)

      {event, delivered, later}
    end

    test "cancels the parent and its unsent rows, keeping delivered history", %{repo: repo} do
      {event, delivered, pending} = delivered_and_pending!(repo, ~U[2026-08-15 13:00:00Z])
      _fixture = lifecycle_phases()

      assert {:ok, result} = cancel_referent(repo, now: ~U[2026-08-15 14:00:00Z])

      # The full canonical event, so the acknowledgement can name what went.
      assert result.event.id == event.id
      assert result.event.status == "cancelled"
      assert result.event.title == "Submit the report"
      assert result.event.kind == "explicit_reminder"

      # Anchored to the reminder that made "that" resolvable.
      assert result.source.id == delivered.id

      assert {:ok, sent} = Repo.get_temporal_reminder(delivered.id, server: repo)
      assert sent.status == "delivered"

      assert {:ok, unsent} = Repo.get_temporal_reminder(pending.id, server: repo)
      assert unsent.status == "cancelled"

      events = lifecycle_phases()
      assert Enum.map(events, & &1.phase) == [:cancelled]
      assert hd(events).event_id == event.id
      assert hd(events).platform == "telegram"
    end

    test "a yearly parent is returned whole, so future occurrences are visible", %{repo: repo} do
      {:ok, %{event: event, reminders: rows}} =
        create(repo, birthday_params(), caller_target_opts())

      early = Enum.min_by(rows, &DateTime.to_unix(&1.scheduled_for))
      {:ok, [claimed]} = Repo.claim_due_reminders(early.scheduled_for, 10, server: repo)

      {:ok, _delivered} =
        Repo.temporal_reminder_delivered(claimed.id, ~U[2026-09-07 13:00:00Z], server: repo)

      assert {:ok, result} = cancel_referent(repo, now: ~U[2026-09-07 14:00:00Z])

      assert result.event.id == event.id
      assert result.event.recurrence_kind == "yearly"
      assert Registry.event_view(result.event)["recurrence"]["kind"] == "yearly"
    end

    test "no match and no conversation both refuse instead of guessing", %{repo: repo} do
      assert {:error, :no_recent_reminder} =
               cancel_referent(repo, now: ~U[2026-08-16 20:00:00Z])

      {_event, _delivered, _pending} = delivered_and_pending!(repo, ~U[2026-08-15 13:00:00Z])

      assert {:error, :no_conversation_target} =
               cancel_referent(repo, [now: ~U[2026-08-15 14:00:00Z]], %{conversation_key: nil})
    end

    test "the committed cancel notifies the scheduler", %{repo: repo} do
      scheduler = :"cancel_referent_scheduler_#{System.unique_integer([:positive])}"
      start_supervised!({FakeScheduler, name: scheduler, test_pid: self()})

      {_event, _delivered, _pending} = delivered_and_pending!(repo, ~U[2026-08-15 13:00:00Z])

      assert {:ok, _result} =
               cancel_referent(repo, [now: ~U[2026-08-15 14:00:00Z]], %{
                 temporal_scheduler: scheduler
               })

      assert_receive {:scheduler_cast, :event_changed}
    end
  end
end
