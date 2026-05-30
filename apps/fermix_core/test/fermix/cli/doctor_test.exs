defmodule Fermix.CLI.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Doctor

  test "without --full, prints a report and exits with a valid status" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:doctor_status, Doctor.run([])})
      end)

    status =
      receive do
        {:doctor_status, value} -> value
      after
        100 -> 0
      end

    assert status in [0, 1]
    assert output =~ "fermix doctor"
    assert output =~ "setup secrets"
    assert output =~ "ok,"
    assert output =~ "warning(s)"
    assert output =~ "failure(s)"
  end

  test "rejects unknown options with non-zero exit" do
    test_self = self()

    output =
      capture_io(:stderr, fn ->
        send(test_self, {:doctor_status, Doctor.run(["--bogus"])})
      end)

    status =
      receive do
        {:doctor_status, value} -> value
      after
        100 -> 0
      end

    assert status == 1
    assert output =~ "invalid options"
  end
end
