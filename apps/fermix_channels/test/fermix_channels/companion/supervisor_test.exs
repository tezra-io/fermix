defmodule FermixChannels.Companion.SupervisorTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Supervisor, as: CompanionSupervisor
  alias FermixCore.Memory.Repo
  alias FermixCore.Setup.ConfigStore

  test "the application tree always holds the registry, and a test tree serves no socket" do
    assert is_pid(Process.whereis(Companion.registry()))
    assert is_pid(Process.whereis(CompanionSupervisor))
    refute Process.whereis(Endpoint)
    refute Process.whereis(CompanionSupervisor.request_coordinator())
  end

  test "a serving boot binds companion.sock owner-only, after its coordinator" do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-companion-sup-#{unique}.sock")
    db_path = Path.join(System.tmp_dir!(), "fermix-companion-sup-#{unique}.db")
    repo = :"companion_sup_repo_#{unique}"

    on_exit(fn ->
      Enum.each(
        [socket_path, db_path, "#{db_path}-wal", "#{db_path}-shm"],
        &FermixTestSupport.SafeRm.rm/1
      )
    end)

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    supervisor =
      start_supervised!(
        {CompanionSupervisor,
         name: nil,
         serve?: true,
         boot_epoch: "boot-sup",
         registry: :"companion_sup_registry_#{unique}",
         request_coordinator: :"companion_sup_coordinator_#{unique}",
         connection_supervisor: :"companion_sup_connections_#{unique}",
         socket_path: socket_path,
         store_opts: [repo: repo]}
      )

    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    assert ids == [
             :"companion_sup_registry_#{unique}",
             :"companion_sup_coordinator_#{unique}",
             :"companion_sup_connections_#{unique}",
             Endpoint
           ]

    assert Bitwise.band(File.stat!(socket_path).mode, 0o777) == 0o600
  end

  test "the socket lives under FERMIX_HOME" do
    assert Path.basename(Endpoint.socket_path()) == "companion.sock"
    assert Path.dirname(Endpoint.socket_path()) == ConfigStore.fermix_home()
    assert Endpoint.max_clients() == 4
  end
end
