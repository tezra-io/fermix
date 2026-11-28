defmodule FermixCore.Setup.FermixHomeReadersTest do
  # `ConfigStore.fermix_home/0` is the one reading of FERMIX_HOME, and a blank
  # value is unset there. A reader that resolved the variable itself took ""
  # as a path: the daemon's socket and lock landed in the working directory
  # while the engine served `~/.fermix`. Only paths are computed here; no home
  # is created. async: false because it sets the process environment.
  use ExUnit.Case, async: false

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Upgrade.Swapper
  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Auth.Store
  alias FermixCore.Setup.ConfigStore

  setup do
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", "")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    %{home: ConfigStore.fermix_home()}
  end

  test "a blank FERMIX_HOME puts every reader under the resolver's home", %{home: home} do
    assert Path.type(home) == :absolute

    assert Daemon.default_socket_path() == Path.join(home, "daemon.sock")
    assert IdentityStore.dir() == Path.join(home, "acp_identities")
    assert Store.path() == Path.join(home, "auth.json")
    assert Swapper.default_staging_dir() == Path.join(home, "upgrade.staging")
  end
end
