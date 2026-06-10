defmodule FermixCore.Plugins.Dist.Lock do
  @moduledoc """
  Cross-VM advisory lock for the plugin store, so two BEAM VMs sharing one
  `$FERMIX_HOME` (the daemon serving the web page + a separate `fermix plugins`
  CLI process) cannot interleave a mutating pipeline. A GenServer mailbox only
  serializes within one VM; this is the layer that crosses processes.

  Implemented as an `O_EXCL` lockfile (atomic create-or-fail on the same
  filesystem). Acquisition is **bounded** — a fixed number of attempts with a
  delay, then fail loud (`{:error, :lock_unavailable}`), never an indefinite
  block. A lockfile older than the stale threshold is assumed to belong to a
  crashed holder and is broken once, so a dead process cannot brick plugin
  management forever.

  **Stale-threshold invariant.** The lock is held across the whole install
  pipeline (download → extract → hash → activate), so every stage must be
  time-bounded for stale-breaking to be safe. Download is the only network
  stage and `Net.StreamDownload` caps idle time with a `receive_timeout` — a
  stalled or dead connection fails (releasing the lock) long before the stale
  threshold. The remaining stages are local disk I/O over a small artifact
  tree (KB to tens of MB) and finish in seconds. So a lockfile older than the
  threshold is necessarily a crashed holder, not a slow-but-live one, and
  breaking it is safe.
  """

  @default_attempts 50
  @default_delay_ms 100
  # See the stale-threshold invariant above: downloads are idle-bounded, the
  # local stages are seconds of disk I/O, so a live holder never approaches this.
  @default_stale_after_ms 600_000

  @doc """
  Acquire the lock at `lock_path`, run `fun`, and release — even if `fun`
  raises. Returns `fun`'s result, or `{:error, :lock_unavailable}` if the lock
  could not be acquired within the attempt budget.

  Opts: `:attempts`, `:delay_ms`, `:stale_after_ms` (all bounded; tests shrink them).
  """
  @spec with_lock(Path.t(), (-> result), keyword()) :: result | {:error, :lock_unavailable}
        when result: term()
  def with_lock(lock_path, fun, opts \\ []) when is_binary(lock_path) and is_function(fun, 0) do
    case acquire(lock_path, opts) do
      :ok ->
        try do
          fun.()
        after
          release(lock_path)
        end

      {:error, _} = error ->
        error
    end
  end

  defp acquire(lock_path, opts) do
    File.mkdir_p!(Path.dirname(lock_path))
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    delay = Keyword.get(opts, :delay_ms, @default_delay_ms)
    stale = Keyword.get(opts, :stale_after_ms, @default_stale_after_ms)
    do_acquire(lock_path, attempts, delay, stale)
  end

  defp do_acquire(_lock_path, attempts, _delay, _stale) when attempts <= 0,
    do: {:error, :lock_unavailable}

  defp do_acquire(lock_path, attempts, delay, stale) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, marker())
        File.close(io)
        :ok

      {:error, :eexist} ->
        maybe_break_stale(lock_path, stale)
        Process.sleep(delay)
        do_acquire(lock_path, attempts - 1, delay, stale)

      {:error, reason} ->
        {:error, {:lock_open_failed, reason}}
    end
  end

  defp maybe_break_stale(lock_path, stale_after_ms) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        age_ms = (System.system_time(:second) - mtime) * 1000
        if age_ms > stale_after_ms, do: File.rm(lock_path)

      {:error, _} ->
        :ok
    end
  end

  defp release(lock_path), do: File.rm(lock_path)

  # Debug breadcrumb only; staleness is judged by mtime, not this content.
  defp marker, do: "#{System.system_time(:millisecond)} #{System.pid()}\n"
end
