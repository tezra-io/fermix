defmodule FermixCore.TelemetryTest do
  # Sync: the capture-content tests mutate the global :telemetry app env.
  use ExUnit.Case, async: false

  alias FermixCore.Telemetry

  test "timed_us returns the function result and elapsed microseconds" do
    assert {:ok, duration_us} = Telemetry.timed_us(fn -> :ok end)
    assert is_integer(duration_us)
    assert duration_us >= 0
  end

  describe "with content capture off" do
    setup do
      set_capture(false)
    end

    test "preview truncates long strings to the 2k bound" do
      long = String.duplicate("a", 3_000)

      assert Telemetry.preview(long) ==
               String.duplicate("a", 2_000) <> "…[truncated]"
    end

    test "preview elides large terms via inspect limits" do
      assert Telemetry.preview(Enum.to_list(1..200)) =~ "..."
    end
  end

  describe "with content capture on" do
    setup do
      set_capture(true)
    end

    test "preview returns long strings whole" do
      long = String.duplicate("a", 3_000)
      assert Telemetry.preview(long) == long
    end

    test "preview inspects terms without eliding" do
      preview = Telemetry.preview(Enum.to_list(1..200))
      refute preview =~ "..."
      assert preview =~ "200"
    end
  end

  defp set_capture(value) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, value))
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)
    :ok
  end
end
