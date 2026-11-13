defmodule FermixCore.Tools.EventCardsTest do
  @moduledoc """
  EVENTS_DRAWN_AS_CARDS §04 and §05: each event tool hands the events it
  returned to the reply's blocks holder, as `checklist_edit` hands its lists,
  and the reply's `events` block carries each once, in its last state.
  """

  # async: false — the default delivery target, the delivery-channels map and
  # the personalization timezone are global `Application` env, established
  # here and restored on exit, as the event tools' own tests do.
  use ExUnit.Case, async: false

  alias FermixCore.Companion.Protocol
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.EventList
  alias FermixCore.Tools.EventRemove
  alias FermixCore.Tools.EventStore
  alias FermixCore.Tools.EventUpdate
  alias FermixCore.Tools.ReminderSnooze
  alias FermixTestSupport.WireSchema

  defmodule FakeAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  @schema_path Application.app_dir(:fermix_core, "priv/companion/protocol.schema.json")
  @channels %{"telegram" => FakeAdapter}
  @owner_channels [:telegram, :discord, :signal, :slack, :whatsapp]
  @tz "America/New_York"
  @chat {"companion", "main", :root}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-event-cards-#{unique}.db")
    repo_name = :"event_cards_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})
    holder = start_supervised!({ReplyBlocks, name: nil})

    previous_jobs = Application.get_env(:fermix_core, :jobs)
    previous_personalization = Application.get_env(:fermix_core, :personalization)
    previous_channels = Map.new(@owner_channels, &{&1, Application.get_env(:fermix_channels, &1)})
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

    Application.put_env(:fermix_core, :personalization, timezone: @tz)

    on_exit(fn ->
      restore(:jobs, previous_jobs)
      restore(:personalization, previous_personalization)
      Enum.each(previous_channels, fn {channel, value} -> restore_channel(channel, value) end)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{context: context(repo_name, holder), holder: holder}
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp restore_channel(channel, nil), do: Application.delete_env(:fermix_channels, channel)
  defp restore_channel(channel, value), do: Application.put_env(:fermix_channels, channel, value)

  defp context(repo, holder) do
    %{
      agent_name: "main",
      conversation_key: @chat,
      session_id: "sess-cards",
      source_trust: :operator,
      computer_use_origin: :interactive,
      memory_agent_id: "main",
      memory_owner_id: "default",
      memory_repo: repo,
      temporal_scheduler: nil,
      reply_blocks: holder
    }
  end

  defp payload(%{success: true, output: output}), do: Jason.decode!(output)

  # The reply's `events` block, as the turn writer builds it of what it takes.
  defp events(holder) do
    case holder |> ReplyBlocks.take(@chat) |> ReplyBlocks.events() do
      [%{"type" => "events", "events" => events}] -> events
      [] -> []
    end
  end

  defp in_days(days), do: Date.to_iso8601(Date.add(Date.utc_today(), days))

  defp store!(context, args) do
    {:ok, result} = EventStore.execute(args, context)
    payload(result)
  end

  defp dentist(context, days \\ 10) do
    store!(context, %{
      "title" => "Dentist",
      "kind" => "appointment",
      "when" => %{"type" => "datetime", "date" => in_days(days), "time" => "10:30:00"}
    })
  end

  describe "each event tool hands over the events it returned" do
    test "event_store: the stored event, its plan and its target in words", %{
      context: context,
      holder: holder
    } do
      stored = dentist(context)

      assert [card] = events(holder)

      assert card == %{
               "event_id" => stored["event_id"],
               "title" => "Dentist",
               "kind" => "appointment",
               "date" => in_days(10),
               "time" => "10:30",
               "timezone" => @tz,
               "status" => "active",
               "change" => "stored",
               "when" => stored["stated_as"],
               "reminds" => "1 day and 1 hour before",
               "rings" => "on Telegram"
             }

      assert byte_size(Jason.encode!(card)) < 400
    end

    test "event_update: the event as changed", %{context: context, holder: holder} do
      stored = dentist(context)
      _ = events(holder)

      {:ok, result} =
        EventUpdate.execute(%{"event_id" => stored["event_id"], "title" => "Dentist, Dr Lee"}, context)

      updated = payload(result)
      assert [card] = events(holder)
      assert %{"change" => "changed", "title" => "Dentist, Dr Lee"} = card
      assert card["when"] == updated["stated_as"]
      assert card["reminds"] == "1 day and 1 hour before"
    end

    test "event_remove: a cancelled event, with no reminder left to say", %{
      context: context,
      holder: holder
    } do
      stored = dentist(context)
      _ = events(holder)

      {:ok, %{success: true}} = EventRemove.execute(%{"event_id" => stored["event_id"]}, context)

      assert [card] = events(holder)
      assert %{"status" => "cancelled", "change" => "cancelled", "time" => "10:30"} = card
      refute Map.has_key?(card, "reminds")
      refute Map.has_key?(card, "rings")
      assert card["when"] == stored["stated_as"]
    end

    test "event_list: each event it listed, with no change", %{context: context, holder: holder} do
      stored = dentist(context)
      _ = events(holder)

      {:ok, %{success: true}} = EventList.execute(%{}, context)

      assert [card] = events(holder)
      assert card["event_id"] == stored["event_id"]
      refute Map.has_key?(card, "change")
      assert card["reminds"] == "1 day and 1 hour before"
      assert card["rings"] == "on Telegram"
    end

    test "reminder_snooze: the event, and when its reminder rings next", %{
      context: context,
      holder: holder
    } do
      stored =
        store!(context, %{
          "title" => "Submit the report",
          "kind" => "explicit_reminder",
          "when" => %{"type" => "datetime", "date" => in_days(400), "time" => "09:00:00"},
          "reminders" => [%{"type" => "at_time"}]
        })

      [reminder] = stored["planned_reminders"]
      _ = events(holder)

      snooze = %{"type" => "datetime", "date" => in_days(30), "time" => "15:40:00"}

      {:ok, result} =
        ReminderSnooze.execute(%{"reminder_id" => reminder["reminder_id"], "snooze" => snooze}, context)

      assert payload(result)["status"] == "snoozed"
      assert [card] = events(holder)
      assert %{"change" => "snoozed", "rings" => "on Telegram"} = card
      assert card["reminds"] =~ ~r/\Aagain on [A-Z][a-z]+day, [A-Z][a-z]+ \d{1,2}(, \d{4})? at 3:40 PM E[SD]T\z/
    end
  end

  describe "the reply's events block" do
    test "a turn that stores then changes the same event carries it once, as changed", %{
      context: context,
      holder: holder
    } do
      stored = dentist(context)

      {:ok, %{success: true}} =
        EventUpdate.execute(%{"event_id" => stored["event_id"], "title" => "Dentist, moved"}, context)

      assert [%{"event_id" => id, "change" => "changed", "title" => "Dentist, moved"}] =
               events(holder)

      assert id == stored["event_id"]
    end

    test "a list of twelve carries eight, the ones the turn changed first, the rest by date", %{
      context: context,
      holder: holder
    } do
      for day <- 12..1//-1 do
        store!(context, %{
          "title" => "Errand #{day}",
          "kind" => "deadline",
          "when" => %{"type" => "date", "date" => in_days(day + 20)}
        })
      end

      _ = events(holder)
      late = store!(context, %{"title" => "Late one", "kind" => "deadline", "when" => %{"type" => "date", "date" => in_days(90)}})
      {:ok, %{success: true}} = EventList.execute(%{}, context)

      cards = events(holder)
      assert length(cards) == ReplyBlocks.max_events()
      assert hd(cards)["event_id"] == late["event_id"]
      assert hd(cards)["change"] == "stored"
      assert Enum.map(tl(cards), & &1["title"]) == Enum.map(1..7, &"Errand #{&1}")
      assert Enum.all?(tl(cards), &(not Map.has_key?(&1, "change")))
    end

    test "a yearly event: its next occurrence, its yearly mark and the stored sentence", %{
      context: context,
      holder: holder
    } do
      stored =
        store!(context, %{
          "title" => "Mum's birthday",
          "kind" => "birthday",
          "when" => %{"type" => "annual", "month" => 9, "day" => 14}
        })

      assert [card] = events(holder)
      assert card["yearly"] == true
      assert card["date"] == stored["next_occurrence_on"]
      assert String.ends_with?(card["date"], "-09-14")
      refute Map.has_key?(card, "time")
      assert card["when"] =~ ~r/\Aevery September 14 — next on /
      assert card["reminds"] == "1 week before and on the day, at 9:00 AM"
    end

    test "a timer: a reminder minutes away, at its time", %{context: context, holder: holder} do
      store!(context, %{
        "title" => "Tea",
        "kind" => "explicit_reminder",
        "when" => %{"type" => "relative", "amount" => 10, "unit" => "minutes"}
      })

      assert [card] = events(holder)
      assert %{"kind" => "explicit_reminder", "reminds" => "at the time"} = card
      assert card["time"] =~ ~r/\A\d{2}:\d{2}\z/
      refute Map.has_key?(card, "yearly")
    end

    test "a turn that touched no event has no block, and a refused call hands nothing", %{
      context: context,
      holder: holder
    } do
      assert events(holder) == []

      {:ok, %{success: false}} =
        EventUpdate.execute(%{"event_id" => "evt_aaaaaaaaaaaaaaaa", "title" => "x"}, context)

      {:ok, %{success: false}} = EventList.execute(%{"from" => "2020-01-01", "to" => "2029-01-01"}, context)

      assert ReplyBlocks.take(holder, @chat) == []
    end

    test "the block is what the exported schema describes and the codec takes", %{
      context: context,
      holder: holder
    } do
      schema = @schema_path |> File.read!() |> Jason.decode!()
      dentist(context)

      store!(context, %{
        "title" => "Mum's birthday",
        "kind" => "birthday",
        "when" => %{"type" => "annual", "month" => 9, "day" => 14}
      })

      [block] = holder |> ReplyBlocks.take(@chat) |> ReplyBlocks.events()
      assert WireSchema.errors(block, WireSchema.ref("replyBlock"), schema) == []

      done = %{"turn_id" => "t-1", "server_seq" => 3, "text" => "Done.", "blocks" => [block]}
      assert :ok = Protocol.validate_server_payload("text_done", done)

      drifted = put_in(block, ["events", Access.at(0), "status"], "maybe")
      refute WireSchema.errors(drifted, WireSchema.ref("replyBlock"), schema) == []

      assert {:error, {:invalid_field, "blocks"}} =
               Protocol.validate_server_payload("text_done", %{done | "blocks" => [drifted]})
    end
  end
end
