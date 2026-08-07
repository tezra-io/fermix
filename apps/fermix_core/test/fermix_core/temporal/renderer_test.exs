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

  describe "render/2" do
    test "an upcoming date-only reminder names the absolute date and the day count" do
      # 2026-09-07 09:00 EDT, the week-before rule's wall time.
      assert {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-09-07 13:00:00Z])
      assert text == "Reminder: Sarah's birthday is September 14 (in 7 days)."
    end

    test "a day-of date-only reminder uses the today template with no relative clause" do
      assert {:ok, text} =
               Renderer.render(
                 row(%{"rule_id" => "day_of"}, @birthday_at),
                 ~U[2026-09-14 13:00:00Z]
               )

      assert text == "Today: Sarah's birthday — September 14."
    end

    test "a timed reminder names date, time, and zone" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 18:00:00Z])
      assert text == "Reminder: Dentist appointment — August 16 at 3:00 PM EDT (in 1 hour)."
    end

    # The live defect: delivered 13ms after the scheduled instant, the 24h-before
    # reminder read "(in 23 hours)" — a floor shaved the hour. Seconds of
    # scheduler latency must never change the displayed number.
    test "scheduler latency does not shave the displayed hour" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-15 19:00:13Z])
      assert text == "Reminder: Dentist appointment — August 16 at 3:00 PM EDT (in 24 hours)."
    end

    test "the one-hour clause survives sub-minute latency instead of vanishing" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 18:00:30Z])
      assert text == "Reminder: Dentist appointment — August 16 at 3:00 PM EDT (in 1 hour)."
    end

    test "the relative clause is dropped when a retry lands under an hour before a timed event" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 18:30:00Z])
      assert text == "Reminder: Dentist appointment — August 16 at 3:00 PM EDT."
    end

    test "the relative clause is dropped once the event has begun" do
      assert {:ok, text} = Renderer.render(appointment_row(), ~U[2026-08-16 19:30:00Z])
      assert text == "Reminder: Dentist appointment — August 16 at 3:00 PM EDT."
    end

    test "a different calendar year is named explicitly" do
      next_year =
        row(
          %{"occurrence_key" => "2027-09-14", "event_local_date" => "2027-09-14"},
          ~U[2027-09-14 04:00:00Z]
        )

      assert {:ok, text} = Renderer.render(next_year, ~U[2026-09-07 13:00:00Z])
      assert text =~ "September 14, 2027"
    end

    test "a single day reads in the singular" do
      assert {:ok, text} =
               Renderer.render(
                 row(%{"rule_id" => "day_before"}, @birthday_at),
                 ~U[2026-09-13 13:00:00Z]
               )

      assert text == "Reminder: Sarah's birthday is September 14 (in 1 day)."
    end

    test "the message carries no ids, retry counts, or configuration details" do
      {:ok, text} = Renderer.render(row(%{}, @birthday_at), ~U[2026-09-07 13:00:00Z])

      refute text =~ "week_before"
      refute text =~ "attempt"
      refute text =~ "telegram"
      refute text =~ "rem_"
    end

    test "an oversized title is truncated at a grapheme boundary inside one bounded message" do
      now = ~U[2026-09-07 13:00:00Z]
      long = String.duplicate("é", 4_000)

      assert {:ok, text} = Renderer.render(row(%{"title" => long}, @birthday_at), now)

      assert byte_size(text) <= 1_800
      assert String.valid?(text)
      assert text =~ "…"
      assert text =~ "September 14 (in 7 days)."
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
end
