defmodule FermixCore.Temporal.Card do
  @moduledoc """
  An event as a reply draws it (EVENTS_DRAWN_AS_CARDS §04): the record an
  event tool returned, in the `events` block's shape, with the engine's words
  for when it is and when and where it reminds, written once here for every
  surface. A receipt, not a live view: the event as the reply left it.

  A card is `event_id`, `title` and `kind` as stored; `date`, the occurrence
  the reply is about in the event's own zone (a yearly event's next one), and
  `time` (`HH:MM`) only for an event with a time; `timezone`; `yearly: true`
  for a yearly event; `status` (`active`, `completed` or `cancelled`);
  `change`, what the turn did (`stored`, `changed`, `cancelled`, `snoozed`),
  absent for an event it only listed or found already so; `when`, the
  occurrence as `Temporal.Registry.stated_as/2` states it; and `reminds` and
  `rings`, the plan and the target in words, both absent with no reminder
  left. For a snooze, `reminds` says when it rings next.

  Pure, beside `Temporal.Renderer`, whose clock and calendar words it uses,
  except `put/2`, which hands the cards to the reply's blocks holder
  (`FermixCore.ReplyBlocks.put_events/3`), as `checklist_edit` hands over the
  lists it touched. A card that cannot be made (a stored row whose date
  cannot be read) is logged and left out: the tool's own answer already went
  to the model, and a reply with one card fewer still stands as text.
  """

  require Logger

  alias FermixCore.ReplyBlocks
  alias FermixCore.Temporal.Defaults
  alias FermixCore.Temporal.Registry
  alias FermixCore.Temporal.Renderer

  # The units a lead is said in, largest first, each with its length in seconds.
  @units [{"week", 604_800}, {"day", 86_400}, {"hour", 3_600}, {"minute", 60}, {"second", 1}]
  # Where a reminder rings, by the platform its row snapshotted.
  @platform_words %{
    "telegram" => "on Telegram",
    "slack" => "on Slack",
    "discord" => "on Discord",
    "signal" => "on Signal",
    "whatsapp" => "on WhatsApp",
    "imessage" => "on iMessage",
    "computer" => "on your computer"
  }

  @typedoc "One event as the `events` block carries it, string keyed."
  @type t :: %{required(String.t()) => term()}

  @doc """
  The card of an event `event_store` stored (`Registry.create_event/3`'s
  result): `change: "stored"`, or none when it was already stored.
  """
  @spec stored(map()) :: {:ok, t()} | {:error, term()}
  def stored(%{status: status, event: event, reminders: reminders, stated_as: stated_as})
      when status in [:created, :existing] and is_list(reminders) and is_binary(stated_as) do
    with {:ok, card} <- base(event, stated_as) do
      {:ok, card |> put_change(status == :created, "stored") |> put_plan(event, reminders != [])}
    end
  end

  @doc "The card of an event `event_update` changed (`Registry.update_event/4`'s result)."
  @spec changed(map()) :: {:ok, t()} | {:error, term()}
  def changed(%{event: event, reminders: reminders, stated_as: stated_as})
      when is_list(reminders) and is_binary(stated_as) do
    with {:ok, card} <- base(event, stated_as) do
      {:ok, card |> Map.put("change", "changed") |> put_plan(event, reminders != [])}
    end
  end

  @doc """
  The card of an event `event_remove` cancelled, stated at `now`: no
  reminder is left, so it carries neither `reminds` nor `rings`.
  """
  @spec cancelled(map(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def cancelled(%{} = event, %DateTime{} = now) do
    with {:ok, card} <- stated(event, now) do
      {:ok, Map.put(card, "change", "cancelled")}
    end
  end

  @doc """
  The card of an event `event_list` returned, stated at `now`: its plan while
  a reminder of it is still pending (`next_reminder_at`), else none.
  """
  @spec listed(map(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def listed(%{} = event, %DateTime{} = now) do
    with {:ok, card} <- stated(event, now) do
      {:ok, put_plan(card, event, Map.get(event, :next_reminder_at) != nil)}
    end
  end

  @doc """
  The card of the event behind a reminder `reminder_snooze` deferred
  (`Registry.snooze_reminder/3`'s result), stated at `now`: `reminds` is when
  the snoozed reminder rings next, in the owner's zone, and `rings` where.
  `change: "snoozed"`, or none when it was already snoozed to that time.
  """
  @spec snoozed(Registry.snooze_result(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def snoozed(%{status: status, reminder: reminder, event: event, timezone: zone}, now)
      when status in [:created, :existing] and is_binary(zone) do
    with {:ok, card} <- stated(event, now),
         {:ok, next} <- next_ring(reminder.scheduled_for, zone, now) do
      card
      |> put_change(status == :created, "snoozed")
      |> Map.put("reminds", "again on " <> next)
      |> put_rings(reminder.delivery_platform)
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Hand `results` (each a `{:ok, card}` or `{:error, reason}` of this module)
  to the reply's blocks holder under the turn's conversation: the context's
  `:reply_blocks` (the holder's name, a test's own) and `:conversation_key`.
  A card that could not be made is logged and left out.
  """
  @spec put(map(), [{:ok, t()} | {:error, term()}]) :: :ok
  def put(context, results) when is_map(context) and is_list(results) do
    cards =
      Enum.flat_map(results, fn
        {:ok, card} ->
          [card]

        {:error, reason} ->
          Logger.error("an event's card for the reply was not made: #{inspect(reason)}")
          []
      end)

    context
    |> Map.get(:reply_blocks, ReplyBlocks)
    |> ReplyBlocks.put_events(Map.fetch!(context, :conversation_key), cards)
  end

  @doc "The time a card is stated at: the context's `:now_fn` (a test's clock), else now."
  @spec now(map()) :: DateTime.t()
  def now(%{now_fn: now_fn}) when is_function(now_fn, 0), do: now_fn.()
  def now(context) when is_map(context), do: DateTime.utc_now()

  @doc """
  A reminder plan in the engine's words (`reminds`), from the plan's rules as
  `Temporal.Defaults` decodes them: leads before the time of a timed event
  (`1 day and 1 hour before`), leads by day at a wall time (`1 week before and
  on the day, at 9:00 AM`), and `at the time`.
  """
  @spec plan_words([Defaults.rule()]) :: String.t()
  def plan_words([_ | _] = rules) do
    durations = for %{kind: :duration_before, seconds: seconds} <- rules, do: amount(seconds)
    at_time? = Enum.any?(rules, &(&1.kind == :at_occurrence))

    [before_phrase(durations) | day_phrases(rules)]
    |> Kernel.++(if at_time?, do: ["at the time"], else: [])
    |> Enum.reject(&is_nil/1)
    |> join()
  end

  @doc "Where a reminder rings, in the engine's words (`rings`), by its platform."
  @spec rings_words(String.t()) :: {:ok, String.t()} | {:error, term()}
  def rings_words(platform) when is_binary(platform) do
    case Map.fetch(@platform_words, platform) do
      {:ok, words} -> {:ok, words}
      :error -> {:error, {:unknown_delivery_platform, platform}}
    end
  end

  # --- the card --------------------------------------------------------------

  defp stated(event, now) do
    with {:ok, _date} <- occurrence_date(event) do
      base(event, Registry.stated_as(event, now))
    end
  end

  defp base(event, stated_as) do
    with {:ok, date} <- occurrence_date(event) do
      %{
        "event_id" => event.id,
        "title" => event.title,
        "kind" => event.kind,
        "date" => Date.to_iso8601(date),
        "timezone" => event.timezone,
        "status" => event.status,
        "when" => stated_as
      }
      |> put_time(event.local_time)
      |> put_yearly(event.recurrence_kind)
      |> then(&{:ok, &1})
    end
  end

  # The occurrence the reply is about: a yearly event's next one, which its
  # stored sentence names too, and a one-time event's own date.
  defp occurrence_date(%{recurrence_kind: "yearly", next_occurrence_on: %Date{} = date}),
    do: {:ok, date}

  defp occurrence_date(%{recurrence_kind: "once", local_date: %Date{} = date}), do: {:ok, date}
  defp occurrence_date(event), do: {:error, {:no_occurrence_date, Map.get(event, :id)}}

  defp put_time(card, %Time{hour: hour, minute: minute}),
    do: Map.put(card, "time", two_digits(hour) <> ":" <> two_digits(minute))

  defp put_time(card, nil), do: card

  defp put_yearly(card, "yearly"), do: Map.put(card, "yearly", true)
  defp put_yearly(card, "once"), do: card

  defp put_change(card, true, change), do: Map.put(card, "change", change)
  defp put_change(card, false, _change), do: card

  # The plan and its target, while a reminder of the event is left.
  defp put_plan(card, _event, false), do: card

  defp put_plan(card, event, true) do
    case Defaults.decode_plan(event.reminder_plan) do
      {:ok, []} ->
        card

      {:ok, rules} ->
        card |> Map.put("reminds", plan_words(rules)) |> put_rings(event.delivery_platform)

      {:error, reason} ->
        Logger.error("event #{event.id}'s reminder plan cannot be said: #{inspect(reason)}")
        card
    end
  end

  defp put_rings(card, platform) do
    case rings_words(platform) do
      {:ok, words} ->
        Map.put(card, "rings", words)

      {:error, reason} ->
        Logger.error("an event's card says no target: #{inspect(reason)}")
        card
    end
  end

  # The snoozed reminder's instant, in the owner's zone, stated as an event's
  # occurrence is: the weekday, the date and the wall time with its zone.
  defp next_ring(%DateTime{} = at, zone, now) do
    with {:ok, local} <- DateTime.shift_zone(at, zone),
         {:ok, local_now} <- DateTime.shift_zone(now, zone) do
      time = %Time{hour: local.hour, minute: local.minute, second: 0}
      {:ok, Renderer.stated_date!(DateTime.to_date(local), time, zone, local_now)}
    end
  end

  # --- the plan's words --------------------------------------------------------

  defp before_phrase([]), do: nil
  defp before_phrase(amounts), do: join(amounts) <> " before"

  # Leads by day, a phrase for each wall time they ring at, in plan order.
  defp day_phrases(rules) do
    days = Enum.filter(rules, &(&1.kind == :days_before))

    days
    |> Enum.map(& &1.at)
    |> Enum.uniq()
    |> Enum.map(fn at -> day_phrase(Enum.filter(days, &(&1.at == at)), at) end)
  end

  defp day_phrase(group, at) do
    leads = for %{days: days} <- group, days > 0, do: amount(days * 86_400)
    on_day = if Enum.any?(group, &(&1.days == 0)), do: ["on the day"], else: []

    [before_phrase(leads) | on_day]
    |> Enum.reject(&is_nil/1)
    |> join()
    |> Kernel.<>(", at " <> Renderer.clock_text(at))
  end

  defp amount(seconds) when is_integer(seconds) and seconds > 0 do
    {unit, length} = Enum.find(@units, fn {_unit, length} -> rem(seconds, length) == 0 end)
    plural(div(seconds, length), unit)
  end

  defp plural(1, unit), do: "1 " <> unit
  defp plural(count, unit), do: Integer.to_string(count) <> " " <> unit <> "s"

  defp join([one]), do: one
  defp join([first, second]), do: first <> " and " <> second

  defp join(phrases) do
    {init, [last]} = Enum.split(phrases, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp two_digits(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
