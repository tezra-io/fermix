defmodule FermixCore.Tools.EventToolsTest do
  # async: false — the default delivery target, the delivery-channels map, and
  # the channel configuration the owner inbox is derived from are all global
  # `Application` env. Each test's precondition is established in this module's
  # own setup and restored on exit, never inherited.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.EventList
  alias FermixCore.Tools.EventRemove
  alias FermixCore.Tools.EventStore
  alias FermixCore.Tools.EventUpdate

  defmodule FakeAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  @channels %{"telegram" => FakeAdapter, "slack" => FakeAdapter}
  @owner_channels [:telegram, :discord, :signal, :slack, :whatsapp]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-event-tools-#{unique}.db")
    repo_name = :"event_tools_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    previous_jobs = Application.get_env(:fermix_core, :jobs)
    previous_personalization = Application.get_env(:fermix_core, :personalization)
    previous_channels = Map.new(@owner_channels, &{&1, Application.get_env(:fermix_channels, &1)})

    # The tools resolve their delivery target through the real config, so the
    # "no target anywhere" case must establish that no channel carries an owner
    # id rather than inheriting a host or sibling-test answer.
    Enum.each(@owner_channels, &Application.delete_env(:fermix_channels, &1))

    Application.put_env(
      :fermix_core,
      :jobs,
      Keyword.merge(previous_jobs || [],
        default_delivery_mode: "channel",
        default_delivery_target: [platform: "telegram", chat_id: "8217352118"],
        delivery_channels: @channels
      )
    )

    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    on_exit(fn ->
      restore(:jobs, previous_jobs)
      restore(:personalization, previous_personalization)
      Enum.each(previous_channels, fn {channel, value} -> restore_channel(channel, value) end)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp restore_channel(channel, nil), do: Application.delete_env(:fermix_channels, channel)
  defp restore_channel(channel, value), do: Application.put_env(:fermix_channels, channel, value)

  # Second Sunday of March, next year: always inside the America/New_York
  # spring-forward gap at 02:30, and always in the future when the suite runs —
  # no hardcoded date to turn into a time bomb.
  defp next_us_spring_forward do
    march_first = Date.new!(Date.utc_today().year + 1, 3, 1)
    days_to_first_sunday = rem(8 - Date.day_of_week(march_first, :sunday), 7)
    Date.add(march_first, days_to_first_sunday + 7)
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

  defp payload(%{success: true, output: output}), do: Jason.decode!(output)

  defp store_birthday(repo, overrides \\ %{}) do
    args =
      Map.merge(
        %{
          "title" => "Sarah's birthday",
          "kind" => "birthday",
          "when" => %{"type" => "annual", "month" => 9, "day" => 14}
        },
        overrides
      )

    {:ok, result} = EventStore.execute(args, context(repo))
    result
  end

  describe "event_store" do
    test "acknowledges the canonical stored event, plan, recurrence, and platform", %{repo: repo} do
      result = store_birthday(repo)

      assert result.success == true
      stored = payload(result)

      assert stored["title"] == "Sarah's birthday"
      assert stored["recurrence"]["kind"] == "yearly"
      assert stored["recurrence"]["month"] == 9
      assert stored["recurrence"]["day"] == 14
      # Date-robust: the horizon rolls with the real clock, the identity does not.
      assert String.ends_with?(stored["next_occurrence_on"], "-09-14")
      assert stored["delivery"]["platform"] == "telegram"
      assert stored["delivery"]["destination"] == "8217352118"
      assert stored["status"] == "created"

      planned = stored["planned_reminders"]
      assert planned != []
      assert Enum.all?(planned, &(&1["rule_id"] in ["week_before", "day_of"]))
      assert Enum.all?(planned, &is_binary(&1["scheduled_for"]))
      assert Enum.all?(planned, &String.ends_with?(&1["occurrence_key"], "-09-14"))
    end

    test "a fresh install with a configured channel stores through its derived inbox", %{
      repo: repo
    } do
      # The whole point of the derived rung: neither a fresh install nor an
      # upgrade writes [fermix_core.jobs] default_delivery_target, so without
      # derivation the default-on reminder rail refuses on first use. No seams
      # here — this is the production path reading real configuration.
      Application.put_env(:fermix_core, :jobs, delivery_channels: @channels)
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "8217352118")

      stored = payload(store_birthday(repo))

      assert stored["delivery"]["platform"] == "telegram"
      assert stored["delivery"]["destination"] == "8217352118"
      assert stored["delivery"]["source"] == "derived"
    end

    test "the acknowledgement can name a configured target as configured", %{repo: repo} do
      assert payload(store_birthday(repo))["delivery"]["source"] == "configured"
    end

    test "an idempotent repeat reports the existing event rather than a second one", %{repo: repo} do
      first = payload(store_birthday(repo))
      second = payload(store_birthday(repo))

      assert first["status"] == "created"
      assert second["status"] == "existing"
      assert second["event_id"] == first["event_id"]
    end

    test "a failed creation never reads like success", %{repo: repo} do
      Application.put_env(:fermix_core, :jobs, delivery_channels: @channels)

      {:ok, result} =
        EventStore.execute(
          %{
            "title" => "Sarah's birthday",
            "kind" => "birthday",
            "when" => %{"type" => "annual", "month" => 9, "day" => 14}
          },
          context(repo)
        )

      assert result.success == false
      assert result.output == ""
      assert result.error =~ "default_delivery_target"

      assert {:ok, %{events: []}} = Repo.list_temporal_events(%{}, server: repo)
    end

    test "a missing title is refused before any write", %{repo: repo} do
      {:ok, result} =
        EventStore.execute(
          %{"kind" => "birthday", "when" => %{"type" => "annual", "month" => 9, "day" => 14}},
          context(repo)
        )

      assert result.success == false
      assert result.error =~ "title"
      assert {:ok, %{events: []}} = Repo.list_temporal_events(%{}, server: repo)
    end

    test "a DST-gap datetime asks for a real local time", %{repo: repo} do
      {:ok, result} =
        EventStore.execute(
          %{
            "title" => "Spring meeting",
            "kind" => "appointment",
            "when" => %{
              "type" => "datetime",
              "date" => Date.to_iso8601(next_us_spring_forward()),
              "time" => "02:30:00"
            }
          },
          context(repo)
        )

      assert result.success == false
      assert result.error =~ "not exist"
    end

    test "emits one tool telemetry event carrying the model's arguments", %{repo: repo} do
      handler = "event-store-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:fermix, :tool, :exec],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_exec, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      store_birthday(repo)

      assert_receive {:tool_exec, %{duration_ms: duration}, metadata}
      assert metadata.tool == "event_store"
      assert metadata.success == true
      assert duration >= 0
    end
  end

  describe "event_list" do
    test "lists stored events with their delivery target and next reminder", %{repo: repo} do
      store_birthday(repo)

      {:ok, result} = EventList.execute(%{}, context(repo))

      assert result.success == true
      listed = payload(result)

      assert [event] = listed["events"]
      assert event["title"] == "Sarah's birthday"
      assert event["delivery"]["platform"] == "telegram"
      assert is_binary(event["next_reminder_at"])
      assert is_nil(listed["cursor"])
    end

    # The floor is invisible in the result, so the only way the model learns the
    # default is the advertised text. If that sentence goes, "what happened last
    # month" silently returns nothing.
    test "tells the model the default window and how to reach history" do
      assert EventList.description() =~ "from today"

      params = EventList.parameters()
      assert params.properties.from.description =~ "starts at today"
      assert params.properties.status.description =~ "past events"
    end

    test "refuses a date window wider than two years", %{repo: repo} do
      {:ok, result} =
        EventList.execute(%{"from" => "2026-01-01", "to" => "2030-01-01"}, context(repo))

      assert result.success == false
      assert result.error =~ "two years"
    end

    test "returns an opaque cursor the model passes back verbatim", %{repo: repo} do
      base = Date.add(Date.utc_today(), 300)

      for {date, index} <-
            Enum.with_index([Date.to_iso8601(base), Date.to_iso8601(Date.add(base, 31))], 1) do
        {:ok, created} =
          EventStore.execute(
            %{
              "title" => "Deadline #{index}",
              "kind" => "deadline",
              "when" => %{"type" => "date", "date" => date}
            },
            context(repo)
          )

        assert created.success == true
      end

      {:ok, first} = EventList.execute(%{"limit" => 1}, context(repo))
      first_page = payload(first)
      assert is_binary(first_page["cursor"])

      {:ok, second} =
        EventList.execute(%{"limit" => 1, "cursor" => first_page["cursor"]}, context(repo))

      second_page = payload(second)
      assert length(second_page["events"]) == 1

      assert Enum.map(first_page["events"], & &1["title"]) !=
               Enum.map(second_page["events"], & &1["title"])
    end
  end

  describe "event_update" do
    test "patches the stored event and reports the new plan", %{repo: repo} do
      stored = payload(store_birthday(repo))

      {:ok, result} =
        EventUpdate.execute(
          %{
            "event_id" => stored["event_id"],
            "title" => "Sarah's birthday party",
            "reminders" => [%{"type" => "days_before", "days" => 0, "at" => "07:30:00"}]
          },
          context(repo)
        )

      assert result.success == true
      updated = payload(result)

      assert updated["title"] == "Sarah's birthday party"
      assert updated["revision"] == 2
      assert updated["planned_reminders"] != []
      assert Enum.all?(updated["planned_reminders"], &(&1["rule_id"] == "days_before_0"))
    end

    test "rebinds to the current default target on explicit request", %{repo: repo} do
      stored = payload(store_birthday(repo))

      Application.put_env(:fermix_core, :jobs,
        default_delivery_mode: "channel",
        default_delivery_target: [platform: "slack", channel_id: "C99"],
        delivery_channels: @channels
      )

      {:ok, result} =
        EventUpdate.execute(
          %{"event_id" => stored["event_id"], "rebind_delivery_to_default" => true},
          context(repo)
        )

      assert result.success == true
      assert payload(result)["delivery"]["platform"] == "slack"
      assert payload(result)["delivery"]["destination"] == "C99"
    end

    test "an in-flight send surfaces the ask-again contract instead of a silent failure", %{
      repo: repo
    } do
      {:ok, created} =
        EventStore.execute(
          %{
            "title" => "Call the clinic",
            "kind" => "explicit_reminder",
            "when" => %{
              "type" => "datetime",
              "date" => Date.to_iso8601(Date.add(Date.utc_today(), 365)),
              "time" => "09:00:00"
            }
          },
          context(repo)
        )

      event_id = payload(created)["event_id"]

      # Claim at the reminder's own scheduled instant — derived, never
      # hardcoded: a fixed future timestamp paired with a relative event date
      # becomes a time bomb the day the calendar catches up.
      {:ok, due_at, 0} =
        payload(created)["planned_reminders"]
        |> List.first()
        |> Map.fetch!("scheduled_for")
        |> DateTime.from_iso8601()

      assert {:ok, [_claimed]} = Repo.claim_due_reminders(due_at, 5, server: repo)

      {:ok, result} =
        EventUpdate.execute(
          %{"event_id" => event_id, "title" => "Call the dentist"},
          context(repo)
        )

      assert result.success == false
      assert result.error =~ "try again"
    end

    test "a missing event_id is refused", %{repo: repo} do
      {:ok, result} = EventUpdate.execute(%{"title" => "x"}, context(repo))

      assert result.success == false
      assert result.error =~ "event_id"
    end
  end

  describe "event_remove" do
    test "soft-cancels the event and its unsent reminders", %{repo: repo} do
      stored = payload(store_birthday(repo))

      {:ok, result} = EventRemove.execute(%{"event_id" => stored["event_id"]}, context(repo))

      assert result.success == true
      assert payload(result)["status"] == "cancelled"

      assert {:ok, event} = Repo.get_temporal_event(stored["event_id"], server: repo)
      assert event.status == "cancelled"

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: stored["event_id"]}, server: repo)

      assert Enum.all?(rows, &(&1.status == "cancelled"))
    end

    test "an unknown event id is refused, not silently accepted", %{repo: repo} do
      {:ok, result} = EventRemove.execute(%{"event_id" => "evt_missing"}, context(repo))

      assert result.success == false
      assert result.error =~ "not"
    end
  end

  # "cancel that" right after a reminder arrived. The model cannot see the
  # delivered reminder — delivery inserts no conversation row — so the referent
  # is resolved server-side from the outbox, exactly as "snooze that" is.
  describe "event_remove — implicit \"cancel that\"" do
    setup do
      # The caller's own conversation IS the delivery target: the only
      # configuration in which an omitted id can resolve anything.
      Application.put_env(
        :fermix_core,
        :jobs,
        Keyword.merge(Application.get_env(:fermix_core, :jobs, []),
          default_delivery_target: [platform: "telegram", chat_id: "555"]
        )
      )

      :ok
    end

    defp target_chat(chat_id) do
      Application.put_env(
        :fermix_core,
        :jobs,
        Keyword.merge(Application.get_env(:fermix_core, :jobs, []),
          default_delivery_target: [platform: "telegram", chat_id: chat_id]
        )
      )
    end

    # A far-future timed event with exactly one reminder, so claiming at its due
    # instant claims that row and nothing else.
    defp store_timed!(repo, title, days_out) do
      {:ok, result} =
        EventStore.execute(
          %{
            "title" => title,
            "kind" => "explicit_reminder",
            "when" => %{
              "type" => "datetime",
              "date" => Date.to_iso8601(Date.add(Date.utc_today(), days_out)),
              "time" => "09:00:00"
            },
            "reminders" => [%{"type" => "at_time"}]
          },
          context(repo)
        )

      payload(result)
    end

    # Delivers the event's EARLIEST planned reminder. Claiming at that instant
    # leaves no sibling mid-send, which a later cancel would refuse.
    defp deliver!(repo, stored, sent_at) do
      reminder = Enum.min_by(stored["planned_reminders"], & &1["scheduled_for"])
      {:ok, due, _offset} = DateTime.from_iso8601(reminder["scheduled_for"])

      {:ok, claimed} = Repo.claim_due_reminders(due, 10, server: repo)
      assert [row] = claimed
      assert row.id == reminder["reminder_id"]

      {:ok, delivered} = Repo.temporal_reminder_delivered(row.id, sent_at, server: repo)
      delivered
    end

    test "tells the model the id may be omitted right after a reminder arrived" do
      assert EventRemove.description() =~ "most recent"
      assert EventRemove.when_to_use() =~ "cancel that"

      params = EventRemove.parameters()
      assert params.required == []
      assert params.properties.event_id.description =~ "Leave it out"
    end

    test "resolves the reminder most recently delivered here and names what it cancelled", %{
      repo: repo
    } do
      older = store_timed!(repo, "Submit the report", 400)
      newer = store_timed!(repo, "Call the vet", 401)

      _stale = deliver!(repo, older, DateTime.add(DateTime.utc_now(), -2, :hour))
      recent = deliver!(repo, newer, DateTime.add(DateTime.utc_now(), -5, :minute))

      {:ok, result} = EventRemove.execute(%{}, context(repo))

      assert result.success == true
      view = payload(result)

      assert view["event_id"] == newer["event_id"]
      assert view["title"] == "Call the vet"
      assert view["kind"] == "explicit_reminder"
      assert view["status"] == "cancelled"
      assert view["recurrence"]["kind"] == "once"
      assert view["source_reminder_id"] == recent.id

      assert {:ok, cancelled} = Repo.get_temporal_event(newer["event_id"], server: repo)
      assert cancelled.status == "cancelled"

      # The older conversation-mate is untouched: "that" is one reminder, not a sweep.
      assert {:ok, untouched} = Repo.get_temporal_event(older["event_id"], server: repo)
      assert untouched.status == "active"
    end

    # Cancelling a yearly event ends every future occurrence, so the payload the
    # model echoes must say the event recurs — silence there reads as "just this one".
    test "a yearly parent's cancellation is visible as yearly in the payload", %{repo: repo} do
      stored = payload(store_birthday(repo))
      delivered = deliver!(repo, stored, DateTime.utc_now())

      {:ok, result} = EventRemove.execute(%{}, context(repo))

      assert result.success == true
      view = payload(result)

      assert view["event_id"] == stored["event_id"]
      assert view["title"] == "Sarah's birthday"
      assert view["status"] == "cancelled"
      assert view["recurrence"]["kind"] == "yearly"
      assert view["recurrence"]["month"] == 9
      assert view["recurrence"]["day"] == 14
      assert view["source_reminder_id"] == delivered.id
    end

    test "with nothing delivered here, it asks which event instead of guessing", %{repo: repo} do
      stored = payload(store_birthday(repo))

      {:ok, result} = EventRemove.execute(%{}, context(repo))

      assert result.success == false
      assert result.error =~ "which event"

      assert {:ok, untouched} = Repo.get_temporal_event(stored["event_id"], server: repo)
      assert untouched.status == "active"
    end

    # One axis of the target triple proves the wiring; the query's five axes are
    # pinned exhaustively by the snooze resolution tests.
    test "a reminder delivered into another conversation never resolves here", %{repo: repo} do
      target_chat("999")
      elsewhere = store_timed!(repo, "Submit the report", 400)
      _delivered = deliver!(repo, elsewhere, DateTime.utc_now())
      target_chat("555")

      {:ok, result} = EventRemove.execute(%{}, context(repo))

      assert result.success == false
      assert result.error =~ "which event"

      assert {:ok, untouched} = Repo.get_temporal_event(elsewhere["event_id"], server: repo)
      assert untouched.status == "active"
    end

    test "an explicit event_id cancels that event and never consults the outbox", %{repo: repo} do
      delivered_here = store_timed!(repo, "Call the vet", 401)
      _recent = deliver!(repo, delivered_here, DateTime.add(DateTime.utc_now(), -5, :minute))
      named = payload(store_birthday(repo))

      {:ok, result} = EventRemove.execute(%{"event_id" => named["event_id"]}, context(repo))

      assert result.success == true
      view = payload(result)

      assert view["event_id"] == named["event_id"]
      assert view["status"] == "cancelled"
      refute Map.has_key?(view, "source_reminder_id")

      assert {:ok, untouched} = Repo.get_temporal_event(delivered_here["event_id"], server: repo)
      assert untouched.status == "active"
    end
  end
end
