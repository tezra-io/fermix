defmodule Fermix.CLI.Daemon.LockTest do
  # The lock a running daemon holds beside its socket (`<socket>.lock`): only
  # a live holder holds it, and it is free again once the holder lets go or
  # its process ends. Held here in the test's own VM, which SQLite tells apart
  # from the probe's connection as it would another process.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Fermix.CLI.Daemon.Lock
  alias FermixTestSupport.SafeRm

  # How long a starting daemon may wait a reader out, in the test that lets
  # the reader go: a waiting acquire returns the moment it may, so only a
  # failing run waits it out.
  @reader_wait_ms 30_000
  # Looks, 10 ms apart, for the starting daemon to be waiting: 10 s at most.
  @looks 1_000

  setup do
    dir = SafeRm.make_tmp_dir!("daemon_lock")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{socket: Path.join(dir, "daemon.sock")}
  end

  test "a fresh home has no lock, so nothing holds it", %{socket: socket} do
    assert Lock.path(socket) == socket <> ".lock"
    assert Lock.held(socket) == {:ok, false}
    refute File.exists?(Lock.path(socket))
  end

  test "a held lock is held, refused to a second holder, and free once released", %{
    socket: socket
  } do
    assert {:ok, lock} = Lock.acquire(socket)
    assert Lock.held(socket) == {:ok, true}
    assert Lock.acquire(socket) == {:error, :held}

    assert Lock.release(lock) == :ok
    assert Lock.held(socket) == {:ok, false}

    # Free again for the next daemon, which holds it in its turn.
    assert {:ok, again} = Lock.acquire(socket)
    assert Lock.held(socket) == {:ok, true}
    assert Lock.release(again) == :ok
  end

  # A daemon that crashes never releases it: its connection goes with its
  # process, as the operating system drops a dead process's locks.
  test "the lock is free once the process holding it is gone", %{socket: socket} do
    test = self()

    holder =
      spawn(fn ->
        {:ok, _lock} = Lock.acquire(socket)
        send(test, :holding)

        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(holder)
    assert_receive :holding
    assert Lock.held(socket) == {:ok, true}

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    :erlang.garbage_collect()

    assert Lock.held(socket) == {:ok, false}
  end

  # A client that reads the lock (`held/1`) holds SQLite's shared lock for the
  # instant of its read. A daemon starting at that instant waits the read out
  # rather than taking it for another daemon's lock.
  test "a daemon starting while a client reads the lock waits the read out", %{socket: socket} do
    path = Lock.path(socket)
    {:ok, first} = Lock.acquire(socket)
    :ok = Lock.release(first)
    reader = reading!(path)

    starting = Task.async(fn -> Lock.acquire(socket, reader_wait_ms: @reader_wait_ms) end)
    :ok = await_waiting(starting, path, @looks)

    :ok = Sqlite3.execute(reader, "COMMIT")
    :ok = Sqlite3.close(reader)

    assert {:ok, lock} = Task.await(starting, @reader_wait_ms)
    assert Lock.held(socket) == {:ok, true}
    assert Lock.release(lock) == :ok
  end

  # A live daemon never lets go, so the wait ends refused.
  test "a holder that never lets go is still refused once the wait is over", %{socket: socket} do
    {:ok, holder} = Lock.acquire(socket)
    on_exit(fn -> Lock.release(holder) end)

    assert Lock.acquire(socket, reader_wait_ms: 50) == {:error, :held}
    assert Lock.held(socket) == {:ok, true}
  end

  test "a lock file left by a daemon that stopped is free", %{socket: socket} do
    {:ok, lock} = Lock.acquire(socket)
    :ok = Lock.release(lock)

    assert File.exists?(Lock.path(socket))
    assert Lock.held(socket) == {:ok, false}
  end

  test "a lock that cannot be read says so, naming the file", %{socket: socket} do
    path = Lock.path(socket)
    File.write!(path, String.duplicate("not a database ", 64))

    assert {:error, {:lock_unreadable, ^path, _reason}} = Lock.held(socket)
    assert {:error, {:lock_failed, ^path, _reason}} = Lock.acquire(socket)
  end

  # A client's read of the lock caught mid-way: SQLite's shared lock, held
  # until the read's transaction ends.
  defp reading!(path) do
    {:ok, reader} = Sqlite3.open(path, mode: :readonly)
    :ok = Sqlite3.execute(reader, "BEGIN")
    :ok = Sqlite3.execute(reader, "SELECT count(*) FROM sqlite_master")
    reader
  end

  # Until the starting daemon waits on the read: it then holds SQLite's
  # pending lock, which turns a new read away. One that ended at once (it did
  # not wait) fails the test with what it answered.
  defp await_waiting(_starting, _path, 0), do: flunk("the starting daemon never waited")

  defp await_waiting(starting, path, looks) do
    case Task.yield(starting, 10) do
      {:ok, ended} -> flunk("the acquire did not wait the read out: #{inspect(ended)}")
      nil -> if pending?(path), do: :ok, else: await_waiting(starting, path, looks - 1)
    end
  end

  defp pending?(path) do
    {:ok, probe} = Sqlite3.open(path, mode: :readonly)
    :ok = Sqlite3.execute(probe, "PRAGMA busy_timeout=0")
    answer = Sqlite3.execute(probe, "SELECT count(*) FROM sqlite_master")
    :ok = Sqlite3.close(probe)
    answer == {:error, "database is locked"}
  end
end
