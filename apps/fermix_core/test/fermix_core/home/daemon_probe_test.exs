defmodule FermixCore.Home.DaemonProbeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.DaemonProbe
  alias FermixTestSupport.SafeRm

  test "the three answers an injected hello can give" do
    assert DaemonProbe.stopped("/invented/home", hello: fn -> {:error, :not_running} end) == :ok

    assert DaemonProbe.stopped("/invented/home", hello: fn -> {:ok, %{}} end) ==
             {:error, :daemon_running}

    assert DaemonProbe.stopped("/invented/home", hello: fn -> {:error, :eacces} end) ==
             {:error, {:daemon_probe_failed, :eacces}}
  end

  test "a home with no socket is stopped, and a home whose daemon answers is running" do
    home = short_home!()
    assert DaemonProbe.stopped(home) == :ok

    sup = :"daemon_probe_tasks_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {Fermix.CLI.Daemon,
       name: :"daemon_probe_daemon_#{System.unique_integer([:positive, :monotonic])}",
       socket_path: Path.join(home, "daemon.sock"),
       task_supervisor: sup}
    )

    assert DaemonProbe.stopped(home) == {:error, :daemon_running}
  end

  # A unix socket address is capped at 104 bytes on macOS, so the home sits
  # directly under the temp dir.
  defp short_home! do
    home = Path.join(System.tmp_dir!(), "fxp-#{System.unique_integer([:positive, :monotonic])}")
    SafeRm.mark!(home)
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    home
  end
end
