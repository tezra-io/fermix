defmodule FermixCore.ComputerHistory.RecorderTest do
  # M97 §8.3, §8.8: whether this system has a recorder is the paired helper's
  # word (`Compux.Protocol.history_systems/0`), never this host's platform
  # alone, and an Always On server, at which nobody sits, has none (§19.2):
  # the server rule is `Home.AlwaysOn.here?/1`'s, run here on the facts it
  # decides on, never on a boolean handed in.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory
  alias FermixCore.Home.Epoch
  alias FermixTestSupport.SafeRm

  @primary %{role: :primary, primary: nil}
  @server_host %{install: :linux_package_cli, os: :linux, linux_app: false}
  @mac_host %{install: :app_engine, os: :darwin, linux_app: :not_asked}

  setup do
    home = SafeRm.make_tmp_dir!("history_recorder")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 2)
    %{home: home}
  end

  test "a Mac has a recorder", %{home: home} do
    assert ComputerHistory.recorder?(system: :macos, always_on: facts(home, @mac_host))
  end

  test "a Linux computer has one exactly where its paired helper records there",
       %{home: home} do
    desktop = facts(home, %{@server_host | linux_app: true})

    assert ComputerHistory.recorder?(system: :linux, always_on: desktop)

    refute ComputerHistory.recorder?(
             system: :linux,
             always_on: desktop,
             history_systems: [:macos]
           )
  end

  test "this release's helper records on macOS and Linux" do
    assert Compux.Protocol.history_systems() == [:macos, :linux]
  end

  test "an Always On server has none", %{home: home} do
    refute ComputerHistory.recorder?(system: :linux, always_on: facts(home, @server_host))
  end

  # The Linux computer the home came back to, another computer still linked:
  # it holds that computer's desktop row, and runs the Linux app.
  test "a Linux computer that took the home back keeps its recorder", %{home: home} do
    took_back = facts(home, %{@server_host | linux_app: true})
    assert ComputerHistory.recorder?(system: :linux, always_on: took_back)
  end

  # `fermix doctor` boots no engine: the server is told by its home and host.
  test "a tree-less verb on an Always On server finds no recorder", %{home: home} do
    treeless = [home: home, booted: nil, host_facts: @server_host]
    refute ComputerHistory.recorder?(system: :linux, always_on: treeless)
  end

  @tag :capture_log
  test "a server whose facts cannot be read records nothing", %{home: home} do
    File.write!(Epoch.path(home), "not an epoch\n")
    refute ComputerHistory.recorder?(system: :linux, always_on: facts(home, @server_host))
  end

  test "any other system has none", %{home: home} do
    refute ComputerHistory.recorder?(system: :other, always_on: facts(home, @mac_host))
  end

  # The default path, nothing handed in: this suite's engine is a source run,
  # no server, on a system its helper records on.
  test "this suite's engine, asked with no seams, has a recorder" do
    assert ComputerHistory.recorder?()
  end

  defp facts(home, host), do: [home: home, booted: @primary, host_facts: host]
end
