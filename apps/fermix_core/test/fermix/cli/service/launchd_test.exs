defmodule Fermix.CLI.Service.LaunchdTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Service.Launchd

  # Intercept the launchctl shell-out so tests assert the exact argv without
  # touching the real service manager (hermetic: no host state mutation).
  setup do
    test = self()

    Application.put_env(:fermix_core, :launchctl_runner, fn "launchctl", args ->
      send(test, {:launchctl, args})
      {"", 0}
    end)

    on_exit(fn -> Application.delete_env(:fermix_core, :launchctl_runner) end)
    :ok
  end

  test "start uses plain kickstart — never -k, which SIGKILLs the running daemon" do
    assert :ok = Launchd.start(%{scope: :user, label: "io.tezra.fermix"})

    assert_received {:launchctl, args}
    assert "kickstart" in args
    refute "-k" in args, "start must not SIGKILL a running instance (the -9 relaunch loop)"
    assert Enum.any?(args, &String.ends_with?(&1, "/io.tezra.fermix"))
  end

  test "stop sends SIGTERM for a graceful drain" do
    assert :ok = Launchd.stop(%{scope: :user, label: "io.tezra.fermix"})

    assert_received {:launchctl, args}
    assert "kill" in args
    assert "TERM" in args
  end
end
