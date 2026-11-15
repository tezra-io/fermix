defmodule Fermix.CLI.DaemonClientReachTest do
  # What the control socket's client answers when it cannot reach a daemon.
  # Only a missing socket or a refused connection while no daemon holds the
  # socket's lock (`Daemon.Lock`) is "not running": a connect that times out,
  # or one turned away while the lock is held, may be a daemon on a starved
  # machine (on macOS a full backlog refuses the connect at once), so Fermix
  # could not tell, and a verb that must not act on a live home refuses on it.
  # Every answer of the socket but one is injected (`:connect`), and nothing
  # waits on a real stall; the one real socket is a macOS listener whose full
  # backlog refuses the next connect.
  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Daemon.Lock
  alias FermixCore.Home.DaemonProbe
  alias FermixTestSupport.SafeRm

  # The bound on a connect a full backlog should refuse at once: only a
  # failing run waits it out.
  @connect_ms 10_000

  @socket "/invented/home/daemon.sock"

  defp connecting(answer), do: fn @socket, _timeout -> answer end

  test "a missing socket or a refused connection is not running" do
    for reason <- [:enoent, :econnrefused] do
      assert Client.request_v1("hello", %{},
               socket_path: @socket,
               connect: connecting({:error, reason})
             ) ==
               {:error, :not_running},
             inspect(reason)

      assert Client.request("status", socket_path: @socket, connect: connecting({:error, reason})) ==
               {:error, :not_running},
             inspect(reason)
    end
  end

  test "a connect that times out could not tell, and never reads as not running" do
    timed_out = connecting({:error, :timeout})

    assert Client.request_v1("hello", %{}, socket_path: @socket, connect: timed_out) ==
             {:error, :timeout}

    assert Client.request("status", socket_path: @socket, connect: timed_out) ==
             {:error, :timeout}

    assert Client.describe_error(:timeout) =~ "could not tell whether it is running"
  end

  test "the home's probe reads a connect that timed out as could not tell" do
    hello = fn ->
      Client.request_v1("hello", %{},
        socket_path: @socket,
        connect: connecting({:error, :timeout})
      )
    end

    assert DaemonProbe.stopped("/invented/home", hello: hello) ==
             {:error, {:daemon_probe_failed, :timeout}}
  end

  # The macOS case: a daemon too busy to accept has a full backlog, and the
  # next connect is refused at once, as a stale socket's is. Its lock says it
  # lives, so the refusal is "could not tell", never "not running".
  test "a connection turned away while a daemon holds the lock could not tell" do
    socket = Path.join(short_home!(), "daemon.sock")
    {:ok, lock} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(lock) end)

    for reason <- [:econnrefused, :enoent] do
      refused = fn ^socket, _timeout -> {:error, reason} end

      assert Client.request_v1("hello", %{}, socket_path: socket, connect: refused) ==
               {:error, :not_accepting},
             inspect(reason)

      assert Client.request("status", socket_path: socket, connect: refused) ==
               {:error, :not_accepting},
             inspect(reason)
    end

    assert Client.describe_error(:not_accepting) =~ "could not tell whether it is running"
  end

  # First run on a fresh machine, and a daemon that stopped or crashed: no
  # holder, so a refused or missing socket is stopped.
  test "a socket no daemon holds the lock of is not running, a lock file left behind included" do
    socket = Path.join(short_home!(), "daemon.sock")
    refused = fn ^socket, _timeout -> {:error, :econnrefused} end

    assert Client.request_v1("hello", %{}, socket_path: socket) == {:error, :not_running}

    assert Client.request_v1("hello", %{}, socket_path: socket, connect: refused) ==
             {:error, :not_running}

    {:ok, lock} = Lock.acquire(socket)
    :ok = Lock.release(lock)

    assert Client.request_v1("hello", %{}, socket_path: socket, connect: refused) ==
             {:error, :not_running}
  end

  test "a lock that cannot be read could not tell, naming it" do
    socket = Path.join(short_home!(), "daemon.sock")
    lock_path = Lock.path(socket)
    File.write!(lock_path, String.duplicate("not a database ", 64))
    refused = fn ^socket, _timeout -> {:error, :econnrefused} end

    assert {:error, {:lock_unreadable, ^lock_path, _reason} = reason} =
             Client.request_v1("hello", %{}, socket_path: socket, connect: refused)

    assert Client.describe_error(reason) =~ "could not tell whether it is running"
    assert Client.describe_error(reason) =~ lock_path
  end

  test "the home's probe reads a busy daemon as could not tell" do
    home = short_home!()
    socket = Path.join(home, "daemon.sock")
    {:ok, lock} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(lock) end)

    hello = fn ->
      Client.request_v1("hello", %{},
        socket_path: socket,
        connect: fn ^socket, _timeout -> {:error, :econnrefused} end
      )
    end

    assert DaemonProbe.stopped(home, hello: hello) ==
             {:error, {:daemon_probe_failed, :not_accepting}}

    # A fresh home: no socket, no lock.
    assert DaemonProbe.stopped(short_home!()) == :ok
  end

  # The real macOS kernel: a listener that never accepts, its backlog full.
  # Linux blocks such a connect instead of refusing it.
  unless :os.type() == {:unix, :darwin},
    do: @tag(skip: "only macOS refuses a full backlog's connect at once")

  test "on macOS a daemon whose backlog is full reads as could not tell" do
    socket = Path.join(short_home!(), "daemon.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, backlog: 1, ifaddr: {:local, socket}])

    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, lock} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(lock) end)

    assert {:error, :econnrefused} = fill_backlog(socket, 16)
    assert Client.request_v1("hello", %{}, socket_path: socket) == {:error, :not_accepting}
  end

  # Connects until the kernel refuses one, bounded; each waiting connection
  # stays open so the backlog stays full.
  defp fill_backlog(_socket, 0), do: :never_full

  defp fill_backlog(socket, left) do
    case :gen_tcp.connect({:local, to_charlist(socket)}, 0, [active: false], @connect_ms) do
      {:ok, conn} ->
        on_exit(fn -> :gen_tcp.close(conn) end)
        fill_backlog(socket, left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A unix socket address is capped at 104 bytes on macOS, so the home sits
  # directly under the temp dir.
  defp short_home! do
    home = Path.join(System.tmp_dir!(), "fxr-#{System.unique_integer([:positive, :monotonic])}")
    SafeRm.mark!(home)
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    home
  end
end
