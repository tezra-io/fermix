defmodule FermixCore.ApplicationHomeLockTest do
  # One engine serves a home at a time, and the proof is the lock beside its
  # control socket (`Fermix.CLI.Daemon.Lock`). A daemon boot takes it before it
  # reads or writes anything else in the home and before any child starts,
  # holds it for the life of the application, and a boot that finds it held
  # starts nothing: no home write, no ownership marker, no boot sweep over the
  # rows the running engine owns. The start function here stands in for the
  # tree's (`FermixCore.Application`'s `start_supervision_tree/0` passes the
  # real one), so the order is asserted without booting a second tree.
  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon.Lock
  alias FermixCore.Application, as: CoreApplication
  alias FermixTestSupport.SafeRm

  # A daemon too busy to accept turns a connection away as a stale socket
  # does (on macOS its full backlog refuses the connect at once), so a second
  # boot decides from the lock only a live daemon holds, never from the
  # connect: the busy daemon keeps its socket, and its home is left as it was.
  test "a daemon boot on a home whose lock is held starts nothing and leaves the home as it was" do
    home = home!()
    socket = Path.join(home, "daemon.sock")
    File.touch!(socket)
    {:ok, held} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(held) end)
    before = home |> File.ls!() |> Enum.sort()

    assert CoreApplication.start_holding_home_lock(true, socket, starting(self(), socket)) ==
             {:error, {:another_daemon_running, socket}}

    refute_received {:started, _held}
    assert home |> File.ls!() |> Enum.sort() == before
    assert Lock.held(socket) == {:ok, true}
  end

  # The first boot on a fresh machine: the home does not exist yet, and the
  # lock's own file is the one thing the boot makes before it starts the rest.
  test "a daemon boot on a fresh home holds the lock before it starts the rest, until it stops" do
    home = Path.join(home!(), "fresh")
    socket = Path.join(home, "daemon.sock")
    test = self()

    assert {:ok, ^test, state} =
             CoreApplication.start_holding_home_lock(true, socket, starting(test, socket))

    assert_received {:started, {:ok, true}}
    assert File.ls!(home) == [Path.basename(Lock.path(socket))]
    assert Lock.held(socket) == {:ok, true}

    assert CoreApplication.stop(state) == :ok
    assert Lock.held(socket) == {:ok, false}
  end

  test "a start that returns a failure lets go of the lock" do
    socket = Path.join(home!(), "daemon.sock")

    assert CoreApplication.start_holding_home_lock(true, socket, fn -> {:error, :refused} end) ==
             {:error, :refused}

    assert Lock.held(socket) == {:ok, false}
  end

  # The boot's own failures raise (`Home.Role.remember!/2` on a moved home,
  # an invalid epoch). A lock nobody refers to any more is also let go of once
  # its process collects its garbage, so the raise runs in a process whose
  # heap is too large to be collected during the case: only a release before
  # the raise goes on reads as released while that process lives.
  test "a start that raises lets go of the lock before the raise goes on" do
    socket = Path.join(home!(), "daemon.sock")
    test = self()

    raising =
      Process.spawn(
        fn ->
          raised =
            try do
              CoreApplication.start_holding_home_lock(true, socket, fn ->
                raise "this home moved"
              end)
            rescue
              error in RuntimeError -> error.message
            end

          send(test, {:raised, raised, Lock.held(socket)})
          receive do: (:done -> :ok)
        end,
        [:link, min_heap_size: 1_000_000]
      )

    assert_receive {:raised, "this home moved", {:ok, false}}
    send(raising, :done)
  end

  # `mix test`, `fermix memory` and a supervised `fermix setup` boot a tree
  # that is not the home's daemon, as before.
  test "a boot that is not a daemon's takes no lock and makes no lock file" do
    home = Path.join(home!(), "fresh")
    socket = Path.join(home, "daemon.sock")
    test = self()

    assert {:ok, ^test, state} =
             CoreApplication.start_holding_home_lock(false, socket, starting(test, socket))

    assert_received {:started, {:ok, false}}
    refute File.exists?(home)
    assert CoreApplication.stop(state) == :ok
  end

  test "a boot that is not a daemon's starts beside a held lock and leaves it held" do
    socket = Path.join(home!(), "daemon.sock")
    {:ok, held} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(held) end)
    test = self()

    assert {:ok, ^test, state} =
             CoreApplication.start_holding_home_lock(false, socket, starting(test, socket))

    assert_received {:started, {:ok, true}}
    assert CoreApplication.stop(state) == :ok
    assert Lock.held(socket) == {:ok, true}
  end

  # The tree's stand-in: it tells the test whether the lock was held when it
  # ran, and answers as `Supervisor.start_link/2` does.
  defp starting(test, socket) do
    fn ->
      send(test, {:started, Lock.held(socket)})
      {:ok, test}
    end
  end

  defp home! do
    home = SafeRm.make_tmp_dir!("home-lock")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    home
  end
end
