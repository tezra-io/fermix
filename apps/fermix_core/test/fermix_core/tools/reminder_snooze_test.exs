defmodule FermixCore.Tools.ReminderSnoozeTest do
  # async: false — the default delivery target, the delivery-channels map, and
  # the personalization timezone are global `Application` env. Each precondition
  # is established in this module's own setup and restored on exit, never
  # inherited from whatever an earlier module left behind.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.DeliverySupervisor
  alias FermixCore.Temporal.DeliveryWorker
  alias FermixCore.Tools.EventStore
  alias FermixCore.Tools.EventUpdate
  alias FermixCore.Tools.ReminderSnooze

  defmodule FakeAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  # A fake channel adapter answering from a named Agent. The reminder's
  # destination IS that agent's name, so no test-only send option is smuggled
  # through the real send path.
  defmodule ScriptedAdapter do
    @moduledoc false

    def send_message(destination, text, opts) do
      destination
      |> String.to_existing_atom()
      |> Agent.get_and_update(fn state ->
        {:ok, %{state | calls: state.calls ++ [%{text: text, opts: opts}]}}
      end)
    end
  end

  @channels %{"telegram" => FakeAdapter, "slack" => FakeAdapter}
  @tz "America/New_York"

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-reminder-snooze-#{unique}.db")
    repo_name = :"reminder_snooze_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    previous_jobs = Application.get_env(:fermix_core, :jobs)
    previous_personalization = Application.get_env(:fermix_core, :personalization)

    Application.put_env(
      :fermix_core,
      :jobs,
      Keyword.merge(previous_jobs || [],
        default_delivery_mode: "channel",
        default_delivery_target: [platform: "telegram", chat_id: "555"],
        delivery_channels: @channels
      )
    )

    Application.put_env(:fermix_core, :personalization, timezone: @tz)

    on_exit(fn ->
      restore(:jobs, previous_jobs)
      restore(:personalization, previous_personalization)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name, unique: unique}
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

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

  # An absolute local wall time inside the 90-day snooze horizon and well before
  # the fixture event, so two calls name the SAME instant — the only form under
  # which a repeat can be an identical re-snooze.
  defp snooze_at(time) do
    %{
      "type" => "datetime",
      "date" => Date.to_iso8601(Date.add(Date.utc_today(), 30)),
      "time" => time
    }
  end

  # A far-future timed event, so its boundary is always ahead of a snooze of a
  # few hours no matter when the suite runs.
  defp store_reminder!(repo, title \\ "Submit the report") do
    {:ok, result} =
      EventStore.execute(
        %{
          "title" => title,
          "kind" => "explicit_reminder",
          "when" => %{
            "type" => "datetime",
            "date" => Date.to_iso8601(Date.add(Date.utc_today(), 400)),
            "time" => "09:00:00"
          },
          "reminders" => [%{"type" => "at_time"}]
        },
        context(repo)
      )

    stored = payload(result)
    [reminder] = stored["planned_reminders"]
    {stored, reminder}
  end

  describe "reminder_snooze — contract" do
    test "declares the scheduling, attended-owner shape the family shares" do
      assert ReminderSnooze.name() == "reminder_snooze"
      assert ReminderSnooze.category() == :scheduling
      assert is_binary(ReminderSnooze.description())
      assert ReminderSnooze.when_to_use() =~ "snooze"
      assert ReminderSnooze.requires_setup() == nil

      params = ReminderSnooze.parameters()
      assert params.required == ["snooze"]
      assert Map.has_key?(params.properties, :reminder_id)
      assert Map.has_key?(params.properties, :snooze)
      assert Map.has_key?(params.properties, :confirm_past_boundary)
    end
  end

  describe "reminder_snooze — execution" do
    test "defers an explicitly named reminder and acknowledges the stored values", %{repo: repo} do
      {stored, reminder} = store_reminder!(repo)

      {:ok, result} =
        ReminderSnooze.execute(
          %{
            "reminder_id" => reminder["reminder_id"],
            "snooze" => %{"type" => "duration", "amount" => 2, "unit" => "hours"}
          },
          context(repo)
        )

      assert result.success == true
      view = payload(result)

      assert view["status"] == "snoozed"
      assert view["event_id"] == stored["event_id"]
      assert view["title"] == "Submit the report"
      assert view["kind"] == "explicit_reminder"
      assert view["source_reminder_id"] == reminder["reminder_id"]
      assert view["timezone"] == @tz
      assert view["delivery"]["platform"] == "telegram"
      assert view["delivery"]["destination"] == "555"
      assert view["replaced_earlier_snooze"] == false
      assert is_binary(view["scheduled_for"])
      assert is_binary(view["scheduled_for_local"])
      assert is_binary(view["zone_abbr"])
      assert view["rule_id"] =~ "snooze:"

      # The explicitly named pending source is retired; exactly one row is live.
      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: stored["event_id"]}, server: repo)

      assert Enum.count(rows, &(&1.status == "pending")) == 1
      assert Enum.find(rows, &(&1.id == reminder["reminder_id"])).status == "superseded"
    end

    test "\"snooze that\" resolves the last delivered reminder in this conversation", %{
      repo: repo
    } do
      {stored, reminder} = store_reminder!(repo)

      {:ok, due, _offset} = DateTime.from_iso8601(reminder["scheduled_for"])
      {:ok, [claimed]} = Repo.claim_due_reminders(due, 5, server: repo)

      # Delivered "just now" in real time, so the 24-hour lookback covers it.
      {:ok, _delivered} =
        Repo.temporal_reminder_delivered(claimed.id, DateTime.utc_now(), server: repo)

      {:ok, result} =
        ReminderSnooze.execute(
          %{"snooze" => %{"type" => "duration", "amount" => 30, "unit" => "minutes"}},
          context(repo)
        )

      assert result.success == true
      view = payload(result)
      assert view["source_reminder_id"] == reminder["reminder_id"]
      assert view["event_id"] == stored["event_id"]

      # Sent history is immutable: the delivered source stays delivered.
      assert {:ok, source} =
               Repo.get_temporal_reminder(reminder["reminder_id"], server: repo)

      assert source.status == "delivered"
    end

    test "with nothing recent, it asks which event instead of guessing", %{repo: repo} do
      {:ok, result} =
        ReminderSnooze.execute(
          %{"snooze" => %{"type" => "duration", "amount" => 1, "unit" => "hours"}},
          context(repo)
        )

      assert result.success == false
      assert result.error =~ "which event"
      assert result.error =~ "reminder_id"
    end

    test "a missing snooze form is refused with the two accepted shapes", %{repo: repo} do
      {_stored, reminder} = store_reminder!(repo)

      {:ok, result} =
        ReminderSnooze.execute(%{"reminder_id" => reminder["reminder_id"]}, context(repo))

      assert result.success == false
      assert result.error =~ "duration"
      assert result.error =~ "datetime"
    end

    test "a second snooze replaces the first and says so", %{repo: repo} do
      {stored, reminder} = store_reminder!(repo)

      args = fn hours ->
        %{
          "reminder_id" => reminder["reminder_id"],
          "snooze" => %{"type" => "duration", "amount" => hours, "unit" => "hours"}
        }
      end

      {:ok, first} = ReminderSnooze.execute(args.(1), context(repo))
      {:ok, second} = ReminderSnooze.execute(args.(3), context(repo))

      assert payload(first)["replaced_earlier_snooze"] == false
      assert payload(second)["replaced_earlier_snooze"] == true
      assert payload(second)["note"] =~ "replaced"

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: stored["event_id"]}, server: repo)

      assert Enum.count(rows, &(&1.status == "pending")) == 1
    end

    test "an identical repeat never implies a second reminder", %{repo: repo} do
      {_stored, reminder} = store_reminder!(repo)

      args = %{
        "reminder_id" => reminder["reminder_id"],
        "snooze" => snooze_at("09:00:00")
      }

      {:ok, first} = ReminderSnooze.execute(args, context(repo))
      {:ok, repeat} = ReminderSnooze.execute(args, context(repo))

      assert payload(first)["status"] == "snoozed"
      assert payload(repeat)["status"] == "already_snoozed"
      assert payload(repeat)["reminder_id"] == payload(first)["reminder_id"]
      assert payload(repeat)["note"] =~ "already"
    end

    # An acknowledged snooze must be a snooze that can still fire. Both chains
    # end on a row the scheduler claims, because "already snoozed" over a row in
    # a terminal state is a promise nothing will keep.
    test "re-snoozing after an event edit cancelled the first one leaves a claimable row", %{
      repo: repo
    } do
      {stored, reminder} = store_reminder!(repo)

      args = %{
        "reminder_id" => reminder["reminder_id"],
        "snooze" => snooze_at("09:00:00")
      }

      {:ok, first} = ReminderSnooze.execute(args, context(repo))
      snooze_id = payload(first)["reminder_id"]

      # The revision bump cancels every pending row of the older revision.
      {:ok, updated} =
        EventUpdate.execute(
          %{"event_id" => stored["event_id"], "title" => "Submit the revised report"},
          context(repo)
        )

      assert updated.success == true
      assert {:ok, cancelled} = Repo.get_temporal_reminder(snooze_id, server: repo)
      assert cancelled.status == "cancelled"

      {:ok, again} = ReminderSnooze.execute(args, context(repo))

      assert again.success == true
      assert payload(again)["status"] == "snoozed"
      assert payload(again)["reminder_id"] == snooze_id

      assert {:ok, revived} = Repo.get_temporal_reminder(snooze_id, server: repo)
      assert revived.status == "pending"

      assert {:ok, claimed} =
               Repo.claim_due_reminders(revived.scheduled_for, 10, server: repo)

      assert Enum.any?(claimed, &(&1.id == snooze_id))
    end

    test "snoozing back to an earlier time revives it and replaces the later one", %{repo: repo} do
      {stored, reminder} = store_reminder!(repo)

      args = fn at ->
        %{
          "reminder_id" => reminder["reminder_id"],
          "snooze" => snooze_at(at)
        }
      end

      {:ok, first} = ReminderSnooze.execute(args.("09:00:00"), context(repo))
      {:ok, second} = ReminderSnooze.execute(args.("11:00:00"), context(repo))
      {:ok, third} = ReminderSnooze.execute(args.("09:00:00"), context(repo))

      early_id = payload(first)["reminder_id"]
      late_id = payload(second)["reminder_id"]

      assert payload(third)["status"] == "snoozed"
      assert payload(third)["reminder_id"] == early_id
      assert payload(third)["replaced_earlier_snooze"] == true
      assert payload(third)["note"] =~ "replaced"

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: stored["event_id"]}, server: repo)

      snoozes = Enum.filter(rows, &(&1.source_reminder_id == reminder["reminder_id"]))
      assert Enum.count(snoozes, &(&1.status == "pending")) == 1
      assert Enum.find(snoozes, &(&1.id == early_id)).status == "pending"
      assert Enum.find(snoozes, &(&1.id == late_id)).status == "superseded"
    end

    test "a snooze mid-send blocks a second one instead of arming two sends", %{repo: repo} do
      {_stored, reminder} = store_reminder!(repo)

      {:ok, first} =
        ReminderSnooze.execute(
          %{
            "reminder_id" => reminder["reminder_id"],
            "snooze" => snooze_at("09:00:00")
          },
          context(repo)
        )

      snooze_id = payload(first)["reminder_id"]
      {:ok, snoozed} = Repo.get_temporal_reminder(snooze_id, server: repo)
      {:ok, claimed} = Repo.claim_due_reminders(snoozed.scheduled_for, 10, server: repo)
      assert Enum.find(claimed, &(&1.id == snooze_id)).status == "delivering"

      {:ok, second} =
        ReminderSnooze.execute(
          %{
            "reminder_id" => reminder["reminder_id"],
            "snooze" => snooze_at("11:00:00")
          },
          context(repo)
        )

      assert second.success == false
      assert second.error =~ "being delivered right now"

      assert {:ok, rows} =
               Repo.list_temporal_reminders(%{event_id: snoozed.event_id}, server: repo)

      snoozes = Enum.filter(rows, &(&1.source_reminder_id == reminder["reminder_id"]))
      assert length(snoozes) == 1
    end

    test "emits exactly one tool telemetry event carrying the model's arguments", %{repo: repo} do
      handler = "reminder-snooze-telemetry-#{System.unique_integer([:positive])}"
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

      {_stored, reminder} = store_reminder!(repo)
      # Drop the event_store event the fixture emitted.
      assert_receive {:tool_exec, _measurements, %{tool: "event_store"}}

      {:ok, _result} =
        ReminderSnooze.execute(
          %{
            "reminder_id" => reminder["reminder_id"],
            "snooze" => %{"type" => "duration", "amount" => 1, "unit" => "hours"}
          },
          context(repo)
        )

      assert_receive {:tool_exec, %{duration_ms: duration}, metadata}
      assert metadata.tool == "reminder_snooze"
      assert metadata.success == true
      assert duration >= 0
      refute_receive {:tool_exec, _more, _metadata}
    end
  end

  describe "reminder_snooze — attended-owner gate" do
    test "advertisement and execution both refuse a non-attended turn", %{repo: repo} do
      unattended = context(repo, %{computer_use_origin: :unattended})

      refute ReminderSnooze.advertise?(unattended)

      {:ok, result} =
        ReminderSnooze.execute(
          %{"snooze" => %{"type" => "duration", "amount" => 1, "unit" => "hours"}},
          unattended
        )

      assert result.success == false
      assert result.error =~ "reminder_snooze"
    end

    test "an attended top-level operator turn is advertised", %{repo: repo} do
      assert ReminderSnooze.advertise?(context(repo))
    end
  end

  # The snooze row is an ordinary outbox row: it must claim, render, send, and
  # settle through the SHIPPED worker with no snooze-specific delivery path.
  describe "a snooze row delivers end to end" do
    setup %{repo: repo, unique: unique} do
      supervisor = :"reminder_snooze_sup_#{unique}"
      channel = :"reminder_snooze_channel_#{unique}"

      start_supervised!({DeliverySupervisor, name: supervisor})

      start_supervised!(%{
        id: {:channel, channel},
        start: {Agent, :start_link, [fn -> %{calls: []} end, [name: channel]]},
        restart: :temporary
      })

      Application.put_env(
        :fermix_core,
        :jobs,
        Keyword.merge(Application.get_env(:fermix_core, :jobs, []),
          default_delivery_target: [platform: "telegram", chat_id: Atom.to_string(channel)]
        )
      )

      %{repo: repo, supervisor: supervisor, channel: channel}
    end

    test "renders the copied payload and settles delivered", ctx do
      {_stored, reminder} = store_reminder!(ctx.repo, "Submit the report")

      {:ok, snoozed} =
        ReminderSnooze.execute(
          %{
            "reminder_id" => reminder["reminder_id"],
            "snooze" => %{"type" => "duration", "amount" => 1, "unit" => "hours"}
          },
          context(ctx.repo)
        )

      snooze_id = payload(snoozed)["reminder_id"]
      due = DateTime.add(DateTime.utc_now(), 2, :hour)

      {:ok, claimed} = Repo.claim_due_reminders(due, 5, server: ctx.repo)
      row = Enum.find(claimed, &(&1.id == snooze_id))
      assert row.status == "delivering"

      {:ok, pid} =
        DeliverySupervisor.start_delivery(ctx.supervisor, DeliveryWorker, %{
          reminder: row,
          repo: ctx.repo,
          now_fn: fn -> due end,
          delivery_opts: [adapter: ScriptedAdapter]
        })

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      assert [%{text: text}] = Agent.get(ctx.channel, & &1.calls)
      assert text =~ "Submit the report"
      assert text =~ "9:00 AM"

      assert {:ok, settled} = Repo.get_temporal_reminder(snooze_id, server: ctx.repo)
      assert settled.status == "delivered"
      assert settled.sent_at != nil
      assert settled.source_reminder_id == reminder["reminder_id"]
    end
  end
end
