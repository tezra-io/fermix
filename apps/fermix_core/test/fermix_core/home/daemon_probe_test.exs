defmodule FermixCore.Home.DaemonProbeTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon.Lock
  alias FermixCore.Home.DaemonProbe
  alias FermixTestSupport.SafeRm

  # The probe's reply bound over a real socket: an answer returns at once, so
  # only a failing run waits it out (the client's own 3 s raced a busy runner).
  @hello_ms 10_000

  test "the three answers an injected hello can give" do
    assert DaemonProbe.stopped("/invented/home", hello: fn -> {:error, :not_running} end) == :ok

    assert DaemonProbe.stopped("/invented/home", hello: fn -> {:ok, %{}} end) ==
             {:error, :daemon_running}

    assert DaemonProbe.stopped("/invented/home", hello: fn -> {:error, :eacces} end) ==
             {:error, {:daemon_probe_failed, :eacces}}
  end

  # The probe over a real socket, against a listener that answers `hello` as
  # soon as the frame arrives. Not the engine's daemon: its answer runs the
  # management router through several processes and reads this VM's global
  # settings. What this asserts is the probe's answer to a socket that
  # answers, within a bound the test names rather than the client's own.
  test "a home with no socket is stopped, and a home whose daemon answers is running" do
    home = short_home!()
    assert DaemonProbe.stopped(home) == :ok

    listen = listening!(Path.join(home, "daemon.sock"))
    test = self()
    start_supervised!({Task, fn -> answer_hello(listen, test) end})

    assert DaemonProbe.stopped(home, hello_timeout: @hello_ms) == {:error, :daemon_running}
    assert_receive {:asked, "hello"}
  end

  # A daemon that crashed left its socket and its lock file, and holds
  # neither: stopped. One that holds its lock but turns the connection away
  # is too busy to answer: could not tell.
  test "a stale socket is stopped, and one whose daemon holds the lock could not tell" do
    home = short_home!()
    socket = Path.join(home, "daemon.sock")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, socket}])
    :ok = :gen_tcp.close(listen)
    {:ok, left} = Lock.acquire(socket)
    :ok = Lock.release(left)

    assert DaemonProbe.stopped(home) == :ok

    {:ok, lock} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(lock) end)

    assert DaemonProbe.stopped(home) == {:error, {:daemon_probe_failed, :not_accepting}}
  end

  # Listening before the probe dials: `listen/2` returns once the socket is
  # bound and accepting connections into its backlog.
  defp listening!(path) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: 4, ifaddr: {:local, path}])

    on_exit(fn -> :gen_tcp.close(listen) end)
    listen
  end

  # One connection, one v1 answer: the request's own id and an empty result,
  # sent the moment the frame is read. Each wait ends on the socket's event.
  defp answer_hello(listen, test) do
    {:ok, conn} = :gen_tcp.accept(listen)
    {:ok, frame} = :gen_tcp.recv(conn, 0)
    %{"request_id" => id, "method" => method} = Jason.decode!(frame)
    send(test, {:asked, method})
    :ok = :gen_tcp.send(conn, Jason.encode!(%{"request_id" => id, "result" => %{}}))
    :gen_tcp.close(conn)
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
