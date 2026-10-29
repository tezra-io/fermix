defmodule FermixCore.Temporal.RendererTest do
  use ExUnit.Case, async: true

  alias FermixCore.Temporal.Renderer

  @tz "America/New_York"

  defp row(payload_overrides, event_occurrence_at) do
    payload =
      Map.merge(
        %{
          "title" => "Sarah's birthday",
          "kind" => "birthday",
          "rule_id" => "week_before",
          "occurrence_key" => "2026-09-14",
          "event_local_date" => "2026-09-14",
          "event_local_time" => nil,
          "timezone" => @tz
        },
        payload_overrides
      )

    %{payload: payload, event_occurrence_at: event_occurrence_at}
  end

  # 2026-09-14 00:00 EDT
  @birthday_at ~U[2026-09-14 04:00:00Z]
  # 2026-08-16 15:00 EDT
  @appointment_at ~U[2026-08-16 19:00:00Z]

  # Dinner on Sunday, 2026-08-16, at `time` EDT.
  defp evening_row(time) do
    {:ok, at} = DateTime.new(~D[2026-08-16], time, @tz)

    row(
      %{
        "title" => "Dinner with Sam",
        "kind" => "event",
        "occurrence_key" => "2026-08-16",
        "event_local_date" => "2026-08-16",
        "event_local_time" => Time.to_iso8601(time)
      },
      DateTime.shift_zone!(at, "Etc/UTC")
    )
  end

  defp appointment_row do
    row(
      %{
        "title" => "Dentist appointment",
        "kind" => "appointment",
        "rule_id" => "hour_1_before",
        "occurrence_key" => "2026-08-16",
        "event_local_date" => "2026-08-16",
        "event_local_time" => "15:00:00"
      },
      @appointment_at
    )
  end

  # A reminder leads with the moment in the words a person would use, then the
  # title; a birthday or anniversary, whose title is a name and an occasion,
  # reads as a sentence. Every fact the old form carried is still there.
  describe "render/2: the moment" do
    test "a week out says so, with the weekday and the date" do
      # 2026-09-07 09:00 EDT, the week-before rule's wall time.
      assert {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-09-07 13:00:00Z])
      assert text == "Sarah's birthday is a week from today, Monday, September 14."
    end

    test "on the day it says today" do
      assert {:ok, text} =
               Renderer.render(
                 row(%{"rule_id" => "day_of"}, @birthday_at),
                 ~U[2026-09-14 13:00:00Z]
               )

      assert text == "Sarah's birthday is today, Monday, September 14."
    end

    test "the day before it says tomorrow" do
      assert {:ok, text} =
               Renderer.render(
                 row(%{"rule_id" => "day_before"}, @birthday_at),
                 ~U[2026-09-13 13:00:00Z]
               )

      assert text == "Sarah's birthday is tomorrow, Monday, September 14."
    end

    test "two to six days out it names this weekday" do
      assert {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-09-11 13:00:00Z])
      assert text == "Sarah's birthday is this Monday, September 14."
    end

    test "further out it gives the weekday, the date and the day count" do
      assert {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-08-21 13:00:00Z])
      assert text == "Sarah's birthday is Monday, September 14, in 24 days."
    end

    test "an anniversary reads as a sentence too" do
      anniversary =
        row(%{"title" => "Our wedding anniversary", "kind" => "anniversary"}, @birthday_at)

      assert {:ok, text} = Renderer.render(anniversary, ~U[2026-09-11 13:00:00Z])
      assert text == "Our wedding anniversary is this Monday, September 14."
    end

    test "every other kind leads with the moment, so an instruction stays grammatical" do
      task =
        row(
          %{"title" => "Call the Fenwick surveyor", "kind" => "explicit_reminder"},
          @birthday_at
        )

      assert {:ok, text} = Renderer.render(task, ~U[2026-09-11 13:00:00Z])
      assert text == "This Monday, September 14: Call the Fenwick surveyor."
    end

    test "a payload with no kind leads with the moment" do
      untyped = %{
        row(%{}, @birthday_at)
        | payload: Map.delete(row(%{}, @birthday_at).payload, "kind")
      }

      assert {:ok, text} = Renderer.render(untyped, ~U[2026-09-11 13:00:00Z])
      assert text == "This Monday, September 14: Sarah's birthday."
    end

    test "a title that already ends a sentence gets no second stop" do
      task = row(%{"title" => "Call mum!", "kind" => "explicit_reminder"}, @birthday_at)

      assert {:ok, "Tomorrow, Monday, September 14: Call mum!"} =
               Renderer.render(task, ~U[2026-09-13 13:00:00Z])
    end

    test "a date already past is stated without a relative word, whatever the kind" do
      assert {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-09-15 13:00:00Z])
      assert text == "Monday, September 14: Sarah's birthday."
    end

    test "a different calendar year is named explicitly" do
      next_year =
        row(
          %{"occurrence_key" => "2027-09-14", "event_local_date" => "2027-09-14"},
          ~U[2027-09-14 04:00:00Z]
        )

      assert {:ok, text} = Renderer.render(next_year, ~U[2026-09-07 13:00:00Z])
      assert text == "Sarah's birthday is Tuesday, September 14, 2027, in 372 days."
    end

    test "tomorrow across the new year names the year" do
      new_year =
        row(
          %{
            "title" => "Renew the Ashby parking permit",
            "kind" => "deadline",
            "occurrence_key" => "2027-01-01",
            "event_local_date" => "2027-01-01"
          },
          ~U[2027-01-01 05:00:00Z]
        )

      assert {:ok, text} = Renderer.render(new_year, ~U[2026-12-31 14:00:00Z])
      assert text == "Tomorrow, Friday, January 1, 2027: Renew the Ashby parking permit."
    end
  end

  describe "render/2: a timed event" do
    test "later today it gives the time, the zone and the hours left" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 18:00:00Z])
      assert text == "Today at 3:00 PM EDT, in 1 hour: Dentist appointment."
    end

    test "from 6 PM it says tonight" do
      assert {:ok, text} = Renderer.render(evening_row(~T[18:00:00]), ~U[2026-08-16 20:00:00Z])
      assert text == "Tonight at 6:00 PM EDT, in 2 hours: Dinner with Sam."

      assert {:ok, text} = Renderer.render(evening_row(~T[17:59:00]), ~U[2026-08-16 19:59:00Z])
      assert text == "Today at 5:59 PM EDT, in 2 hours: Dinner with Sam."
    end

    test "tonight is the owner's evening even when it is already tomorrow in UTC" do
      dinner =
        row(
          %{
            "title" => "Dinner with Sam",
            "kind" => "event",
            "event_local_date" => "2026-08-16",
            "event_local_time" => "20:00:00",
            "timezone" => "America/Los_Angeles"
          },
          ~U[2026-08-17 03:00:00Z]
        )

      assert {:ok, text} = Renderer.render(dinner, ~U[2026-08-16 22:00:00Z])
      assert text == "Tonight at 8:00 PM PDT, in 5 hours: Dinner with Sam."
    end

    test "tomorrow it gives the weekday, the date and the time" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-15 19:00:13Z])
      assert text == "Tomorrow, Sunday, August 16, at 3:00 PM EDT: Dentist appointment."
    end

    test "this weekday, and further out with the day count" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-13 13:00:00Z])
      assert text == "This Sunday, August 16, at 3:00 PM EDT: Dentist appointment."

      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-01 13:00:00Z])
      assert text == "Sunday, August 16, at 3:00 PM EDT, in 15 days: Dentist appointment."
    end

    test "a clock change inside the window states the zone the event is in" do
      surveyor =
        row(
          %{
            "title" => "Call the Fenwick surveyor",
            "kind" => "explicit_reminder",
            "event_local_date" => "2026-11-02",
            "event_local_time" => "09:00:00"
          },
          ~U[2026-11-02 14:00:00Z]
        )

      # Friday, October 30, 09:00 EDT; the clocks go back on Sunday, November 1.
      assert {:ok, text} = Renderer.render(surveyor, ~U[2026-10-30 13:00:00Z])
      assert text == "This Monday, November 2, at 9:00 AM EST: Call the Fenwick surveyor."
    end

    # The live defect: delivered 13ms after the scheduled instant, a reminder read
    # one hour short — a floor shaved the hour. Seconds of scheduler latency must
    # never change the displayed number.
    test "scheduler latency does not shave the displayed hour" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 16:00:13Z])
      assert text == "Today at 3:00 PM EDT, in 3 hours: Dentist appointment."
    end

    test "the one-hour clause survives sub-minute latency instead of vanishing" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 18:00:30Z])
      assert text == "Today at 3:00 PM EDT, in 1 hour: Dentist appointment."
    end

    test "the hours are dropped when a retry lands under an hour before the event" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 18:30:00Z])
      assert text == "Today at 3:00 PM EDT: Dentist appointment."
    end

    test "the hours are dropped once the event has begun" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 19:30:00Z])
      assert text == "Today at 3:00 PM EDT: Dentist appointment."
    end
  end

  describe "render/2: bounds and refusals" do
    test "the message carries no ids, retry counts, or configuration details" do
      {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-09-07 13:00:00Z])

      refute text =~ "week_before"
      refute text =~ "attempt"
      refute text =~ "telegram"
      refute text =~ "rem_"
      refute text =~ "Reminder:"
    end

    test "an oversized title is cut at a grapheme boundary, never the moment" do
      now = ~U[2026-09-07 13:00:00Z]
      long = String.duplicate("é", 4_000)

      assert {:ok, text} = Renderer.render(row(%{"title" => long}, @birthday_at), now)
      assert byte_size(text) <= 1_800
      assert String.valid?(text)
      assert String.ends_with?(text, "… is a week from today, Monday, September 14.")

      task = row(%{"title" => long, "kind" => "explicit_reminder"}, @birthday_at)
      assert {:ok, text} = Renderer.render(task, now)
      assert byte_size(text) <= 1_800
      assert String.starts_with?(text, "A week from today, Monday, September 14: éé")
      assert String.ends_with?(text, "é…")
    end

    test "a payload missing its title is refused rather than rendered blank" do
      now = ~U[2026-09-07 13:00:00Z]
      broken = %{row(%{}, @birthday_at) | payload: %{"timezone" => @tz}}

      assert {:error, {:invalid_payload, "title"}} = Renderer.render(broken, now)
    end

    test "an unparsable event date is refused" do
      now = ~U[2026-09-07 13:00:00Z]
      broken = row(%{"event_local_date" => "not-a-date"}, @birthday_at)

      assert {:error, {:invalid_payload, "event_local_date"}} = Renderer.render(broken, now)
    end

    test "an unknown timezone is refused rather than silently rendered in UTC" do
      now = ~U[2026-09-07 13:00:00Z]
      broken = row(%{"timezone" => "Mars/Olympus"}, @birthday_at)

      assert {:error, {:invalid_timezone, "Mars/Olympus"}} = Renderer.render(broken, now)
    end
  end

  # The statement form `Temporal.Registry` confirms a WRITE with. A reminder
  # arrives beside its event, so the templates above lean on a relative clause;
  # a confirmation has to settle which day was meant, so this form always carries
  # the weekday and never a relative word.
  describe "stated_date!/4" do
    # 2026-08-02 08:00 EDT
    @stating_now DateTime.shift_zone!(~U[2026-08-02 12:00:00Z], @tz)

    test "a timed occurrence states weekday, date, wall time, and zone" do
      assert Renderer.stated_date!(~D[2026-08-16], ~T[15:00:00], @tz, @stating_now) ==
               "Sunday, August 16 at 3:00 PM EDT"
    end

    test "a date-only occurrence states the weekday and the date" do
      assert Renderer.stated_date!(~D[2026-08-14], nil, @tz, @stating_now) == "Friday, August 14"
    end

    # The same differs-from-the-current-year rule the reminder templates use, so
    # a next-year occurrence can never be read as this year's.
    test "an occurrence in another calendar year names the year; this year's does not" do
      assert Renderer.stated_date!(~D[2027-09-14], nil, @tz, @stating_now) ==
               "Tuesday, September 14, 2027"

      assert Renderer.stated_date!(~D[2026-09-14], nil, @tz, @stating_now) ==
               "Monday, September 14"
    end

    # The live defect in one assertion: asked just past midnight on a Friday for
    # "tomorrow morning", the two candidate days are Friday and Saturday, and the
    # weekday is the only part of the statement that tells them apart.
    test "consecutive days state different weekdays" do
      friday = Renderer.stated_date!(~D[2026-08-07], ~T[09:00:00], @tz, @stating_now)
      saturday = Renderer.stated_date!(~D[2026-08-08], ~T[09:00:00], @tz, @stating_now)

      assert friday == "Friday, August 7 at 9:00 AM EDT"
      assert saturday == "Saturday, August 8 at 9:00 AM EDT"
    end
  end

  describe "weekday/1 and month_name/1" do
    test "weekdays are spelled out from known dates" do
      assert Renderer.weekday(~D[2026-08-07]) == "Friday"
      assert Renderer.weekday(~D[2026-08-08]) == "Saturday"
      assert Renderer.weekday(~D[2026-09-14]) == "Monday"
      assert Renderer.weekday(~D[2026-08-02]) == "Sunday"
    end

    test "months are spelled out from their number" do
      assert Renderer.month_name(1) == "January"
      assert Renderer.month_name(9) == "September"
      assert Renderer.month_name(12) == "December"
    end
  end
end
