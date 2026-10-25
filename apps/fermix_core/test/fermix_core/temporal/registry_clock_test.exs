defmodule FermixCore.Temporal.RegistryClockTest do
  # async: false — the views state instants in the personalization timezone, global
  # `Application` env this file pins and restores.
  use ExUnit.Case, async: false

  alias FermixCore.Temporal.Registry

  setup do
    previous = Application.get_env(:fermix_core, :personalization)
    Application.put_env(:fermix_core, :personalization, timezone: "America/New_York")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :personalization)
        value -> Application.put_env(:fermix_core, :personalization, value)
      end
    end)

    :ok
  end

  test "a planned reminder's instants carry the owner's offset, not UTC's Z" do
    # 13:00 UTC on an August Sunday is 9:00 AM EDT in New York. Every id here is
    # invented.
    view =
      Registry.reminder_view(%{
        id: "rem_ferncastle01",
        reminder_rule_id: "day_of",
        occurrence_key: "2026-08-16",
        scheduled_for: ~U[2026-08-16 13:00:00.000000Z],
        valid_until: ~U[2026-08-16 19:00:00.000000Z],
        status: "pending"
      })

    assert view["scheduled_for"] == "2026-08-16T09:00:00-04:00"
    assert view["valid_until"] == "2026-08-16T15:00:00-04:00"
  end
end
