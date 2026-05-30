defmodule FermixCore.TelemetryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Telemetry

  test "timed_us returns the function result and elapsed microseconds" do
    assert {:ok, duration_us} = Telemetry.timed_us(fn -> :ok end)
    assert is_integer(duration_us)
    assert duration_us >= 0
  end
end
