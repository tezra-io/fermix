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

  The lockfile is created and removed by `FermixCore.Plugins.Dist.Lock.Owner`,
  a process linked to the holder, rather than by a `try/after` in the holder
  itself. `after` covers a return and a raise but not an exit signal, and a
  cancelled management job stops its run with exactly that — so one Cancel used
  to strand the lockfile and refuse every plugin operation on the machine until
  the stale threshold expired.

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

  alias FermixCore.Plugins.Dist.Lock.Owner

  @doc """
  Acquire the lock at `lock_path`, run `fun`, and release — on every path the
  holder can leave by, including a raise and the exit signal a cancelled job
  sends. Returns `fun`'s result, or `{:error, :lock_unavailable}` if the lock
  could not be acquired within the attempt budget.

  Opts: `:attempts`, `:delay_ms`, `:stale_after_ms` (all bounded; tests shrink them).
  """
  @spec with_lock(Path.t(), (-> result), keyword()) :: result | {:error, :lock_unavailable}
        when result: term()
  def with_lock(lock_path, fun, opts \\ []) when is_binary(lock_path) and is_function(fun, 0) do
    File.mkdir_p!(Path.dirname(lock_path))
    {:ok, owner} = Owner.start_link(lock_path, self())

    try do
      hold(owner, fun, opts)
    after
      Owner.release(owner)
    end
  end

  defp hold(owner, fun, opts) do
    case Owner.acquire(owner, opts) do
      :ok -> fun.()
      {:error, _reason} = error -> error
    end
  end
end

defmodule FermixCore.Plugins.Dist.Lock.Owner do
  @moduledoc """
  The process that owns one plugin-store lockfile for the length of one
  critical section.

  It is linked to the holder and traps exits, so the holder's death — a crash,
  the `:shutdown` a cancelled management job sends, a brutal kill — arrives
  here as a message and the lockfile is removed in `terminate/2` before this
  process stops. `terminate/2` is the only place the file is removed, so there
  is one release path whether the section ended by returning, by raising, or by
  being killed.
  """

  use GenServer

  require Logger

  @default_attempts 50
  @default_delay_ms 100
  # See the stale-threshold invariant in `FermixCore.Plugins.Dist.Lock`:
  # downloads are idle-bounded and the local stages are seconds of disk I/O, so
  # a live holder never approaches this.
  @default_stale_after_ms 600_000
  # `release/1` is synchronous, so `with_lock` returns only once the file is
  # gone. All `terminate/2` does is one `File.rm`, so anything slower than this
  # is a wedged filesystem and exits loud rather than waiting on it.
  @stop_timeout_ms 5_000
  # Acquisition sleeps `attempts × delay_ms` at most; the slack covers the
  # filesystem calls around that loop.
  @acquire_slack_ms 5_000

  @spec start_link(Path.t(), pid()) :: GenServer.on_start()
  def start_link(lock_path, holder) when is_binary(lock_path) and is_pid(holder) do
    GenServer.start_link(__MODULE__, {lock_path, holder})
  end

  @doc """
  Creates the lockfile, bounded by the attempt budget. The owner holds it until
  `release/1` or until the holder dies, whichever comes first.
  """
  @spec acquire(pid(), keyword()) :: :ok | {:error, term()}
  def acquire(owner, opts) when is_pid(owner) and is_list(opts) do
    GenServer.call(owner, {:acquire, opts}, acquire_timeout(opts))
  end

  @doc "Removes the lockfile and stops the owner, synchronously."
  @spec release(pid()) :: :ok
  def release(owner) when is_pid(owner), do: GenServer.stop(owner, :normal, @stop_timeout_ms)

  @impl true
  def init({lock_path, holder}) do
    Process.flag(:trap_exit, true)
    {:ok, %{lock_path: lock_path, holder: holder, held?: false}}
  end

  @impl true
  def handle_call({:acquire, opts}, _from, state) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    delay = Keyword.get(opts, :delay_ms, @default_delay_ms)
    stale = Keyword.get(opts, :stale_after_ms, @default_stale_after_ms)

    case do_acquire(state.lock_path, attempts, delay, stale) do
      :ok -> {:reply, :ok, %{state | held?: true}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # The holder is gone, so nothing will call `release/1`. Say so — a lock
  # released this way means a critical section was cut short — and stop, which
  # is what runs `terminate/2`. Matched on the holder itself: any other trapped
  # exit is a message this process was never meant to receive, and reading it as
  # a release would drop the lock under a still-running section. It crashes here
  # instead, loudly.
  @impl true
  def handle_info({:EXIT, holder, reason}, %{holder: holder} = state) do
    Logger.warning(
      "plugin store lock #{state.lock_path} released: holder #{inspect(holder)} exited " <>
        inspect(reason)
    )

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{held?: false}), do: :ok

  def terminate(_reason, %{held?: true, lock_path: lock_path}) do
    case File.rm(lock_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("plugin store lock #{lock_path} could not be removed: #{inspect(reason)}")
    end
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

  # The call has to outlast the acquisition budget it carries, so the one bound
  # that decides the answer stays the attempt budget.
  defp acquire_timeout(opts) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    delay = Keyword.get(opts, :delay_ms, @default_delay_ms)

    attempts * delay + @acquire_slack_ms
  end

  # Debug breadcrumb only; staleness is judged by mtime, not this content.
  defp marker, do: "#{System.system_time(:millisecond)} #{System.pid()}\n"
end
