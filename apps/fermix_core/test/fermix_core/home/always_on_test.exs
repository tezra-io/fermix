defmodule FermixCore.Home.AlwaysOnTest do
  @moduledoc """
  Which engine is an Always On server (M75 L20): the primary of a home that
  came to its host by a move or a restore (epoch above 1), run by the Linux
  package on a machine with no Fermix app. Every fact is handed in, so no test
  reads this machine, its role record or its home.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Home.AlwaysOn
  alias FermixCore.Home.Epoch
  alias FermixTestSupport.SafeRm

  @server %{role: :primary, install: :linux_package_cli, os: :linux, linux_app: false, epoch: 2}

  describe "server?/1" do
    test "the packaged Linux primary of a moved or restored home, with no app, is one" do
      assert AlwaysOn.server?(@server)
      assert AlwaysOn.server?(%{@server | epoch: 7})
    end

    test "a home that never moved or was restored is not, on the same host" do
      refute AlwaysOn.server?(%{@server | epoch: 1})
      refute AlwaysOn.server?(%{@server | epoch: nil})
    end

    test "a Linux desktop, whose Fermix app is installed, is not" do
      refute AlwaysOn.server?(%{@server | linux_app: true})
    end

    test "only the primary is: a desktop or a candidate waiting for its move is not" do
      refute AlwaysOn.server?(%{@server | role: :device})
      refute AlwaysOn.server?(%{@server | role: :candidate, epoch: nil})
    end

    test "only the Linux package is: the Mac app, a standalone binary or a source run is not" do
      refute AlwaysOn.server?(%{
               @server
               | install: :app_engine,
                 os: :darwin,
                 linux_app: :not_asked
             })

      refute AlwaysOn.server?(%{@server | install: :standalone_cli})
      refute AlwaysOn.server?(%{@server | install: :source})
    end

    test "anything but the facts it decides on is refused, loud" do
      assert_raise FunctionClauseError, fn -> AlwaysOn.server?(Map.delete(@server, :epoch)) end
      assert_raise FunctionClauseError, fn -> AlwaysOn.server?(%{@server | epoch: 0}) end
    end
  end

  describe "facts/3" do
    setup do
      home = SafeRm.make_tmp_dir!("always_on_facts")
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      %{home: home}
    end

    @linux_host %{install: :linux_package_cli, os: :linux, linux_app: false}

    test "a primary's facts carry the epoch its home holds", %{home: home} do
      :ok = Epoch.write(home, 3)

      assert AlwaysOn.facts(home, %{role: :primary, primary: nil}, @linux_host) ==
               %{
                 role: :primary,
                 install: :linux_package_cli,
                 os: :linux,
                 linux_app: false,
                 epoch: 3
               }
    end

    test "a primary with no epoch file has none", %{home: home} do
      assert %{epoch: nil} = AlwaysOn.facts(home, %{role: :primary, primary: nil}, @linux_host)
    end

    test "a device or a candidate is not asked for an epoch", %{home: home} do
      File.mkdir_p!(Path.join(home, "mobile"))
      File.write!(Epoch.path(home), "not an epoch\n")

      assert %{role: :device, epoch: nil} =
               AlwaysOn.facts(home, %{role: :device, primary: "north-box"}, @linux_host)

      assert %{role: :candidate, epoch: nil} =
               AlwaysOn.facts(home, %{role: :candidate, primary: nil}, @linux_host)
    end

    test "a primary's epoch file that cannot be read fails loud", %{home: home} do
      File.mkdir_p!(Path.join(home, "mobile"))
      File.write!(Epoch.path(home), "not an epoch\n")

      assert_raise RuntimeError, ~r/primary epoch/, fn ->
        AlwaysOn.facts(home, %{role: :primary, primary: nil}, @linux_host)
      end
    end
  end
end
