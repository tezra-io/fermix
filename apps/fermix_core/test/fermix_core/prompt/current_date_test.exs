defmodule FermixCore.Prompt.CurrentDateTest do
  # Mutates :personalization in Application env, so it must not run concurrently
  # with other reads of that key.
  use ExUnit.Case, async: false

  alias FermixCore.Prompt.CurrentDate

  setup do
    previous = Application.get_env(:fermix_core, :personalization)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :personalization)
        value -> Application.put_env(:fermix_core, :personalization, value)
      end
    end)

    :ok
  end

  test "note carries the current UTC date with the weekday and no clock time" do
    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    note = CurrentDate.note()
    now = DateTime.utc_now()

    assert note =~ "Current date:"
    assert note =~ "UTC"
    assert note =~ Integer.to_string(now.year)
    assert note =~ Calendar.strftime(now, "%A")
    # Date-only on purpose: the note sits ahead of history in every request,
    # so a minute-level stamp would bust provider prompt caches every turn.
    refute note =~ ~r/\d{1,2}:\d{2}/
  end

  test "note appends the configured timezone label" do
    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    assert CurrentDate.note() =~ "The user's timezone is America/New_York"
  end

  test "note omits the timezone clause when none is configured" do
    Application.put_env(:fermix_core, :personalization, [])

    note = CurrentDate.note()

    assert note =~ "Current date:"
    refute note =~ "timezone is"
  end
end
