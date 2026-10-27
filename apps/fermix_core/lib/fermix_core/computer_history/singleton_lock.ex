defmodule FermixCore.ComputerHistory.SingletonLock do
  @moduledoc """
  A **machine-wide** singleton lock for the capturer (MILESTONE_32 §8.6). One
  login session is one event source, but two daemons with different
  `FERMIX_HOME`s (the live `~/.fermix` + a dev `~/.fermix-dev`) would each spawn
  a capturer and both attach AXObservers to the same apps — double-recording,
  and a race to write two spools of the same activity. So the lock lives at a
  path **independent of `FERMIX_HOME`** (`~/Library/Application Support/Fermix/
  observer.lock`); the second capturer detects it and **stands down loudly**,
  then re-checks on a bounded tick so that when the holder exits the standee
  re-acquires and resumes — rather than leaving capture dead on both.

  It is an `O_EXCL` create-or-fail lockfile (the `Plugins.Dist.Lock` primitive),
  but **held for the capturer's lifetime** rather than scoped to one operation,
  so the holder must **heartbeat** (refresh the mtime) to prove liveness: a
  standee breaks a lock only when it is both present and *stale* (older than the
  heartbeat threshold), so a live holder is never displaced and a crashed
  holder's lock cannot brick capture forever. The lock records the holder's
  `FERMIX_HOME` so status can name who holds it. The path is injectable so the
  suite never touches the real machine path.

  **Guarantee scope.** The uncontended path (a fresh lock) is exactly-once by
  `O_EXCL`. The stale-break path is race-safe for the **pairwise** threat model
  §8.6 names — two daemons on one Mac — proven by a looped concurrent test; a
  fully N-way-race-free break is not achievable with a lockfile alone (it needs a
  kernel advisory lock), but two is the real ceiling here, so pairwise is the
  guarantee the system depends on.
  """

  require Logger

  # A live holder heartbeats every @heartbeat_ms; a lock older than
  # @stale_after_ms is assumed abandoned by a crashed holder and is broken once.
  @stale_after_ms 30_000

  @doc "The default machine-wide (not FERMIX_HOME-scoped) lock path."
  @spec default_path() :: String.t()
  def default_path do
    Path.join([System.user_home!(), "Library", "Application Support", "Fermix", "observer.lock"])
  end

  @doc "Heartbeat interval — refresh the mtime well inside the stale window."
  @spec heartbeat_interval_ms() :: pos_integer()
  def heartbeat_interval_ms, do: 10_000

  @doc """
  Try to acquire the lock. Returns `:ok` (this process now holds it and must
  heartbeat) or `{:error, {:held_by, home}}` (another live daemon holds it —
  stand down and re-check later). A stale lock is broken once, then re-attempted.
  """
  @spec acquire(String.t(), keyword()) :: :ok | {:error, {:held_by, String.t() | nil}}
  def acquire(path, opts \\ []) when is_binary(path) do
    stale_after = Keyword.get(opts, :stale_after_ms, @stale_after_ms)
    ensure_folder!(Path.dirname(path))

    case open_exclusive(path) do
      {:ok, fd} ->
        write_marker(fd, opts)

      {:error, :eexist} ->
        break_or_yield(path, stale_after, opts)

      {:error, reason} ->
        {:error, {:held_by, "unknown (#{inspect(reason)})"}}
    end
  end

  # Acquiring, breaking and releasing make their file calls in this process
  # (`:raw`, or `:prim_file` where `:file` has no raw form), never through the
  # VM's one file server (`:file_server_2`), which runs each call to its end:
  # on a loaded machine every other file call in the VM queues there, and an
  # acquire waited behind them. `File.mkdir_p!/1` would also ask that server
  # twice for every ancestor of the folder, so it runs only for a folder that
  # is not there yet. The heartbeat's `File.touch/2` is raw already, and it
  # must keep re-creating a lock that is missing: a late holder whose lock a
  # breaker renamed away re-creates it, and the breaker's final O_EXCL create
  # then loses. The marker is written as the UTF-8 it is; the old Latin-1 io
  # device garbled an accented home and raised on one beyond Latin-1.
  defp ensure_folder!(folder) do
    if File.dir?(folder, [:raw]), do: :ok, else: File.mkdir_p!(folder)
  end

  defp open_exclusive(path), do: :file.open(path, [:write, :exclusive, :raw, :binary])

  defp write_marker(fd, opts) do
    written = :file.write(fd, marker(opts))
    closed = :file.close(fd)
    :ok = written
    :ok = closed
  end

  defp break_or_yield(path, stale_after, opts) do
    if stale?(path, stale_after) do
      break_stale(path, stale_after, opts)
    else
      {:error, {:held_by, holder_home(path)}}
    end
  end

  # Break a stale lock ATOMICALLY. A plain rm-then-create races: two daemons that
  # both see the stale lock (the live `~/.fermix` + a dev `~/.fermix-dev` is a
  # real pairing here) can interleave rm/create so BOTH proceed and double-record.
  # Instead, rename the stale file to a breaker-unique name — only one racer can
  # rename a given inode; the loser gets `:enoent` and yields. Then re-check the
  # file WE now solely hold is still stale (not a fresh lock that replaced it
  # between our stale-check and the rename); if it turned fresh, restore it and
  # yield. The final `O_EXCL` create arbitrates against any fresh creator that
  # slipped in after the rename, so at most one daemon ever holds.
  defp break_stale(path, stale_after, opts) do
    claim = "#{path}.break.#{System.system_time(:nanosecond)}.#{System.pid()}"

    case :prim_file.rename(path, claim) do
      :ok -> resolve_claim(path, claim, stale_after, opts)
      {:error, _lost_or_gone} -> {:error, {:held_by, holder_home(path)}}
    end
  end

  defp resolve_claim(path, claim, stale_after, opts) do
    if stale?(claim, stale_after) do
      _ = :file.delete(claim, [:raw])
      create_exclusive(path, opts)
    else
      # The lock was refreshed just before we grabbed it — it is live. Put it
      # back and stand down.
      _ = :prim_file.rename(claim, path)
      {:error, {:held_by, holder_home(path)}}
    end
  end

  defp create_exclusive(path, opts) do
    case open_exclusive(path) do
      {:ok, fd} ->
        write_marker(fd, opts)

      _lost_the_race ->
        {:error, {:held_by, holder_home(path)}}
    end
  end

  @doc "Refresh the lock's mtime to prove this holder is still alive."
  @spec heartbeat(String.t()) :: :ok
  def heartbeat(path) when is_binary(path) do
    now = System.os_time(:second)
    _ = File.touch(path, now)
    :ok
  end

  @doc "Release the lock (rm). Idempotent."
  @spec release(String.t()) :: :ok
  def release(path) when is_binary(path) do
    _ = :file.delete(path, [:raw])
    :ok
  end

  defp stale?(path, stale_after_ms) do
    case :file.read_file_info(path, [:raw, {:time, :posix}]) do
      {:ok, info} ->
        %File.Stat{mtime: mtime} = File.Stat.from_record(info)
        (System.os_time(:second) - mtime) * 1000 > stale_after_ms

      # A lock that vanished between the eexist and the stat is effectively free.
      {:error, _reason} ->
        true
    end
  end

  defp holder_home(path) do
    case :file.read_file(path, [:raw]) do
      {:ok, contents} -> parse_home(contents)
      {:error, _reason} -> nil
    end
  end

  defp parse_home(contents) do
    contents
    |> String.split("\n", trim: true)
    |> List.first()
  end

  # First line = the holder's FERMIX_HOME (named in status when contended);
  # second = a debug breadcrumb. Staleness is judged by mtime, not this content.
  defp marker(opts) do
    home = Keyword.get(opts, :home, fermix_home())
    "#{home}\n#{System.system_time(:millisecond)} #{System.pid()}\n"
  end

  defp fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end
end
