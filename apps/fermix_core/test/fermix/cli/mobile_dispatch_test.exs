defmodule Fermix.CLI.MobileDispatchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fermix.CLI

  test "top-level dispatcher routes pair without starting a local tree" do
    test_pid = self()

    output =
      capture_io(:stderr, fn ->
        send(test_pid, {:status, CLI.main(["pair", "unexpected"])})
      end)

    assert_received {:status, 2}
    assert output =~ "usage: fermix pair"
  end

  test "top-level dispatcher routes device management" do
    test_pid = self()

    output =
      capture_io(:stderr, fn ->
        send(test_pid, {:status, CLI.main(["devices", "delete"])})
      end)

    assert_received {:status, 2}
    assert output =~ "usage: fermix devices list"
  end
end
