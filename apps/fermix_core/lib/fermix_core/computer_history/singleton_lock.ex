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
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, marker(opts))
        File.close(io)
        :ok

      {:error, :eexist} ->
        break_or_yield(path, stale_after, opts)

      {:error, reason} ->
        {:error, {:held_by, "unknown (#{inspect(reason)})"}}
    end
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

    case File.rename(path, claim) do
      :ok -> resolve_claim(path, claim, stale_after, opts)
      {:error, _lost_or_gone} -> {:error, {:held_by, holder_home(path)}}
    end
  end

  defp resolve_claim(path, claim, stale_after, opts) do
    if stale?(claim, stale_after) do
      _ = File.rm(claim)
      create_exclusive(path, opts)
    else
      # The lock was refreshed just before we grabbed it — it is live. Put it
      # back and stand down.
      _ = File.rename(claim, path)
      {:error, {:held_by, holder_home(path)}}
    end
  end

  defp create_exclusive(path, opts) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, marker(opts))
        File.close(io)
        :ok

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
    _ = File.rm(path)
    :ok
  end

  defp stale?(path, stale_after_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        (System.os_time(:second) - mtime) * 1000 > stale_after_ms

      # A lock that vanished between the eexist and the stat is effectively free.
      {:error, _reason} ->
        true
    end
  end

  defp holder_home(path) do
    case File.read(path) do
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
