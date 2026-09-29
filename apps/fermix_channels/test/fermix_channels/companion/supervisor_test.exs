defmodule FermixChannels.Companion.SupervisorTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Supervisor, as: CompanionSupervisor
  alias FermixChannels.Companion.Turns
  alias FermixCore.Memory.Repo
  alias FermixCore.Setup.ConfigStore

  # A test tree runs no Turns, so each test starts the one it drives.
  test "the application tree always holds the registry, and a test tree serves no socket" do
    assert is_pid(Process.whereis(Companion.registry()))
    assert is_pid(Process.whereis(Approvals))
    assert is_pid(Process.whereis(CompanionSupervisor))
    refute Process.whereis(Turns)
    refute Process.whereis(Endpoint)
    refute Process.whereis(CompanionSupervisor.request_coordinator())
  end

  # R1-7: Turns settles the phone's requests as well as the Mac's, so a boot
  # that serves no companion socket (`iex -S mix`) still runs it.
  test "a boot that settles but serves no socket runs Turns and nothing of the socket" do
    unique = System.unique_integer([:positive])

    supervisor =
      start_supervised!(
        {CompanionSupervisor,
         name: nil,
         serve?: false,
         settle?: true,
         boot_epoch: "boot-source",
         registry: :"companion_source_registry_#{unique}",
         approvals: :"companion_source_approvals_#{unique}"}
      )

    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    assert ids == [
             :"companion_source_registry_#{unique}",
             Turns,
             :"companion_source_approvals_#{unique}"
           ]
  end

  test "a boot that serves the socket without settling is refused" do
    assert_raise ArgumentError, ~r/serve/, fn ->
      CompanionSupervisor.init(serve?: true, settle?: false, boot_epoch: "boot-bad")
    end
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
         settle?: true,
         boot_epoch: "boot-sup",
         registry: :"companion_sup_registry_#{unique}",
         approvals: :"companion_sup_approvals_#{unique}",
         request_coordinator: :"companion_sup_coordinator_#{unique}",
         connection_supervisor: :"companion_sup_connections_#{unique}",
         socket_path: socket_path,
         store_opts: [repo: repo]}
      )

    ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    assert ids == [
             :"companion_sup_registry_#{unique}",
             Turns,
             :"companion_sup_approvals_#{unique}",
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
