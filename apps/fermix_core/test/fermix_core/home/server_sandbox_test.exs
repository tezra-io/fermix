defmodule FermixCore.Home.ServerSandboxTest do
  # M97 §4: an Always On server whose machine-file migration left out the
  # settings it inherited records it once, for its summary's notice.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Home.ServerSandbox
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @inherited """
  [fermix_core.agent]
  name = "Orchard"

  [fermix_core.computer_use]
  enabled = true
  """

  setup do
    home = SafeRm.make_tmp_dir!("server_sandbox")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "a server that left out its inherited settings records it once", %{home: home} do
    File.write!(Path.join(home, "config.toml"), @inherited)
    assert ServerSandbox.read(home) == :absent

    log =
      capture_log(fn -> assert :ok = ConfigStore.migrate_machine_file(home, server?: true) end)

    assert log =~ "This server now uses its own sandbox setting: open."

    assert {:ok, %DateTime{} = at} = ServerSandbox.read(home)
    assert Bitwise.band(File.stat!(ServerSandbox.path(home)).mode, 0o777) == 0o600

    # The event happened once: a later record keeps the first.
    assert :ok = ServerSandbox.record(home, DateTime.add(at, 3_600))
    assert {:ok, ^at} = ServerSandbox.read(home)
  end

  test "a server with nothing inherited, and any other computer, records nothing", %{home: home} do
    other = Path.join(home, "mac")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "config.toml"), @inherited)

    _log =
      capture_log(fn -> assert :ok = ConfigStore.migrate_machine_file(home, server?: true) end)

    assert ServerSandbox.read(home) == :absent

    _log =
      capture_log(fn -> assert :ok = ConfigStore.migrate_machine_file(other, server?: false) end)

    assert ServerSandbox.read(other) == :absent
  end

  test "a record Fermix did not write is named", %{home: home} do
    File.mkdir_p!(Path.dirname(ServerSandbox.path(home)))
    File.write!(ServerSandbox.path(home), "{")

    assert {:error, {:invalid_record, _file}} = ServerSandbox.read(home)
  end
end
