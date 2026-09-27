defmodule FermixChannels.BrowserHost.SupervisorTest do
  use ExUnit.Case, async: true

  alias FermixChannels.BrowserHost.Endpoint
  alias FermixChannels.BrowserHost.Supervisor, as: BrowserHostSupervisor
  alias FermixCore.Setup.ConfigStore

  test "the application tree always holds the supervisor, and a test tree serves no socket" do
    assert is_pid(Process.whereis(BrowserHostSupervisor))
    refute Process.whereis(Endpoint)
  end

  test "a serving boot binds browser_host.sock owner-only" do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-browser-host-sup-#{unique}.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)

    supervisor =
      start_supervised!(
        {BrowserHostSupervisor,
         name: nil,
         serve?: true,
         connection_supervisor: :"browser_host_sup_connections_#{unique}",
         socket_path: socket_path}
      )

    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    assert ids == [:"browser_host_sup_connections_#{unique}", Endpoint]

    assert Bitwise.band(File.stat!(socket_path).mode, 0o777) == 0o600
  end

  test "the socket lives under FERMIX_HOME" do
    assert Path.basename(Endpoint.socket_path()) == "browser_host.sock"
    assert Path.dirname(Endpoint.socket_path()) == ConfigStore.fermix_home()
  end
end
