defmodule FermixCore.Management.LifecycleRestartTest do
  # The self-restart a move or an activation makes, with the cgroup file, the
  # systemctl runner and the stop injected: nothing reaches a service manager.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Management.Lifecycle

  @user_unit "0::/user.slice/user-1000.slice/user@1000.service/app.slice/fermix.service\n"

  test "under a systemd user unit, its start budget is reset before the stop" do
    restart!(cgroup: fn -> {:ok, @user_unit} end, cmd: answering({"", 0}))

    assert_received {:cmd, "systemctl", ["--user", "reset-failed", "fermix.service"]}
    assert_received :stopped
  end

  test "under launchd, a system unit or with no cgroup file, only the stop" do
    for cgroup <- [
          fn -> {:error, :enoent} end,
          fn -> {:ok, "0::/system.slice/fermix.service\n"} end,
          fn -> {:ok, "0::/user.slice/user-1000.slice/user@1000.service/init.scope\n"} end
        ] do
      restart!(cgroup: cgroup, cmd: answering({"", 0}))

      refute_received {:cmd, _exe, _args}
      assert_received :stopped
    end
  end

  test "a reset systemd refuses is logged by its words, and the restart still happens" do
    log =
      capture_log(fn ->
        restart!(
          cgroup: fn -> {:ok, @user_unit} end,
          cmd: answering({"Failed to reset failed state: Access denied\n", 1})
        )
      end)

    assert_received :stopped
    assert log =~ "Access denied"
  end

  defp restart!(opts) do
    test = self()

    stop = fn ->
      send(test, :stopped)
      :ok
    end

    assert :ok = Lifecycle.restart_self(Keyword.put(opts, :stop, stop))
  end

  defp answering(answer) do
    test = self()

    fn exe, args ->
      send(test, {:cmd, exe, args})
      answer
    end
  end
end
