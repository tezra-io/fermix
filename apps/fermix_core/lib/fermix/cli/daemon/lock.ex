defmodule Fermix.CLI.Daemon.Lock do
  @moduledoc """
  The lock a running daemon holds beside its control socket for its whole
  life (`<socket>.lock`: `daemon.sock.lock` in a home), so "is Fermix
  stopped?" has an answer a busy daemon cannot get wrong.

  A daemon too busy to accept turns a connection away the way a stale socket
  does: on macOS a full listen backlog refuses the connect at once with
  `:econnrefused`, which is also what a socket no process listens on
  answers. So a failed connect alone never says stopped
  (`Fermix.CLI.Daemon.Client`): the client then asks this lock, which only a
  live daemon holds and which the operating system lets go of when that
  process ends, however it ends. A daemon that finds it held does not start
  (`Fermix.CLI.Daemon`).

  The lock is SQLite's: the daemon opens the file in exclusive locking mode
  and writes it once (`PRAGMA locking_mode=EXCLUSIVE`), which keeps the
  write's lock until the connection closes, with the journal in memory so
  nothing else is written beside the socket. It is the one advisory file
  lock this VM can take and test without a native shim of its own, and
  SQLite tells two connections of one process apart, so a test holds it in
  its own VM. The file is device-local (`*.lock`): no archive, snapshot or
  move reads it, which matters because closing any descriptor of a file
  drops the POSIX locks its process holds on it.
  """

  alias Exqlite.Sqlite3

  # SQLite's own words for SQLITE_BUSY: another connection holds the lock.
  @busy "database is locked"
  # A reader's held lock is the answer, never contention to wait out:
  # Exqlite opens every connection waiting up to 2 s on one.
  @no_wait "PRAGMA busy_timeout=0"
  # How long a starting daemon waits out the shared lock a client's read of
  # the file holds for that instant (`held/1`), so a read at boot is never
  # taken for another daemon. A live daemon never lets go, so one that holds
  # it is still refused once the wait is over.
  @reader_wait_ms 2_000

  @typedoc "A held lock: the connection that holds it."
  @type t :: reference()

  @type failure :: {:lock_failed, Path.t(), term()}
  @type unreadable :: {:lock_unreadable, Path.t(), term()}

  @doc "The lock's file beside `socket_path`."
  @spec path(Path.t()) :: Path.t()
  def path(socket_path) when is_binary(socket_path) and socket_path != "",
    do: socket_path <> ".lock"

  @doc """
  Takes the lock beside `socket_path` for as long as the caller keeps the
  answer and does not `release/1` it: `{:error, :held}` while another daemon
  holds it, and `{:lock_failed, path, reason}` when the file cannot be
  opened or written. A client reading the lock at that instant holds it
  shared for the read: the acquire waits that out, up to
  `opts[:reader_wait_ms]` (#{@reader_wait_ms} by default).
  """
  @spec acquire(Path.t(), keyword()) :: {:ok, t()} | {:error, :held | failure()}
  def acquire(socket_path, opts \\ [])
      when is_binary(socket_path) and socket_path != "" and is_list(opts) do
    path = path(socket_path)

    wait_ms = Keyword.get(opts, :reader_wait_ms, @reader_wait_ms)

    case Sqlite3.open(path) do
      {:ok, conn} -> hold(conn, path, wait_ms)
      {:error, reason} -> {:error, {:lock_failed, path, reason}}
    end
  end

  @doc "Lets go of a lock `acquire/1` took."
  @spec release(t()) :: :ok | {:error, term()}
  def release(lock) when is_reference(lock), do: Sqlite3.close(lock)

  @doc """
  Whether a daemon holds the lock beside `socket_path` now: false where no
  lock file is (a fresh home, an engine before the lock) or nothing holds
  it, and `{:lock_unreadable, path, reason}` when the file cannot be read.
  """
  @spec held(Path.t()) :: {:ok, boolean()} | {:error, unreadable()}
  def held(socket_path) when is_binary(socket_path) and socket_path != "" do
    path = path(socket_path)
    if File.exists?(path), do: try_lock(path), else: {:ok, false}
  end

  defp hold(conn, path, wait_ms) do
    case take(conn, wait_ms) do
      :ok ->
        {:ok, conn}

      {:error, reason} ->
        closed = Sqlite3.close(conn)
        not_taken(reason, closed, path)
    end
  end

  # The first write in exclusive locking mode takes the lock the connection
  # keeps; the row names the process that holds it, for whoever reads the file.
  defp take(conn, wait_ms) when is_integer(wait_ms) and wait_ms >= 0 do
    os_pid = String.to_integer(System.pid())

    with :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=#{wait_ms}"),
         :ok <- Sqlite3.execute(conn, "PRAGMA locking_mode=EXCLUSIVE"),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=MEMORY"),
         :ok <- Sqlite3.execute(conn, "BEGIN EXCLUSIVE"),
         :ok <- Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS holder (os_pid INTEGER)"),
         :ok <- Sqlite3.execute(conn, "DELETE FROM holder"),
         :ok <- Sqlite3.execute(conn, "INSERT INTO holder (os_pid) VALUES (#{os_pid})"),
         do: Sqlite3.execute(conn, "COMMIT")
  end

  defp not_taken(@busy, :ok, _path), do: {:error, :held}
  defp not_taken(reason, :ok, path), do: {:error, {:lock_failed, path, reason}}

  defp not_taken(reason, {:error, closing}, path),
    do: {:error, {:lock_failed, path, {reason, closing}}}

  # A read needs the shared lock a holder's exclusive one refuses.
  defp try_lock(path) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, conn} ->
        answer =
          with :ok <- Sqlite3.execute(conn, @no_wait),
               do: Sqlite3.execute(conn, "SELECT count(*) FROM sqlite_master")

        closed = Sqlite3.close(conn)
        read(answer, closed, path)

      {:error, reason} ->
        {:error, {:lock_unreadable, path, reason}}
    end
  end

  defp read(:ok, :ok, _path), do: {:ok, false}
  defp read({:error, @busy}, :ok, _path), do: {:ok, true}
  defp read({:error, reason}, :ok, path), do: {:error, {:lock_unreadable, path, reason}}
  defp read(_answer, {:error, closing}, path), do: {:error, {:lock_unreadable, path, closing}}
end
